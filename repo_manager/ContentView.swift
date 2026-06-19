import SwiftUI

struct ContentView: View {
    @State private var tabsManager = TabsManager()

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
                Link("Update", destination: URL(string: "https://github.com/chanonly123/swiftpm-local-repo-manager/releases")!)
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
    @Bindable var viewModel: RepoManagerViewModel
    let onDirectorySelected: (URL) -> Void
    var validateDirectory: ((URL) -> Bool)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .disabled(viewModel.isScanning || viewModel.isPerformingOperation)

            Divider()

            // Main content
            Group {
                if viewModel.isScanning {
                    loadingView
                } else if viewModel.repositories.isEmpty {
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
        .sheet(isPresented: $viewModel.showingResults) {
            OperationResultsView(
                results: viewModel.operationResults,
                onClose: viewModel.clearResults
            )
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: $viewModel.showingRecheckoutMenu) {
            recheckoutMenuView
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
    }
}

// MARK: - TabContentView Extensions
extension TabContentView {
    // MARK: - Toolbar
    private var toolbar: some View {
        HStack {
            if let directory = viewModel.currentDirectory {
                VStack(alignment: .leading, spacing: 2) {
                    Text(directory.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(directory.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            // Xcode tasks menu
            if !viewModel.xcodeProjects.isEmpty, let currentDir = viewModel.currentDirectory {
                Menu {
                    ForEach(viewModel.xcodeProjects) { project in
                        Menu(project.relativePath(from: currentDir)) {
                            Button(action: {
                                Task {
                                    await viewModel.addLocalDependencies(to: project)
                                }
                            }) {
                                Label("Add Local Dependencies", systemImage: "link.badge.plus")
                            }
                            .disabled(viewModel.isPerformingOperation)

                            Button(action: {
                                Task {
                                    await viewModel.toggleRunScripts(for: project)
                                }
                            }) {
                                Label("Toggle Run Scripts", systemImage: "play.slash")
                            }
                            .disabled(viewModel.isPerformingOperation)
                        }
                    }
                } label: {
                    Label("Xcode Tasks (\(viewModel.xcodeProjects.count))", systemImage: "hammer")
                }
                .frame(width: 200)
                .disabled(viewModel.isPerformingOperation)

                Divider()
                    .frame(height: 20)
            }

            Button(action: {
                Task {
                    await viewModel.scanRepositories()
                }
            }) {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.currentDirectory == nil || viewModel.isScanning || viewModel.isPerformingOperation)
        }
    }

    // MARK: - Repository List
    private var repositoryListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.repositories) { repo in
                    RepoRowView(
                        repo: repo,
                        isSelected: viewModel.selectedRepoIDs.contains(repo.id),
                        isOperating: viewModel.operatingRepoIDs.contains(repo.id),
                        onToggle: {
                            viewModel.toggleSelection(for: repo)
                        }
                    )
                }
            }
            .padding(8)
        }
    }

    // MARK: - Bottom Bar
    private var bottomBar: some View {
        HStack {
            // Selection controls
            HStack(spacing: 8) {
                Text("\(viewModel.selectedCount) of \(viewModel.repositories.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: {
                    viewModel.selectAll()
                }) {
                    Label("Select All", systemImage: "checkmark.square")
                }
                .disabled(viewModel.repositories.isEmpty || viewModel.hasLoadingRepos)

                Button(action: {
                    viewModel.deselectAll()
                }) {
                    Label("Deselect All", systemImage: "square")
                }
                .disabled(!viewModel.hasSelection)
            }

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
                    Text("Performing operation...")
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

                    Button(role: .destructive, action: {
                        viewModel.showingHardResetConfirmation = true
                    }) {
                        Label("Hard Reset", systemImage: "exclamationmark.triangle")
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

                // Develop branch option
                Button(action: {
                    viewModel.showingRecheckoutMenu = false
                    Task {
                        await viewModel.recheckoutToCustomBranch("develop")
                    }
                }) {
                    Label("develop", systemImage: "arrow.triangle.branch")
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
                        TextField("Branch name", text: $viewModel.customBranchInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !viewModel.customBranchInput.isEmpty {
                                    let branchName = viewModel.customBranchInput
                                    viewModel.showingRecheckoutMenu = false
                                    viewModel.customBranchInput = ""
                                    Task {
                                        await viewModel.recheckoutToCustomBranch(branchName)
                                    }
                                }
                            }

                        Button(action: {
                            if !viewModel.customBranchInput.isEmpty {
                                let branchName = viewModel.customBranchInput
                                viewModel.showingRecheckoutMenu = false
                                viewModel.customBranchInput = ""
                                Task {
                                    await viewModel.recheckoutToCustomBranch(branchName)
                                }
                            }
                        }) {
                            Label("Go", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.customBranchInput.isEmpty)
                    }
                }
            }
            .padding()

            Spacer()
        }
        .frame(width: 400, height: 350)
    }
}

#Preview {
    ContentView()
}
