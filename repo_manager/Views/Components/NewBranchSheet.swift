import SwiftUI

// MARK: - Branch switch / create sheet

struct NewBranchSheet: View {
    let repo: GitRepo
    let onSwitch: (String, Bool) -> Void   // (branch name, stash changes)
    let onCreate: (String, Bool) -> Void   // (branch name, stash changes)

    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var changeHandling: ChangeHandling = .bring
    @State private var branches: [String] = []

    private enum ChangeHandling { case bring, stash }

    private let git = GitService()

    private var trimmedName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // An exact match means we'll switch; anything else creates a new branch
    private var matchesExistingBranch: Bool {
        branches.contains(trimmedName)
    }

    private let suggestionLimit = 50

    // All branches matching what the user is typing (excluding the current one), sorted —
    // matches starting with the query rank first, then alphabetical.
    private var allMatches: [String] {
        let query = trimmedName.lowercased()
        return branches
            .filter { branch in
                branch != repo.currentBranch &&
                (query.isEmpty || branch.lowercased().contains(query)) &&
                branch != trimmedName
            }
            .sorted { a, b in
                let ap = a.lowercased().hasPrefix(query)
                let bp = b.lowercased().hasPrefix(query)
                if ap != bp { return ap }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
    }

    // Capped list actually rendered, to stay responsive with very many branches
    private var suggestions: [String] { Array(allMatches.prefix(suggestionLimit)) }

    private var hiddenMatchCount: Int { max(0, allMatches.count - suggestions.count) }

    private var actionTitle: String { matchesExistingBranch ? "Switch" : "Create" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch or Create Branch")
                    .font(.headline)
                Text(repo.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Source branch the new branch will be created from / switched away from
            HStack(spacing: 5) {
                Image(systemName: "arrow.branch")
                    .font(.system(size: 11))
                Text("Current")
                    .foregroundStyle(.secondary)
                Text(repo.currentBranch ?? "current branch")
                    .fontWeight(.medium)
            }
            .font(.system(size: 12))

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            suggestionList

            if repo.hasUncommittedChanges {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This repo has uncommitted changes:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $changeHandling) {
                        Text("Bring changes along").tag(ChangeHandling.bring)
                        Text("Stash changes first").tag(ChangeHandling.stash)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }

            HStack {
                if !trimmedName.isEmpty {
                    Text(matchesExistingBranch ? "Switch to existing branch" : "Create new branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            branches = (try? await git.getBranches(at: repo.url)) ?? []
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestions, id: \.self) { branch in
                            Button(action: { branchName = branch }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.branch")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text(branch)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
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
        guard !trimmedName.isEmpty else { return }
        let stash = changeHandling == .stash
        if matchesExistingBranch {
            onSwitch(trimmedName, stash)
        } else {
            onCreate(trimmedName, stash)
        }
        dismiss()
    }
}
