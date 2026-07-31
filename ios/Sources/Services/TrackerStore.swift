import Foundation

/// On-device store of the member's tracked targets. Persists to a JSON file so
/// captures survive relaunch and are readable offline; syncs from the private
/// `captures` inbox on foreground / pull-to-refresh (server wins on conflict).
@MainActor
final class TrackerStore: ObservableObject {
    @Published private(set) var players: [TrackedPlayer] = []
    /// Theft history per target, keyed on `player_id`. Feeds the scoring engine.
    @Published private(set) var eventsByPlayer: [String: [CryptoEvent]] = [:]
    /// The member's own captured game accounts, newest-first. A member with
    /// several HackEx logins has one entry per account (see migration 0011).
    @Published private(set) var ownAccounts: [OwnProfile] = []
    @Published var lastError: String?
    @Published private(set) var loading = false

    private let fileURL: URL
    private let eventsURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tracked_players.json")
        eventsURL = dir.appendingPathComponent("crypto_events.json")
        load()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        async let captures = CaptureService.fetchMine()
        async let events = CryptoEventService.fetchMineByPlayer()
        async let own = OwnProfileService.fetchAll()
        do {
            merge(try await captures)
            eventsByPlayer = try await events
            saveEvents()
            lastError = nil
        } catch {
            lastError = AppError.map(error).errorDescription
        }
        // Own-account list is best-effort — a failure here shouldn't surface as a
        // tracker error or wipe a previously-loaded list.
        if let accounts = try? await own { ownAccounts = accounts }
    }

    func player(id: String) -> TrackedPlayer? { players.first { $0.id == id } }

    /// Theft history for a target (empty if it has never been looted).
    func events(for player: TrackedPlayer) -> [CryptoEvent] {
        guard let pid = player.playerID, !pid.isEmpty else { return [] }
        return eventsByPlayer[pid] ?? []
    }

    /// Full scoring readout for a target, using its cached theft history.
    func assessment(for player: TrackedPlayer, userLevel: Int) -> TargetAssessment {
        TargetAssessor.assess(player: player, events: events(for: player), userLevel: userLevel)
    }

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
        eventsByPlayer = [:]
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: eventsURL)
    }

    private func merge(_ remote: [TrackedPlayer]) {
        var byKey: [String: TrackedPlayer] = [:]
        for p in players { byKey[p.dedupeKey] = p }
        for r in remote { byKey[r.dedupeKey] = r }   // server is source of truth
        players = byKey.values.sorted { ($0.capturedAt ?? "") > ($1.capturedAt ?? "") }
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let rows = try? JSONDecoder().decode([TrackedPlayer].self, from: data) {
            players = rows
        }
        if let data = try? Data(contentsOf: eventsURL),
           let events = try? JSONDecoder().decode([String: [CryptoEvent]].self, from: data) {
            eventsByPlayer = events
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(players) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func saveEvents() {
        guard let data = try? JSONEncoder().encode(eventsByPlayer) else { return }
        try? data.write(to: eventsURL, options: .atomic)
    }
}
