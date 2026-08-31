import Foundation
import Supabase

/// Resolved, normalized player fields ready to write (empty → nil, IP
/// normalized, crew_rank coupled to crew). Built from a validated draft.
struct PlayerInput {
    var username: String
    var playerID: String?
    var crew: String?
    var crewRank: String?
    var currentIP: String?
    var level: Int?
    var firewall: Int?
    var reputation: Int?
    var notes: String?
    /// Only carried by a capture promotion; the manual form has no wallet field, so
    /// leaving this nil omits the column and preserves whatever is already stored.
    var walletAddress: String?

    /// Build from a validated form draft (call only after Validation passes).
    /// Applies guide §6 rules: trim, empty→nil, crew_rank only with crew,
    /// normalize IPv4.
    static func from(draft d: Validation.PlayerDraft, rank: CrewRank) -> PlayerInput {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let crew = clean(d.crew)
        return PlayerInput(
            username: d.username.trimmingCharacters(in: .whitespacesAndNewlines),
            playerID: clean(d.playerID),
            crew: crew,
            crewRank: crew == nil ? nil : rank.rawValue,
            currentIP: Validation.normalizeIPv4(d.currentIP),
            level: Int(d.level.trimmingCharacters(in: .whitespacesAndNewlines)),
            firewall: Int(d.firewall.trimmingCharacters(in: .whitespacesAndNewlines)),
            reputation: Int(d.reputation.trimmingCharacters(in: .whitespacesAndNewlines)),
            notes: clean(d.notes)
        )
    }
}

/// Filters for the un-searched player list (guide §6 "Player list / search").
struct PlayerFilters: Equatable {
    var crew: String?
    var minLevel: Int?
    var minFirewall: Int?
    var minReputation: Int?
    var updatedToday = false
    var hasPlayerID: Bool?   // true = not null, false = null, nil = any
}

enum PlayerService {
    private static var client: SupabaseClient { SupabaseManager.client }
    private static let pageSize = 50

    // MARK: Reads

    /// Un-searched list. Returns up to `pageSize` rows plus a `hasMore` flag
    /// derived from an extra probe row (guide §6).
    static func list(page: Int, filters: PlayerFilters) async throws
        -> (players: [Player], hasMore: Bool)
    {
        var q = client.from("players").select().is("deleted_at", value: nil)

        if let crew = filters.crew, !crew.isEmpty {
            q = q.ilike("crew", pattern: "%\(crew)%")
        }
        if let v = filters.minLevel { q = q.gte("level", value: v) }
        if let v = filters.minFirewall { q = q.gte("firewall", value: v) }
        if let v = filters.minReputation { q = q.gte("reputation", value: v) }
        if filters.updatedToday {
            q = q.gte("updated_at", value: startOfLocalDayISO())
        }
        if let has = filters.hasPlayerID {
            q = has ? q.not("player_id", operator: .is, value: "null")
                    : q.is("player_id", value: nil)
        }

        let from = page * pageSize
        let rows: [Player] = try await q
            .order("updated_at", ascending: false)
            .range(from: from, to: from + pageSize)   // +1 probe row
            .execute()
            .value

        return (Array(rows.prefix(pageSize)), rows.count > pageSize)
    }

    /// Search via the RPC (handles soft-delete + historical IP matching).
    static func search(_ term: String) async throws -> [Player] {
        do {
            return try await client
                .rpc("search_players", params: ["q": term])
                .execute()
                .value
        } catch { throw AppError.map(error) }
    }

    static func fetch(id: String) async throws -> Player {
        do {
            return try await client.from("players")
                .select().eq("id", value: id).single().execute().value
        } catch { throw AppError.notFound }
    }

    static func ipHistory(playerID: String) async throws -> [PlayerIP] {
        try await client.from("player_ips")
            .select()
            .eq("player_id", value: playerID)
            .order("last_seen", ascending: false)
            .execute()
            .value
    }

    static func auditTrail(playerID: String) async throws -> [AuditLog] {
        try await client.from("audit_logs")
            .select()
            .eq("target_player_id", value: playerID)
            .order("timestamp", ascending: false)
            .execute()
            .value
    }

    /// Find a shared player matching a capture — by HackEx player_id first, then
    /// unique (case-insensitive) username — so an upload updates the existing row
    /// instead of hitting the username-unique constraint. Sees soft-deleted rows
    /// too (so we neither duplicate nor resurrect them).
    static func findExisting(playerID: String?, username: String) async throws -> Player? {
        if let pid = playerID, !pid.isEmpty {
            let rows: [Player] = try await client.from("players")
                .select().eq("player_id", value: pid).limit(1).execute().value
            if let p = rows.first { return p }
        }
        let rows: [Player] = try await client.from("players")
            .select().ilike("username", pattern: username).limit(1).execute().value
        return rows.first
    }

