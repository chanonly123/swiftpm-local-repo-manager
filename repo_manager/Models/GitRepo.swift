import Foundation
import CryptoKit

struct GitRepo: Identifiable, Hashable {
    // Identity is derived from the repo's location so it stays stable across status
    // refreshes (FSEvents / re-scan rebuild the struct). A random UUID here would give
    // each refresh a new identity, causing SwiftUI to recreate the row and lose its
    // @State (open menus, the new-branch sheet, etc.).
    var id: UUID { GitRepo.stableID(for: url) }
    let name: String
    let url: URL
    var currentBranch: String?
    var status: RepoStatus
    var hasUncommittedChanges: Bool
    var hasConflicts: Bool = false
    var aheadCount: Int?
    var behindCount: Int?
    var changedFilesCount: Int?
    // An in-progress git operation (rebase/merge/cherry-pick/…) left mid-flight,
    // detected from marker files under `.git`. nil when the repo is in a normal state.
    var inProgressOperation: InProgressOperation?

    // A git operation that is paused mid-flight (typically waiting on conflict
    // resolution). The raw value is the human-facing label; `gitCommand` is the
    // subcommand used to --continue / --abort it.
    enum InProgressOperation: String, Equatable {
        case merge = "Merging"
        case rebase = "Rebasing"
        case cherryPick = "Cherry-picking"
        case revert = "Reverting"
        case applyMailbox = "Applying patch"

        var gitCommand: String {
            switch self {
            case .merge: return "merge"
            case .rebase: return "rebase"
            case .cherryPick: return "cherry-pick"
            case .revert: return "revert"
            case .applyMailbox: return "am"
            }
        }
    }

    enum RepoStatus: Equatable {
        case clean
        case uncommittedChanges
        case error(String)
        case loading

        var displayText: String {
            switch self {
            case .clean: return ""
            case .uncommittedChanges: return "changes"
            case .error(let message): return "Error: \(message)"
            case .loading: return "Loading..."
            }
        }

        var color: String {
            switch self {
            case .clean: return "green"
            case .uncommittedChanges: return "orange"
            case .error: return "red"
            case .loading: return "gray"
            }
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: GitRepo, rhs: GitRepo) -> Bool {
        lhs.url == rhs.url
    }

    // Deterministic UUID from the repo path (MD5 conveniently yields 16 bytes).
    private static func stableID(for url: URL) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(url.path.utf8))
        let b = Array(digest)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
