import Foundation

/// Client-side replica of the web crew gate (IOS_APP_GUIDE §3). Uses the
/// Discord `provider_token` returned right after OAuth to confirm the user is
/// in the guild AND holds the #K3RN or Officer role.
///
/// The gate is UX only — RLS is the real boundary (a rejected user stays
/// `pending` and sees no data). We can only run it immediately after sign-in
/// because the provider token is transient (gotcha §7).
enum DiscordGate {
    enum GateError: Error {
        case notInCrew      // not in guild, or lacks the required role
        case verifyFailed   // network / Discord API error — couldn't decide
    }

    private struct GuildMember: Decodable {
        let roles: [String]
    }

    static func verify(providerToken: String) async throws {
        let guildID = AppConfig.discordGuildID
        guard let url = URL(string:
            "https://discord.com/api/v10/users/@me/guilds/\(guildID)/member")
        else { throw GateError.verifyFailed }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(providerToken)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw GateError.verifyFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw GateError.verifyFailed
        }
        // 404 → the user isn't a member of the guild at all.
        if http.statusCode == 404 { throw GateError.notInCrew }
        guard http.statusCode == 200 else { throw GateError.verifyFailed }

        guard let member = try? JSONDecoder().decode(GuildMember.self, from: data) else {
            throw GateError.verifyFailed
        }

        let allowed: Set<String> = [
            AppConfig.discordK3RNRoleID,
            AppConfig.discordOfficerRoleID,
        ]
        guard !allowed.isDisjoint(with: Set(member.roles)) else {
            throw GateError.notInCrew
        }
    }
}
