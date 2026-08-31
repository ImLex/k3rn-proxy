import SwiftUI

@MainActor
final class VirusModel: ObservableObject {
    @Published private(set) var spam: [VirusDeployment] = []
    @Published private(set) var siphon: [VirusDeployment] = []
    @Published var errorMessage: String?
    @Published private(set) var loading = true

    var totalRateHr: Double { spam.filter(\.active).compactMap(\.earningRateHr).reduce(0, +) }
    var totalSiphoned: Double { siphon.filter(\.active).compactMap(\.totalSiphoned).reduce(0, +) }
    var activeSpam: Int { spam.filter(\.active).count }
    var activeSiphon: Int { siphon.filter(\.active).count }

    /// Offline (signed-out): no server session, so stop the initial spinner and
    /// let the empty state show. Virus deployments aren't cached locally.
    func setOffline() { loading = false }

    func load() async {
        errorMessage = nil
        do {
            let rows = try await VirusService.fetchMine()
            spam = rows.filter(\.isSpam).sorted(by: Self.order)
            siphon = rows.filter { !$0.isSpam }.sorted(by: Self.order)
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }

    /// Permanently drop every inactive deployment of one kind. Gated on the
    /// server call so a failure leaves the rows on screen rather than splitting
    /// local and server state.
    func clearInactive(isSpam: Bool) async {
        let rows = (isSpam ? spam : siphon).filter { !$0.active }
        guard !rows.isEmpty else { return }
        do {
            try await VirusService.delete(ids: rows.map(\.id))
            if isSpam { spam.removeAll { !$0.active } }
            else { siphon.removeAll { !$0.active } }
            errorMessage = nil
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
    }

    /// Active first, then by earned descending.
    private static func order(_ a: VirusDeployment, _ b: VirusDeployment) -> Bool {
        if a.active != b.active { return a.active && !b.active }
        return (a.earned ?? 0) > (b.earned ?? 0)
    }
}

/// Virus tab: the member's OWN spam/siphon deployments and their earnings,
/// mirroring the Android companion's Virus screen. Data is captured passively
/// from the game's /v1/user_spam and /v1/user_siphon calls by the proxy.
struct VirusView: View {
    let actor: Actor?
    @StateObject private var model = VirusModel()
    /// Section titles that are currently collapsed. Dead deployments start folded
    /// away so live earnings are what you land on.
    @State private var collapsed: Set<String> = [SectionKey.spamInactive, SectionKey.siphonInactive]
    @State private var confirmClearSpam = false
    @State private var confirmClearSiphon = false

    private enum SectionKey {
        static let spam = "Spam"
        static let spamInactive = "Spam · inactive"
        static let siphon = "Siphon"
        static let siphonInactive = "Siphon · inactive"
    }

    private var inactiveSpam: [VirusDeployment] { model.spam.filter { !$0.active } }
    private var inactiveSiphon: [VirusDeployment] { model.siphon.filter { !$0.active } }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let e = model.errorMessage { ErrorBanner(message: e) }

                    if model.spam.isEmpty && model.siphon.isEmpty && !model.loading {
                        EmptyState(
                            systemImage: "ladybug",
                            title: actor == nil ? "Sign in to sync virus data" : "No deployments yet",
                            message: actor == nil
                                ? "Your spam and siphon deployments live in the crew database. Sign in with Discord to sync them."
                                : "Open your Spam or Siphon screen in-game with the VPN on — your deployments and earnings show up here."
                        )
                    } else {
                        summary
                        section(title: SectionKey.spam, rows: model.spam.filter(\.active))
                        section(title: SectionKey.spamInactive, rows: inactiveSpam,
                                onClear: { confirmClearSpam = true })
                        section(title: SectionKey.siphon, rows: model.siphon.filter(\.active))
                        section(title: SectionKey.siphonInactive, rows: inactiveSiphon,
                                onClear: { confirmClearSiphon = true })
                    }
                }
                .padding(Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Virus")
            .refreshable { if actor != nil { await model.load() } }
            .confirmationDialog(
                "Delete \(inactiveSpam.count) inactive spam deployment\(inactiveSpam.count == 1 ? "" : "s")? This can't be undone.",
                isPresented: $confirmClearSpam, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.clearInactive(isSpam: true) }
                }
            }
            .confirmationDialog(
                "Delete \(inactiveSiphon.count) inactive siphon deployment\(inactiveSiphon.count == 1 ? "" : "s")? This can't be undone.",
                isPresented: $confirmClearSiphon, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.clearInactive(isSpam: false) }
                }
            }
        }
        .task {
            if actor == nil { model.setOffline() }
            else if model.loading { await model.load() }
        }
    }

    private var summary: some View {
        HStack(spacing: Space.md) {
            StatTile(label: "Spam / hr",
                     value: Self.crypto(model.totalRateHr),
                     color: Theme.orange,
                     hint: "\(model.activeSpam) active")
            StatTile(label: "Siphoned",
                     value: Self.crypto(model.totalSiphoned),
                     color: Theme.crypto,
                     hint: "\(model.activeSiphon) active")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: Space.md)
    }

    /// `onClear` renders a sibling Clear button. It must stay a sibling of the
    /// collapse button — nesting a Button inside a Button fires both.
    @ViewBuilder
    private func section(title: String, rows: [VirusDeployment],
                         onClear: (() -> Void)? = nil) -> some View {
        if !rows.isEmpty {
            let isCollapsed = collapsed.contains(title)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Button {
                        withAnimation {
                            if isCollapsed { collapsed.remove(title) } else { collapsed.insert(title) }
                        }
                    } label: {
                        HStack {
                            SectionHeader(title: "\(title) (\(rows.count))")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textFaint)
                                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if let onClear {
                        Button(action: onClear) {
                            Text("Clear")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !isCollapsed {
                    ForEach(rows) { row($0) }
                }
            }
        }
    }

    private func row(_ d: VirusDeployment) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                CopyableIP(ip: d.ip, font: .mono(14, weight: .semibold))
                if let lvl = d.level {
                    TagPill(label: "Lv \(lvl)", color: Theme.info)
                }
                Spacer()
            }
            HStack(spacing: Space.md) {
                if d.isSpam {
                    stat("RATE/HR", Self.crypto(d.earningRateHr), Theme.orange)
                    stat("EARNED", Self.crypto(d.totalEarned), Theme.textPrimary)
                    if let age = d.ageDays { stat("AGE", "\(age)d", Theme.textSecondary) }
                } else {
                    stat("SIPHON", d.percent.map { "\(Self.trim($0))%" } ?? "—", Theme.crypto)
                    stat("PULLED", Self.crypto(d.totalSiphoned), Theme.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(d.active ? 1 : 0.5)
        .cardStyle(padding: Space.md)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.mono(15, weight: .semibold)).foregroundColor(color)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textFaint)
        }
    }

    // MARK: number formatting

    /// Compact crypto amount: 1.2K / 3.4M / 5.1B, else the trimmed number.
    private static func crypto(_ v: Double?) -> String {
        guard let v, v != 0 else { return v == nil ? "—" : "0" }
        let abs = Swift.abs(v)
        switch abs {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...:     return trim(v / 1_000_000) + "M"
        case 1_000...:         return trim(v / 1_000) + "K"
        default:               return trim(v)
        }
    }

    private static func trim(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}
