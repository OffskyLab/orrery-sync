import Foundation
import NMTP
import NIO
import Logging
import Crypto

#if canImport(Network)
import Network
#endif

/// Core daemon that manages NMT server, peer connections, file watching, and control socket.
actor SyncDaemon {
    let port: Int
    let syncDirectory: String
    let socketPath: String
    let peerID: String
    let tls: SyncTLSContext?
    let logger = Logger(label: "orbital-sync")

    private var server: NMTServer?
    private var peers: [String: PeerConnection] = [:]
    private var controlSocket: ControlSocket?
    private var fileWatchTask: Task<Void, Never>?
    /// Paths recently written by sync — skip these in FileWatcher to avoid ping-pong loops.
    private var recentSyncWrites: [String: Date] = [:]
    #if canImport(Network)
    private var discovery: BonjourDiscovery?
    #endif

    static let version = "0.1.0"

    init(port: Int, syncDirectory: String, socketPath: String, tls: SyncTLSContext? = nil) {
        self.port = port
        // Resolve symlinks (e.g. /tmp → /private/tmp on macOS)
        self.syncDirectory = Self.resolveRealPath(syncDirectory)
        self.socketPath = socketPath
        self.peerID = UUID().uuidString
        self.tls = tls
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
        server = try await NMTServer.bind(on: address, handler: handler, tls: tls)
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

        // 4. Auto-connect to known peers from config
        let config = SyncConfig.load()
        if config.team != nil {
            for peer in config.knownPeers {
                Task {
                    do {
                        try await daemonRef.addPeer(host: peer.host, port: peer.port)
                    } catch {
                        logger.warning("Failed to connect to known peer \(peer.host):\(peer.port): \(error)")
                    }
                }
            }
        }

        // 5. Start mDNS discovery (macOS only)
        #if canImport(Network)
        let info = localPeerInfo()
        let disc = BonjourDiscovery(
            peerID: peerID,
            peerName: info.peerName,
            port: port,
            teamID: config.team?.id,
            onPeerFound: { [weak self] peer in
                guard let self else { return }
                let alreadyPaired = await self.hasPeer(peer.peerID)
                guard !alreadyPaired else { return }
                await self.resolveAndConnect(peer)
            }
        )
        try await disc.startAdvertising()
        await disc.startBrowsing()
        self.discovery = disc
        #endif

        logger.info("Daemon ready")

        // 6. Block until terminated
        try await server?.listen()
    }

    func stop() async throws {
        #if canImport(Network)
        await discovery?.stopBrowsing()
        await discovery?.stopAdvertising()
        #endif
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
        let client = try await NMTClient.connect(to: address, tls: tls)

        // Handshake
        let info = localPeerInfo()
        let config = SyncConfig.load()
        let handshakeBody = HandshakeBody(
            peerID: info.peerID,
            peerName: info.peerName,
            version: info.version,
            port: self.port,
            teamID: config.team?.id
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

        // Save to known peers for auto-reconnect
        var cfg = SyncConfig.load()
        let alreadyKnown = cfg.knownPeers.contains { $0.host == host && $0.port == port }
        if !alreadyKnown {
            cfg.knownPeers.append(KnownPeer(
                peerID: handshakeReply.peerID,
                peerName: handshakeReply.peerName,
                host: host,
                port: port,
                addedAt: Date()
            ))
            try? cfg.save()
        }

        // Start listening for server-push from this peer.
        // When the stream ends (peer disconnected), attempt reconnection.
        let peerIDCopy = handshakeReply.peerID
        let peerNameCopy = handshakeReply.peerName
        Task {
            for await push in client.pushes {
                await self.handlePeerPush(push, from: peerIDCopy)
            }
            // Stream ended — peer disconnected
            await self.handlePeerDisconnect(peerID: peerIDCopy, peerName: peerNameCopy, host: host, port: port)
        }

        // Initial sync: exchange manifests and reconcile
        try await reconcileWithPeer(connection)
    }

    private func handlePeerDisconnect(peerID: String, peerName: String, host: String, port: Int) {
        peers.removeValue(forKey: peerID)
        logger.warning("Peer disconnected: \(peerName) (\(peerID))")

        // Retry reconnection with backoff
        Task {
            var delay: UInt64 = 2_000_000_000 // 2s
            let maxDelay: UInt64 = 30_000_000_000 // 30s
            let maxAttempts = 10

            for attempt in 1...maxAttempts {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                // Already reconnected (e.g., reverse-pair from the other side)
                if hasPeer(peerID) {
                    logger.info("Peer \(peerName) already reconnected")
                    return
                }

                logger.info("Reconnecting to \(peerName) (attempt \(attempt)/\(maxAttempts))...")
                do {
                    try await addPeer(host: host, port: port)
                    logger.info("Reconnected to \(peerName)")
                    return
                } catch {
                    logger.debug("Reconnect failed: \(error)")
                    delay = min(delay * 2, maxDelay)
                }
            }
            logger.warning("Gave up reconnecting to \(peerName) after \(maxAttempts) attempts")
        }
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

    func deleteFile(relativePath: String) -> Bool {
        let fullPath = (syncDirectory as NSString).appendingPathComponent(relativePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fullPath) else { return false }
        do {
            try fm.removeItem(atPath: fullPath)
            recentSyncWrites[relativePath] = Date()
            return true
        } catch {
            logger.error("Failed to delete \(relativePath): \(error)")
            return false
        }
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
                    let deleteBody = FileDeleteBody(path: change.path)
                    let argData = try JSONEncoder().encode(deleteBody)
                    let callBody = CallBody(
                        namespace: "orbital-sync",
                        service: "sync",
                        method: SyncMethod.fileDelete,
                        arguments: [EncodedArgument(key: "body", value: argData)]
                    )
                    let matter = try Matter.make(type: .call, body: callBody)
                    _ = try await peer.client.request(matter: matter)
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

    #if canImport(Network)
    /// Resolve a Bonjour-discovered peer's endpoint and connect via NMT.
    private func resolveAndConnect(_ peer: DiscoveredPeer) async {
        let nmtPort = peer.nmtPort
        let peerName = peer.peerName

        // Use NWConnection to resolve the Bonjour endpoint to an IP address
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, _) = innerEndpoint {
                    let hostStr = "\(host)"
                    connection.cancel()

                    Task {
                        do {
                            try await self.addPeer(host: hostStr, port: nmtPort)
                        } catch {
                            self.logger.warning("mDNS auto-connect to \(peerName) failed: \(error)")
                        }
                    }
                }
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "orbital-sync.resolve"))
    }
    #endif

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
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
