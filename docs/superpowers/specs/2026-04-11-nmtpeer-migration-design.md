# orrery-sync: NMTPeer Migration Design

> **For agentic workers:** Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this spec.

**Goal:** Migrate `orrery-sync` from the asymmetric `NMTServer`/`NMTClient`/`NMTHandler` architecture to the symmetric `NMTPeer`/`PeerDispatcher` layer. This is a clean-break migration — no backward compatibility with v1.x wire format.

**Architecture:** Replace string-based method dispatch (`CallBody(method:arguments:)`) with typed `PeerMessage` conformers identified by `UInt16` messageType. `PeerDispatcher.listen` replaces `NMTServer` + `SyncHandler`. `PeerDispatcher.connect` replaces `NMTClient`. Reverse-pairing is eliminated — NMTPeer is symmetric, so both sides of a connection hold a `Peer` and can request/reply bidirectionally. Rendezvous server follows the same pattern.

**Tech Stack:** Swift 6, `NMTPeer` target (swift-nmtp), `Synchronization.Mutex`, `Foundation` (JSONEncoder/JSONDecoder via PeerMessage/Codable)

---

## What Changes

### Deleted files

| File | Reason |
|------|--------|
| `Sources/OrrerySync/Sync/SyncMethods.swift` | String method constants replaced by `UInt16` messageType on each `PeerMessage` conformer |
| `Sources/OrrerySync/Daemon/SyncHandler.swift` | Handler logic moves into `SyncDaemon` as `PeerDispatcher.register` calls |
| `Sources/OrrerySync/Rendezvous/RendezvousHandler.swift` | Same — logic moves into `RendezvousServer` |

### Modified/rewritten files

| File | Change |
|------|--------|
| `Package.swift` | Add `NMTPeer` product dependency from `swift-nmtp` |
| `Sources/OrrerySync/Sync/SyncBodies.swift` | All structs conform to `PeerMessage`; add `static var messageType: UInt16`; rename to `SyncMessages.swift` |
| `Sources/OrrerySync/Daemon/PeerConnection.swift` | `client: NMTClient` → `dispatcher: PeerDispatcher`; add `isInitiator: Bool` |
| `Sources/OrrerySync/Daemon/SyncDaemon.swift` | Major refactor (see below) |
| `Sources/OrrerySync/Rendezvous/RendezvousServer.swift` | `NMTServer` → `PeerDispatcher.listen`; register RV handlers inline |
| `Sources/OrrerySync/Rendezvous/RendezvousClient.swift` | `NMTClient` → `PeerDispatcher.connect` + typed `request<M,R>` |

---

## Message Types

### Sync namespace (`0x00xx`)

| Type ID | Swift type | Direction | Purpose |
|---------|-----------|-----------|---------|
| `0x0001` | `SyncHandshake` | connector → listener | Identity exchange (peerID, peerName, version, port, teamID) |
| `0x0002` | `SyncHandshakeReply` | reply | Accept/reject with local peer info |
| `0x0003` | `SyncManifestRequest` | either → either | Request peer's file manifest |
| `0x0004` | `SyncManifestReply` | reply | Return manifest |
| `0x0005` | `SyncFilePull` | either → either | Request a specific file |
| `0x0006` | `SyncFilePullReply` | reply | Return file content |
| `0x0007` | `SyncFilePush` | either → either | Push file content to peer |
| `0x0008` | `SyncFilePushReply` | reply | Acknowledge receipt |
| `0x0009` | `SyncFileDelete` | either → either | Notify peer to delete file |
| `0x000A` | `SyncFileDeleteReply` | reply | Acknowledge deletion |

### Rendezvous namespace (`0x01xx`)

| Type ID | Swift type | Direction | Purpose |
|---------|-----------|-----------|---------|
| `0x0101` | `RVRegister` | client → server | Register peer and get current peer list |
| `0x0102` | `RVRegisterReply` | reply | List of known peers |
| `0x0103` | `RVHeartbeat` | client → server | Keep registration alive |
| `0x0104` | `RVHeartbeatReply` | reply | Ack |
| `0x0105` | `RVUnregister` | client → server | Remove registration on clean disconnect |

---

## Public API Changes

### PeerConnection

```swift
struct PeerConnection: Sendable {
    let peerID: String
    let peerName: String
    let address: String
    let port: Int
    let dispatcher: PeerDispatcher
    let isInitiator: Bool   // true = we connected out; retry on disconnect
}
```

### SyncDaemon — listener setup

```swift
// start()
let serverListener = try await PeerDispatcher.listen(
    on: SocketAddress(ipAddress: "0.0.0.0", port: port),
    tls: tls
) { [weak self] dispatcher in
    self?.registerSyncHandlers(on: dispatcher)
}
Task { try? await serverListener.run() }
```

`registerSyncHandlers(on dispatcher: PeerDispatcher)` captures `dispatcher` in each handler closure. The `SyncHandshake` handler uses the captured `dispatcher` to build `PeerConnection` and store it in `peers`:

