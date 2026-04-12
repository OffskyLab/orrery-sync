import Foundation
import NIO
import NIOSSL
import NMTP
import Synchronization

/// Concrete `TLSContext` implementation for orrery-sync.
///
/// Uses swift-nio-ssl (BoringSSL) for mTLS — both peers present certificates
/// signed by a shared CA. Any peer with an unknown cert is rejected at handshake.
public final class SyncTLSContext: TLSContext {
    private let serverCtx: Mutex<NIOSSLContext>
    private let clientCtx: Mutex<NIOSSLContext>

    public init(ca: CACertSource, identity: IdentitySource) throws {
        let serverCtx = try Self.buildServerContext(ca: ca, identity: identity)
        let clientCtx = try Self.buildClientContext(ca: ca, identity: identity)
        self.serverCtx = Mutex(serverCtx)
        self.clientCtx = Mutex(clientCtx)
    }

    // MARK: - TLSContext

    public func makeServerHandler() async throws -> any ChannelHandler {
        let ctx = serverCtx.withLock { $0 }
        return NIOSSLServerHandler(context: ctx)
    }

    public func makeClientHandler(serverHostname: String?) async throws -> any ChannelHandler {
        let ctx = clientCtx.withLock { $0 }
        return try NIOSSLClientHandler(context: ctx, serverHostname: serverHostname)
    }

    // MARK: - Private

    private static func buildServerContext(ca: CACertSource, identity: IdentitySource) throws -> NIOSSLContext {
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: try loadCertChain(identity),
            privateKey: try loadPrivateKey(identity)
        )
        config.trustRoots = .certificates(try loadCA(ca))
        // Verify client cert against CA, skip hostname check (peers connect by IP)
        config.certificateVerification = .noHostnameVerification
        return try NIOSSLContext(configuration: config)
    }

    private static func buildClientContext(ca: CACertSource, identity: IdentitySource) throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = try loadCertChain(identity)
        config.privateKey = try loadPrivateKey(identity)
        config.trustRoots = .certificates(try loadCA(ca))
        config.certificateVerification = .noHostnameVerification
        return try NIOSSLContext(configuration: config)
    }

    private static func loadCertChain(_ source: IdentitySource) throws -> [NIOSSLCertificateSource] {
        switch source {
        case .files(let cert, _):
            return try NIOSSLCertificate.fromPEMFile(cert).map { .certificate($0) }
        case .pem(let certData, _):
            return try NIOSSLCertificate.fromPEMBytes(Array(certData)).map { .certificate($0) }
        }
    }

    private static func loadPrivateKey(_ source: IdentitySource) throws -> NIOSSLPrivateKeySource {
        switch source {
        case .files(_, let key):
            return .privateKey(try NIOSSLPrivateKey(file: key, format: .pem))
        case .pem(_, let keyData):
            return .privateKey(try NIOSSLPrivateKey(bytes: Array(keyData), format: .pem))
        }
    }

    private static func loadCA(_ source: CACertSource) throws -> [NIOSSLCertificate] {
        switch source {
        case .file(let path):
            return try NIOSSLCertificate.fromPEMFile(path)
        case .pem(let data):
            return try NIOSSLCertificate.fromPEMBytes(Array(data))
        }
    }
}

// MARK: - Config types

/// Where to load the CA certificate from.
public enum CACertSource: Sendable {
    case file(path: String)
    case pem(Data)
}

/// Where to load this node's identity (cert + key) from.
public enum IdentitySource: Sendable {
    case files(cert: String, key: String)
    case pem(cert: Data, key: Data)
}
