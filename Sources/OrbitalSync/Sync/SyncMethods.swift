/// Method names used in NMT .call bodies for sync operations.
enum SyncMethod {
    static let handshake = "sync.handshake"
    static let manifest = "sync.manifest"
    static let filePull = "sync.file.pull"
    static let filePush = "sync.file.push"
    static let fileDelete = "sync.file.delete"
}
