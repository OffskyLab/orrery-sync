import Foundation

// MARK: - Control socket (CLI → Daemon)

struct ControlRequest: Codable, Sendable {
    let command: String
    let args: [String: String]?
}

struct ControlResponse: Codable, Sendable {
    let ok: Bool
    let message: String
    let data: [String: String]?
}
