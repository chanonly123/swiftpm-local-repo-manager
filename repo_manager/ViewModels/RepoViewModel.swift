import Foundation
import SwiftUI
import Combine

// One RepoViewModel == one git repository, and it is the single source of truth for that
// repo. The same reference is passed into every view that renders the repo (list row and its
// branch/merge/rebase/delete/squash sheets), so any change — a git op from the row or a
// background FSEvents refresh — is observed everywhere it's shown. No view keeps its own copy
// of the repo's data.
// The whole type is @MainActor so all observable state is read and mutated on the main actor —
// this is what SwiftUI observation expects, so reassigning `repo` (a value type) reliably
// invalidates every view that read it, with no manual change signal needed for in-list rows.
@MainActor
final class RepoViewModel: ObservableObject, Identifiable {
    // The repo data model. Reassigned wholesale on refresh; observation tracks the accessors.
    @Published var repo: GitRepo
    // Selection lives here (replaces the coordinator's selectedRepoIDs set).
    @Published var isSelected: Bool = false
    // True while a git operation on this repo is in flight (replaces operatingRepoIDs).
    @Published var isOperating: Bool = false
    // When true, perform() skips its post-operation reload. Set by the batch coordinator so a
    // multi-repo operation never runs `git status` on one repo while others are still being
    // written — that concurrency was hanging batches. The coordinator reloads the operated
    // repos once, after the whole batch finishes.
    @Published var deferReload: Bool = false
    // Set after a history-rewriting op (rebase/squash/reset) so the row can offer Force Push;
    // cleared once a push/force-push lands. Session-only — not persisted, resets on relaunch.
    @Published var needsForcePush: Bool = false
    // Operation failures for this repo, shown in the top-right banner stack.
    // Never auto-cleared — the user dismisses each banner explicitly.
    @Published var banners: [BannerItem] = []
    
    @Published var updateHash: String = UUID().uuidString

    // Stable across the object's life (derived from the repo path, which never changes here).
    let id: UUID

    // This repo's single git actor. Every git command for this repo — row operations, the
    // branch/squash sheets' listings — goes through this one instance, so they all run serially
    // (see GitService's SerialGate). Exposed (not private) so sheets share it instead of
    // spinning up their own unserialized GitService.
    let gitService = GitService()

    init(repo: GitRepo) {
        self.repo = repo
        self.id = repo.id
    }

    // MARK: - Refresh

    // Silent background refresh: never flips to .loading, just swaps in fresh data when it
    // arrives. Skipped while an operation is running (that op reloads at the end).
    func refresh() async {
        guard !isOperating else { return }
        await reload()
    }

    func reload() async {
        repo = await gitService.getRepoInfo(at: repo.url)
        updateHash = UUID().uuidString
    }

    // MARK: - Banners

    func addBanner(_ message: String) {
        banners.append(BannerItem(message: message, repoName: repo.name))
    }

    func dismissBanner(_ id: UUID) {
        banners.removeAll { $0.id == id }
    }

    // MARK: - Operations

