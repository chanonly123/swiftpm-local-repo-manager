import Foundation
import AsyncFileMonitor

/// Wrapper around AsyncFileMonitor for monitoring git repository changes
@Observable
class FSEventsMonitor {
    private var monitoringTask: Task<Void, Never>?
    private var callback: ((URL) -> Void)?
    private(set) var isPaused = false

    /// Start monitoring multiple repositories at once
    func startMonitoringMultiple(repoURLs: [URL], onChange: @escaping (URL) -> Void) {
        self.callback = onChange

        // Stop any existing monitoring
        stopMonitoring()

        guard !repoURLs.isEmpty else { return }

        // Create set of paths for quick lookup
        let monitoredPaths = Set(repoURLs.map { $0.path })

        print("[DEBUG] Starting monitoring for \(repoURLs.count) repositories")

        // Create event stream for all repository paths with higher latency to debounce
        let eventStream = FolderContentMonitor.makeStream(
            paths: Array(monitoredPaths),
            latency: 1.0  // Higher latency to coalesce rapid git command changes
        )

        // Start monitoring task
        monitoringTask = Task { [weak self] in
            for await event in eventStream {
                guard let self = self, !Task.isCancelled else { break }

                // Drop events while paused (app not in focus)
                if self.isPaused {
                    continue
                }

                // Ignore all events from .git directory (git internal operations)
                if event.eventPath.contains("/.git/") || event.filename.hasPrefix(".git/") {
                    continue
                }

                // Find which repo this event belongs to
                for monitoredPath in monitoredPaths {
                    if event.eventPath.hasPrefix(monitoredPath) {
                        // Notify on main actor with the repo URL
                        let repoURL = URL(fileURLWithPath: monitoredPath)
                        await MainActor.run {
                            self.callback?(repoURL)
                        }
                        break
                    }
                }
            }
            print("[DEBUG] Monitoring task completed")
        }

        print("[DEBUG] Started monitoring \(repoURLs.count) repositories")
    }

    func pause() {
        isPaused = true
        print("[DEBUG] FSEvents monitoring paused (app inactive)")
    }

    func resume() {
        isPaused = false
        print("[DEBUG] FSEvents monitoring resumed (app active)")
    }

    /// Stop monitoring all repositories
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        print("[DEBUG] Stopped monitoring repositories")
    }

    deinit {
        stopMonitoring()
    }
}
