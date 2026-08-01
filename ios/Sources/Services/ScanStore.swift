import Foundation

/// On-device store of the member's private Deep-scan pool. Persists to a JSON file
/// so the pool survives relaunch and stays visible offline — and, crucially, stays
/// visible after the member turns Deep scan back off (the server rows persist, but
/// the local copy guarantees the list never blanks out on a failed refresh). Server
/// wins on conflict, keyed on `player_id`; a re-seen player refreshes its row.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var targets: [ScanTarget] = []
    @Published var lastError: String?
    @Published private(set) var loading = false

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("scan_targets.json")
        load()
    }

    var sortedTargets: [ScanTarget] {
        targets.sorted { ($0.lastScannedAt ?? "") > ($1.lastScannedAt ?? "") }
    }

    /// Pull the full pool (paginated past 1000) and fold it into the cache. Only
    /// rows that actually changed are rewritten; existing rows the server no longer
    /// returns are kept so the list never shrinks unexpectedly.
    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            merge(try await ScanService.fetchMine())
            lastError = nil
        } catch {
            lastError = AppError.map(error).errorDescription
        }
    }

    /// Wipe local cache (sign-out, so a shared device doesn't leak the pool).
    func clear() {
        targets = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func merge(_ remote: [ScanTarget]) {
        var byKey: [String: ScanTarget] = [:]
        for t in targets { byKey[t.playerID] = t }
        for r in remote { byKey[r.playerID] = r }   // server is source of truth
        targets = byKey.values.sorted { ($0.lastScannedAt ?? "") > ($1.lastScannedAt ?? "") }
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let rows = try? JSONDecoder().decode([ScanTarget].self, from: data) {
            targets = rows
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
