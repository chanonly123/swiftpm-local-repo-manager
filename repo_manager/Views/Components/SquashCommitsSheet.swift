import SwiftUI

// Quick squash sheet — reachable via right-click → Squash… on a repo row. Shows the most recent
// commits so the user can pick a contiguous run from HEAD to combine, without opening the full
// diff/history window.
struct SquashCommitsSheet: View {
    @ObservedObject var vm: RepoViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var commits: [CommitEntry] = []
    @State private var selectedIDs: Set<String> = []
    @State private var message = ""
    @State private var isLoading = true

    private static let recentLimit = 5

    private var git: GitService { vm.gitService }

    // Only a contiguous run starting at the most recent commit can be squashed — a soft reset
    // can only collapse commits down from HEAD.
    private var squashableCount: Int? {
        let n = selectedIDs.count
        guard n >= 2, commits.count >= n else { return nil }
        let topIDs = Set(commits.prefix(n).map(\.id))
        return topIDs == selectedIDs ? n : nil
    }

    private var defaultMessage: String {
        guard let n = squashableCount else { return "" }
        return commits.prefix(n).reversed().map(\.subject).joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if commits.isEmpty {
                Text("No commits to squash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                commitList

                if squashableCount != nil {
                    Text("Commit message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    messageEditor
                } else if selectedIDs.count >= 2 {
                    Label("Select a contiguous run starting from the most recent commit.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            actionButtons
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let raw = (try? await git.getCommitHistory(at: vm.repo.url, skip: 0, limit: Self.recentLimit)) ?? []
            commits = raw.map {
                CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags)
            }
            isLoading = false
        }
        .onChange(of: selectedIDs) { _, _ in
            if squashableCount != nil { message = defaultMessage }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Squash Commits")
                .font(.headline)
            Text(vm.repo.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commitList: some View {
        VStack(spacing: 0) {
            ForEach(commits) { commit in
                commitRow(commit)
                if commit.id != commits.last?.id {
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func commitRow(_ commit: CommitEntry) -> some View {
        let isSelected = selectedIDs.contains(commit.id)
        return Button(action: { toggle(commit.id) }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text("\(commit.shortHash) · \(commit.author) · \(commit.relativeDate)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private var messageEditor: some View {
        CommitMessageEditor(text: $message)
            .frame(height: 100)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }

    private var squashDisabled: Bool {
        squashableCount == nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Squash and Force Push") {
                performSquash(forcePush: true)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(squashDisabled)
            Button("Squash") {
                performSquash(forcePush: false)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(squashDisabled)
        }
    }

    private func performSquash(forcePush: Bool) {
        guard let count = squashableCount else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await vm.squash(count: count, message: trimmed)
            if forcePush && result.success {
                await vm.forcePush()
            }
        }
        dismiss()
    }
}
