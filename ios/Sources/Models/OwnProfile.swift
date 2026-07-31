import Foundation

/// The member's own in-game profile (`own_profile`), captured from /v1/user +
/// /v1/user_wallet by the proxy. One row per member. Read-only on the client.
struct OwnProfile: Codable, Sendable, Identifiable {
    var playerID: String?
    var username: String?
    var level: Int?
    var reputation: Int?
    var firewall: Int?
    var device: String?
    var software: [CapturedSoftware]
    var cryptoHot: Double?
    var cryptoCold: Double?
    var cryptoUpdatedAt: String?
    var capturedAt: String?

    /// Identity for the account switcher — the in-game user id.
    var id: String { playerID ?? username ?? "" }

    enum CodingKeys: String, CodingKey {
        case username, level, reputation, firewall, device, software
        case playerID = "player_id"
        case cryptoHot = "crypto_hot"
        case cryptoCold = "crypto_cold"
        case cryptoUpdatedAt = "crypto_updated_at"
        case capturedAt = "captured_at"
    }
}
