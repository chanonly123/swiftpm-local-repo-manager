import SwiftUI

// MARK: - Recheckout sheet (single repo)

// Per-repo equivalent of ContentView's batch recheckoutMenuView (reset mode only): stash,
// fetch, checkout -B, restore stash — offered against the current branch, main, or any
// branch picked from the dropdown.
struct RecheckoutSheet: View {
    @ObservedObject var vm: RepoViewModel

    private var repo: GitRepo { vm.repo }

    @Environment(\.dismiss) private var dismiss
    @State private var branches: [String] = []
    @State private var customBranchInput = ""

    // Share the repo's git actor so branch listing serializes with its operations.
    private var git: GitService { vm.gitService }

    // Recently used branches, shown as their own section above "All Branches" — only while
    // the field is empty; once the user starts typing, the ranked search below is enough.
    private var recentMatches: [RecentBranch] {
        guard customBranchInput.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return RecentBranchStore.recent(for: repo.url).filter { branches.contains($0.name) }
    }

    private var suggestions: [String] {
        BranchSearch.ranked(branches, query: customBranchInput, excluding: Set(recentMatches.map(\.name)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 16) {
                Text("Reset branch to origin (stash, fetch, checkout -B, restore stash)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top)

                Button(action: recheckoutCurrent) {
                    Label(
                        repo.currentBranch.map { "Current Branch (\($0))" } ?? "Current Branch",
                        systemImage: "arrow.branch"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(repo.currentBranch == nil)

                Button(action: { recheckout(to: "main") }) {
                    Label("main", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Divider()
                    .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Search or type a branch name", text: $customBranchInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { recheckout(to: customBranchInput) }

                        Button(action: { recheckout(to: customBranchInput) }) {
                            Label("Go", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customBranchInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    branchList
                }
            }
            .padding()

            Spacer()
        }
        .frame(width: 400, height: 460)
        .task {
            let fetched = (try? await git.getBranches(at: repo.url)) ?? []
            branches = fetched.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recheckout")
                    .font(.headline)
                Text(repo.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var branchList: some View {
        if !recentMatches.isEmpty || !suggestions.isEmpty {
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
                        branchRow(branch, icon: "arrow.triangle.branch")
                    }
                }
            }
            .frame(maxHeight: 130)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if branches.isEmpty {
            Text("Loading branches…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No matching branches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func branchRow(_ branch: String, icon: String) -> some View {
        Button(action: { recheckout(to: branch) }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private func recentBranchRow(_ recent: RecentBranch) -> some View {
        Button(action: { recheckout(to: recent.name) }) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(recent.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(recent.relativeDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private func recheckoutCurrent() {
        dismiss()
        Task { await vm.recheckout() }
    }

    private func recheckout(to branch: String) {
        let name = branch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        dismiss()
        Task { await vm.recheckout(toBranch: name) }
    }
}
