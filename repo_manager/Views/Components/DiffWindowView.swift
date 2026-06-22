import SwiftUI
import AppKit

private struct FileEntry: Identifiable {
    let id: String
    let status: String
    let path: String
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

private struct CommitEntry: Identifiable {
    let id: String          // full hash
    let shortHash: String
    let subject: String
    let author: String
    let relativeDate: String
    let tags: [String]
}

private struct StashEntry: Identifiable {
    let id: String          // ref, e.g. "stash@{0}"
    let message: String
    let relativeDate: String
}

private struct DiffLine: Identifiable {
    let id: Int
    let text: String
    let kind: Kind
    var showSeparator = false   // draw a horizontal rule above this line (file boundary)
    enum Kind { case added, removed, hunk, meta, context, fileHeader }
}

private enum HistoryTab: Hashable { case commits, stashes }

struct DiffWindowView: View {
    let repo: GitRepo

    @State private var files: [FileEntry] = []
    @State private var selectedPath: String?
    @State private var diffLines: [DiffLine] = []
    @State private var loadingFiles = true
    @State private var loadingDiff = false
    @State private var tooLarge = false
    @State private var checkedPaths: Set<String> = []
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var commitError: String?

    @State private var commits: [CommitEntry] = []
    @State private var selectedCommit: String?
    @State private var loadingCommits = true
    @State private var loadingMoreCommits = false
    @State private var hasMoreCommits = true

    @State private var historyTab: HistoryTab = .commits
    @State private var stashes: [StashEntry] = []
    @State private var selectedStash: String?
    @State private var loadingStashes = true
    @State private var resetTargetCommit: CommitEntry?

    private let git = GitService()
    private let sizeLimit = 100_000
    private let commitPageSize = 10

    var body: some View {
        HSplitView {
            sidebarPanel
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 500)
            diffPanel
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        .frame(minWidth: 700, minHeight: 450)
        .task {
            await loadFiles()
            await loadCommits(reset: true)
            await loadStashes()
        }
        .onChange(of: selectedPath) { _, path in
            guard let path, let entry = files.first(where: { $0.id == path }) else { return }
            selectedCommit = nil
            selectedStash = nil
            Task { await loadDiff(entry: entry) }
        }
        .onChange(of: selectedCommit) { _, hash in
            guard let hash else { return }
            selectedPath = nil
            selectedStash = nil
            Task { await loadCommitDiff(hash: hash) }
        }
        .onChange(of: selectedStash) { _, ref in
            guard let ref else { return }
            selectedPath = nil
            selectedCommit = nil
            Task { await loadStashDiff(ref: ref) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoFilesDidChange)) { note in
            guard (note.object as? URL) == repo.url else { return }
            Task {
                await loadFiles()
                await refreshCommits()
                await loadStashes()
                // Refresh the diff only for a currently-selected file (its contents may have changed).
                // A selected commit's diff is historical and doesn't change on a working-tree refresh.
                if let path = selectedPath, let entry = files.first(where: { $0.id == path }) {
                    await loadDiff(entry: entry)
                }
            }
        }
        .sheet(item: $resetTargetCommit) { commit in
            MoveBranchSheet(commit: commit, currentBranch: repo.currentBranch) { hard in
                Task { await resetToCommit(commit, hard: hard) }
            }
        }
    }

    // MARK: - Sidebar (Changed files + History)

