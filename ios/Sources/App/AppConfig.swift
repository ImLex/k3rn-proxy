import Foundation

/// Reads build-time configuration injected into Info.plist from
/// Config/Secrets.xcconfig. See Secrets.example.xcconfig.
enum AppConfig {
    private static func string(_ key: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !v.isEmpty, !v.hasPrefix("$(") else {
            fatalError("Missing Info.plist key \(key) — set it in Config/Secrets.xcconfig")
        }
        return v
    }

    /// SUPABASE_HOST is stored without a scheme (xcconfig treats `//` as a comment).
    static var supabaseURL: URL {
        URL(string: "https://\(string("SUPABASE_HOST"))")!
    }

    static var supabaseAnonKey: String { string("SUPABASE_ANON_KEY") }

    static var discordGuildID: String { string("DISCORD_GUILD_ID") }
    static var discordOfficerRoleID: String { string("DISCORD_OFFICER_ROLE_ID") }
    static var discordK3RNRoleID: String { string("DISCORD_K3RN_ROLE_ID") }

    /// Custom scheme redirect registered in Info.plist + Supabase Auth.
    static let authRedirect = URL(string: "k3rnintel://auth-callback")!

    static func isAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == authRedirect.scheme
            && url.host?.lowercased() == authRedirect.host
    }
}
