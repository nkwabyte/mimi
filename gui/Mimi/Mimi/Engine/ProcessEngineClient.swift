//
//  ProcessEngineClient.swift
//  Mimi
//

import Foundation

/// Launches the mimi CLI and streams its JSONL output.
///
/// The executable is a fixed path. Arguments come from `EngineCommand` and are
/// never joined into a shell string. The process gets a small environment, not
/// a copy of the user's, so secrets and shell startup variables are not passed
/// through.
nonisolated final class ProcessEngineClient: EngineClientProtocol, @unchecked Sendable {
    let engineURL: URL
    private var process: Process?
    private var cancelled = false
    private let lock = NSLock()

    init(customEngineURL: URL? = nil) {
        if let custom = customEngineURL {
            engineURL = custom
            return
        }

        let bundle = Bundle.main
        if let auxURL = bundle.url(forAuxiliaryExecutable: "engine/bin/mimi"),
           FileManager.default.isExecutableFile(atPath: auxURL.path) {
            engineURL = auxURL
            return
        }
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Resources/engine/bin/mimi")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            engineURL = bundled
            return
        }

        #if DEBUG
        // Development builds only: gui/Mimi/Mimi/Engine/<this file> puts the
        // repository root four levels up. #filePath is the build machine's
        // source path, so release builds must not carry it.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devBin = repoRoot.appendingPathComponent("bin/mimi")
        if FileManager.default.isExecutableFile(atPath: devBin.path) {
            engineURL = devBin
            return
        }
        #endif

        for path in ["/opt/homebrew/bin/mimi", "/usr/local/bin/mimi"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                engineURL = URL(fileURLWithPath: path)
                return
            }
        }

        // Nothing found: point at the bundled location so the error names it.
        engineURL = bundled
    }

    var engineLocation: String {
        if FileManager.default.isExecutableFile(atPath: engineURL.path) {
            return engineURL.path
        }
        return "\(engineURL.path) (not executable)"
    }

    func events(for command: EngineCommand) -> AsyncThrowingStream<(String, EngineEvent), Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.run(command, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        proc?.terminate()
    }

    private func run(
        _ command: EngineCommand,
        continuation: AsyncThrowingStream<(String, EngineEvent), Error>.Continuation
    ) async {
        guard FileManager.default.isExecutableFile(atPath: engineURL.path) else {
            continuation.finish(throwing: EngineError.engineNotFound(engineURL.path))
            return
        }

        let proc = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stderrCapture = StderrCapture()
        proc.executableURL = engineURL
        proc.arguments = command.arguments
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice
        proc.environment = Self.engineEnvironment()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrCapture.append(chunk) }
        }

        begin(proc)

        do {
            try proc.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.finish(throwing: EngineError.engineNotFound(engineURL.path))
            return
        }

        let handle = stdout.fileHandleForReading
        var buffer = Data()
        var sawRunFinished = false
        do {
            while true {
                if Task.isCancelled || isCancelled {
                    proc.terminate()
                    continuation.finish()
                    stderr.fileHandleForReading.readabilityHandler = nil
                    return
                }
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 16_384)
                } catch {
                    proc.terminate()
                    continuation.finish(throwing: error)
                    stderr.fileHandleForReading.readabilityHandler = nil
                    return
                }
                if chunk == nil || chunk?.isEmpty == true { break }
                buffer.append(chunk!)
                if buffer.count > EngineEventDecoder.maxLineBytes {
                    proc.terminate()
                    continuation.finish(throwing: EngineError.eventTooLarge)
                    stderr.fileHandleForReading.readabilityHandler = nil
                    return
                }
                let produced = try consumeLines(from: &buffer, to: continuation)
                if produced.finished { sawRunFinished = true }
                if produced.stopped {
                    proc.terminate()
                    stderr.fileHandleForReading.readabilityHandler = nil
                    return
                }
            }
            if !buffer.isEmpty {
                let produced = try consumeLines(from: &buffer, to: continuation, flushTail: true)
                if produced.finished { sawRunFinished = true }
            }
        } catch {
            proc.terminate()
            continuation.finish(throwing: error)
            stderr.fileHandleForReading.readabilityHandler = nil
            return
        }

        proc.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        if Task.isCancelled || isCancelled {
            continuation.finish()
            return
        }
        // A run_finished event already told the app how the scan ended, including
        // a partial exit. Throwing here would hide that summary.
        if proc.terminationStatus != 0 && !sawRunFinished {
            let detail = stderrCapture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.finish(throwing: EngineError.processFailed(
                exitCode: proc.terminationStatus,
                message: detail
            ))
        } else {
            continuation.finish()
        }
    }

    private func begin(_ proc: Process) {
        lock.lock()
        cancelled = false
        process = proc
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private struct EmitResult {
        var finished = false
        var stopped = false
    }

    private func consumeLines(
        from buffer: inout Data,
        to continuation: AsyncThrowingStream<(String, EngineEvent), Error>.Continuation,
        flushTail: Bool = false
    ) throws -> EmitResult {
        var result = EmitResult()
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let outcome = try emit(lineData, to: continuation) {
                result.finished = result.finished || outcome.finished
                if outcome.stopped {
                    result.stopped = true
                    return result
                }
            }
        }
        if flushTail, !buffer.isEmpty {
            let tail = buffer
            buffer.removeAll()
            if let outcome = try emit(tail, to: continuation) {
                result.finished = result.finished || outcome.finished
                result.stopped = outcome.stopped
            }
        }
        return result
    }

    private func emit(
        _ lineData: Data,
        to continuation: AsyncThrowingStream<(String, EngineEvent), Error>.Continuation
    ) throws -> EmitResult? {
        guard !lineData.isEmpty else { return nil }
        guard var line = String(data: lineData, encoding: .utf8) else {
            // One unreadable line is reported, not allowed to end the run.
            continuation.yield(("", .warning(code: "undecodable_event", message: "The engine sent a line that is not UTF-8.")))
            return nil
        }
        if line.hasSuffix("\r") { line.removeLast() }
        guard !line.isEmpty else { return nil }
        let decoded: (String, EngineEvent)
        do {
            decoded = try EngineEventDecoder.decode(line: line)
        } catch let error as EngineError {
            throw error
        } catch {
            continuation.yield((line, .warning(code: "undecodable_event", message: "The engine sent a line that could not be decoded.")))
            return nil
        }
        continuation.yield(decoded)
        var result = EmitResult()
        if case .runFinished = decoded.1 { result.finished = true }
        return result
    }

    /// The only environment the engine is given. Tool paths are listed
    /// explicitly so `brew` and `xcrun` can be found without inheriting a
    /// user-controlled `PATH`.
    static func engineEnvironment() -> [String: String] {
        let user = NSUserName()
        let identifier = Locale.current.identifier
        let lang = identifier.contains(".") ? identifier : identifier + ".UTF-8"
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": lang,
            "LC_ALL": lang,
            "USER": user,
            "LOGNAME": user,
        ]
    }
}

/// A capped copy of the engine's stderr, filled from a readability callback.
private nonisolated final class StderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap = 8_192

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = cap - data.count
        guard room > 0 else { return }
        data.append(chunk.prefix(room))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
