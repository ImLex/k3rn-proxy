import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published var deepScan = false
    @Published var scanCount = 5000
    @Published private(set) var reveals: [String: RevealRequest] = [:]  // player_id -> row
    @Published var errorMessage: String?
    @Published private(set) var loading = true
    @Published var savingToggle = false
    @Published var savingCount = false

    let actor: Actor
    init(actor: Actor) { self.actor = actor }

    /// A reveal is in flight anywhere in the pool — blocks queuing another
    /// (single-lookup rule, also enforced in the DB).
    var hasPendingReveal: Bool { reveals.values.contains { $0.status == "pending" } }

    func reveal(for playerID: String) -> RevealRequest? { reveals[playerID] }

    /// Offline (signed-out): no session, so stop the spinner and show the gate.
    func setOffline() { loading = false }

    /// Settings + reveals come from the model; the target pool lives in the shared
    /// `ScanStore` so it persists across relaunch and stays put when Deep scan is
    /// turned back off.
    func load(store: ScanStore) async {
        errorMessage = nil
        async let settings = ScanService.fetchSettings()
        async let r = ScanService.fetchReveals()
        await store.refresh()
        do {
            let s = try await settings
            deepScan = s.deepScan
            scanCount = s.scanCount
            reveals = Dictionary(try await r.map { ($0.playerID, $0) },
                                 uniquingKeysWith: { first, _ in first })
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }

    func setDeepScan(_ on: Bool) async {
        savingToggle = true
        errorMessage = nil
        do {
            try await ScanService.setDeepScan(on, actor: actor)
            deepScan = on
        } catch {
            errorMessage = AppError.map(error).errorDescription
            deepScan = !on  // revert the toggle to reflect the failed write
        }
        savingToggle = false
    }

    func setScanCount(_ count: Int) async {
        savingCount = true
        errorMessage = nil
        do {
            try await ScanService.setScanCount(count, actor: actor)
            scanCount = count
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        savingCount = false
    }

    func queueReveal(_ playerID: String, store: ScanStore) async {
        errorMessage = nil
        do {
            try await ScanService.queueReveal(playerID: playerID, actor: actor)
            await load(store: store)  // pull the new pending row back
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
    }
}

/// Scan tab: the member's private Deep-scan target pool. Turning Deep scan on
/// makes the proxy boost the member's next in-game scan and capture the full pool
/// here (never promoted to the shared crew DB). Per-target "Reveal real IP" hijacks
/// the member's next in-game Bypass — single lookup, never looped.
struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var model: ScanModel
    @State private var confirmReveal: ScanTarget?
    @State private var search = ""
    @State private var countText = ""

    init(actor: Actor) { _model = StateObject(wrappedValue: ScanModel(actor: actor)) }

    /// Substring match over username, both IPs, and player id.
    private var filtered: [ScanTarget] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.targets }   // already sorted in the store
        return store.targets.filter { t in
            (t.username?.lowercased().contains(q) ?? false)
            || (t.ip?.lowercased().contains(q) ?? false)
            || (t.realIP?.lowercased().contains(q) ?? false)
            || t.playerID.lowercased().contains(q)
        }
    }

    private var isSyncing: Bool { model.loading || store.loading }

    var body: some View {
        NavigationView {
            ScrollView {
                // LazyVStack (not VStack) so only on-screen rows are built — a full
                // pool is thousands of targets and eager rendering crashes the app.
                LazyVStack(alignment: .leading, spacing: Space.lg) {
                    if let e = model.errorMessage { ErrorBanner(message: e) }
                    toggleCard
                    if isSyncing { syncingBanner }
                    if store.targets.isEmpty && !isSyncing {
                        EmptyState(
                            systemImage: "dot.radiowaves.left.and.right",
                            title: "No scanned targets yet",
                            message: "Turn on Deep scan, then run Scan in-game with the VPN on. Your full target pool syncs here privately."
                        )
                    } else if !store.targets.isEmpty {
                        summary
                        searchField
                        if filtered.isEmpty {
                            Text("No matches for \u{201C}\(search)\u{201D}")
                                .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, Space.lg)
                        } else {
                            ForEach(filtered) { row($0) }
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Scan")
            .refreshable { await model.load(store: store) }
        }
        .task {
            countText = "\(model.scanCount)"
            if model.loading { await model.load(store: store); countText = "\(model.scanCount)" }
        }
        .confirmationDialog(
            "Reveal real IP?",
            isPresented: Binding(
                get: { confirmReveal != nil },
                set: { if !$0 { confirmReveal = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmReveal
        ) { target in
            Button("Reveal (uses next Bypass)") {
                let pid = target.playerID
                Task { await model.queueReveal(pid, store: store) }
                confirmReveal = nil
            }
            Button("Cancel", role: .cancel) { confirmReveal = nil }
        } message: { _ in
            Text("This hijacks your next in-game Bypass to unmask this target. That Bypass won't hit its intended victim — it auto-aborts once the IP is read.")
        }
    }

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Toggle(isOn: Binding(
                    get: { model.deepScan },
                    set: { on in Task { await model.setDeepScan(on) } }
                )) {
                    Text("Deep scan").font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .disabled(model.savingToggle)
                .tint(Theme.accent)
            }
            Text("When on, your next in-game Scan captures the full target pool here. The in-game scan screen still shows its normal count.")
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)

            Divider().overlay(Theme.border)

            HStack(spacing: Space.sm) {
                Text("Scan amount").font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                TextField("5000", text: $countText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.mono(15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 80)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    let n = max(1, Int(countText.filter(\.isNumber)) ?? model.scanCount)
                    countText = "\(n)"
                    Task { await model.setScanCount(n) }
                } label: {
                    if model.savingCount { ProgressView().tint(Theme.accent) }
                    else { Text("Set").font(.system(size: 14, weight: .semibold)) }
                }
                .disabled(model.savingCount || countText.filter(\.isNumber).isEmpty)
                .foregroundColor(Theme.accent)
            }
            Text("How many players the next boosted scan captures. The addon reads this on its next refresh.")
                .font(.system(size: 12)).foregroundColor(Theme.textFaint)
        }
        .cardStyle(padding: Space.md)
    }

    private var syncingBanner: some View {
        HStack(spacing: Space.sm) {
            ProgressView().tint(Theme.accent)
            Text("Syncing target pool… this can take a moment after a big scan.")
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
    }

    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.textFaint)
            TextField("Search username, IP, or ID", text: $search)
                .font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textFaint)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, Space.md)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var summary: some View {
        HStack(spacing: Space.md) {
            StatTile(label: "Pool", value: "\(store.targets.count)", color: Theme.accent,
                     hint: search.isEmpty ? "scanned players" : "\(filtered.count) shown")
            StatTile(label: "Revealed",
                     value: "\(store.targets.filter { $0.realIP != nil }.count)",
                     color: Theme.crypto,
                     hint: model.hasPendingReveal ? "1 pending" : "real IPs")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ t: ScanTarget) -> some View {
        let reveal = model.reveal(for: t.playerID)
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text(t.username ?? "—").font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary).lineLimit(1)
                if let lvl = t.level { TagPill(label: "Lv \(lvl)", color: Theme.info) }
                Spacer()
                if let fw = t.firewall { stat("FW", "\(fw)", Theme.orange) }
                if let rep = t.reputation { stat("REP", "\(rep)", Theme.textSecondary) }
            }
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.realIP ?? t.ip ?? "—")
                        .font(.mono(13, weight: .semibold))
                        .foregroundColor(t.realIP != nil ? Theme.crypto : Theme.textSecondary)
                    Text(t.realIP != nil ? "real ip" : "masked ip")
                        .font(.system(size: 10)).foregroundColor(Theme.textFaint)
                }
                Spacer()
                revealControl(t, reveal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
    }

    @ViewBuilder
    private func revealControl(_ t: ScanTarget, _ reveal: RevealRequest?) -> some View {
        // Keyed on the target's own real_ip, not the reveal row: when a target
        // scrambles its IP the DB clears real_ip, so the button re-arms for a
        // fresh reveal even though an old reveal row is still marked "done".
        if t.realIP != nil {
            TagPill(label: "revealed", color: Theme.crypto)
        } else if reveal?.status == "pending" {
            TagPill(label: "pending", color: Theme.orange)
        } else {
            Button {
                confirmReveal = t
            } label: {
                Text("Reveal IP").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(model.hasPendingReveal ? Theme.textFaint : Theme.accent)
            }
            .disabled(model.hasPendingReveal)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.mono(14, weight: .semibold)).foregroundColor(color)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(Theme.textFaint)
        }
    }
}
