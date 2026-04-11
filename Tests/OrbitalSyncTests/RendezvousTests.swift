import Testing
import Foundation
@testable import OrbitalSync

struct RendezvousTests {

    @Test func registerReturnsPeerList() async throws {
        let server = RendezvousServer(port: 19101)
        let serverTask = Task { try? await server.start() }
        try await Task.sleep(for: .milliseconds(200))

        let client1 = RendezvousClient(host: "127.0.0.1", port: 19101)
        let peers1 = try await client1.register(
            peerID: "peer1", peerName: "Host1", teamID: "team-A", host: "1.2.3.4", port: 8100
        )
        #expect(peers1.isEmpty)

        let client2 = RendezvousClient(host: "127.0.0.1", port: 19101)
        let peers2 = try await client2.register(
            peerID: "peer2", peerName: "Host2", teamID: "team-A", host: "1.2.3.5", port: 8101
        )
        #expect(peers2.count == 1)
        #expect(peers2[0].peerID == "peer1")

        await client1.disconnect()
        await client2.disconnect()
        serverTask.cancel()
        try? await server.stop()
    }

    @Test func heartbeatKeepsRegistrationAlive() async throws {
        let server = RendezvousServer(port: 19102)
        let serverTask = Task { try? await server.start() }
        try await Task.sleep(for: .milliseconds(200))

        let client = RendezvousClient(host: "127.0.0.1", port: 19102)
        _ = try await client.register(
            peerID: "peer-hb", peerName: "HBHost", teamID: "team-B", host: "10.0.0.1", port: 9000
        )

        try await client.sendHeartbeatNow()

        let client2 = RendezvousClient(host: "127.0.0.1", port: 19102)
        let peers = try await client2.register(
            peerID: "peer-other", peerName: "OtherHost", teamID: "team-B", host: "10.0.0.2", port: 9001
        )
        #expect(peers.contains { $0.peerID == "peer-hb" })

        await client.disconnect()
        await client2.disconnect()
        serverTask.cancel()
        try? await server.stop()
    }

    @Test func differentTeamsAreIsolated() async throws {
        let server = RendezvousServer(port: 19103)
        let serverTask = Task { try? await server.start() }
        try await Task.sleep(for: .milliseconds(200))

        let clientA = RendezvousClient(host: "127.0.0.1", port: 19103)
        _ = try await clientA.register(peerID: "a1", peerName: "A1", teamID: "team-X", host: "1.1.1.1", port: 8200)

        let clientB = RendezvousClient(host: "127.0.0.1", port: 19103)
        let peers = try await clientB.register(peerID: "b1", peerName: "B1", teamID: "team-Y", host: "2.2.2.2", port: 8201)
        #expect(peers.isEmpty)

        await clientA.disconnect()
        await clientB.disconnect()
        serverTask.cancel()
        try? await server.stop()
    }
}
