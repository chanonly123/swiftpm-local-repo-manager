import Foundation
import SwiftUI

@Observable
class RepoManagerViewModel {
    // One RepoViewModel per discovered repo — each is the single source of truth for its repo
    // and is shared by reference into the row / sheets / diff window.
    var repoViewModels: [RepoViewModel] = []
    var isScanning = false
    var isPerformingOperation = false
    var currentDirectory: URL?
    var operationResults: [OperationResult] = []
    var showingResults = false
    var errorMessage: String?
    var maxConcurrentOperations = 4
    var showingRecheckoutMenu = false
    var customBranchInput = ""
    // Union of branches across the selected repos, shown in the recheckout popup
    var recheckoutBranches: [String] = []
    var showingHardResetConfirmation = false
    var showingForcePushConfirmation = false
    var xcodeProjects: [XcodeProject] = []
    private(set) var isStopping = false

    private let gitService = GitService()
    private let repoService = RepoService()
    private let fsEventsMonitor = FSEventsMonitor()
    private var appObservers: [NSObjectProtocol] = []
    // Session cache: reuse the same RepoViewModel for a path across re-scans/refreshes so
    // cached data shows immediately (no loading flash) and refresh happens silently behind it.
    private var repoCache: [URL: RepoViewModel] = [:]

    // All repos as plain data (e.g. for Xcode dependency wiring).
    var repositories: [GitRepo] {
        repoViewModels.map(\.repo)
    }

    // Selection is derived from the per-repo VMs (the source of truth).
    var selectedRepositoryVMs: [RepoViewModel] {
        repoViewModels.filter(\.isSelected)
    }

    var selectedRepositories: [GitRepo] {
        selectedRepositoryVMs.map(\.repo)
    }

    var selectedCount: Int {
        selectedRepositoryVMs.count
    }

    var hasSelection: Bool {
        repoViewModels.contains(where: \.isSelected)
    }

    var hasLoadingRepos: Bool {
        repoViewModels.contains { $0.repo.status == .loading }
    }

    // Xcode projects located inside a specific repository
    func xcodeProjects(for repo: GitRepo) -> [XcodeProject] {
        let repoPrefix = repo.url.path.hasSuffix("/") ? repo.url.path : repo.url.path + "/"
        return xcodeProjects.filter { $0.projectPath.path.hasPrefix(repoPrefix) }
    }

