import SwiftUI

/// Client-side ordering for the Search results (server returns `updated_at` DESC).
enum SearchSort: String, CaseIterable, Identifiable {
    case updated, level, firewall, reputation, username
    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return "Recently updated"
        case .level: return "Level"
        case .firewall: return "Firewall"
        case .reputation: return "Reputation"
        case .username: return "Username"
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var filters = PlayerFilters()
    @Published var sort: SearchSort = .updated
    @Published private(set) var players: [Player] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published var errorMessage: String?

    private var page = 0
    private var debounceTask: Task<Void, Never>?

    var activeFilterCount: Int {
        var n = 0
        if let c = filters.crew, !c.isEmpty { n += 1 }
        if filters.minLevel != nil { n += 1 }
        if filters.minFirewall != nil { n += 1 }
        if filters.minReputation != nil { n += 1 }
        if filters.updatedToday { n += 1 }
        if filters.hasPlayerID != nil { n += 1 }
        return n
    }

    /// Debounced reload triggered by the search field (~250 ms, guide §7).
    func onQueryChange() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await reload()
        }
    }

    func reload() async {
        page = 0
        await fetch(reset: true)
    }

    func loadMore() async {
        guard hasMore, !loading else { return }
        page += 1
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        loading = true
        errorMessage = nil
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if term.isEmpty {
                let result = try await PlayerService.list(page: page, filters: filters)
                apply(result.players, hasMore: result.hasMore, reset: reset)
            } else {
                // search_players returns the full set; filter + paginate client-side.
                let all = try await PlayerService.search(term)
                let filtered = applyClientFilters(all)
                let start = page * 50
                let slice = Array(filtered.dropFirst(start).prefix(50))
                apply(slice, hasMore: filtered.count > start + 50, reset: reset)
            }
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }

    /// Loaded results in the member's chosen order (applied over the fetched set).
    var sortedPlayers: [Player] {
        switch sort {
        case .updated:
            return players.sorted { (Formatting.date(from: $0.updatedAt) ?? .distantPast)
                > (Formatting.date(from: $1.updatedAt) ?? .distantPast) }
        case .level:      return players.sorted { ($0.level ?? 0) > ($1.level ?? 0) }
        case .firewall:   return players.sorted { ($0.firewall ?? 0) > ($1.firewall ?? 0) }
        case .reputation: return players.sorted { ($0.reputation ?? 0) > ($1.reputation ?? 0) }
        case .username:   return players.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
        }
    }

    private func apply(_ new: [Player], hasMore: Bool, reset: Bool) {
        players = reset ? new : players + new
        self.hasMore = hasMore
    }

    private func applyClientFilters(_ list: [Player]) -> [Player] {
        list.filter { p in
            if let c = filters.crew, !c.isEmpty,
               !(p.crew?.localizedCaseInsensitiveContains(c) ?? false) { return false }
            if let v = filters.minLevel, (p.level ?? Int.min) < v { return false }
            if let v = filters.minFirewall, (p.firewall ?? Int.min) < v { return false }
            if let v = filters.minReputation, (p.reputation ?? Int.min) < v { return false }
            if let has = filters.hasPlayerID {
                let present = !(p.playerID?.isEmpty ?? true)
                if present != has { return false }
            }
            if filters.updatedToday {
                let start = Calendar.current.startOfDay(for: Date())
                guard let d = Formatting.date(from: p.updatedAt), d >= start else { return false }
            }
            return true
        }
    }
}

struct SearchView: View {
    let actor: Actor
    @StateObject private var model = SearchModel()
    @State private var showFilters = false
    @State private var showAdd = false

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let msg = model.errorMessage { ErrorBanner(message: msg) }

                    if model.activeFilterCount > 0 {
                        HStack {
                            Text("\(model.activeFilterCount) filter\(model.activeFilterCount == 1 ? "" : "s") active")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("Clear") {
                                model.filters = PlayerFilters()
                                Task { await model.reload() }
                            }
                            .font(.system(size: 13)).foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 4)
                    }

                    if model.players.isEmpty && !model.loading {
                        EmptyState(systemImage: "magnifyingglass",
                                   title: "No players found",
                                   message: "Try a different search or adjust filters.")
                    }

                    ForEach(model.sortedPlayers) { player in
                        NavigationLink {
                            PlayerDetailView(playerID: player.id, actor: actor)
                        } label: { PlayerRow(player: player) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if player.id == model.sortedPlayers.last?.id { Task { await model.loadMore() } }
                        }
                    }

                    if model.loading { ProgressView().tint(Theme.accent).padding() }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Search")
            .searchable(text: $model.query, prompt: "Username, IP, crew, notes…")
            .onChange(of: model.query) { _ in model.onQueryChange() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $model.sort) {
                            ForEach(SearchSort.allCases) { s in Text(s.label).tag(s) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet(filters: $model.filters) { Task { await model.reload() } }
            }
            .sheet(isPresented: $showAdd) {
                PlayerFormView(mode: .create, actor: actor) { Task { await model.reload() } }
            }
            .task { if model.players.isEmpty { await model.reload() } }
        }
    }
}

struct FilterSheet: View {
    @Binding var filters: PlayerFilters
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var crew = ""
    @State private var minLevel = ""
    @State private var minFirewall = ""
    @State private var minReputation = ""
    @State private var updatedToday = false
    @State private var playerIDMode = 0   // 0 any, 1 has, 2 missing

    var body: some View {
        NavigationView {
            Form {
                Section("Crew") {
                    TextField("Crew tag contains", text: $crew)
                }
                Section("Minimums") {
                    TextField("Min level", text: $minLevel).keyboardType(.numberPad)
                    TextField("Min firewall", text: $minFirewall).keyboardType(.numberPad)
                    TextField("Min reputation", text: $minReputation).keyboardType(.numbersAndPunctuation)
                }
                Section {
                    Toggle("Updated today", isOn: $updatedToday)
                    Picker("Player ID", selection: $playerIDMode) {
                        Text("Any").tag(0)
                        Text("Has ID").tag(1)
                        Text("Missing ID").tag(2)
                    }
                }
            }
            .hideScrollBackground()
            .background(Theme.background)
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                }
            }
            .onAppear(perform: hydrate)
        }
    }

    private func hydrate() {
        crew = filters.crew ?? ""
        minLevel = filters.minLevel.map(String.init) ?? ""
        minFirewall = filters.minFirewall.map(String.init) ?? ""
        minReputation = filters.minReputation.map(String.init) ?? ""
        updatedToday = filters.updatedToday
        playerIDMode = filters.hasPlayerID == nil ? 0 : (filters.hasPlayerID == true ? 1 : 2)
    }

    private func apply() {
        filters.crew = crew.isEmpty ? nil : crew
        filters.minLevel = Int(minLevel)
        filters.minFirewall = Int(minFirewall)
        filters.minReputation = Int(minReputation)
        filters.updatedToday = updatedToday
        filters.hasPlayerID = playerIDMode == 0 ? nil : (playerIDMode == 1)
        onApply()
        dismiss()
    }
}
