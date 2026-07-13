import Foundation
import SwiftUI
import Combine

// One RepoViewModel == one git repository, and it is the single source of truth for that
// repo. The same reference is passed into every view that renders the repo (list row, its
// branch/merge/rebase/delete sheets, and its diff window), so any change — a git op from the
// row, a commit from the diff window, or a background FSEvents refresh — is observed
// everywhere it's shown. No view keeps its own copy of the repo's data.
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
    // Set after a history-rewriting op (rebase/squash/reset) so the diff window offers Force
    // Push as the primary action; cleared once a push/force-push lands. Session-only — not
    // persisted, resets to false on relaunch.
    @Published var needsForcePush: Bool = false
    // Operation failures for this repo, shown in the top-right banner stack (row + diff
    // window). Never auto-cleared — the user dismisses each banner explicitly.
    @Published var banners: [BannerItem] = []
    // Diff-window changed-files selection, kept on the VM so it survives closing/reopening the
    // window (session-only). `knownFilePaths` remembers every path we've seen so a reopen
    // restores the saved checkbox state instead of re-checking everything.
    @Published var checkedPaths: Set<String> = []
    @Published var knownFilePaths: Set<String> = []
    // Bumps on every refresh / operation. The detached diff window watches this via
    // `.onChange` to reload its content — GitRepo's Equatable only compares url, so
    // `.onChange(of: repo)` wouldn't fire on a status/branch change. In-list rows don't need
    // it; they observe `repo` directly now that the type is uniformly @MainActor.
    @Published private(set) var changeToken: Int = 0

    // MARK: - Diff window state
    //
    // The diff/history window renders no repo data of its own — everything below lives here so
    // it survives closing/reopening the window and stays in lockstep with the shared repo. The
    // loading/action logic that fills these lives in RepoViewModel+DiffWindow.swift.

    // Changed files and the selected file's diff.
    @Published var files: [FileEntry] = []
    @Published var selectedPath: String?
    @Published var diffLines: [DiffLine] = []
    @Published var loadingFiles = true
    @Published var loadingDiff = false
    @Published var tooLarge = false

    // Commit composer state.
    @Published var commitMessage = ""
    @Published var isCommitting = false
    @Published var commitError: String?
    @Published var gitIdentity: (name: String, email: String) = ("", "")
    // Conflicted files that still contain leftover conflict markers (unresolved). Refreshed by
    // loadFiles(); once empty, the conflict warning gives way to the commit UI.
    @Published var unresolvedConflicts: Set<String> = []

    // Commit history (paged) and its selection.
    @Published var commits: [CommitEntry] = []
    @Published var selectedCommits: Set<String> = []
    @Published var loadingCommits = true
    @Published var loadingMoreCommits = false
    @Published var hasMoreCommits = true

    // Files changed in the currently-selected commit/stash, and which one's diff is shown.
    // GitHub-Desktop style: the history diff panel lists these files, then shows the selected
    // file's diff in `diffLines`.
    @Published var commitFiles: [FileEntry] = []
    @Published var selectedCommitFile: String?
    @Published var loadingCommitFiles = false
    // The (revision + file) currently loaded into diffLines. Auto-selecting the first file loads
    // it directly; this lets the selection's onChange skip re-loading that same file.
    var loadedRevisionFileKey: String?

    // History tab + stashes and their selection.
    @Published var historyTab: HistoryTab = .commits
    @Published var stashes: [StashEntry] = []
    @Published var selectedStash: Set<String> = []
    @Published var loadingStashes = true

    let diffSizeLimit = 1_000_000
    let commitPageSize = 10

    // Stable across the object's life (derived from the repo path, which never changes here).
    let id: UUID

    // This repo's single git actor. Every git command for this repo — row operations, the diff
    // window's loads/commits, the branch sheets' listings — goes through this one instance, so
    // they all run serially (see GitService's SerialGate). Exposed (not private) so the diff
    // window and sheets share it instead of spinning up their own unserialized GitService.
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
        let old = repo.status.displayText
        repo = await gitService.getRepoInfo(at: repo.url)
        changeToken &+= 1
        debugLog("[DEBUG] refresh \(repo.name): \(old) -> \(repo.status.displayText) branch=\(repo.currentBranch ?? "nil") token=\(changeToken)")
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

    @discardableResult func recheckout(toBranch: String? = nil) async -> OperationResult {
        await perform(.recheckout) { try await self.gitService.recheckout(at: $0.url, toBranch: toBranch) }
    }

    @discardableResult func merge(branch: String) async -> OperationResult {
        await perform(.merge) { try await self.gitService.merge(at: $0.url, branch: branch) }
    }

    @discardableResult func rebase(onto branch: String) async -> OperationResult {
        let result = await perform(.rebase) { try await self.gitService.rebase(at: $0.url, onto: branch) }
        if result.success { needsForcePush = true }
        return result
    }

    @discardableResult func switchBranch(name: String, stashChanges: Bool) async -> OperationResult {
        await perform(.switchBranch) { try await self.gitService.switchBranch(at: $0.url, name: name, stashChanges: stashChanges) }
    }

    @discardableResult func createBranch(name: String, stashChanges: Bool) async -> OperationResult {
        await perform(.createBranch) { try await self.gitService.createBranch(at: $0.url, name: name, stashChanges: stashChanges) }
    }

    @discardableResult func deleteBranch(name: String, deleteRemote: Bool) async -> OperationResult {
        await perform(.deleteBranch) { try await self.gitService.deleteBranch(at: $0.url, name: name, deleteRemote: deleteRemote) }
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
}
