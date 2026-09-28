//
//  EngineClientProtocol.swift
//  Mimi
//

import Foundation

/// Anything that can stream engine events. Lets us swap MockEngineClient for
/// the real ProcessEngineClient without changing AppModel.
///
/// `nonisolated` opts this protocol out of the module's default MainActor
/// isolation so a scan can read the engine without blocking the window.
nonisolated protocol EngineClientProtocol: Sendable {
    /// Path or label shown in the interface. Never used to build a shell command.
    var engineLocation: String { get }
    /// The engine executable, when there is a real one (nil for preview data).
    var executableURL: URL? { get }
    func events(for command: EngineCommand) -> AsyncThrowingStream<(String, EngineEvent), Error>
    /// Runs a command to completion and returns what it printed. For commands
    /// that answer with one JSON document (history, history clear, purge).
    func output(for command: EngineCommand) async throws -> EngineOutput
    func cancel()
}