    init() {
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.fsEventsMonitor.pause()
        })
        appObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.fsEventsMonitor.resume()
            Task { @MainActor [weak self] in
                await self?.refreshAllRepositoryStatuses()
            }
        })
    }

    deinit {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fsEventsMonitor.stopMonitoring()
        currentDirectory?.stopAccessingSecurityScopedResource()
    }

    @MainActor
    func refreshAllRepositoryStatuses() async {
        guard !repoViewModels.isEmpty, !isScanning, !isPerformingOperation else { return }
        print("[DEBUG] Refreshing all repository statuses")
        // Each VM refreshes itself silently; any open diff window shares the same VM and
        // observes the change, so no notification bridge is needed.
        await withTaskGroup(of: Void.self) { group in
            for vm in repoViewModels {
                group.addTask { await vm.refresh() }
            }
        }
    }

    // Load directory from security-scoped bookmark
    @MainActor
    func loadDirectory(from bookmarkData: Data) async {
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData,
                             options: .withSecurityScope,
                             relativeTo: nil,
                             bookmarkDataIsStale: &isStale)

            if isStale {
                print("[DEBUG] Bookmark is stale, will need to re-select directory")
            }

            // Start accessing the security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                currentDirectory = url
                print("[DEBUG] Loaded directory from bookmark: \(url.path)")
                await scanRepositories()
            } else {
                print("[ERROR] Failed to access security-scoped resource")
            }
        } catch {
            print("[ERROR] Failed to resolve bookmark: \(error.localizedDescription)")
        }
    }

    // Create security-scoped bookmark for current directory
    func createBookmark() -> Data? {
        guard let url = currentDirectory else { return nil }

        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            return bookmarkData
        } catch {
            print("[ERROR] Failed to create bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    // Set directory with security-scoped access
    private func setDirectory(_ url: URL) {
        // Stop accessing previous directory if any
        currentDirectory?.stopAccessingSecurityScopedResource()

        // Start accessing new directory
        if url.startAccessingSecurityScopedResource() {
            currentDirectory = url
            print("[DEBUG] Set directory: \(url.path)")
        } else {
            print("[ERROR] Failed to access security-scoped resource for: \(url.path)")
            currentDirectory = url
        }
    }

    // Select directory and scan for repositories
    @MainActor
    func selectDirectory(validate: ((URL) -> Bool)? = nil, onSelected: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory to scan for git repositories"

        if let currentDir = currentDirectory {
            panel.directoryURL = currentDir
        }

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }

            if let validate = validate, !validate(url) { return }

            self.setDirectory(url)
            onSelected?(url)
            Task {
                await self.scanRepositories()
            }
        }
    }

    // Set directory programmatically and scan
    @MainActor
    func setDirectoryAndScan(_ url: URL) async {
        setDirectory(url)
        await scanRepositories()
    }

    // Scan for repositories in the current directory
    @MainActor
    func scanRepositories() async {
        guard let directory = currentDirectory else { return }

        print("[DEBUG] Scanning directory: \(directory.path)")

        // Stop monitoring previous repositories
        fsEventsMonitor.stopMonitoring()

        // Only show the full-screen scanning state on a cold scan (nothing displayed yet).
        // A re-scan keeps the existing rows visible and updates them in place.
        isScanning = repoViewModels.isEmpty
        errorMessage = nil

        do {
            // Scan for git repositories
            let repoURLs = try await gitService.scanForRepositories(at: directory)
            print("[DEBUG] Found \(repoURLs.count) git repositories")

            // Scan for Xcode projects
            let projects = try await repoService.findXcodeProjects(in: directory)
            xcodeProjects = projects
            print("[DEBUG] Found \(projects.count) Xcode projects")

            // Build the list, reusing cached VMs so their data (and selection) persist across
            // scans. Genuinely new repos start in .loading until their first refresh lands.
            let vms: [RepoViewModel] = repoURLs.map { url in
                if let cached = repoCache[url] { return cached }
                let vm = RepoViewModel(
                    repo: GitRepo(
                        name: url.lastPathComponent,
                        url: url,
                        currentBranch: nil,
                        status: .loading,
                        hasUncommittedChanges: false
                    ),
                    gitService: gitService
                )
                repoCache[url] = vm
                return vm
            }
            self.repoViewModels = vms.sorted { $0.repo.name < $1.repo.name }
            isScanning = false

            // Refresh every repo silently (cached ones keep showing prior data meanwhile).
            await withTaskGroup(of: Void.self) { group in
                for vm in self.repoViewModels {
                    group.addTask { await vm.refresh() }
                }
            }
            print("[SUCCESS] Loaded repository information for \(repoViewModels.count) repos")

            // Start monitoring all repositories for file system changes
            startMonitoringRepositories()
        } catch {
            print("[ERROR] Failed to scan directory: \(error.localizedDescription)")
            errorMessage = "Failed to scan directory: \(error.localizedDescription)"
            isScanning = false
        }
    }

    // Start monitoring repositories for file system changes
    @MainActor
    private func startMonitoringRepositories() {
        let repoURLs = repositories.map { $0.url }
        fsEventsMonitor.startMonitoringMultiple(repoURLs: repoURLs) { [weak self] repoURL in
            Task { @MainActor [weak self] in
                await self?.handleFileSystemChange(at: repoURL)
            }
        }
    }

    // Handle file system change for a specific repository
    @MainActor
    private func handleFileSystemChange(at repoURL: URL) async {
        guard let vm = repoCache[repoURL] else { return }
        // refresh() no-ops while the repo has an operation in flight, which also prevents
        // FSEvents feedback loops from our own git commands.
        print("[DEBUG] File system change detected in: \(vm.repo.name)")
        await vm.refresh()
    }

    // Select all repositories (excluding loading ones)
    func selectAll() {
        for vm in repoViewModels where vm.repo.status != .loading {
            vm.isSelected = true
        }
    }

    // Deselect all repositories
    func deselectAll() {
        for vm in repoViewModels {
            vm.isSelected = false
        }
    }

    // True when every selectable (non-loading) repo is selected
    var allSelected: Bool {
        let selectable = repoViewModels.filter { $0.repo.status != .loading }
        return !selectable.isEmpty && selectable.allSatisfy(\.isSelected)
    }

    // Toggle between selecting all and deselecting all
    func toggleSelectAll() {
        if allSelected {
            deselectAll()
        } else {
            selectAll()
        }
    }

    // Pull selected repositories
    @MainActor
    func pullSelected() async {
        await performBatch(on: selectedRepositoryVMs) { await $0.pull() }
    }

    // Fetch selected repositories
    @MainActor
    func fetchSelected() async {
        await performBatch(on: selectedRepositoryVMs) { await $0.fetch() }
    }

    // Recheckout selected repositories to current branch
    @MainActor
    func recheckoutCurrentBranch() async {
        await performBatch(on: selectedRepositoryVMs) { await $0.recheckout() }
    }

    // Load the union of local + remote branches across the selected repos so the
    // recheckout popup can offer them as pickable suggestions.
    @MainActor
    func loadRecheckoutBranches() async {
        recheckoutBranches = []
        var seen = Set<String>()
        var all: [String] = []
        for repo in selectedRepositories {
            let branches = (try? await gitService.getBranches(at: repo.url)) ?? []
            for branch in branches where seen.insert(branch).inserted {
                all.append(branch)
            }
        }
        recheckoutBranches = all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Recheckout selected repositories to custom branch
    @MainActor
    func recheckoutToCustomBranch(_ branchName: String) async {
        await performBatch(on: selectedRepositoryVMs) { await $0.recheckout(toBranch: branchName) }
    }

    // Push selected repositories
    @MainActor
    func pushSelected() async {
        await performBatch(on: selectedRepositoryVMs) { await $0.push() }
    }

    // Force-push selected repositories
    @MainActor
    func forcePushSelected() async {
        await performBatch(on: selectedRepositoryVMs) { await $0.forcePush() }
    }

    // Hard reset selected repositories
    @MainActor
    func hardResetSelected() async {
        await performBatch(on: selectedRepositoryVMs) { await $0.hardReset() }
    }

    // Run a batch git operation over the given repo VMs with a bounded concurrency limit.
    // Each VM runs its own operation (setting its isOperating flag and reloading itself);
    // this layer only aggregates the per-repo OperationResults for OperationResultsView and
    // drains queued work when the user hits Stop.
    @MainActor
    private func performBatch(
        on vms: [RepoViewModel],
        _ run: @escaping (RepoViewModel) async -> OperationResult
    ) async {
        guard !vms.isEmpty else { return }

        isStopping = false
        isPerformingOperation = true
        operationResults.removeAll()

        await withTaskGroup(of: (Int, OperationResult).self) { group in
            let pending = Array(vms.enumerated())
            var activeCount = 0
            var nextIndex = 0

            // Start initial batch up to maxConcurrentOperations
            while nextIndex < pending.count && activeCount < maxConcurrentOperations && !isStopping {
                let (index, vm) = pending[nextIndex]
                group.addTask { (index, await run(vm)) }
                activeCount += 1
                nextIndex += 1
            }

            // Process results and start new tasks as slots free up
            var results: [(Int, OperationResult)] = []
            for await (index, result) in group {
                results.append((index, result))
                activeCount -= 1
                if nextIndex < pending.count && !isStopping {
                    let (idx, vm) = pending[nextIndex]
                    group.addTask { (idx, await run(vm)) }
                    activeCount += 1
                    nextIndex += 1
                }
            }

            self.operationResults = results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        isPerformingOperation = false
        if !isStopping && self.operationResults.contains(where: { !$0.success }) {
            showingResults = true
        }
        isStopping = false
    }

    // Clear operation results
    func clearResults() {
        operationResults.removeAll()
        showingResults = false
    }

    // Stop the current batch operation (lets running tasks finish, skips queued ones)
    func stopCurrentOperation() {
        guard isPerformingOperation else { return }
        isStopping = true
    }

    // MARK: - xcode-specific operations

    // Add local dependencies to xcode project
    @MainActor
    func addLocalDependencies(to project: XcodeProject) async {
        guard let directory = currentDirectory else {
            errorMessage = "No directory selected"
            return
        }

        isPerformingOperation = true
        print("[DEBUG] Adding local dependencies to \(project.name)")

        do {
            let result = try await repoService.addLocalDependencies(
                project: project,
                baseDirectory: directory,
                repositories: repositories
            )

            print("[SUCCESS] Added \(result.success)/\(result.total) module references to \(project.name)")
            errorMessage = nil

            operationResults = []
        } catch {
            print("[ERROR] Failed to add local dependencies: \(error.localizedDescription)")
            errorMessage = "Failed to add dependencies: \(error.localizedDescription)"
        }

        isPerformingOperation = false
    }

    // Remove local dependencies from xcode project
    @MainActor
    func removeLocalDependencies(from project: XcodeProject) async {
        isPerformingOperation = true
        print("[DEBUG] Removing local dependencies from \(project.name)")
        do {
            let count = try await repoService.removeLocalDependencies(project: project)
            print("[SUCCESS] Removed \(count) local dependency references from \(project.name)")
            errorMessage = nil
        } catch {
            print("[ERROR] Failed to remove local dependencies: \(error.localizedDescription)")
            errorMessage = "Failed to remove dependencies: \(error.localizedDescription)"
        }
        isPerformingOperation = false
    }

    // Toggle run scripts in a project
    @MainActor
    func toggleRunScripts(for project: XcodeProject) async {
        isPerformingOperation = true
        print("[DEBUG] Toggling run scripts in \(project.name)")

        do {
            let result = try await repoService.toggleRunScripts(project: project)

            let status = result.enabled ? "Enabled" : "Disabled"
            print("[SUCCESS] \(status) \(result.count) run script(s)")
            errorMessage = nil

            operationResults = []
        } catch {
            print("[ERROR] Failed to toggle run scripts: \(error.localizedDescription)")
            errorMessage = "Failed to toggle run scripts: \(error.localizedDescription)"
        }

        isPerformingOperation = false
    }
}
