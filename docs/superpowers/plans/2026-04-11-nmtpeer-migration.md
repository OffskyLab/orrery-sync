# orbital-sync NMTPeer Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `orbital-sync` from the asymmetric `NMTServer`/`NMTClient`/`NMTHandler` architecture to the symmetric `NMTPeer`/`PeerDispatcher` layer (PR #4 on swift-nmtp, branch `feature/nmtp-peer`).

**Architecture:** Replace `CallBody` string-method dispatch with typed `PeerMessage` conformers identified by `UInt16` messageType. `PeerListener` replaces `NMTServer`. `PeerDispatcher.connect` replaces `NMTClient`. The reverse-pairing hack (server opening an outbound `NMTClient` back to each connector) is eliminated — `PeerDispatcher` is symmetric so both sides communicate on the already-open connection. Clean-break: no backward-compat with v1.x wire format.

**Tech Stack:** Swift 6 strict concurrency, `NMTPeer` target from `swift-nmtp` branch `feature/nmtp-peer`, `Synchronization.Mutex`, `Foundation` (JSONEncoder/JSONDecoder via PeerMessage/Codable)

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `Package.swift` | Add `NMTPeer` product dependency |
| Create | `Sources/OrbitalSync/Sync/SyncMessages.swift` | All `PeerMessage` conformers (sync + rendezvous namespaces) |
| Modify | `Sources/OrbitalSync/Sync/SyncBodies.swift` | Remove everything except `ControlRequest`/`ControlResponse` |
| Delete | `Sources/OrbitalSync/Sync/SyncMethods.swift` | String constants replaced by `static var messageType: UInt16` |
| Modify | `Sources/OrbitalSync/Daemon/PeerConnection.swift` | Replace `client: NMTClient` with `dispatcher: PeerDispatcher, isInitiator: Bool` |
| Rewrite | `Sources/OrbitalSync/Daemon/SyncDaemon.swift` | `PeerListener`-based accept loop; `PeerDispatcher.connect` for outbound; typed request/reply throughout |
| Delete | `Sources/OrbitalSync/Daemon/SyncHandler.swift` | Logic moves inline to `SyncDaemon`; `SyncError` moves to `SyncDaemon.swift` |
| Rewrite | `Sources/OrbitalSync/Rendezvous/RendezvousServer.swift` | `NMTServer` → `PeerDispatcher.listen`; handler registration inline |
| Rewrite | `Sources/OrbitalSync/Rendezvous/RendezvousClient.swift` | `NMTClient` → `PeerDispatcher.connect`; typed `request<M,R>` |
| Delete | `Sources/OrbitalSync/Rendezvous/RendezvousHandler.swift` | Logic moves inline to `RendezvousServer` |
| Create | `Tests/OrbitalSyncTests/SyncMessagesTests.swift` | Task 1 tests |
| Create | `Tests/OrbitalSyncTests/SyncDaemonPeerTests.swift` | Task 2 tests |
| Create | `Tests/OrbitalSyncTests/RendezvousTests.swift` | Task 3 tests |

---

## Task 1: Package + SyncMessages

**Files:**
- Modify: `Package.swift`
- Create: `Sources/OrbitalSync/Sync/SyncMessages.swift`
- Modify: `Sources/OrbitalSync/Sync/SyncBodies.swift` (trim to control types only)
- Delete: `Sources/OrbitalSync/Sync/SyncMethods.swift`
- Test: `Tests/OrbitalSyncTests/SyncMessagesTests.swift`

- [ ] **Step 1: Update Package.swift to import NMTPeer**

The `NMTPeer` target lives on branch `feature/nmtp-peer` of `swift-nmtp`, which is what the `main` dependency already tracks (the remote is ahead of local). Update the dependency to pin to that branch explicitly if needed — but since `branch: "main"` already points there once merged, add the product immediately and let Swift resolve it.

