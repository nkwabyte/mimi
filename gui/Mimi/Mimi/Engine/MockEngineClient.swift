//
//  MockEngineClient.swift
//  Mimi
//

import Foundation

/// A mock engine client that replays fixture JSONL lines.
/// Used in previews and unit tests.
nonisolated struct MockEngineClient: EngineClientProtocol, Sendable {
    let lines: [String]
    let delay: Duration

    var engineLocation: String { "Preview data" }

    init(lines: [String] = MockEngineClient.builtIn, delay: Duration = .zero) {
        self.lines = lines
        self.delay = delay
    }

    /// The built-in fixture lines (loaded from Resources/Fixtures/scan-safe.jsonl).
    static let builtIn: [String] = {
        let bundleCandidates = [
            Bundle.main,
            Bundle(for: _BundleFinder.self)
        ]
        for bundle in bundleCandidates {
            if let url = bundle.url(forResource: "scan-safe", withExtension: "jsonl") ??
                         bundle.url(forResource: "scan-safe", withExtension: "jsonl", subdirectory: "Fixtures") {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    return content.components(separatedBy: "\n").filter { !$0.isEmpty }
                }
            }
        }

        #if DEBUG
        // Development builds only: read the fixture next to this source file.
        // #filePath is the build machine's path, so release builds skip this.
        let repoFixturePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/scan-safe.jsonl")
        if let content = try? String(contentsOf: repoFixturePath, encoding: .utf8) {
            return content.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        #endif

        // Embedded fallback literal in case bundle lookup fails during headless tests
        return [
            #"{"type":"hello","seq":1,"request_id":"mimi-test","timestamp":"2026-09-27T00:00:00Z","protocol_version":1,"engine_version":"0.2.1","plan_schema_version":1,"capabilities":["scan","clean"]}"#,
            #"{"type":"phase_started","phase":"scan"}"#,
            #"{"type":"candidate","candidate_id":"cand-1","category":"caches","path":"/Users/test/Library/Caches/com.example.app","size_kb":812000,"risk":"safe"}"#,
            #"{"type":"candidate","candidate_id":"cand-2","category":"logs","path":"/Users/test/Library/Logs/com.example.app","size_kb":500,"risk":"safe"}"#,
            #"{"type":"permission_required","permission":"fda","message":"Full Disk Access recommended"}"#,
            #"{"type":"phase_finished","phase":"scan","status":"ok"}"#,
            #"{"type":"run_finished","status":"ok","exit_code":0,"reclaimed_kb":0,"scanned_kb":812500}"#
        ]
    }()

    func events(for command: EngineCommand) -> AsyncThrowingStream<(String, EngineEvent), Error> {
        AsyncThrowingStream { continuation in
            Task {
                for line in lines {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    do {
                        continuation.yield(try EngineEventDecoder.decode(line: line))
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
        }
    }

    func cancel() {}
}

private class _BundleFinder {}