    /// Distinct non-empty crew tags for the form autocomplete.
    ///
    /// Paged past PostgREST's 1000-row cap: an unpaged select silently dropped every
    /// crew whose players fell beyond the first 1000 rows, which is what made the app
    /// disagree with the web dashboard.
    static func knownCrews() async throws -> [String] {
        struct Row: Decodable { let crew: String? }
        let pageSize = 1000
        var seen = Set<String>()
        var out: [String] = []
        var from = 0
        while true {
            let page: [Row] = try await client.from("players")
                .select("crew")
                .is("deleted_at", value: nil)
                .not("crew", operator: .is, value: "null")
                .neq("crew", value: "")
                .order("id", ascending: true)
                .range(from: from, to: from + pageSize - 1)
                .execute()
                .value
            for r in page {
                guard let c = r.crew?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !c.isEmpty else { continue }
                if seen.insert(c.lowercased()).inserted { out.append(c) }
            }
            if page.count < pageSize { break }
            from += pageSize
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Writes

    static func create(_ input: PlayerInput, actor: Actor) async throws -> Player {
        do {
            let created: Player = try await client.from("players")
                .insert(writePayload(input, actor: actor))
                .select().single().execute().value
            if let ip = input.currentIP { try await recordIP(playerID: created.id, ip: ip) }
            try await writeAudit(action: "player.create", actor: actor,
                                 targetID: created.id, before: nil, after: created)
            return created
        } catch let e as AppError { throw e }
        catch { throw AppError.map(error) }
    }

    static func update(id: String, input: PlayerInput, actor: Actor) async throws -> Player {
        let before = try await fetch(id: id)   // throws .notFound
        do {
            let rows: [Player] = try await client.from("players")
                .update(writePayload(input, actor: actor))
                .eq("id", value: id)
                .select().execute().value
            // Silent RLS: 0 rows means the write was rejected (guide §4/§9.2).
            guard let updated = rows.first else { throw AppError.permissionDenied }
            if let ip = input.currentIP, ip != before.currentIP {
                try await recordIP(playerID: id, ip: ip)
            }
            try await writeAudit(action: "player.update", actor: actor,
                                 targetID: id, before: before, after: updated)
            return updated
        } catch let e as AppError { throw e }
        catch { throw AppError.map(error) }
    }

    /// Admin-only; the RPC writes its own audit entry.
    static func softDelete(id: String) async throws {
        do { try await client.rpc("soft_delete_player", params: ["p_id": id]).execute() }
        catch { throw AppError.map(error) }
    }

    static func restore(id: String) async throws {
        do { try await client.rpc("restore_player", params: ["p_id": id]).execute() }
        catch { throw AppError.map(error) }
    }

    // MARK: Private

    private static func recordIP(playerID: String, ip: String) async throws {
        let payload: [String: AnyJSON] = [
            "player_id": .string(playerID),
            "ip": .string(ip),
            "last_seen": .string(nowISO()),
        ]
        try await client.from("player_ips")
            .upsert(payload, onConflict: "player_id,ip")
            .execute()
    }

    private static func writeAudit(action: String, actor: Actor,
                                   targetID: String?, before: Player?, after: Player?) async throws {
        let payload: [String: AnyJSON] = [
            "discord_user_id": .string(actor.discordID),
            "discord_username": .string(actor.name),
            "action": .string(action),
            "target_player_id": targetID.map(AnyJSON.string) ?? .null,
            "before": try before.map(snapshot) ?? .null,
            "after": try after.map(snapshot) ?? .null,
        ]
        try await client.from("audit_logs").insert(payload).execute()
    }

    private static func writePayload(_ i: PlayerInput, actor: Actor) -> [String: AnyJSON] {
        var payload: [String: AnyJSON] = [
            "username": .string(i.username),
            "player_id": i.playerID.map(AnyJSON.string) ?? .null,
            "crew": i.crew.map(AnyJSON.string) ?? .null,
            "crew_rank": i.crewRank.map(AnyJSON.string) ?? .null,
            "current_ip": i.currentIP.map(AnyJSON.string) ?? .null,
            "level": i.level.map(AnyJSON.integer) ?? .null,
            "firewall": i.firewall.map(AnyJSON.integer) ?? .null,
            "reputation": i.reputation.map(AnyJSON.integer) ?? .null,
            "notes": i.notes.map(AnyJSON.string) ?? .null,
            "updated_by": .string(actor.discordID),
        ]
        // A newer address replaces the stored one — wallets change. But a write that
        // carries no address omits the key entirely rather than sending null, so
        // promoting a capture taken before the wallet was opened can't erase it.
        if let w = i.walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !w.isEmpty {
            payload["wallet_address"] = .string(w)
        }
        return payload
    }

    /// Full player JSON snapshot for audit before/after (snake_case, matches DB).
    private static func snapshot(_ p: Player) throws -> AnyJSON {
        let data = try JSONEncoder().encode(p)
        return try JSONDecoder().decode(AnyJSON.self, from: data)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func nowISO() -> String { iso.string(from: Date()) }

    private static func startOfLocalDayISO() -> String {
        let start = Calendar.current.startOfDay(for: Date())
        return iso.string(from: start)
    }
}
