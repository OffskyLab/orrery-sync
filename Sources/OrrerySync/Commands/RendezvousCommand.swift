import ArgumentParser

struct RendezvousCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rendezvous",
        abstract: "Run a rendezvous server for cross-network peer discovery"
    )

    @OptionGroup var globals: OrrerySyncCommand

    @Option(name: .shortAndLong, help: "Port for rendezvous server")
    var port: Int = 9600

    func run() async throws {
        print("Starting rendezvous server on port \(port)")
        let server = RendezvousServer(port: port)
        try await server.start()
    }
}
