import Foundation
import Supabase

/// Reads `peer_heartbeats`. RLS scopes to the signed-in member (one row max),
/// written by the capture addon on any mapped GAME_HOST flow — see migration
/// 0028 for the shape and the addon's `_maybe_heartbeat`.
enum HeartbeatService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// Latest heartbeat for the signed-in member, or nil if the addon has never
    /// stamped one (fresh member who has never opened HackEx through the tunnel).
    static func fetchMine() async throws -> PeerHeartbeat? {
        do {
            let rows: [PeerHeartbeat] = try await client.from("peer_heartbeats")
                .select()
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch { throw AppError.map(error) }
    }
}
