import Foundation

/// One spam or siphon deployment the member currently owns in-game. Decodes
/// directly from a `virus_deployments` row (RLS-scoped to the signed-in member).
/// Feeds the Virus tab — the member's own deployment earnings, not target intel.
struct VirusDeployment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var kind: String            // "spam" | "siphon"
    var virusID: String?
    var ip: String?
    var level: Int?
    var earningRateHr: Double?  // spam: crypto/hr
    var totalEarned: Double?    // spam: cumulative earnings
    var ageDays: Int?           // spam: days deployed
    var decayPct: Double?       // spam
    var percent: Double?        // siphon: % of target income
    var totalSiphoned: Double?  // siphon: cumulative crypto pulled
    var active: Bool
    var firstSeen: String?
    var lastSeen: String?
    var capturedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, ip, level, percent, active
        case virusID = "virus_id"
        case earningRateHr = "earning_rate_hr"
        case totalEarned = "total_earned"
        case ageDays = "age_days"
        case decayPct = "decay_pct"
        case totalSiphoned = "total_siphoned"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case capturedAt = "captured_at"
    }

    var isSpam: Bool { kind == "spam" }

    /// The "earned" figure shown on a row, regardless of kind.
    var earned: Double? { isSpam ? totalEarned : totalSiphoned }

    static func == (l: VirusDeployment, r: VirusDeployment) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
