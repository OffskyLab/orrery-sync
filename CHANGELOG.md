# Changelog

## v1.0.0

Initial release.

- **NMT P2P daemon** — bidirectional real-time sync over NMT protocol
- **Memory-only sync** — syncs `~/.orbital/shared/memory/`, not sessions
- **File sync** — manifest reconcile + live push for create/modify/delete
- **FileWatcher** — FSEvents on macOS, polling fallback on Linux
- **Team management** — create, invite, join, info
- **mDNS/Bonjour discovery** — auto-find peers on same LAN (macOS)
- **Rendezvous server** — cross-network peer discovery
- **mTLS** — optional encrypted peer communication via SyncTLSContext
- **Graceful reconnect** — exponential backoff on peer disconnect
- **Unix domain socket** — CLI ↔ daemon control
- **Persistent config** — `~/.orbital/sync-config.json` for team + known peers
- **SHA256 file hashing** — reliable change detection
- **CLAUDE.md** — development guidelines
