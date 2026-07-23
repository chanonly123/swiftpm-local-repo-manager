import Foundation

// A branch name paired with when it was last used, for the "Recent" section's relative
// timestamp ("2 min ago", "1 day ago").
struct RecentBranch: Codable, Equatable {
    let name: String
    let date: Date

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // Compact "2 min ago" / "1 day ago" style label shown next to the branch name.
    var relativeDescription: String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// Tracks a small most-recently-used list of branch names per repo, so branch pickers can
// surface a "Recent" section the way GitHub Desktop's branch switcher does. Recorded whenever
// a branch is checked out, merged, rebased onto, or created; trimmed when deleted.
enum RecentBranchStore {
    private static let limit = 5

    private static func key(for repoURL: URL) -> String {
        "recentBranches.\(repoURL.path)"
    }

    static func recent(for repoURL: URL) -> [RecentBranch] {
        guard let data = UserDefaults.standard.data(forKey: key(for: repoURL)),
              let list = try? JSONDecoder().decode([RecentBranch].self, from: data) else { return [] }
        return list
    }

    // Moves `branch` to the front of the MRU list with a fresh timestamp (inserting it if
    // new), trimmed to `limit`.
    static func record(_ branch: String, for repoURL: URL) {
        var list = recent(for: repoURL)
        list.removeAll { $0.name == branch }
        list.insert(RecentBranch(name: branch, date: Date()), at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        save(list, for: repoURL)
    }

    // Drops a branch that no longer exists (e.g. after it's deleted).
    static func remove(_ branch: String, for repoURL: URL) {
        var list = recent(for: repoURL)
        list.removeAll { $0.name == branch }
        save(list, for: repoURL)
    }

    private static func save(_ list: [RecentBranch], for repoURL: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key(for: repoURL))
    }
}
