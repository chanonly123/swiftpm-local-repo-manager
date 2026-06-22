import Foundation

struct OperationResult: Identifiable {
    let id = UUID()
    let repoName: String
    let operation: GitOperation
    let success: Bool
    let message: String
    let timestamp: Date

    enum GitOperation: String {
        case pull = "Pull"
        case fetch = "Fetch"
        case recheckout = "Recheckout"
        case hardReset = "Hard Reset"
        case push = "Push"
        case forcePush = "Force Push"
        case status = "Status"
        case refresh = "Refresh"
        case createBranch = "Create Branch"
    }
}
