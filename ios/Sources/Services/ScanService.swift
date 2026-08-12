import Foundation
import Supabase

/// The member's private Deep-scan pool (`scan_targets`), Deep-scan toggle
/// (`scan_settings`), and real-IP reveal queue (`reveal_queue`). RLS scopes every
/// read/write to the signed-in member, so no owner filter is needed on reads;
/// writes still stamp owner_user_id / owner_discord_id to satisfy the policy.
enum ScanService {
    private static var client: SupabaseClient { SupabaseManager.client }

    private static func ownerUserID() async throws -> String {
        try await client.auth.session.user.id.uuidString
    }

    // MARK: Targets

    /// The pool can exceed PostgREST's default 1000-row cap, so page through with
    /// explicit ranges until a short page signals the end.
    static func fetchMine() async throws -> [ScanTarget] {
        let pageSize = 1000
        var all: [ScanTarget] = []
        var from = 0
        do {
            while true {
                let page: [ScanTarget] = try await client.from("scan_targets")
                    .select()
                    .order("last_scanned_at", ascending: false)
                    .range(from: from, to: from + pageSize - 1)
                    .execute()
                    .value
                all.append(contentsOf: page)
                if page.count < pageSize { break }
                from += pageSize
            }
            return all
        } catch { throw AppError.map(error) }
    }

    // MARK: Deep-scan toggle

    struct ScanSettings: Decodable {
        let deepScan: Bool
        let scanCount: Int
        enum CodingKeys: String, CodingKey {
            case deepScan = "deep_scan"
            case scanCount = "scan_count"
        }
    }

    /// Both the toggle and the boost count in one read, so the UI can seed its
    /// controls without two round-trips.
    static func fetchSettings() async throws -> ScanSettings {
        do {
            let rows: [ScanSettings] = try await client.from("scan_settings")
                .select("deep_scan,scan_count").limit(1).execute().value
            return rows.first ?? ScanSettings(deepScan: false, scanCount: 5000)
        } catch { throw AppError.map(error) }
    }

    static func setDeepScan(_ on: Bool, actor: Actor) async throws {
        let payload: [String: AnyJSON] = [
            "owner_user_id": .string(try await ownerUserID()),
            "owner_discord_id": .string(actor.discordID),
            "deep_scan": .bool(on),
            "updated_at": .string(nowISO()),
        ]
        do {
            try await client.from("scan_settings")
                .upsert(payload, onConflict: "owner_user_id")
                .execute()
        } catch { throw AppError.map(error) }
    }

    /// The addon reads `scan_count` from its settings cache, so writing it here is
    /// enough to change how many players the next boosted scan captures.
    static func setScanCount(_ count: Int, actor: Actor) async throws {
        let payload: [String: AnyJSON] = [
            "owner_user_id": .string(try await ownerUserID()),
            "owner_discord_id": .string(actor.discordID),
            "scan_count": .integer(count),
            "updated_at": .string(nowISO()),
        ]
        do {
            try await client.from("scan_settings")
                .upsert(payload, onConflict: "owner_user_id")
                .execute()
        } catch { throw AppError.map(error) }
    }

    // MARK: Reveal queue

    /// Every reveal row for this member (pending + resolved), so the UI can show
    /// which targets are pending / have a real IP.
    static func fetchReveals() async throws -> [RevealRequest] {
        do {
            return try await client.from("reveal_queue")
                .select("id,player_id,status,real_ip")
                .order("requested_at", ascending: false)
                .execute()
                .value
        } catch { throw AppError.map(error) }
    }

    /// Queue a reveal for one target. The partial unique index (one pending per
    /// owner) rejects a second concurrent reveal — surfaced as a friendly error.
    static func queueReveal(playerID: String, actor: Actor) async throws {
        let payload: [String: AnyJSON] = [
            "owner_user_id": .string(try await ownerUserID()),
            "owner_discord_id": .string(actor.discordID),
            "player_id": .string(playerID),
            "status": .string("pending"),
        ]
        do {
            try await client.from("reveal_queue").insert(payload).execute()
        } catch let pg as PostgrestError {
            // 23505 = unique_violation on the reveal_queue_one_pending partial index.
            if pg.code == "23505" || pg.message.localizedCaseInsensitiveContains("duplicate") {
                throw AppError.network("A reveal is already pending. Wait for it to resolve first.")
            }
            throw AppError.map(pg)
        } catch { throw AppError.map(error) }
    }

    /// Manually clear a target's revealed IP: null `scan_targets.real_ip` and wipe
    /// that target's reveal history so a fresh reveal can be queued right away. The
    /// scramble-reset trigger does this automatically on IP change; this is the
    /// on-demand version (e.g. the member wants to re-verify a suspiciously old IP).
    static func resetReveal(playerID: String, actor: Actor) async throws {
        let owner = try await ownerUserID()
        do {
            try await client.from("scan_targets")
                .update(["real_ip": AnyJSON.null])
                .eq("owner_user_id", value: owner)
                .eq("player_id", value: playerID)
                .execute()
            try await client.from("reveal_queue")
                .delete()
                .eq("owner_user_id", value: owner)
                .eq("player_id", value: playerID)
                .execute()
        } catch { throw AppError.map(error) }
    }

    /// Wipe the member's entire Deep-scan pool: delete every scan_targets row and any
    /// reveal history, so the list starts genuinely fresh. RLS scopes the delete to the
    /// member; the owner filter mirrors resetReveal for safety.
    static func clearAllTargets(actor: Actor) async throws {
        let owner = try await ownerUserID()
        do {
            try await client.from("scan_targets")
                .delete().eq("owner_user_id", value: owner).execute()
            try await client.from("reveal_queue")
                .delete().eq("owner_user_id", value: owner).execute()
        } catch { throw AppError.map(error) }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func nowISO() -> String { iso.string(from: Date()) }
}
