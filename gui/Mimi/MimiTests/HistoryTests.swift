//
//  HistoryTests.swift
//  MimiTests
//

import Foundation
import Testing
@testable import Mimi

struct HistoryDocumentTests {
    private func sample() throws -> HistoryDocument {
        try JSONDecoder().decode(HistoryDocument.self, from: Data(MockEngineClient.sampleHistory.utf8))
    }

    @Test func decodesEveryKindOfRow() throws {
        let document = try sample()
        #expect(document.schema == HistoryDocument.supportedSchema)
        let items = HistoryRows.items(from: document)
        #expect(items.count == 9)
        #expect(items.filter { $0.section == .activity }.count == 5)
        #expect(items.filter { $0.section == .quarantine }.count == 1)
        #expect(items.filter { $0.section == .logs }.count == 3)
    }

    @Test func activityIsNewestFirstAndKeepsTheEngineID() throws {
        let items = HistoryRows.items(from: try sample())
        #expect(items[0].kind == .restore)
        #expect(items[0].engineKey == "r5@2026-09-27T11:00:00Z")
        #expect(items[0].id == "record:r5@2026-09-27T11:00:00Z")
        #expect(items[0].date != nil)
    }

    @Test func cleanRecordsShowWhatWasFreed() throws {
        let clean = HistoryRows.items(from: try sample()).first { $0.kind == .clean }
        #expect(clean?.bytes == Int64(1_843_200) * 1_024)
        #expect(clean?.subtitle.contains("214 items removed") == true)
        #expect(clean?.status == "ok")
    }

    @Test func orphanReviewFilesAreTheirOwnKind() throws {
        let logs = HistoryRows.items(from: try sample()).filter { $0.section == .logs }
        #expect(logs.contains { $0.kind == .orphanReview && $0.engineKey == "orphans-review-20260925.txt" })
        #expect(logs.first?.engineKey == "clean-20260927-103000.log")
    }

    @Test func numbersWrittenAsTextAndMissingFieldsAreTolerated() throws {
        let line = #"{"id":"r1@x","at":"2026-09-27T10:00:00Z","type":"something-new","status":"ok","removed":"12","app":42}"#
        let record = try JSONDecoder().decode(HistoryRecord.self, from: Data(line.utf8))
        #expect(record.removed == 12)
        #expect(record.app == "42")
        #expect(HistoryKind(recordType: record.type) == .other)
    }
}

struct HistoryCommandTests {
    @Test func historyAsksForADocument() {
        #expect(Array(EngineCommand.history(limit: 500).arguments.suffix(3)) == ["history", "--limit", "500"])
    }

    @Test func clearAllPassesYesAndAll() {
        let args = EngineCommand.historyClear(all: true, recordIDs: ["ignored"], logNames: []).arguments
        #expect(Array(args.suffix(4)) == ["--yes", "history", "clear", "--all"])
        #expect(!args.contains("--records"))
    }

    @Test func selectiveClearNamesRecordsAndLogs() {
        let args = EngineCommand.historyClear(all: false, recordIDs: ["r1@a", "r2@b"], logNames: ["clean-1.log"]).arguments
        #expect(Array(args.suffix(4)) == ["--records", "r1@a,r2@b", "--logs", "clean-1.log"])
        #expect(args.contains("clear"))
        #expect(!args.contains("--all"))
    }

    @Test func purgeIsAuthorizedExplicitly() {
        let args = EngineCommand.purge(runID: "run-1").arguments
        #expect(Array(args.suffix(4)) == ["--force-risky", "purge", "purge", "run-1"])
    }
}

/// Records every command the mock engine was asked to run.
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [EngineCommand] = []

    func append(_ command: EngineCommand) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    var all: [EngineCommand] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

@MainActor
struct HistoryStoreTests {
    @Test func loadingFillsTheRows() async {
        let store = HistoryStore(engine: MockEngineClient())
        await store.load()
        #expect(store.state == .loaded)
        #expect(store.items.count == 9)
        #expect(store.items(in: .logs).count == 3)
    }

    @Test func deletingSendsRecordsAndLogsTogetherAndPurgesRuns() async {
        let log = CommandLog()
        let engine = MockEngineClient { command in
            log.append(command)
            return MockEngineClient.defaultResponse(command)
        }
        let store = HistoryStore(engine: engine)
        await store.load()
        store.selection = [
            "record:r2@2026-09-26T18:40:00Z",
            "log:clean-20260926-091200.log",
            "run:plan-20260927",
        ]
        await store.deleteSelected()
        let sent = log.all
        #expect(sent.contains(.historyClear(all: false, recordIDs: ["r2@2026-09-26T18:40:00Z"], logNames: ["clean-20260926-091200.log"])))
        #expect(sent.contains(.purge(runID: "plan-20260927")))
        #expect(store.selection.isEmpty)
        #expect(store.notice?.contains("Purged 1 quarantine run") == true)
    }

    @Test func clearAllNeverPurgesRuns() async {
        let log = CommandLog()
        let engine = MockEngineClient { command in
            log.append(command)
            return MockEngineClient.defaultResponse(command)
        }
        let store = HistoryStore(engine: engine)
        await store.load()
        await store.clearAll()
        #expect(log.all.contains(.historyClear(all: true, recordIDs: [], logNames: [])))
        #expect(!log.all.contains { if case .purge = $0 { return true } else { return false } })
    }

    @Test func anUnknownFormatIsReportedNotGuessed() async {
        let engine = MockEngineClient { _ in
            EngineOutput(stdout: Data(#"{"schema":"mimi.history/9","records":[],"quarantine_runs":[],"logs":[]}"#.utf8))
        }
        let store = HistoryStore(engine: engine)
        await store.load()
        guard case .failed(let message) = store.state else {
            Issue.record("state \(store.state)")
            return
        }
        #expect(message.contains("mimi.history/9"))
    }
}

@MainActor
struct TerminalLauncherTests {
    @Test func quotingKeepsArgumentsLiteral() {
        #expect(TerminalLauncher.shellQuoted("it's $HOME") == #"'it'\''s $HOME'"#)
        #expect(TerminalLauncher.displayCommand(["scan", "--only", "orphans"]) == "mimi scan --only orphans")
    }
}
