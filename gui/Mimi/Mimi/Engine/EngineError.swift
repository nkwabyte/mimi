//
//  EngineError.swift
//  Mimi
//

import Foundation

nonisolated enum EngineError: Error, Equatable, Sendable {
    case eventTooLarge
    case unsupportedProtocol(Int)
    case engineNotFound(String)
    case processFailed(exitCode: Int32, message: String)
    case decodingFailed(String)
}

extension EngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .eventTooLarge:
            return "The engine sent a line larger than 64 KB. The scan was stopped."
        case .unsupportedProtocol(let version):
            return "This app speaks protocol version 1. The engine offered version \(version)."
        case .engineNotFound(let path):
            return "The mimi engine is not executable at \(path). Run it from the repository checkout, or install the command-line tool."
        case .processFailed(let exitCode, let message):
            if message.isEmpty {
                return "The engine stopped with exit code \(exitCode)."
            }
            return "The engine stopped with exit code \(exitCode). \(message)"
        case .decodingFailed(let detail):
            return "The engine sent an event this app could not read. \(detail)"
        }
    }
}
