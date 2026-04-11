import Foundation
import NMTP
import NIO
import Logging

// TODO: migrate to NMTPeer/PeerDispatcher — implementation pending Task 2

enum SyncError: Error {
    case missingArgument
    case fileNotFound(String)
    case daemonNotRunning
    case invalidInviteCode
    case noTeamConfigured
}
