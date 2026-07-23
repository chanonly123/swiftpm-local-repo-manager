import Foundation

enum GitServiceError: LocalizedError {
    case gitNotFound
    case notAGitRepository
    case commandFailed(String)
    case timedOut(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .gitNotFound:
            return "Git not found. Please ensure git is installed."
        case .notAGitRepository:
            return "Directory is not a git repository."
        case .commandFailed(let message):
            return "Git command failed: \(message)"
        case .timedOut(let command):
            return "Git command timed out: \(command)"
        case .invalidOutput:
            return "Invalid git command output."
        }
    }
}

actor GitService {
    // Timeout budget for network/bulk commands (fetch, pull, push, clean, hard reset, …), which
    // legitimately run longer than the 5s default for fast local commands.
    static let networkTimeout: TimeInterval = 30

    private let gitPath: String
    // Per-instance serial gate. Each RepoViewModel owns one GitService, and every command on
    // this instance goes through `runGitCommand`, which acquires this gate — so only one git
    // process runs at a time for a given repo. An `actor` alone can't guarantee this: actors
    // are reentrant, so any `await` inside an isolated method lets the next call interleave.
    // The gate holds across the whole command (spawn → drain → exit), giving true serial
    // execution. Different repos use different instances and still run fully in parallel.
    private let gate = SerialGate()

    init() {
        // Try multiple git paths - /usr/bin/git uses xcrun which fails in sandbox
        let possiblePaths = [
            "/Library/Developer/CommandLineTools/usr/bin/git",  // Xcode CommandLineTools
            "/usr/bin/git"            // System fallback
        ]

        self.gitPath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/git"
    }

    // Check if directory is a valid git repository
    nonisolated func isGitRepository(at url: URL) -> Bool {
        let gitDir = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.path)
    }

    // Get current branch name. `--show-current` prints nothing while HEAD is detached, which is
    // always the case mid-rebase (rebase checks out the target commit directly) — so fall back to
    // the branch name git itself stashed away for the rebase, read the same way git-prompt.sh does.
    nonisolated func getCurrentBranch(at repoURL: URL) async throws -> String {
        let output = try await runGitCommand(
            args: ["branch", "--show-current"],
            at: repoURL
        )
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }
        return rebaseHeadName(at: repoURL) ?? branch
    }

    // Reads the branch being rebased from .git/rebase-merge/head-name (interactive/merge rebase)
    // or .git/rebase-apply/head-name (apply-based rebase, e.g. `git rebase` without --merge).
    // Both store a full ref like "refs/heads/feature"; only branch refs are meaningful here.
    private nonisolated func rebaseHeadName(at repoURL: URL) -> String? {
        let gitDir = repoURL.appendingPathComponent(".git")
        for component in ["rebase-merge/head-name", "rebase-apply/head-name"] {
            let path = gitDir.appendingPathComponent(component)
            guard let contents = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let ref = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.hasPrefix("refs/heads/") {
                return String(ref.dropFirst("refs/heads/".count))
            }
        }
        return nil
    }

    // Get repository status
    nonisolated func getStatus(at repoURL: URL) async throws -> (hasChanges: Bool, hasConflicts: Bool, output: String) {
        let output = try await runGitCommand(
            args: ["status", "--porcelain"],
            at: repoURL,
            noOptionalLocks: true
        )
        let hasChanges = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Active merge conflict (UU/AA/DD etc. in porcelain)
        let conflictPrefixes = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]
        let hasMergeConflict = output.components(separatedBy: .newlines).contains { line in
            conflictPrefixes.contains(where: { line.hasPrefix($0) })
        }
        return (hasChanges, hasMergeConflict, output)
    }

    // Commit history (paged) — newest first
    nonisolated func getCommitHistory(at repoURL: URL, skip: Int, limit: Int) async throws -> [(hash: String, shortHash: String, subject: String, author: String, relativeDate: String, tags: [String])] {
        // Unit-separator (\x1f) between fields keeps subjects with spaces intact; %D lists ref names
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%D"
        let output = try await runGitCommand(
            args: ["log", "--skip=\(skip)", "-n", "\(limit)", "--pretty=format:\(format)"],
            at: repoURL,
            allowNonZeroExit: true // empty repo (no commits yet) exits non-zero
        )
        return output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count == 6 else { return nil }
            // %D looks like "HEAD -> main, tag: v1.0, tag: v2.0, origin/main" — keep only tags
            let tags = parts[5]
                .components(separatedBy: ", ")
                .filter { $0.hasPrefix("tag: ") }
                .map { String($0.dropFirst("tag: ".count)) }
            return (parts[0], parts[1], parts[2], parts[3], parts[4], tags)
        }
    }

    // List stash entries, newest first (index 0 == stash@{0}).
    nonisolated func getStashes(at repoURL: URL) async throws -> [StashEntry] {
        let output = try await runGitCommand(
            args: ["stash", "list", "--pretty=format:%gd%x1f%s"],
            at: repoURL,
            allowNonZeroExit: true
        )
        return output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count == 2,
                  let openBrace = parts[0].firstIndex(of: "{"),
                  let closeBrace = parts[0].firstIndex(of: "}"),
                  let index = Int(parts[0][parts[0].index(after: openBrace)..<closeBrace])
            else { return nil }
            return StashEntry(id: index, message: parts[1])
        }
    }

    // Diff introduced by a contiguous run of commits, oldest..newest (oldest's parent to newest).
    nonisolated func diffForCommits(at repoURL: URL, oldestHash: String, newestHash: String) async throws -> String {
        try await runGitCommand(args: ["diff", "\(oldestHash)^..\(newestHash)"], at: repoURL)
    }

    // Diff for a single stash entry, including any untracked files it captured.
    nonisolated func diffForStash(at repoURL: URL, index: Int) async throws -> String {
        try await runGitCommand(args: ["stash", "show", "-p", "-u", "stash@{\(index)}"], at: repoURL)
    }

    // Diff for current uncommitted changes (staged + unstaged tracked files) against HEAD,
    // restricted to `paths` (repo-relative).
    nonisolated func diffForCurrentChanges(at repoURL: URL, paths: [String]) async throws -> String {
        try await runGitCommand(args: ["diff", "HEAD", "--"] + paths, at: repoURL)
    }

    // List tracked files with uncommitted changes (staged and/or unstaged), for the Create Diff
    // "Current Changes" picker. Untracked files ("??") are excluded — `git diff HEAD` never
    // shows them, so they can't be included in the resulting patch anyway.
    nonisolated func getChangedFiles(at repoURL: URL) async throws -> [ChangedFileEntry] {
        let output = try await runGitCommand(
            args: ["status", "--porcelain"],
            at: repoURL,
            noOptionalLocks: true
        )
        return output.components(separatedBy: .newlines).compactMap { line in
            guard line.count > 3 else { return nil }
            let status = String(line.prefix(2))
            guard status != "??" else { return nil }
            var path = String(line.dropFirst(3))
            // Renames render as "old -> new"; the new path is what `git diff` expects.
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }
            return ChangedFileEntry(path: path, statusCode: status)
        }
    }

    // List local branch names
    // Local branches plus remote-only branches, by short name (deduped, locals first).
    // Remote refs (e.g. "origin/feature") are reduced to their branch name so checking
    // them out creates a local tracking branch instead of detaching HEAD.
    nonisolated func getBranches(at repoURL: URL) async throws -> [String] {
        let output = try await runGitCommand(
            args: ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"],
            at: repoURL
        )
        var seen = Set<String>()
        var locals: [String] = []
        var remoteOnly: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let ref = line.trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { continue }
            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst("refs/heads/".count))
                if seen.insert(name).inserted { locals.append(name) }
            } else if ref.hasPrefix("refs/remotes/") {
                // Drop "refs/remotes/<remote>/" to get the branch short name
                let rest = String(ref.dropFirst("refs/remotes/".count))
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let name = String(rest[rest.index(after: slash)...])
                // Skip the remote HEAD symref (e.g. refs/remotes/origin/HEAD)
                if name == "HEAD" { continue }
                remoteOnly.append(name)
            }
        }
        // Append remote-only branches that don't already exist locally
        for name in remoteOnly where seen.insert(name).inserted {
            locals.append(name)
        }
        return locals
    }

    // Detect a git operation left mid-flight by inspecting marker files under `.git`.
    // This is a pure filesystem check — no git process — so it's cheap to run on every refresh.
    nonisolated func getInProgressOperation(at repoURL: URL) -> GitRepo.InProgressOperation? {
        let gitDir = repoURL.appendingPathComponent(".git")
        let fileManager = FileManager.default
        func exists(_ component: String) -> Bool {
            fileManager.fileExists(atPath: gitDir.appendingPathComponent(component).path)
        }
        // `git am` and an apply-based rebase both use rebase-apply; the `applying`
        // marker distinguishes a mailbox apply from a rebase.
        if exists("rebase-apply") {
            return exists("rebase-apply/applying") ? .applyMailbox : .rebase
        }
        if exists("rebase-merge") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    // Merge a branch into the current branch. Conflicts exit non-zero and surface as an error;
    // the repo is then left in a merging state (see getInProgressOperation).
    nonisolated func merge(at repoURL: URL, branch: String) async throws -> String {
        // Mutating and potentially long: give it the network budget and never auto-retry (a
        // retry could re-run a merge that already left the repo mid-merge).
        let output = try await runGitCommand(args: ["merge", "--no-edit", branch], at: repoURL, timeout: GitService.networkTimeout, retries: 0)
        return output.isEmpty ? "✓ Merged \(branch) into current branch" : output
    }

    // Rebase the current branch onto the given branch. Conflicts exit non-zero and leave the
    // repo mid-rebase.
    nonisolated func rebase(at repoURL: URL, onto branch: String) async throws -> String {
        // Mutating and potentially long: network budget, no auto-retry (avoid re-running a rebase
        // that already left the repo mid-rebase).
        let output = try await runGitCommand(args: ["rebase", branch], at: repoURL, timeout: GitService.networkTimeout, retries: 0)
        return output.isEmpty ? "✓ Rebased current branch onto \(branch)" : output
    }

    // Abort an in-progress operation (rebase/merge/cherry-pick/…), restoring the prior state.
    nonisolated func abortInProgress(at repoURL: URL, operation: GitRepo.InProgressOperation) async throws -> String {
        _ = try await runGitCommand(args: [operation.gitCommand, "--abort"], at: repoURL)
        return "✓ Aborted \(operation.rawValue.lowercased())"
    }

    // Continue an in-progress operation after conflicts are resolved. GIT_EDITOR=true accepts the
    // default commit message non-interactively so the command can't hang waiting on an editor.
    nonisolated func continueInProgress(at repoURL: URL, operation: GitRepo.InProgressOperation) async throws -> String {
        // Resolving conflicts by editing files leaves them unmerged until they're staged; git
        // refuses --continue with "you must mark them as resolved" unless we `git add` first.
        // Stage everything (the standard `git add .` after a conflict fix) so continue can proceed.
        _ = try await runGitCommand(args: ["add", "-A"], at: repoURL)
        _ = try await runGitCommand(
            args: [operation.gitCommand, "--continue"],
            at: repoURL,
            environment: ["GIT_EDITOR": "true"],
            timeout: GitService.networkTimeout,
            retries: 0 // --continue commits; a retry could re-apply a step that already landed
        )
        return "✓ Continued \(operation.rawValue.lowercased())"
    }

    // Switch to an existing branch. Stashes uncommitted changes first when stashChanges is true.
    nonisolated func switchBranch(at repoURL: URL, name: String, stashChanges: Bool) async throws -> String {
        var messages: [String] = []
        if stashChanges {
            let status = try await getStatus(at: repoURL)
            if status.hasChanges {
                messages.append("Stashing uncommitted changes...")
                _ = try await runGitCommand(args: ["stash", "push", "--include-untracked"], at: repoURL)
            }
        }
        messages.append("Switching to \(name)...")
        // -m: three-way merge of local changes into the target branch (instead of refusing
        // when the touched files differ between branches) when they weren't stashed above.
        let checkoutArgs = stashChanges ? ["checkout", name] : ["checkout", "-m", name]
        _ = try await runGitCommand(args: checkoutArgs, at: repoURL)
        messages.append("✓ Switched to \(name)")
        return messages.joined(separator: "\n")
    }

    // Delete a local branch (force, since the user explicitly chose to delete). When
    // deleteRemote is true, also delete the matching branch on origin. A missing local
    // branch isn't fatal when a remote delete was requested — the remote is still removed.
    nonisolated func deleteBranch(at repoURL: URL, name: String, deleteRemote: Bool) async throws -> String {
        var messages: [String] = []
        do {
            _ = try await runGitCommand(args: ["branch", "-D", name], at: repoURL)
            messages.append("✓ Deleted local branch \(name)")
        } catch {
            guard deleteRemote else { throw error }
            messages.append("• No local branch \(name) to delete")
        }
        if deleteRemote {
            _ = try await runGitCommand(args: ["push", "origin", "--delete", name], at: repoURL, timeout: GitService.networkTimeout)
            messages.append("✓ Deleted remote branch origin/\(name)")
        }
        return messages.joined(separator: "\n")
    }

    // Squash the most recent `count` commits into a single commit with the given
    // message. Uses a soft reset to the commit below the range, then re-commits the
    // combined staged changes.
    nonisolated func squashCommits(at repoURL: URL, count: Int, message: String) async throws -> String {
        _ = try await runGitCommand(args: ["reset", "--soft", "HEAD~\(count)"], at: repoURL)
        // Don't auto-retry the commit: if it timed out after already committing, a rerun would
        // spuriously fail with "nothing to commit".
        _ = try await runGitCommand(args: ["commit", "-m", message], at: repoURL, retries: 0)
        return "✓ Squashed \(count) commits"
    }

    // Push current branch to origin
    nonisolated func push(at repoURL: URL) async throws -> String {
        try await runGitCommand(args: ["push", "origin", "HEAD"], at: repoURL, timeout: GitService.networkTimeout)
    }

    // Force-push current branch to origin
    nonisolated func forcePush(at repoURL: URL) async throws -> String {
        try await runGitCommand(args: ["push", "--force-with-lease", "origin", "HEAD"], at: repoURL, timeout: GitService.networkTimeout)
    }

    // Publish a local-only branch: push and set it to track origin/<branch>.
    nonisolated func publish(at repoURL: URL, branch: String) async throws -> String {
        try await runGitCommand(args: ["push", "--set-upstream", "origin", branch], at: repoURL, timeout: GitService.networkTimeout)
    }

    // Get remote URL
    // Pull from remote
    nonisolated func pull(at repoURL: URL) async throws -> String {
        try await runGitCommand(
            args: ["pull"],
            at: repoURL,
            timeout: GitService.networkTimeout
        )
    }

    // Fetch from remote. Fetch is the one command that can block on the network — waiting
    // on a credential/host-key prompt or a stalled transfer — so it gets git-level defenses the
    // other commands don't need:
    //   • GIT_TERMINAL_PROMPT=0 + SSH BatchMode: fail fast instead of blocking on a prompt.
    //   • ConnectTimeout / http low-speed limits: git itself aborts a dead or crawling connection.
    // It's also cancellable mid-flight via the Stop button (task cancellation → terminate).
    nonisolated func fetch(at repoURL: URL) async throws -> String {
        let out = try? await runGitCommand(
            args: [
                "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=15",
                "fetch", "--all"
            ],
            at: repoURL,
            environment: [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
            ],
            timeout: GitService.networkTimeout
        )
        return out ?? ""
    }

    // Recheckout to branch (stash, fetch, checkout -B, stash pop)
    nonisolated func recheckout(at repoURL: URL, toBranch: String? = nil) async throws -> String {
        var messages: [String] = []

        // Get current branch if no target branch specified
        let targetBranch: String
        if let branch = toBranch {
            targetBranch = branch
        } else {
            targetBranch = try await getCurrentBranch(at: repoURL)
        }

        guard !targetBranch.isEmpty && targetBranch != "unknown" && targetBranch != "HEAD" else {
            throw GitServiceError.commandFailed("Invalid branch: \(targetBranch)")
        }

        // Check for uncommitted changes
        let status = try await getStatus(at: repoURL)
        var didStash = false

        if status.hasChanges {
            messages.append("Stashing uncommitted changes...")
            _ = try await runGitCommand(args: ["stash"], at: repoURL)
            didStash = true
        }

        func finish() async throws {
            // Restore stash if needed
            if didStash {
                messages.append("Restoring stashed changes...")
                _ = try await runGitCommand(args: ["stash", "pop"], at: repoURL)
            }
        }

        do {
            // Fetch from origin
            messages.append("Fetching from origin...")
            _ = try await runGitCommand(args: ["fetch"], at: repoURL, timeout: GitService.networkTimeout)
        } catch {
            messages.append("Fetching from origin...")
            _ = try? await runGitCommand(args: ["remote", "prune", "origin"], at: repoURL, timeout: GitService.networkTimeout)
        }

        do {
            // Checkout -B (creates or resets branch)
            messages.append("Checking out to \(targetBranch)...")
            _ = try await runGitCommand(
                args: ["checkout", "-B", targetBranch, "origin/\(targetBranch)"],
                at: repoURL
            )
            messages.append("✓ Successfully rechecked out to \(targetBranch)")
        } catch {
            try await finish()
            throw error
        }

        try? await finish()

        return messages.joined(separator: "\n")
    }

    // Create and switch to a new branch.
    // If stashChanges is true, uncommitted changes are stashed first so the new branch starts clean;
    // otherwise `git checkout -b` carries the working-tree changes over to the new branch.
    nonisolated func createBranch(at repoURL: URL, name: String, stashChanges: Bool) async throws -> String {
        var messages: [String] = []

        if stashChanges {
            let status = try await getStatus(at: repoURL)
            if status.hasChanges {
                messages.append("Stashing uncommitted changes...")
                _ = try await runGitCommand(args: ["stash", "push", "--include-untracked"], at: repoURL)
            }
        }

        messages.append("Creating branch \(name)...")
        _ = try await runGitCommand(args: ["checkout", "-b", name], at: repoURL)
        messages.append("✓ Created and switched to \(name)")
        return messages.joined(separator: "\n")
    }

    // Hard reset to HEAD (discards all uncommitted changes)
    nonisolated func hardReset(at repoURL: URL) async throws -> String {
        var messages: [String] = []

        // Check for uncommitted changes
        let status = try await getStatus(at: repoURL)

        if status.hasChanges {
            messages.append("⚠️  Discarding all uncommitted changes...")
        }

        // Perform hard reset
        messages.append("Resetting to HEAD...")
        _ = try await runGitCommand(args: ["reset", "--hard", "HEAD"], at: repoURL, timeout: GitService.networkTimeout)

        _ = try await runGitCommand(args: ["clean", "-f", "-d"], at: repoURL, timeout: GitService.networkTimeout)

        messages.append("✓ Successfully reset to HEAD")
        return messages.joined(separator: "\n")
    }

    // Stash uncommitted changes (including untracked files). `git stash push` exits 0 with
    // "No local changes to save" when there's nothing to stash — check first so that case
    // surfaces as an error instead of silently succeeding.
    nonisolated func stash(at repoURL: URL) async throws -> String {
        let status = try await getStatus(at: repoURL)
        guard status.hasChanges else {
            throw GitServiceError.commandFailed("No local changes to stash.")
        }
        return try await runGitCommand(args: ["stash", "push", "--include-untracked"], at: repoURL)
    }

    // Pop the most recent stash (stash@{0}).
    nonisolated func stashPop(at repoURL: URL) async throws -> String {
        try await runGitCommand(args: ["stash", "pop"], at: repoURL)
    }

    // Remove ALL untracked and ignored files/directories (git clean -xdf). Unlike the clean
    // baked into hardReset (-f -d), the -x flag also deletes ignored files — build artifacts,
    // caches, DerivedData, etc. Does not touch tracked changes.
    nonisolated func clean(at repoURL: URL) async throws -> String {
        let output = try await runGitCommand(args: ["clean", "-xdf"], at: repoURL, timeout: GitService.networkTimeout)
        let removed = output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        return "✓ Cleaned \(removed) untracked/ignored item(s)"
    }

    // Apply a diff/patch file to the working tree with a 3-way merge fallback (uses the blob
    // info recorded in the patch to merge instead of failing outright on context mismatches).
    // Leaves conflict markers in affected files on partial failure; nothing is committed.
    nonisolated func applyPatch(at repoURL: URL, patchURL: URL) async throws -> String {
        // Mutating and non-idempotent: a retry after a partial apply could double-apply hunks
        // or conflict differently, so no auto-retry (same reasoning as merge/rebase).
        _ = try await runGitCommand(args: ["apply", "--3way", patchURL.path], at: repoURL, timeout: GitService.networkTimeout, retries: 0)
        return "✓ Applied \(patchURL.lastPathComponent)"
    }

    // Get ahead/behind counts relative to upstream, plus whether the branch is actually
    // published (has its own remote branch / configured upstream — not just the fork-point
    // fallback). `hasUpstream == false` means the branch exists only locally: the UI offers
    // Publish instead of Push.
    nonisolated func getAheadBehind(at repoURL: URL, branch: String) async -> (ahead: Int, behind: Int, hasUpstream: Bool)? {
        // Pick a remote ref to compare against. Prefer this branch's own remote
        // tracking branch, then its configured upstream, then the remote's default
        // branch (origin/HEAD). The fallbacks let a freshly created local branch —
        // which has no origin/<branch> ref yet — still show how far ahead/behind it
        // is of the base it was forked from.
        // Verifying the ref first also avoids a noisy "ambiguous argument" error
        // on repos that have never been fetched.
        var remoteRef: String?
        var hasUpstream = false
        for candidate in ["origin/\(branch)", "@{upstream}", "origin/HEAD"] {
            if (try? await runGitCommand(
                args: ["rev-parse", "--verify", "--quiet", candidate],
                at: repoURL,
                logErrors: false // candidates are expected to miss; not a real failure
            )) != nil {
                remoteRef = candidate
                // origin/HEAD is only the fork-point fallback — matching it does not mean
                // this branch itself is published.
                hasUpstream = candidate != "origin/HEAD"
                break
            }
        }
        guard let remoteRef else { return nil }

        guard let output = try? await runGitCommand(
            args: ["rev-list", "--left-right", "--count", "HEAD...\(remoteRef)"],
            at: repoURL
        ) else { return nil }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else { return nil }
        return (ahead, behind, hasUpstream)
    }

    // Run a git command, serialized on this service's gate and bounded by a timeout.
    //
    // `timeout` caps how long a single attempt may run (default 5s for fast local commands; the
    // network/bulk callers pass GitService.networkTimeout). A command that exceeds it is killed
    // and surfaces as GitServiceError.timedOut, so nothing can hang forever.
    //
    // `retries` re-runs the command *only* after a timeout (never after a genuine failure or a
    // user Stop) — a deterministic command that failed on its merits won't magically pass on a
    // rerun, and re-issuing a mutating command that actually failed could do harm.
    private nonisolated func runGitCommand(args: [String], at repoURL: URL, logErrors: Bool = true, allowNonZeroExit: Bool = false, environment: [String: String]? = nil, noOptionalLocks: Bool = false, timeout: TimeInterval = 5, retries: Int = 2) async throws -> String {
        let repoName = repoURL.lastPathComponent
        // --no-optional-locks stops read-only commands (status/diff) from taking index.lock
        // for their opportunistic index refresh, so they can never contend with a concurrent
        // write on the same repo (e.g. an FSEvents-triggered status during a commit/rebase).
        let fullArgs = noOptionalLocks ? ["--no-optional-locks"] + args : args
        let command = "git \(fullArgs.joined(separator: " "))"

        // Serialize: wait until any in-flight command on this service finishes before starting.
        // Released in the defer, whether the command succeeds, fails, or is cancelled (Stop).
        await gate.acquire()
        defer { gate.release() }

        var lastError: Error = GitServiceError.commandFailed("Unknown error")
        for attempt in 0...max(0, retries) {
            if attempt > 0 {
                debugLog("[GitService] \(repoName) retry \(attempt + 1)/\(retries + 1): \(command)")
            }
            do {
                let result = try await runGitProcess(
                    fullArgs: fullArgs, command: command,
                    at: repoURL, environment: environment,
                    allowNonZeroExit: allowNonZeroExit,
                    timeout: timeout
                )
                debugLog("[GitService] \(repoName) ran: \(command)")
                return result
            } catch let error as GitServiceError {
                lastError = error
                if logErrors {
                    debugLog("[GitService] \(repoName) failed: \(command) — \(error.localizedDescription)")
                }
                if case .timedOut = error, attempt < retries, !Task.isCancelled { continue }
                throw error
            }
        }
        throw lastError
    }

    // One attempt at running the process. Spawns git, drains its pipes, and enforces `timeout`.
    //
    // The whole spawn/drain/wait runs on background dispatch threads and reports its outcome
    // through a one-shot `RunState`. Crucially, the timeout (and a user Stop) resolve that same
    // RunState and return to the caller *immediately* — we never await the pipe reads on the
    // timeout path. That's the fix for the app hang: on Darwin, neither closing the read fd nor
    // SIGTERM reliably unblocks a `readToEnd()` that a surviving child still holds open, so any
    // design that awaited the read could hang forever. Here the reader thread may leak for a hung
    // command, but the app always makes progress. git is force-killed (SIGTERM then SIGKILL).
    private nonisolated func runGitProcess(fullArgs: [String], command: String, at repoURL: URL, environment: [String: String]?, allowNonZeroExit: Bool, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = fullArgs
        process.currentDirectoryURL = repoURL
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let state = RunState()
        nonisolated(unsafe) let proc = process
        nonisolated(unsafe) let outHandle = outputPipe.fileHandleForReading
        nonisolated(unsafe) let errHandle = errorPipe.fileHandleForReading

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                state.attach(continuation)

                // Worker: spawn git, drain both pipes concurrently (avoids the >64KB stderr/stdout
                // deadlock), wait, and report. Runs off the Swift cooperative pool so a batch of
                // blocked reads can't starve it. If it's abandoned (timeout/Stop already resolved
                // the RunState), `finish` is a no-op and this thread simply unwinds — or leaks,
                // if a surviving child holds the pipe, which is bounded and preferable to a hang.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try proc.run()
                    } catch {
                        state.finish(.failure(GitServiceError.commandFailed(error.localizedDescription)))
                        return
                    }

                    // Mutated on the reader threads, read here after group.wait() — the group's
                    // barrier makes that safe; nonisolated(unsafe) tells the compiler so.
                    let group = DispatchGroup()
                    nonisolated(unsafe) var outputData = Data()
                    nonisolated(unsafe) var errorData = Data()
                    // .userInitiated to match the worker thread that's about to block on
                    // group.wait() below — a higher-QoS thread waiting on lower-QoS readers is
                    // a priority inversion (flagged by the Thread Performance Checker), since
                    // DispatchGroup.wait() can't donate priority the way a direct call would.
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async { outputData = (try? outHandle.readToEnd()) ?? Data(); group.leave() }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async { errorData = (try? errHandle.readToEnd()) ?? Data(); group.leave() }
                    group.wait()
                    proc.waitUntilExit()

                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    if proc.terminationStatus != 0 && !allowNonZeroExit {
                        let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        state.finish(.failure(GitServiceError.commandFailed(detail.isEmpty ? "Unknown error" : detail)))
                    } else {
                        state.finish(.success(output))
                    }
                }

                // Timeout: kill git and resolve immediately, without waiting on the reader threads.
                // SIGTERM then SIGKILL — SIGKILL can't be caught or blocked, so a git that ignores
                // SIGTERM (or is wedged) still dies. Guard pid > 0: kill(0, …) hits our own group.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard !state.isFinished else { return }
                    if proc.isRunning {
                        proc.terminate()
                        if proc.processIdentifier > 0 { kill(proc.processIdentifier, SIGKILL) }
                    }
                    state.finish(.failure(GitServiceError.timedOut(command)))
                }
            }
        } onCancel: {
            if proc.isRunning {
                proc.terminate()
                if proc.processIdentifier > 0 { kill(proc.processIdentifier, SIGKILL) }
            }
            state.finish(.failure(GitServiceError.commandFailed("Git command cancelled")))
        }
    }

    // Scan directory for git repositories
    nonisolated func scanForRepositories(at directoryURL: URL) async throws -> [URL] {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var gitRepos: [URL] = []

        for url in contents {
            // Check if it's a directory
            guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else {
                continue
            }

            // Check if it contains a .git folder
            if isGitRepository(at: url) {
                gitRepos.append(url)
            }
        }

        return gitRepos.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Get detailed information for a repository
    nonisolated func getRepoInfo(at repoURL: URL) async -> GitRepo {
        let name = repoURL.lastPathComponent

        guard isGitRepository(at: repoURL) else {
            return GitRepo(
                name: name,
                url: repoURL,
                currentBranch: nil,
                status: .error("Not a git repository"),
                hasUncommittedChanges: false
            )
        }

        do {
            async let branchTask = getCurrentBranch(at: repoURL)
            async let statusTask = getStatus(at: repoURL)

            let branch = try await branchTask
            let status = try await statusTask

            let resolvedBranch = branch.isEmpty ? "unknown" : branch
            let aheadBehind = await getAheadBehind(at: repoURL, branch: resolvedBranch)
            let changedFiles = status.output
                .components(separatedBy: .newlines)
                .filter { $0.count >= 4 }
                .count
            let inProgress = getInProgressOperation(at: repoURL)

            return GitRepo(
                name: name,
                url: repoURL,
                currentBranch: resolvedBranch,
                status: status.hasChanges ? .uncommittedChanges : .clean,
                hasUncommittedChanges: status.hasChanges,
                hasConflicts: status.hasConflicts,
                aheadCount: aheadBehind?.ahead,
                behindCount: aheadBehind?.behind,
                hasRemoteBranch: aheadBehind?.hasUpstream ?? false,
                changedFilesCount: status.hasChanges ? changedFiles : nil,
                inProgressOperation: inProgress
            )
        } catch {
            return GitRepo(
                name: name,
                url: repoURL,
                currentBranch: nil,
                status: .error(error.localizedDescription),
                hasUncommittedChanges: false
            )
        }
    }
}

