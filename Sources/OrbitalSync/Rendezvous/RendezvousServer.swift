import Foundation
import NMTP
import NMTPeer
import NIO
import Logging

/// Lightweight coordination server for cross-network peer discovery.
/// Does NOT relay data — only exchanges peer connection info.
actor RendezvousServer {
    let port: Int
    let logger = Logger(label: "orbital-sync.rendezvous")

    private var serverListener: PeerDispatcherListener?
    private var cleanupTask: Task<Void, Never>?
    /// teamID → [peerID: registration]
    private var registry: [String: [String: PeerRegistration]] = [:]

    struct PeerRegistration {
        let peerID: String
        let peerName: String
        let host: String
        let port: Int
        let lastSeen: Date
    }

    init(port: Int) {
        self.port = port
    }

    func start() async throws {
        let address = try SocketAddress(ipAddress: "0.0.0.0", port: port)
        serverListener = try await PeerDispatcher.listen(on: address) { [weak self] dispatcher in
            self?.registerRVHandlers(on: dispatcher)
        }
        logger.info("Rendezvous server listening on port \(port)")

        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.cleanupStale()
            }
        }

        try await serverListener?.run()
    }

    func stop() async throws {
        cleanupTask?.cancel()
        cleanupTask = nil
        try await serverListener?.close()
    }

    // MARK: - Handler registration

    nonisolated func registerRVHandlers(on dispatcher: PeerDispatcher) {
        dispatcher.register(RVRegister.self) { [weak self] msg, peer in
            guard let self else { return nil }
            let remoteHost = peer.remoteAddress.ipAddress
            return await self.register(msg, remoteAddress: remoteHost)
        }

        dispatcher.register(RVHeartbeat.self) { [weak self] msg, _ in
            guard let self else { return nil }
            return await self.heartbeat(msg)
        }
    }

    // MARK: - Registry operations

    func register(_ msg: RVRegister, remoteAddress: String?) -> RVRegisterReply {
        let host = msg.host.isEmpty ? (remoteAddress ?? msg.host) : msg.host
        let reg = PeerRegistration(
            peerID: msg.peerID, peerName: msg.peerName,
            host: host, port: msg.port, lastSeen: Date()
        )
        var teamPeers = registry[msg.teamID] ?? [:]
        teamPeers[msg.peerID] = reg
        registry[msg.teamID] = teamPeers
        logger.info("Registered \(msg.peerName) (\(msg.peerID)) for team \(msg.teamID) at \(host):\(msg.port)")
        let otherPeers = teamPeers.values
            .filter { $0.peerID != msg.peerID }
            .map { RVPeerEntry(peerID: $0.peerID, peerName: $0.peerName, host: $0.host, port: $0.port) }
        return RVRegisterReply(peers: otherPeers)
    }

    func heartbeat(_ msg: RVHeartbeat) -> RVHeartbeatReply {
        if var teamPeers = registry[msg.teamID], let reg = teamPeers[msg.peerID] {
            teamPeers[msg.peerID] = PeerRegistration(
                peerID: reg.peerID, peerName: reg.peerName,
                host: reg.host, port: reg.port, lastSeen: Date()
            )
            registry[msg.teamID] = teamPeers
        }
        return RVHeartbeatReply(ok: true)
    }

    private func cleanupStale() {
        let staleThreshold: TimeInterval = 90
        let now = Date()
        for (teamID, peers) in registry {
            let alive = peers.filter { now.timeIntervalSince($0.value.lastSeen) < staleThreshold }
            let removed = peers.count - alive.count
            if removed > 0 {
                logger.info("Cleaned up \(removed) stale peer(s) from team \(teamID)")
            }
            registry[teamID] = alive.isEmpty ? nil : alive
        }
    }
}
