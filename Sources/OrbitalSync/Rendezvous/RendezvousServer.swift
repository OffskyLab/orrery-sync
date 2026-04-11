import Foundation
import NMTP
import NIO
import Logging

// TODO: migrate to NMTPeer/PeerDispatcher — implementation pending Task 2

/// Lightweight coordination server for cross-network peer discovery.
actor RendezvousServer {
    let port: Int
    let logger = Logger(label: "orbital-sync.rendezvous")

    private var server: NMTServer?

    init(port: Int) {
        self.port = port
    }

    func start() async throws {
        // TODO: migrate
        fatalError("RendezvousServer.start() — pending Task 2 migration")
    }

    func stop() async throws {
        try await server?.stop()
    }
}
