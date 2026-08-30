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

    /// Short commit the .ipa was built from. Builds are sideloaded by hand from
    /// same-named CI artifacts, so without this there is no way to tell which
    /// build is on a device. "local" when built outside CI.
    static var buildRevision: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "GIT_SHA") as? String ?? ""
        return (v.isEmpty || v.hasPrefix("$(")) ? "local" : v
    }
}
