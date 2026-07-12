import Foundation
import SwiftUI
import Combine

@MainActor
class RepoManagerViewModel: ObservableObject {
    // One RepoViewModel per discovered repo — each is the single source of truth for its repo
    // and is shared by reference into the row / sheets / diff window.
    @Published var repoViewModels: [RepoViewModel] = []
    @Published var isScanning = false
    @Published var isPerformingOperation = false
    // Human-readable label of the batch operation currently running, shown in the toolbar.
    @Published var currentOperationLabel = ""
    @Published var currentDirectory: URL?
    @Published var operationResults: [OperationResult] = []
    @Published var maxConcurrentOperations = 4
    @Published var showingRecheckoutMenu = false
    @Published var customBranchInput = ""
    // Union of branches across the selected repos, shown in the recheckout popup
    @Published var recheckoutBranches: [String] = []
    @Published var showingHardResetConfirmation = false
    @Published var showingCleanConfirmation = false
    @Published var showingForcePushConfirmation = false
    @Published var xcodeProjects: [XcodeProject] = []
    // Tab-wide banners (scan failures etc.); the tab's banner stack also shows each repo's own.
    @Published var tabBanners: [BannerItem] = []
    // True only for the tab currently shown, so FSEvents monitoring runs for the active tab only.
    @Published private(set) var isActiveTab = false
    @Published private(set) var isStopping = false
    // The running batch, held so Stop can cancel it (which terminates in-flight git processes).
    private var operationTask: Task<Void, Never>?

    // Directory-level git actor, used only for the initial repo scan. Per-repo commands run on
    // each RepoViewModel's own GitService (see RepoViewModel.gitService).
    private let gitService = GitService()
    private let repoService = RepoService()
    private let fsEventsMonitor = FSEventsMonitor()
    // Written once in init, read once in the nonisolated deinit — never observed, so it stays
    // outside the main-actor isolation the rest of the state lives under.
    private nonisolated(unsafe) var appObservers: [NSObjectProtocol] = []
    // Mirrors the currently security-scoped directory so the nonisolated deinit can release it
    // without reaching into the main-actor-isolated `currentDirectory`. Kept in sync wherever we
    // start/stop accessing a scoped resource.
    private nonisolated(unsafe) var scopedResourceURL: URL?
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

    // Tab-wide banner stack: tab-level notices plus every repo's own banners (newest last).
    var banners: [BannerItem] {
        tabBanners + repoViewModels.flatMap(\.banners)
    }

    func addBanner(_ message: String) {
        tabBanners.append(BannerItem(message: message))
    }

    func dismissBanner(_ id: UUID) {
        tabBanners.removeAll { $0.id == id }
        repoViewModels.forEach { $0.dismissBanner(id) }
    }

    func dismissAllBanners() {
        tabBanners.removeAll()
        repoViewModels.forEach { $0.banners.removeAll() }
    }

    // MARK: - Active tab (FSEvents runs for the shown tab only)

    func activate() {
        isActiveTab = true
        fsEventsMonitor.resume()
        Task { @MainActor in await refreshAllRepositoryStatuses() }
    }

