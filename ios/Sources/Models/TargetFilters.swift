import Foundation

/// Client-side filter set for the Targets tab (applied over the local
/// `TrackerStore` cache, not a server query). Mirrors the shape of the Search
/// tab's `PlayerFilters` but adds min/max ranges and per-software selection.
struct TargetFilters: Equatable {
    var username: String?
    var minLevel: Int?
    var maxLevel: Int?
    var minFirewall: Int?
    var maxFirewall: Int?
    var minReputation: Int?
    var playerID: String?
    /// Selected software names from `HackExSoftware.catalog`. A target matches if
    /// it has at least one installed software whose name matches a selected entry
    /// (and meets `minSoftwareLevel`, when set).
    var software: Set<String> = []
    var minSoftwareLevel: Int?

    var activeCount: Int {
        var n = 0
        if let s = username, !s.isEmpty { n += 1 }
        if minLevel != nil { n += 1 }
        if maxLevel != nil { n += 1 }
        if minFirewall != nil { n += 1 }
        if maxFirewall != nil { n += 1 }
        if minReputation != nil { n += 1 }
        if let s = playerID, !s.isEmpty { n += 1 }
        if !software.isEmpty { n += 1 }
        if minSoftwareLevel != nil { n += 1 }
        return n
    }

    /// True if the target passes every active filter.
    func matches(_ p: TrackedPlayer) -> Bool {
        if let s = username, !s.isEmpty,
           !p.username.localizedCaseInsensitiveContains(s) { return false }
        if let v = minLevel, (p.level ?? Int.min) < v { return false }
        if let v = maxLevel, (p.level ?? Int.max) > v { return false }
        if let v = minFirewall, (p.firewall ?? Int.min) < v { return false }
        if let v = maxFirewall, (p.firewall ?? Int.max) > v { return false }
        if let v = minReputation, (p.reputation ?? Int.min) < v { return false }
        if let s = playerID, !s.isEmpty,
           !(p.playerID?.localizedCaseInsensitiveContains(s) ?? false) { return false }
        if !software.isEmpty {
            let minLvl = minSoftwareLevel ?? Int.min
            let ok = p.software.contains { sw in
                software.contains { sel in sw.name.localizedCaseInsensitiveContains(sel) }
                    && sw.level >= minLvl
            }
            if !ok { return false }
        } else if let minLvl = minSoftwareLevel {
            // Software-level filter without a specific program: any software qualifies.
            if !p.software.contains(where: { $0.level >= minLvl }) { return false }
        }
        return true
    }
}

/// Sort options for the Targets tab. `.recent` (newest capture first) is the
/// default so freshly-entered targets surface at the top.
enum TargetSort: String, CaseIterable, Identifiable {
    case recent, score, level, username, firewall, reputation
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recently entered"
        case .score: return "Potential score"
        case .level: return "Level"
        case .username: return "Username"
        case .firewall: return "Firewall"
        case .reputation: return "Reputation"
        }
    }
}
