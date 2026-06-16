import Foundation

struct WorkspaceTab: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var directoryPath: String?
    var bookmarkData: Data?

    init(id: UUID = UUID(), name: String = "Untitled", directoryPath: String? = nil, bookmarkData: Data? = nil) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
        self.bookmarkData = bookmarkData
    }

    var directoryURL: URL? {
        guard let path = directoryPath else { return nil }
        return URL(fileURLWithPath: path)
    }
}
