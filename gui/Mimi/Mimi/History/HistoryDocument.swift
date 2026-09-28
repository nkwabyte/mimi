//
//  HistoryDocument.swift
//  Mimi
//
//  Decodes `mimi history --json` (schemas/history-v2.json) and turns records,
//  quarantine runs, and log files into one list of rows.
//

import Foundation

nonisolated struct HistoryDocument: Decodable, Sendable {
    let schema: String
    let records: [HistoryRecord]
    let quarantineRuns: [QuarantineRunInfo]
    let logs: [LogFileInfo]

    enum CodingKeys: String, CodingKey {
        case schema, records, logs
        case quarantineRuns = "quarantine_runs"
    }

    static let supportedSchema = "mimi.history/2"
}

/// One line of history.jsonl. Records carry different keys per type, and a
/// value made only of digits is written as a number, so every field is read
/// leniently.
nonisolated struct HistoryRecord: Decodable, Sendable, Equatable {
    let id: String
    let at: String
    let type: String
    let status: String
    let app: String?
    let bundleID: String?
    let token: String?
    let planID: String?
    let runID: String?
    let log: String?
    let freedKb: Int64?
    let removed: Int?
    let failed: Int?

    enum CodingKeys: String, CodingKey {
        case id, at, type, status, app, token, log, removed, failed
        case bundleID = "bundle_id"
        case planID = "plan_id"
        case runID = "run_id"
        case freedKb = "freed_kb"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(String.self, forKey: .at)
        type = try c.decode(String.self, forKey: .type)
        status = Self.text(c, .status) ?? ""
        app = Self.text(c, .app)
        bundleID = Self.text(c, .bundleID)
        token = Self.text(c, .token)
        planID = Self.text(c, .planID)
        runID = Self.text(c, .runID)
        log = Self.text(c, .log)
        freedKb = Self.number(c, .freedKb)
        removed = Self.number(c, .removed).map { Int(clamping: $0) }
        failed = Self.number(c, .failed).map { Int(clamping: $0) }
    }

    private static func text(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key) { return s.isEmpty ? nil : s }
        if let n = try? c.decode(Int64.self, forKey: key) { return String(n) }
        return nil
    }

    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
        if let n = try? c.decode(Int64.self, forKey: key) { return n }
        if let s = try? c.decode(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}

nonisolated struct QuarantineRunInfo: Decodable, Sendable, Equatable {
    let runID: String
    let items: Int
    let restored: Int
    let sizeKb: Int64

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case items, restored
        case sizeKb = "size_kb"
    }
}

nonisolated struct LogFileInfo: Decodable, Sendable, Equatable {
    let name: String
    let sizeKb: Int64
    let modified: String

    enum CodingKeys: String, CodingKey {
        case name, modified
        case sizeKb = "size_kb"
    }
}

// MARK: - Rows

nonisolated enum HistoryKind: String, Sendable, CaseIterable {
    case clean, apply, restore, purge, expire
    case uninstall, caskUninstall, vendorUninstaller, systemRequest
    case quarantineRun, log, orphanReview, other

    init(recordType: String) {
        switch recordType {
        case "clean": self = .clean
        case "apply": self = .apply
        case "restore": self = .restore
        case "purge": self = .purge
        case "expire": self = .expire
        case "uninstall": self = .uninstall
        case "cask-uninstall": self = .caskUninstall
        case "vendor-uninstaller": self = .vendorUninstaller
        case "system-request": self = .systemRequest
        default: self = .other
        }
    }

    /// SF Symbol for the row's icon.
    var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .apply: "checklist"
        case .restore: "arrow.uturn.backward.circle"
        case .purge: "flame"
        case .expire: "hourglass"
        case .uninstall: "trash"
        case .caskUninstall: "shippingbox"
        case .vendorUninstaller: "wrench.and.screwdriver"
        case .systemRequest: "lock.shield"
        case .quarantineRun: "archivebox"
        case .log: "doc.text"
        case .orphanReview: "doc.text.magnifyingglass"
        case .other: "clock"
        }
    }

    var label: String {
        switch self {
        case .clean: "Clean"
        case .apply: "Plan applied"
        case .restore: "Restore"
        case .purge: "Purge"
        case .expire: "Quarantine released"
        case .uninstall: "Uninstall"
        case .caskUninstall: "Homebrew uninstall"
        case .vendorUninstaller: "Vendor uninstaller"
        case .systemRequest: "System request"
        case .quarantineRun: "Restorable run"
        case .log: "Run log"
        case .orphanReview: "Leftover review"
        case .other: "Activity"
        }
    }
}

/// Which list a row belongs to; also what deleting it does.
nonisolated enum HistorySection: String, Sendable, CaseIterable, Identifiable {
    case activity, quarantine, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .quarantine: "Restorable runs"
        case .logs: "Log files"
        }
    }
}

nonisolated struct HistoryItem: Identifiable, Sendable, Equatable {
    /// "record:<id>", "run:<run_id>" or "log:<name>"; unique across sections.
    let id: String
    let section: HistorySection
    let kind: HistoryKind
    let title: String
    let subtitle: String
    let date: Date?
    let bytes: Int64?
    let status: String?
    /// The id, run id, or file name the engine knows it by.
    let engineKey: String
}

nonisolated enum HistoryRows {
    static func items(from document: HistoryDocument) -> [HistoryItem] {
        let records = document.records.reversed().map(item(for:))
        let runs = document.quarantineRuns.map { run in
            HistoryItem(
                id: "run:\(run.runID)",
                section: .quarantine,
                kind: .quarantineRun,
                title: run.runID,
                subtitle: run.restored > 0
                    ? "\(run.items) item\(run.items == 1 ? "" : "s"), \(run.restored) restored"
                    : "\(run.items) item\(run.items == 1 ? "" : "s") in quarantine",
                date: nil,
                bytes: run.sizeKb * 1_024,
                status: nil,
                engineKey: run.runID
            )
        }
        let logs = document.logs
            .sorted { $0.modified > $1.modified }
            .map { log in
                HistoryItem(
                    id: "log:\(log.name)",
                    section: .logs,
                    kind: log.name.hasPrefix("orphans-review-") ? .orphanReview : .log,
                    title: log.name,
                    subtitle: log.name.hasPrefix("orphans-review-") ? "Leftover review file" : "Run transcript",
                    date: parseDate(log.modified),
                    bytes: log.sizeKb * 1_024,
                    status: nil,
                    engineKey: log.name
                )
            }
        return records + runs + logs
    }

    static func item(for record: HistoryRecord) -> HistoryItem {
        let kind = HistoryKind(recordType: record.type)
        let subject = record.app ?? record.bundleID ?? record.token ?? record.planID ?? record.runID
        let title = subject.map { "\(kind.label): \($0)" } ?? kind.label
        var details: [String] = []
        if let removed = record.removed {
            details.append("\(removed) item\(removed == 1 ? "" : "s") removed")
        }
        if let failed = record.failed, failed > 0 {
            details.append("\(failed) failed")
        }
        if let run = record.runID, record.app == nil, subject != run {
            details.append("run \(run)")
        }
        if details.isEmpty, let bundle = record.bundleID, subject != bundle {
            details.append(bundle)
        }
        return HistoryItem(
            id: "record:\(record.id)",
            section: .activity,
            kind: kind,
            title: title,
            subtitle: details.joined(separator: " · "),
            date: parseDate(record.at),
            bytes: record.freedKb.map { $0 * 1_024 },
            status: record.status,
            engineKey: record.id
        )
    }

    static func parseDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
