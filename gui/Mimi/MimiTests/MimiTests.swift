//
//  MimiTests.swift
//  MimiTests
//

import Foundation
import Testing
@testable import Mimi

struct EngineCommandTests {
    @Test func scanArgumentsMatchTheCLI() {
        #expect(EngineCommand.scan(profile: "safe").arguments == [
            "--jsonl", "--no-prompt", "--no-color", "scan", "--profile", "safe",
        ])
    }

    @Test func planDoesNotSendACandidateFlag() {
        let args = EngineCommand.plan(profile: "developer").arguments
        #expect(args == [
            "--jsonl", "--no-prompt", "--no-color", "plan", "--profile", "developer",
        ])
        #expect(!args.contains("--candidate"))
        #expect(!args.contains("doctor"))
    }

    @Test func applyAndRestoreUseRealSubcommands() {
        let plan = URL(fileURLWithPath: "/tmp/plan.json")
        #expect(EngineCommand.apply(planFile: plan).arguments.last == "/tmp/plan.json")
        #expect(Array(EngineCommand.restore(runID: "run-1").arguments.suffix(2)) == ["restore", "run-1"])
    }
}
