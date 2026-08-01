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

    static func fetchMine() async throws -> [ScanTarget] {
        do {
            return try await client.from("scan_targets")
                .select()
                .order("last_scanned_at", ascending: false)
                .execute()
                .value
        } catch { throw AppError.map(error) }
    }

    // MARK: Deep-scan toggle

    static func fetchDeepScan() async throws -> Bool {
        struct Row: Decodable { let deepScan: Bool
            enum CodingKeys: String, CodingKey { case deepScan = "deep_scan" } }
        do {
            let rows: [Row] = try await client.from("scan_settings")
                .select("deep_scan").limit(1).execute().value
            return rows.first?.deepScan ?? false
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

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func nowISO() -> String { iso.string(from: Date()) }
}
