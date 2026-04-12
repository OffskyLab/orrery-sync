import Testing
import Foundation
@testable import OrrerySync

struct SyncDaemonPeerTests {

    private func makeDaemon(port: Int) -> (SyncDaemon, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let sockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sock").path
        let daemon = SyncDaemon(port: port, syncDirectory: dir, socketPath: sockPath)
        return (daemon, dir)
    }

    @Test func handshakeSucceeds() async throws {
        let (daemonA, _) = makeDaemon(port: 18201)
        let (daemonB, _) = makeDaemon(port: 18202)

        let taskA = Task { try? await daemonA.start() }
        let taskB = Task { try? await daemonB.start() }
        defer {
            taskA.cancel()
            taskB.cancel()
            Task { try? await daemonA.stop() }
            Task { try? await daemonB.stop() }
        }

        try await Task.sleep(for: .milliseconds(200))
        try await daemonA.addPeer(host: "127.0.0.1", port: 18202)
        let count = await daemonA.connectedPeerCount
        #expect(count == 1)
    }

    @Test func filePushReachesRemote() async throws {
        let (daemonA, _) = makeDaemon(port: 18203)
        let (daemonB, dirB) = makeDaemon(port: 18204)

        let taskA = Task { try? await daemonA.start() }
        let taskB = Task { try? await daemonB.start() }
        defer {
            taskA.cancel()
            taskB.cancel()
            Task { try? await daemonA.stop() }
            Task { try? await daemonB.stop() }
        }

        try await Task.sleep(for: .milliseconds(200))
        try await daemonA.addPeer(host: "127.0.0.1", port: 18204)

        guard let connToB = await daemonA.firstPeer() else {
            Issue.record("No peer connection after addPeer")
            return
        }

        let content = Data("hello from A".utf8)
        let relativePath = "memory/test.md"
        let now = Date()
        let pushMsg = SyncFilePush(path: relativePath, content: content, hash: "testhash", modifiedAt: now)
        _ = try await connToB.dispatcher.request(pushMsg, expecting: SyncFilePushReply.self)

        let expectedPath = (dirB as NSString).appendingPathComponent(relativePath)
        let written = FileManager.default.contents(atPath: expectedPath)
        #expect(written == content)
    }

    @Test func initiatorFlagIsCorrect() async throws {
        let (daemonA, _) = makeDaemon(port: 18205)
        let (daemonB, _) = makeDaemon(port: 18206)

        let taskA = Task { try? await daemonA.start() }
        let taskB = Task { try? await daemonB.start() }
        defer {
            taskA.cancel()
            taskB.cancel()
            Task { try? await daemonA.stop() }
            Task { try? await daemonB.stop() }
        }

        try await Task.sleep(for: .milliseconds(200))
        try await daemonA.addPeer(host: "127.0.0.1", port: 18206)

        let connA = await daemonA.firstPeer()
        #expect(connA?.isInitiator == true)

        // Give listener side time to process handshake
        try await Task.sleep(for: .milliseconds(100))
        let connB = await daemonB.firstPeer()
        #expect(connB?.isInitiator == false)
    }
}