    private var sidebarPanel: some View {
        VSplitView {
            fileListSection
                .frame(minHeight: 160)
            historySection
                .frame(minHeight: 140)
        }
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Changed files section

    private var fileListSection: some View {
        VStack(spacing: 0) {
            sectionHeader("CHANGED FILES", count: files.isEmpty ? nil : files.count)
            Divider()
            if loadingFiles {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                Text("No changes")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPath) {
                    ForEach(files) { file in
                        fileRow(file).tag(file.id)
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            commitPanel
        }
    }

    // MARK: - History section (Commits / Stashes tabs)

    private var historySection: some View {
        VStack(spacing: 0) {
            Picker("", selection: $historyTab) {
                Text("Commits")
                    .tag(HistoryTab.commits)
                Text(stashes.isEmpty ? "Stashes" : "Stashes (\(stashes.count))")
                    .tag(HistoryTab.stashes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch historyTab {
            case .commits: commitsList
            case .stashes: stashesList
            }
        }
    }

    @ViewBuilder
    private var commitsList: some View {
        if loadingCommits {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if commits.isEmpty {
            Text("No commits")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedCommit) {
                ForEach(commits) { commit in
                    commitRow(commit).tag(commit.id)
                }
                if hasMoreCommits {
                    Button(action: { Task { await loadCommits(reset: false) } }) {
                        HStack(spacing: 6) {
                            if loadingMoreCommits {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            }
                            Text("Load more")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .disabled(loadingMoreCommits)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var stashesList: some View {
        if loadingStashes {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stashes.isEmpty {
            Text("No stashes")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedStash) {
                ForEach(stashes) { stash in
                    stashRow(stash).tag(stash.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func stashRow(_ stash: StashEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stash.message)
                .font(.system(size: 12))
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(stash.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(stash.relativeDate)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(stash.message)
        .contextMenu {
            Button {
                Task { await applyStash(stash, removeAfter: false) }
            } label: {
                Label("Apply Stash", systemImage: "tray.and.arrow.up")
            }
            Button {
                Task { await applyStash(stash, removeAfter: true) }
            } label: {
                Label("Apply and Remove", systemImage: "tray.and.arrow.up.fill")
            }
            Divider()
            Button(role: .destructive) {
                Task { await dropStash(stash) }
            } label: {
                Label("Delete Stash", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func commitRow(_ commit: CommitEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
            if !commit.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(commit.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                            .help("Tag: \(tag)")
                    }
                }
            }
            HStack(spacing: 4) {
                Text(commit.shortHash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(commit.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.relativeDate)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help("\(commit.shortHash) — \(commit.subject)")
        .contextMenu {
            Button {
                resetTargetCommit = commit
            } label: {
                Label("Move current branch to this commit…", systemImage: "arrow.uturn.backward.circle")
            }
        }
    }

    private var hasConflicts: Bool {
        files.contains { $0.status.contains("U") || ($0.status.first == "A" && $0.status.last == "A") || ($0.status.first == "D" && $0.status.last == "D") }
    }

    private var commitPanel: some View {
        VStack(spacing: 6) {
            if hasConflicts {
                Label("Resolve merge conflicts before committing", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CommitMessageEditor(text: $commitMessage)
                    .frame(height: 60)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if commitMessage.isEmpty {
                            Text("Commit message")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 5)
                                .allowsHitTesting(false)
                        }
                    }

                if let error = commitError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: { Task { await performCommit() } }) {
                    HStack(spacing: 4) {
                        if isCommitting { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12) }
                        Text("Commit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommitting || checkedPaths.isEmpty)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { checkedPaths.contains(entry.id) },
                set: { checked in
                    if checked { checkedPaths.insert(entry.id) }
                    else { checkedPaths.remove(entry.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(badge(entry.status))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(badgeColor(entry.status))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(entry.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .help(entry.path)
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await discardFile(entry) }
            } label: {
                Label("Discard Changes", systemImage: "arrow.uturn.backward")
            }
        }
    }

    // MARK: - Diff panel

    private var diffPanel: some View {
        VStack(spacing: 0) {
            Text(diffHeaderText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            diffContent
        }
    }

    private var diffHeaderText: String {
        if let path = selectedPath { return path }
        if let hash = selectedCommit,
           let commit = commits.first(where: { $0.id == hash }) {
            return "\(commit.shortHash)  \(commit.subject)"
        }
        if let ref = selectedStash,
           let stash = stashes.first(where: { $0.id == ref }) {
            return "\(ref)  \(stash.message)"
        }
        return ""
    }

    @ViewBuilder
    private var diffContent: some View {
        if loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedPath == nil && selectedCommit == nil && selectedStash == nil {
            Text("Select a file, commit, or stash to view changes")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tooLarge {
            Text("Diff too large to display")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diffLines.isEmpty {
            Text("No diff available")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffTextView(lines: diffLines)
        }
    }

    // MARK: - Data loading

    private func performCommit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = files.filter { checkedPaths.contains($0.id) }.map { $0.path }
        guard !message.isEmpty, !paths.isEmpty else { return }
        isCommitting = true
        commitError = nil
        defer { isCommitting = false }
        do {
            try await git.stageFiles(at: repo.url, paths: paths)
            _ = try await git.commitStaged(at: repo.url, message: message)
            NotificationCenter.default.post(name: .repoDidCommit, object: repo.url)
            DiffWindowManager.close(for: repo)
        } catch {
            commitError = error.localizedDescription
        }
    }

    private func discardFile(_ entry: FileEntry) async {
        do {
            try await git.discardFileChanges(at: repo.url, filePath: entry.path, status: entry.status)
            if selectedPath == entry.id { selectedPath = nil; diffLines = [] }
            await loadFiles()
        } catch {
            print("[ERROR] DiffWindowView discardFile: \(error)")
        }
    }

    private func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let raw = try await git.getChangedFiles(at: repo.url)
            let previousIDs = Set(files.map { $0.id })
            files = raw.map { FileEntry(id: $0.path, status: $0.status, path: $0.path) }
            let currentIDs = Set(files.map { $0.id })
            // Preserve the user's checkbox choices; auto-check only newly-appeared files
            let appeared = currentIDs.subtracting(previousIDs)
            checkedPaths = checkedPaths.intersection(currentIDs).union(appeared)
            // Only auto-select the first file on the initial load (nothing selected yet).
            if selectedPath == nil && selectedCommit == nil {
                selectedPath = files.first?.id
            } else if let path = selectedPath, !currentIDs.contains(path) {
                // The selected file is gone (committed/discarded) — clear the stale diff.
                selectedPath = nil
                diffLines = []
            }
        } catch {
            print("[ERROR] DiffWindowView loadFiles: \(error)")
        }
    }

    private func loadDiff(entry: FileEntry) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await entry.status.hasPrefix("??")
                ? git.getDiffUntracked(at: repo.url, filePath: entry.path)
                : git.getDiff(at: repo.url, filePath: entry.path)
            guard raw.count <= sizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            print("[ERROR] DiffWindowView loadDiff: \(error)")
        }
    }

    private func loadCommits(reset: Bool) async {
        if reset {
            loadingCommits = true
            defer { loadingCommits = false }
            do {
                let raw = try await git.getCommitHistory(at: repo.url, skip: 0, limit: commitPageSize)
                commits = raw.map { CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags) }
                hasMoreCommits = raw.count == commitPageSize
            } catch {
                print("[ERROR] DiffWindowView loadCommits: \(error)")
            }
        } else {
            guard !loadingMoreCommits else { return }
            loadingMoreCommits = true
            defer { loadingMoreCommits = false }
            do {
                let raw = try await git.getCommitHistory(at: repo.url, skip: commits.count, limit: commitPageSize)
                let existing = Set(commits.map { $0.id })
                let newEntries = raw
                    .filter { !existing.contains($0.hash) }
                    .map { CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags) }
                commits.append(contentsOf: newEntries)
                hasMoreCommits = raw.count == commitPageSize
            } catch {
                print("[ERROR] DiffWindowView loadCommits(more): \(error)")
            }
        }
    }

    // Re-fetch history without collapsing the loaded page count or losing the selection.
    private func refreshCommits() async {
        let count = max(commitPageSize, commits.count)
        do {
            let raw = try await git.getCommitHistory(at: repo.url, skip: 0, limit: count)
            commits = raw.map { CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags) }
            hasMoreCommits = raw.count == count
            // Only drop the selection if the selected commit no longer exists (e.g. history rewritten)
            if let sel = selectedCommit, !commits.contains(where: { $0.id == sel }) {
                selectedCommit = nil
            }
        } catch {
            print("[ERROR] DiffWindowView refreshCommits: \(error)")
        }
    }

    private func loadCommitDiff(hash: String) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await git.getCommitDiff(at: repo.url, hash: hash)
            guard raw.count <= sizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            print("[ERROR] DiffWindowView loadCommitDiff: \(error)")
        }
    }

    private func loadStashes() async {
        loadingStashes = true
        defer { loadingStashes = false }
        do {
            let raw = try await git.getStashes(at: repo.url)
            stashes = raw.map { StashEntry(id: $0.ref, message: $0.message, relativeDate: $0.relativeDate) }
            // Drop a stale stash selection if it no longer exists (e.g. it was popped)
            if let sel = selectedStash, !stashes.contains(where: { $0.id == sel }) {
                selectedStash = nil
            }
        } catch {
            print("[ERROR] DiffWindowView loadStashes: \(error)")
        }
    }

    private func loadStashDiff(ref: String) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await git.getStashDiff(at: repo.url, ref: ref)
            guard raw.count <= sizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            print("[ERROR] DiffWindowView loadStashDiff: \(error)")
        }
    }

    // MARK: - Commit / stash actions

    private func resetToCommit(_ commit: CommitEntry, hard: Bool) async {
        do {
            _ = try await git.resetToCommit(at: repo.url, hash: commit.id, hard: hard)
            // Refreshes the repo list (branch position + status) and, in turn, this window
            NotificationCenter.default.post(name: .repoDidCommit, object: repo.url)
            await loadFiles()
            await refreshCommits()
        } catch {
            print("[ERROR] DiffWindowView resetToCommit: \(error)")
        }
    }

    private func applyStash(_ stash: StashEntry, removeAfter: Bool) async {
        do {
            if removeAfter {
                _ = try await git.popStash(at: repo.url, ref: stash.id)
            } else {
                _ = try await git.applyStash(at: repo.url, ref: stash.id)
            }
            NotificationCenter.default.post(name: .repoDidCommit, object: repo.url)
            await loadFiles()
            await loadStashes()
        } catch {
            print("[ERROR] DiffWindowView applyStash: \(error)")
        }
    }

    private func dropStash(_ stash: StashEntry) async {
        do {
            _ = try await git.dropStash(at: repo.url, ref: stash.id)
            if selectedStash == stash.id { selectedStash = nil; diffLines = [] }
            await loadStashes()
        } catch {
            print("[ERROR] DiffWindowView dropStash: \(error)")
        }
    }

    private func parseDiff(_ text: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var fileCount = 0
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.hasPrefix("diff --git") {
                fileCount += 1
                // Show the file path as a header, with a separator before every file after the first
                result.append(DiffLine(id: i, text: filePath(fromDiffGit: line), kind: .fileHeader, showSeparator: fileCount > 1))
                continue
            }
            if line.hasPrefix("index ") { continue }
            let kind: DiffLine.Kind
            if line.hasPrefix("+++") || line.hasPrefix("---") { kind = .meta }
            else if line.hasPrefix("+") { kind = .added }
            else if line.hasPrefix("-") { kind = .removed }
            else if line.hasPrefix("@@") { kind = .hunk }
            else { kind = .context }
            result.append(DiffLine(id: i, text: line, kind: kind))
        }
        return result
    }

    // Extract the file path from a "diff --git a/path b/path" line
    private func filePath(fromDiffGit line: String) -> String {
        let body = line.dropFirst("diff --git ".count)
        if let range = body.range(of: " b/") {
            return String(body[range.upperBound...])
        }
        return String(body)
    }

    // MARK: - Status badge helpers

    private func badge(_ xy: String) -> String {
        if xy == "??" { return "+" }
        if xy.contains("U") || (xy.first == "A" && xy.last == "A") { return "!" }
        if xy.hasPrefix("R") { return "R" }
        if xy.hasPrefix("A") || xy.hasSuffix("A") { return "A" }
        if xy.hasPrefix("D") || xy.hasSuffix("D") { return "D" }
        return "M"
    }

    private func badgeColor(_ xy: String) -> Color {
        switch badge(xy) {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "!": return .red
        case "+": return .green
        default: return .orange
        }
    }
}

extension Notification.Name {
    static let repoDidCommit = Notification.Name("repoDidCommit")
    static let repoFilesDidChange = Notification.Name("repoFilesDidChange")
}

// MARK: - Move-branch-to-commit (reset) sheet

private struct MoveBranchSheet: View {
    let commit: CommitEntry
    let currentBranch: String?
    let onConfirm: (Bool) -> Void   // hard

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ResetMode = .soft

    private enum ResetMode { case soft, hard }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move Branch to Commit")
                    .font(.headline)
                Text("\(currentBranch ?? "current branch")  →  \(commit.shortHash)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(commit.subject)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(.secondary)

            Picker("", selection: $mode) {
                Text("Soft — keep changes staged").tag(ResetMode.soft)
                Text("Hard — discard all changes").tag(ResetMode.hard)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if mode == .hard {
                Label("Permanently discards uncommitted changes and any commits after this one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .hard ? "Hard Reset" : "Soft Reset") {
                    onConfirm(mode == .hard)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Commit message editor with consistent text inset

private struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 4, height: 5)
        tv.textContainer?.lineFragmentPadding = 1
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        // Never touch the text storage while the user is actively typing — causes out-of-bounds crash
        guard !context.coordinator.isEditing else { return }
        if tv.string != text { tv.string = text }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var isEditing = false
        init(text: Binding<String>) { _text = text }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}

// MARK: - NSTextView wrapper for multi-line selection

private extension NSAttributedString.Key {
    static let fileSeparator = NSAttributedString.Key("diffFileSeparator")
}

// NSTextView that draws a full-width horizontal rule above any line carrying .fileSeparator
private final class DiffNSTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let inset = textContainerInset
        ts.enumerateAttribute(.fileSeparator, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let height: CGFloat = 4
            let y = (rect.minY + inset.height - 12).rounded()
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
        }
    }
}

private struct DiffTextView: NSViewRepresentable {
    let lines: [DiffLine]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = DiffNSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let attrString = NSMutableAttributedString()
        for line in lines {
            if line.kind == .fileHeader {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = line.showSeparator ? 100 : 2
                para.paragraphSpacing = 4
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: para
                ]
                if line.showSeparator { attrs[.fileSeparator] = true }
                attrString.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
                continue
            }
            let (fg, bg) = nsColors(line.kind)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: fg,
                .backgroundColor: bg
            ]
            attrString.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(attrString)
        textView.needsDisplay = true
    }

    private func nsColors(_ kind: DiffLine.Kind) -> (NSColor, NSColor) {
        switch kind {
        case .added:      return (.labelColor, NSColor.systemGreen.withAlphaComponent(0.15))
        case .removed:    return (.labelColor, NSColor.systemRed.withAlphaComponent(0.15))
        case .hunk:       return (.systemBlue, NSColor.systemBlue.withAlphaComponent(0.06))
        case .meta:       return (.secondaryLabelColor, .clear)
        case .context:    return (.labelColor, .clear)
        case .fileHeader: return (.labelColor, .clear)
        }
    }
}
