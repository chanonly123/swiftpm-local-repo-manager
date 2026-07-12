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

    // Convenience — the live repo data.
    private var repo: GitRepo { vm.repo }

    var body: some View {
        HStack(spacing: 10) {
            // Selection checkbox
            Button(action: { vm.isSelected.toggle() }) {
                Image(systemName: vm.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(vm.isSelected ? .blue : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(repo.status == .loading)

            // Repository name
            Text(repo.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 200, alignment: .leading)


            // Operation progress indicator
            Color.clear
                .frame(width: 20, height: 20)
                .overlay {
                    if vm.isOperating {
                        ProgressView()
                            .scaleEffect(0.4)
                    }
                }


            // Status indicator
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

            // Branch indicator
            if let branch = repo.currentBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.branch")
                        .font(.system(size: 11))
                    Text(branch)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }

            // Ahead / behind badges
            HStack(spacing: 4) {
                if let ahead = repo.aheadCount, ahead > 0 {
                    aheadBehindBadge(count: ahead, systemImage: "arrow.up", color: .blue)
                }
                if let behind = repo.behindCount, behind > 0 {
                    aheadBehindBadge(count: behind, systemImage: "arrow.down", color: .orange)
                }
            }

            // In-progress operation badge (mid-rebase / merge / cherry-pick / am)
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
                .help("\(operation.rawValue) in progress — use the git menu to continue or abort")
            }

            Spacer()

            // Xcode tasks menu (only when this repo contains Xcode projects)
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

            // Terminal button
            Button(action: {
                openInTerminal(url: repo.url)
            }) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in Terminal")

            // Git operations menu (merge / rebase, plus continue / abort when mid-operation)
            Menu {
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
                Button(action: { showNewBranchSheet = true }) {
                    Label("Switch or Create Branch…", systemImage: "arrow.triangle.branch")
                }
                Divider()
                Button(role: .destructive, action: { showDeleteBranchSheet = true }) {
                    Label("Delete Branch…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14))
                    .foregroundStyle(repo.inProgressOperation != nil ? .red : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(repo.inProgressOperation != nil ? "\(repo.inProgressOperation!.rawValue) in progress — Git Operations" : "Git Operations (Branches)")
            .disabled(repo.status == .loading || vm.isOperating)

            // Diff / History button
            Button(action: {
                DiffWindowManager.open(for: vm)
            }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Diff & History")
            .disabled(repo.status == .loading)

            // Path button
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
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            vm.isOperating ? Color.orange.opacity(0.08) :
                vm.isSelected ? Color.blue.opacity(0.08) : Color.clear
        )
        .cornerRadius(4)
        .opacity(vm.isOperating ? 0.8 : 1.0)
        .contentShape(Rectangle())
        // Double-click anywhere on the row opens the diff & history window.
        .onTapGesture(count: 2) {
            guard repo.status != .loading else { return }
            DiffWindowManager.open(for: vm)
        }
        .sheet(isPresented: $showNewBranchSheet) {
            NewBranchSheet(vm: vm)
        }
        .sheet(isPresented: $showDeleteBranchSheet) {
            DeleteBranchSheet(vm: vm)
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
            if let error {
                debugLog("[ERROR] Failed to open terminal: \(error)")
            }
        }
    }
}
