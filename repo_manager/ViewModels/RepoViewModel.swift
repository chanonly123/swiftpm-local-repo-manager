import Foundation
import SwiftUI

// One RepoViewModel == one git repository, and it is the single source of truth for that
// repo. The same reference is passed into every view that renders the repo (list row, its
// branch/merge/rebase/delete sheets, and its diff window), so any change — a git op from the
// row, a commit from the diff window, or a background FSEvents refresh — is observed
// everywhere it's shown. No view keeps its own copy of the repo's data.
// Stored properties stay non-isolated (like RepoManagerViewModel) so the coordinator's
// computed selectors can read them synchronously; the methods that mutate them are @MainActor
// so all mutation lands on the main thread.
@Observable
final class RepoViewModel: Identifiable {
    // The repo data model. Reassigned wholesale on refresh; observation tracks the accessors.
    var repo: GitRepo
    // Selection lives here (replaces the coordinator's selectedRepoIDs set).
    var isSelected: Bool = false
    // True while a git operation on this repo is in flight (replaces operatingRepoIDs).
    @MainActor var isOperating: Bool = false
    // Set after a history-rewriting op (rebase/squash/reset) so the diff window offers Force
    // Push as the primary action; cleared once a push/force-push lands. Session-only — not
    // persisted, resets to false on relaunch.
    @MainActor var needsForcePush: Bool = false
    // Last single-op failure, shown inline on the row until the next op clears it.
    var lastOperationError: String?
    // Bumps on every refresh / operation. Detached observers (the diff window) watch this to
    // know the repo changed — GitRepo's Equatable only compares url, so `.onChange(of: repo)`
    // wouldn't fire on a status/branch change.
    private(set) var changeToken: Int = 0

    // Stable across the object's life (derived from the repo path, which never changes here).
    let id: UUID

    private let gitService: GitService

    init(repo: GitRepo, gitService: GitService) {
        self.repo = repo
        self.id = repo.id
        self.gitService = gitService
    }

    // MARK: - Refresh

    // Silent background refresh: never flips to .loading, just swaps in fresh data when it
    // arrives. Skipped while an operation is running (that op reloads at the end).
    @MainActor
    func refresh() async {
        guard !isOperating else { return }
        await reload()
    }

    @MainActor
    func reload() async {
        let old = repo.status.displayText
        repo = await gitService.getRepoInfo(at: repo.url)
        changeToken &+= 1
        debugLog("[DEBUG] refresh \(repo.name): \(old) -> \(repo.status.displayText) branch=\(repo.currentBranch ?? "nil") token=\(changeToken)")
    }

    // MARK: - Operations

    // Runs a git command, records success/failure as an OperationResult (for batch
    // aggregation), reloads the repo, and surfaces any error inline via lastOperationError.
    @MainActor
    private func perform(
        _ operation: OperationResult.GitOperation,
        _ action: (GitRepo) async throws -> String
    ) async -> OperationResult {
        isOperating = true
        lastOperationError = nil
        let snapshot = repo
        let result: OperationResult
        do {
            debugLog("[DEBUG] Starting \(operation.rawValue) on: \(snapshot.name)")
            let output = try await action(snapshot)
            debugLog("[SUCCESS] \(operation.rawValue) completed for: \(snapshot.name)")
            result = OperationResult(
                repoName: "\(snapshot.name) (\(snapshot.url.path))",
                operation: operation,
                success: true,
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: Date()
            )
        } catch {
            debugLog("[ERROR] \(operation.rawValue) failed for: \(snapshot.name): \(error.localizedDescription)")
            lastOperationError = error.localizedDescription
            result = OperationResult(
                repoName: "\(snapshot.name) (\(snapshot.url.path))",
                operation: operation,
                success: false,
                message: error.localizedDescription,
                timestamp: Date()
            )
        }
        // If the user cancelled (Stop), skip the reload — its git commands would be
        // terminated too and flip the repo to an error state. Keep the prior status; a
        // later refresh/FSEvents update will reconcile it.
        if !Task.isCancelled {
            await reload()
        }
        isOperating = false
        return result
    }

    @MainActor @discardableResult func pull() async -> OperationResult {
        await perform(.pull) { try await self.gitService.pull(at: $0.url) }
    }

    @MainActor @discardableResult func fetch() async -> OperationResult {
        await perform(.fetch) { try await self.gitService.fetch(at: $0.url) }
    }

    @MainActor @discardableResult func push() async -> OperationResult {
        let result = await perform(.push) { try await self.gitService.push(at: $0.url) }
        if result.success { needsForcePush = false }
        return result
    }

    @MainActor @discardableResult func forcePush() async -> OperationResult {
        let result = await perform(.forcePush) { try await self.gitService.forcePush(at: $0.url) }
        if result.success { needsForcePush = false }
        return result
    }

    @MainActor @discardableResult func hardReset() async -> OperationResult {
        await perform(.hardReset) { try await self.gitService.hardReset(at: $0.url) }
    }

    @MainActor @discardableResult func clean() async -> OperationResult {
        await perform(.clean) { try await self.gitService.clean(at: $0.url) }
    }

    @MainActor @discardableResult func recheckout(toBranch: String? = nil) async -> OperationResult {
        await perform(.recheckout) { try await self.gitService.recheckout(at: $0.url, toBranch: toBranch) }
    }

    @MainActor @discardableResult func merge(branch: String) async -> OperationResult {
        await perform(.merge) { try await self.gitService.merge(at: $0.url, branch: branch) }
    }

    @MainActor @discardableResult func rebase(onto branch: String) async -> OperationResult {
        let result = await perform(.rebase) { try await self.gitService.rebase(at: $0.url, onto: branch) }
        if result.success { needsForcePush = true }
        return result
    }

    @MainActor @discardableResult func switchBranch(name: String, stashChanges: Bool) async -> OperationResult {
        await perform(.switchBranch) { try await self.gitService.switchBranch(at: $0.url, name: name, stashChanges: stashChanges) }
    }

    @MainActor @discardableResult func createBranch(name: String, stashChanges: Bool) async -> OperationResult {
        await perform(.createBranch) { try await self.gitService.createBranch(at: $0.url, name: name, stashChanges: stashChanges) }
    }

    @MainActor @discardableResult func deleteBranch(name: String, deleteRemote: Bool) async -> OperationResult {
        await perform(.deleteBranch) { try await self.gitService.deleteBranch(at: $0.url, name: name, deleteRemote: deleteRemote) }
    }

    // Continue / abort the in-progress operation recorded on the repo (nil if none).
    @MainActor @discardableResult func continueInProgress() async -> OperationResult? {
        guard let operation = repo.inProgressOperation else { return nil }
        let result = await perform(.continueOperation) { try await self.gitService.continueInProgress(at: $0.url, operation: operation) }
        // A rebase that paused on a conflict rewrites history once continued to completion.
        if result.success, operation == .rebase { needsForcePush = true }
        return result
    }

    @MainActor @discardableResult func abortInProgress() async -> OperationResult? {
        guard let operation = repo.inProgressOperation else { return nil }
        return await perform(.abortOperation) { try await self.gitService.abortInProgress(at: $0.url, operation: operation) }
    }
}
