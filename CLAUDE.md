# orrery-sync — Development Guidelines

## Versioning

- orrery-sync and Orrery share the same version number (e.g. both at 1.0.0).
- When bumping version, update both repos together.
- Version locations in this repo:
  - `Sources/OrrerySync/OrrerySync.swift` — `version:` field
  - `CHANGELOG.md`

## Release Checklist

1. Bump version in all locations above
2. Update `CHANGELOG.md`
3. Commit and push
4. Tag `vX.Y.Z` and push tag (triggers CI)
5. Wait for CI to complete
6. Update `homebrew-orrery/Formula/orrery-sync.rb` with new sha256
7. Push homebrew formula

## Architecture

- Built on `swift-nmtp` (NMT protocol) for P2P communication
- `SyncDaemon` — core actor: NMT server + control socket + file watcher + peer management
- `SyncHandler` — implements `NMTHandler`, processes sync RPC calls
- `ControlSocket` / `ControlClient` — Unix domain socket for CLI ↔ daemon
- `BonjourDiscovery` — mDNS/Bonjour (macOS only, gated by `canImport(Network)`)
- `RendezvousServer` / `RendezvousClient` — cross-network peer discovery
- `SyncTLSContext` — implements NMTP's `TLSContext` protocol for mTLS
- Only syncs `memory/` — sessions are machine-specific

## Naming

- Follow NMTP conventions: transmission unit is **Matter**, not message/packet/frame
- Sync methods use `sync.*` namespace (e.g. `sync.handshake`, `sync.file.push`)
- Rendezvous methods use `rv.*` namespace (e.g. `rv.register`, `rv.heartbeat`)

## Cross-platform

- macOS: FSEvents for file watching, Network framework for Bonjour
- Linux: polling fallback for file watching, manual pairing only (no Bonjour)
- `SOCK_STREAM` needs `Int32(SOCK_STREAM.rawValue)` on Linux (Glibc)
- `sockaddr.sa_len` does not exist on Linux — use `MemoryLayout<sockaddr_in>.size`