    // Runs a git command, records success/failure as an OperationResult (for batch
    // aggregation), reloads the repo, and surfaces any failure as a dismissable banner.
    private func perform(
        _ operation: OperationResult.GitOperation,
        _ action: (GitRepo) async throws -> String
    ) async -> OperationResult {
        isOperating = true
        let snapshot = repo
        let result: OperationResult
        do {
            let output = try await action(snapshot)
            result = OperationResult(
                repoName: "\(snapshot.name) (\(snapshot.url.path))",
                operation: operation,
                success: true,
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: Date()
            )
        } catch {
            banners.append(BannerItem(message: "\(operation.rawValue) failed: \(error.localizedDescription)", repoName: snapshot.name))
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
        // later refresh/FSEvents update will reconcile it. In a batch, `deferReload` also
        // suppresses it so `git status` never runs while other repos are still being written;
        // the coordinator reloads all operated repos once the batch completes.
        if !Task.isCancelled && !deferReload {
            await reload()
        }
        isOperating = false
        return result
    }

    @discardableResult func pull() async -> OperationResult {
        await perform(.pull) { try await self.gitService.pull(at: $0.url) }
    }

    @discardableResult func fetch() async -> OperationResult {
        await perform(.fetch) { try await self.gitService.fetch(at: $0.url) }
    }

    @discardableResult func push() async -> OperationResult {
        let result = await perform(.push) { try await self.gitService.push(at: $0.url) }
        if result.success { needsForcePush = false }
        return result
    }

    // Publish a local-only branch (push -u origin <branch>). reload() afterwards refreshes
    // hasRemoteBranch so the UI switches from Publish back to Push.
    @discardableResult func publish() async -> OperationResult {
        let result = await perform(.publish) {
            try await self.gitService.publish(at: $0.url, branch: $0.currentBranch ?? "HEAD")
        }
        if result.success { needsForcePush = false }
        return result
    }

    @discardableResult func forcePush() async -> OperationResult {
        let result = await perform(.forcePush) { try await self.gitService.forcePush(at: $0.url) }
        if result.success { needsForcePush = false }
        return result
    }

    @discardableResult func hardReset() async -> OperationResult {
        await perform(.hardReset) { try await self.gitService.hardReset(at: $0.url) }
    }

    @discardableResult func clean() async -> OperationResult {
        await perform(.clean) { try await self.gitService.clean(at: $0.url) }
    }

    @discardableResult func stash() async -> OperationResult {
        await perform(.stash) { try await self.gitService.stash(at: $0.url) }
    }

    @discardableResult func stashPop() async -> OperationResult {
        await perform(.stashPop) { try await self.gitService.stashPop(at: $0.url) }
    }

    @discardableResult func recheckout(toBranch: String? = nil) async -> OperationResult {
        let result = await perform(.recheckout) { try await self.gitService.recheckout(at: $0.url, toBranch: toBranch) }
        if result.success, let branch = toBranch ?? repo.currentBranch {
            RecentBranchStore.record(branch, for: repo.url)
        }
        return result
    }

    @discardableResult func applyPatch(patchURL: URL) async -> OperationResult {
        await perform(.applyPatch) { try await self.gitService.applyPatch(at: $0.url, patchURL: patchURL) }
    }

    @discardableResult func merge(branch: String) async -> OperationResult {
        let result = await perform(.merge) { try await self.gitService.merge(at: $0.url, branch: branch) }
        if result.success { RecentBranchStore.record(branch, for: repo.url) }
        return result
    }

    @discardableResult func rebase(onto branch: String) async -> OperationResult {
        let result = await perform(.rebase) { try await self.gitService.rebase(at: $0.url, onto: branch) }
        if result.success {
            needsForcePush = true
            RecentBranchStore.record(branch, for: repo.url)
        }
        return result
    }

    @discardableResult func switchBranch(name: String, stashChanges: Bool) async -> OperationResult {
        let result = await perform(.switchBranch) { try await self.gitService.switchBranch(at: $0.url, name: name, stashChanges: stashChanges) }
        if result.success { RecentBranchStore.record(name, for: repo.url) }
        return result
    }

    @discardableResult func createBranch(name: String, stashChanges: Bool) async -> OperationResult {
        let result = await perform(.createBranch) { try await self.gitService.createBranch(at: $0.url, name: name, stashChanges: stashChanges) }
        if result.success { RecentBranchStore.record(name, for: repo.url) }
        return result
    }

    @discardableResult func deleteBranch(name: String, deleteRemote: Bool) async -> OperationResult {
        let result = await perform(.deleteBranch) { try await self.gitService.deleteBranch(at: $0.url, name: name, deleteRemote: deleteRemote) }
        if result.success { RecentBranchStore.remove(name, for: repo.url) }
        return result
    }

    // Squash the most recent `count` commits (a contiguous run from HEAD) into one.
    @discardableResult func squash(count: Int, message: String) async -> OperationResult {
        let result = await perform(.squash) { try await self.gitService.squashCommits(at: $0.url, count: count, message: message) }
        if result.success { needsForcePush = true }
        return result
    }

    // Continue / abort the in-progress operation recorded on the repo (nil if none).
    @discardableResult func continueInProgress() async -> OperationResult? {
        guard let operation = repo.inProgressOperation else { return nil }
        let result = await perform(.continueOperation) { try await self.gitService.continueInProgress(at: $0.url, operation: operation) }
        // A rebase that paused on a conflict rewrites history once continued to completion.
        if result.success, operation == .rebase { needsForcePush = true }
        return result
    }

    @discardableResult func abortInProgress() async -> OperationResult? {
        guard let operation = repo.inProgressOperation else { return nil }
        return await perform(.abortOperation) { try await self.gitService.abortInProgress(at: $0.url, operation: operation) }
    }

    // MARK: - Create Diff

    // Generates a diff file into ~/Downloads. Read-only (no repo mutation), so unlike the
    // operations above this doesn't go through `perform` / trigger a reload — same reasoning
    // as the plain listing calls (getCommitHistory) used by the squash/recheckout sheets.
    private func createDiffFile(suggestedName: String, _ diff: (GitRepo) async throws -> String) async -> URL? {
        do {
            let content = try await diff(repo)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                addBanner("Nothing to diff")
                return nil
            }
            return try DiffFileWriter.write(content, suggestedName: suggestedName)
        } catch {
            addBanner("Create Diff failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult func createDiffFile(oldestCommit: CommitEntry, newestCommit: CommitEntry) async -> URL? {
        await createDiffFile(suggestedName: "\(repo.name)-diff-commits-\(newestCommit.shortHash)-\(oldestCommit.shortHash)") {
            try await self.gitService.diffForCommits(at: $0.url, oldestHash: oldestCommit.id, newestHash: newestCommit.id)
        }
    }

    @discardableResult func createDiffFile(stash: StashEntry) async -> URL? {
        await createDiffFile(suggestedName: "\(repo.name)-diff-stash-\(stash.id)") {
            try await self.gitService.diffForStash(at: $0.url, index: stash.id)
        }
    }

    @discardableResult func createDiffFileForCurrentChanges(paths: [String]) async -> URL? {
        await createDiffFile(suggestedName: "\(repo.name)-diff-changes") {
            try await self.gitService.diffForCurrentChanges(at: $0.url, paths: paths)
        }
    }
}
