//
//  EngineCommand.swift
//  Mimi
//

import Foundation

/// A typed request sent to the CLI engine.
///
/// The app builds an argument array and never a shell string. Only flags the
/// CLI accepts are included. Candidate-id filtering and `doctor` are not
/// commands today, so they are not represented here.
nonisolated enum EngineCommand: Sendable, Equatable {
    case scan(profile: String)
    case plan(profile: String)
    case apply(planFile: URL)
    case restore(runID: String)
    case history

    /// Arguments placed after the `mimi` executable.
    var arguments: [String] {
        var args = ["--jsonl", "--no-prompt", "--no-color"]
        switch self {
        case .scan(let profile):
            args += ["scan", "--profile", profile]
        case .plan(let profile):
            args += ["plan", "--profile", profile]
        case .apply(let file):
            args += ["apply", file.path]
        case .restore(let runID):
            args += ["restore", runID]
        case .history:
            args += ["history"]
        }
        return args
    }
}
