//
//  EngineEventTests.swift
//  MimiTests
//

import Foundation
import Testing
@testable import Mimi

struct EngineEventTests {
    @Test func decodesEveryEventTypeTheEngineEmits() throws {
        let kinds = try MockEngineClient.builtIn.map { try EngineEventDecoder.decode(line: $0).1 }
        #expect(kinds.count == 7)
        guard case .hello(let hello) = kinds[0] else { Issue.record("first event is not hello"); return }
        #expect(hello.protocolVersion == 1)
        guard case .candidate(let c) = kinds[2] else { Issue.record("no candidate"); return }
        #expect(c.candidateId == "cand-1")
        #expect(c.bytes == 812_000 * 1024)
        guard case .runFinished(let summary) = kinds.last else { Issue.record("no run_finished"); return }
        #expect(summary.exitCode == 0)
    }

    @Test func unknownEventTypesAreKeptButNeverInterpreted() throws {
        let line = #"{"type":"something_new","seq":9,"request_id":"r","timestamp":"t"}"#
        let (_, event) = try EngineEventDecoder.decode(line: line)
        #expect(event == .unknown(type: "something_new"))
    }

    @Test func aMalformedEventThrows() {
        #expect(throws: (any Error).self) {
            try EngineEventDecoder.decode(line: #"{"type":"candidate","seq":1}"#)
        }
    }

    @Test func oversizedLinesAreRefused() {
        let huge = String(repeating: "x", count: EngineEventDecoder.maxLineBytes + 1)
        #expect(throws: EngineError.eventTooLarge) { try EngineEventDecoder.decode(line: huge) }
    }

    @Test func aNewerProtocolVersionStopsTheRun() async {
        let newer = MockEngineClient.builtIn[0].replacingOccurrences(of: #""protocol_version":1"#, with: #""protocol_version":2"#)
        let engine = MockEngineClient(lines: [newer], delay: .zero)
        await #expect(throws: EngineError.unsupportedProtocol(2)) {
            for try await _ in engine.events(for: .scan(profile: "safe")) {}
        }
    }

    @Test func aCandidateWithoutAnIdUsesItsPath() throws {
        let line = #"{"type":"candidate","category":"tmp","path":"/tmp/example","size_kb":2,"risk":"safe"}"#
        guard case .candidate(let candidate) = try EngineEventDecoder.decode(line: line).1 else {
            Issue.record("not a candidate")
            return
        }
        #expect(candidate.candidateId == "tmp|/tmp/example")
        #expect(candidate.bytes == 2_048)
    }

    @Test func warningsCarryTheEngineCode() throws {
        let line = #"{"type":"warning","code":"fda","message":"Full Disk Access is off"}"#
        guard case .warning(let code, let message) = try EngineEventDecoder.decode(line: line).1 else {
            Issue.record("not a warning")
            return
        }
        #expect(code == "fda")
        #expect(message == "Full Disk Access is off")
    }

    @Test func realEngineOutputDecodes() throws {
        // Recorded from `mimi scan --only dsstore --jsonl` (engine 0.2.1).
        let recorded = [
            #"{"type":"hello","seq":1,"request_id":"mimi-20260927-001556","timestamp":"2026-09-27T00:15:56Z","protocol_version":1,"engine_version":"0.2.1","plan_schema_version":1,"capabilities":["scan","clean","report","profile","config"]}"#,
            #"{"type":"run_finished","seq":4,"request_id":"mimi-20260927-001556","timestamp":"2026-09-27T00:17:02Z","status":"ok","exit_code":0,"reclaimed_kb":0,"scanned_kb":1296,"actions_ok":0,"actions_skipped":0,"actions_denied":0,"actions_failed":0}"#,
        ]
        for line in recorded { _ = try EngineEventDecoder.decode(line: line) }
    }
}

@MainActor
struct AppModelTests {
    @Test func aScanCollectsCandidatesAndFinishes() async throws {
        let model = AppModel(engine: MockEngineClient(lines: MockEngineClient.builtIn, delay: .zero))
        model.scan()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.candidates.count == 2)
        #expect(model.engineVersion == "0.2.1")
        #expect(model.permissionNotices.count == 1)
        guard case .finished(let summary) = model.state else { Issue.record("state \(model.state)"); return }
        #expect(summary.status == "ok")
    }

    @Test func cancellingStopsTheRun() async throws {
        let model = AppModel(engine: MockEngineClient(lines: MockEngineClient.builtIn, delay: .seconds(5)))
        model.scan()
        model.cancel()
        #expect(model.state == .cancelled)
    }
}
