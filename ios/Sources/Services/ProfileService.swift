import Foundation
import Supabase

/// Profile reads/writes: the nickname map (all roles, via security-definer RPC)
/// and admin-only user management (guide §6 "Settings").
enum ProfileService {
    private static var client: SupabaseClient { SupabaseManager.client }

    /// `profile_nicknames()` → dictionary discord_user_id → nickname.
    static func nicknames() async throws -> [String: String] {
        let rows: [NicknameEntry] = try await client
            .rpc("profile_nicknames").execute().value
        return Dictionary(rows.map { ($0.discordUserID, $0.nickname) }) { _, new in new }
    }

    // MARK: Admin

    /// All profiles (RLS lets only admins see more than their own).
    static func allProfiles() async throws -> [Profile] {
        try await client.from("profiles")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    static func approve(userID: String, approverUID: String) async throws {
        try await updateProfile(userID: userID, payload: [
            "role": .string(Role.member.rawValue),
            "approved_at": .string(nowISO()),
            "approved_by": .string(approverUID),
        ])
    }

    static func setRole(userID: String, role: Role) async throws {
        try await updateProfile(userID: userID, payload: ["role": .string(role.rawValue)])
    }

    /// Trim, ≤32 chars, empty → null (guide §6 Settings).
    static func setNickname(userID: String, nickname: String) async throws {
        let trimmed = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        try await updateProfile(userID: userID, payload: [
            "nickname": trimmed.isEmpty ? .null : .string(trimmed),
        ])
    }

    private static func updateProfile(userID: String, payload: [String: AnyJSON]) async throws {
        do {
            let rows: [Profile] = try await client.from("profiles")
                .update(payload).eq("user_id", value: userID)
                .select().execute().value
            // Silent RLS: no rows back means the caller isn't admin (guide §9.2).
            guard !rows.isEmpty else { throw AppError.permissionDenied }
        } catch let e as AppError { throw e }
        catch { throw AppError.map(error) }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func nowISO() -> String { iso.string(from: Date()) }
}

/// Session-scoped nickname cache (~5 min). Inject into the SwiftUI environment
/// so audit/"updated by" rows can resolve snowflakes → nicknames.
@MainActor
final class NicknameStore: ObservableObject {
    @Published private(set) var map: [String: String] = [:]
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 300

    func nickname(forDiscordID id: String?, fallback: String?) -> String {
        if let id, let nick = map[id] { return nick }
        return fallback ?? "—"
    }

    func refreshIfStale() async {
        if let at = fetchedAt, Date().timeIntervalSince(at) < ttl { return }
        await refresh()
    }

    func refresh() async {
        if let fresh = try? await ProfileService.nicknames() {
            map = fresh
            fetchedAt = Date()
        }
    }
}
