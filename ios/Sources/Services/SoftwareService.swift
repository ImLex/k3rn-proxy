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
}
