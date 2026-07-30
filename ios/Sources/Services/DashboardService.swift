import Foundation
import Supabase

enum DashboardService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// `dashboard_stats()` returns { players, known_ips, updated_today } only
    /// (guide §9.9). The Crews card counts distinct crew tags client-side.
    static func stats() async throws -> DashboardStats {
        try await client.rpc("dashboard_stats").execute().value
    }

    /// Distinct non-empty crew tags among non-deleted players.
    static func crewCount() async throws -> Int {
        struct Row: Decodable { let crew: String? }
        let rows: [Row] = try await client.from("players")
            .select("crew").is("deleted_at", value: nil).execute().value
        var keys = Set<String>()
        for r in rows {
            if let c = r.crew?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                keys.insert(c.lowercased())
            }
        }
        return keys.count
    }

    static func recentActivity(limit: Int = 6) async throws -> [AuditLog] {
        try await client.from("audit_logs")
            .select()
            .order("timestamp", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    static func recentlyUpdated(limit: Int = 5) async throws -> [Player] {
        try await client.from("players")
            .select()
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }
}
