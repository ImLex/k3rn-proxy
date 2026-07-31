import Foundation

/// One piece of a target's installed software, captured personally.
struct CapturedSoftware: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let category: String?
    let level: Int
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, category, level }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        // The game (and older capture rows) store software_level as a JSON
        // string; accept either a number or a numeric string.
        if let i = try? c.decode(Int.self, forKey: .level) {
            level = i
        } else if let s = try? c.decode(String.self, forKey: .level), let i = Int(s) {
            level = i
        } else {
            level = 1
        }
    }
}

/// A target the member has opened, tracked privately. Decodes directly from a
/// `captures` row and is also the on-device persistence model (JSON file store).
struct TrackedPlayer: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var playerID: String?
    var username: String
    var currentIP: String?
    var level: Int?
    var firewall: Int?
    var reputation: Int?
    var crew: String?
    var software: [CapturedSoftware]
    var capturedAt: String?
    var uploadedAt: String?
    /// Stealable crypto currently held on the target (captures.crypto_hot).
    var cryptoHot: Double?
    /// Safe crypto the target can't lose (captures.crypto_cold).
    var cryptoCold: Double?
    /// When the wallet snapshot was last refreshed in-game.
    var cryptoUpdatedAt: String?
    /// The target's persistent hx wallet address (captures.wallet_address),
    /// revealed when the member enters the target's wallet in-game.
    var walletAddress: String?

    enum CodingKeys: String, CodingKey {
        case id, username, level, firewall, reputation, crew, software
        case playerID = "player_id"
        case currentIP = "current_ip"
        case capturedAt = "captured_at"
        case uploadedAt = "uploaded_at"
        case cryptoHot = "crypto_hot"
        case cryptoCold = "crypto_cold"
        case cryptoUpdatedAt = "crypto_updated_at"
        case walletAddress = "wallet_address"
    }

    var isUploaded: Bool { !(uploadedAt?.isEmpty ?? true) }

    /// Stable identity for merging local + server rows (server keys on player_id).
    var dedupeKey: String {
        if let pid = playerID, !pid.isEmpty { return pid }
        return "u:" + username.lowercased()
    }

    static func == (l: TrackedPlayer, r: TrackedPlayer) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
