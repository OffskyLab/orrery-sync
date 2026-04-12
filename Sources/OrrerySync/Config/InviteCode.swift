import Foundation

/// Invite code payload — base64-encoded JSON shared out-of-band.
struct InviteCode: Codable, Sendable {
    let teamID: String
    let teamName: String
    let secret: String
    let host: String
    let port: Int

    func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }

    static func decode(_ code: String) throws -> InviteCode {
        guard let data = Data(base64Encoded: code) else {
            throw SyncError.invalidInviteCode
        }
        return try JSONDecoder().decode(InviteCode.self, from: data)
    }
}
