import Foundation
import NMTPeer

/// Represents a connected peer in the mesh.
struct PeerConnection: Sendable {
    let peerID: String
    let peerName: String
    let address: String
    let port: Int
    let dispatcher: PeerDispatcher
    /// true if we initiated the connection (addPeer); false if accepted via PeerListener.
    /// Only initiator-side connections retry on disconnect.
    let isInitiator: Bool
}
