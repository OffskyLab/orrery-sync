import Foundation

/// Persistent configuration stored at ~/.orbital/sync-config.json
struct SyncConfig: Codable, Sendable {
    var team: TeamConfig?
    var knownPeers: [KnownPeer]

    init() {
        self.team = nil
        self.knownPeers = []
    }

    // MARK: - Load / Save

    static func load() -> SyncConfig {
        let path = configPath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(SyncConfig.self, from: data) else {
            return SyncConfig()
        }
        return config
    }

    func save() throws {
        let path = Self.configPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func configPath() -> String {
        if let home = ProcessInfo.processInfo.environment["ORBITAL_HOME"] {
            return home + "/sync-config.json"
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.orbital/sync-config.json"
    }
}

struct TeamConfig: Codable, Sendable {
    let id: String
    let name: String
    let secret: String
    let createdAt: Date
}

struct KnownPeer: Codable, Sendable {
    let peerID: String
    let peerName: String
    let host: String
    let port: Int
    let addedAt: Date
}
