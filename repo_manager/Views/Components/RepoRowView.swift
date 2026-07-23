import SwiftUI

struct RepoRowView: View {
    // The single source of truth for this repo — shared with its sheets and diff window.
    // @ObservedObject so the sheets below can bind to the VM; reading its @Published state in the
    // body (via `repo`, `vm.isSelected`, `vm.isOperating`) drives the row's updates.
    @ObservedObject var vm: RepoViewModel
    let xcodeProjects: [XcodeProject]
    // Xcode tasks stay coordinator concerns (they touch the project files + repo list).
    var onAddDependencies: (XcodeProject) -> Void = { _ in }
    var onRemoveDependencies: (XcodeProject) -> Void = { _ in }
    var onToggleRunScripts: (XcodeProject) -> Void = { _ in }

    @State private var showNewBranchSheet = false
    @State private var showDeleteBranchSheet = false
    @State private var showSquashSheet = false
    @State private var showForcePushConfirmation = false
    @State private var showHardResetConfirmation = false
    @State private var showRecheckoutSheet = false
    @State private var showCreateDiffSheet = false
    @State private var showApplyPatchPicker = false
    @State private var showApplyPatchConfirmation = false
    @State private var pendingPatchURL: URL?
    @State private var isHovering = false

    // Convenience — the live repo data.
    private var repo: GitRepo { vm.repo }

