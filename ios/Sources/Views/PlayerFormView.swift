import SwiftUI
import UIKit

struct PlayerFormView: View {
    enum Mode {
        case create
        case edit(Player)
    }

    let mode: Mode
    let actor: Actor
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = Validation.PlayerDraft()
    @State private var rank: CrewRank = .member
    @State private var errors = Validation.Errors()
    @State private var knownCrews: [String] = []
    @State private var saving = false
    @State private var errorMessage: String?

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var hasCrew: Bool {
        !draft.crew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                if let msg = errorMessage {
                    Section { ErrorBanner(message: msg) }
                }

                Section("Identity") {
                    field("Username", text: $draft.username, error: errors.username)
                    field("Player ID", text: $draft.playerID, error: errors.playerID)
                }

                Section("Crew") {
                    field("Crew tag", text: $draft.crew, error: errors.crew)
                    if !knownCrews.isEmpty && hasCrew {
                        crewSuggestions
                    }
                    if hasCrew {
                        Picker("Rank", selection: $rank) {
                            ForEach(CrewRank.allCases, id: \.self) { r in
                                Text(r.rawValue.capitalized).tag(r)
                            }
                        }
                    }
                }

                Section("Stats") {
                    field("Current IP", text: $draft.currentIP, error: errors.currentIP,
                          keyboard: .numbersAndPunctuation)
                    field("Level", text: $draft.level, error: errors.level, keyboard: .numberPad)
                    field("Firewall", text: $draft.firewall, error: errors.firewall, keyboard: .numberPad)
                    field("Reputation", text: $draft.reputation, error: errors.reputation,
                          keyboard: .numbersAndPunctuation)
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                    if let e = errors.notes { fieldError(e) }
                }
            }
            .hideScrollBackground()
            .background(Theme.background)
            .navigationTitle(isEdit ? "Edit Player" : "Add Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving)
                }
            }
            .task {
                hydrate()
                knownCrews = (try? await PlayerService.knownCrews()) ?? []
            }
        }
    }

    private var crewSuggestions: some View {
        let q = draft.crew.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = knownCrews.filter { $0.lowercased().contains(q) && $0.lowercased() != q }.prefix(5)
        return ForEach(Array(matches), id: \.self) { crew in
            Button {
                draft.crew = crew
            } label: {
                Label(crew, systemImage: "arrow.up.left")
                    .font(.system(size: 14)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, error: String?,
                       keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if let error { fieldError(error) }
        }
    }

    private func fieldError(_ msg: String) -> some View {
        Text(msg).font(.system(size: 12)).foregroundStyle(.red)
    }

    private func hydrate() {
        guard case let .edit(p) = mode else { return }
        draft.username = p.username
        draft.playerID = p.playerID ?? ""
        draft.crew = p.crew ?? ""
        draft.currentIP = p.currentIP ?? ""
        draft.level = p.level.map(String.init) ?? ""
        draft.firewall = p.firewall.map(String.init) ?? ""
        draft.reputation = p.reputation.map(String.init) ?? ""
        draft.notes = p.notes ?? ""
        rank = p.rank
    }

    private func save() async {
        errors = Validation.validate(draft)
        guard errors.isValid else { return }
        saving = true
        errorMessage = nil
        let input = PlayerInput.from(draft: draft, rank: rank)
        do {
            switch mode {
            case .create:
                _ = try await PlayerService.create(input, actor: actor)
            case let .edit(p):
                _ = try await PlayerService.update(id: p.id, input: input, actor: actor)
            }
            onSave()
            dismiss()
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        saving = false
    }
}
