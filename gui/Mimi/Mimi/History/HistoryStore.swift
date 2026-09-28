//
//  HistoryStore.swift
//  Mimi
//

import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var items: [HistoryItem] = []
    private(set) var state: LoadState = .idle
    private(set) var isWorking = false
    /// A short result line after a delete or clear, shown until the next action.
    private(set) var notice: String?
    var selection: Set<HistoryItem.ID> = []

    /// How many records to ask the engine for.
    static let recordLimit = 500

    private let engine: any EngineClientProtocol

    init(engine: any EngineClientProtocol) {
        self.engine = engine
    }

    var selectedItems: [HistoryItem] {
        items.filter { selection.contains($0.id) }
    }

    func items(in section: HistorySection) -> [HistoryItem] {
        items.filter { $0.section == section }
    }

    func load() async {
        state = .loading
        do {
            let output = try await engine.output(for: .history(limit: Self.recordLimit))
            guard output.exitCode == 0 else {
                throw EngineError.processFailed(exitCode: output.exitCode, message: output.stderr)
            }
            let document = try JSONDecoder().decode(HistoryDocument.self, from: output.stdout)
            guard document.schema == HistoryDocument.supportedSchema else {
                throw EngineError.decodingFailed("History format \(document.schema) is not supported; update the app or the engine.")
            }
            items = HistoryRows.items(from: document)
            selection = selection.intersection(Set(items.map(\.id)))
            state = .loaded
        } catch let error as DecodingError {
            state = .failed("The engine's history could not be read. \(error.localizedDescription)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Deletes the selected rows: records and log files through
    /// `history clear`, quarantine runs through `purge`.
    func deleteSelected() async {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let records = chosen.filter { $0.section == .activity }.map(\.engineKey)
        let logs = chosen.filter { $0.section == .logs }.map(\.engineKey)
        let runs = chosen.filter { $0.section == .quarantine }.map(\.engineKey)
        await perform {
            var parts: [String] = []
            if !records.isEmpty || !logs.isEmpty {
                parts.append(try await self.clear(all: false, records: records, logs: logs))
            }
            var purged = 0
            for run in runs {
                let output = try await self.engine.output(for: .purge(runID: run))
                guard output.exitCode == 0 else {
                    throw EngineError.processFailed(exitCode: output.exitCode, message: output.stderr)
                }
                purged += 1
            }
            if purged > 0 { parts.append("Purged \(purged) quarantine run\(purged == 1 ? "" : "s").") }
            return parts.joined(separator: " ")
        }
    }

    /// Deletes every history record and log file. Quarantine runs are kept.
    func clearAll() async {
        await perform { try await self.clear(all: true, records: [], logs: []) }
    }

    private func clear(all: Bool, records: [String], logs: [String]) async throws -> String {
        let output = try await engine.output(for: .historyClear(all: all, recordIDs: records, logNames: logs))
        // 3 means some ids were already gone; the rest was still removed.
        guard output.exitCode == 0 || output.exitCode == 3 else {
            throw EngineError.processFailed(exitCode: output.exitCode, message: output.stderr)
        }
        let result = try JSONDecoder().decode(HistoryClearResult.self, from: output.stdout)
        var text = "Deleted \(result.recordsRemoved) record\(result.recordsRemoved == 1 ? "" : "s") and \(result.logsRemoved) log file\(result.logsRemoved == 1 ? "" : "s")."
        if result.notFound > 0 {
            text += " \(result.notFound) had already changed or gone."
        }
        return text
    }

    private func perform(_ work: @escaping () async throws -> String) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        do {
            notice = try await work()
            selection.removeAll()
        } catch {
            notice = error.localizedDescription
        }
        isWorking = false
        await load()
    }
}

nonisolated struct HistoryClearResult: Decodable, Sendable, Equatable {
    let recordsRemoved: Int
    let logsRemoved: Int
    let notFound: Int

    enum CodingKeys: String, CodingKey {
        case recordsRemoved = "records_removed"
        case logsRemoved = "logs_removed"
        case notFound = "not_found"
    }
}
