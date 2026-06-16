import Foundation

struct GitRepo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    var currentBranch: String?
    var status: RepoStatus
    var hasUncommittedChanges: Bool
    var remoteURL: String?
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
        hasher.combine(id)
    }

    static func == (lhs: GitRepo, rhs: GitRepo) -> Bool {
        lhs.id == rhs.id
    }
}
