import ArgumentParser

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon and peer status"
    )

    @OptionGroup var globals: OrrerySyncCommand

    func run() async throws {
        let socketPath = resolveSocketPath(from: globals.socket)
        let client = ControlClient(socketPath: socketPath)
        do {
            let response = try client.send(ControlRequest(command: "status", args: nil))
            if response.ok {
                print(response.message)
                if let peers = response.data?["peers"], !peers.isEmpty {
                    print("Peers: \(peers)")
                }
            } else {
                print("Error: \(response.message)")
            }
        } catch SyncError.daemonNotRunning {
            print("Daemon is not running. Start it with: orrery-sync daemon")
        }
    }
}
