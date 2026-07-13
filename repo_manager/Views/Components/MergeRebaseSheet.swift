import SwiftUI

// MARK: - Merge / Rebase branch picker

// Picks an existing branch to merge into — or rebase the current branch onto.
// Mirrors NewBranchSheet's filtered suggestion list, but only offers branches that
// already exist (you can't merge/rebase against a branch that isn't there).
struct MergeRebaseSheet: View {
    enum Mode: String, Identifiable {
        case merge
        case rebase
        var id: String { rawValue }

        var title: String { self == .merge ? "Merge Branch" : "Rebase Branch" }
        var actionTitle: String { self == .merge ? "Merge" : "Rebase" }

        // Sentence describing what will happen to the current branch
        func summary(current: String) -> String {
            switch self {
            case .merge: return "Merge the selected branch into \(current)"
            case .rebase: return "Rebase \(current) onto the selected branch"
            }
        }
    }

    @ObservedObject var vm: RepoViewModel
    let mode: Mode

    private var repo: GitRepo { vm.repo }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var branches: [String] = []

    // Share the repo's git actor so branch listing serializes with its operations.
    private var git: GitService { vm.gitService }
    private let suggestionLimit = 50

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentBranch: String { repo.currentBranch ?? "current branch" }

    // Only existing branches other than the current one, ranked: prefix matches first,
    // then alphabetical.
    private var allMatches: [String] {
        BranchSearch.ranked(branches, query: trimmedQuery, excluding: repo.currentBranch.map { [$0] } ?? [])
    }

    private var suggestions: [String] { Array(allMatches.prefix(suggestionLimit)) }
    private var hiddenMatchCount: Int { max(0, allMatches.count - suggestions.count) }

    // The branch that the action would target — an exact name match, else the first suggestion.
    private var selectedBranch: String? {
        if branches.contains(trimmedQuery) { return trimmedQuery }
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

            if repo.hasUncommittedChanges {
                Label("This repo has uncommitted changes. \(mode.actionTitle) may fail until they're committed or stashed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

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
            Text(mode.title)
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
            Text(currentBranch)
                .fontWeight(.medium)
        }
        .font(.system(size: 12))
    }

    private var actionButtons: some View {
        HStack {
            if let branch = selectedBranch {
                Text(mode.summary(current: currentBranch).replacingOccurrences(of: "the selected branch", with: "“\(branch)”"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode.actionTitle, action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedBranch == nil)
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestions, id: \.self) { branch in
                            Button(action: { query = branch }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.branch")
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

    private func submit() {
        guard let branch = selectedBranch else { return }
        switch mode {
        case .merge: Task { await vm.merge(branch: branch) }
        case .rebase: Task { await vm.rebase(onto: branch) }
        }
        dismiss()
    }
}