    func deactivate() {
        isActiveTab = false
        fsEventsMonitor.pause()
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
            // Only the active tab resumes monitoring — background tabs stay paused.
            guard self.isActiveTab else { return }
            self.fsEventsMonitor.resume()
            Task { @MainActor [weak self] in
                await self?.refreshAllRepositoryStatuses()
            }
        })
    }

    deinit {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fsEventsMonitor.stopMonitoring()
        scopedResourceURL?.stopAccessingSecurityScopedResource()
    }

    func refreshAllRepositoryStatuses() async {
        guard !repoViewModels.isEmpty, !isScanning, !isPerformingOperation else { return }
        debugLog("[DEBUG] Refreshing all repository statuses")
        // Each VM refreshes itself silently; any open diff window shares the same VM and
        // observes the change, so no notification bridge is needed.
        await withTaskGroup(of: Void.self) { group in
            for vm in repoViewModels {
                group.addTask { await vm.refresh() }
            }
        }
    }

    // Load directory from security-scoped bookmark
    func loadDirectory(from bookmarkData: Data) async {
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData,
                             options: .withSecurityScope,
                             relativeTo: nil,
                             bookmarkDataIsStale: &isStale)

            if isStale {
                debugLog("[DEBUG] Bookmark is stale, will need to re-select directory")
            }

            // Start accessing the security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                currentDirectory = url
                scopedResourceURL = url
                debugLog("[DEBUG] Loaded directory from bookmark: \(url.path)")
                await scanRepositories()
            } else {
                debugLog("[ERROR] Failed to access security-scoped resource")
            }
        } catch {
            debugLog("[ERROR] Failed to resolve bookmark: \(error.localizedDescription)")
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
            debugLog("[ERROR] Failed to create bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    // Set directory with security-scoped access
    private func setDirectory(_ url: URL) {
        // Stop accessing previous directory if any
        scopedResourceURL?.stopAccessingSecurityScopedResource()
        scopedResourceURL = nil

        // Start accessing new directory
        if url.startAccessingSecurityScopedResource() {
            currentDirectory = url
            scopedResourceURL = url
            debugLog("[DEBUG] Set directory: \(url.path)")
        } else {
            debugLog("[ERROR] Failed to access security-scoped resource for: \(url.path)")
            currentDirectory = url
        }
    }

    // Select directory and scan for repositories
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

            debugLog("[DEBUG] User selected directory: \(url.path)")
            self.setDirectory(url)
            onSelected?(url)
            Task {
                await self.scanRepositories()
            }
        }
    }

    // Set directory programmatically and scan
    func setDirectoryAndScan(_ url: URL) async {
        setDirectory(url)
        await scanRepositories()
    }

    // Scan for repositories in the current directory
    func scanRepositories() async {
        // TEMP DIAGNOSTIC: capture who is triggering a scan.
        debugLog("[TRACE] scanRepositories from:\n" + Thread.callStackSymbols.dropFirst().prefix(8).joined(separator: "\n"))
        guard let directory = currentDirectory, !isScanning else { return }

        debugLog("[DEBUG] Scanning directory: \(directory.path)")

        // Stop monitoring previous repositories
        fsEventsMonitor.stopMonitoring()

        // Only show the full-screen scanning state on a cold scan (nothing displayed yet).
        // A re-scan keeps the existing rows visible and updates them in place.
        isScanning = true //repoViewModels.isEmpty
        defer {
            isScanning = false
        }

        do {
            // Scan for git repositories
            let repoURLs = try await gitService.scanForRepositories(at: directory)
            debugLog("[DEBUG] Found \(repoURLs.count) git repositories")

            // Scan for Xcode projects
            let projects = try await repoService.findXcodeProjects(in: directory)
            xcodeProjects = projects
            debugLog("[DEBUG] Found \(projects.count) Xcode projects")

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
                    )
                )
                repoCache[url] = vm
                return vm
            }
            self.repoViewModels = vms.sorted { $0.repo.name < $1.repo.name }

            // Start monitoring all repositories for file system changes
            startMonitoringRepositories()

            // Refresh every repo silently, in its own task rather than awaited inline. Rows
            // update via per-row observation of `vm.repo` — but on a cold launch via bookmark
            // restore the reload can land before SwiftUI has committed the rows' first render,
            // so no row has subscribed yet and those per-row invalidations are dropped. To
            // deliver the loaded state reliably regardless of that timing, we reassign the
            // observed `repoViewModels` array once the batch finishes: that invalidates the
            // parent list, which rebuilds every row against its now-updated VM. Steady-state
            // single-repo updates (git ops, FSEvents) still flow through per-row observation.
            Task { @MainActor in
                repoViewModels.forEach({ $0.isOperating = true })
                await withTaskGroup(of: Void.self) { group in
                    for vm in self.repoViewModels {
                        // reload() (not refresh()) — refresh() no-ops while isOperating is
                        // true, which we just set to drive the per-row spinner.
                        group.addTask { await vm.reload() }
                    }
                }
                debugLog("[SUCCESS] Loaded repository information for \(self.repoViewModels.count) repos")
                repoViewModels.forEach({ $0.isOperating = false })
                // Catch-up re-render for the cold-launch race described above (no-op cost in the
                // common case where rows already subscribed and updated themselves live).
                self.repoViewModels = self.repoViewModels.sorted { $0.repo.name < $1.repo.name }
            }
        } catch {
            debugLog("[ERROR] Failed to scan directory: \(error.localizedDescription)")
            addBanner("Failed to scan directory: \(error.localizedDescription)")
        }
    }

    // Start monitoring repositories for file system changes
    private func startMonitoringRepositories() {
        let repoURLs = repositories.map { $0.url }
        fsEventsMonitor.startMonitoringMultiple(repoURLs: repoURLs) { [weak self] repoURL in
            Task { @MainActor [weak self] in
                await self?.handleFileSystemChange(at: repoURL)
            }
        }
        // A background tab scans (e.g. bookmark restore) but must not emit change events
        // until it becomes the active tab.
        if !isActiveTab { fsEventsMonitor.pause() }
    }

    // Handle file system change for a specific repository
    private func handleFileSystemChange(at repoURL: URL) async {
        guard let vm = repoCache[repoURL] else { return }
        // refresh() no-ops while the repo has an operation in flight, which also prevents
        // FSEvents feedback loops from our own git commands.
        debugLog("[DEBUG] File system change detected in: \(vm.repo.name)")
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
    func pullSelected() async {
        await performBatch("pull", on: selectedRepositoryVMs) { await $0.pull() }
    }

    // Fetch selected repositories
    func fetchSelected() async {
        await performBatch("fetch", on: selectedRepositoryVMs) { await $0.fetch() }
    }

    // Recheckout selected repositories to current branch
    func recheckoutCurrentBranch() async {
        await performBatch("recheckout", on: selectedRepositoryVMs) { await $0.recheckout() }
    }

    // Load the local + remote branches of the first selected repo so the recheckout popup can
    // offer them as pickable suggestions. Only the first repo is used (not the union across all
    // selected repos) to keep the list fast and representative.
    func loadRecheckoutBranches() async {
        recheckoutBranches = []
        // Use the repo's own service so this listing serializes with any operation running on it.
        guard let firstVM = selectedRepositoryVMs.first else { return }
        let branches = (try? await firstVM.gitService.getBranches(at: firstVM.repo.url)) ?? []
        recheckoutBranches = branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Recheckout selected repositories to custom branch
    func recheckoutToCustomBranch(_ branchName: String) async {
        await performBatch("recheckout \(branchName)", on: selectedRepositoryVMs) { await $0.recheckout(toBranch: branchName) }
    }

    // Push selected repositories
    func pushSelected() async {
        await performBatch("push", on: selectedRepositoryVMs) { await $0.push() }
    }

    // Force-push selected repositories
    func forcePushSelected() async {
        await performBatch("force-push", on: selectedRepositoryVMs) { await $0.forcePush() }
    }

    // Hard reset selected repositories
    func hardResetSelected() async {
        await performBatch("hard-reset", on: selectedRepositoryVMs) { await $0.hardReset() }
    }

    // Clean (git clean -xdf) selected repositories
    func cleanSelected() async {
        await performBatch("clean", on: selectedRepositoryVMs) { await $0.clean() }
    }

    // Run a batch git operation over the given repo VMs with a bounded concurrency limit.
    // Each VM runs its own operation (setting its isOperating flag and reloading itself);
    // this layer only aggregates the per-repo OperationResults for OperationResultsView and
    // drains queued work when the user hits Stop.
    private func performBatch(
        _ label: String = "operation",
        on vms: [RepoViewModel],
        _ run: @escaping (RepoViewModel) async -> OperationResult
    ) async {
        guard !vms.isEmpty else { return }
        debugLog("[BATCH] Starting \(label) on \(vms.count) repo(s), maxConcurrent=\(maxConcurrentOperations)")

        isStopping = false
        isPerformingOperation = true
        currentOperationLabel = label
        operationResults.removeAll()

        // Pause filesystem monitoring for the whole batch: the operations churn working-tree
        // files, which would otherwise fire debounced status refreshes that spawn a burst of
        // git subprocesses contending with the in-flight operations. Each operated repo is
        // reloaded by its own perform() anyway, so nothing is missed. Resumed in the `defer`.
        fsEventsMonitor.suspendForOperation()
        // Suppress each operation's own post-op reload for the duration of the batch: running
        // `git status` on one repo while others are still being written was hanging multi-repo
        // operations. The operated repos are reloaded once, below, after all writes finish.
        vms.forEach { $0.deferReload = true }
        defer {
            vms.forEach { $0.deferReload = false }
            fsEventsMonitor.resumeAfterOperation()
        }

        // Run the group inside a stored Task so stopCurrentOperation() can cancel it;
        // cancellation propagates to the child tasks and terminates their git processes.
        let task = Task { @MainActor in
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
        }
        operationTask = task
        await task.value
        operationTask = nil

        isPerformingOperation = false
        currentOperationLabel = ""
        let failures = operationResults.filter { !$0.success }.count
        debugLog("[BATCH] Finished \(label): \(operationResults.count - failures) succeeded, \(failures) failed\(isStopping ? " (stopped early)" : "")")
        // Per-repo failures already surface as banners (via each VM's perform()); no results sheet.
        isStopping = false

        // Now that every operation is done and no writes are in flight, reload the operated
        // repos' status once. This is the only place `git status` runs for the batch, so it
        // never contends with an in-progress checkout/stash/pull on another repo.
        await withTaskGroup(of: Void.self) { group in
            for vm in vms {
                group.addTask { await vm.reload() }
            }
        }
    }

    // Stop the current batch operation (lets running tasks finish, skips queued ones)
    func stopCurrentOperation() {
        guard isPerformingOperation else { return }
        debugLog("[BATCH] Stop requested by user — cancelling in-flight operations")
        isStopping = true
        operationTask?.cancel()
    }

    // MARK: - xcode-specific operations

    // Add local dependencies to xcode project
    func addLocalDependencies(to project: XcodeProject) async {
        guard let directory = currentDirectory else {
            addBanner("No directory selected")
            return
        }

        isPerformingOperation = true
        debugLog("[DEBUG] Adding local dependencies to \(project.name)")

        do {
            let result = try await repoService.addLocalDependencies(
                project: project,
                baseDirectory: directory,
                repositories: repositories
            )

            debugLog("[SUCCESS] Added \(result.success)/\(result.total) module references to \(project.name)")

            operationResults = []
        } catch {
            debugLog("[ERROR] Failed to add local dependencies: \(error.localizedDescription)")
            addBanner("Failed to add dependencies: \(error.localizedDescription)")
        }

        isPerformingOperation = false
    }

    // Remove local dependencies from xcode project
    func removeLocalDependencies(from project: XcodeProject) async {
        isPerformingOperation = true
        debugLog("[DEBUG] Removing local dependencies from \(project.name)")
        do {
            let count = try await repoService.removeLocalDependencies(project: project)
            debugLog("[SUCCESS] Removed \(count) local dependency references from \(project.name)")
        } catch {
            debugLog("[ERROR] Failed to remove local dependencies: \(error.localizedDescription)")
            addBanner("Failed to remove dependencies: \(error.localizedDescription)")
        }
        isPerformingOperation = false
    }

    // Toggle run scripts in a project
    func toggleRunScripts(for project: XcodeProject) async {
        isPerformingOperation = true
        debugLog("[DEBUG] Toggling run scripts in \(project.name)")

        do {
            let result = try await repoService.toggleRunScripts(project: project)

            let status = result.enabled ? "Enabled" : "Disabled"
            debugLog("[SUCCESS] \(status) \(result.count) run script(s)")

            operationResults = []
        } catch {
            debugLog("[ERROR] Failed to toggle run scripts: \(error.localizedDescription)")
            addBanner("Failed to toggle run scripts: \(error.localizedDescription)")
        }

        isPerformingOperation = false
    }
}
