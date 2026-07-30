import Foundation

/// One piece of a target's installed software, captured personally.
struct CapturedSoftware: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let category: String?
    let level: Int
    var id: String { name }
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

    enum CodingKeys: String, CodingKey {
        case id, username, level, firewall, reputation, crew, software
        case playerID = "player_id"
        case currentIP = "current_ip"
        case capturedAt = "captured_at"
        case uploadedAt = "uploaded_at"
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
