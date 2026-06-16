import Foundation

struct XcodeProject: Identifiable, Equatable {
    let id: UUID
    let name: String
    let projectPath: URL // Path to .xcodeproj
    let pbxprojPath: URL // Path to project.pbxproj

    init(projectPath: URL) {
        self.id = UUID()
        self.projectPath = projectPath
        self.name = projectPath.deletingPathExtension().lastPathComponent
        self.pbxprojPath = projectPath.appendingPathComponent("project.pbxproj")
    }

    // Get relative path from base directory
    func relativePath(from baseDirectory: URL) -> String {
        let basePath = baseDirectory.path
        let projectFullPath = projectPath.path

        if projectFullPath.hasPrefix(basePath) {
            var relativePath = String(projectFullPath.dropFirst(basePath.count))
            // Remove leading slash if present
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }
            return relativePath + "/project.pbxproj"
        }

        return projectPath.lastPathComponent + "/project.pbxproj"
    }
}