/// One-shot resolution for a single git run. Whichever of the worker, the timeout, or a user Stop
/// gets there first resumes the continuation exactly once; every later `finish` is ignored. This
/// is what lets the timeout return to the caller without waiting on a reader thread that may never
/// unblock. Lock-backed so it's safe to call from any dispatch thread and the cancellation handler.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        // A Stop can fire onCancel (→ finish) before the operation attaches its continuation.
        // Resume right away in that case, otherwise the continuation would never be resumed.
        if finished {
            lock.unlock()
            continuation.resume(throwing: GitServiceError.commandFailed("Git command cancelled"))
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// A serial async gate: only one holder runs at a time; others await their turn in FIFO order.
///
/// Backed by a plain `NSLock` rather than actor isolation so `release()` is synchronous and can
/// be called from a `defer` inside the nonisolated `runGitCommand`. Ownership is handed off
/// directly to the next waiter on release, so the gate is never momentarily free between a
/// release and the next acquire (no lost wakeups, strict FIFO).
///
/// A task cancelled while waiting stays queued until its turn, then proceeds — `runGitCommand`
/// itself checks `Task.isCancelled` and terminates its process, so nothing blocks permanently.
private final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        lock.lock()
        if !isBusy {
            isBusy = true
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            isBusy = false
            lock.unlock()
        } else {
            // Hand ownership straight to the next waiter; `isBusy` stays true.
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
