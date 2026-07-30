import Foundation

/// Client-side validation mirroring the web dashboard's rules (players.ts /
/// IOS_APP_GUIDE §6). The DB is the real boundary (checks + RLS); these give
/// fast inline feedback and normalize input before write.
enum Validation {
    /// Normalize an IPv4 string: 4 octets 0–255, strip leading zeros, re-join.
    /// Returns nil if the input is not a valid dotted-quad. Empty/whitespace → nil.
    static func normalizeIPv4(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var octets: [String] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(String(value))
        }
        return octets.joined(separator: ".")
    }

    struct Errors {
        var username: String?
        var playerID: String?
        var crew: String?
        var currentIP: String?
        var level: String?
        var firewall: String?
        var reputation: String?
        var notes: String?

        var isValid: Bool {
            username == nil && playerID == nil && crew == nil && currentIP == nil
                && level == nil && firewall == nil && reputation == nil && notes == nil
        }
    }

    /// Draft used by the add/edit form. Numeric fields are strings so the form
    /// can show raw input; validation parses and range-checks them.
    struct PlayerDraft {
        var username = ""
        var playerID = ""
        var crew = ""
        var currentIP = ""
        var level = ""
        var firewall = ""
        var reputation = ""
        var notes = ""
    }

    static func validate(_ d: PlayerDraft) -> Errors {
        var e = Errors()

        let username = d.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty {
            e.username = "Username is required"
        } else if username.count > 100 {
            e.username = "Username must be 100 characters or fewer"
        }

        if d.playerID.count > 200 { e.playerID = "Too long (max 200)" }
        if d.crew.count > 200 { e.crew = "Too long (max 200)" }
        if d.notes.count > 2000 { e.notes = "Notes must be 2000 characters or fewer" }

        if !d.currentIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizeIPv4(d.currentIP) == nil {
            e.currentIP = "Enter a valid IPv4 address"
        }

        e.level = intError(d.level, min: 0, max: 2_147_483_647, label: "Level")
        e.firewall = intError(d.firewall, min: 0, max: 2_147_483_647, label: "Firewall")
        e.reputation = intError(d.reputation, min: -99_999, max: 99_999, label: "Reputation")

        return e
    }

    /// nil when the (optional) field is empty or a valid in-range integer.
    private static func intError(_ raw: String, min: Int, max: Int, label: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed) else { return "\(label) must be a whole number" }
        guard (min...max).contains(value) else { return "\(label) must be between \(min) and \(max)" }
        return nil
    }
}
