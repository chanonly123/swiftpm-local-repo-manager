import Foundation

enum RepoServiceError: LocalizedError {
    case projectNotFound
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "project not found"
        case .readFailed(let message):
            return "Failed to read project file: \(message)"
        case .writeFailed(let message):
            return "Failed to write project file: \(message)"
        }
    }
}

actor RepoService {
    // Folders to ignore during scanning
    private let ignoredFolderNames = ["DerivedData", "Derived Data", ".build", "Build", "build"]

    // Find all Xcode projects recursively in a directory
    func findXcodeProjects(in directory: URL) async throws -> [XcodeProject] {
        var projects: [XcodeProject] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            // Skip ignored folders
            let folderName = fileURL.lastPathComponent
            if ignoredFolderNames.contains(folderName) {
                enumerator.skipDescendants()
                continue
            }

            // Check if it's an .xcodeproj directory
            if fileURL.pathExtension == "xcodeproj" {
                let pbxprojPath = fileURL.appendingPathComponent("project.pbxproj")
                if fileManager.fileExists(atPath: pbxprojPath.path) {
                    let project = XcodeProject(projectPath: fileURL)
                    projects.append(project)
                }
            }
        }

        return projects.sorted { $0.name < $1.name }
    }

    func addLocalDependencies(
        project: XcodeProject,
        baseDirectory: URL,
        repositories: [GitRepo]
    ) async throws -> (success: Int, total: Int) {
        let projectPath = project.pbxprojPath

        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw RepoServiceError.projectNotFound
        }

        var successCount = 0
        var totalCount = 0

        for repo in repositories {
            let packageSwiftPath = repo.url.appendingPathComponent("Package.swift")

            if
                FileManager.default.fileExists(atPath: packageSwiftPath.path)
                && !repo.name.hasPrefix(".")
            {
                totalCount += 1
                let modifier = XcodeProjModifier(projectPath: projectPath)

                do {
                    _ = try modifier.addFileReferenceToMainGroup(
                        fileName: repo.name,
                        filePath: repo.url.path,
                        fileType: "wrapper",
                        sourceTree: "<absolute>"
                    )
                    successCount += 1
                } catch XcodeProjError.fileReferenceAlreadyExists {
                    // Already exists, count as success
                    successCount += 1
                } catch {
                    // Other errors are actual failures
                    debugLog("[ERROR] Failed to add \(repo.name): \(error)")
                }
            }
        }

        return (successCount, totalCount)
    }

    func removeLocalDependencies(project: XcodeProject) async throws -> Int {
        let projectPath = project.pbxprojPath
        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw RepoServiceError.projectNotFound
        }
        let modifier = XcodeProjModifier(projectPath: projectPath)
        return try modifier.removeLocalDependencies()
    }

    func toggleRunScripts(project: XcodeProject) async throws -> (enabled: Bool, count: Int) {
        let projectPath = project.pbxprojPath

        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw RepoServiceError.projectNotFound
        }

        do {
            var content = try String(contentsOf: projectPath, encoding: .utf8)

            // Count current occurrences
            let shCount = content.components(separatedBy: "shellPath = /bin/sh;").count - 1
            let trueCount = content.components(separatedBy: "shellPath = /usr/bin/true;").count - 1

            // Determine which direction to toggle
            let toTrue = shCount > trueCount

            if toTrue {
                // Replace /bin/sh with /usr/bin/true (disable scripts)
                content = content.replacingOccurrences(of: "shellPath = /bin/sh;", with: "shellPath = /usr/bin/true;")
                try content.write(to: projectPath, atomically: true, encoding: .utf8)
                return (false, shCount)
            } else {
                // Replace /usr/bin/true with /bin/sh (enable scripts)
                content = content.replacingOccurrences(of: "shellPath = /usr/bin/true;", with: "shellPath = /bin/sh;")
                try content.write(to: projectPath, atomically: true, encoding: .utf8)
                return (true, trueCount)
            }
        } catch {
            throw RepoServiceError.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Xcode Project Modifier

struct XcodeProjModifier {
    private let projectPath: URL

    init(projectPath: URL) {
        self.projectPath = projectPath
    }

    @discardableResult
    func addFileReferenceToMainGroup(
        fileName: String,
        filePath: String,
        fileType: String,
        sourceTree: String = "SOURCE_ROOT"
    ) throws -> String {
        let content = try String(contentsOf: projectPath, encoding: .utf8)

        if isFileReferenceExists(in: content, filePath: filePath) {
            throw XcodeProjError.fileReferenceAlreadyExists(filePath)
        }

        let fileReferenceUUID = generateXcodeUUID()

        let fileReferenceEntry = createPBXFileReferenceEntry(
            uuid: fileReferenceUUID,
            fileName: fileName,
            filePath: filePath,
            fileType: fileType,
            sourceTree: sourceTree
        )

        var modifiedContent = insertFileReference(
            in: content,
            fileReference: fileReferenceEntry
        )

        modifiedContent = try addToMainGroup(
            in: modifiedContent,
            fileReferenceUUID: fileReferenceUUID,
            fileName: fileName
        )

        try modifiedContent.write(to: projectPath, atomically: true, encoding: .utf8)

        return fileReferenceUUID
    }

    // MARK: - Private Helper Methods

    private func isFileReferenceExists(in content: String, filePath: String) -> Bool {
        let pattern = "path = \(filePath);"
        return content.contains(pattern)
    }

    private func generateXcodeUUID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = String(format: "%08X", Int(Date().timeIntervalSince1970))
        return String(uuid.prefix(16) + timestamp).prefix(24).uppercased()
    }

    private static let marker = "/* swiftpm-local-repo-manager */"

    private func createPBXFileReferenceEntry(
        uuid: String,
        fileName: String,
        filePath: String,
        fileType: String,
        sourceTree: String
    ) -> String {
        return "\t\t\(uuid) /* \(fileName) */ = {isa = PBXFileReference; lastKnownFileType = \(fileType); name = \(fileName); path = \(filePath); sourceTree = \"\(sourceTree)\"; }; \(XcodeProjModifier.marker)"
    }

    private func insertFileReference(in content: String, fileReference: String) -> String {
        guard let range = content.range(of: "/* Begin PBXFileReference section */") else {
            return content
        }
        // Insert immediately after the section header (no blank line) so removal of the
        // marked line restores the file to its exact original state.
        var modifiedContent = content
        modifiedContent.insert(contentsOf: "\n\(fileReference)", at: range.upperBound)
        return modifiedContent
    }

    private func addToMainGroup(
        in content: String,
        fileReferenceUUID: String,
        fileName: String
    ) throws -> String {
        guard let mainGroupLine = content.split(separator: "\n")
            .first(where: { $0.contains("mainGroup =") }) else {
            throw XcodeProjError.mainGroupNotFound
        }

        let mainGroupUUID = mainGroupLine
            .components(separatedBy: "mainGroup = ")
            .last?
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespaces)

        guard let mainGroupUUID = mainGroupUUID else {
            throw XcodeProjError.mainGroupUUIDNotFound
        }

        let pattern = "\(mainGroupUUID) = \\{[\\s\\S]*?children = \\([\\s\\S]*?\\);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw XcodeProjError.regexCreationFailed
        }

        let nsContent = content as NSString
        guard let match = regex.firstMatch(
            in: content,
            options: [],
            range: NSRange(location: 0, length: nsContent.length)
        ) else {
            throw XcodeProjError.mainGroupDefinitionNotFound
        }

        let matchRange = match.range
        let matchedText = nsContent.substring(with: matchRange)

        guard let childrenEndRange = matchedText.range(of: ");", options: .backwards) else {
            throw XcodeProjError.childrenArrayNotFound
        }

        // Insert before the newline that precedes ); so the ); line is never modified.
        // This makes removal a simple line-filter with no residual diff.
        let beforeParen = matchedText[matchedText.startIndex..<childrenEndRange.lowerBound]
        guard let lastNewlineRange = beforeParen.range(of: "\n", options: .backwards) else {
            throw XcodeProjError.childrenArrayNotFound
        }

        var modifiedMatch = matchedText
        let newEntry = "\n\t\t\t\t\t\(fileReferenceUUID) /* \(fileName) */, \(XcodeProjModifier.marker)"
        modifiedMatch.insert(contentsOf: newEntry, at: lastNewlineRange.lowerBound)

        var modifiedContent = content
        let contentRange = Range(matchRange, in: content)!
        modifiedContent.replaceSubrange(contentRange, with: modifiedMatch)

        return modifiedContent
    }

    // Remove all lines added by this tool — both PBXFileReference and mainGroup children
    // entries carry the marker, so a single filter pass restores the original file exactly.
    @discardableResult
    func removeLocalDependencies() throws -> Int {
        let content = try String(contentsOf: projectPath, encoding: .utf8)
        let marker = XcodeProjModifier.marker
        let lines = content.components(separatedBy: "\n")

        let markedLines = lines.filter { $0.contains(marker) }
        guard !markedLines.isEmpty else { return 0 }

        let fileRefCount = markedLines.filter { $0.contains("PBXFileReference") }.count
        let filtered = lines.filter { !$0.contains(marker) }
        try filtered.joined(separator: "\n").write(to: projectPath, atomically: true, encoding: .utf8)
        return fileRefCount
    }
}

// MARK: - Error Handling

enum XcodeProjError: Error, CustomStringConvertible {
    case mainGroupNotFound
    case mainGroupUUIDNotFound
    case mainGroupDefinitionNotFound
    case childrenArrayNotFound
    case regexCreationFailed
    case fileReferenceAlreadyExists(String)

    var description: String {
        switch self {
        case .mainGroupNotFound:
            return "Could not find mainGroup in project file"
        case .mainGroupUUIDNotFound:
            return "Could not extract mainGroup UUID"
        case .mainGroupDefinitionNotFound:
            return "Could not find mainGroup definition"
        case .childrenArrayNotFound:
            return "Could not find children array in mainGroup"
        case .regexCreationFailed:
            return "Failed to create regular expression"
        case .fileReferenceAlreadyExists(let filePath):
            return "File reference already exists for path: \(filePath)"
        }
    }
}
