import Foundation

// MARK: - Handshake

struct HandshakeBody: Codable, Sendable {
    let peerID: String
    let peerName: String
    let version: String
    let port: Int
    let teamID: String?
}

struct HandshakeReplyBody: Codable, Sendable {
    let peerID: String
    let peerName: String
    let version: String
    let accepted: Bool
}

// MARK: - Manifest exchange

struct ManifestRequestBody: Codable, Sendable {
    let peerID: String
}

struct ManifestReplyBody: Codable, Sendable {
    let manifest: SyncManifest
}

// MARK: - File transfer

struct FilePullBody: Codable, Sendable {
    let path: String
}

struct FilePullReplyBody: Codable, Sendable {
    let path: String
    let content: Data
    let hash: String
    let modifiedAt: Date
}

struct FilePushBody: Codable, Sendable {
    let path: String
    let content: Data
    let hash: String
    let modifiedAt: Date
}

struct FilePushReplyBody: Codable, Sendable {
    let accepted: Bool
}

// MARK: - File delete

struct FileDeleteBody: Codable, Sendable {
    let path: String
}

struct FileDeleteReplyBody: Codable, Sendable {
    let deleted: Bool
}

// MARK: - File change notification (server-push via .event)

struct FileChangedBody: Codable, Sendable {
    let peerID: String
    let change: FileChangeEntry
}

struct FileChangeEntry: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case created
        case modified
        case deleted
    }

    let path: String
    let kind: Kind
    let hash: String?
    let modifiedAt: Date?
}

// MARK: - Control socket (CLI → Daemon)

struct ControlRequest: Codable, Sendable {
    let command: String
    let args: [String: String]?
}

struct ControlResponse: Codable, Sendable {
    let ok: Bool
    let message: String
    let data: [String: String]?
}
