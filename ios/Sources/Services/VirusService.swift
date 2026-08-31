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

    /// Used by the Virus tab's clear-inactive action. Safe to delete for real:
    /// a deployment is only marked inactive because it dropped off the game's
    /// own list (see `deactivate_absent` in k3rn_capture_addon.py), so nothing
    /// will re-insert it.
    static func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        do {
            try await client.from("virus_deployments")
                .delete()
                .in("id", values: ids)
                .execute()
        } catch { throw AppError.map(error) }
    }
}
