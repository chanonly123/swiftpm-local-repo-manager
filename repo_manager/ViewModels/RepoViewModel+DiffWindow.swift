import Foundation
import AppKit

// Diff/history window logic. The window is a thin view over this — all the loading, commit,
// stash and diff-export work lives here, mutating the @Published state declared on the main
// RepoViewModel so it survives closing/reopening the window and stays shared with the repo.
@MainActor
extension RepoViewModel {
    // The repo's git actor, shared with its row/sheets, so the window's loads and commits
    // serialize with every other operation on this repo instead of racing on its own instance.
    private var git: GitService { gitService }
    private var repoURL: URL { repo.url }

    // Git's empty-tree object — used as the "from" side when the oldest commit is the repo
    // root and therefore has no parent to diff against.
    private static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    // MARK: - Derived state

    // A porcelain status representing an active merge conflict (UU/AA/DD/AU/UA/DU/UD).
    func isConflict(_ status: String) -> Bool {
        status.contains("U") || (status.first == "A" && status.last == "A") || (status.first == "D" && status.last == "D")
    }

    // Block committing only while conflicts still have leftover markers. Once the user
    // removes the markers the files are treated as resolved — committing git-adds them,
    // which is how git marks a conflict resolved.
    var hasUnresolvedConflicts: Bool {
        !unresolvedConflicts.isEmpty
    }

    // "Name <email>", or just whichever is set — nil when neither is configured.
    var gitIdentityText: String? {
        let name = gitIdentity.name, email = gitIdentity.email
        switch (name.isEmpty, email.isEmpty) {
        case (false, false): return "\(name) <\(email)>"
        case (false, true): return name
        case (true, false): return "<\(email)>"
        case (true, true): return nil
        }
    }

    var allFilesChecked: Bool {
        !files.isEmpty && files.allSatisfy { checkedPaths.contains($0.id) }
    }

    func toggleAllChecked() {
        if allFilesChecked {
            checkedPaths.removeAll()
        } else {
            checkedPaths = Set(files.map { $0.id })
        }
    }

    // Number of commits to squash, but only when the selection is the top N
    // contiguous commits (a soft reset can only collapse commits down from HEAD).
    var squashableCount: Int? {
        let n = selectedCommits.count
        guard n >= 2, commits.count >= n else { return nil }
        let topIDs = Set(commits.prefix(n).map(\.id))
        return topIDs == selectedCommits ? n : nil
    }

    // Combined message seeded from the selected commits, oldest first.
    var squashDefaultMessage: String {
        guard let n = squashableCount else { return "" }
        return commits.prefix(n).reversed().map(\.subject).joined(separator: "\n\n")
    }

    // The selected items in list order, but only if they form a single contiguous block in
    // `all` (no gaps). Returns nil otherwise — used to gate the "Create Diff" action, which
    // only makes sense for a consecutive run.
    private func contiguousSelection<T: Identifiable>(_ selection: Set<T.ID>, in all: [T]) -> [T]? {
        guard !selection.isEmpty else { return nil }
        let indices = all.indices.filter { selection.contains(all[$0].id) }
        guard indices.count == selection.count else { return nil }
        guard let first = indices.first, let last = indices.last,
              last - first == indices.count - 1 else { return nil }
        return indices.map { all[$0] }
    }

    // Contiguous selections (list order: newest-first for both) ready for diff export.
    var contiguousCommitSelection: [CommitEntry]? { contiguousSelection(selectedCommits, in: commits) }
    var contiguousStashSelection: [StashEntry]? { contiguousSelection(selectedStash, in: stashes) }

    // MARK: - Window lifecycle loads

    // Initial load when the window opens: identity + the three lists.
    func loadDiffWindow() async {
        gitIdentity = await git.getUserIdentity(at: repoURL)
        await loadFiles()
        await loadCommits(reset: true)
        await loadStashes()
    }

    // Reload everything when the shared VM signals a change (FSEvents, app-active, our own
    // ops). The diff is refreshed only for a currently-selected file — a selected commit's
    // diff is historical and doesn't change on a working-tree refresh.
    func reloadDiffWindow() async {
        await loadFiles()
        await refreshCommits()
        await loadStashes()
        if let path = selectedPath, let entry = files.first(where: { $0.id == path }) {
            await loadDiff(entry: entry, showLoader: false)
        }
    }

    // MARK: - Selection changes

    func onSelectPath(_ path: String?) {
        guard let path, let entry = files.first(where: { $0.id == path }) else { return }
        selectedCommits = []
        selectedStash = []
        Task { await loadDiff(entry: entry) }
    }

