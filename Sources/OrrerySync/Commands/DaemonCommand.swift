import ArgumentParser
import Foundation

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Start the sync daemon"
    )

    @OptionGroup var globals: OrrerySyncCommand

    @Option(name: .shortAndLong, help: "Port for NMT server")
    var port: Int = 9527

    @Option(name: .shortAndLong, help: "Path to sync directory")
    var syncDir: String?

    @Option(name: .long, help: "Path to CA certificate (PEM) for mTLS")
    var tlsCA: String?

    @Option(name: .long, help: "Path to node certificate (PEM) for mTLS")
    var tlsCert: String?

    @Option(name: .long, help: "Path to node private key (PEM) for mTLS")
    var tlsKey: String?

    @Option(name: .long, help: "Rendezvous server address (host:port)")
    var rendezvous: String?

    func run() async throws {
        let dir = syncDir ?? defaultSyncDirectory()
        let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let socketPath = resolveSocketPath(from: globals.socket)

        // Build TLS context if all three paths provided
        var tls: SyncTLSContext?
        if let ca = tlsCA, let cert = tlsCert, let key = tlsKey {
            tls = try SyncTLSContext(
                ca: .file(path: ca),
                identity: .files(cert: cert, key: key)
            )
            print("mTLS enabled")
        }

        print("Starting orrery-sync daemon on port \(port)")
        print("Sync directory: \(resolvedDir)")
        print("Control socket: \(socketPath)")

        let daemon = SyncDaemon(
            port: port,
            syncDirectory: dir,
            socketPath: socketPath,
            tls: tls,
            rendezvousAddress: rendezvous
        )
        try await daemon.start()
    }

    private func defaultSyncDirectory() -> String {
        if let custom = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            return custom + "/shared"
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.orrery/shared"
    }
}
