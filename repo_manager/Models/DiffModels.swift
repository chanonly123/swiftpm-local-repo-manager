import Foundation

// MARK: - Data models for the diff / history window

struct FileEntry: Identifiable {
    let id: String
    let status: String
    let path: String
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct CommitEntry: Identifiable {
    let id: String          // full hash
    let shortHash: String
    let subject: String
    let author: String
    let relativeDate: String
    let tags: [String]
}

struct StashEntry: Identifiable {
    let id: String          // ref, e.g. "stash@{0}"
    let message: String
    let relativeDate: String
}

struct DiffLine: Identifiable {
    let id: Int
    let text: String
    let kind: Kind
    var showSeparator = false   // draw a horizontal rule above this line (file boundary)
    enum Kind { case added, removed, hunk, meta, context, fileHeader }
}

enum HistoryTab: Hashable { case commits, stashes }
