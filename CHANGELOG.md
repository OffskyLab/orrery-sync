# Changelog

## v2.0.0

orbital-sync has been renamed to **orrery-sync** and forked to
`OffskyLab/orrery-sync`, matching the rename of Orbital → Orrery. No feature
changes — the entire diff is the rename.

**Breaking:**
- Daemon binary: `orbital-sync` → `orrery-sync`
- Swift module: `OrbitalSync` → `OrrerySync`
- Default sync directory: `~/.orbital/shared/memory/` → `~/.orrery/shared/memory/`
- Config file: `~/.orbital/sync-config.json` → `~/.orrery/sync-config.json`

Existing users should rely on Orrery's automatic `~/.orbital/` → `~/.orrery/`
migration (which moves the sync config too); stop the old daemon with
`orbital sync stop` before upgrading.

## v1.0.0

Initial release.

- **NMT P2P daemon** — bidirectional real-time sync over NMT protocol
- **Memory-only sync** — syncs `~/.orrery/shared/memory/`, not sessions
- **File sync** — manifest reconcile + live push for create/modify/delete
- **FileWatcher** — FSEvents on macOS, polling fallback on Linux
- **Team management** — create, invite, join, info
- **mDNS/Bonjour discovery** — auto-find peers on same LAN (macOS)
- **Rendezvous server** — cross-network peer discovery
- **mTLS** — optional encrypted peer communication via SyncTLSContext
- **Graceful reconnect** — exponential backoff on peer disconnect
- **Unix domain socket** — CLI ↔ daemon control
- **Persistent config** — `~/.orrery/sync-config.json` for team + known peers
- **SHA256 file hashing** — reliable change detection
- **CLAUDE.md** — development guidelines
