import SwiftUI
import Supabase

@MainActor
final class ActivityModel: ObservableObject {
    @Published var filters = ActivityFilters()
    @Published private(set) var logs: [AuditLog] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published private(set) var actions: [String] = []
    @Published var errorMessage: String?

    private var page = 0

    func reload() async {
        page = 0
        await fetch(reset: true)
        if actions.isEmpty { actions = (try? await ActivityService.knownActions()) ?? [] }
    }

    func loadMore() async {
        guard hasMore, !loading else { return }
        page += 1
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        loading = true
        errorMessage = nil
        do {
            let result = try await ActivityService.list(page: page, filters: filters)
            logs = reset ? result.logs : logs + result.logs
            hasMore = result.hasMore
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }
}

struct ActivityView: View {
    @StateObject private var model = ActivityModel()
    @EnvironmentObject private var nicknames: NicknameStore
    @State private var showFilters = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let msg = model.errorMessage { ErrorBanner(message: msg) }

                    if model.logs.isEmpty && !model.loading {
                        EmptyState(systemImage: "clock.arrow.circlepath", title: "No activity")
                    }

                    ForEach(model.logs) { log in
                        ExpandableAuditRow(log: log, nicknames: nicknames)
                            .onAppear {
                                if log.id == model.logs.last?.id { Task { await model.loadMore() } }
                            }
                    }

                    if model.loading { ProgressView().tint(Theme.accent).padding() }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                ActivityFilterSheet(filters: $model.filters, actions: model.actions) {
                    Task { await model.reload() }
                }
            }
            .task { if model.logs.isEmpty { await model.reload() } }
        }
    }
}

struct ExpandableAuditRow: View {
    let log: AuditLog
    let nicknames: NicknameStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                AuditRow(log: log, nicknames: nicknames)
            }
            .buttonStyle(.plain)

            if expanded {
                let diffs = computeDiff()
                if diffs.isEmpty {
                    Text("No field changes").font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(diffs, id: \.field) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.field).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            HStack(spacing: 6) {
                                Text(d.before).foregroundStyle(.red.opacity(0.85))
                                Image(systemName: "arrow.right").font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(d.after).foregroundStyle(Theme.accent)
                            }
                            .font(.mono(12))
                        }
                    }
                    .padding(.leading, 10)
                }
            }
        }
    }

    private struct Diff { let field: String; let before: String; let after: String }

    private func computeDiff() -> [Diff] {
        let before = log.before ?? [:]
        let after = log.after ?? [:]
        let keys = Set(before.keys).union(after.keys)
            .subtracting(["updated_at", "created_at", "id"])
            .sorted()
        var out: [Diff] = []
        for key in keys {
            let b = string(before[key])
            let a = string(after[key])
            if b != a { out.append(Diff(field: key, before: b, after: a)) }
        }
        return out
    }

    private func string(_ v: AnyJSON?) -> String {
        guard let v else { return "—" }
        switch v {
        case .null: return "∅"
        case let .string(s): return s.isEmpty ? "∅" : s
        case let .integer(i): return String(i)
        case let .double(d): return String(d)
        case let .bool(b): return String(b)
        default: return "…"
        }
    }
}

struct ActivityFilterSheet: View {
    @Binding var filters: ActivityFilters
    let actions: [String]
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var action = ""
    @State private var username = ""
    @State private var playerQuery = ""
    @State private var useFrom = false
    @State private var from = Date()
    @State private var useTo = false
    @State private var to = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Action") {
                    Picker("Action", selection: $action) {
                        Text("Any").tag("")
                        ForEach(actions, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Who / What") {
                    TextField("User (Discord name)", text: $username)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Player (username or id)", text: $playerQuery)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Date range") {
                    Toggle("From", isOn: $useFrom)
                    if useFrom { DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden() }
                    Toggle("To", isOn: $useTo)
                    if useTo { DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() } }
            }
            .onAppear(perform: hydrate)
        }
    }

    private func hydrate() {
        action = filters.action ?? ""
        username = filters.username ?? ""
        playerQuery = filters.playerQuery ?? ""
        if let f = filters.from { useFrom = true; from = f }
        if let t = filters.to { useTo = true; to = t }
    }

    private func apply() {
        filters.action = action.isEmpty ? nil : action
        filters.username = username.isEmpty ? nil : username
        filters.playerQuery = playerQuery.isEmpty ? nil : playerQuery
        filters.from = useFrom ? from : nil
        filters.to = useTo ? to : nil
        onApply()
        dismiss()
    }
}
