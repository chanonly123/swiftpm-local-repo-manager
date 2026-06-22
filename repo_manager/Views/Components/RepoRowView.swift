import SwiftUI

struct RepoRowView: View {
    let repo: GitRepo
    let isSelected: Bool
    let isOperating: Bool
    let xcodeProjects: [XcodeProject]
    let isPerformingOperation: Bool
    let onToggle: () -> Void
    var onAddDependencies: (XcodeProject) -> Void = { _ in }
    var onRemoveDependencies: (XcodeProject) -> Void = { _ in }
    var onToggleRunScripts: (XcodeProject) -> Void = { _ in }
    var onCreateBranch: (GitRepo, String, Bool) -> Void = { _, _, _ in }
    var onSwitchBranch: (GitRepo, String, Bool) -> Void = { _, _, _ in }

    @State private var showNewBranchSheet = false

    var body: some View {
        HStack(spacing: 10) {
            // Selection checkbox
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .blue : .secondary)
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
                    if isOperating {
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
                    Text(repo.hasUncommittedChanges ? "Changes" : "Clean")
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
                .disabled(isPerformingOperation)
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

            // Branch switch / create button
            Button(action: { showNewBranchSheet = true }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Switch or Create Branch")
            .disabled(repo.status == .loading || isPerformingOperation)

            // Diff / History button
            Button(action: {
                DiffWindowManager.open(for: repo)
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
            isOperating ? Color.orange.opacity(0.08) :
                isSelected ? Color.blue.opacity(0.08) : Color.clear
        )
        .cornerRadius(4)
        .opacity(isOperating ? 0.8 : 1.0)
        .sheet(isPresented: $showNewBranchSheet) {
            NewBranchSheet(
                repo: repo,
                onSwitch: { name, stashChanges in onSwitchBranch(repo, name, stashChanges) },
                onCreate: { name, stashChanges in onCreateBranch(repo, name, stashChanges) }
            )
        }
    }

    @ViewBuilder
    private func xcodeActions(for project: XcodeProject) -> some View {
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
                print("[ERROR] Failed to open terminal: \(error)")
            }
        }
    }
}
