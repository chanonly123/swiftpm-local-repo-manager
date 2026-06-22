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

    enum RepoStatus: Equatable {
        case clean
        case uncommittedChanges
        case error(String)
        case loading

        var displayText: String {
            switch self {
            case .clean: return "Clean"
            case .uncommittedChanges: return "Uncommitted changes"
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
