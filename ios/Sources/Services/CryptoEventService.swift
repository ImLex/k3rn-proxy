import Foundation
import Supabase

/// The member's per-target theft time-series (`target_crypto_events`). RLS scopes
/// every read to the signed-in member, so no owner filter is needed. This is the
/// history that feeds the scoring engine's rate / total / trend.
enum CryptoEventService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// One row of `target_crypto_events`, decoded straight from PostgREST.
    private struct Row: Decodable {
        let playerID: String
        let amount: Double
        let source: String?
        let capturedAt: String

        enum CodingKeys: String, CodingKey {
            case amount, source
            case playerID = "player_id"
            case capturedAt = "captured_at"
        }
    }

    /// Every crypto event for the member, grouped by `player_id` (= victim_user_id),
    /// newest-first within each target.
    static func fetchMineByPlayer() async throws -> [String: [CryptoEvent]] {
        do {
            let rows: [Row] = try await client.from("target_crypto_events")
                .select("player_id, amount, source, captured_at")
                .order("captured_at", ascending: false)
                .execute()
                .value

            var byPlayer: [String: [CryptoEvent]] = [:]
            for r in rows {
                guard let date = Formatting.date(from: r.capturedAt) else { continue }
                byPlayer[r.playerID, default: []].append(CryptoEvent(amount: r.amount, date: date))
            }
            return byPlayer
        } catch { throw AppError.map(error) }
    }
}
