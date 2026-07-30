import Foundation
import Supabase

struct ActivityFilters: Equatable {
    var action: String?
    var username: String?      // ilike on discord_username
    var playerQuery: String?   // player id, or username ilike → resolve to ids
    var from: Date?
    var to: Date?
}

enum ActivityService {
    private static var client: SupabaseClient { SupabaseManager.client }
    private static let pageSize = 30

    /// Filterable audit list with +1-row pagination (guide §6 "Activity").
    static func list(page: Int, filters: ActivityFilters) async throws
        -> (logs: [AuditLog], hasMore: Bool)
    {
        var q = client.from("audit_logs").select()

        if let action = filters.action, !action.isEmpty {
            q = q.eq("action", value: action)
        }
        if let user = filters.username?.trimmingCharacters(in: .whitespacesAndNewlines),
           !user.isEmpty {
            q = q.ilike("discord_username", pattern: "%\(user)%")
        }
        if let raw = filters.playerQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if isUUID(raw) {
                q = q.eq("target_player_id", value: raw)
            } else {
                let ids = try await resolvePlayerIDs(usernameLike: raw)
                guard !ids.isEmpty else { return ([], false) }
                q = q.in("target_player_id", values: ids)
            }
        }
        if let from = filters.from {
            q = q.gte("timestamp", value: dayStartISO(from))
        }
        if let to = filters.to {
            q = q.lte("timestamp", value: dayEndISO(to))
        }

        let start = page * pageSize
        let rows: [AuditLog] = try await q
            .order("timestamp", ascending: false)
            .range(from: start, to: start + pageSize)
            .execute()
            .value
        return (Array(rows.prefix(pageSize)), rows.count > pageSize)
    }

    /// Distinct action strings present in the log (for the filter picker).
    static func knownActions() async throws -> [String] {
        struct Row: Decodable { let action: String }
        let rows: [Row] = try await client.from("audit_logs")
            .select("action").limit(1000).execute().value
        return Array(Set(rows.map(\.action))).sorted()
    }

    private static func resolvePlayerIDs(usernameLike: String) async throws -> [String] {
        struct Row: Decodable { let id: String }
        let rows: [Row] = try await client.from("players")
            .select("id")
            .ilike("username", pattern: "%\(usernameLike)%")
            .limit(50)
            .execute()
            .value
        return rows.map(\.id)
    }

    private static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func dayStartISO(_ d: Date) -> String {
        iso.string(from: Calendar.current.startOfDay(for: d))
    }
    private static func dayEndISO(_ d: Date) -> String {
        let start = Calendar.current.startOfDay(for: d)
        let end = start.addingTimeInterval(24 * 3600 - 1)
        return iso.string(from: end)
    }
}
