import SwiftUI

/// Personal tracker: the targets this member has opened in-game, synced from
/// their private capture inbox + theft history, scored by the potential engine.
/// Sortable, filterable, and editable (single + multi delete).
struct TrackerView: View {
    let actor: Actor?
    @EnvironmentObject private var store: TrackerStore
    @AppStorage("user_level") private var userLevel = 0

    @State private var sort: TargetSort = .recent
    @State private var filters = TargetFilters()
    @State private var showFilters = false
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmBulkDelete = false

    /// Players paired with their live assessment, after filtering + sorting.
    private var visible: [(player: TrackedPlayer, assessment: TargetAssessment)] {
        let rows = store.players
            .filter { filters.matches($0) }
            .map { ($0, store.assessment(for: $0, userLevel: userLevel)) }
        return rows.sorted { a, b in
            switch sort {
            case .recent:     return (a.0.capturedAt ?? "") > (b.0.capturedAt ?? "")
            case .score:      return a.1.score > b.1.score
            case .level:      return (a.0.level ?? 0) > (b.0.level ?? 0)
            case .username:   return a.0.username.localizedCaseInsensitiveCompare(b.0.username) == .orderedAscending
            case .firewall:   return (a.0.firewall ?? 0) > (b.0.firewall ?? 0)
            case .reputation: return (a.0.reputation ?? 0) > (b.0.reputation ?? 0)
            }
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if store.players.isEmpty {
                    ScrollView {
                        if let e = store.lastError { ErrorBanner(message: e).padding(.horizontal) }
                        EmptyState(
                            systemImage: "scope",
                            title: "No tracked targets",
                            message: "Open a target in-game with the VPN on — it shows up here privately."
                        )
                    }
                    .refreshable { if actor != nil { await store.refresh() } }
                } else {
                    listContent
                }
            }
            .background(Theme.background)
            .navigationTitle("Targets")
            .toolbar { toolbarContent }
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .bottom) { if editMode == .active { deleteBar } }
            .sheet(isPresented: $showFilters) {
                TargetFilterSheet(filters: $filters)
            }
            .confirmationDialog("Delete \(selection.count) target\(selection.count == 1 ? "" : "s")?",
                                isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.delete(ids: selection)
                    selection.removeAll()
                    editMode = .inactive
                }
            }
        }
        .task { if actor != nil { await store.refresh() } }
    }

    private var listContent: some View {
        List(selection: $selection) {
            if let e = store.lastError {
                ErrorBanner(message: e)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if filters.activeCount > 0 {
                filterSummary.listRowBackground(Color.clear)
            }
            ForEach(visible, id: \.player.id) { item in
                NavigationLink {
                    TrackedPlayerDetailView(trackedID: item.player.id, actor: actor)
                } label: { row(item.player, item.assessment) }
                .listRowBackground(Theme.surface)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { store.delete(id: item.player.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .tag(item.player.id)
            }
        }
        .listStyle(.plain)
        .hideScrollBackground()
        .refreshable { if actor != nil { await store.refresh() } }
    }

    private var filterSummary: some View {
        HStack {
            Text("\(filters.activeCount) filter\(filters.activeCount == 1 ? "" : "s") active")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Clear") { filters = TargetFilters() }
                .font(.system(size: 13)).foregroundStyle(Theme.accent)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                withAnimation { editMode = editMode == .active ? .inactive : .active }
                selection.removeAll()
            } label: {
                Text(editMode == .active ? "Done" : "Edit")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(TargetSort.allCases) { s in Text(s.label).tag(s) }
                }
                Button {
                    showFilters = true
                } label: {
                    Label(filters.activeCount > 0 ? "Filters (\(filters.activeCount))" : "Filters",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
        }
    }

    private var deleteBar: some View {
        Button(role: .destructive) {
            if !selection.isEmpty { confirmBulkDelete = true }
        } label: {
            Text(selection.isEmpty ? "Select targets to delete" : "Delete \(selection.count)")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.md)
        }
        .disabled(selection.isEmpty)
        .foregroundStyle(selection.isEmpty ? Theme.textFaint : Theme.danger)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
    }

    private func row(_ p: TrackedPlayer, _ a: TargetAssessment) -> some View {
        HStack(spacing: Space.md) {
            ScoreBadge(score: a.score, band: a.band)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.sm) {
                    Text(p.username)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let lvl = p.level {
                        Text("Lv \(lvl)").font(.mono(12)).foregroundStyle(Theme.textSecondary)
                    }
                    if p.isUploaded {
                        Image(systemName: "checkmark.icloud")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }
                HStack(spacing: Space.xs) {
                    TagPill(label: a.activity.label, color: ScoreStyle.activityColor(a.activity))
                    TagPill(label: a.recommendation.label,
                            color: ScoreStyle.recommendationColor(a.recommendation))
                    if a.trend.direction != .unknown {
                        Image(systemName: ScoreStyle.trendIcon(a.trend.direction))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ScoreStyle.trendColor(a.trend.direction))
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(CryptoFormat.compact(p.cryptoHot))
                    .font(.mono(15, weight: .semibold)).foregroundStyle(Theme.crypto)
                Text("held").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Filter sheet for the Targets tab, modeled on the Search tab's `FilterSheet`
/// but with min/max ranges and per-software checkboxes from `HackExSoftware`.
struct TargetFilterSheet: View {
    @Binding var filters: TargetFilters
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var minLevel = ""
    @State private var maxLevel = ""
    @State private var minFirewall = ""
    @State private var maxFirewall = ""
    @State private var minReputation = ""
    @State private var playerID = ""
    @State private var software: Set<String> = []
    @State private var minSoftwareLevel = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Identity") {
                    TextField("Username contains", text: $username)
                    TextField("Player ID contains", text: $playerID)
                }
                Section("Level") {
                    TextField("Min level", text: $minLevel).keyboardType(.numberPad)
                    TextField("Max level", text: $maxLevel).keyboardType(.numberPad)
                }
                Section("Firewall") {
                    TextField("Min firewall", text: $minFirewall).keyboardType(.numberPad)
                    TextField("Max firewall", text: $maxFirewall).keyboardType(.numberPad)
                }
                Section("Reputation") {
                    TextField("Min reputation", text: $minReputation).keyboardType(.numbersAndPunctuation)
                }
                Section("Software") {
                    TextField("Min software level", text: $minSoftwareLevel).keyboardType(.numberPad)
                    ForEach(HackExSoftware.catalog, id: \.self) { name in
                        Button {
                            if software.contains(name) { software.remove(name) } else { software.insert(name) }
                        } label: {
                            HStack {
                                Text(name).foregroundColor(Theme.textPrimary)
                                Spacer()
                                if software.contains(name) {
                                    Image(systemName: "checkmark").foregroundColor(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .hideScrollBackground()
            .background(Theme.background)
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) { Button("Reset") { reset() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() } }
            }
            .onAppear(perform: hydrate)
        }
    }

    private func hydrate() {
        username = filters.username ?? ""
        minLevel = filters.minLevel.map(String.init) ?? ""
        maxLevel = filters.maxLevel.map(String.init) ?? ""
        minFirewall = filters.minFirewall.map(String.init) ?? ""
        maxFirewall = filters.maxFirewall.map(String.init) ?? ""
        minReputation = filters.minReputation.map(String.init) ?? ""
        playerID = filters.playerID ?? ""
        software = filters.software
        minSoftwareLevel = filters.minSoftwareLevel.map(String.init) ?? ""
    }

    private func reset() {
        filters = TargetFilters()
        dismiss()
    }

    private func apply() {
        filters.username = username.isEmpty ? nil : username
        filters.minLevel = Int(minLevel)
        filters.maxLevel = Int(maxLevel)
        filters.minFirewall = Int(minFirewall)
        filters.maxFirewall = Int(maxFirewall)
        filters.minReputation = Int(minReputation)
        filters.playerID = playerID.isEmpty ? nil : playerID
        filters.software = software
        filters.minSoftwareLevel = Int(minSoftwareLevel)
        dismiss()
    }
}
