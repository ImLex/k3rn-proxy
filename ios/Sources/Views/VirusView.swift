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
    let actor: Actor
    @StateObject private var model = VirusModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let e = model.errorMessage { ErrorBanner(message: e) }

                    if model.spam.isEmpty && model.siphon.isEmpty && !model.loading {
                        EmptyState(
                            systemImage: "ladybug",
                            title: "No deployments yet",
                            message: "Open your Spam or Siphon screen in-game with the VPN on — your deployments and earnings show up here."
                        )
                    } else {
                        summary
                        section(title: "Spam", rows: model.spam)
                        section(title: "Siphon", rows: model.siphon)
                    }
                }
                .padding(Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Virus")
            .refreshable { await model.load() }
        }
        .task { if model.loading { await model.load() } }
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

    @ViewBuilder
    private func section(title: String, rows: [VirusDeployment]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader(title: title)
                ForEach(rows) { row($0) }
            }
        }
    }

    private func row(_ d: VirusDeployment) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(d.ip ?? "—").font(.mono(14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let lvl = d.level {
                    TagPill(label: "Lv \(lvl)", color: Theme.info)
                }
                Spacer()
                if !d.active { TagPill(label: "inactive", color: Theme.textFaint) }
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
