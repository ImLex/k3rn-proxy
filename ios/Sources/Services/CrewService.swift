import Foundation
import Supabase

/// One crew card's data, assembled client-side (crews are derived, not a table).
struct CrewGroup: Identifiable {
    var id: String { key }
    let key: String          // lower(trim(crew))
    let displayName: String   // first-seen original casing
    var members: [Player]
    let position: Int?
}

enum CrewService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// Fetch all non-deleted players + the manual order rows, then build sorted
    /// crew groups per guide §6 "Crews screen".
    static func load() async throws -> (crews: [CrewGroup], unassigned: Int) {
        async let playersReq: [Player] = client.from("players")
            .select().is("deleted_at", value: nil).execute().value
        async let orderReq: [CrewOrder] = client.from("crew_order")
            .select().execute().value
        let players = try await playersReq
        let order = try await orderReq

        let positions = Dictionary(uniqueKeysWithValues:
            order.compactMap { o in o.position.map { (o.crewKey, $0) } })
        let memberOrders = Dictionary(uniqueKeysWithValues:
            order.compactMap { o in o.memberOrder.map { (o.crewKey, $0) } })

        var groups: [String: (name: String, members: [Player])] = [:]
        var unassigned = 0
        for p in players {
            guard let raw = p.crew?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { unassigned += 1; continue }
            let key = raw.lowercased()
            if groups[key] == nil { groups[key] = (raw, []) }
            groups[key]!.members.append(p)
        }

        var result: [CrewGroup] = groups.map { key, value in
            let order = memberOrders[key] ?? []
            let indexOf = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let sorted = value.members.sorted { a, b in
                if a.rank.tier != b.rank.tier { return a.rank.tier < b.rank.tier }
                let ia = indexOf[a.id] ?? Int.max
                let ib = indexOf[b.id] ?? Int.max
                if ia != ib { return ia < ib }
                return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
            }
            return CrewGroup(key: key, displayName: value.name,
                             members: sorted, position: positions[key])
        }

        result.sort { a, b in
            let pa = a.position ?? Int.max
            let pb = b.position ?? Int.max
            if pa != pb { return pa < pb }
            if a.members.count != b.members.count { return a.members.count > b.members.count }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        return (result, unassigned)
    }

    /// Persist crew card order. Keys must be lowercased (guide §9.6).
    static func saveCrewOrder(_ orderedKeys: [String]) async throws {
        let payload: [[String: AnyJSON]] = orderedKeys.enumerated().map { idx, key in
            ["crew_key": .string(key.lowercased()), "position": .integer(idx)]
        }
        try await client.from("crew_order").upsert(payload, onConflict: "crew_key").execute()
    }

    /// Persist member order within a crew (tie-breaker inside a rank group).
    static func saveMemberOrder(crewKey: String, orderedPlayerIDs: [String]) async throws {
        let payload: [String: AnyJSON] = [
            "crew_key": .string(crewKey.lowercased()),
            "member_order": .array(orderedPlayerIDs.map(AnyJSON.string)),
        ]
        try await client.from("crew_order").upsert(payload, onConflict: "crew_key").execute()
    }
}