    func onSelectCommits(_ hashes: Set<String>) {
        guard !hashes.isEmpty else { return }
        selectedPath = nil
        selectedStash = []
        // Show a diff only when a single commit is selected; multi-select is for squashing.
        if hashes.count == 1, let hash = hashes.first {
            Task { await loadCommitDiff(hash: hash) }
        } else {
            diffLines = []
            tooLarge = false
        }
    }

    func onSelectStash(_ refs: Set<String>) {
        guard !refs.isEmpty else { return }
        selectedPath = nil
        selectedCommits = []
        // Show a diff only when a single stash is selected; multi-select is for export.
        if refs.count == 1, let ref = refs.first {
            Task { await loadStashDiff(ref: ref) }
        } else {
            diffLines = []
            tooLarge = false
        }
    }

    // MARK: - Data loading

    func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let raw = try await git.getChangedFiles(at: repoURL)
            files = raw.map { FileEntry(id: $0.path, status: $0.status, path: $0.path) }
            let currentIDs = Set(files.map { $0.id })
            // While any file is in a conflict state, check which still have leftover
            // markers. Editing/saving the file (or FSEvents) re-runs loadFiles, so the
            // set updates live as the user resolves each conflict.
            unresolvedConflicts = files.contains(where: { isConflict($0.status) })
                ? (try? await git.unresolvedConflictPaths(at: repoURL)) ?? []
                : []
            // Persist the checkbox selection on the VM so it survives closing/reopening the
            // window. Auto-check only files we've never seen before (genuinely new, incl. the
            // first-ever load which checks everything); keep the user's choices otherwise.
            let appeared = currentIDs.subtracting(knownFilePaths)
            checkedPaths = checkedPaths.intersection(currentIDs).union(appeared)
            knownFilePaths.formUnion(currentIDs)
            // Only auto-select the first file on the initial load (nothing selected yet).
            if selectedPath == nil && selectedCommits.isEmpty {
                selectedPath = files.first?.id
            } else if let path = selectedPath, !currentIDs.contains(path) {
                // The selected file is gone (committed/discarded) — clear the stale diff.
                selectedPath = nil
                diffLines = []
            }
        } catch {
            debugLog("[ERROR] RepoViewModel loadFiles: \(error)")
        }
    }

    func loadDiff(entry: FileEntry, showLoader: Bool = true) async {
        // On a background refresh (showLoader == false) keep the current diff on
        // screen instead of blanking to a spinner; just swap in the new content.
        if showLoader {
            loadingDiff = true
            tooLarge = false
            diffLines = []
        }
        defer { loadingDiff = false }
        do {
            let raw = try await entry.status.hasPrefix("??")
                ? git.getDiffUntracked(at: repoURL, filePath: entry.path)
                : git.getDiff(at: repoURL, filePath: entry.path)
            guard raw.utf8.count <= diffSizeLimit else { tooLarge = true; diffLines = []; return }
            tooLarge = false
            diffLines = parseDiff(raw)
        } catch {
            debugLog("[ERROR] RepoViewModel loadDiff: \(error)")
        }
    }

    func loadCommits(reset: Bool) async {
        if reset {
            loadingCommits = true
            defer { loadingCommits = false }
            do {
                let raw = try await git.getCommitHistory(at: repoURL, skip: 0, limit: commitPageSize)
                commits = raw.map { CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags) }
                hasMoreCommits = raw.count == commitPageSize
            } catch {
                debugLog("[ERROR] RepoViewModel loadCommits: \(error)")
            }
        } else {
            guard !loadingMoreCommits else { return }
            loadingMoreCommits = true
            defer { loadingMoreCommits = false }
            do {
                let raw = try await git.getCommitHistory(at: repoURL, skip: commits.count, limit: commitPageSize)
                let existing = Set(commits.map { $0.id })
                let newEntries = raw
                    .filter { !existing.contains($0.hash) }
                    .map { CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags) }
                commits.append(contentsOf: newEntries)
                hasMoreCommits = raw.count == commitPageSize
            } catch {
                debugLog("[ERROR] RepoViewModel loadCommits(more): \(error)")
            }
        }
    }

    // Re-fetch history without collapsing the loaded page count or losing the selection.
    func refreshCommits() async {
        let count = max(commitPageSize, commits.count)
        do {
            let raw = try await git.getCommitHistory(at: repoURL, skip: 0, limit: count)
            commits = raw.map { CommitEntry(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject, author: $0.author, relativeDate: $0.relativeDate, tags: $0.tags) }
            hasMoreCommits = raw.count == count
            // Drop any selected commits that no longer exist (e.g. history rewritten)
            let existing = Set(commits.map(\.id))
            selectedCommits.formIntersection(existing)
        } catch {
            debugLog("[ERROR] RepoViewModel refreshCommits: \(error)")
        }
    }

    func loadCommitDiff(hash: String) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await git.getCommitDiff(at: repoURL, hash: hash)
            guard raw.utf8.count <= diffSizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            debugLog("[ERROR] RepoViewModel loadCommitDiff: \(error)")
        }
    }

    func loadStashes() async {
        loadingStashes = true
        defer { loadingStashes = false }
        do {
            let raw = try await git.getStashes(at: repoURL)
            stashes = raw.map { StashEntry(id: $0.ref, message: $0.message, relativeDate: $0.relativeDate) }
            // Drop any stale stash selections that no longer exist (e.g. popped/dropped)
            selectedStash.formIntersection(Set(stashes.map { $0.id }))
        } catch {
            debugLog("[ERROR] RepoViewModel loadStashes: \(error)")
        }
    }

    func loadStashDiff(ref: String) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await git.getStashDiff(at: repoURL, ref: ref)
            guard raw.utf8.count <= diffSizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            debugLog("[ERROR] RepoViewModel loadStashDiff: \(error)")
        }
    }

    // MARK: - Commit / file actions

    func performCommit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = files.filter { checkedPaths.contains($0.id) }.map { $0.path }
        guard !message.isEmpty, !paths.isEmpty else { return }
        isCommitting = true
        commitError = nil
        isOperating = true // suppress FSEvents refreshes while this write runs
        defer { isCommitting = false }
        do {
            try await git.stageFiles(at: repoURL, paths: paths)
            _ = try await git.commitStaged(at: repoURL, message: message)
            debugLog("[COMMIT] \(repo.name): committed \(paths.count) file(s)")
            // Keep the window open — clear the composer and refresh in place.
            commitMessage = ""
            checkedPaths.removeAll()
            isOperating = false // release before refreshing so refresh() isn't skipped
            await refresh()
            await loadFiles()
            await refreshCommits()
        } catch {
            isOperating = false
            debugLog("[ERROR] \(repo.name): commit failed — \(error.localizedDescription)")
            commitError = error.localizedDescription
        }
    }

    func discardFile(_ entry: FileEntry) async {
        do {
            try await git.discardFileChanges(at: repoURL, filePath: entry.path, status: entry.status)
            if selectedPath == entry.id { selectedPath = nil; diffLines = [] }
            await refresh()
            await loadFiles()
        } catch {
            debugLog("[ERROR] RepoViewModel discardFile: \(error)")
        }
    }

    // MARK: - Commit / stash actions

    func resetToCommit(_ commit: CommitEntry, hard: Bool) async {
        isOperating = true // suppress FSEvents refreshes while this write runs
        do {
            _ = try await git.resetToCommit(at: repoURL, hash: commit.id, hard: hard)
            needsForcePush = true // moving the branch rewrites history vs origin
            isOperating = false // release before refreshing so refresh() isn't skipped
            // Refresh the shared VM so the row (branch position + status) updates too.
            await refresh()
            await loadFiles()
            await refreshCommits()
        } catch {
            isOperating = false
            debugLog("[ERROR] RepoViewModel resetToCommit: \(error)")
        }
    }

    func squashSelectedCommits(message: String) async {
        guard let count = squashableCount else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isOperating = true // suppress FSEvents refreshes while this write runs
        do {
            _ = try await git.squashCommits(at: repoURL, count: count, message: trimmed)
            needsForcePush = true // squash rewrites history vs origin
            selectedCommits = []
            isOperating = false // release before refreshing so refresh() isn't skipped
            await refresh()
            await loadFiles()
            await refreshCommits()
        } catch {
            isOperating = false
            debugLog("[ERROR] RepoViewModel squashSelectedCommits: \(error)")
        }
    }

    func applyStash(_ stash: StashEntry, removeAfter: Bool) async {
        do {
            if removeAfter {
                _ = try await git.popStash(at: repoURL, ref: stash.id)
            } else {
                _ = try await git.applyStash(at: repoURL, ref: stash.id)
            }
            await refresh()
            await loadFiles()
            await loadStashes()
        } catch {
            debugLog("[ERROR] RepoViewModel applyStash: \(error)")
        }
    }

    func dropStash(_ stash: StashEntry) async {
        do {
            _ = try await git.dropStash(at: repoURL, ref: stash.id)
            if selectedStash.contains(stash.id) { selectedStash.remove(stash.id); diffLines = [] }
            await loadStashes()
        } catch {
            debugLog("[ERROR] RepoViewModel dropStash: \(error)")
        }
    }

    // Stash the checked files (tracked changes + untracked among them).
    func stashSelectedFiles() async {
        let paths = files.filter { checkedPaths.contains($0.id) }.map { $0.path }
        guard !paths.isEmpty else { return }
        isOperating = true
        do {
            _ = try await git.stashFiles(at: repoURL, paths: paths)
            debugLog("[STASH] \(repo.name): stashed \(paths.count) file(s)")
            isOperating = false
            await refresh()
            await loadFiles()
            await loadStashes()
        } catch {
            isOperating = false
            addBanner("Stash failed: \(error.localizedDescription)")
            debugLog("[ERROR] \(repo.name): stash failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Create diff (export selected commits / stashes to a .diff file)

    // Cumulative patch introduced by a contiguous run of commits (list is newest-first).
    func createCommitDiff(_ selected: [CommitEntry]) async {
        guard let newest = selected.first, let oldest = selected.last else { return }
        let patch: String
        do {
            patch = try await git.getRangeDiff(at: repoURL, from: "\(oldest.id)^", to: newest.id)
        } catch {
            // Oldest is likely the root commit (no parent) — diff from the empty tree.
            patch = (try? await git.getRangeDiff(at: repoURL, from: Self.emptyTreeHash, to: newest.id)) ?? ""
        }
        let name = selected.count == 1
            ? "\(newest.shortHash).diff"
            : "\(oldest.shortHash)..\(newest.shortHash).diff"
        saveDiff(patch, suggestedName: name)
    }

    // Combined patch of the currently checked working-tree files (the same set the Commit
    // button would stage). Tracked files diff against HEAD; untracked files diff against
    // /dev/null so their full content is captured.
    func createSelectedFilesDiff() async {
        let selected = files.filter { checkedPaths.contains($0.id) }
        guard !selected.isEmpty else { return }
        var parts: [String] = []
        for entry in selected {
            let raw = entry.status.hasPrefix("??")
                ? (try? await git.getDiffUntracked(at: repoURL, filePath: entry.path)) ?? ""
                : (try? await git.getDiff(at: repoURL, filePath: entry.path)) ?? ""
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(raw) }
        }
        saveDiff(parts.joined(separator: "\n"), suggestedName: "working-changes.diff")
    }

    // Combined patch of the selected stashes, each stash's diff concatenated in list order.
    func createStashDiff(_ selected: [StashEntry]) async {
        var parts: [String] = []
        for stash in selected {
            if let patch = try? await git.getStashDiff(at: repoURL, ref: stash.id) {
                parts.append("### \(stash.id)  \(stash.message)\n\(patch)")
            }
        }
        let combined = parts.joined(separator: "\n")
        let name = selected.count == 1 ? "\(selected[0].id).diff" : "stashes.diff"
        saveDiff(combined, suggestedName: name)
    }

    // Prompt for a destination and write the patch to disk.
    private func saveDiff(_ contents: String, suggestedName: String) {
        guard !contents.isEmpty else {
            debugLog("[DEBUG] Create diff: empty patch, nothing to save")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(repo.name)-\(suggestedName)"
        panel.canCreateDirectories = true
        panel.title = "Save Diff"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            debugLog("[SUCCESS] Saved diff to \(url.path)")
        } catch {
            debugLog("[ERROR] Failed to save diff: \(error.localizedDescription)")
        }
    }

    // Pick a .diff/.patch file and apply it to the working tree.
    func applyPatchFromFile() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select a .diff or .patch file to apply"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isOperating = true // suppress FSEvents refreshes while this write runs
        do {
            _ = try await git.applyPatch(at: repoURL, patchPath: url.path)
            debugLog("[SUCCESS] Applied patch \(url.lastPathComponent) to \(repo.name)")
            isOperating = false // release before refreshing so refresh() isn't skipped
            await refresh()
            await loadFiles()
        } catch {
            isOperating = false
            addBanner("Apply patch failed: \(error.localizedDescription)")
            debugLog("[ERROR] Apply patch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Diff parsing

    func parseDiff(_ text: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var fileCount = 0
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.hasPrefix("diff --git") {
                fileCount += 1
                // Show the file path as a header, with a separator before every file after the first
                result.append(DiffLine(id: i, text: filePath(fromDiffGit: line), kind: .fileHeader, showSeparator: fileCount > 1))
                continue
            }
            // Drop low-signal header lines — the bold file header already shows the path
            if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename from")
                || line.hasPrefix("rename to") { continue }
            let kind: DiffLine.Kind
            if line.hasPrefix("+") { kind = .added }
            else if line.hasPrefix("-") { kind = .removed }
            else if line.hasPrefix("@@") { kind = .hunk }
            else { kind = .context }
            result.append(DiffLine(id: i, text: line, kind: kind))
        }
        return result
    }

    // Extract the file path from a "diff --git a/path b/path" line
    private func filePath(fromDiffGit line: String) -> String {
        let body = line.dropFirst("diff --git ".count)
        if let range = body.range(of: " b/") {
            return String(body[range.upperBound...])
        }
        return String(body)
    }
}
