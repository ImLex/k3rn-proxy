import Foundation
import Supabase

/// The member's private capture inbox (`captures`). RLS scopes every read/write
/// to the signed-in member, so no owner filter is needed here.
enum CaptureService {
    private static var client: SupabaseClient { SupabaseManager.client }

    static func fetchMine() async throws -> [TrackedPlayer] {
        do {
            return try await client.from("captures")
                .select()
                .order("captured_at", ascending: false)
                .execute()
                .value
        } catch { throw AppError.map(error) }
    }

    /// Stamp a capture as promoted into the shared crew DB.
    static func markUploaded(id: String) async throws {
        do {
            try await client.from("captures")
                .update(["uploaded_at": AnyJSON.string(nowISO())])
                .eq("id", value: id)
                .execute()
        } catch { throw AppError.map(error) }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func nowISO() -> String { iso.string(from: Date()) }
}
