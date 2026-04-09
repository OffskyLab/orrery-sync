import ArgumentParser
import Foundation

@main
struct OrbitalSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orbital-sync",
        abstract: "P2P real-time sync daemon for Orbital",
        version: "0.1.0",
        subcommands: [
            DaemonCommand.self,
            PairCommand.self,
            StatusCommand.self,
            TeamCommand.self,
        ]
    )

    @Option(name: .long, help: "Path to control socket")
    var socket: String?
}

/// Resolve socket path from parent options or default.
func resolveSocketPath(from socket: String?) -> String {
    if let socket { return socket }
    if let home = ProcessInfo.processInfo.environment["ORBITAL_HOME"] {
        return home + "/sync.sock"
    }
    return FileManager.default.homeDirectoryForCurrentUser.path + "/.orbital/sync.sock"
}
