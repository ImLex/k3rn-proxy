import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    @Published private(set) var targets: [ScanTarget] = []
    @Published var deepScan = false
    @Published private(set) var reveals: [String: RevealRequest] = [:]  // player_id -> row
    @Published var errorMessage: String?
    @Published private(set) var loading = true
    @Published var savingToggle = false

    let actor: Actor
    init(actor: Actor) { self.actor = actor }

    var sortedTargets: [ScanTarget] {
        targets.sorted { ($0.lastScannedAt ?? "") > ($1.lastScannedAt ?? "") }
    }

    /// A reveal is in flight anywhere in the pool — blocks queuing another
    /// (single-lookup rule, also enforced in the DB).
    var hasPendingReveal: Bool { reveals.values.contains { $0.status == "pending" } }

    func reveal(for playerID: String) -> RevealRequest? { reveals[playerID] }

    /// Offline (signed-out): no session, so stop the spinner and show the gate.
    func setOffline() { loading = false }

    func load() async {
        errorMessage = nil
        do {
            async let t = ScanService.fetchMine()
            async let d = ScanService.fetchDeepScan()
            async let r = ScanService.fetchReveals()
            targets = try await t
            deepScan = try await d
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

    func queueReveal(_ playerID: String) async {
        errorMessage = nil
        do {
            try await ScanService.queueReveal(playerID: playerID, actor: actor)
            await load()  // pull the new pending row back
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
    @StateObject private var model: ScanModel
    @State private var confirmReveal: ScanTarget?

    init(actor: Actor) { _model = StateObject(wrappedValue: ScanModel(actor: actor)) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let e = model.errorMessage { ErrorBanner(message: e) }
                    toggleCard
                    if model.targets.isEmpty && !model.loading {
                        EmptyState(
                            systemImage: "dot.radiowaves.left.and.right",
                            title: "No scanned targets yet",
                            message: "Turn on Deep scan, then run Scan in-game with the VPN on. Your full target pool syncs here privately."
                        )
                    } else if !model.targets.isEmpty {
                        summary
                        ForEach(model.sortedTargets) { row($0) }
                    }
                }
                .padding(Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Scan")
            .refreshable { await model.load() }
        }
        .task { if model.loading { await model.load() } }
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
                Task { await model.queueReveal(pid) }
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
        }
        .cardStyle(padding: Space.md)
    }

    private var summary: some View {
        HStack(spacing: Space.md) {
            StatTile(label: "Pool", value: "\(model.targets.count)", color: Theme.accent,
                     hint: "scanned players")
            StatTile(label: "Revealed",
                     value: "\(model.reveals.values.filter { $0.realIP != nil }.count)",
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
        if t.realIP != nil || reveal?.status == "done" {
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
