import SwiftUI
import AppKit

struct DiffWindowView: View {
    // Shared with the row/sheets — the single source of truth for this repo. The window
    // observes it directly (no NotificationCenter) and refreshes it after its own commits.
    // @Bindable so the view re-renders on the VM's observable changes.
    @Bindable var vm: RepoViewModel

    private var repo: GitRepo { vm.repo }

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
    @State private var gitIdentity: (name: String, email: String) = ("", "")

    @State private var commits: [CommitEntry] = []
    @State private var selectedCommits: Set<String> = []
    @State private var showingSquashSheet = false
    @State private var loadingCommits = true
    @State private var loadingMoreCommits = false
    @State private var hasMoreCommits = true

    @State private var historyTab: HistoryTab = .commits
    @State private var stashes: [StashEntry] = []
    @State private var selectedStash: String?
    @State private var loadingStashes = true
    @State private var resetTargetCommit: CommitEntry?
    @State private var branchActionMode: MergeRebaseSheet.Mode?
    @State private var showingForcePushConfirm = false
    // The hosting NSWindow, captured so we can keep its (non-SwiftUI) title in sync.
    @State private var hostWindow: NSWindow?

    private let git = GitService()
    private let sizeLimit = 1_000_000
    private let commitPageSize = 10

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebarPanel
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 500)
                diffPanel
                    .frame(minWidth: 400, maxWidth: .infinity)
            }
            Divider()
            branchOpsBar
        }
        .frame(minWidth: 700, minHeight: 450)
        .background(DiffWindowAccessor { window in
            hostWindow = window
            window.title = DiffWindowManager.title(for: repo)
        })
        // Keep the window title live when the branch changes (e.g. a switch/merge/rebase).
        .onChange(of: repo.currentBranch) {
            hostWindow?.title = DiffWindowManager.title(for: repo)
        }
        .task {
            gitIdentity = await git.getUserIdentity(at: repo.url)
            await loadFiles()
            await loadCommits(reset: true)
            await loadStashes()
        }
        .onChange(of: selectedPath) { _, path in
            guard let path, let entry = files.first(where: { $0.id == path }) else { return }
            selectedCommits = []
            selectedStash = nil
            Task { await loadDiff(entry: entry) }
        }
        .onChange(of: selectedCommits) { _, hashes in
            guard !hashes.isEmpty else { return }
            selectedPath = nil
            selectedStash = nil
            // Show a diff only when a single commit is selected; multi-select is for squashing.
            if hashes.count == 1, let hash = hashes.first {
                Task { await loadCommitDiff(hash: hash) }
            } else {
                diffLines = []
                tooLarge = false
            }
        }
        .onChange(of: selectedStash) { _, ref in
            guard let ref else { return }
            selectedPath = nil
            selectedCommits = []
            Task { await loadStashDiff(ref: ref) }
        }
        // The shared VM bumps changeToken on any refresh (FSEvents, app-active, our own ops),
        // so we reload the window's lists in lockstep — no NotificationCenter needed.
        .onChange(of: vm.changeToken) {
            Task {
                await loadFiles()
                await refreshCommits()
                await loadStashes()
                // Refresh the diff only for a currently-selected file (its contents may have changed).
                // A selected commit's diff is historical and doesn't change on a working-tree refresh.
                if let path = selectedPath, let entry = files.first(where: { $0.id == path }) {
                    await loadDiff(entry: entry, showLoader: false)
                }
            }
        }
        .sheet(item: $resetTargetCommit) { commit in
            MoveBranchSheet(commit: commit, currentBranch: repo.currentBranch) { hard in
                Task { await resetToCommit(commit, hard: hard) }
            }
        }
        .sheet(isPresented: $showingSquashSheet) {
            SquashSheet(count: squashableCount ?? 0, defaultMessage: squashDefaultMessage) { message in
                Task { await squashSelectedCommits(message: message) }
            }
        }
        .sheet(item: $branchActionMode) { mode in
            MergeRebaseSheet(vm: vm, mode: mode)
        }
    }

    // MARK: - Branch operations bar (merge / rebase, plus continue / abort mid-operation)

    private var branchOpsBar: some View {
        HStack(spacing: 8) {
            if let branch = repo.currentBranch {
                Image(systemName: "arrow.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(branch)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Menu {
                    Button(action: { Task { await vm.push() } }) {
                        Label("Push", systemImage: "arrow.up")
                    }
                    Divider()
                    Button(role: .destructive, action: { showingForcePushConfirm = true }) {
                        Label("Force Push…", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Label(pushLabel, systemImage: "arrow.up")
                } primaryAction: {
                    Task { await vm.push() }
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.small)
                .disabled(vm.isOperating)
                .help("Push \(branch) to origin")
            }

            if let operation = repo.inProgressOperation {
                Label(operation.rawValue, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())

                Button("Continue") { Task { await vm.continueInProgress() } }
                    .controlSize(.small)
                    .disabled(vm.isOperating)
                Button("Abort", role: .destructive) { Task { await vm.abortInProgress() } }
                    .controlSize(.small)
                    .disabled(vm.isOperating)
            }

            if let error = vm.lastOperationError {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .help(error)
            }

            Spacer()

            Button(action: { branchActionMode = .merge }) {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .controlSize(.small)
            .disabled(vm.isOperating)

            Button(action: { branchActionMode = .rebase }) {
                Label("Rebase", systemImage: "arrow.triangle.pull")
            }
            .controlSize(.small)
            .disabled(vm.isOperating)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Force Push?", isPresented: $showingForcePushConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Force Push", role: .destructive) { Task { await vm.forcePush() } }
        } message: {
            Text("This force-pushes \(repo.currentBranch ?? "the current branch") to origin with --force-with-lease.\n\nIt can overwrite remote history.")
        }
    }

    // "Push" plus the ahead count when the branch is ahead of its upstream.
    private var pushLabel: String {
        if let ahead = repo.aheadCount, ahead > 0 { return "Push \(ahead)" }
        return "Push"
    }

    // Number of commits to squash, but only when the selection is the top N
    // contiguous commits (a soft reset can only collapse commits down from HEAD).
    private var squashableCount: Int? {
        let n = selectedCommits.count
        guard n >= 2, commits.count >= n else { return nil }
        let topIDs = Set(commits.prefix(n).map(\.id))
        return topIDs == selectedCommits ? n : nil
    }

    // Combined message seeded from the selected commits, oldest first.
    private var squashDefaultMessage: String {
        guard let n = squashableCount else { return "" }
        return commits.prefix(n).reversed().map(\.subject).joined(separator: "\n\n")
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
            changedFilesHeader
            Divider()
            if files.isEmpty && loadingFiles {
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

    // Header for the changed-files list with a single checkbox that toggles all
    // files between checked and unchecked.
    private var changedFilesHeader: some View {
        HStack(spacing: 6) {
            if !files.isEmpty {
                Toggle("", isOn: Binding(
                    get: { allFilesChecked },
                    set: { _ in toggleAllChecked() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(allFilesChecked ? "Uncheck all" : "Check all")
            }
            sectionHeader("CHANGED FILES", count: files.isEmpty ? nil : files.count)
        }
        .padding(.leading, files.isEmpty ? 0 : 10)
    }

    private var allFilesChecked: Bool {
        !files.isEmpty && files.allSatisfy { checkedPaths.contains($0.id) }
    }

    private func toggleAllChecked() {
        if allFilesChecked {
            checkedPaths.removeAll()
        } else {
            checkedPaths = Set(files.map { $0.id })
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
            List(selection: $selectedCommits) {
                ForEach(commits) { commit in
                    commitRow(commit).tag(commit.id)
                }
                if hasMoreCommits {
                    HStack {
                        Spacer()
                        Button(action: { Task { await loadCommits(reset: false) } }) {
                            HStack(spacing: 6) {
                                if loadingMoreCommits {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text("Load more")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(loadingMoreCommits)
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 4)
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
            if selectedCommits.count <= 1 {
                Button {
                    resetTargetCommit = commit
                } label: {
                    Label("Move current branch to this commit…", systemImage: "arrow.uturn.backward.circle")
                }
            }
            if let count = squashableCount {
                Divider()
                Button {
                    showingSquashSheet = true
                } label: {
                    Label("Squash \(count) commits…", systemImage: "arrow.triangle.merge")
                }
            } else if selectedCommits.count >= 2 {
                Divider()
                Button {} label: {
                    Label("Squash — select consecutive commits from the top", systemImage: "arrow.triangle.merge")
                }
                .disabled(true)
            }
        }
    }

    private var hasConflicts: Bool {
        files.contains { $0.status.contains("U") || ($0.status.first == "A" && $0.status.last == "A") || ($0.status.first == "D" && $0.status.last == "D") }
    }

    // "Name <email>", or just whichever is set — nil when neither is configured.
    private var gitIdentityText: String? {
        let name = gitIdentity.name, email = gitIdentity.email
        switch (name.isEmpty, email.isEmpty) {
        case (false, false): return "\(name) <\(email)>"
        case (false, true): return name
        case (true, false): return "<\(email)>"
        case (true, true): return nil
        }
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

                // The identity this commit will be authored with (repo-local, else global).
                HStack(spacing: 4) {
                    Image(systemName: gitIdentityText == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                        .font(.system(size: 10))
                    Text(gitIdentityText ?? "No git identity configured (git config user.name / user.email)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundStyle(gitIdentityText == nil ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(gitIdentityText ?? "This repo has no user.name / user.email configured")

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
            Button {
                openInVSCode(entry)
            } label: {
                Label("Open in VSCode", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button {
                NSWorkspace.shared.open(repo.url.appendingPathComponent(entry.path))
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }
            Divider()
            Button(role: .destructive) {
                Task { await discardFile(entry) }
            } label: {
                Label("Discard Changes", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private func openInVSCode(_ entry: FileEntry) {
        let url = repo.url.appendingPathComponent(entry.path)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            // VSCode not installed — fall back to the default app
            NSWorkspace.shared.open(url)
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
        if selectedCommits.count == 1, let hash = selectedCommits.first,
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
        } else if selectedPath == nil && selectedCommits.isEmpty && selectedStash == nil {
            Text("Select a file, commit, or stash to view changes")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedCommits.count > 1 {
            Text("\(selectedCommits.count) commits selected")
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
            // Keep the window open — clear the composer and refresh in place.
            commitMessage = ""
            checkedPaths.removeAll()
            await vm.refresh()
            await loadFiles()
            await refreshCommits()
        } catch {
            commitError = error.localizedDescription
        }
    }

    private func discardFile(_ entry: FileEntry) async {
        do {
            try await git.discardFileChanges(at: repo.url, filePath: entry.path, status: entry.status)
            if selectedPath == entry.id { selectedPath = nil; diffLines = [] }
            await vm.refresh()
            await loadFiles()
        } catch {
            debugLog("[ERROR] DiffWindowView discardFile: \(error)")
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
            if selectedPath == nil && selectedCommits.isEmpty {
                selectedPath = files.first?.id
            } else if let path = selectedPath, !currentIDs.contains(path) {
                // The selected file is gone (committed/discarded) — clear the stale diff.
                selectedPath = nil
                diffLines = []
            }
        } catch {
            debugLog("[ERROR] DiffWindowView loadFiles: \(error)")
        }
    }

    private func loadDiff(entry: FileEntry, showLoader: Bool = true) async {
        // On a background refresh (showLoader == false) keep the current diff on
        // screen instead of blanking to a spinner; just swap in the new content.
        if showLoader {
            loadingDiff = true
            tooLarge = false
            diffLines = []
        }
        defer { loadingDiff = false }
        do {
            let raw = try await entry.status.hasPrefix("??")
                ? git.getDiffUntracked(at: repo.url, filePath: entry.path)
                : git.getDiff(at: repo.url, filePath: entry.path)
            guard raw.utf8.count <= sizeLimit else { tooLarge = true; diffLines = []; return }
            tooLarge = false
            diffLines = parseDiff(raw)
        } catch {
            debugLog("[ERROR] DiffWindowView loadDiff: \(error)")
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
                debugLog("[ERROR] DiffWindowView loadCommits: \(error)")
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
                debugLog("[ERROR] DiffWindowView loadCommits(more): \(error)")
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
            // Drop any selected commits that no longer exist (e.g. history rewritten)
            let existing = Set(commits.map(\.id))
            selectedCommits.formIntersection(existing)
        } catch {
            debugLog("[ERROR] DiffWindowView refreshCommits: \(error)")
        }
    }

    private func loadCommitDiff(hash: String) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await git.getCommitDiff(at: repo.url, hash: hash)
            guard raw.utf8.count <= sizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            debugLog("[ERROR] DiffWindowView loadCommitDiff: \(error)")
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
            debugLog("[ERROR] DiffWindowView loadStashes: \(error)")
        }
    }

    private func loadStashDiff(ref: String) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await git.getStashDiff(at: repo.url, ref: ref)
            guard raw.utf8.count <= sizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            debugLog("[ERROR] DiffWindowView loadStashDiff: \(error)")
        }
    }

    // MARK: - Commit / stash actions

    private func resetToCommit(_ commit: CommitEntry, hard: Bool) async {
        do {
            _ = try await git.resetToCommit(at: repo.url, hash: commit.id, hard: hard)
            // Refresh the shared VM so the row (branch position + status) updates too.
            await vm.refresh()
            await loadFiles()
            await refreshCommits()
        } catch {
            debugLog("[ERROR] DiffWindowView resetToCommit: \(error)")
        }
    }

    private func squashSelectedCommits(message: String) async {
        guard let count = squashableCount else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await git.squashCommits(at: repo.url, count: count, message: trimmed)
            selectedCommits = []
            await vm.refresh()
            await loadFiles()
            await refreshCommits()
        } catch {
            debugLog("[ERROR] DiffWindowView squashSelectedCommits: \(error)")
        }
    }

    private func applyStash(_ stash: StashEntry, removeAfter: Bool) async {
        do {
            if removeAfter {
                _ = try await git.popStash(at: repo.url, ref: stash.id)
            } else {
                _ = try await git.applyStash(at: repo.url, ref: stash.id)
            }
            await vm.refresh()
            await loadFiles()
            await loadStashes()
        } catch {
            debugLog("[ERROR] DiffWindowView applyStash: \(error)")
        }
    }

    private func dropStash(_ stash: StashEntry) async {
        do {
            _ = try await git.dropStash(at: repo.url, ref: stash.id)
            if selectedStash == stash.id { selectedStash = nil; diffLines = [] }
            await loadStashes()
        } catch {
            debugLog("[ERROR] DiffWindowView dropStash: \(error)")
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
            // Drop low-signal header lines — the bold file header already shows the path
            if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename from")
                || line.hasPrefix("rename to") { continue }
            let kind: DiffLine.Kind
            if line.hasPrefix("+") { kind = .added }
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
        case "!": return .orange
        case "+": return .green
        default: return .gray
        }
    }
}

// Resolves the hosting NSWindow of a SwiftUI view so we can drive its (non-SwiftUI) title.
private struct DiffWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't attached to its window yet during makeNSView; resolve next runloop.
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
