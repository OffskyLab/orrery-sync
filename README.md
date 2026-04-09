# orbital-sync

P2P real-time sync daemon for [Orbital](https://github.com/OffskyLab/Orbital). Keeps `~/.orbital/shared/` in sync across multiple machines — sessions, memory, and environment config.

Built on [NMT protocol](https://github.com/OffskyLab/swift-nmtp) (Nebula Matter Transfer).

## Install

### Homebrew (macOS / Linux)

```bash
brew install OffskyLab/orbital/orbital-sync
```

### APT (Ubuntu / Debian)

```bash
curl -fsSL https://offskylab.github.io/apt/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/offskylab.gpg
echo "deb [signed-by=/usr/share/keyrings/offskylab.gpg] https://offskylab.github.io/apt stable main" | sudo tee /etc/apt/sources.list.d/offskylab.list
sudo apt update && sudo apt install orbital-sync
```

### From source

```bash
git clone https://github.com/OffskyLab/orbital-sync.git
cd orbital-sync
swift build -c release
cp .build/release/orbital-sync ~/.orbital/bin/
```

## Quick start

### Two machines, same Wi-Fi

```bash
# Machine A
orbital-sync daemon --port 9527

# Machine B
orbital-sync pair 192.168.1.100:9527
orbital-sync daemon --port 9528
```

Bonjour auto-discovery is enabled by default on macOS — peers on the same LAN find each other automatically.

### With Orbital CLI

All commands work through `orbital sync`:

```bash
orbital sync daemon --port 9527
orbital sync status
orbital sync pair 192.168.1.100:9527
```

## Usage patterns

### Personal: desktop + laptop

Both machines on the same network. Start the daemon on each — Bonjour handles the rest:

```bash
# Desktop
orbital-sync daemon --port 9527

# Laptop
orbital-sync daemon --port 9528
# → auto-discovers desktop via Bonjour, syncs immediately
```

### Team collaboration

Create a team so only authorized peers can connect:

```bash
# Alice creates team and generates invite
orbital-sync team create frontend-team
orbital-sync team invite --port 9527
# → prints a base64 invite code, share via Slack/email

# Alice starts daemon
orbital-sync daemon --port 9527

# Bob joins
orbital-sync team join <invite-code>
orbital-sync daemon --port 9528
# → auto-connects to Alice, pulls all existing memory

# Charlie joins
orbital-sync team join <invite-code>
orbital-sync daemon --port 9529
# → full mesh: all three peers connected
```

### Cross-network (rendezvous)

For peers on different networks (different offices, home + office):

```bash
# Run rendezvous on a VPS or cloud server
orbital-sync rendezvous --port 9600

# Each peer connects through it
orbital-sync daemon --port 9527 --rendezvous rv.example.com:9600
orbital-sync daemon --port 9528 --rendezvous rv.example.com:9600
# → rendezvous exchanges IPs, peers connect directly
```

### Encrypted (mTLS)

For sensitive environments — both peers must present certificates signed by the same CA:

```bash
# Generate test certs (see samples/)
./samples/gen-test-certs.sh

# Start with TLS
orbital-sync daemon --port 9527 \
  --tls-ca certs/ca.pem \
  --tls-cert certs/node-a.pem \
  --tls-key certs/node-a-key.pem
```

### Mixed mode

Combine all discovery layers:

```bash
orbital-sync daemon --port 9527 --rendezvous rv.company.com:9600
# → Same LAN: Bonjour auto-discovery (fastest)
# → Known peers: auto-connect from config
# → Cross-network: rendezvous server
# → Manual: orbital-sync pair host:port
```

## What gets synced

Everything under `~/.orbital/shared/`:

| Path | Content | Sync behavior |
|------|---------|---------------|
| `claude/projects/` | Session files (JSONL) | Append merge |
| `claude/sessions/` | Session metadata | Last-write-wins |
| `memory/*/ORBITAL_MEMORY.md` | Shared memory | Via fragments |
| `memory/*/fragments/` | Memory fragments | Conflict-free sync |
| `codex/sessions/` | Codex sessions | Append merge |
| `gemini/tmp/` | Gemini sessions | Last-write-wins |

### Memory fragment workflow

When memory is written on Machine A:
1. `ORBITAL_MEMORY.md` is updated locally
2. A fragment file is created in `fragments/`
3. Fragment syncs to all peers
4. On Machine B, next agent session reads memory → sees pending fragments → consolidates → writes back → fragments cleaned up

## Commands

```
orbital-sync daemon        Start the sync daemon
orbital-sync pair          Pair with a remote peer
orbital-sync status        Show daemon and peer status
orbital-sync team create   Create a new team
orbital-sync team invite   Generate an invite code
orbital-sync team join     Join a team using an invite code
orbital-sync team info     Show current team and known peers
orbital-sync rendezvous    Run a rendezvous server
```

## Architecture

```
Machine A                              Machine B
┌──────────────────┐                  ┌──────────────────┐
│  orbital-sync    │◄── NMT/TCP ────►│  orbital-sync    │
│    daemon        │   (P2P mesh)     │    daemon        │
├──────────────────┤                  ├──────────────────┤
│  FileWatcher     │                  │  FileWatcher     │
│  (FSEvents/poll) │                  │  (FSEvents/poll) │
├──────────────────┤                  ├──────────────────┤
│  ~/.orbital/     │                  │  ~/.orbital/     │
│    shared/       │                  │    shared/       │
└──────────────────┘                  └──────────────────┘
        │                                      │
   Unix socket                            Unix socket
   (~/.orbital/sync.sock)                 (~/.orbital/sync.sock)
        │                                      │
   orbital sync status                    orbital sync status
```

Discovery layers (used in order of speed):
1. **mDNS/Bonjour** — same LAN, zero config
2. **Known peers** — saved in `~/.orbital/sync-config.json`
3. **Rendezvous server** — cross-network coordination
4. **Manual pairing** — `orbital-sync pair host:port`

## License

Apache 2.0
