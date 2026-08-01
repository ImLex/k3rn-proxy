import Foundation

/// One player from the member's private Deep-scan pool. Decodes a `scan_targets`
/// row (RLS-scoped to the signed-in member). Never promoted to the shared crew DB
/// — this is a private, owner-scoped intel pool captured by the proxy when the
/// member runs an in-game scan with Deep scan on.
struct ScanTarget: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var playerID: String
    var username: String?
    var ip: String?            // masked/displayed scan IP
    var realIP: String?        // unmasked via a queued reveal
    var level: Int?
    var firewall: Int?
    var reputation: Int?
    var status: String?
    var gameCreatedAt: String?
    var firstScannedAt: String?
    var lastScannedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, ip, level, firewall, reputation, status
        case playerID = "player_id"
        case realIP = "real_ip"
        case gameCreatedAt = "game_created_at"
        case firstScannedAt = "first_scanned_at"
        case lastScannedAt = "last_scanned_at"
    }

    static func == (l: ScanTarget, r: ScanTarget) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A pending/resolved real-IP reveal for one scanned target (`reveal_queue`).
/// At most one `pending` row per member (enforced by DB + RLS + a partial unique
/// index) — a reveal hijacks the member's next in-game Bypass and never loops.
struct RevealRequest: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var playerID: String
    var status: String         // pending | done | failed
    var realIP: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case playerID = "player_id"
        case realIP = "real_ip"
    }
}
