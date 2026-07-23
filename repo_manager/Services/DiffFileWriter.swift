import Foundation

enum DiffFileWriterError: LocalizedError {
    case downloadsDirectoryNotFound

    var errorDescription: String? {
        "Could not locate the Downloads folder."
    }
}

// Writes generated diff/patch content to the user's Downloads folder, always under a unique
// name so a repeat "Create Diff" never silently overwrites a previous one.
enum DiffFileWriter {
    static func write(_ diff: String, suggestedName: String) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw DiffFileWriterError.downloadsDirectoryNotFound
        }
        let url = uniqueURL(in: downloads, baseName: suggestedName)
        try diff.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func uniqueURL(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).patch")
        var attempt = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(attempt).patch")
            attempt += 1
        }
        return candidate
    }
}
