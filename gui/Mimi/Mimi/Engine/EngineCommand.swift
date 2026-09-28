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
    /// `mimi history --json`: one mimi.history/2 document.
    case history(limit: Int)
    /// `mimi history clear`: the app asks first, so `--yes` is passed.
    case historyClear(all: Bool, recordIDs: [String], logNames: [String])
    /// `mimi purge <run>`: irreversible. The app shows its own destructive
    /// confirmation first, which stands in for the typed word.
    case purge(runID: String)

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
        case .history(let limit):
            args += ["history", "--limit", String(max(1, limit))]
        case .historyClear(let all, let recordIDs, let logNames):
            args += ["--yes", "history", "clear"]
            if all {
                args.append("--all")
            } else {
                if !recordIDs.isEmpty { args += ["--records", recordIDs.joined(separator: ",")] }
                if !logNames.isEmpty { args += ["--logs", logNames.joined(separator: ",")] }
            }
        case .purge(let runID):
            args += ["--force-risky", "purge", "purge", runID]
        }
        return args
    }
}

/// Everything one engine command printed, for the commands that answer with a
/// single JSON document instead of an event stream.
nonisolated struct EngineOutput: Sendable, Equatable {
    let stdout: Data
    let exitCode: Int32
    let stderr: String

    init(stdout: Data, exitCode: Int32 = 0, stderr: String = "") {
        self.stdout = stdout
        self.exitCode = exitCode
        self.stderr = stderr
    }
}
