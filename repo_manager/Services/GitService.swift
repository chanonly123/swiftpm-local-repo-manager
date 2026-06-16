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
    nonisolated func getStatus(at repoURL: URL) async throws -> (hasChanges: Bool, output: String) {
        let output = try await runGitCommand(
            args: ["status", "--porcelain"],
            at: repoURL
        )
        let hasChanges = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasChanges, output)
    }

    // Get remote URL
    nonisolated func getRemoteURL(at repoURL: URL) async throws -> String? {
        do {
            let output = try await runGitCommand(
                args: ["remote", "get-url", "origin"],
                at: repoURL
            )
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // Pull from remote
    nonisolated func pull(at repoURL: URL) async throws -> String {
        try await runGitCommand(
            args: ["pull"],
            at: repoURL
        )
    }

    // Fetch from remote
    nonisolated func fetch(at repoURL: URL) async throws -> String {
        try await runGitCommand(
            args: ["fetch", "--all"],
            at: repoURL
        )
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

        do {

            if status.hasChanges {
                messages.append("Stashing uncommitted changes...")
                _ = try await runGitCommand(args: ["stash"], at: repoURL)
                didStash = true
            }

            // Fetch from origin
            messages.append("Fetching from origin...")
            _ = try? await runGitCommand(args: ["fetch"], at: repoURL)

            // Checkout -B (creates or resets branch)
            messages.append("Checking out to \(targetBranch)...")
            _ = try? await runGitCommand(
                args: ["checkout", "-B", targetBranch, "origin/\(targetBranch)"],
                at: repoURL
            )
        } catch {
            // Restore stash if needed

            if didStash {
                messages.append("Restoring stashed changes...")
                _ = try? await runGitCommand(args: ["stash", "pop"], at: repoURL)
            }

            throw error
        }

        // Restore stash if needed
        if didStash {
            messages.append("Restoring stashed changes...")
            _ = try await runGitCommand(args: ["stash", "pop"], at: repoURL)
        }

        messages.append("✓ Successfully rechecked out to \(targetBranch)")
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

        // Clean untracked files
        // messages.append("Cleaning untracked files...")
        // _ = try await runGitCommand(args: ["clean", "-fd"], at: repoURL)

        messages.append("✓ Successfully reset to HEAD")
        return messages.joined(separator: "\n")
    }

    // Get ahead/behind counts relative to upstream
    nonisolated func getAheadBehind(at repoURL: URL, branch: String) async -> (ahead: Int, behind: Int)? {
        guard let output = try? await runGitCommand(
            args: ["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"],
            at: repoURL
        ) else { return nil }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    // Run a git command
    private nonisolated func runGitCommand(args: [String], at repoURL: URL) async throws -> String {
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
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw GitServiceError.commandFailed(errorOutput.isEmpty ? "Unknown error" : errorOutput)
            }

            return output
        } catch let error as GitServiceError {
            print("[ERROR] runGitCommand: \(error.localizedDescription)")
            throw error
        } catch {
            print("[ERROR] runGitCommand: \(error.localizedDescription)")
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
                hasUncommittedChanges: false,
                remoteURL: nil
            )
        }

        do {
            async let branchTask = getCurrentBranch(at: repoURL)
            async let statusTask = getStatus(at: repoURL)
            async let remoteTask = getRemoteURL(at: repoURL)

            let branch = try await branchTask
            let status = try await statusTask
            let remote = try await remoteTask

            let resolvedBranch = branch.isEmpty ? "unknown" : branch
            let aheadBehind = await getAheadBehind(at: repoURL, branch: resolvedBranch)
            let changedFiles = status.output
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count

            return GitRepo(
                name: name,
                url: repoURL,
                currentBranch: resolvedBranch,
                status: status.hasChanges ? .uncommittedChanges : .clean,
                hasUncommittedChanges: status.hasChanges,
                remoteURL: remote,
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
                hasUncommittedChanges: false,
                remoteURL: nil
            )
        }
    }
}
