import SwiftUI

// Create Diff sheet — reachable via right-click → Create Diff… on a repo row. Builds a patch
// file from a contiguous run of commits, a single stash, or the current uncommitted changes,
// and writes it to ~/Downloads.
struct CreateDiffSheet: View {
    @ObservedObject var vm: RepoViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Source: String, CaseIterable, Identifiable {
        case commits = "Commits"
        case stashes = "Stashes"
        case currentChanges = "Current Changes"
        var id: String { rawValue }
    }

    @State private var source: Source = .commits

    @State private var commits: [CommitEntry] = []
    @State private var selectedCommitIDs: Set<String> = []
    @State private var isLoadingCommits = true

    @State private var stashes: [StashEntry] = []
    @State private var selectedStashID: Int?
    @State private var isLoadingStashes = true

    @State private var changedFiles: [ChangedFileEntry] = []
    @State private var selectedFilePaths: Set<String> = []
    @State private var isLoadingChangedFiles = true

    private static let commitLimit = 30

    private var repo: GitRepo { vm.repo }
    private var git: GitService { vm.gitService }

    // Only a contiguous run (any position in the log, not necessarily from HEAD) makes a
    // coherent diff — the range is oldest-selected's parent through newest-selected.
    private var contiguousCommitRange: (oldest: CommitEntry, newest: CommitEntry)? {
        guard !selectedCommitIDs.isEmpty else { return nil }
        let indices = commits.indices.filter { selectedCommitIDs.contains(commits[$0].id) }
        guard let minIdx = indices.min(), let maxIdx = indices.max(), maxIdx - minIdx + 1 == indices.count else { return nil }
        return (oldest: commits[maxIdx], newest: commits[minIdx])
    }

    private var selectedStash: StashEntry? {
        stashes.first { $0.id == selectedStashID }
    }

    private var createDisabled: Bool {
        switch source {
        case .commits: return contiguousCommitRange == nil
        case .stashes: return selectedStash == nil
        case .currentChanges: return selectedFilePaths.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source {
            case .commits: commitsTab
            case .stashes: stashesTab
            case .currentChanges: currentChangesTab
            }

            actionButtons
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let raw = (try? await git.getCommitHistory(at: repo.url, skip: 0, limit: Self.commitLimit)) ?? []
            commits = raw.map {
                CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags)
            }
            isLoadingCommits = false

            stashes = (try? await git.getStashes(at: repo.url)) ?? []
            isLoadingStashes = false

            changedFiles = (try? await git.getChangedFiles(at: repo.url)) ?? []
            selectedFilePaths = Set(changedFiles.map(\.path))
            isLoadingChangedFiles = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Create Diff")
                .font(.headline)
            Text(repo.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Commits tab

    @ViewBuilder
    private var commitsTab: some View {
        if isLoadingCommits {
            ProgressView().frame(maxWidth: .infinity)
        } else if commits.isEmpty {
            Text("No commits in this repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select a contiguous run of commits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                commitList
                if contiguousCommitRange == nil && selectedCommitIDs.count > 1 {
                    Label("Selected commits must be contiguous.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var commitList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(commits) { commit in
                    commitRow(commit)
                    if commit.id != commits.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func commitRow(_ commit: CommitEntry) -> some View {
        let isSelected = selectedCommitIDs.contains(commit.id)
        return Button(action: { toggleCommit(commit.id) }) {
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

    private func toggleCommit(_ id: String) {
        if selectedCommitIDs.contains(id) {
            selectedCommitIDs.remove(id)
        } else {
            selectedCommitIDs.insert(id)
        }
    }

    // MARK: - Stashes tab

    @ViewBuilder
    private var stashesTab: some View {
        if isLoadingStashes {
            ProgressView().frame(maxWidth: .infinity)
        } else if stashes.isEmpty {
            Text("No stashes in this repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select a stash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                stashList
            }
        }
    }

    private var stashList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(stashes) { stash in
                    stashRow(stash)
                    if stash.id != stashes.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func stashRow(_ stash: StashEntry) -> some View {
        let isSelected = selectedStashID == stash.id
        return Button(action: { selectedStashID = stash.id }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(stash.message)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text("stash@{\(stash.id)}")
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

    // MARK: - Current changes tab

    @ViewBuilder
    private var currentChangesTab: some View {
        if isLoadingChangedFiles {
            ProgressView().frame(maxWidth: .infinity)
        } else if changedFiles.isEmpty {
            Text("No uncommitted changes in this repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select files to include in the diff.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                selectAllRow
                changedFilesList
            }
        }
    }

    private var allFilesSelected: Bool {
        !changedFiles.isEmpty && selectedFilePaths.count == changedFiles.count
    }

    private var selectAllRow: some View {
        Button(action: toggleSelectAll) {
            HStack(spacing: 8) {
                Image(systemName: allFilesSelected ? "checkmark.square.fill" : (selectedFilePaths.isEmpty ? "square" : "minus.square.fill"))
                    .foregroundStyle(selectedFilePaths.isEmpty ? Color.secondary : Color.blue)
                Text(allFilesSelected ? "Deselect All" : "Select All")
                    .font(.caption)
                Spacer()
                Text("\(selectedFilePaths.count) of \(changedFiles.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSelectAll() {
        selectedFilePaths = allFilesSelected ? [] : Set(changedFiles.map(\.path))
    }

    private var changedFilesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(changedFiles) { file in
                    changedFileRow(file)
                    if file.id != changedFiles.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func changedFileRow(_ file: ChangedFileEntry) -> some View {
        let isSelected = selectedFilePaths.contains(file.path)
        return Button(action: { toggleFile(file.path) }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(file.statusCode.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
                Text(file.path)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleFile(_ path: String) {
        if selectedFilePaths.contains(path) {
            selectedFilePaths.remove(path)
        } else {
            selectedFilePaths.insert(path)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Diff") { createDiff() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(createDisabled)
        }
    }

    private func createDiff() {
        let action: () async -> URL?
        switch source {
        case .commits:
            guard let range = contiguousCommitRange else { return }
            action = { await vm.createDiffFile(oldestCommit: range.oldest, newestCommit: range.newest) }
        case .stashes:
            guard let stash = selectedStash else { return }
            action = { await vm.createDiffFile(stash: stash) }
        case .currentChanges:
            let paths = Array(selectedFilePaths)
            action = { await vm.createDiffFileForCurrentChanges(paths: paths) }
        }
        Task {
            if let url = await action() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        dismiss()
    }
}
