import Foundation
import NMTP
import NMTPeer
import NIO
import Logging
import Crypto

#if canImport(Network)
import Network
#endif

/// Core daemon that manages peer listener, peer connections, file watching, and control socket.
actor SyncDaemon {
    let port: Int
    let syncDirectory: String
    let socketPath: String
    let peerID: String
    let tls: SyncTLSContext?
    let rendezvousAddress: String?
    let logger = Logger(label: "orbital-sync")

    private var peerListener: PeerListener?
    private var peers: [String: PeerConnection] = [:]
    private var controlSocket: ControlSocket?
    private var fileWatchTask: Task<Void, Never>?
    private var recentSyncWrites: [String: Date] = [:]
    private var isStopping = false
    private var shouldStop: Bool { isStopping }
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

    // MARK: - Testability helpers

    var connectedPeerCount: Int { peers.count }

    func firstPeer() -> PeerConnection? { peers.values.first }

    // MARK: - Lifecycle

    func start() async throws {
        try FileManager.default.createDirectory(atPath: syncDirectory, withIntermediateDirectories: true)

        logger.info("Starting daemon", metadata: [
            "peerID": "\(peerID)",
            "port": "\(port)",
            "syncDir": "\(syncDirectory)",
        ])

        // 1. Bind peer listener
        let address = try SocketAddress(ipAddress: "0.0.0.0", port: port)
        let listener = try await PeerListener.bind(on: address, tls: tls)
        self.peerListener = listener
        logger.info("Peer listener bound on port \(port)")

        // 2. Start control socket
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

        // 4. Auto-connect to known peers
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

        // 5. mDNS discovery (macOS only)
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

        // 6. Rendezvous registration
        if let rvAddr = rendezvousAddress, let team = config.team {
            let parts = rvAddr.split(separator: ":")
            if parts.count == 2, let rvPort = Int(parts[1]) {
                let rvHost = String(parts[0])
                let rv = RendezvousClient(host: rvHost, port: rvPort)
                self.rvClient = rv
                Task {
                    do {
                        let info = await daemonRef.localPeerInfo()
                        let rvPeers = try await rv.register(
                            peerID: peerID, peerName: info.peerName,
                            teamID: team.id, host: "", port: port
                        )
                        for rvPeer in rvPeers {
                            let alreadyPaired = await daemonRef.hasPeer(rvPeer.peerID)
                            if !alreadyPaired {
                                try await daemonRef.addPeer(host: rvPeer.host, port: rvPeer.port)
                            }
                        }
                    } catch {
                        logger.warning("Rendezvous registration failed: \(error)")
                    }
                }
            }
        }

        logger.info("Daemon ready")

        // 7. Accept loop — blocks until peerListener.close() is called
        for await peer in listener.peers {
            let dispatcher = PeerDispatcher(peer: peer)
            registerSyncHandlers(on: dispatcher)
            Task { [weak self] in
                try? await dispatcher.run()
                await self?.handleListenerPeerDisconnect(dispatcher: dispatcher)
            }
        }
    }

    func stop() async throws {
        isStopping = true
        await rvClient?.disconnect()
        #if canImport(Network)
        await discovery?.stopBrowsing()
        await discovery?.stopAdvertising()
        #endif
        fileWatchTask?.cancel()
        for (_, peer) in peers {
            try? await peer.dispatcher.peer.close()
        }
        peers.removeAll()
        try await controlSocket?.stop()
        try await peerListener?.close()
        logger.info("Daemon stopped")
    }

    // MARK: - Peer management

    func hasPeer(_ peerID: String) -> Bool {
        peers[peerID] != nil
    }

    func storePeer(_ connection: PeerConnection) {
        peers[connection.peerID] = connection
        logger.info("Paired with \(connection.peerName) (\(connection.peerID))")
    }

    func addPeer(host: String, port: Int) async throws {
        let address = try SocketAddress(ipAddress: host, port: port)
        let dispatcher = try await PeerDispatcher.connect(to: address, tls: tls)
        registerSyncHandlers(on: dispatcher)

        // Start run() BEFORE sending any request — ensures replies are routed
        let runTask = Task {
            try? await dispatcher.run()
        }

        let info = localPeerInfo()
        let config = SyncConfig.load()
        let reply: SyncHandshakeReply
        do {
            reply = try await dispatcher.request(
                SyncHandshake(
                    peerID: info.peerID, peerName: info.peerName,
                    version: info.version, port: self.port, teamID: config.team?.id
                ),
                expecting: SyncHandshakeReply.self
            )
        } catch {
            runTask.cancel()
            try? await dispatcher.peer.close()
            throw error
        }

        guard reply.accepted else {
            runTask.cancel()
            try? await dispatcher.peer.close()
            logger.warning("Peer rejected handshake: \(host):\(port)")
            throw SyncError.handshakeRejected
        }

        guard !hasPeer(reply.peerID) else {
            runTask.cancel()
            try? await dispatcher.peer.close()
            logger.debug("Already paired with \(reply.peerName), skipping")
            return
        }

        let connection = PeerConnection(
            peerID: reply.peerID, peerName: reply.peerName,
            address: host, port: port,
            dispatcher: dispatcher, isInitiator: true
        )
        peers[reply.peerID] = connection
        logger.info("Paired with \(reply.peerName) (\(reply.peerID))")

        // Save to known peers for auto-reconnect
        var cfg = SyncConfig.load()
        let alreadyKnown = cfg.knownPeers.contains { $0.host == host && $0.port == port }
        if !alreadyKnown {
            cfg.knownPeers.append(KnownPeer(
                peerID: reply.peerID, peerName: reply.peerName,
                host: host, port: port, addedAt: Date()
            ))
            try? cfg.save()
        }

        let remotePeerID = reply.peerID
        let remotePeerName = reply.peerName
        // When runTask finishes, the peer has disconnected
        Task {
            await runTask.value
            await self.handlePeerDisconnect(
                peerID: remotePeerID, peerName: remotePeerName,
                host: host, port: port, isInitiator: true
            )
        }

        try await reconcileWithPeer(connection)
    }

    private func handleListenerPeerDisconnect(dispatcher: PeerDispatcher) {
        guard !isStopping else { return }
        guard let peerID = peers.first(where: { $0.value.dispatcher === dispatcher })?.key else { return }
        let peerName = peers[peerID]?.peerName ?? peerID
        peers.removeValue(forKey: peerID)
        logger.info("Listener peer disconnected: \(peerName) (\(peerID)) — no retry")
    }

    private func handlePeerDisconnect(peerID: String, peerName: String, host: String, port: Int, isInitiator: Bool) {
        guard !isStopping else { return }
        peers.removeValue(forKey: peerID)
        logger.warning("Peer disconnected: \(peerName) (\(peerID))")
        guard isInitiator else { return }

        Task {
            var delay: UInt64 = 2_000_000_000
            let maxDelay: UInt64 = 30_000_000_000
            let maxAttempts = 10
            for attempt in 1...maxAttempts {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if await self.shouldStop { return }
                if await self.hasPeer(peerID) {
                    logger.info("Peer \(peerName) already reconnected")
                    return
                }
                logger.info("Reconnecting to \(peerName) (attempt \(attempt)/\(maxAttempts))...")
                do {
                    try await self.addPeer(host: host, port: port)
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

    // MARK: - Handler registration

    nonisolated func registerSyncHandlers(on dispatcher: PeerDispatcher) {
        dispatcher.register(SyncHandshake.self) { [weak self, dispatcher] msg, _ in
            guard let self else { return nil }
            let config = SyncConfig.load()
            if let team = config.team, let remoteTeam = msg.teamID, team.id != remoteTeam {
                let info = await self.localPeerInfo()
                return SyncHandshakeReply(
                    peerID: info.peerID, peerName: info.peerName,
                    version: info.version, accepted: false
                )
            }
            let host = dispatcher.peer.remoteAddress.ipAddress ?? "127.0.0.1"
            let info = await self.localPeerInfo()
            let connection = PeerConnection(
                peerID: msg.peerID, peerName: msg.peerName,
                address: host, port: msg.port,
                dispatcher: dispatcher, isInitiator: false
            )
            await self.storePeer(connection)
            return SyncHandshakeReply(
                peerID: info.peerID, peerName: info.peerName,
                version: info.version, accepted: true
            )
        }

        dispatcher.register(SyncManifestRequest.self) { [weak self] _, _ in
            guard let self else { return nil }
            let manifest = await self.buildManifest()
            return SyncManifestReply(manifest: manifest)
        }

        dispatcher.register(SyncFilePull.self) { [weak self] msg, _ in
            guard let self else { return nil }
            let fileData = try await self.readFile(relativePath: msg.path)
            return SyncFilePullReply(
                path: msg.path, content: fileData.content,
                hash: fileData.hash, modifiedAt: fileData.modifiedAt
            )
        }

        dispatcher.register(SyncFilePush.self) { [weak self] msg, _ in
            guard let self else { return nil }
            try await self.writeFile(relativePath: msg.path, content: msg.content, modifiedAt: msg.modifiedAt)
            return SyncFilePushReply(accepted: true)
        }

        dispatcher.register(SyncFileDelete.self) { [weak self] msg, _ in
            guard let self else { return nil }
            let deleted = await self.deleteFile(relativePath: msg.path)
            return SyncFileDeleteReply(deleted: deleted)
        }
    }

    // MARK: - Sync logic

    private static let syncPrefix = "memory/"

    func buildManifest() -> SyncManifest {
        let fm = FileManager.default
        var entries: [SyncManifest.Entry] = []
        let memoryDir = (syncDirectory as NSString).appendingPathComponent("memory")
        guard let enumerator = fm.enumerator(atPath: memoryDir) else {
            return SyncManifest(peerID: peerID, timestamp: Date(), entries: [])
        }
        while let subPath = enumerator.nextObject() as? String {
            let relativePath = Self.syncPrefix + subPath
            let fullPath = (syncDirectory as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let size = attrs[.size] as? UInt64,
                  let modified = attrs[.modificationDate] as? Date else { continue }
            let hash = computeHash(of: fullPath)
            entries.append(SyncManifest.Entry(path: relativePath, hash: hash, size: size, modifiedAt: modified))
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
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fullPath)
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
        let reply = try await peer.dispatcher.request(
            SyncManifestRequest(peerID: peerID),
            expecting: SyncManifestReply.self
        )
        let remoteManifest = reply.manifest
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
        let reply = try await peer.dispatcher.request(
            SyncFilePull(path: path),
            expecting: SyncFilePullReply.self
        )
        try writeFile(relativePath: reply.path, content: reply.content, modifiedAt: reply.modifiedAt)
        logger.debug("Pulled \(path) from \(peer.peerName)")
    }

    private func handleFileChange(_ change: FileChange) async {
        guard change.path.hasPrefix(Self.syncPrefix) else { return }
        if let writeTime = recentSyncWrites[change.path],
           Date().timeIntervalSince(writeTime) < 2.0 { return }
        let now = Date()
        let staleKeys = recentSyncWrites.filter { now.timeIntervalSince($0.value) > 5.0 }.map(\.key)
        for key in staleKeys { recentSyncWrites.removeValue(forKey: key) }
        logger.info("File changed: \(change.kind) \(change.path), peers: \(peers.count)")
        for (_, peer) in peers {
            do {
                if change.kind == .deleted {
                    _ = try await peer.dispatcher.request(
                        SyncFileDelete(path: change.path),
                        expecting: SyncFileDeleteReply.self
                    )
                } else {
                    let fileData = try readFile(relativePath: change.path)
                    _ = try await peer.dispatcher.request(
                        SyncFilePush(
                            path: change.path, content: fileData.content,
                            hash: fileData.hash, modifiedAt: fileData.modifiedAt
                        ),
                        expecting: SyncFilePushReply.self
                    )
                }
            } catch {
                logger.error("Failed to push change to \(peer.peerName): \(error)")
            }
        }
    }

    #if canImport(Network)
    private func resolveAndConnect(_ peer: DiscoveredPeer) async {
        let nmtPort = peer.nmtPort
        let peerName = peer.peerName
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
                        do { try await self.addPeer(host: hostStr, port: nmtPort) }
                        catch { self.logger.warning("mDNS auto-connect to \(peerName) failed: \(error)") }
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

// MARK: - Errors

enum SyncError: Error {
    case missingArgument
    case fileNotFound(String)
    case daemonNotRunning
    case invalidInviteCode
    case noTeamConfigured
    case handshakeRejected
}
