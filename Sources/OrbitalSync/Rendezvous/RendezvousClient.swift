import Foundation
import NMTP
import NMTPeer
import NIO
import Logging

/// Client for registering with and querying a rendezvous server.
actor RendezvousClient {
    let serverHost: String
    let serverPort: Int
    let logger = Logger(label: "orbital-sync.rv-client")

    private var dispatcher: PeerDispatcher?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var registeredPeerID: String?
    private var registeredTeamID: String?

    init(host: String, port: Int) {
        self.serverHost = host
        self.serverPort = port
    }

    /// Connect to the rendezvous server and register this peer.
    /// Returns list of other peers in the same team.
    func register(peerID: String, peerName: String, teamID: String, host: String, port: Int) async throws -> [RVPeerEntry] {
        // Clean up any previous registration before registering again
        if dispatcher != nil {
            await disconnect()
        }

        let address = try SocketAddress(ipAddress: serverHost, port: serverPort)
        let d = try await PeerDispatcher.connect(to: address)
        self.dispatcher = d
        self.registeredPeerID = peerID
        self.registeredTeamID = teamID

        // Start run() BEFORE issuing any request — ensures replies are routed
        runTask = Task { try? await d.run() }

        let reply = try await d.request(
            RVRegister(peerID: peerID, peerName: peerName, teamID: teamID, host: host, port: port),
            expecting: RVRegisterReply.self
        )

        // Start heartbeat loop
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                await self.sendHeartbeatNow()
            }
        }

        logger.info("Registered with rendezvous server, \(reply.peers.count) peer(s) found")
        return reply.peers
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        runTask?.cancel()
        runTask = nil
        try? await dispatcher?.peer.close()
        dispatcher = nil
    }

    /// Send a single heartbeat immediately. Used by the heartbeat loop and tests.
    func sendHeartbeatNow() async {
        guard let d = dispatcher,
              let peerID = registeredPeerID,
              let teamID = registeredTeamID else { return }
        _ = try? await d.request(
            RVHeartbeat(peerID: peerID, teamID: teamID),
            expecting: RVHeartbeatReply.self
        )
    }
}
