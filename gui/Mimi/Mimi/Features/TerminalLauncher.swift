//
//  TerminalLauncher.swift
//  Mimi
//
//  Opens a mimi command in Terminal. The command runs in a real terminal, so
//  every typed confirmation the engine asks for still reaches a person; the
//  app never answers them.
//

import AppKit
import Foundation

enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case noEngine
        case writeFailed(String)
        case openFailed

        var errorDescription: String? {
            switch self {
            case .noEngine:
                "The mimi engine was not found, so there is nothing to run in Terminal."
            case .writeFailed(let detail):
                "Could not prepare the Terminal command. \(detail)"
            case .openFailed:
                "Terminal did not open the command."
            }
        }
    }

    /// Writes a one-off `.command` file that runs the engine with these
    /// arguments and opens it, which starts it in Terminal. No Apple Events,
    /// so no automation permission is needed.
    static func run(engine: URL?, arguments: [String]) throws {
        guard let engine else { throw LaunchError.noEngine }
        let line = ([engine.path] + arguments).map(shellQuoted).joined(separator: " ")
        let script = """
        #!/bin/zsh
        clear
        \(line)
        echo
        echo "mimi finished. You can close this window."
        rm -f -- "$0"
        exec /bin/zsh -l
        """
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-terminal", isDirectory: true)
        let file = folder.appendingPathComponent("mimi-\(UUID().uuidString).command")
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            throw LaunchError.writeFailed(error.localizedDescription)
        }
        guard NSWorkspace.shared.open(file) else { throw LaunchError.openFailed }
    }

    /// The command as a person would type it, for display and copying.
    static func displayCommand(_ arguments: [String]) -> String {
        (["mimi"] + arguments).map { $0.contains(" ") ? shellQuoted($0) : $0 }.joined(separator: " ")
    }

    static func copy(_ arguments: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayCommand(arguments), forType: .string)
    }

    /// Single-quoted for zsh: nothing inside is interpreted.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
