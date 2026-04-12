import Foundation
import Synchronization
import NIO
import Logging

/// Unix domain socket server for CLI → Daemon communication.
final class ControlSocket: Sendable {
    let socketPath: String
    let logger = Logger(label: "orrery-sync.control")
    let commandHandler: @Sendable (ControlRequest) async -> ControlResponse

    private let state = Mutex(ControlSocketState())

    struct ControlSocketState {
        var channel: Channel?
        var group: MultiThreadedEventLoopGroup?
    }

    init(
        socketPath: String? = nil,
        onCommand: @escaping @Sendable (ControlRequest) async -> ControlResponse
    ) {
        if let socketPath {
            self.socketPath = socketPath
        } else if let home = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            self.socketPath = home + "/sync.sock"
        } else {
            self.socketPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.orrery/sync.sock"
        }
        self.commandHandler = onCommand
    }

    func start() async throws {
        // Remove stale socket file
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = ControlChannelHandler(onCommand: commandHandler)

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        state.withLock {
            $0.channel = channel
            $0.group = group
        }
        logger.info("Control socket listening at \(socketPath)")
    }

    func stop() async throws {
        let (channel, group) = state.withLock { ($0.channel, $0.group) }
        try await channel?.close()
        try await group?.shutdownGracefully()
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }
    }
}

/// NIO handler that reads JSON lines from the Unix socket and dispatches commands.
final class ControlChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let onCommand: @Sendable (ControlRequest) async -> ControlResponse

    init(onCommand: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        self.onCommand = onCommand
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        let data = Data(bytes)

        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
            let errorResponse = ControlResponse(ok: false, message: "Invalid request", data: nil)
            writeResponse(errorResponse, to: context)
            return
        }

        let handler = onCommand
        let channel = context.channel
        Task {
            let response = await handler(request)
            guard let responseData = try? JSONEncoder().encode(response) else { return }
            var buf = channel.allocator.buffer(capacity: responseData.count + 1)
            buf.writeBytes(responseData)
            buf.writeInteger(UInt8(0x0A))
            try? await channel.writeAndFlush(buf)
        }
    }

    private func writeResponse(_ response: ControlResponse, to context: ChannelHandlerContext) {
        guard let responseData = try? JSONEncoder().encode(response) else { return }
        var buffer = context.channel.allocator.buffer(capacity: responseData.count + 1)
        buffer.writeBytes(responseData)
        buffer.writeInteger(UInt8(0x0A))
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }
}
