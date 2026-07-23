import SwiftUI

// MARK: - Delete branch sheet

// Picks an existing branch to delete. Mirrors MergeRebaseSheet's filtered suggestion
// list, but never offers the current branch (git won't delete a checked-out branch)
// and adds an optional toggle to also delete the branch on origin.
struct DeleteBranchSheet: View {
    @ObservedObject var vm: RepoViewModel

    private var repo: GitRepo { vm.repo }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var branches: [String] = []
    @State private var deleteRemote = false

    // Share the repo's git actor so branch listing serializes with its operations.
    private var git: GitService { vm.gitService }
    private let suggestionLimit = 50

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Recently used branches, shown as their own section above "All Branches" — only while
    // the field is empty; once the user starts typing, the ranked search below is enough.
    private var recentMatches: [RecentBranch] {
        guard trimmedQuery.isEmpty else { return [] }
        let current = repo.currentBranch
        return RecentBranchStore.recent(for: repo.url).filter { branches.contains($0.name) && $0.name != current }
    }

    // Existing branches other than the current one (a checked-out branch can't be deleted)
    // and anything already shown in the Recent section, ranked: prefix matches first, then
    // alphabetical.
    private var allMatches: [String] {
        var excluded = repo.currentBranch.map { Set([$0]) } ?? []
        excluded.formUnion(recentMatches.map(\.name))
        return BranchSearch.ranked(branches, query: trimmedQuery, excluding: excluded)
    }

    private var suggestions: [String] { Array(allMatches.prefix(suggestionLimit)) }
    private var hiddenMatchCount: Int { max(0, allMatches.count - suggestions.count) }

    // The branch that would be deleted — an exact name match, else the most recent branch
    // (when the field is empty), else the first suggestion. Never the current branch, so
    // deleting it is always safe.
    private var selectedBranch: String? {
        if trimmedQuery == repo.currentBranch { return nil }
        if branches.contains(trimmedQuery) { return trimmedQuery }
        if trimmedQuery.isEmpty { return recentMatches.first?.name ?? suggestions.first }
        return suggestions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            currentBranchRow

            TextField("Branch name", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            suggestionList

            Toggle(isOn: $deleteRemote) {
                Text("Also delete remote branch\(selectedBranch.map { " (origin/\($0))" } ?? "")")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            actionButtons
        }
        .padding(20)
        .frame(width: 600)
        .task {
            branches = (try? await git.getBranches(at: repo.url)) ?? []
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Delete Branch")
                .font(.headline)
            Text(repo.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var currentBranchRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.branch")
                .font(.system(size: 11))
            Text("Current")
                .foregroundStyle(.secondary)
            Text(repo.currentBranch ?? "current branch")
                .fontWeight(.medium)
            Text("(can't be deleted)")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
    }

    private var actionButtons: some View {
        HStack {
            if let branch = selectedBranch {
                Text("Delete “\(branch)”\(deleteRemote ? " locally and on origin" : " locally")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Delete", action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedBranch == nil)
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !recentMatches.isEmpty || !suggestions.isEmpty {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !recentMatches.isEmpty {
                            sectionHeader("Recent")
                            ForEach(recentMatches, id: \.name) { recent in
                                recentBranchRow(recent)
                            }
                            if !suggestions.isEmpty {
                                sectionHeader("All Branches")
                            }
                        }
                        ForEach(suggestions, id: \.self) { branch in
                            branchRow(branch, icon: "arrow.branch")
                        }
                    }
                }
                .frame(maxHeight: 140)

                if hiddenMatchCount > 0 {
                    Divider()
                    Text("\(hiddenMatchCount) more — keep typing to narrow")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }

    private func branchRow(_ branch: String, icon: String) -> some View {
        Button(action: { query = branch }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(branch)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if branch == selectedBranch {
                    Image(systemName: "return")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentBranchRow(_ recent: RecentBranch) -> some View {
        Button(action: { query = recent.name }) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(recent.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(recent.relativeDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if recent.name == selectedBranch {
                    Image(systemName: "return")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        guard let branch = selectedBranch else { return }
        let remote = deleteRemote
        Task { await vm.deleteBranch(name: branch, deleteRemote: remote) }
        dismiss()
    }
}
