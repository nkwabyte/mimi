//
//  AppModel.swift
//  Mimi
//

import Foundation
import Observation

struct Candidate: Identifiable, Equatable, Sendable {
    let id: String
    let category: String
    let path: String
    let bytes: Int64
    let risk: String
    var isSelected: Bool = true
}

enum ScanProfile: String, CaseIterable, Identifiable, Sendable {
    case safe
    case developer
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: "Safe"
        case .developer: "Developer"
        case .aggressive: "Aggressive"
        }
    }

    var detail: String {
        switch self {
        case .safe:
            "Regenerable caches. This scan does not delete anything."
        case .developer:
            "Safe categories, plus Xcode DerivedData and simulator caches. Nothing is deleted."
        case .aggressive:
            "Broad caches, logs, and local snapshots. This window still only scans."
        }
    }
}

enum AppState: Equatable, Sendable {
    case idle
    case running
    case finished(RunFinishedEvent)
    case failed(String)
    case cancelled
}

@MainActor
@Observable
final class AppModel {
    private(set) var candidates: [Candidate] = []
    private(set) var state: AppState = .idle
    private(set) var engineVersion: String = ""
    private(set) var capabilities: [String] = []
    private(set) var phase: String = ""
    private(set) var permissionNotices: [String] = []
    private(set) var warnings: [String] = []
    var profile: ScanProfile = .safe

    var isRunning: Bool { state == .running }

    var engineLocation: String { engine.engineLocation }

    var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }

    private let engine: any EngineClientProtocol
    private var streamTask: Task<Void, Never>?

    init(engine: any EngineClientProtocol = ProcessEngineClient()) {
        self.engine = engine
    }

    func scan() {
        guard !isRunning else { return }
        candidates = []
        permissionNotices = []
        warnings = []
        capabilities = []
        engineVersion = ""
        phase = ""
        state = .running

        let profile = self.profile
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await (_, event) in engine.events(for: .scan(profile: profile.rawValue)) {
                    if Task.isCancelled { return }
                    self.handle(event)
                }
                if case .running = self.state {
                    self.state = .failed("The engine stopped before it reported a result.")
                }
            } catch is CancellationError {
                return
            } catch {
                if case .cancelled = self.state { return }
                if case .finished = self.state { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        engine.cancel()
        state = .cancelled
    }

    private func handle(_ event: EngineEvent) {
        if case .cancelled = state { return }
        switch event {
        case .hello(let hello):
            engineVersion = hello.engineVersion
            capabilities = hello.capabilities
        case .phaseStarted(let phase):
            self.phase = phase
        case .phaseFinished:
            break
        case .candidate(let candidate):
            var identifier = candidate.candidateId
            if candidates.contains(where: { $0.id == identifier }) {
                identifier = "\(identifier)#\(candidates.count)"
            }
            candidates.append(Candidate(
                id: identifier,
                category: candidate.category,
                path: candidate.path,
                bytes: candidate.bytes,
                risk: candidate.risk
            ))
        case .permissionRequired(let notice):
            permissionNotices.append(notice.message)
        case .warning(let code, let message):
            warnings.append(code.isEmpty ? message : "\(code): \(message)")
        case .runFinished(let summary):
            state = .finished(summary)
        case .unknown:
            break
        }
    }
}
