import Foundation

enum GitServiceError: LocalizedError {
    case gitNotFound
    case notAGitRepository
    case commandFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .gitNotFound:
            return "Git not found. Please ensure git is installed."
        case .notAGitRepository:
            return "Directory is not a git repository."
        case .commandFailed(let message):
            return "Git command failed: \(message)"
        case .invalidOutput:
            return "Invalid git command output."
        }
    }
}

actor GitService {
    private let gitPath: String

    init() {
        // Try multiple git paths - /usr/bin/git uses xcrun which fails in sandbox
        let possiblePaths = [
            "/Library/Developer/CommandLineTools/usr/bin/git",  // Xcode CommandLineTools
            "/usr/bin/git"            // System fallback
        ]

        self.gitPath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/git"
        print("[DEBUG] Using git at: \(self.gitPath)")
    }

    // Check if directory is a valid git repository
    nonisolated func isGitRepository(at url: URL) -> Bool {
        let gitDir = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.path)
    }

    // Get current branch name
    nonisolated func getCurrentBranch(at repoURL: URL) async throws -> String {
        let output = try await runGitCommand(
            args: ["branch", "--show-current"],
            at: repoURL
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Get repository status
    nonisolated func getStatus(at repoURL: URL) async throws -> (hasChanges: Bool, hasConflicts: Bool, output: String) {
        let output = try await runGitCommand(
            args: ["status", "--porcelain"],
            at: repoURL
        )
        let hasChanges = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Active merge conflict (UU/AA/DD etc. in porcelain)
        let conflictPrefixes = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]
        let hasMergeConflict = output.components(separatedBy: .newlines).contains { line in
            conflictPrefixes.contains(where: { line.hasPrefix($0) })
        }
        return (hasChanges, hasMergeConflict, output)
    }

    // List changed files from git status --porcelain
    nonisolated func getChangedFiles(at repoURL: URL) async throws -> [(status: String, path: String)] {
        let output = try await runGitCommand(args: ["status", "--porcelain"], at: repoURL)
        return output.components(separatedBy: .newlines).compactMap { line in
            guard line.count >= 4 else { return nil }
            let xy = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let range = path.range(of: " -> ") { path = String(path[range.upperBound...]) }
            return path.isEmpty ? nil : (xy, path)
        }
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
        _ = try await runGitCommand(args: ["checkout", name], at: repoURL)
        messages.append("✓ Switched to \(name)")
        return messages.joined(separator: "\n")
    }

    // Full diff for a single commit
    nonisolated func getCommitDiff(at repoURL: URL, hash: String) async throws -> String {
        try await runGitCommand(args: ["show", "--no-color", hash], at: repoURL)
    }

    // List stash entries — newest first
    nonisolated func getStashes(at repoURL: URL) async throws -> [(ref: String, message: String, relativeDate: String)] {
        let format = "%gd%x1f%s%x1f%cr"
        let output = try await runGitCommand(
            args: ["stash", "list", "--pretty=format:\(format)"],
            at: repoURL,
            allowNonZeroExit: true
        )
        return output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1], parts[2])
        }
    }

    // Full diff for a single stash entry (ref like "stash@{0}")
    nonisolated func getStashDiff(at repoURL: URL, ref: String) async throws -> String {
        try await runGitCommand(
            args: ["stash", "show", "-p", "--no-color", ref],
            at: repoURL,
            allowNonZeroExit: true
        )
    }

    // Move the current branch to a commit. hard=true discards changes, false keeps them staged (soft).
    nonisolated func resetToCommit(at repoURL: URL, hash: String, hard: Bool) async throws -> String {
        let mode = hard ? "--hard" : "--soft"
        _ = try await runGitCommand(args: ["reset", mode, hash], at: repoURL)
        return "✓ Moved branch to \(hash) (\(hard ? "hard" : "soft"))"
    }

    // Squash the most recent `count` commits into a single commit with the given
    // message. Uses a soft reset to the commit below the range, then re-commits the
    // combined staged changes.
    nonisolated func squashCommits(at repoURL: URL, count: Int, message: String) async throws -> String {
        _ = try await runGitCommand(args: ["reset", "--soft", "HEAD~\(count)"], at: repoURL)
        _ = try await runGitCommand(args: ["commit", "-m", message], at: repoURL)
        return "✓ Squashed \(count) commits"
    }

    // Apply a stash without removing it
    nonisolated func applyStash(at repoURL: URL, ref: String) async throws -> String {
        try await runGitCommand(args: ["stash", "apply", ref], at: repoURL)
    }

    // Apply a stash and remove it from the stash list
    nonisolated func popStash(at repoURL: URL, ref: String) async throws -> String {
        try await runGitCommand(args: ["stash", "pop", ref], at: repoURL)
    }

    // Delete a stash without applying it
    nonisolated func dropStash(at repoURL: URL, ref: String) async throws -> String {
        try await runGitCommand(args: ["stash", "drop", ref], at: repoURL)
    }

    // Stage specific files
    nonisolated func stageFiles(at repoURL: URL, paths: [String]) async throws {
        _ = try await runGitCommand(args: ["add", "--"] + paths, at: repoURL)
    }

    // Commit currently staged changes
    nonisolated func commitStaged(at repoURL: URL, message: String) async throws -> String {
        try await runGitCommand(args: ["commit", "-m", message], at: repoURL)
    }

    // Diff for a tracked file vs HEAD (staged + unstaged)
    nonisolated func getDiff(at repoURL: URL, filePath: String) async throws -> String {
        try await runGitCommand(args: ["diff", "HEAD", "--", filePath], at: repoURL)
    }

    // Diff for an untracked file (git diff --no-index exits 1 when diffs exist)
    nonisolated func getDiffUntracked(at repoURL: URL, filePath: String) async throws -> String {
        try await runGitCommand(
            args: ["diff", "--no-index", "--", "/dev/null", filePath],
            at: repoURL,
            allowNonZeroExit: true
        )
    }

    // Discard changes for a single file
    nonisolated func discardFileChanges(at repoURL: URL, filePath: String, status: String) async throws {
        if status.hasPrefix("??") {
            // Untracked — delete via git clean
            _ = try await runGitCommand(args: ["clean", "-f", "--", filePath], at: repoURL)
        } else {
            // Tracked — restore both index and worktree to HEAD
            _ = try await runGitCommand(args: ["restore", "--staged", "--worktree", "--", filePath], at: repoURL)
        }
    }

    // Push current branch to origin
    nonisolated func push(at repoURL: URL) async throws -> String {
        try await runGitCommand(args: ["push", "origin", "HEAD"], at: repoURL)
    }

    // Force-push current branch to origin
    nonisolated func forcePush(at repoURL: URL) async throws -> String {
        try await runGitCommand(args: ["push", "--force-with-lease", "origin", "HEAD"], at: repoURL)
    }

    // Get remote URL
    // Pull from remote
    nonisolated func pull(at repoURL: URL) async throws -> String {
        try await runGitCommand(
            args: ["pull"],
            at: repoURL
        )
    }

    // Fetch from remote
    nonisolated func fetch(at repoURL: URL) async throws -> String {
        let out = try? await runGitCommand(
            args: ["fetch", "--all"],
            at: repoURL
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
            _ = try await runGitCommand(args: ["fetch"], at: repoURL)
        } catch {
            messages.append("Fetching from origin...")
            _ = try? await runGitCommand(args: ["remote", "prune", "origin"], at: repoURL)
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
        _ = try await runGitCommand(args: ["reset", "--hard", "HEAD"], at: repoURL)

        _ = try await runGitCommand(args: ["clean", "-f", "-d"], at: repoURL)

        messages.append("✓ Successfully reset to HEAD")
        return messages.joined(separator: "\n")
    }

    // Get ahead/behind counts relative to upstream
    nonisolated func getAheadBehind(at repoURL: URL, branch: String) async -> (ahead: Int, behind: Int)? {
        // Pick a remote ref to compare against. Prefer this branch's own remote
        // tracking branch, then its configured upstream, then the remote's default
        // branch (origin/HEAD). The fallbacks let a freshly created local branch —
        // which has no origin/<branch> ref yet — still show how far ahead/behind it
        // is of the base it was forked from.
        // Verifying the ref first also avoids a noisy "ambiguous argument" error
        // on repos that have never been fetched.
        var remoteRef: String?
        for candidate in ["origin/\(branch)", "@{upstream}", "origin/HEAD"] {
            if (try? await runGitCommand(
                args: ["rev-parse", "--verify", "--quiet", candidate],
                at: repoURL,
                logErrors: false
            )) != nil {
                remoteRef = candidate
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
        return (ahead, behind)
    }

    // Run a git command
    private nonisolated func runGitCommand(args: [String], at repoURL: URL, logErrors: Bool = true, allowNonZeroExit: Bool = false) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = repoURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Drain stdout/stderr *while* the process runs. Reading only after the
            // process exits deadlocks when output exceeds the OS pipe buffer (~64KB):
            // the child blocks writing to the full pipe and never exits. A newly
            // added file's full-content diff easily crosses that threshold. A 30s
            // timeout (which terminates the process to unblock the reads) guards
            // against a genuinely hung git.
            let pipes: (Data, Data)? = await withTaskGroup(of: (Data, Data)?.self) { group in
                group.addTask {
                    let out = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let err = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
                    return (out, err)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(30))
                    if process.isRunning { process.terminate() }
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }

            guard let (outputData, errorData) = pipes else {
                throw GitServiceError.commandFailed("Git command timed out after 30 seconds")
            }

            process.waitUntilExit()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 && !allowNonZeroExit {
                throw GitServiceError.commandFailed(errorOutput.isEmpty ? "Unknown error" : errorOutput)
            }

            return output
        } catch let error as GitServiceError {
            if logErrors { print("[ERROR] runGitCommand: \(error.localizedDescription)") }
            throw error
        } catch {
            if logErrors { print("[ERROR] runGitCommand: \(error.localizedDescription)") }
            throw GitServiceError.commandFailed(error.localizedDescription)
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

            return GitRepo(
                name: name,
                url: repoURL,
                currentBranch: resolvedBranch,
                status: status.hasChanges ? .uncommittedChanges : .clean,
                hasUncommittedChanges: status.hasChanges,
                hasConflicts: status.hasConflicts,
                aheadCount: aheadBehind?.ahead,
                behindCount: aheadBehind?.behind,
                changedFilesCount: status.hasChanges ? changedFiles : nil
            )
        } catch {
            print("[ERROR] getRepoInfo: \(error.localizedDescription)")
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
