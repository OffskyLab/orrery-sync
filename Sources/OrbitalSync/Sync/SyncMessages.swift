import Foundation
import NMTPeer

// MARK: - Sync messages (0x00xx)

struct SyncHandshake: PeerMessage {
    static let messageType: UInt16 = 0x0001
    let peerID: String
    let peerName: String
    let version: String
    let port: Int
    let teamID: String?
}

struct SyncHandshakeReply: PeerMessage {
    static let messageType: UInt16 = 0x0002
    let peerID: String
    let peerName: String
    let version: String
    let accepted: Bool
}

struct SyncManifestRequest: PeerMessage {
    static let messageType: UInt16 = 0x0003
    let peerID: String
}

struct SyncManifestReply: PeerMessage {
    static let messageType: UInt16 = 0x0004
    let manifest: SyncManifest
}

struct SyncFilePull: PeerMessage {
    static let messageType: UInt16 = 0x0005
    let path: String
}

struct SyncFilePullReply: PeerMessage {
    static let messageType: UInt16 = 0x0006
    let path: String
    let content: Data
    let hash: String
    let modifiedAt: Date
}

struct SyncFilePush: PeerMessage {
    static let messageType: UInt16 = 0x0007
    let path: String
    let content: Data
    let hash: String
    let modifiedAt: Date
}

struct SyncFilePushReply: PeerMessage {
    static let messageType: UInt16 = 0x0008
    let accepted: Bool
}

struct SyncFileDelete: PeerMessage {
    static let messageType: UInt16 = 0x0009
    let path: String
}

struct SyncFileDeleteReply: PeerMessage {
    static let messageType: UInt16 = 0x000A
    let deleted: Bool
}

// MARK: - Rendezvous messages (0x01xx)

struct RVRegister: PeerMessage {
    static let messageType: UInt16 = 0x0101
    let peerID: String
    let peerName: String
    let teamID: String
    let host: String
    let port: Int
}

struct RVRegisterReply: PeerMessage {
    static let messageType: UInt16 = 0x0102
    let peers: [RVPeerEntry]
}

struct RVHeartbeat: PeerMessage {
    static let messageType: UInt16 = 0x0103
    let peerID: String
    let teamID: String
}

struct RVHeartbeatReply: PeerMessage {
    static let messageType: UInt16 = 0x0104
    let ok: Bool
}

// MARK: - Supporting types

struct RVPeerEntry: Codable, Sendable {
    let peerID: String
    let peerName: String
    let host: String
    let port: Int
}
