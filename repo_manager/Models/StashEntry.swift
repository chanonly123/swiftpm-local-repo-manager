import Foundation

struct StashEntry: Identifiable {
    let id: Int          // stash index, e.g. 0 for stash@{0}
    let message: String
}
