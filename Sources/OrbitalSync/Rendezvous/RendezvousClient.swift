import Foundation
import NMTP
import NIO
import Logging

// TODO: migrate to NMTPeer/PeerDispatcher — implementation pending Task 2

/// Client for registering with and querying a rendezvous server.
actor RendezvousClient {
    let serverHost: String
    let serverPort: Int

    private var client: NMTClient?
    private var heartbeatTask: Task<Void, Never>?

    init(host: String, port: Int) {
        self.serverHost = host
        self.serverPort = port
    }

    func register(peerID: String, peerName: String, teamID: String, host: String, port: Int) async throws -> [RVPeerEntry] {
        // TODO: migrate
        return []
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        try? await client?.close()
        client = nil
    }
}
