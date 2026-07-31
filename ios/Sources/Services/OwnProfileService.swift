import Foundation
import Supabase

/// The member's own captured profile (`own_profile`). RLS scopes the read to the
/// signed-in member, so there is at most one row.
enum OwnProfileService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// The member's own profile, or nil if the proxy hasn't captured it yet
    /// (they haven't opened their own account in-game with the VPN on).
    static func fetchMine() async throws -> OwnProfile? {
        do {
            let rows: [OwnProfile] = try await client.from("own_profile")
                .select()
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch { throw AppError.map(error) }
    }
}
