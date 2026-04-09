import Foundation
import Logging

#if canImport(CoreServices)
import CoreServices
#endif

/// Watches a directory recursively for file changes and yields events via AsyncStream.
struct FileWatcher: Sendable {
    let directory: String
    let logger = Logger(label: "orbital-sync.watcher")

    init(directory: String) {
        // Resolve symlinks (e.g. /tmp → /private/tmp on macOS)
        if let resolved = realpath(directory, nil) {
            self.directory = String(cString: resolved)
            free(resolved)
        } else {
            self.directory = directory
        }
    }

    func watch() -> AsyncStream<FileChange> {
        #if canImport(CoreServices)
        return watchWithFSEvents()
        #else
        return watchWithPolling()
        #endif
    }

    #if canImport(CoreServices)
    private func watchWithFSEvents() -> AsyncStream<FileChange> {
        AsyncStream { continuation in
            let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
                guard let info = clientCallBackInfo else { return }
                let cont = Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

                for i in 0..<numEvents {
                    let fullPath = paths[i]
                    let flag = flags[i]

                    guard !FileManager.default.isDirectory(atPath: fullPath) else { continue }

                    let kind: FileChange.Kind
                    if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                        kind = .deleted
                    } else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                        kind = .created
                    } else {
                        kind = .modified
                    }

                    let relativePath = fullPath.replacingOccurrences(
                        of: cont.directory + "/",
                        with: ""
                    )
                    cont.continuation.yield(FileChange(path: relativePath, kind: kind))
                }
            }

            let box = ContinuationBox(continuation: continuation, directory: self.directory)
            let contextPtr = Unmanaged.passRetained(box).toOpaque()

            var streamContext = FSEventStreamContext(
                version: 0,
                info: contextPtr,
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let stream = FSEventStreamCreate(
                nil,
                callback,
                &streamContext,
                [self.directory] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3,
                UInt32(
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagUseCFTypes |
                    kFSEventStreamCreateFlagNoDefer
                )
            ) else {
                continuation.finish()
                return
            }

            let queue = DispatchQueue(label: "orbital-sync.fsevents", qos: .utility)
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)

            let cleanup = StreamCleanup(stream: stream, context: contextPtr)

            continuation.onTermination = { _ in
                cleanup.run()
            }
        }
    }
    #endif

    /// Fallback polling-based watcher for Linux.
    private func watchWithPolling() -> AsyncStream<FileChange> {
        AsyncStream { continuation in
            let pollInterval: UInt64 = 2_000_000_000 // 2 seconds
            let dir = self.directory
            let task = Task {
                var snapshot = Self.buildSnapshot(of: dir)

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    let current = Self.buildSnapshot(of: dir)

                    for (path, modDate) in current {
                        if let oldDate = snapshot[path] {
                            if modDate > oldDate {
                                continuation.yield(FileChange(path: path, kind: .modified))
                            }
                        } else {
                            continuation.yield(FileChange(path: path, kind: .created))
                        }
                    }

                    for path in snapshot.keys where current[path] == nil {
                        continuation.yield(FileChange(path: path, kind: .deleted))
                    }

                    snapshot = current
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func buildSnapshot(of directory: String) -> [String: Date] {
        let fm = FileManager.default
        var result: [String: Date] = [:]

        guard let enumerator = fm.enumerator(atPath: directory) else { return result }
        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (directory as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            result[relativePath] = modified
        }
        return result
    }
}

struct FileChange: Sendable {
    enum Kind: Sendable {
        case created
        case modified
        case deleted
    }

    let path: String
    let kind: Kind
}

#if canImport(CoreServices)
/// Box to pass continuation through C callback context pointer.
final class ContinuationBox: @unchecked Sendable {
    let continuation: AsyncStream<FileChange>.Continuation
    let directory: String

    init(continuation: AsyncStream<FileChange>.Continuation, directory: String) {
        self.continuation = continuation
        self.directory = directory
    }
}

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Sendable wrapper for FSEventStream cleanup resources.
final class StreamCleanup: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let context: UnsafeMutableRawPointer

    init(stream: FSEventStreamRef, context: UnsafeMutableRawPointer) {
        self.stream = stream
        self.context = context
    }

    func run() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Unmanaged<ContinuationBox>.fromOpaque(context).release()
    }
}
#endif