```swift
func registerSyncHandlers(on dispatcher: PeerDispatcher) {
    dispatcher.register(SyncHandshake.self) { [weak self] msg, _ in
        guard let self else { return nil }
        // validate team ...
        let connection = PeerConnection(
            peerID: msg.peerID, peerName: msg.peerName,
            address: dispatcher.peer.remoteAddress.ipAddress ?? "",
            port: msg.port,
            dispatcher: dispatcher, isInitiator: false
        )
        await self.storePeer(connection)
        return SyncHandshakeReply(peerID: peerID, peerName: hostname, version: version, accepted: true)
    }
    // ... other handlers
}
```

`registerSyncHandlers` registers:
- `SyncManifestRequest` — build + return manifest
- `SyncFilePull` — read + return file
- `SyncFilePush` — write file locally
- `SyncFileDelete` — delete file locally

### SyncDaemon — connect to peer

```swift
func addPeer(host: String, port: Int) async throws {
    let address = try SocketAddress(ipAddress: host, port: port)
    let dispatcher = try await PeerDispatcher.connect(to: address, tls: tls)
    registerSyncHandlers(on: dispatcher)   // symmetric — same handlers

    // Send handshake first — peerID comes from reply
    let reply = try await dispatcher.request(
        SyncHandshake(peerID: peerID, peerName: hostname, version: version,
                      port: port, teamID: config.team?.id),
        expecting: SyncHandshakeReply.self
    )
    guard reply.accepted else { throw SyncError.handshakeRejected }

    let remotePeerID = reply.peerID
    let remotePeerName = reply.peerName
    // Task: run dispatcher; on return → peer disconnected
    Task {
        try? await dispatcher.run()
        await handlePeerDisconnect(peerID: remotePeerID, peerName: remotePeerName, host: host, port: port)
    }

    let connection = PeerConnection(
        peerID: reply.peerID, peerName: reply.peerName,
        address: host, port: port,
        dispatcher: dispatcher, isInitiator: true
    )
    peers[reply.peerID] = connection
}
```

### SyncDaemon — file push

```swift
// Before
_ = try await peer.client.request(matter: Matter.make(type: .call, body: callBody))

// After
_ = try await peer.dispatcher.request(SyncFilePush(...), expecting: SyncFilePushReply.self)
_ = try await peer.dispatcher.request(SyncFileDelete(...), expecting: SyncFileDeleteReply.self)
```

### Reverse-pairing eliminated

`SyncHandler.handleHandshake` currently creates an outbound `NMTClient` connection back to the connector. This is **deleted**. The listener side's `SyncHandshake` handler simply validates the peer and registers the already-existing `dispatcher` in `peers`. No outbound connection needed.

---

## Connection Lifecycle

```
Connector (A):
  PeerDispatcher.connect → SyncHandshake → SyncHandshakeReply
  → store in peers[peerID]
  → run() in Task (returns on disconnect)
  → handlePeerDisconnect → retry with backoff (isInitiator = true)

Listener (B):
  PeerDispatcher.listen → per-peer configure block
  → run() in Task (returns on disconnect)
  → SyncHandshake received → store dispatcher in peers[peerID]
  → handlePeerDisconnect → no retry (isInitiator = false)
```

---

## Rendezvous

### RendezvousServer

```swift
actor RendezvousServer {
    private var serverListener: PeerDispatcherListener?

    func start() async throws {
        serverListener = try await PeerDispatcher.listen(
            on: SocketAddress(ipAddress: "0.0.0.0", port: port)
        ) { [weak self] dispatcher in
            self?.registerRVHandlers(on: dispatcher)
        }
        Task { try? await serverListener?.run() }
    }
}
```

`registerRVHandlers` registers: `RVRegister`, `RVHeartbeat`, `RVUnregister`.

### RendezvousClient

```swift
let dispatcher = try await PeerDispatcher.connect(to: rvAddress)
Task { try? await dispatcher.run() }

let reply = try await dispatcher.request(
    RVRegister(peerID: peerID, peerName: peerName, teamID: teamID, host: host, port: port),
    expecting: RVRegisterReply.self
)
// reply.peers contains known peers to connect to
```

---

## Error Handling

- `SyncError.handshakeRejected` — new case; thrown when `SyncHandshakeReply.accepted == false`
- `NMTPError.timeout` — request timeout (unchanged)
- `NMTPError.connectionClosed` — peer disconnected mid-request (unchanged)
- Decode errors in dispatcher — logged and dropped (PeerDispatcher default behaviour)

---

## What This Spec Does NOT Cover

- Reconnection strategy changes (backoff logic unchanged from v1)
- Bonjour/mDNS discovery (`BonjourDiscovery` — unchanged, no NMT dependency)
- Control socket (`ControlSocket`/`ControlClient` — unchanged, uses Unix domain socket)
- TLS setup (`SyncTLSContext` — unchanged, implements `TLSContext` protocol)
- Version negotiation (clean break, no negotiation needed)

---

## Testing

Integration tests in `Tests/OrrerySyncTests/`:

### Task 1 (Package + Messages)
- `SyncMessages`: each struct has correct `messageType`, conforms to `PeerMessage`, round-trips through `JSONEncoder`/`JSONDecoder`

### Task 2 (SyncDaemon peer connection)
- Two in-process `SyncDaemon` instances connect to each other; handshake succeeds
- File push from A reaches B (handler called, file written)
- Disconnect triggers reconnect logic on initiator side only

### Task 3 (Rendezvous)
- `RendezvousServer` accepts registration, returns peer list
- `RendezvousClient` heartbeat keeps registration alive; unregister removes it
