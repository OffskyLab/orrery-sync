import Foundation
import NMTP
import NIO
import Logging

/// Core daemon that manages NMT server, peer connections, file watching, and control socket.
actor SyncDaemon {
    let port: Int
    let syncDirectory: String
    let socketPath: String
    let peerID: String
    let logger = Logger(label: "orbital-sync")

    private var server: NMTServer?
    private var peers: [String: PeerConnection] = [:]
    private var controlSocket: ControlSocket?
    private var fileWatchTask: Task<Void, Never>?
    /// Paths recently written by sync — skip these in FileWatcher to avoid ping-pong loops.
    private var recentSyncWrites: [String: Date] = [:]

    static let version = "0.1.0"

    init(port: Int, syncDirectory: String, socketPath: String) {
        self.port = port
        // Resolve symlinks (e.g. /tmp → /private/tmp on macOS)
        self.syncDirectory = Self.resolveRealPath(syncDirectory)
        self.socketPath = socketPath
        self.peerID = UUID().uuidString
    }

    private static func resolveRealPath(_ path: String) -> String {
        // Ensure parent exists so realpath can resolve
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let resolved = realpath(path, nil) {
            let result = String(cString: resolved)
            free(resolved)
            return result
        }
        return path
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Ensure sync directory exists
        try FileManager.default.createDirectory(atPath: syncDirectory, withIntermediateDirectories: true)

        logger.info("Starting daemon", metadata: [
            "peerID": "\(peerID)",
            "port": "\(port)",
            "syncDir": "\(syncDirectory)",
        ])

        // 1. Start NMT server for peer connections
        let handler = SyncHandler(daemon: self)
        let address = try SocketAddress(ipAddress: "0.0.0.0", port: port)
        server = try await NMTServer.bind(on: address, handler: handler)
        logger.info("NMT server bound on port \(port)")

        // 2. Start control socket for CLI commands
        let daemonRef = self
        let socket = ControlSocket(socketPath: socketPath) { request in
            await daemonRef.handleControl(request)
        }
        self.controlSocket = socket
        try await socket.start()

        // 3. Start file watcher
        let watcher = FileWatcher(directory: syncDirectory)
        let watchStream = watcher.watch()
        fileWatchTask = Task {
            for await change in watchStream {
                await daemonRef.handleFileChange(change)
            }
        }

        logger.info("Daemon ready")

        // 4. Block until terminated
        try await server?.listen()
    }

    func stop() async throws {
        fileWatchTask?.cancel()
        for (_, peer) in peers {
            try await peer.client.close()
        }
        peers.removeAll()
        try await controlSocket?.stop()
        try await server?.stop()
        logger.info("Daemon stopped")
    }

    // MARK: - Peer management

    func hasPeer(_ peerID: String) -> Bool {
        peers[peerID] != nil
    }

    func addPeer(host: String, port: Int, skipHandshake: Bool = false) async throws {
        let address = try SocketAddress(ipAddress: host, port: port)
        let client = try await NMTClient.connect(to: address)

        // Handshake
        let info = localPeerInfo()
        let handshakeBody = HandshakeBody(
            peerID: info.peerID,
            peerName: info.peerName,
            version: info.version,
            port: self.port,
            teamID: nil
        )
        let argData = try JSONEncoder().encode(handshakeBody)
        let callBody = CallBody(
            namespace: "orbital-sync",
            service: "sync",
            method: SyncMethod.handshake,
            arguments: [EncodedArgument(key: "body", value: argData)]
        )
        let request = try Matter.make(type: .call, body: callBody)
        let response = try await client.request(matter: request)
        let reply = try response.decodeBody(CallReplyBody.self)

        guard let resultData = reply.result else {
            throw SyncError.missingArgument
        }
        let handshakeReply = try JSONDecoder().decode(HandshakeReplyBody.self, from: resultData)

        guard handshakeReply.accepted else {
            try await client.close()
            logger.warning("Peer rejected handshake: \(host):\(port)")
            return
        }

        // Skip if already paired (prevents infinite reverse-pair loop)
        guard !hasPeer(handshakeReply.peerID) else {
            try await client.close()
            logger.debug("Already paired with \(handshakeReply.peerName), skipping")
            return
        }

        let connection = PeerConnection(
            peerID: handshakeReply.peerID,
            peerName: handshakeReply.peerName,
            address: host,
            port: port,
            client: client
        )
        peers[handshakeReply.peerID] = connection
        logger.info("Paired with \(handshakeReply.peerName) (\(handshakeReply.peerID))")

        // Start listening for server-push from this peer
        Task {
            for await push in client.pushes {
                await self.handlePeerPush(push, from: handshakeReply.peerID)
            }
        }

        // Initial sync: exchange manifests and reconcile
        try await reconcileWithPeer(connection)
    }

    // MARK: - Sync logic

    func buildManifest() -> SyncManifest {
        let fm = FileManager.default
        var entries: [SyncManifest.Entry] = []

        guard let enumerator = fm.enumerator(atPath: syncDirectory) else {
            return SyncManifest(peerID: peerID, timestamp: Date(), entries: [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (syncDirectory as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let size = attrs[.size] as? UInt64,
                  let modified = attrs[.modificationDate] as? Date else { continue }

            let hash = computeHash(of: fullPath)

            entries.append(SyncManifest.Entry(
                path: relativePath,
                hash: hash,
                size: size,
                modifiedAt: modified
            ))
        }

        return SyncManifest(peerID: peerID, timestamp: Date(), entries: entries)
    }

    struct FileData {
        let content: Data
        let hash: String
        let modifiedAt: Date
    }

    func readFile(relativePath: String) throws -> FileData {
        let fullPath = (syncDirectory as NSString).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw SyncError.fileNotFound(relativePath)
        }
        let content = try Data(contentsOf: URL(fileURLWithPath: fullPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: fullPath)
        let modified = attrs[.modificationDate] as? Date ?? Date()
        let hash = computeHash(of: fullPath)
        return FileData(content: content, hash: hash, modifiedAt: modified)
    }

    func writeFile(relativePath: String, content: Data, modifiedAt: Date) throws {
        let fullPath = (syncDirectory as NSString).appendingPathComponent(relativePath)
        let dir = (fullPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(to: URL(fileURLWithPath: fullPath))

        // Preserve original modification time
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: fullPath
        )

        // Mark as sync-written so FileWatcher ignores it
        recentSyncWrites[relativePath] = Date()
    }

    func localPeerInfo() -> (peerID: String, peerName: String, version: String) {
        let name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return (peerID: peerID, peerName: name, version: Self.version)
    }

    // MARK: - Private

    private func reconcileWithPeer(_ peer: PeerConnection) async throws {
        let localManifest = buildManifest()

        // Request remote manifest
        let requestBody = ManifestRequestBody(peerID: peerID)
        let argData = try JSONEncoder().encode(requestBody)
        let callBody = CallBody(
            namespace: "orbital-sync",
            service: "sync",
            method: SyncMethod.manifest,
            arguments: [EncodedArgument(key: "body", value: argData)]
        )
        let request = try Matter.make(type: .call, body: callBody)
        let response = try await peer.client.request(matter: request)
        let reply = try response.decodeBody(CallReplyBody.self)

        guard let resultData = reply.result else { return }
        let remoteManifest = try JSONDecoder().decode(ManifestReplyBody.self, from: resultData).manifest

        // Diff: find files remote has that we don't, or are newer
        let localIndex = Dictionary(uniqueKeysWithValues: localManifest.entries.map { ($0.path, $0) })

        for remoteEntry in remoteManifest.entries {
            let needsPull: Bool
            if let localEntry = localIndex[remoteEntry.path] {
                needsPull = remoteEntry.hash != localEntry.hash && remoteEntry.modifiedAt > localEntry.modifiedAt
            } else {
                needsPull = true
            }

            if needsPull {
                try await pullFile(remoteEntry.path, from: peer)
            }
        }

        logger.info("Reconciliation with \(peer.peerName) complete")
    }

    private func pullFile(_ path: String, from peer: PeerConnection) async throws {
        let pullBody = FilePullBody(path: path)
        let argData = try JSONEncoder().encode(pullBody)
        let callBody = CallBody(
            namespace: "orbital-sync",
            service: "sync",
            method: SyncMethod.filePull,
            arguments: [EncodedArgument(key: "body", value: argData)]
        )
        let request = try Matter.make(type: .call, body: callBody)
        let response = try await peer.client.request(matter: request)
        let reply = try response.decodeBody(CallReplyBody.self)

        guard let resultData = reply.result else { return }
        let fileReply = try JSONDecoder().decode(FilePullReplyBody.self, from: resultData)
        try writeFile(relativePath: fileReply.path, content: fileReply.content, modifiedAt: fileReply.modifiedAt)
        logger.debug("Pulled \(path) from \(peer.peerName)")
    }

    private func handleFileChange(_ change: FileChange) async {
        // Skip files recently written by sync to avoid ping-pong loops
        if let writeTime = recentSyncWrites[change.path],
           Date().timeIntervalSince(writeTime) < 2.0 {
            return
        }
        let now = Date()
        let staleKeys = recentSyncWrites.filter { now.timeIntervalSince($0.value) > 5.0 }.map(\.key)
        for key in staleKeys { recentSyncWrites.removeValue(forKey: key) }

        logger.info("File changed: \(change.kind) \(change.path), peers: \(peers.count)")

        let entry = FileChangeEntry(
            path: change.path,
            kind: FileChangeEntry.Kind(rawValue: "\(change.kind)") ?? .modified,
            hash: computeHash(of: (syncDirectory as NSString).appendingPathComponent(change.path)),
            modifiedAt: Date()
        )
        let body = FileChangedBody(peerID: peerID, change: entry)

        // Push file content to all peers
        for (_, peer) in peers {
            do {
                if change.kind == .deleted {
                    // Just notify deletion
                    let argData = try JSONEncoder().encode(body)
                    let eventBody = CallBody(
                        namespace: "orbital-sync",
                        service: "sync",
                        method: "sync.file.changed",
                        arguments: [EncodedArgument(key: "body", value: argData)]
                    )
                    let matter = try Matter.make(type: .event, body: eventBody)
                    peer.client.fire(matter: matter)
                } else {
                    // Push the file
                    let fileData = try readFile(relativePath: change.path)
                    let pushBody = FilePushBody(
                        path: change.path,
                        content: fileData.content,
                        hash: fileData.hash,
                        modifiedAt: fileData.modifiedAt
                    )
                    let argData = try JSONEncoder().encode(pushBody)
                    let callBody = CallBody(
                        namespace: "orbital-sync",
                        service: "sync",
                        method: SyncMethod.filePush,
                        arguments: [EncodedArgument(key: "body", value: argData)]
                    )
                    let matter = try Matter.make(type: .call, body: callBody)
                    _ = try await peer.client.request(matter: matter)
                }
            } catch {
                logger.error("Failed to push change to \(peer.peerName): \(error)")
            }
        }
    }

    private func handlePeerPush(_ matter: Matter, from peerID: String) async {
        // Handle server-push events from peers (e.g., file change notifications)
        logger.debug("Received push from \(peerID): \(matter.type)")
    }

    private func handleControl(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case "status":
            let peerList = peers.values.map { "\($0.peerName) (\($0.address):\($0.port))" }
            return ControlResponse(
                ok: true,
                message: "Running on port \(port), \(peers.count) peer(s)",
                data: ["peers": peerList.joined(separator: ", ")]
            )
        case "pair":
            guard let host = request.args?["host"],
                  let portStr = request.args?["port"],
                  let port = Int(portStr) else {
                return ControlResponse(ok: false, message: "Missing host/port", data: nil)
            }
            do {
                try await addPeer(host: host, port: port)
                return ControlResponse(ok: true, message: "Paired successfully", data: nil)
            } catch {
                return ControlResponse(ok: false, message: "Pair failed: \(error)", data: nil)
            }
        default:
            return ControlResponse(ok: false, message: "Unknown command: \(request.command)", data: nil)
        }
    }

    private func computeHash(of path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        // Simple hash: use data count + first/last bytes as quick fingerprint
        // TODO: Replace with proper SHA256
        var hasher = Hasher()
        hasher.combine(data)
        return String(hasher.finalize(), radix: 16)
    }
}
