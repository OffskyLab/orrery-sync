import Foundation
import NIO

/// Client for sending commands to a running daemon via Unix domain socket.
struct ControlClient {
    let socketPath: String

    init(socketPath: String? = nil) {
        if let socketPath {
            self.socketPath = socketPath
        } else if let home = ProcessInfo.processInfo.environment["ORRERY_HOME"] {
            self.socketPath = home + "/sync.sock"
        } else {
            self.socketPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.orrery/sync.sock"
        }
    }

    func send(_ request: ControlRequest) throws -> ControlResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SyncError.daemonNotRunning
        }

        let requestData = try JSONEncoder().encode(request)

        // Simple synchronous Unix socket communication
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SyncError.daemonNotRunning }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strcpy(dest, ptr)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw SyncError.daemonNotRunning }

        // Send request
        requestData.withUnsafeBytes { buf in
            _ = Foundation.send(fd, buf.baseAddress!, buf.count, 0)
        }

        // Read response
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        if bytesRead > 0 {
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        // Strip trailing newline
        if responseData.last == 0x0A {
            responseData.removeLast()
        }

        return try JSONDecoder().decode(ControlResponse.self, from: responseData)
    }
}
