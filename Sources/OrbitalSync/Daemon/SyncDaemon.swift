import Foundation
import NMTP
import NIO
import Logging
import Crypto

#if canImport(Network)
import Network
#endif

// TODO: migrate to NMTPeer/PeerDispatcher — implementation pending Task 2

/// Core daemon that manages NMT server, peer connections, file watching, and control socket.
actor SyncDaemon {
    let port: Int
    let syncDirectory: String
    let socketPath: String
    let peerID: String
    let tls: SyncTLSContext?
    let rendezvousAddress: String?
    let logger = Logger(label: "orbital-sync")

    private var server: NMTServer?
    private var peers: [String: PeerConnection] = [:]
    private var controlSocket: ControlSocket?
    private var fileWatchTask: Task<Void, Never>?
    private var recentSyncWrites: [String: Date] = [:]
    #if canImport(Network)
    private var discovery: BonjourDiscovery?
    #endif
    private var rvClient: RendezvousClient?

    static let version = "1.0.0"

    init(port: Int, syncDirectory: String, socketPath: String, tls: SyncTLSContext? = nil, rendezvousAddress: String? = nil) {
        self.port = port
        self.syncDirectory = Self.resolveRealPath(syncDirectory)
        self.socketPath = socketPath
        self.peerID = UUID().uuidString
        self.tls = tls
        self.rendezvousAddress = rendezvousAddress
    }

    private static func resolveRealPath(_ path: String) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let resolved = realpath(path, nil) {
            let result = String(cString: resolved)
            free(resolved)
            return result
        }
        return path
    }

    func start() async throws {
        // TODO: migrate
        fatalError("SyncDaemon.start() — pending Task 2 migration")
    }

    func stop() async throws {
        // TODO: migrate
    }

    func hasPeer(_ peerID: String) -> Bool {
        peers[peerID] != nil
    }

    func addPeer(host: String, port: Int, skipHandshake: Bool = false) async throws {
        // TODO: migrate
        fatalError("SyncDaemon.addPeer() — pending Task 2 migration")
    }

    func buildManifest() -> SyncManifest {
        // TODO: migrate
        return SyncManifest(peerID: peerID, timestamp: Date(), entries: [])
    }

    struct FileData {
        let content: Data
        let hash: String
        let modifiedAt: Date
    }

    func readFile(relativePath: String) throws -> FileData {
        // TODO: migrate
        throw SyncError.fileNotFound(relativePath)
    }

    func writeFile(relativePath: String, content: Data, modifiedAt: Date) throws {
        // TODO: migrate
    }

    func deleteFile(relativePath: String) -> Bool {
        // TODO: migrate
        return false
    }

    func localPeerInfo() -> (peerID: String, peerName: String, version: String) {
        let name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return (peerID: peerID, peerName: name, version: Self.version)
    }
}
