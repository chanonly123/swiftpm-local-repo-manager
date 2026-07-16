import Foundation

struct CommitEntry: Identifiable {
    let id: String          // full hash
    let shortHash: String
    let subject: String
    let author: String
    let relativeDate: String
    let tags: [String]
}
