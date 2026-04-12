import Foundation

/// A snapshot of all files in the sync directory with their hashes.
struct SyncManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let hash: String
        let size: UInt64
        let modifiedAt: Date
    }

    let peerID: String
    let timestamp: Date
    let entries: [Entry]
}
