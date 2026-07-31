import Foundation
import Supabase

/// The member's own spam/siphon deployments (`virus_deployments`). RLS scopes
/// every read to the signed-in member, so no owner filter is needed here.
enum VirusService {
    private static var client: SupabaseClient { SupabaseManager.client }

    static func fetchMine() async throws -> [VirusDeployment] {
        do {
            return try await client.from("virus_deployments")
                .select()
                .order("active", ascending: false)
                .order("captured_at", ascending: false)
                .execute()
                .value
        } catch { throw AppError.map(error) }
    }
}
