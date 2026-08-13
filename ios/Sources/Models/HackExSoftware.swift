import Foundation

/// Catalog of HackEx programs used to build the per-software Target filter.
///
/// `name` must stay in sync with `SW_NAMES` in `k3rn_capture_addon.py` — that is
/// what the capture proxy writes into a target's software list, and the filter
/// matches against it case-insensitively. `label` is the game's own wording,
/// which is longer for a couple of programs ("Password Cracker" vs "Cracker").
///
/// Ordered as the game lists them: defense, then attack, then utility. Firewall
/// is deliberately absent — the game reports it as a program but the proxy
/// routes its level to the target's `firewall` column, which has its own filter.
enum HackExSoftware {
    struct Entry: Identifiable {
        /// Name as stored on a captured target; the filter's match key.
        let name: String
        /// Name as the game displays it.
        let label: String
        var id: String { name }
    }

    static let catalog: [Entry] = [
        Entry(name: "Antivirus", label: "Antivirus"),
        Entry(name: "Encryptor", label: "Password Encryptor"),
        Entry(name: "Proxy", label: "Proxy"),
        Entry(name: "Trace", label: "Trace"),
        Entry(name: "Bypasser", label: "Bypasser"),
        Entry(name: "Cracker", label: "Password Cracker"),
        Entry(name: "Spam", label: "Spam"),
        Entry(name: "Rootkit", label: "Rootkit"),
        Entry(name: "Siphon", label: "Siphon"),
        Entry(name: "Keygen", label: "Keygen"),
    ]
}
