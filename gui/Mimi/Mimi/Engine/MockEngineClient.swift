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

    /// What `output(for:)` answers; the built-in history document by default.
    let respond: @Sendable (EngineCommand) -> EngineOutput

    var engineLocation: String { "Preview data" }
    var executableURL: URL? { nil }

    init(
        lines: [String] = MockEngineClient.builtIn,
        delay: Duration = .zero,
        respond: @escaping @Sendable (EngineCommand) -> EngineOutput = MockEngineClient.defaultResponse
    ) {
        self.lines = lines
        self.delay = delay
        self.respond = respond
    }

    func output(for command: EngineCommand) async throws -> EngineOutput {
        respond(command)
    }

    @Sendable static func defaultResponse(_ command: EngineCommand) -> EngineOutput {
        switch command {
        case .history:
            EngineOutput(stdout: Data(sampleHistory.utf8))
        case .historyClear:
            EngineOutput(stdout: Data(#"{"schema":"mimi.history-clear/1","records_removed":0,"logs_removed":0,"not_found":0}"#.utf8))
        default:
            EngineOutput(stdout: Data())
        }
    }

    /// A mimi.history/2 document with one of each kind of row, for previews
    /// and tests.
    static let sampleHistory = """
    {
      "schema": "mimi.history/2",
      "records": [
        {"id":"r1@2026-09-26T09:12:00Z","v":1,"at":"2026-09-26T09:12:00Z","type":"clean","status":"ok","freed_kb":1843200,"removed":214,"skipped":3,"failed":0,"log":"clean-20260926-091200.log"},
        {"id":"r2@2026-09-26T18:40:00Z","v":1,"at":"2026-09-26T18:40:00Z","type":"uninstall","status":"ok","app":"Zoom","bundle_id":"us.zoom.xos","plan_id":"uninstall-1","removed":7,"failed":0,"leftovers":0},
        {"id":"r3@2026-09-27T08:05:00Z","v":1,"at":"2026-09-27T08:05:00Z","type":"cask-uninstall","status":"ok","app":"Figma","token":"figma","zap":1},
        {"id":"r4@2026-09-27T10:30:00Z","v":1,"at":"2026-09-27T10:30:00Z","type":"apply","status":"partial","plan_id":"plan-20260927","freed_kb":51200,"removed":40,"failed":2,"run_id":"plan-20260927","log":"clean-20260927-103000.log"},
        {"id":"r5@2026-09-27T11:00:00Z","v":1,"at":"2026-09-27T11:00:00Z","type":"restore","status":"ok","run_id":"orphans-20260920-120000"}
      ],
      "quarantine_runs": [
        {"run_id": "plan-20260927", "items": 40, "restored": 0, "size_kb": 51200}
      ],
      "logs": [
        {"name": "clean-20260926-091200.log", "size_kb": 12, "modified": "2026-09-26T09:14:00Z"},
        {"name": "clean-20260927-103000.log", "size_kb": 8, "modified": "2026-09-27T10:31:00Z"},
        {"name": "orphans-review-20260925.txt", "size_kb": 4, "modified": "2026-09-25T16:00:00Z"}
      ]
    }
    """

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
