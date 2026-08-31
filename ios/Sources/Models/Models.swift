import Foundation
import Supabase

// Timestamps are kept as ISO strings (formatted for display in Formatting.swift)
// to avoid Date-decoding pitfalls across the PostgREST/JSON boundary.

enum Role: String, Codable, Sendable {
    case pending, member, admin, disabled
}

enum CrewRank: String, Codable, Sendable, CaseIterable {
    case leader, officer, member

    /// Sort tier: leader 0, officer 1, member/null 2.
    var tier: Int { self == .leader ? 0 : (self == .officer ? 1 : 2) }
}

struct Player: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var username: String
    var playerID: String?
    var crew: String?
    var crewRank: String?
    var currentIP: String?
    var level: Int?
    var firewall: Int?
    var reputation: Int?
    var notes: String?
    var walletAddress: String?
    var createdAt: String?
    var updatedAt: String?
    var updatedBy: String?
    var deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, crew, level, firewall, reputation, notes
        case playerID = "player_id"
        case crewRank = "crew_rank"
        case currentIP = "current_ip"
        case walletAddress = "wallet_address"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
    }

    var rank: CrewRank { CrewRank(rawValue: crewRank ?? "") ?? .member }
    static func == (l: Player, r: Player) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PlayerIP: Codable, Identifiable, Sendable {
    let id: String
    let playerID: String
    let ip: String
    let firstSeen: String?
    let lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case id, ip
        case playerID = "player_id"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }
}

struct AuditLog: Codable, Identifiable, Sendable {
    let id: String
    let discordUserID: String
    let discordUsername: String
    let action: String
    let targetPlayerID: String?
    let timestamp: String?
    let before: [String: AnyJSON]?
    let after: [String: AnyJSON]?

    enum CodingKeys: String, CodingKey {
        case id, action, timestamp, before, after
        case discordUserID = "discord_user_id"
        case discordUsername = "discord_username"
        case targetPlayerID = "target_player_id"
    }
}

struct Profile: Codable, Identifiable, Sendable {
    var id: String { userID }
    let userID: String
    let discordUserID: String?
    let discordUsername: String?
    let displayName: String?
    let nickname: String?
    let email: String?
    let role: Role
    let discordRoles: [String]?
    let verifiedAt: String?
    let createdAt: String?
    let approvedAt: String?

    enum CodingKeys: String, CodingKey {
        case email, role, nickname
        case userID = "user_id"
        case discordUserID = "discord_user_id"
        case discordUsername = "discord_username"
        case displayName = "display_name"
        case discordRoles = "discord_roles"
        case verifiedAt = "verified_at"
        case createdAt = "created_at"
        case approvedAt = "approved_at"
    }
}

struct Software: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String?
}

struct InstalledSoftware: Codable, Identifiable, Sendable {
    let id: String
    let playerID: String
    let softwareID: String
    let level: Int
    let owner: String
    let source: String?
    let updatedAt: String?
    let software: Software?   // embedded via select=*,software(*)

    enum CodingKeys: String, CodingKey {
        case id, level, owner, source, software
        case playerID = "player_id"
        case softwareID = "software_id"
        case updatedAt = "updated_at"
    }
}

struct DashboardStats: Codable, Sendable {
    let players: Int
    let knownIPs: Int
    let updatedToday: Int

    enum CodingKeys: String, CodingKey {
        case players
        case knownIPs = "known_ips"
        case updatedToday = "updated_today"
    }
}

/// Actor identity for writes/audit; mirrors actor_discord_id()/actor_name().
struct Actor: Sendable {
    let discordID: String
    let name: String
    let role: Role
}

struct CrewOrder: Codable, Identifiable, Sendable {
    var id: String { crewKey }
    let crewKey: String
    let position: Int?
    let memberOrder: [String]?

    enum CodingKeys: String, CodingKey {
        case position
        case crewKey = "crew_key"
        case memberOrder = "member_order"
    }
}

struct NicknameEntry: Codable, Sendable {
    let discordUserID: String
    let nickname: String
    enum CodingKeys: String, CodingKey {
        case nickname
        case discordUserID = "discord_user_id"
    }
}
