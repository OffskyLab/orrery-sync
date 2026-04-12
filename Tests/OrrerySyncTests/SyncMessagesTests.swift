import Testing
import Foundation
@testable import OrrerySync
import NMTPeer

struct SyncMessagesTests {

    // MARK: messageType values

    @Test func syncHandshakeMessageType() {
        #expect(SyncHandshake.messageType == 0x0001)
    }

    @Test func syncHandshakeReplyMessageType() {
        #expect(SyncHandshakeReply.messageType == 0x0002)
    }

    @Test func syncManifestRequestMessageType() {
        #expect(SyncManifestRequest.messageType == 0x0003)
    }

    @Test func syncManifestReplyMessageType() {
        #expect(SyncManifestReply.messageType == 0x0004)
    }

    @Test func syncFilePullMessageType() {
        #expect(SyncFilePull.messageType == 0x0005)
    }

    @Test func syncFilePullReplyMessageType() {
        #expect(SyncFilePullReply.messageType == 0x0006)
    }

    @Test func syncFilePushMessageType() {
        #expect(SyncFilePush.messageType == 0x0007)
    }

    @Test func syncFilePushReplyMessageType() {
        #expect(SyncFilePushReply.messageType == 0x0008)
    }

    @Test func syncFileDeleteMessageType() {
        #expect(SyncFileDelete.messageType == 0x0009)
    }

    @Test func syncFileDeleteReplyMessageType() {
        #expect(SyncFileDeleteReply.messageType == 0x000A)
    }

    @Test func rvRegisterMessageType() {
        #expect(RVRegister.messageType == 0x0101)
    }

    @Test func rvRegisterReplyMessageType() {
        #expect(RVRegisterReply.messageType == 0x0102)
    }

    @Test func rvHeartbeatMessageType() {
        #expect(RVHeartbeat.messageType == 0x0103)
    }

    @Test func rvHeartbeatReplyMessageType() {
        #expect(RVHeartbeatReply.messageType == 0x0104)
    }

    // MARK: Codable round-trips

    @Test func syncHandshakeRoundTrip() throws {
        let msg = SyncHandshake(peerID: "abc", peerName: "mac", version: "1.0.0", port: 8100, teamID: "team1")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncHandshake.self, from: data)
        #expect(decoded.peerID == msg.peerID)
        #expect(decoded.port == msg.port)
        #expect(decoded.teamID == msg.teamID)
    }

    @Test func syncFilePushRoundTrip() throws {
        let content = Data("hello".utf8)
        let msg = SyncFilePush(path: "memory/file.md", content: content, hash: "abc123", modifiedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncFilePush.self, from: data)
        #expect(decoded.path == msg.path)
        #expect(decoded.content == msg.content)
        #expect(decoded.hash == msg.hash)
    }

    @Test func rvRegisterRoundTrip() throws {
        let msg = RVRegister(peerID: "p1", peerName: "host1", teamID: "t1", host: "192.168.1.1", port: 9000)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(RVRegister.self, from: data)
        #expect(decoded.peerID == msg.peerID)
        #expect(decoded.host == msg.host)
    }

    @Test func instanceMessageTypeMatchesStatic() {
        let msg = SyncHandshake(peerID: "x", peerName: "y", version: "1", port: 1, teamID: nil)
        #expect(msg.messageType == SyncHandshake.messageType)
    }
}
