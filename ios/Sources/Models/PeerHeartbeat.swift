import Foundation

/// A row from `peer_heartbeats` — the capture addon stamps it on any mapped
/// GAME_HOST response, so a fresh `lastSeenAt` proves the phone → WireGuard →
/// mitmproxy → Supabase path is alive end-to-end. See migration 0028.
///
/// Distinct from `OwnProfile.capturedAt`: that one only advances when the game
/// hits /v1/user (member taps their own profile), so it can read "2 days ago"
/// during a live session. This one advances on every game screen the member
/// touches, so the app can render a truthful Connection: Live/Idle/Lost.
struct PeerHeartbeat: Codable, Sendable {
    var lastSeenAt: String?
    var wgIP: String?
    var pathLast: String?

    enum CodingKeys: String, CodingKey {
        case lastSeenAt = "last_seen_at"
        case wgIP = "wg_ip"
        case pathLast = "path_last"
    }
}