    var body: some View {
        HStack(spacing: 10) {
            selectionCheckbox
            repoName
            operationProgressIndicator
            statusIndicator
            branchIndicator
            aheadBehindBadges
            inProgressOperationBadge

            Spacer()

            xcodeTasksMenu
            terminalButton
            pathButton
            diffHistoryButton
        }
        .textSelection(.disabled)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            vm.isOperating ? Color.orange.opacity(0.08) :
                vm.isSelected ? Color.blue.opacity(0.08) :
                isHovering ? Color.primary.opacity(0.05) : Color.clear
        )
        .cornerRadius(4)
        .opacity(vm.isOperating ? 0.8 : 1.0)
        .contentShape(Rectangle())
        .contextMenu { gitOperationsMenuItems }
        .onHover { isHovering = $0 }
        // Double-click anywhere on the row opens the repo in the last-used Git client
        // (falling back to the first installed one).
        .onTapGesture(count: 2) {
            guard repo.status != .loading else { return }
            GitDesktopClient.default?.open(repoURL: repo.url)
        }
        .sheet(isPresented: $showNewBranchSheet) {
            NewBranchSheet(vm: vm)
        }
        .sheet(isPresented: $showDeleteBranchSheet) {
            DeleteBranchSheet(vm: vm)
        }
        .sheet(isPresented: $showSquashSheet) {
            SquashCommitsSheet(vm: vm)
        }
        .sheet(isPresented: $showRecheckoutSheet) {
            RecheckoutSheet(vm: vm)
        }
        .sheet(isPresented: $showCreateDiffSheet) {
            CreateDiffSheet(vm: vm)
        }
        .alert("⚠️ Force Push Warning", isPresented: $showForcePushConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Force Push", role: .destructive) {
                Task { await vm.forcePush() }
            }
        } message: {
            Text("This will force-push (--force-with-lease) \(repo.currentBranch ?? "the current branch") to origin for \(repo.name).\n\nThis may overwrite remote history.")
        }
        .alert("⚠️ Hard Reset Warning", isPresented: $showHardResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                Task { await vm.hardReset() }
            }
        } message: {
            Text("This will permanently discard ALL uncommitted changes and untracked files in \(repo.name).\n\nThis action CANNOT be undone.")
        }
        .alert("Apply Diff/Patch", isPresented: $showApplyPatchPicker) {
            ForEach(RecentPatchFileStore.recentPaths(for: repo.url), id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) {
                    pendingPatchURL = URL(fileURLWithPath: path)
                    showApplyPatchConfirmation = true
                }
            }
            Button("Choose File…") { choosePatchFile() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Select a recent patch file for \(repo.name), or choose a new one.")
        }
        .alert("Apply Diff/Patch", isPresented: $showApplyPatchConfirmation, presenting: pendingPatchURL) { patchURL in
            Button("Cancel", role: .cancel) { }
            Button("Apply") { applyPatch(patchURL) }
        } message: { patchURL in
            Text("Apply \(patchURL.lastPathComponent) to \(repo.name) using a 3-way merge (git apply --3way).\n\nConflicts, if any, are left as markers in the affected files — nothing is committed.")
        }
    }

    // MARK: - Row content

    // Selection checkbox
    private var selectionCheckbox: some View {
        Button(action: { vm.isSelected.toggle() }) {
            Image(systemName: vm.isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(vm.isSelected ? .blue : .secondary)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .disabled(repo.status == .loading)
    }

    // Repository name
    private var repoName: some View {
        Text(repo.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 200, alignment: .leading)
    }

    // Operation progress indicator
    private var operationProgressIndicator: some View {
        Color.clear
            .frame(width: 20, height: 20)
            .overlay {
                if vm.isOperating {
                    ProgressView()
                        .scaleEffect(0.4)
                }
            }
    }

    // Status indicator
    private var statusIndicator: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            if let changed = repo.changedFilesCount, changed > 0 {
                Text("\(changed) changed")
            } else if repo.status == .loading {
                Text("Loading...")
            } else {
                Text(repo.hasUncommittedChanges ? "Changes" : "")
            }
            if repo.hasConflicts {
                Text("⚠️")
                    .font(.system(size: 11))
                    .help("Merge conflicts detected")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
    }

    // Branch indicator
    @ViewBuilder
    private var branchIndicator: some View {
        if let branch = repo.currentBranch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.branch")
                    .font(.system(size: 11))
                Text(branch)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
    }

    // Ahead / behind badges
    private var aheadBehindBadges: some View {
        HStack(spacing: 4) {
            if let ahead = repo.aheadCount, ahead > 0 {
                aheadBehindBadge(count: ahead, systemImage: "arrow.up", color: .blue)
            }
            if let behind = repo.behindCount, behind > 0 {
                aheadBehindBadge(count: behind, systemImage: "arrow.down", color: .orange)
            }
        }
    }

    // In-progress operation badge (mid-rebase / merge / cherry-pick / am)
    @ViewBuilder
    private var inProgressOperationBadge: some View {
        if let operation = repo.inProgressOperation {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(operation.rawValue)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12))
            .clipShape(Capsule())
            .help("\(operation.rawValue) in progress — right-click the row to continue or abort")
        }
    }

    // Xcode tasks menu (only when this repo contains Xcode projects)
    @ViewBuilder
    private var xcodeTasksMenu: some View {
        if !xcodeProjects.isEmpty {
            Menu {
                if xcodeProjects.count == 1 {
                    xcodeActions(for: xcodeProjects[0])
                } else {
                    ForEach(xcodeProjects) { project in
                        Menu(project.relativePath(from: repo.url)) {
                            xcodeActions(for: project)
                        }
                    }
                }
            } label: {
                Image(systemName: "hammer")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Xcode Tasks")
            .disabled(vm.isOperating)
        }
    }

    // Terminal button
    private var terminalButton: some View {
        Button(action: {
            openInTerminal(url: repo.url)
        }) {
            Image(systemName: "terminal")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open in Terminal")
    }

    // Path button
    private var pathButton: some View {
        Button(action: {
            NSWorkspace.shared.open(repo.url)
        }) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open in Finder")
    }

    // Git operations menu items (merge / rebase, plus continue / abort when mid-operation) —
    // shown as a right-click context menu on the row rather than a dedicated toolbar button.
    @ViewBuilder
    private var gitOperationsMenuItems: some View {
        Group {
            if let operation = repo.inProgressOperation {
                Section("\(operation.rawValue) in progress") {
                    Button(action: { Task { await vm.continueInProgress() } }) {
                        Label("Continue \(operation.rawValue)", systemImage: "arrow.right.circle")
                    }
                    Button(role: .destructive, action: { Task { await vm.abortInProgress() } }) {
                        Label("Abort \(operation.rawValue)", systemImage: "xmark.circle")
                    }
                }
                Divider()
            }
            Button(action: { Task { await vm.fetch() } }) {
                Label("Fetch", systemImage: "arrow.down.circle")
            }
            Button(action: { showRecheckoutSheet = true }) {
                Label("Recheckout", systemImage: "arrow.clockwise.circle")
            }
            Divider()
            Button(action: { Task { await vm.stash() } }) {
                Label("Stash", systemImage: "tray.and.arrow.down")
            }
            Button(action: { Task { await vm.stashPop() } }) {
                Label("Stash Pop", systemImage: "tray.and.arrow.up")
            }
            Divider()
            Button(action: { showNewBranchSheet = true }) {
                Label("Switch or Create Branch…", systemImage: "arrow.triangle.branch")
            }
            Divider()
            Button(action: { startApplyPatch() }) {
                Label("Apply Diff/Patch…", systemImage: "doc.badge.plus")
            }
            Button(action: { showCreateDiffSheet = true }) {
                Label("Create Diff…", systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            Menu("Copy") {
                Button(action: { copyToClipboard(repo.url.path) }) {
                    Label("Directory Path", systemImage: "folder")
                }
                Button(action: { copyToClipboard(repo.name) }) {
                    Label("Directory Name", systemImage: "textformat")
                }
                if let branch = repo.currentBranch {
                    Button(action: { copyToClipboard(branch) }) {
                        Label("Branch Name", systemImage: "arrow.branch")
                    }
                }
            }
            Divider()
            if repo.currentBranch != nil {
                Button(action: {
                    Task {
                        if repo.hasRemoteBranch { await vm.push() } else { await vm.publish() }
                    }
                }) {
                    Label(
                        repo.hasRemoteBranch ? "Push" : "Publish",
                        systemImage: repo.hasRemoteBranch ? "arrow.up.circle" : "icloud.and.arrow.up"
                    )
                }
            }
            Button(role: .destructive, action: { showForcePushConfirmation = true }) {
                Label("Force Push", systemImage: "arrow.up.circle.fill")
            }
            Divider()
            Button(role: .destructive, action: { showHardResetConfirmation = true }) {
                Label("Reset", systemImage: "exclamationmark.triangle")
            }
            Button(action: { showSquashSheet = true }) {
                Label("Squash…", systemImage: "arrow.triangle.merge")
            }
            Divider()
            Button(role: .destructive, action: { showDeleteBranchSheet = true }) {
                Label("Delete Branch…", systemImage: "trash")
            }
        }
        .disabled(repo.status == .loading || vm.isOperating)
    }

    // Git client button — opens the repo in GitHub Desktop / SourceTree.
    // Shows a menu when both are installed, a single button when only one is.
    @ViewBuilder
    private var diffHistoryButton: some View {
        let clients = GitDesktopClient.installed
        if clients.count > 1 {
            Menu {
                ForEach(clients) { client in
                    Button(action: { client.open(repoURL: repo.url) }) {
                        Label("Open in \(client.displayName)", systemImage: client.systemImage)
                    }
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open in Git client")
            .disabled(repo.status == .loading)
        } else if let client = clients.first {
            Button(action: { client.open(repoURL: repo.url) }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in \(client.displayName)")
            .disabled(repo.status == .loading)
        }
    }

    @ViewBuilder
    private func xcodeActions(for project: XcodeProject) -> some View {
        Button(action: { NSWorkspace.shared.open(project.projectPath) }) {
            Label("Open in Xcode", systemImage: "hammer")
        }
        Divider()
        Button(action: { onAddDependencies(project) }) {
            Label("Add Local Dependencies", systemImage: "link.badge.plus")
        }
        Button(action: { onRemoveDependencies(project) }) {
            Label("Remove Local Dependencies", systemImage: "link.badge.minus")
        }
        Button(action: { onToggleRunScripts(project) }) {
            Label("Toggle Run Scripts", systemImage: "play.slash")
        }
    }

    @ViewBuilder
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

    private var statusColor: Color {
        switch repo.status {
        case .clean:
            return .green
        case .uncommittedChanges:
            return .orange
        case .error:
            return .red
        case .loading:
            return .gray
        }
    }

    // Offer the repo's recent patch files if we have any; otherwise go straight to the picker.
    private func startApplyPatch() {
        if RecentPatchFileStore.recentPaths(for: repo.url).isEmpty {
            choosePatchFile()
        } else {
            showApplyPatchPicker = true
        }
    }

    private func choosePatchFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a diff/patch file to apply to \(repo.name)"
        if let recent = RecentPatchFileStore.recent(for: repo.url) {
            panel.directoryURL = recent.deletingLastPathComponent()
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pendingPatchURL = url
            showApplyPatchConfirmation = true
        }
    }

    private func applyPatch(_ patchURL: URL) {
        RecentPatchFileStore.save(patchURL, for: repo.url)
        Task {
            let didAccess = patchURL.startAccessingSecurityScopedResource()
            defer { if didAccess { patchURL.stopAccessingSecurityScopedResource() } }
            await vm.applyPatch(patchURL: patchURL)
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func openInTerminal(url: URL) {
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "'\\''")
        let myAppleScript = """
            tell application "Terminal"
                do script "cd '\(escapedPath)'; clear"
                activate
            end tell
            """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: myAppleScript) {
            scriptObject.executeAndReturnError(&error)
        }
    }
}
