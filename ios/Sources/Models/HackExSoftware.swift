import Foundation

/// Fixed catalog of HackEx programs used to build the per-software Target filter.
/// Captured software names are free-text from the game API, so matching is done
/// case-insensitively against these labels. Extend this list if the game adds
/// programs that members want to filter on.
enum HackExSoftware {
    static let catalog: [String] = [
        "Firewall",
        "Antivirus",
        "Bruteforce",
        "SPAM",
        "Siphon",
        "Spyware",
        "SDK",
        "Encryptor",
        "Decryptor",
    ]
}