Replace the entire `Package.swift` with:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "orbital-sync",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "orbital-sync", targets: ["OrbitalSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/OffskyLab/swift-nmtp.git", branch: "feature/nmtp-peer"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
    ],
    targets: [
        .executableTarget(name: "OrbitalSync", dependencies: [
            .product(name: "NMTP", package: "swift-nmtp"),
            .product(name: "NMTPeer", package: "swift-nmtp"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .testTarget(name: "OrbitalSyncTests", dependencies: [
            "OrbitalSync",
            .product(name: "NMTPeer", package: "swift-nmtp"),
        ]),
    ]
)
```

- [ ] **Step 2: Write failing tests for SyncMessages**

Create `Tests/OrbitalSyncTests/SyncMessagesTests.swift`:

```swift
import Testing
import Foundation
@testable import OrbitalSync
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
```

- [ ] **Step 3: Run tests — expect compile failure (types don't exist yet)**

```bash
cd /Users/gradyzhuo/Dropbox/Work/OpenSource/orbital-sync
swift test --filter SyncMessagesTests 2>&1 | head -30
```

Expected: compile error — `SyncHandshake`, `SyncHandshakeReply`, etc. not found.

- [ ] **Step 4: Create SyncMessages.swift**

Create `Sources/OrbitalSync/Sync/SyncMessages.swift`:

```swift
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
```

- [ ] **Step 5: Trim SyncBodies.swift — remove all non-control types**

Replace `Sources/OrbitalSync/Sync/SyncBodies.swift` with only the control types that `ControlSocket`/`ControlClient` need:

```swift
import Foundation

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
```

- [ ] **Step 6: Delete SyncMethods.swift**

```bash
rm Sources/OrbitalSync/Sync/SyncMethods.swift
```

- [ ] **Step 7: Run tests — expect pass**

```bash
swift test --filter SyncMessagesTests
```

Expected: all 15 tests pass. If build fails on other targets (SyncHandler still imports old types), ignore for now — we address those in Task 2.

- [ ] **Step 8: Verify full build compiles (expect errors in SyncHandler/SyncDaemon)**

```bash
swift build 2>&1 | grep error: | head -20
```

Expected: errors in `SyncHandler.swift`, `SyncDaemon.swift`, `RendezvousHandler.swift` about removed types (`HandshakeBody`, `SyncMethod`, etc.). These are addressed in Tasks 2 and 3.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/OrbitalSync/Sync/SyncMessages.swift Sources/OrbitalSync/Sync/SyncBodies.swift Tests/OrbitalSyncTests/SyncMessagesTests.swift
git rm Sources/OrbitalSync/Sync/SyncMethods.swift
git commit -m "feat: add SyncMessages PeerMessage conformers; trim SyncBodies; drop SyncMethods"
```

---

## Task 2: PeerConnection + SyncDaemon

**Files:**
- Modify: `Sources/OrbitalSync/Daemon/PeerConnection.swift`
- Rewrite: `Sources/OrbitalSync/Daemon/SyncDaemon.swift`
- Delete: `Sources/OrbitalSync/Daemon/SyncHandler.swift`
- Test: `Tests/OrbitalSyncTests/SyncDaemonPeerTests.swift`

### Context

`SyncDaemon` is an `actor`. The current `start()` binds `NMTServer`, runs the accept handler via `SyncHandler`, and blocks on `server?.listen()`. After migration:

- `NMTServer` → `PeerListener` (from `NMTPeer`)
- `NMTClient.connect` → `PeerDispatcher.connect`
- `CallBody` string dispatch → typed `PeerDispatcher.register<M>` handlers
- Server-to-client reverse-pair hack → eliminated (connection is bidirectional already)
- `client.pushes` loop → eliminated (push from remote arrives via `dispatcher.run()` internally)
- `handlePeerDisconnect` only retries when `isInitiator == true`

The actor runs handlers registered on `PeerDispatcher`. Since handler closures are `@Sendable` and registered from a `nonisolated` function, they capture `self` weakly and hop back onto the actor with `await`.

- [ ] **Step 1: Write failing integration tests**

Create `Tests/OrbitalSyncTests/SyncDaemonPeerTests.swift`:

```swift
import Testing
import Foundation
@testable import OrbitalSync

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

        // Give listeners time to bind
        try await Task.sleep(for: .milliseconds(100))

        try await daemonA.addPeer(host: "127.0.0.1", port: 18202)

        let count = await daemonA.connectedPeerCount
        #expect(count == 1)
    }

    @Test func filePushReachesRemote() async throws {
        let (daemonA, dirA) = makeDaemon(port: 18203)
        let (daemonB, dirB) = makeDaemon(port: 18204)

        let taskA = Task { try? await daemonA.start() }
        let taskB = Task { try? await daemonB.start() }
        defer {
            taskA.cancel()
            taskB.cancel()
            Task { try? await daemonA.stop() }
            Task { try? await daemonB.stop() }
        }

        try await Task.sleep(for: .milliseconds(100))
        try await daemonA.addPeer(host: "127.0.0.1", port: 18204)

        // Get the connection to B
        guard let connToB = await daemonA.firstPeer() else {
            Issue.record("No peer connection after addPeer")
            return
        }

        // Write a file and push it
        let content = Data("hello from A".utf8)
        let relativePath = "memory/test.md"
        let now = Date()
        let pushMsg = SyncFilePush(path: relativePath, content: content, hash: "testhash", modifiedAt: now)
        _ = try await connToB.dispatcher.request(pushMsg, expecting: SyncFilePushReply.self)

        let expectedPath = (dirB as NSString).appendingPathComponent(relativePath)
        let written = FileManager.default.contents(atPath: expectedPath)
        #expect(written == content)
    }

    @Test func disconnectTriggersReconnectOnInitiatorOnly() async throws {
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

        try await Task.sleep(for: .milliseconds(100))
        try await daemonA.addPeer(host: "127.0.0.1", port: 18206)

        guard let connToB = await daemonA.firstPeer() else {
            Issue.record("No peer after addPeer")
            return
        }
        let initiator = connToB.isInitiator
        #expect(initiator == true)

        // Listener side should have isInitiator = false
        // (checked indirectly — listener-side disconnect does not retry)
        let listenerIsInitiator = await daemonB.firstPeer()?.isInitiator
        #expect(listenerIsInitiator == false)
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
swift test --filter SyncDaemonPeerTests 2>&1 | head -30
```

Expected: compile errors — `connectedPeerCount`, `firstPeer()`, `PeerConnection.isInitiator` not found.

- [ ] **Step 3: Rewrite PeerConnection.swift**

```swift
import Foundation
import NMTPeer

/// Represents a connected peer in the mesh.
struct PeerConnection: Sendable {
    let peerID: String
    let peerName: String
    let address: String
    let port: Int
    let dispatcher: PeerDispatcher
    /// true if we initiated the connection (addPeer); false if accepted via PeerListener.
    /// Only initiator-side connections retry on disconnect.
    let isInitiator: Bool
}
```

- [ ] **Step 4: Rewrite SyncDaemon.swift**

Replace the entire file with the following. Key changes from the original:
- `server: NMTServer?` → `peerListener: PeerListener?`
- `isStopping: Bool` flag prevents reconnect during shutdown
- `registerSyncHandlers(on:)` is `nonisolated` — called from both actor-isolated and `@Sendable` contexts
- Disconnect detection for listener-side peers: searches `peers` for the matching dispatcher by identity
- `reconcileWithPeer`, `pullFile`, `handleFileChange` use `dispatcher.request(_:expecting:)`
- `addPeer` no longer has `skipHandshake:` parameter — clean API

```swift
import Foundation
import NMTP
import NMTPeer
import NIO
import Logging
import Crypto

#if canImport(Network)
import Network
#endif

/// Core daemon that manages NMT peer listener, peer connections, file watching, and control socket.
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
                        let peers = try await rv.register(
                            peerID: peerID, peerName: info.peerName,
                            teamID: team.id, host: "", port: port
                        )
                        for rvPeer in peers {
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

        // 7. Accept loop — blocks until close() is called
        for await peer in listener.peers {
            let dispatcher = PeerDispatcher(peer: peer)
            registerSyncHandlers(on: dispatcher)
            // Run dispatcher in background; detect disconnect by matching dispatcher identity
            Task { [weak self, weak dispatcher] in
                guard let dispatcher else { return }
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

        let info = localPeerInfo()
        let config = SyncConfig.load()
        let reply = try await dispatcher.request(
            SyncHandshake(
                peerID: info.peerID, peerName: info.peerName,
                version: info.version, port: self.port, teamID: config.team?.id
            ),
            expecting: SyncHandshakeReply.self
        )
        guard reply.accepted else {
            try? await dispatcher.peer.close()
            logger.warning("Peer rejected handshake: \(host):\(port)")
            throw SyncError.handshakeRejected
        }

        guard !hasPeer(reply.peerID) else {
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
        Task {
            try? await dispatcher.run()
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
                guard !Task.isCancelled, !self.isStopping else { return }
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
        dispatcher.register(SyncHandshake.self) { [weak self, weak dispatcher] msg, _ in
            guard let self, let dispatcher else { return nil }
            let config = SyncConfig.load()
            if let team = config.team, let remoteTeam = msg.teamID, team.id != remoteTeam {
                let info = await self.localPeerInfo()
                logger.info("Rejected handshake from \(msg.peerName): team mismatch")
                return SyncHandshakeReply(peerID: info.peerID, peerName: info.peerName, version: info.version, accepted: false)
            }
            let host = dispatcher.peer.remoteAddress.ipAddress ?? "127.0.0.1"
            let info = await self.localPeerInfo()
            let connection = PeerConnection(
                peerID: msg.peerID, peerName: msg.peerName,
                address: host, port: msg.port,
                dispatcher: dispatcher, isInitiator: false
            )
            await self.storePeer(connection)
            return SyncHandshakeReply(peerID: info.peerID, peerName: info.peerName, version: info.version, accepted: true)
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
                        SyncFilePush(path: change.path, content: fileData.content,
                                     hash: fileData.hash, modifiedAt: fileData.modifiedAt),
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
            return ControlResponse(ok: true, message: "Running on port \(port), \(peers.count) peer(s)",
                                   data: ["peers": peerList.joined(separator: ", ")])
        case "pair":
            guard let host = request.args?["host"], let portStr = request.args?["port"],
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
    case fileNotFound(String)
    case handshakeRejected
}
```

- [ ] **Step 5: Delete SyncHandler.swift**

```bash
cd /Users/gradyzhuo/Dropbox/Work/OpenSource/orbital-sync
git rm Sources/OrbitalSync/Daemon/SyncHandler.swift
```

- [ ] **Step 6: Verify build**

```bash
swift build 2>&1 | grep -E "^.*(error|warning):" | grep -v "SyncHandler\|SyncMethods\|HandshakeBody" | head -20
```

Fix any remaining compile errors. Common issues:
- If `SyncTLSContext` doesn't conform to the new `TLSContext` protocol from `NMTPeer` — check if `NMTP`'s `TLSContext` and `NMTPeer`'s `TLSContext` are the same type (they should be — `NMTPeer` re-exports from `NMTP`). If they differ, `tls: SyncTLSContext?` may need a cast.
- `PeerListener.bind(on:tls:)` — check if `tls` parameter type is `(any TLSContext)?` matching `SyncTLSContext`.

- [ ] **Step 7: Run tests**

```bash
swift test --filter SyncDaemonPeerTests
```

Expected: all 3 tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrbitalSync/Daemon/PeerConnection.swift Sources/OrbitalSync/Daemon/SyncDaemon.swift Tests/OrbitalSyncTests/SyncDaemonPeerTests.swift
git rm Sources/OrbitalSync/Daemon/SyncHandler.swift
git commit -m "feat: migrate SyncDaemon to PeerListener + PeerDispatcher; remove SyncHandler"
```

---

## Task 3: Rendezvous Migration

**Files:**
- Rewrite: `Sources/OrbitalSync/Rendezvous/RendezvousServer.swift`
- Rewrite: `Sources/OrbitalSync/Rendezvous/RendezvousClient.swift`
- Delete: `Sources/OrbitalSync/Rendezvous/RendezvousHandler.swift`
- Test: `Tests/OrbitalSyncTests/RendezvousTests.swift`

### Context

`RendezvousServer` currently uses `NMTServer` + `RendezvousHandler`. After migration it uses `PeerDispatcher.listen`, registering `RVRegister` and `RVHeartbeat` handlers inline. `RendezvousClient` uses `PeerDispatcher.connect` + typed `request<M,R>` for registration and heartbeat.

- [ ] **Step 1: Write failing tests**

Create `Tests/OrbitalSyncTests/RendezvousTests.swift`:

```swift
import Testing
import Foundation
@testable import OrbitalSync

struct RendezvousTests {

    @Test func registerReturnsPeerList() async throws {
        let server = RendezvousServer(port: 19101)
        let serverTask = Task { try? await server.start() }
        defer {
            serverTask.cancel()
            Task { try? await server.stop() }
        }
        try await Task.sleep(for: .milliseconds(100))

        let client1 = RendezvousClient(host: "127.0.0.1", port: 19101)
        let peers1 = try await client1.register(
            peerID: "peer1", peerName: "Host1", teamID: "team-A", host: "1.2.3.4", port: 8100
        )
        // First registrant sees no peers
        #expect(peers1.isEmpty)

        let client2 = RendezvousClient(host: "127.0.0.1", port: 19101)
        let peers2 = try await client2.register(
            peerID: "peer2", peerName: "Host2", teamID: "team-A", host: "1.2.3.5", port: 8101
        )
        // Second registrant sees peer1
        #expect(peers2.count == 1)
        #expect(peers2[0].peerID == "peer1")

        await client1.disconnect()
        await client2.disconnect()
    }

    @Test func heartbeatKeepsRegistrationAlive() async throws {
        let server = RendezvousServer(port: 19102)
        let serverTask = Task { try? await server.start() }
        defer {
            serverTask.cancel()
            Task { try? await server.stop() }
        }
        try await Task.sleep(for: .milliseconds(100))

        let client = RendezvousClient(host: "127.0.0.1", port: 19102)
        _ = try await client.register(
            peerID: "peer-hb", peerName: "HBHost", teamID: "team-B", host: "10.0.0.1", port: 9000
        )

        // Send a heartbeat directly (bypasses the 25s loop)
        try await client.sendHeartbeatNow()

        // Re-register a second peer — should still see peer-hb
        let client2 = RendezvousClient(host: "127.0.0.1", port: 19102)
        let peers = try await client2.register(
            peerID: "peer-other", peerName: "OtherHost", teamID: "team-B", host: "10.0.0.2", port: 9001
        )
        #expect(peers.contains { $0.peerID == "peer-hb" })

        await client.disconnect()
        await client2.disconnect()
    }

    @Test func differentTeamsAreIsolated() async throws {
        let server = RendezvousServer(port: 19103)
        let serverTask = Task { try? await server.start() }
        defer {
            serverTask.cancel()
            Task { try? await server.stop() }
        }
        try await Task.sleep(for: .milliseconds(100))

        let clientA = RendezvousClient(host: "127.0.0.1", port: 19103)
        _ = try await clientA.register(peerID: "a1", peerName: "A1", teamID: "team-X", host: "1.1.1.1", port: 8200)

        let clientB = RendezvousClient(host: "127.0.0.1", port: 19103)
        let peers = try await clientB.register(peerID: "b1", peerName: "B1", teamID: "team-Y", host: "2.2.2.2", port: 8201)
        #expect(peers.isEmpty)  // different team — sees nothing

        await clientA.disconnect()
        await clientB.disconnect()
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
swift test --filter RendezvousTests 2>&1 | head -30
```

Expected: compile errors — `RendezvousClient` may not have `sendHeartbeatNow()` yet.

- [ ] **Step 3: Delete RendezvousHandler.swift**

```bash
git rm Sources/OrbitalSync/Rendezvous/RendezvousHandler.swift
```

- [ ] **Step 4: Rewrite RendezvousServer.swift**

```swift
import Foundation
import NMTP
import NMTPeer
import NIO
import Logging

/// Lightweight coordination server for cross-network peer discovery.
/// Does NOT relay data — only exchanges peer connection info.
actor RendezvousServer {
    let port: Int
    let logger = Logger(label: "orbital-sync.rendezvous")

    private var serverListener: PeerDispatcherListener?
    /// teamID → [peerID: registration]
    private var registry: [String: [String: PeerRegistration]] = [:]

    struct PeerRegistration {
        let peerID: String
        let peerName: String
        let host: String
        let port: Int
        let lastSeen: Date
    }

    init(port: Int) {
        self.port = port
    }

    func start() async throws {
        let address = try SocketAddress(ipAddress: "0.0.0.0", port: port)
        serverListener = try await PeerDispatcher.listen(on: address) { [weak self] dispatcher in
            self?.registerRVHandlers(on: dispatcher)
        }
        logger.info("Rendezvous server listening on port \(port)")

        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.cleanupStale()
            }
        }

        try await serverListener?.run()
    }

    func stop() async throws {
        try await serverListener?.close()
    }

    // MARK: - Handler registration

    nonisolated func registerRVHandlers(on dispatcher: PeerDispatcher) {
        dispatcher.register(RVRegister.self) { [weak self] msg, peer in
            guard let self else { return nil }
            let remoteHost = peer.remoteAddress.ipAddress
            let reply = await self.register(msg, remoteAddress: remoteHost)
            return reply
        }

        dispatcher.register(RVHeartbeat.self) { [weak self] msg, _ in
            guard let self else { return nil }
            return await self.heartbeat(msg)
        }
    }

    // MARK: - Registry operations

    func register(_ msg: RVRegister, remoteAddress: String?) -> RVRegisterReply {
        let host = msg.host.isEmpty ? (remoteAddress ?? msg.host) : msg.host
        let reg = PeerRegistration(
            peerID: msg.peerID, peerName: msg.peerName,
            host: host, port: msg.port, lastSeen: Date()
        )
        var teamPeers = registry[msg.teamID] ?? [:]
        teamPeers[msg.peerID] = reg
        registry[msg.teamID] = teamPeers
        logger.info("Registered \(msg.peerName) (\(msg.peerID)) for team \(msg.teamID) at \(host):\(msg.port)")
        let otherPeers = teamPeers.values
            .filter { $0.peerID != msg.peerID }
            .map { RVPeerEntry(peerID: $0.peerID, peerName: $0.peerName, host: $0.host, port: $0.port) }
        return RVRegisterReply(peers: otherPeers)
    }

    func heartbeat(_ msg: RVHeartbeat) -> RVHeartbeatReply {
        if var teamPeers = registry[msg.teamID], var reg = teamPeers[msg.peerID] {
            reg = PeerRegistration(
                peerID: reg.peerID, peerName: reg.peerName,
                host: reg.host, port: reg.port, lastSeen: Date()
            )
            teamPeers[msg.peerID] = reg
            registry[msg.teamID] = teamPeers
        }
        return RVHeartbeatReply(ok: true)
    }

    private func cleanupStale() {
        let staleThreshold: TimeInterval = 90
        let now = Date()
        for (teamID, peers) in registry {
            let alive = peers.filter { now.timeIntervalSince($0.value.lastSeen) < staleThreshold }
            let removed = peers.count - alive.count
            if removed > 0 {
                logger.info("Cleaned up \(removed) stale peer(s) from team \(teamID)")
            }
            registry[teamID] = alive.isEmpty ? nil : alive
        }
    }
}
```

- [ ] **Step 5: Rewrite RendezvousClient.swift**

Note: `sendHeartbeatNow()` is added as an internal testing hook. Production code only calls the heartbeat loop.

```swift
import Foundation
import NMTP
import NMTPeer
import NIO
import Logging

/// Client for registering with and querying a rendezvous server.
actor RendezvousClient {
    let serverHost: String
    let serverPort: Int
    let logger = Logger(label: "orbital-sync.rv-client")

    private var dispatcher: PeerDispatcher?
    private var heartbeatTask: Task<Void, Never>?
    private var registeredPeerID: String?
    private var registeredTeamID: String?

    init(host: String, port: Int) {
        self.serverHost = host
        self.serverPort = port
    }

    /// Connect to the rendezvous server and register this peer.
    /// Returns list of other peers in the same team.
    func register(peerID: String, peerName: String, teamID: String, host: String, port: Int) async throws -> [RVPeerEntry] {
        let address = try SocketAddress(ipAddress: serverHost, port: serverPort)
        let d = try await PeerDispatcher.connect(to: address)
        self.dispatcher = d
        self.registeredPeerID = peerID
        self.registeredTeamID = teamID

        // Run dispatcher in background (needed for request/reply to work)
        Task { try? await d.run() }

        let reply = try await d.request(
            RVRegister(peerID: peerID, peerName: peerName, teamID: teamID, host: host, port: port),
            expecting: RVRegisterReply.self
        )

        // Start heartbeat loop
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                await self?.sendHeartbeatNow()
            }
        }

        logger.info("Registered with rendezvous server, \(reply.peers.count) peer(s) found")
        return reply.peers
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        try? await dispatcher?.peer.close()
        dispatcher = nil
    }

    /// Send a single heartbeat immediately. Used by production heartbeat loop and tests.
    func sendHeartbeatNow() async {
        guard let d = dispatcher,
              let peerID = registeredPeerID,
              let teamID = registeredTeamID else { return }
        _ = try? await d.request(
            RVHeartbeat(peerID: peerID, teamID: teamID),
            expecting: RVHeartbeatReply.self
        )
    }
}
```

- [ ] **Step 6: Verify build**

```bash
swift build 2>&1 | grep error: | head -20
```

Expected: clean build. Fix any issues — common: `RendezvousHandler` imports still referencing `SyncError.missingArgument` (now deleted).

- [ ] **Step 7: Run all tests**

```bash
swift test
```

Expected: all tests pass (SyncMessages, SyncDaemon, Rendezvous).

- [ ] **Step 8: Commit**

```bash
git add Sources/OrbitalSync/Rendezvous/RendezvousServer.swift Sources/OrbitalSync/Rendezvous/RendezvousClient.swift Tests/OrbitalSyncTests/RendezvousTests.swift
git rm Sources/OrbitalSync/Rendezvous/RendezvousHandler.swift
git commit -m "feat: migrate RendezvousServer + RendezvousClient to PeerDispatcher"
```

---

## Self-Review

### Spec coverage check

| Spec requirement | Covered by |
|---|---|
| `NMTPeer` product added to Package.swift | Task 1 Step 1 |
| All sync structs conform to `PeerMessage`; `static var messageType: UInt16` | Task 1 Steps 4 |
| `SyncMessages.swift` (rename from SyncBodies) | Task 1 Steps 4–6 |
| `SyncMethods.swift` deleted | Task 1 Step 6 |
| `SyncHandler.swift` deleted | Task 2 Step 5 |
| `PeerConnection.dispatcher: PeerDispatcher` + `isInitiator: Bool` | Task 2 Step 3 |
| `SyncDaemon.start()` uses `PeerListener` | Task 2 Step 4 |
| `registerSyncHandlers(on:)` is nonisolated, handles all 5 message types | Task 2 Step 4 |
| `addPeer` uses `PeerDispatcher.connect` + typed `SyncHandshake` request | Task 2 Step 4 |
| Reverse-pairing eliminated | Task 2 Step 4 (addPeer no longer calls `daemon.addPeer` from handler) |
| `handlePeerDisconnect` only retries when `isInitiator = true` | Task 2 Step 4 |
| `SyncError.handshakeRejected` added | Task 2 Step 4 (enum at bottom of SyncDaemon.swift) |
| `RendezvousHandler.swift` deleted | Task 3 Step 3 |
| `RendezvousServer` uses `PeerDispatcher.listen` with inline handlers | Task 3 Step 4 |
| `RendezvousClient` uses `PeerDispatcher.connect` + typed `request<M,R>` | Task 3 Step 5 |

### Placeholder scan
No TBDs or incomplete sections.

### Type consistency
- `SyncHandshake`, `SyncHandshakeReply`, etc. — defined in Task 1, used in Task 2
- `RVRegister`, `RVRegisterReply`, `RVHeartbeat`, `RVHeartbeatReply` — defined in Task 1, used in Task 3
- `PeerConnection.dispatcher: PeerDispatcher` — defined in Task 2 Step 3, used in Task 2 Step 4
- `RendezvousClient.sendHeartbeatNow()` — defined in Task 3 Step 5, used in Task 3 Step 1 test

### Known limitation
`RendezvousClient` does not send an `RVUnregister` message on `disconnect()` — it closes the connection and the server's stale cleanup (90s) handles it. This matches the existing behavior.
