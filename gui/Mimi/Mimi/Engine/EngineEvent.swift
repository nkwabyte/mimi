//
//  EngineEvent.swift
//  Mimi
//

import Foundation

// MARK: - Typed events (protocol §5.3)

nonisolated struct HelloEvent: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let engineVersion: String
    let planSchemaVersion: Int
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case engineVersion = "engine_version"
        case planSchemaVersion = "plan_schema_version"
        case capabilities
    }
}

nonisolated struct CandidateEvent: Decodable, Equatable, Sendable {
    let candidateId: String
    let category: String
    let path: String
    let bytes: Int64      // size_kb * 1024
    let risk: String

    enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case category, path
        case sizeKb = "size_kb"
        case risk
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decode(String.self, forKey: .category)
        path = try c.decode(String.self, forKey: .path)
        // A scan that is not building a plan omits candidate_id. The row still
        // needs a stable identity, and the path is the only other fact we have.
        let provided = try c.decodeIfPresent(String.self, forKey: .candidateId)
        candidateId = (provided?.isEmpty == false) ? provided! : "\(category)|\(path)"
        let kb = try c.decode(Int64.self, forKey: .sizeKb)
        let (scaled, overflow) = kb.multipliedReportingOverflow(by: 1_024)
        guard !overflow else {
            throw DecodingError.dataCorruptedError(
                forKey: .sizeKb,
                in: c,
                debugDescription: "size_kb overflows when converted to bytes"
            )
        }
        bytes = scaled
        risk = try c.decode(String.self, forKey: .risk)
    }
}

nonisolated struct PermissionRequiredEvent: Decodable, Equatable, Sendable {
    let permission: String
    let message: String
}

nonisolated struct RunFinishedEvent: Decodable, Equatable, Sendable {
    let status: String
    let exitCode: Int
    let reclaimedKb: Int64
    let scannedKb: Int64
    let actionsOk: Int
    let actionsFailed: Int

    enum CodingKeys: String, CodingKey {
        case status
        case exitCode = "exit_code"
        case reclaimedKb = "reclaimed_kb"
        case scannedKb = "scanned_kb"
        case actionsOk = "actions_ok"
        case actionsFailed = "actions_failed"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        exitCode = try c.decode(Int.self, forKey: .exitCode)
        reclaimedKb = try c.decodeIfPresent(Int64.self, forKey: .reclaimedKb) ?? 0
        scannedKb = try c.decodeIfPresent(Int64.self, forKey: .scannedKb) ?? 0
        actionsOk = try c.decodeIfPresent(Int.self, forKey: .actionsOk) ?? 0
        actionsFailed = try c.decodeIfPresent(Int.self, forKey: .actionsFailed) ?? 0
    }
}

// MARK: - Discriminated union

nonisolated enum EngineEvent: Equatable, Sendable {
    case hello(HelloEvent)
    case phaseStarted(phase: String)
    case phaseFinished(phase: String, status: String)
    case candidate(CandidateEvent)
    case permissionRequired(PermissionRequiredEvent)
    case runFinished(RunFinishedEvent)
    case warning(code: String, message: String)
    case unknown(type: String)
}
