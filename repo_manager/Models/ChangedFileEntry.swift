import Foundation

// A single tracked file with uncommitted changes, as reported by `git status --porcelain`.
struct ChangedFileEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String        // repo-relative path
    let statusCode: String  // porcelain XY code, e.g. "M ", " M", "A ", "R "
}
