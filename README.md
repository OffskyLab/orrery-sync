# orrery-sync

P2P real-time sync daemon for [Orrery](https://github.com/OffskyLab/Orrery). Keeps `~/.orrery/shared/` in sync across multiple machines — sessions, memory, and environment config.

Built on [NMT protocol](https://github.com/OffskyLab/swift-nmtp) (Nebula Matter Transfer).

## Install

### Homebrew (macOS / Linux)

```bash
brew install OffskyLab/orrery/orrery-sync
```

### APT (Ubuntu / Debian)

```bash
curl -fsSL https://offskylab.github.io/apt/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/offskylab.gpg
echo "deb [signed-by=/usr/share/keyrings/offskylab.gpg] https://offskylab.github.io/apt stable main" | sudo tee /etc/apt/sources.list.d/offskylab.list
sudo apt update && sudo apt install orrery-sync
```

### From source

```bash
git clone https://github.com/OffskyLab/orrery-sync.git
cd orrery-sync
swift build -c release
cp .build/release/orrery-sync ~/.orrery/bin/
```

## Quick start

### Two machines, same Wi-Fi

```bash
# Machine A
orrery-sync daemon --port 9527

# Machine B
orrery-sync pair 192.168.1.100:9527
orrery-sync daemon --port 9528
```

Bonjour auto-discovery is enabled by default on macOS — peers on the same LAN find each other automatically.

### With Orrery CLI

All commands work through `orrery sync`:

```bash
orrery sync daemon --port 9527
orrery sync status
orrery sync pair 192.168.1.100:9527
```

## Usage patterns

### Personal: desktop + laptop

Both machines on the same network. Start the daemon on each — Bonjour handles the rest:

```bash
# Desktop
orrery-sync daemon --port 9527

# Laptop
orrery-sync daemon --port 9528
# → auto-discovers desktop via Bonjour, syncs immediately
```

### Team collaboration

Create a team so only authorized peers can connect:

```bash
# Alice creates team and generates invite
orrery-sync team create frontend-team
orrery-sync team invite --port 9527
# → prints a base64 invite code, share via Slack/email

# Alice starts daemon
orrery-sync daemon --port 9527

# Bob joins
orrery-sync team join <invite-code>
orrery-sync daemon --port 9528
# → auto-connects to Alice, pulls all existing memory

# Charlie joins
orrery-sync team join <invite-code>
orrery-sync daemon --port 9529
# → full mesh: all three peers connected
```

### Cross-network (rendezvous)

For peers on different networks (different offices, home + office):

```bash
# Run rendezvous on a VPS or cloud server
orrery-sync rendezvous --port 9600

# Each peer connects through it
orrery-sync daemon --port 9527 --rendezvous rv.example.com:9600
orrery-sync daemon --port 9528 --rendezvous rv.example.com:9600
# → rendezvous exchanges IPs, peers connect directly
```

### Encrypted (mTLS)

For sensitive environments — both peers must present certificates signed by the same CA:

```bash
# Generate test certs (see samples/)
./samples/gen-test-certs.sh

# Start with TLS
orrery-sync daemon --port 9527 \
  --tls-ca certs/ca.pem \
  --tls-cert certs/node-a.pem \
  --tls-key certs/node-a-key.pem
```

### Mixed mode

Combine all discovery layers:

```bash
orrery-sync daemon --port 9527 --rendezvous rv.company.com:9600
# → Same LAN: Bonjour auto-discovery (fastest)
# → Known peers: auto-connect from config
# → Cross-network: rendezvous server
# → Manual: orrery-sync pair host:port
```

## What gets synced

Only memory files under `~/.orrery/shared/memory/`:

| Path | Content | Sync behavior |
|------|---------|---------------|
| `memory/*/ORRERY_MEMORY.md` | Shared memory | Via fragments |
| `memory/*/fragments/` | Memory fragments | Conflict-free sync |

Sessions (`claude/`, `codex/`, `gemini/`) are **not synced** — they are machine-specific (bound to local paths and environment accounts) and not useful across peers.

### Memory fragment workflow

When memory is written on Machine A:
1. `ORRERY_MEMORY.md` is updated locally
2. A fragment file is created in `fragments/`
3. Fragment syncs to all peers
4. On Machine B, next agent session reads memory → sees pending fragments → consolidates → writes back → fragments cleaned up

## Commands

```
orrery-sync daemon        Start the sync daemon
orrery-sync pair          Pair with a remote peer
orrery-sync status        Show daemon and peer status
orrery-sync team create   Create a new team
orrery-sync team invite   Generate an invite code
orrery-sync team join     Join a team using an invite code
orrery-sync team info     Show current team and known peers
orrery-sync rendezvous    Run a rendezvous server
```

## Architecture

```
Machine A                              Machine B
┌──────────────────┐                  ┌──────────────────┐
│  orrery-sync    │◄── NMT/TCP ────►│  orrery-sync    │
│    daemon        │   (P2P mesh)     │    daemon        │
├──────────────────┤                  ├──────────────────┤
│  FileWatcher     │                  │  FileWatcher     │
│  (FSEvents/poll) │                  │  (FSEvents/poll) │
├──────────────────┤                  ├──────────────────┤
│  ~/.orrery/     │                  │  ~/.orrery/     │
│    shared/       │                  │    shared/       │
└──────────────────┘                  └──────────────────┘
        │                                      │
   Unix socket                            Unix socket
   (~/.orrery/sync.sock)                 (~/.orrery/sync.sock)
        │                                      │
   orrery sync status                    orrery sync status
```

Discovery layers (used in order of speed):
1. **mDNS/Bonjour** — same LAN, zero config
2. **Known peers** — saved in `~/.orrery/sync-config.json`
3. **Rendezvous server** — cross-network coordination
4. **Manual pairing** — `orrery-sync pair host:port`

## License

Apache 2.0
