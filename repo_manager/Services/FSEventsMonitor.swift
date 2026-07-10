import Foundation
import AsyncFileMonitor

/// Wrapper around AsyncFileMonitor for monitoring git repository changes
class FSEventsMonitor {
    private var monitoringTask: Task<Void, Never>?
    private var callback: ((URL) -> Void)?
    // Paused when the app loses focus / the tab is inactive.
    private(set) var isPaused = false
    // Suspended while git operations run, so operation-induced file churn doesn't spawn a burst
    // of contending status refreshes. Kept separate from `isPaused` so resuming after an
    // operation never overrides an app-focus/tab pause that's still in effect.
    private(set) var isSuspendedForOperation = false

    // Events are dropped unless the monitor is fully live (not paused and not suspended).
    private var isLive: Bool { !isPaused && !isSuspendedForOperation }

    // Per-repo debounce: cancels and reschedules on every new event so only
    // the final event in a burst actually triggers a git status refresh.
    @MainActor private var debounceTasks: [String: Task<Void, Never>] = [:]
    private let debounceDelay: Duration = .seconds(2)

    /// Start monitoring multiple repositories at once
    func startMonitoringMultiple(repoURLs: [URL], onChange: @escaping (URL) -> Void) {
        self.callback = onChange

        // Stop any existing monitoring
        stopMonitoring()

        guard !repoURLs.isEmpty else { return }

        // Create set of paths for quick lookup
        let monitoredPaths = Set(repoURLs.map { $0.path })

        debugLog("[DEBUG] Starting monitoring for \(repoURLs.count) repositories")

        // Create event stream for all repository paths with 1s latency to coalesce rapid changes
        let eventStream = FolderContentMonitor.makeStream(
            paths: Array(monitoredPaths),
            latency: 1.0
        )

        // Start monitoring task
        monitoringTask = Task { [weak self] in
            for await event in eventStream {
                guard let self = self, !Task.isCancelled else { break }

                // Drop events while paused (app not in focus) or suspended (operation running)
                if !self.isLive {
                    continue
                }

                // Ignore git's own internal writes
                if event.eventPath.contains("/.git/") || event.filename.hasPrefix(".git/") {
                    continue
                }

                // Find which repo this event belongs to and debounce it
                for monitoredPath in monitoredPaths {
                    if event.eventPath.hasPrefix(monitoredPath) {
                        let repoURL = URL(fileURLWithPath: monitoredPath)
                        await MainActor.run {
                            self.scheduleDebounced(for: repoURL)
                        }
                        break
                    }
                }
            }
            debugLog("[DEBUG] Monitoring task completed")
        }

        debugLog("[DEBUG] Started monitoring \(repoURLs.count) repositories")
    }

    /// Cancel any pending debounce for this URL and schedule a fresh one.
    /// Only the last event in a burst fires the callback after `debounceDelay`.
    @MainActor
    private func scheduleDebounced(for repoURL: URL) {
        let key = repoURL.path
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounceDelay ?? .seconds(2))
            } catch {
                return // cancelled — a newer event is already queued
            }
            guard let self else { return }
            self.debounceTasks.removeValue(forKey: key)
            // A pause/suspension may have begun during the debounce window (e.g. the user
            // kicked off an operation); don't deliver a now-unwanted refresh.
            guard self.isLive else { return }
            self.callback?(repoURL)
        }
    }

    func pause() {
        isPaused = true
        debugLog("[DEBUG] FSEvents monitoring paused (app inactive)")
    }

    func resume() {
        isPaused = false
        debugLog("[DEBUG] FSEvents monitoring resumed (app active)")
    }

    /// Suspend event delivery while git operations run. Independent of `pause()`, so the app /
    /// tab focus state is preserved and honoured when the operation finishes. Pending debounces
    /// are cancelled so nothing fires mid-operation.
    @MainActor
    func suspendForOperation() {
        guard !isSuspendedForOperation else { return }
        isSuspendedForOperation = true
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        debugLog("[DEBUG] FSEvents monitoring suspended (operation in progress)")
    }

    /// Re-enable delivery after operations finish. Delivery only actually resumes if the monitor
    /// isn't also paused for app/tab focus.
    func resumeAfterOperation() {
        isSuspendedForOperation = false
        debugLog("[DEBUG] FSEvents monitoring resumed (operations finished)")
    }

    /// Stop monitoring all repositories and cancel any pending debounce tasks
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        Task { @MainActor [weak self] in
            self?.debounceTasks.values.forEach { $0.cancel() }
            self?.debounceTasks.removeAll()
        }
        debugLog("[DEBUG] Stopped monitoring repositories")
    }

    deinit {
        monitoringTask?.cancel()
    }
}
