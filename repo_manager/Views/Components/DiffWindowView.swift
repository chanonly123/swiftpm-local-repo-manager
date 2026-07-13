import SwiftUI
import AppKit

struct DiffWindowView: View {
    // Shared with the row/sheets — the single source of truth for this repo. The window
    // observes it directly (no NotificationCenter) and refreshes it after its own commits.
    // All repo data (changed files, diffs, commits, stashes, commit composer) lives on the VM;
    // the view keeps only its own presentation state (sheets, the host window).
    // @ObservedObject so the view re-renders on the VM's observable changes.
    @ObservedObject var vm: RepoViewModel

    private var repo: GitRepo { vm.repo }

    // Sheet / alert presentation — view-local UI state, not repo data.
    @State private var showingSquashSheet = false
    @State private var resetTargetCommit: CommitEntry?
    @State private var branchActionMode: MergeRebaseSheet.Mode?
    @State private var showingForcePushConfirm = false
    @State private var showNewBranchSheet = false
    @State private var showDeleteBranchSheet = false
    // The hosting NSWindow, captured so we can keep its (non-SwiftUI) title in sync.
    @State private var hostWindow: NSWindow?

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
        .overlay(alignment: .topTrailing) {
            BannerStackView(
                banners: vm.banners,
                onDismiss: { vm.dismissBanner($0) },
                onDismissAll: { vm.banners.removeAll() }
            )
        }
        .background(DiffWindowAccessor { window in
            hostWindow = window
            window.title = DiffWindowManager.title(for: repo)
        })
        // Keep the window title live when the branch changes (e.g. a switch/merge/rebase).
        .onChange(of: repo.currentBranch) {
            hostWindow?.title = DiffWindowManager.title(for: repo)
        }
        .task {
            await vm.loadDiffWindow()
        }
        .onChange(of: vm.selectedPath) { _, path in
            vm.onSelectPath(path)
        }
        .onChange(of: vm.selectedCommits) { _, hashes in
            vm.onSelectCommits(hashes)
        }
        .onChange(of: vm.selectedStash) { _, refs in
            vm.onSelectStash(refs)
        }
        .onChange(of: vm.selectedCommitFile) { _, path in
            vm.onSelectCommitFile(path)
        }
        // The shared VM bumps changeToken on any refresh (FSEvents, app-active, our own ops),
        // so we reload the window's lists in lockstep — no NotificationCenter needed.
        .onChange(of: vm.changeToken) {
            Task { await vm.reloadDiffWindow() }
        }
        .sheet(item: $resetTargetCommit) { commit in
            MoveBranchSheet(commit: commit, currentBranch: repo.currentBranch) { hard in
                Task { await vm.resetToCommit(commit, hard: hard) }
            }
        }
        .sheet(isPresented: $showingSquashSheet) {
            SquashSheet(count: vm.squashableCount ?? 0, defaultMessage: vm.squashDefaultMessage) { message in
                Task { await vm.squashSelectedCommits(message: message) }
            }
        }
        .sheet(item: $branchActionMode) { mode in
            MergeRebaseSheet(vm: vm, mode: mode)
        }
        .sheet(isPresented: $showNewBranchSheet) {
            NewBranchSheet(vm: vm)
        }
        .sheet(isPresented: $showDeleteBranchSheet) {
            DeleteBranchSheet(vm: vm)
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

                // Fetch button — refresh remote-tracking refs (ahead/behind, new branches).
                Button(action: { Task { await vm.fetch() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(vm.isOperating)
                .help("Fetch from origin")

                if repo.hasRemoteBranch {
                    Menu {
                        Button(action: { Task { await vm.push() } }) {
                            Label("Push", systemImage: "arrow.up")
                        }
                        Divider()
                        Button(role: .destructive, action: { showingForcePushConfirm = true }) {
                            Label("Force Push…", systemImage: "exclamationmark.triangle")
                        }
                    } label: {
                        Label(pushLabel, systemImage: vm.needsForcePush ? "exclamationmark.triangle" : "arrow.up")
                    } primaryAction: {
                        // After a rebase/squash/reset the local history diverges from origin, so a
                        // plain push would be rejected — default the primary action to force push.
                        if vm.needsForcePush {
                            showingForcePushConfirm = true
                        } else {
                            Task { await vm.push() }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .controlSize(.small)
                    .tint(vm.needsForcePush ? .orange : nil)
                    .disabled(vm.isOperating)
                    .help(vm.needsForcePush
                          ? "History was rewritten — force-push \(branch) to origin"
                          : "Push \(branch) to origin")
                } else {
                    // No remote branch yet — first push publishes it and sets upstream.
                    Button(action: { Task { await vm.publish() } }) {
                        Label("Publish", systemImage: "arrow.up.circle")
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(vm.isOperating)
                    .help("Publish \(branch) to origin and set it as the upstream")
                }

                // Ahead / behind of the upstream (or fork point for an unpublished branch).
                aheadBehindBadges

                // All branch / working-tree operations collapsed into one menu.
                Menu {
                    Button(action: { showNewBranchSheet = true }) {
                        Label("Switch or Create Branch…", systemImage: "arrow.triangle.branch")
                    }
                    Button(action: { Task { await vm.recheckout() } }) {
                        Label("Recheckout", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                    Button(action: { branchActionMode = .merge }) {
                        Label("Merge…", systemImage: "arrow.triangle.merge")
                    }
                    Button(action: { branchActionMode = .rebase }) {
                        Label("Rebase…", systemImage: "arrow.triangle.pull")
                    }
                    Divider()
                    Button(action: { Task { await vm.applyPatchFromFile() } }) {
                        Label("Apply Patch…", systemImage: "square.and.arrow.down.on.square")
                    }
                    Divider()
                    Button(role: .destructive, action: { showDeleteBranchSheet = true }) {
                        Label("Delete Branch…", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "lines.measurement.vertical")
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.small)
                .disabled(vm.isOperating)
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

            Spacer()

            if vm.isOperating {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
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

    // Ahead / behind badges shown next to the push/publish control.
    @ViewBuilder
    private var aheadBehindBadges: some View {
        if let ahead = repo.aheadCount, ahead > 0 {
            aheadBehindBadge(count: ahead, systemImage: "arrow.up", color: .blue)
        }
        if let behind = repo.behindCount, behind > 0 {
            aheadBehindBadge(count: behind, systemImage: "arrow.down", color: .orange)
        }
    }

    private func aheadBehindBadge(count: Int, systemImage: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    // "Push" plus the ahead count when the branch is ahead of its upstream.
    private var pushLabel: String {
        if vm.needsForcePush { return "Force Push" }
        if let ahead = repo.aheadCount, ahead > 0 { return "Push \(ahead)" }
        return "Push"
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
            if vm.files.isEmpty && vm.loadingFiles {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.files.isEmpty {
                Text("No changes")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $vm.selectedPath) {
                    ForEach(vm.files) { file in
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
            if !vm.files.isEmpty {
                Toggle("", isOn: Binding(
                    get: { vm.allFilesChecked },
                    set: { _ in vm.toggleAllChecked() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(vm.allFilesChecked ? "Uncheck all" : "Check all")
            }
            sectionHeader("CHANGED FILES", count: vm.files.isEmpty ? nil : vm.files.count)
        }
        .padding(.leading, vm.files.isEmpty ? 0 : 10)
    }

    // MARK: - History section (Commits / Stashes tabs)

    private var historySection: some View {
        VStack(spacing: 0) {
            Picker("", selection: $vm.historyTab) {
                Text("Commits")
                    .tag(HistoryTab.commits)
                Text(vm.stashes.isEmpty ? "Stashes" : "Stashes (\(vm.stashes.count))")
                    .tag(HistoryTab.stashes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch vm.historyTab {
            case .commits: commitsList
            case .stashes: stashesList
            }
        }
    }

    @ViewBuilder
    private var commitsList: some View {
        if vm.commits.isEmpty && vm.loadingCommits {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.commits.isEmpty {
            Text("No commits")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $vm.selectedCommits) {
                ForEach(vm.commits) { commit in
                    VStack(spacing: 0) {
                        commitRow(commit).tag(commit.id)
                        Divider()
                    }
                }
                if vm.hasMoreCommits {
                    HStack {
                        Spacer()
                        Button(action: { Task { await vm.loadCommits(reset: false) } }) {
                            HStack(spacing: 6) {
                                if vm.loadingMoreCommits {
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
                        .disabled(vm.loadingMoreCommits)
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
        if vm.loadingStashes {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.stashes.isEmpty {
            Text("No stashes")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $vm.selectedStash) {
                ForEach(vm.stashes) { stash in
                    VStack(spacing: 0) {
                        stashRow(stash).tag(stash.id)
                        Divider()
                    }
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
                Task { await vm.applyStash(stash, removeAfter: false) }
            } label: {
                Label("Apply Stash", systemImage: "tray.and.arrow.up")
            }
            Button {
                Task { await vm.applyStash(stash, removeAfter: true) }
            } label: {
                Label("Apply and Remove", systemImage: "tray.and.arrow.up.fill")
            }
            Divider()
            if vm.selectedStash.count >= 2 {
                if let range = vm.contiguousStashSelection {
                    Button {
                        Task { await vm.createStashDiff(range) }
                    } label: {
                        Label("Create Diff (\(range.count) stashes)…", systemImage: "doc.badge.plus")
                    }
                } else {
                    Button {} label: {
                        Label("Create Diff — select consecutive stashes", systemImage: "doc.badge.plus")
                    }
                    .disabled(true)
                }
            } else {
                Button {
                    Task { await vm.createStashDiff([stash]) }
                } label: {
                    Label("Create Diff…", systemImage: "doc.badge.plus")
                }
            }
            Divider()
            Button(role: .destructive) {
                Task { await vm.dropStash(stash) }
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
            } label: {
                Label("Copy SHA", systemImage: "doc.on.doc")
            }
            Divider()
            if vm.selectedCommits.count <= 1 {
                Button {
                    resetTargetCommit = commit
                } label: {
                    Label("Move current branch to this commit…", systemImage: "arrow.uturn.backward.circle")
                }
            }
            if let count = vm.squashableCount {
                Divider()
                Button {
                    showingSquashSheet = true
                } label: {
                    Label("Squash \(count) commits…", systemImage: "arrow.triangle.merge")
                }
            } else if vm.selectedCommits.count >= 2 {
                Divider()
                Button {} label: {
                    Label("Squash — select consecutive commits from the top", systemImage: "arrow.triangle.merge")
                }
                .disabled(true)
            }

            Divider()
            if vm.selectedCommits.count >= 2 {
                if let range = vm.contiguousCommitSelection {
                    Button {
                        Task { await vm.createCommitDiff(range) }
                    } label: {
                        Label("Create Diff (\(range.count) commits)…", systemImage: "doc.badge.plus")
                    }
                } else {
                    Button {} label: {
                        Label("Create Diff — select consecutive commits", systemImage: "doc.badge.plus")
                    }
                    .disabled(true)
                }
            } else {
                Button {
                    Task { await vm.createCommitDiff([commit]) }
                } label: {
                    Label("Create Diff…", systemImage: "doc.badge.plus")
                }
            }
        }
    }

    private var commitPanel: some View {
        VStack(spacing: 6) {
            if vm.hasUnresolvedConflicts {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Resolve merge conflicts before committing", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(vm.unresolvedConflicts.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CommitMessageEditor(text: $vm.commitMessage)
                    .frame(height: 60)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if vm.commitMessage.isEmpty {
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
                    Image(systemName: vm.gitIdentityText == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                        .font(.system(size: 10))
                    Text(vm.gitIdentityText ?? "No git identity configured (git config user.name / user.email)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundStyle(vm.gitIdentityText == nil ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(vm.gitIdentityText ?? "This repo has no user.name / user.email configured")

                if let error = vm.commitError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    Button(action: { Task { await vm.performCommit() } }) {
                        HStack(spacing: 4) {
                            if vm.isCommitting { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12) }
                            Text("Commit")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isCommitting || vm.checkedPaths.isEmpty)

                    Button(action: { Task { await vm.stashSelectedFiles() } }) {
                        Label("Stash", systemImage: "tray.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .disabled(vm.isCommitting || vm.checkedPaths.isEmpty)
                    .help("Stash the checked files")

                    Button(action: { Task { await vm.createSelectedFilesDiff() } }) {
                        Label("Create Diff", systemImage: "doc.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .disabled(vm.checkedPaths.isEmpty)
                    .help("Save a diff of the checked files")
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { vm.checkedPaths.contains(entry.id) },
                set: { checked in
                    if checked { vm.checkedPaths.insert(entry.id) }
                    else { vm.checkedPaths.remove(entry.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            // Left: change type (added / deleted / modified …).
            Text(badge(entry.status))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(badgeColor(entry.status))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(entry.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path)

            // Right: conflict/clean tick — only for files that came in as a conflict.
            // Green ✓ once the markers are gone (resolved/clean), orange ⚠ while unresolved.
            if vm.isConflict(entry.status) {
                Spacer(minLength: 4)
                let resolved = !vm.unresolvedConflicts.contains(entry.path)
                Image(systemName: resolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(resolved ? .green : .orange)
                    .help(resolved ? "Conflict resolved" : "Unresolved merge conflict")
            }
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
                Task { await vm.discardFile(entry) }
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

    // A single commit or stash is selected — GitHub-Desktop style, the panel splits into a list
    // of the files it touched (top) and the selected file's diff (bottom).
    private var isViewingRevision: Bool {
        vm.selectedCommits.count == 1 || vm.selectedStash.count == 1
    }

    @ViewBuilder
    private var diffPanel: some View {
        if isViewingRevision {
            VSplitView {
                commitFilesSection
                    .frame(minHeight: 100, idealHeight: 180)
                diffSection
                    .frame(minHeight: 200)
            }
        } else {
            diffSection
        }
    }

    // Header + the selected file's diff content.
    private var diffSection: some View {
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

    // The selected revision (a single commit or stash) whose files/metadata are shown.
    private var selectedCommit: CommitEntry? {
        guard vm.selectedCommits.count == 1, let hash = vm.selectedCommits.first else { return nil }
        return vm.commits.first { $0.id == hash }
    }

    private var selectedStashEntry: StashEntry? {
        guard vm.selectedStash.count == 1, let ref = vm.selectedStash.first else { return nil }
        return vm.stashes.first { $0.id == ref }
    }

    // Top of the revision panel: changed-files list (left) + commit metadata (right).
    private var commitFilesSection: some View {
        HSplitView {
            commitFilesList
                .frame(minWidth: 220, idealWidth: 340, maxWidth: .infinity)
            commitMetaSection
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 380)
        }
    }

    // File list for the selected commit / stash.
    private var commitFilesList: some View {
        VStack(spacing: 0) {
            sectionHeader("FILES CHANGED", count: vm.commitFiles.isEmpty ? nil : vm.commitFiles.count)
            Divider()
            if vm.loadingCommitFiles {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.commitFiles.isEmpty {
                Text("No files changed")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $vm.selectedCommitFile) {
                    ForEach(vm.commitFiles) { file in
                        commitFileRow(file).tag(file.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // Metadata for the selected commit (or stash): message, SHA, author, date, tags.
    private var commitMetaSection: some View {
        VStack(spacing: 0) {
            sectionHeader(selectedStashEntry != nil ? "STASH" : "COMMIT")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let commit = selectedCommit {
                        Text(commit.subject)
                            .font(.system(size: 12, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        metaField("SHA", value: commit.id, monospaced: true, copyable: true)
                        metaField("Author", value: commit.author)
                        metaField("Date", value: commit.relativeDate)
                        if !commit.tags.isEmpty {
                            metaField("Tags", value: commit.tags.joined(separator: ", "))
                        }
                    } else if let stash = selectedStashEntry {
                        Text(stash.message)
                            .font(.system(size: 12, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        metaField("Ref", value: stash.id, monospaced: true)
                        metaField("Date", value: stash.relativeDate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
    }

    // One labelled metadata field. `copyable` adds a small copy button (used for the SHA).
    private func metaField(_ label: String, value: String, monospaced: Bool = false, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                    .textSelection(.enabled)
                    .lineLimit(monospaced ? 1 : 2)
                    .truncationMode(.middle)
                if copyable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy \(label)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitFileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Text(badge(entry.status))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(badgeColor(entry.status))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(entry.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path)
        }
    }

    private var diffHeaderText: String {
        if let path = vm.selectedPath { return path }
        // In revision mode the header shows the selected file's path.
        if isViewingRevision, let file = vm.selectedCommitFile { return file }
        if vm.selectedCommits.count == 1, let hash = vm.selectedCommits.first,
           let commit = vm.commits.first(where: { $0.id == hash }) {
            return "\(commit.shortHash)  \(commit.subject)"
        }
        if vm.selectedStash.count == 1, let ref = vm.selectedStash.first,
           let stash = vm.stashes.first(where: { $0.id == ref }) {
            return "\(ref)  \(stash.message)"
        }
        return ""
    }

    @ViewBuilder
    private var diffContent: some View {
        if vm.loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.selectedPath == nil && vm.selectedCommits.isEmpty && vm.selectedStash.isEmpty {
            Text("Select a file, commit, or stash to view changes")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.selectedCommits.count > 1 {
            Text("\(vm.selectedCommits.count) commits selected")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.selectedStash.count > 1 {
            Text("\(vm.selectedStash.count) stashes selected")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.tooLarge {
            Text("Diff too large to display")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.diffLines.isEmpty {
            Text("No diff available")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffTextView(lines: vm.diffLines)
        }
    }

    // MARK: - Status badge helpers

    // Change-type badge only (added / deleted / modified / renamed / untracked). Conflict
    // state is shown separately by the right-side tick, so conflict statuses map to their
    // underlying change type here (e.g. AA→A, DD→D, UU→M).
    private func badge(_ xy: String) -> String {
        if xy == "??" { return "+" }
        if xy.hasPrefix("R") { return "R" }
        if xy.hasPrefix("A") || xy.hasSuffix("A") { return "A" }
        if xy.hasPrefix("D") || xy.hasSuffix("D") { return "D" }
        return "M"
    }

    private func badgeColor(_ xy: String) -> Color {
        switch badge(xy) {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R": return .blue
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
