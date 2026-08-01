import Foundation
import Supabase

enum SoftwareService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// Installed software for a player, with the embedded catalog row
    /// (`select=*,software(*)`). Ordered TARGET-owned first, then by name.
    static func installed(playerID: String) async throws -> [InstalledSoftware] {
        let rows: [InstalledSoftware] = try await client.from("installed_software")
            .select("*,software(*)")
            .eq("player_id", value: playerID)
            .execute()
            .value
        return rows.sorted { a, b in
            if a.owner != b.owner { return a.owner == "TARGET" }
            let na = a.software?.name ?? ""
            let nb = b.software?.name ?? ""
            return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending
        }
    }

    /// Highest sane software level; keeps a bad capture from writing a wild value.
    private static let levelMax = 1000

    /// Push a target's captured software to the shared `installed_software` table,
    /// mirroring the crew web / Android upload path: resolve each program to a
    /// catalog row via the `upsert_software` RPC, then upsert the
    /// (player, software, TARGET) row. Owner is always TARGET — these are the
    /// target's own programs, seen on their device.
    static func uploadInstalled(playerID: String, software: [CapturedSoftware]) async throws {
        do {
            for item in software {
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }

                let softwareID: String = try await client
                    .rpc("upsert_software",
                         params: ["p_name": name, "p_category": item.category ?? "UTILITY"])
                    .execute()
                    .value

                let payload: [String: AnyJSON] = [
                    "player_id": .string(playerID),
                    "software_id": .string(softwareID),
                    "level": .integer(max(0, min(levelMax, item.level))),
                    "owner": .string("TARGET"),
                    "source": .string("IMPORT"),
                ]
                try await client.from("installed_software")
                    .upsert(payload, onConflict: "player_id,software_id,owner")
                    .execute()
            }
        } catch { throw AppError.map(error) }
    }
}
