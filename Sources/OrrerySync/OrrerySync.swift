import ArgumentParser
import Foundation

@main
struct OrrerySyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orrery-sync",
        abstract: "P2P real-time sync daemon for Orrery",
        version: "1.0.0",
        subcommands: [
            DaemonCommand.self,
            PairCommand.self,
            StatusCommand.self,
            TeamCommand.self,
            RendezvousCommand.self,
        ]
    )

    @Option(name: .long, help: "Path to control socket")
    var socket: String?
}

/// Resolve socket path from parent options or default.
func resolveSocketPath(from socket: String?) -> String {
    if let socket { return socket }
    if let home = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
        return home + "/sync.sock"
    }
    return FileManager.default.homeDirectoryForCurrentUser.path + "/.orrery/sync.sock"
}
