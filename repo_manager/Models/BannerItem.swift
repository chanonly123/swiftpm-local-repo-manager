import Foundation

// A dismissable error/notice shown in the top-right banner stack (ContentView and the diff
// window). Banners never auto-dismiss — the user closes them explicitly.
struct BannerItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let repoName: String?
    let date: Date

    init(message: String, repoName: String? = nil, date: Date = Date()) {
        self.message = message
        self.repoName = repoName
        self.date = date
    }
}
