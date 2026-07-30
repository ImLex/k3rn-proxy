import SwiftUI

@MainActor
final class CrewsModel: ObservableObject {
    @Published private(set) var crews: [CrewGroup] = []
    @Published private(set) var unassigned = 0
    @Published private(set) var loading = true
    @Published var errorMessage: String?

    func load() async {
        errorMessage = nil
        do {
            let result = try await CrewService.load()
            crews = result.crews
            unassigned = result.unassigned
        } catch {
            errorMessage = AppError.map(error).errorDescription
        }
        loading = false
    }

    func moveCrew(_ index: Int, by offset: Int) async {
        let target = index + offset
        guard crews.indices.contains(target) else { return }
        crews.swapAt(index, target)
        do { try await CrewService.saveCrewOrder(crews.map(\.key)) }
        catch { errorMessage = AppError.map(error).errorDescription; await load() }
    }

    /// Move a member up/down, but only within its own rank group (guide §6).
    func moveMember(crewIndex: Int, memberIndex: Int, by offset: Int) async {
        guard crews.indices.contains(crewIndex) else { return }
        var members = crews[crewIndex].members
        let target = memberIndex + offset
        guard members.indices.contains(target),
              members[memberIndex].rank.tier == members[target].rank.tier else { return }
        members.swapAt(memberIndex, target)
        let key = crews[crewIndex].key
        crews[crewIndex] = CrewGroup(key: key,
                                     displayName: crews[crewIndex].displayName,
                                     members: members,
                                     position: crews[crewIndex].position)
        do { try await CrewService.saveMemberOrder(crewKey: key, orderedPlayerIDs: members.map(\.id)) }
        catch { errorMessage = AppError.map(error).errorDescription; await load() }
    }
}

struct CrewsView: View {
    let actor: Actor
    @StateObject private var model = CrewsModel()
    @State private var reordering = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let msg = model.errorMessage { ErrorBanner(message: msg) }

                    if model.crews.isEmpty && !model.loading {
                        EmptyState(systemImage: "person.3",
                                   title: "No crews yet",
                                   message: "Players with a crew tag will appear here.")
                    }

                    ForEach(Array(model.crews.enumerated()), id: \.element.id) { index, crew in
                        crewCard(crew, index: index)
                    }

                    if model.unassigned > 0 {
                        Text("\(model.unassigned) player\(model.unassigned == 1 ? "" : "s") unassigned")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Crews")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(reordering ? "Done" : "Reorder") { reordering.toggle() }
                }
            }
            .refreshable { await model.load() }
            .task { if model.loading { await model.load() } }
        }
    }

    private func crewCard(_ crew: CrewGroup, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(crew.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(crew.members.count)")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                if reordering {
                    reorderButtons(up: { await model.moveCrew(index, by: -1) },
                                   down: { await model.moveCrew(index, by: 1) })
                }
            }

            ForEach(Array(crew.members.enumerated()), id: \.element.id) { mIndex, member in
                HStack(spacing: 8) {
                    RankBadge(rank: member.rank)
                    if reordering {
                        Text(member.username).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        reorderButtons(up: { await model.moveMember(crewIndex: index, memberIndex: mIndex, by: -1) },
                                       down: { await model.moveMember(crewIndex: index, memberIndex: mIndex, by: 1) })
                    } else {
                        NavigationLink {
                            PlayerDetailView(playerID: member.id, actor: actor)
                        } label: {
                            HStack {
                                Text(member.username).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                CopyableIP(ip: member.currentIP, font: .mono(12))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 15))
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private func reorderButtons(up: @escaping () async -> Void,
                                down: @escaping () async -> Void) -> some View {
        HStack(spacing: 14) {
            Button { Task { await up() } } label: { Image(systemName: "chevron.up") }
            Button { Task { await down() } } label: { Image(systemName: "chevron.down") }
        }
        .foregroundStyle(Theme.accent)
        .buttonStyle(.plain)
    }
}
