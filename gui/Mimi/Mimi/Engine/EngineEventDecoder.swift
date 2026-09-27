//
//  EngineEventDecoder.swift
//  Mimi
//

import Foundation

nonisolated enum EngineEventDecoder {
    /// Maximum line size accepted (64 KiB). Protects against runaway output.
    static let maxLineBytes = 65_536

    /// Decode one JSONL line into a (raw JSON string, typed event) pair.
    static func decode(line: String) throws -> (String, EngineEvent) {
        guard line.utf8.count <= maxLineBytes else {
            throw EngineError.eventTooLarge
        }
        let data = Data(line.utf8)
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)

        let event: EngineEvent
        switch envelope.type {
        case "hello":
            let e = try JSONDecoder().decode(HelloEvent.self, from: data)
            event = .hello(e)
        case "phase_started":
            let e = try JSONDecoder().decode(PhaseEnvelope.self, from: data)
            event = .phaseStarted(phase: e.phase)
        case "phase_finished":
            let e = try JSONDecoder().decode(PhaseFinishedEnvelope.self, from: data)
            event = .phaseFinished(phase: e.phase, status: e.status)
        case "candidate":
            let e = try JSONDecoder().decode(CandidateEvent.self, from: data)
            event = .candidate(e)
        case "permission_required":
            let e = try JSONDecoder().decode(PermissionRequiredEvent.self, from: data)
            event = .permissionRequired(e)
        case "run_finished":
            let e = try JSONDecoder().decode(RunFinishedEvent.self, from: data)
            event = .runFinished(e)
        case "warning":
            let e = try JSONDecoder().decode(WarningEnvelope.self, from: data)
            let message = e.message ?? e.code ?? "Warning"
            event = .warning(code: e.code ?? "", message: message)
        default:
            event = .unknown(type: envelope.type)
        }

        // Protocol version guard
        if case .hello(let h) = event, h.protocolVersion != 1 {
            throw EngineError.unsupportedProtocol(h.protocolVersion)
        }
        return (line, event)
    }

    // MARK: - Private envelopes
    private struct EventEnvelope: Decodable { let type: String }
    private struct PhaseEnvelope: Decodable { let phase: String }
    private struct PhaseFinishedEnvelope: Decodable { let phase: String; let status: String }
    private struct WarningEnvelope: Decodable {
        let code: String?
        let message: String?
    }
}
