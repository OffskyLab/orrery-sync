import ArgumentParser

struct PairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair with a remote peer"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    @Argument(help: "Remote peer address (host:port)")
    var address: String

    func run() async throws {
        let parts = address.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            print("Invalid address format. Use host:port")
            throw ExitCode.failure
        }
        let host = String(parts[0])

        let socketPath = resolveSocketPath(from: globals.socket)
        let client = ControlClient(socketPath: socketPath)
        do {
            let response = try client.send(ControlRequest(
                command: "pair",
                args: ["host": host, "port": String(port)]
            ))
            if response.ok {
                print("Paired with \(address)")
            } else {
                print("Error: \(response.message)")
            }
        } catch SyncError.daemonNotRunning {
            print("Daemon is not running. Start it with: orbital-sync daemon")
        }
    }
}
