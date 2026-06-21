import Foundation
import SwiftUI

@Observable
class RepoManagerViewModel {
    var repositories: [GitRepo] = []
    var selectedRepoIDs: Set<UUID> = []
    var operatingRepoIDs: Set<UUID> = []
    var isScanning = false
    var isPerformingOperation = false
    var currentDirectory: URL?
    var operationResults: [OperationResult] = []
    var showingResults = false
    var errorMessage: String?
    var maxConcurrentOperations = 4
    var showingRecheckoutMenu = false
    var customBranchInput = ""
    var showingHardResetConfirmation = false
    var showingForcePushConfirmation = false
    var xcodeProjects: [XcodeProject] = []
    private(set) var isStopping = false

    private let gitService = GitService()
    private let repoService = RepoService()
    private let fsEventsMonitor = FSEventsMonitor()
    private var appObservers: [NSObjectProtocol] = []

    var selectedCount: Int {
        selectedRepoIDs.count
    }

    var hasSelection: Bool {
        !selectedRepoIDs.isEmpty
    }

    var selectedRepositories: [GitRepo] {
        repositories.filter { selectedRepoIDs.contains($0.id) }
    }

    var hasLoadingRepos: Bool {
        repositories.contains { $0.status == .loading }
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
        guard !repositories.isEmpty, !isScanning, !isPerformingOperation else { return }
        print("[DEBUG] Refreshing all repository statuses after app became active")
        await withTaskGroup(of: (Int, GitRepo).self) { group in
            for (index, repo) in repositories.enumerated() {
                guard !operatingRepoIDs.contains(repo.id) else { continue }
                group.addTask {
                    let updated = await self.gitService.getRepoInfo(at: repo.url)
                    return (index, updated)
                }
            }
            for await (index, updated) in group {
                repositories[index] = updated
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

        isScanning = true
        errorMessage = nil
        repositories = []
        selectedRepoIDs.removeAll()
        xcodeProjects = []

        do {
            // Scan for git repositories
            let repoURLs = try await gitService.scanForRepositories(at: directory)
            print("[DEBUG] Found \(repoURLs.count) git repositories")

            // Scan for Xcode projects
            let projects = try await repoService.findXcodeProjects(in: directory)
            xcodeProjects = projects
            print("[DEBUG] Found \(projects.count) Xcode projects")

            // Create basic repo objects immediately and show them
            let basicRepos = repoURLs.map { url in
                GitRepo(
                    name: url.lastPathComponent,
                    url: url,
                    currentBranch: nil,
                    status: .loading,
                    hasUncommittedChanges: false
                )
            }
            self.repositories = basicRepos.sorted { $0.name < $1.name }
            isScanning = false

            // Now fetch detailed info for each repository and update progressively
            await withTaskGroup(of: (UUID, GitRepo).self) { group in
                for repo in self.repositories {
                    // Mark repo as operating
                    operatingRepoIDs.insert(repo.id)

                    group.addTask {
                        let detailedRepo = await self.gitService.getRepoInfo(at: repo.url)
                        return (repo.id, detailedRepo)
                    }
                }

                for await (oldId, updatedRepo) in group {
                    // Find and update the matching repository
                    if let index = self.repositories.firstIndex(where: { $0.id == oldId }) {
                        self.repositories[index] = updatedRepo
                        // Remove from operating set
                        operatingRepoIDs.remove(oldId)
                    }
                }
            }
            print("[SUCCESS] Loaded repository information for \(repositories.count) repos")

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
        guard let index = repositories.firstIndex(where: { $0.url == repoURL }) else { return }
        let repo = repositories[index]

        // Skip if already updating this repo to prevent loops
        guard !operatingRepoIDs.contains(repo.id) else {
            print("[DEBUG] Skipping file system change for \(repo.name) - already updating")
            return
        }

        print("[DEBUG] File system change detected in: \(repo.name)")

        // Mark as operating
        operatingRepoIDs.insert(repo.id)

        // Fetch updated status
        let updatedRepo = await gitService.getRepoInfo(at: repo.url)

        // Update the repository
        repositories[index] = updatedRepo

        // Remove from operating set
        operatingRepoIDs.remove(repo.id)

        print("[DEBUG] Updated status for \(repo.name): \(updatedRepo.status.displayText)")
    }

    // Toggle repository selection
    func toggleSelection(for repo: GitRepo) {
        // Don't allow selection while repo is loading
        guard repo.status != .loading else { return }

        if selectedRepoIDs.contains(repo.id) {
            selectedRepoIDs.remove(repo.id)
        } else {
            selectedRepoIDs.insert(repo.id)
        }
    }

    // Select all repositories (excluding loading ones)
    func selectAll() {
        selectedRepoIDs = Set(repositories.filter { $0.status != .loading }.map { $0.id })
    }

    // Deselect all repositories
    func deselectAll() {
        selectedRepoIDs.removeAll()
    }

    // Pull selected repositories
    @MainActor
    func pullSelected() async {
        await performOperation(on: selectedRepositories, operation: .pull) { repo in
            try await self.gitService.pull(at: repo.url)
        }
    }

    // Fetch selected repositories
    @MainActor
    func fetchSelected() async {
        await performOperation(on: selectedRepositories, operation: .fetch) { repo in
            try await self.gitService.fetch(at: repo.url)
        }
    }

    // Recheckout selected repositories to current branch
    @MainActor
    func recheckoutCurrentBranch() async {
        await performOperation(on: selectedRepositories, operation: .recheckout) { repo in
            try await self.gitService.recheckout(at: repo.url)
        }
        await refreshAllRepositoryStatuses()
    }

    // Recheckout selected repositories to custom branch
    @MainActor
    func recheckoutToCustomBranch(_ branchName: String) async {
        await performOperation(on: selectedRepositories, operation: .recheckout) { repo in
            try await self.gitService.recheckout(at: repo.url, toBranch: branchName)
        }
        await refreshAllRepositoryStatuses()
    }

    // Push selected repositories
    @MainActor
    func pushSelected() async {
        await performOperation(on: selectedRepositories, operation: .push) { repo in
            try await self.gitService.push(at: repo.url)
        }
        await refreshAllRepositoryStatuses()
    }

    // Force-push selected repositories
    @MainActor
    func forcePushSelected() async {
        await performOperation(on: selectedRepositories, operation: .forcePush) { repo in
            try await self.gitService.forcePush(at: repo.url)
        }
        await refreshAllRepositoryStatuses()
    }

    // Hard reset selected repositories
    @MainActor
    func hardResetSelected() async {
        await performOperation(on: selectedRepositories, operation: .hardReset) { repo in
            try await self.gitService.hardReset(at: repo.url)
        }
    }

    // Generic operation performer with configurable concurrency limit
    private func performOperation(
        on repos: [GitRepo],
        operation: OperationResult.GitOperation,
        action: @escaping (GitRepo) async throws -> String
    ) async {
        guard !repos.isEmpty else { return }

        isStopping = false
        isPerformingOperation = true
        operationResults.removeAll()

        // Use a semaphore-like approach to limit concurrent operations
        await withTaskGroup(of: (Int, OperationResult).self) { group in
            var pendingRepos = Array(repos.enumerated())
            var activeCount = 0
            var nextIndex = 0

            // Start initial batch up to maxConcurrentOperations
            while nextIndex < pendingRepos.count && activeCount < maxConcurrentOperations && !isStopping {
                let (index, repo) = pendingRepos[nextIndex]
                group.addTask {
                    let result = await self.executeOperation(repo: repo, operation: operation, action: action)
                    return (index, result)
                }
                activeCount += 1
                nextIndex += 1
            }

            // Process results and start new tasks as slots become available
            var results: [(Int, OperationResult)] = []
            for await (index, result) in group {
                results.append((index, result))
                activeCount -= 1

                // Start next task if available and not stopping
                if nextIndex < pendingRepos.count && !isStopping {
                    let (idx, repo) = pendingRepos[nextIndex]
                    group.addTask {
                        let result = await self.executeOperation(repo: repo, operation: operation, action: action)
                        return (idx, result)
                    }
                    activeCount += 1
                    nextIndex += 1
                }
            }

            // Sort results by original order and extract operation results
            self.operationResults = results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        isPerformingOperation = false
        if !isStopping && self.operationResults.contains(where: { !$0.success }) {
            showingResults = true
        }
        isStopping = false
    }

    // Execute a single operation on a repository
    private func executeOperation(
        repo: GitRepo,
        operation: OperationResult.GitOperation,
        action: @escaping (GitRepo) async throws -> String
    ) async -> OperationResult {
        // Mark repo as being operated on
        await MainActor.run {
            operatingRepoIDs.insert(repo.id)
        }

        defer {
            // Remove from operating set when done
            Task { @MainActor in
                operatingRepoIDs.remove(repo.id)
            }
        }

        do {
            print("[DEBUG] Starting \(operation.rawValue) on: \(repo.name) at \(repo.url.path)")
            let output = try await action(repo)
            print("[SUCCESS] \(operation.rawValue) completed for: \(repo.name)")
            return OperationResult(
                repoName: "\(repo.name) (\(repo.url.path))",
                operation: operation,
                success: true,
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: Date()
            )
        } catch {
            print("[ERROR] \(operation.rawValue) failed for: \(repo.name)")
            print("[ERROR] Path: \(repo.url.path)")
            print("[ERROR] Message: \(error.localizedDescription)")
            if let gitError = error as? GitServiceError {
                print("[ERROR] Git Error Details: \(gitError.errorDescription ?? "Unknown")")
            }
            return OperationResult(
                repoName: "\(repo.name) (\(repo.url.path))",
                operation: operation,
                success: false,
                message: error.localizedDescription,
                timestamp: Date()
            )
        }
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
