import Foundation

/// On-device store of the member's tracked targets. Persists to a JSON file so
/// captures survive relaunch and are readable offline; syncs from the private
/// `captures` inbox on foreground / pull-to-refresh (server wins on conflict).
@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var players: [TrackedPlayer] = []
    @Published var lastError: String?
    @Published private(set) var loading = false

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tracked_players.json")
        load()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            merge(try await CaptureService.fetchMine())
            lastError = nil
        } catch {
            lastError = AppError.map(error).errorDescription
        }
    }

    func player(id: String) -> TrackedPlayer? { players.first { $0.id == id } }

    /// Optimistically mark a row uploaded after a successful push (server also
    /// gets stamped via CaptureService.markUploaded).
    func markUploaded(id: String) {
        guard let i = players.firstIndex(where: { $0.id == id }) else { return }
        players[i].uploadedAt = ISO8601DateFormatter().string(from: Date())
        save()
    }

    /// Wipe local cache (used on sign-out so a shared device doesn't leak captures).
    func clear() {
        players = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func merge(_ remote: [TrackedPlayer]) {
        var byKey: [String: TrackedPlayer] = [:]
        for p in players { byKey[p.dedupeKey] = p }
        for r in remote { byKey[r.dedupeKey] = r }   // server is source of truth
        players = byKey.values.sorted { ($0.capturedAt ?? "") > ($1.capturedAt ?? "") }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let rows = try? JSONDecoder().decode([TrackedPlayer].self, from: data)
        else { return }
        players = rows
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(players) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
