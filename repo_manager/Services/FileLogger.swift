import Foundation
import AppKit

// Session-based file logging for field diagnostics — the app hits edge cases that don't
// reproduce reliably, so we persist a moderate log the user can share back.
//
// Non-sandboxed, so logs live in the user's ~/Library/Logs/<AppName>/ — the conventional
// macOS location, visible in Console.app and easy to find/share. A fresh file is created
// per app session; files older than a day are pruned on launch to bound disk use.
//
// All mutable state is confined to a private serial queue, so `log(_:)` is safe to call
// synchronously from any thread/actor (it never blocks the caller — the write is async).
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    let logsDirectory: URL
    let currentLogFileURL: URL

    private let queue = DispatchQueue(label: "com.repomanager.filelogger")
    private var handle: FileHandle?
    // DateFormatter isn't thread-safe; only ever touched inside `queue`.
    private let timestampFormatter: DateFormatter
    private let retention: TimeInterval = 24 * 60 * 60 // 1 day

    private init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "GitRepoManager"
        logsDirectory = library.appendingPathComponent("Logs/\(appName)", isDirectory: true)

        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        timestampFormatter = timestamp

        // One file per session: session-yyyy-MM-dd-HHmmss.log
        let fileName = DateFormatter()
        fileName.locale = Locale(identifier: "en_US_POSIX")
        fileName.dateFormat = "yyyy-MM-dd-HHmmss"
        currentLogFileURL = logsDirectory.appendingPathComponent("session-\(fileName.string(from: Date())).log")

        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: currentLogFileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentLogFileURL)

        queue.async { [weak self] in self?.pruneOldLogs() }

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        log("===== Session started — \(appName) \(version) (\(build)) =====")
    }

    // Append one timestamped line. Timestamp is captured now but formatted/written on the
    // serial queue, so the call is non-blocking and the formatter stays single-threaded.
    func log(_ message: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let line = "\(self.timestampFormatter.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if self.handle == nil {
                self.handle = try? FileHandle(forWritingTo: self.currentLogFileURL)
                try? self.handle?.seekToEnd()
            }
            try? self.handle?.write(contentsOf: data)
        }
    }

    // Delete prior session logs older than the retention window (never the current file).
    private func pruneOldLogs() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        for url in files where url.pathExtension == "log" && url != currentLogFileURL {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - User actions (menu)

    func revealLogsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentLogFileURL])
    }

    func openCurrentLog() {
        NSWorkspace.shared.open(currentLogFileURL)
    }
}
