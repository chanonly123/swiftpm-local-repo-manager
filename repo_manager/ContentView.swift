import SwiftUI

struct ContentView: View {
    @StateObject private var tabsManager = TabsManager()

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TabBarView(
                tabs: tabsManager.tabs,
                selectedTabID: tabsManager.selectedTabID,
                onSelectTab: { id in
                    tabsManager.selectTab(id)
                },
                onCloseTab: { id in
                    tabsManager.closeTab(id)
                },
                onAddTab: {
                    tabsManager.addTab()
                }
            )

            Divider()

            // Tab content
            if let viewModel = tabsManager.currentViewModel {
                TabContentView(
                    viewModel: viewModel,
                    updateAvailable: tabsManager.isUpdateAvailable,
                    onDirectorySelected: { url in
                        if let tabID = tabsManager.selectedTabID {
                            tabsManager.updateTabDirectory(tabID, directoryURL: url)
                        }
                    },
                    validateDirectory: { url in
                        if let existingID = tabsManager.existingTabID(for: url),
                           existingID != tabsManager.selectedTabID {
                            tabsManager.selectTab(existingID)
                            return false
                        }
                        return true
                    }
                )
            } else {
                emptyTabView
            }
        }
        .textSelection(.enabled)
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle("Repo Manager \(tabsManager.getCurrentVersion().map { "(\($0))" } ?? "")")
        .onAppear {
            tabsManager.checkForNewVersion()
        }
        .alert(
            "New version available\n\(tabsManager.newVersion ?? "")",
            isPresented: Binding(
                get: { tabsManager.newVersionAlert },
                set: { tabsManager.newVersionAlert = $0 }
            ),
            actions: {
                if AppUpdater.canUpdate {
                    Button("Update & Restart") {
                        try? AppUpdater.updateAndRestart()
                    }
                }
                Link("View Releases", destination: URL(string: "https://github.com/chanonly123/swiftpm-local-repo-manager/releases")!)
                Button("Cancel", role: .cancel) { }
            },
            message: {
                if let desc = tabsManager.newVersionDesc {
                    Text(desc)
                }
            }
        )
    }

    private var emptyTabView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Tab Selected")
                .font(.headline)

            Button(action: {
                tabsManager.addTab()
            }) {
                Label("New Tab", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Separate view for tab content to isolate ViewModel observations
struct TabContentView: View {
    @ObservedObject var viewModel: RepoManagerViewModel
    var updateAvailable: Bool = false
    let onDirectorySelected: (URL) -> Void
    var validateDirectory: ((URL) -> Bool)? = nil

    @State private var showingUpdateConfirmation = false
    @State private var showingReportIssue = false

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            Group {
                if viewModel.isScanning && viewModel.repoViewModels.isEmpty {
                    loadingView
                } else if viewModel.repoViewModels.isEmpty {
                    emptyStateView
                } else {
                    repositoryListView
                }
            }
            .disabled(viewModel.isScanning || viewModel.isPerformingOperation)

            Divider()

            // Bottom bar — not disabled at the top level so Stop button stays active
            bottomBar
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(alignment: .topTrailing) {
            BannerStackView(
                banners: viewModel.banners,
                onDismiss: { viewModel.dismissBanner($0) },
                onDismissAll: { viewModel.dismissAllBanners() }
            )
        }
        .sheet(isPresented: $viewModel.showingRecheckoutMenu) {
            recheckoutMenuView
        }
        .alert("⚠️ Force Push Warning", isPresented: $viewModel.showingForcePushConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Force Push", role: .destructive) {
                Task { await viewModel.forcePushSelected() }
            }
        } message: {
            Text("This will force-push (--force-with-lease) the current branch to origin for \(viewModel.selectedCount) selected \(viewModel.selectedCount == 1 ? "repository" : "repositories").\n\nThis may overwrite remote history.")
        }
        .alert("⚠️ Hard Reset Warning", isPresented: $viewModel.showingHardResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                Task {
                    await viewModel.hardResetSelected()
                }
            }
        } message: {
            Text("This will permanently discard ALL uncommitted changes and untracked files in \(viewModel.selectedCount) selected \(viewModel.selectedCount == 1 ? "repository" : "repositories").\n\nThis action CANNOT be undone.")
        }
        .alert("⚠️ Clean Warning", isPresented: $viewModel.showingCleanConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clean", role: .destructive) {
                Task {
                    await viewModel.cleanSelected()
                }
            }
        } message: {
            Text("This runs git clean -xdf on \(viewModel.selectedCount) selected \(viewModel.selectedCount == 1 ? "repository" : "repositories"), permanently deleting ALL untracked AND ignored files/directories (build artifacts, caches, DerivedData, etc.).\n\nThis action CANNOT be undone.")
        }
        .sheet(isPresented: $showingReportIssue) {
            ReportIssueView()
        }
        .alert("Update & Restart?", isPresented: $showingUpdateConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Update & Restart") {
                do {
                    try AppUpdater.updateAndRestart()
                } catch {
                    viewModel.addBanner(error.localizedDescription)
                }
            }
        } message: {
            Text("This will quit the app, pull the latest changes, rebuild with run.sh, and relaunch.\n\nBuild progress opens in a new Terminal window.")
        }
    }
}

