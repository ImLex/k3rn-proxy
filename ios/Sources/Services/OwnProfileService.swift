import Foundation
import Supabase

/// The member's own captured profile (`own_profile`). RLS scopes the read to the
/// signed-in member, so there is at most one row.
enum OwnProfileService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// Every game account the proxy has captured for this member, newest-first.
    /// A member with several HackEx logins gets one row per account (see 0011).
    static func fetchAll() async throws -> [OwnProfile] {
        do {
            return try await client.from("own_profile")
                .select()
                .order("captured_at", ascending: false)
                .execute()
                .value
        } catch { throw AppError.map(error) }
    }
}
