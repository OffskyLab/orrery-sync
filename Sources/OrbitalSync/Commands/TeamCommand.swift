import ArgumentParser
import Foundation

struct TeamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "team",
        abstract: "Manage sync team",
        subcommands: [
            TeamCreateCommand.self,
            TeamInviteCommand.self,
            TeamJoinCommand.self,
            TeamInfoCommand.self,
        ]
    )

    @OptionGroup var globals: OrbitalSyncCommand
}

// MARK: - team create

struct TeamCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new team"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    @Argument(help: "Team name")
    var name: String

    func run() async throws {
        var config = SyncConfig.load()

        if let existing = config.team {
            print("Already in team '\(existing.name)'. Leave first to create a new one.")
            throw ExitCode.failure
        }

        // Generate random 32-byte hex secret
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()

        let team = TeamConfig(
            id: UUID().uuidString,
            name: name,
            secret: secret,
            createdAt: Date()
        )
        config.team = team
        try config.save()

        print("Team '\(name)' created.")
        print("Team ID: \(team.id)")
        print("")
        print("Next: run 'orbital-sync team invite' to generate an invite code for others.")
    }
}

// MARK: - team invite

struct TeamInviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Generate an invite code for a peer"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    @Option(name: .shortAndLong, help: "NMT server port to share")
    var port: Int = 9527

    @Option(name: .long, help: "Host address to share (default: auto-detect)")
    var host: String?

    func run() async throws {
        let config = SyncConfig.load()
        guard let team = config.team else {
            print("No team configured. Create one with: orbital-sync team create <name>")
            throw ExitCode.failure
        }

        let resolvedHost = host ?? detectLocalIP() ?? "127.0.0.1"

        let invite = InviteCode(
            teamID: team.id,
            teamName: team.name,
            secret: team.secret,
            host: resolvedHost,
            port: port
        )
        let code = try invite.encode()

        print("Invite code for team '\(team.name)':")
        print("")
        print(code)
        print("")
        print("Share this code with your teammate.")
        print("They can join with: orbital-sync team join <code>")
    }

    private func detectLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            let ip: String
            if let nullIndex = hostname.firstIndex(of: 0) {
                ip = String(decoding: hostname[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } else {
                ip = String(decoding: hostname.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if !ip.isEmpty && ip != "127.0.0.1" {
                return ip
            }
        }
        return nil
    }
}

// MARK: - team join

struct TeamJoinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Join a team using an invite code"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    @Argument(help: "Invite code from team invite")
    var code: String

    func run() async throws {
        let invite = try InviteCode.decode(code)

        var config = SyncConfig.load()

        if let existing = config.team {
            if existing.id == invite.teamID {
                print("Already in this team.")
            } else {
                print("Already in team '\(existing.name)'. Leave first to join another.")
                throw ExitCode.failure
            }
        } else {
            config.team = TeamConfig(
                id: invite.teamID,
                name: invite.teamName,
                secret: invite.secret,
                createdAt: Date()
            )
        }

        // Save the inviter as a known peer
        let alreadyKnown = config.knownPeers.contains { $0.host == invite.host && $0.port == invite.port }
        if !alreadyKnown {
            config.knownPeers.append(KnownPeer(
                peerID: "",
                peerName: "",
                host: invite.host,
                port: invite.port,
                addedAt: Date()
            ))
        }

        try config.save()

        print("Joined team '\(invite.teamName)'!")
        print("Inviter: \(invite.host):\(invite.port)")
        print("")
        print("Start the daemon to connect: orbital-sync daemon")
    }
}

// MARK: - team info

struct TeamInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show current team and known peers"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    func run() async throws {
        let config = SyncConfig.load()

        if let team = config.team {
            print("Team: \(team.name)")
            print("  ID: \(team.id)")
            print("  Created: \(team.createdAt)")
        } else {
            print("No team configured.")
        }

        if config.knownPeers.isEmpty {
            print("\nNo known peers.")
        } else {
            print("\nKnown peers:")
            for peer in config.knownPeers {
                let name = peer.peerName.isEmpty ? "(pending)" : peer.peerName
                print("  \(name) — \(peer.host):\(peer.port)")
            }
        }
    }
}
