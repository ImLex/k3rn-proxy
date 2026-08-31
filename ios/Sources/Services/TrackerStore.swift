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
    /// Non-nil while `uploadMany` is running so the Tracker view can render a
    /// progress row. `.done` counts completed rows (ok or failed), `.total` is
    /// the batch size.
    @Published private(set) var uploadProgress: (done: Int, total: Int)?

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

    /// Delete a target from the private inbox. Must go server-side too: without it
    /// the next `refresh()` re-adds the row (server wins in `merge`). On failure
    /// the row stays visible so local and server stay consistent.
    func delete(id: String) async {
        await delete(ids: [id])
    }

    func delete(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        do {
            try await CaptureService.delete(ids: Array(ids))
            players.removeAll { ids.contains($0.id) }
            save()
            lastError = nil
        } catch {
            lastError = AppError.map(error).errorDescription
        }
    }

    /// Promote one capture into the shared crew DB (players + software), then
    /// stamp `uploaded_at` on the private capture row. Extracted from
    /// `TrackedPlayerDetailView` so the multi-select bar can reuse it.
    func uploadOne(id: String, actor: Actor) async throws {
        guard let p = players.first(where: { $0.id == id }) else { return }
        let input = PlayerInput(
            username: p.username,
            playerID: p.playerID,
            crew: p.crew,
            crewRank: (p.crew?.isEmpty == false) ? CrewRank.member.rawValue : nil,
            currentIP: p.currentIP,
            level: p.level,
            firewall: p.firewall,
            reputation: p.reputation,
            notes: nil,
            walletAddress: p.walletAddress
        )
        let player: Player
        if let existing = try await PlayerService.findExisting(
            playerID: p.playerID, username: p.username
        ) {
            player = try await PlayerService.update(id: existing.id, input: input, actor: actor)
        } else {
            player = try await PlayerService.create(input, actor: actor)
        }
        if !p.software.isEmpty {
            try await SoftwareService.uploadInstalled(playerID: player.id, software: p.software)
        }
        try await CaptureService.markUploaded(id: p.id)
        markUploaded(id: p.id)
    }

    /// Sequentially upload a selection. Sequential is deliberate:
    /// `PlayerService.findExisting` falls back to case-insensitive username, so
    /// parallelising a batch with no `player_id` yet could double-insert.
    func uploadMany(ids: Set<String>, actor: Actor) async -> (ok: Int, failed: Int) {
        let list = Array(ids)
        guard !list.isEmpty else { return (0, 0) }
        uploadProgress = (0, list.count)
        defer { uploadProgress = nil }
        var ok = 0, failed = 0
        for (i, id) in list.enumerated() {
            do {
                try await uploadOne(id: id, actor: actor)
                ok += 1
            } catch {
                failed += 1
            }
            uploadProgress = (i + 1, list.count)
        }
        return (ok, failed)
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
