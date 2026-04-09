import Foundation
import NMTP
import NIO
import Logging

/// Handles incoming NMT Matter from peers.
struct SyncHandler: NMTHandler {
    let daemon: SyncDaemon
    let logger = Logger(label: "orbital-sync.handler")

    func handle(matter: Matter, channel: Channel) async throws -> Matter? {
        switch matter.type {
        case .call:
            return try await handleCall(matter: matter, channel: channel)
        default:
            logger.warning("Unhandled matter type: \(matter.type)")
            return nil
        }
    }

    private func handleCall(matter: Matter, channel: Channel) async throws -> Matter? {
        let body = try matter.decodeBody(CallBody.self)

        switch body.method {
        case SyncMethod.handshake:
            return try await handleHandshake(matter: matter, body: body, channel: channel)
        case SyncMethod.manifest:
            return try await handleManifest(matter: matter, body: body)
        case SyncMethod.filePull:
            return try await handleFilePull(matter: matter, body: body)
        case SyncMethod.filePush:
            return try await handleFilePush(matter: matter, body: body)
        case SyncMethod.fileDelete:
            return try await handleFileDelete(matter: matter, body: body)
        default:
            logger.warning("Unknown sync method: \(body.method)")
            return try matter.reply(body: CallReplyBody(result: nil, error: "Unknown method: \(body.method)"))
        }
    }

    private func handleHandshake(matter: Matter, body: CallBody, channel: Channel) async throws -> Matter? {
        let request = try decodeArgument(HandshakeBody.self, from: body)
        logger.info("Handshake from \(request.peerName) (\(request.peerID))")

        // Validate team membership if configured
        let config = SyncConfig.load()
        if let team = config.team, let remoteTeam = request.teamID {
            if team.id != remoteTeam {
                logger.warning("Rejected handshake: team mismatch")
                let info = await daemon.localPeerInfo()
                let reply = HandshakeReplyBody(
                    peerID: info.peerID, peerName: info.peerName,
                    version: info.version, accepted: false
                )
                return try matter.reply(body: encodeReply(reply))
            }
        }

        // Resolve the remote peer's IP from the channel
        let remoteHost: String
        if let remoteAddress = channel.remoteAddress {
            remoteHost = remoteAddress.ipAddress ?? "127.0.0.1"
        } else {
            remoteHost = "127.0.0.1"
        }

        // Reverse-pair: connect back to the remote peer so both sides can push
        let alreadyPaired = await daemon.hasPeer(request.peerID)
        if !alreadyPaired {
            logger.info("Reverse-pairing to \(request.peerName) at \(remoteHost):\(request.port)")
            Task {
                do {
                    try await daemon.addPeer(host: remoteHost, port: request.port)
                } catch {
                    logger.error("Reverse-pair failed: \(error)")
                }
            }
        }

        let info = await daemon.localPeerInfo()
        let reply = HandshakeReplyBody(
            peerID: info.peerID,
            peerName: info.peerName,
            version: info.version,
            accepted: true
        )
        return try matter.reply(body: encodeReply(reply))
    }

    private func handleManifest(matter: Matter, body: CallBody) async throws -> Matter? {
        let manifest = await daemon.buildManifest()
        let reply = ManifestReplyBody(manifest: manifest)
        return try matter.reply(body: encodeReply(reply))
    }

    private func handleFilePull(matter: Matter, body: CallBody) async throws -> Matter? {
        let request = try decodeArgument(FilePullBody.self, from: body)
        let fileData = try await daemon.readFile(relativePath: request.path)
        let reply = FilePullReplyBody(
            path: request.path,
            content: fileData.content,
            hash: fileData.hash,
            modifiedAt: fileData.modifiedAt
        )
        return try matter.reply(body: encodeReply(reply))
    }

    private func handleFilePush(matter: Matter, body: CallBody) async throws -> Matter? {
        let request = try decodeArgument(FilePushBody.self, from: body)
        try await daemon.writeFile(relativePath: request.path, content: request.content, modifiedAt: request.modifiedAt)
        let reply = FilePushReplyBody(accepted: true)
        return try matter.reply(body: encodeReply(reply))
    }

    private func handleFileDelete(matter: Matter, body: CallBody) async throws -> Matter? {
        let request = try decodeArgument(FileDeleteBody.self, from: body)
        logger.info("Delete request: \(request.path)")
        let deleted = await daemon.deleteFile(relativePath: request.path)
        let reply = FileDeleteReplyBody(deleted: deleted)
        return try matter.reply(body: encodeReply(reply))
    }

    // MARK: - Helpers

    /// Decode the first argument of a CallBody as a specific type.
    private func decodeArgument<T: Decodable>(_ type: T.Type, from body: CallBody) throws -> T {
        guard let arg = body.arguments.first else {
            throw SyncError.missingArgument
        }
        return try JSONDecoder().decode(type, from: arg.value)
    }

    /// Encode a reply value into a CallReplyBody.
    private func encodeReply<T: Encodable>(_ value: T) throws -> CallReplyBody {
        let data = try JSONEncoder().encode(value)
        return CallReplyBody(result: data, error: nil)
    }
}

enum SyncError: Error {
    case missingArgument
    case fileNotFound(String)
    case daemonNotRunning
    case invalidInviteCode
    case noTeamConfigured
}
