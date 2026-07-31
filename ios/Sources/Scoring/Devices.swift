import Foundation

/// The 12-rung device ladder (Raider → Nova Ultra) and its derived strength.
/// Port of `devices.ts`. Device tier is a weak scoring input on iOS (often unknown).
enum Devices {
    /// Ordered weakest → strongest.
    static let ladder: [String] = [
        "Raider", "Raider II", "Raider III",
        "Bolt", "Bolt II", "Bolt III",
        "Nova", "Nova II", "Nova III",
        "Nova S", "Nova X", "Nova Ultra",
    ]

    /// 1-based position on the ladder, or nil if unrecognised.
    static func rank(_ device: String?) -> Int? {
        guard let name = normalise(device) else { return nil }
        guard let idx = ladder.firstIndex(of: name) else { return nil }
        return idx + 1
    }

    /// 0…1 strength. Unknown device → 0.5 (neutral); else `(rank-1)/(count-1)`.
    static func strength(_ device: String?) -> Double {
        guard let r = rank(device) else { return 0.5 }
        return Double(r - 1) / Double(ladder.count - 1)
    }

    /// Canonical casing for a raw device string, or nil if it isn't on the ladder.
    static func normalise(_ device: String?) -> String? {
        guard let raw = device?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return ladder.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }
}
