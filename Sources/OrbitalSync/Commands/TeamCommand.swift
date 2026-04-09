import ArgumentParser

struct TeamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "team",
        abstract: "Manage sync team",
        subcommands: [
            TeamCreateCommand.self,
            TeamInviteCommand.self,
            TeamJoinCommand.self,
        ]
    )

    @OptionGroup var globals: OrbitalSyncCommand
}

struct TeamCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new team"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    @Argument(help: "Team name")
    var name: String

    func run() async throws {
        // TODO: Generate team ID + shared secret, save to config
        print("Creating team '\(name)'...")
    }
}

struct TeamInviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Generate an invite code for a peer"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    func run() async throws {
        // TODO: Generate invite code containing team ID + secret + host info
        print("Generating invite code...")
    }
}

struct TeamJoinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Join a team using an invite code"
    )

    @OptionGroup var globals: OrbitalSyncCommand

    @Argument(help: "Invite code")
    var code: String

    func run() async throws {
        // TODO: Parse invite code, save team info, start discovery
        print("Joining team with code \(code)...")
    }
}