// MARK: - TabContentView Extensions
extension TabContentView {
    // Update App button — shown at the left of the bottom bar when an update is available
    @ViewBuilder
    private var updateButton: some View {
        if updateAvailable && AppUpdater.canUpdate {
            Button(action: {
                showingUpdateConfirmation = true
            }) {
                Label("Update App", systemImage: "arrow.down.app")
            }
            .help("Pull the latest changes, rebuild, and relaunch the app")
        }
    }

    // Scan button — shown at the left of the bottom bar
    private var scanButton: some View {
        Button(action: {
            Task {
                await viewModel.scanRepositories()
            }
        }) {
            Label("Scan", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.currentDirectory == nil || viewModel.isScanning || viewModel.isPerformingOperation)
    }

    // MARK: - Repository List
    private var repositoryListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.repoViewModels) { vm in
                    RepoRowView(
                        vm: vm,
                        xcodeProjects: viewModel.xcodeProjects(for: vm.repo),
                        onAddDependencies: { project in
                            Task { await viewModel.addLocalDependencies(to: project) }
                        },
                        onRemoveDependencies: { project in
                            Task { await viewModel.removeLocalDependencies(from: project) }
                        },
                        onToggleRunScripts: { project in
                            Task { await viewModel.toggleRunScripts(for: project) }
                        }
                    )
                    Divider()
                }
            }
            .padding(8)
        }
    }

    // MARK: - Bottom Bar
    private var bottomBar: some View {
        HStack {
            // Selection control — single checkbox toggles select / deselect all (far left)
            Toggle(isOn: Binding(
                get: { viewModel.allSelected },
                set: { _ in viewModel.toggleSelectAll() }
            )) {
                Text("\(viewModel.selectedCount) of \(viewModel.repoViewModels.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .disabled(viewModel.repoViewModels.isEmpty)

            Button(action: { showingReportIssue = true }) {
                Label("Report Issue", systemImage: "exclamationmark.bubble")
            }
            .help("Report a problem and share your logs")

            updateButton

            scanButton

            Spacer()

            // Concurrent operations setting
            HStack(spacing: 6) {
                Text("Parallel:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $viewModel.maxConcurrentOperations) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .disabled(viewModel.isPerformingOperation)
            }

            // Operation buttons
            if viewModel.isPerformingOperation {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(viewModel.currentOperationLabel.isEmpty
                         ? "Performing operation…"
                         : "\(viewModel.currentOperationLabel.capitalized)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop") {
                        viewModel.stopCurrentOperation()
                    }
                }
            } else {
                Menu {
                    Button(action: {
                        Task { await viewModel.fetchSelected() }
                    }) {
                        Label("Fetch", systemImage: "arrow.down.circle")
                    }

                    Button(action: {
                        viewModel.showingRecheckoutMenu = true
                    }) {
                        Label("Recheckout", systemImage: "arrow.clockwise.circle")
                    }

                    Divider()

                    Button(action: {
                        Task { await viewModel.pushSelected() }
                    }) {
                        Label("Push", systemImage: "arrow.up.circle")
                    }

                    Button(role: .destructive, action: {
                        viewModel.showingForcePushConfirmation = true
                    }) {
                        Label("Force Push", systemImage: "arrow.up.circle.fill")
                    }

                    Divider()

                    Button(role: .destructive, action: {
                        viewModel.showingHardResetConfirmation = true
                    }) {
                        Label("Hard Reset", systemImage: "exclamationmark.triangle")
                    }

                    Button(role: .destructive, action: {
                        viewModel.showingCleanConfirmation = true
                    }) {
                        Label("Delete untracked files", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .frame(width: 150)
                .disabled(!viewModel.hasSelection)
            }
        }
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Scanning for repositories...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            if viewModel.currentDirectory == nil {
                Text("No Directory Selected")
                    .font(.headline)

                Text("Select a directory to scan for git repositories")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(action: {
                    viewModel.selectDirectory(validate: validateDirectory, onSelected: onDirectorySelected)
                }) {
                    Label("Select Directory", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No Repositories Found")
                    .font(.headline)

                Text("No git repositories found in the selected directory")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recheckout Menu
    private var recheckoutMenuView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Recheckout")
                    .font(.headline)
                Spacer()
                Button(action: {
                    viewModel.showingRecheckoutMenu = false
                    viewModel.customBranchInput = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            VStack(spacing: 16) {
                Text("Reset branch to origin (stash, fetch, checkout -B, restore stash)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top)

                // Current branch option
                Button(action: {
                    viewModel.showingRecheckoutMenu = false
                    Task {
                        await viewModel.recheckoutCurrentBranch()
                    }
                }) {
                    Label("Current Branch", systemImage: "arrow.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Develop branch option
                Button(action: {
                    viewModel.showingRecheckoutMenu = false
                    Task {
                        await viewModel.recheckoutToCustomBranch("main")
                    }
                }) {
                    Label("main", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Divider()
                    .padding(.vertical, 8)

                // Custom branch option
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Search or type a branch name", text: $viewModel.customBranchInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { recheckout(to: viewModel.customBranchInput) }

                        Button(action: { recheckout(to: viewModel.customBranchInput) }) {
                            Label("Go", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.customBranchInput.isEmpty)
                    }

                    recheckoutBranchList
                }
            }
            .padding()

            Spacer()
        }
        .frame(width: 400, height: 460)
        .task { await viewModel.loadRecheckoutBranches() }
    }

    // Filterable list of branches (local + remote) across the selected repos
    private var recheckoutBranchSuggestions: [String] {
        BranchSearch.ranked(viewModel.recheckoutBranches, query: viewModel.customBranchInput)
    }

    @ViewBuilder
    private var recheckoutBranchList: some View {
        if !recheckoutBranchSuggestions.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recheckoutBranchSuggestions, id: \.self) { branch in
                        Button(action: { recheckout(to: branch) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch")
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
                }
            }
            .frame(maxHeight: 130)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if viewModel.recheckoutBranches.isEmpty {
            Text("Loading branches…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No matching branches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func recheckout(to branch: String) {
        let branchName = branch.trimmingCharacters(in: .whitespaces)
        guard !branchName.isEmpty else { return }
        viewModel.showingRecheckoutMenu = false
        viewModel.customBranchInput = ""
        Task { await viewModel.recheckoutToCustomBranch(branchName) }
    }
}

#Preview {
    ContentView()
}
