import AppKit
import SwiftUI

@MainActor
enum DiffWindowManager {
    private static var windows: [String: NSWindow] = [:]
    private static var observers: [String: [NSObjectProtocol]] = [:]

    // Last content size the user resized a diff window to. Persisted so the next
    // window that opens reuses it instead of the default.
    private static let sizeDefaultsKey = "DiffWindowContentSize"
    private static let defaultSize = NSSize(width: 900, height: 600)

    static func open(for vm: RepoViewModel) {
        let repo = vm.repo
        let key = repo.url.path

        if let existing = windows[key], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Reopening a previously closed window for this repo — drop stale observers.
        removeObservers(forKey: key)

        let controller = NSHostingController(rootView: DiffWindowView(vm: vm))
        let window = NSWindow(contentViewController: controller)
        window.title = title(for: repo)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(savedContentSize())
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[key] = window

        // Remember the size whenever the user resizes this window.
        let resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let size = (note.object as? NSWindow)?.contentView?.frame.size else { return }
                saveContentSize(size)
            }
        }
        // Forget the window when it closes (e.g. via the red close button, which
        // doesn't route through close(for:)).
        let closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                windows.removeValue(forKey: key)
                removeObservers(forKey: key)
            }
        }
        observers[key] = [resizeToken, closeToken]
    }

    // Window title: "Diff - <repo> (<branch>)", or just "Diff - <repo>" with no current branch.
    // Shared so DiffWindowView can keep the live NSWindow title in sync on branch changes.
    static func title(for repo: GitRepo) -> String {
        "Diff - \(repo.url.lastPathComponent)" + (repo.currentBranch.map { " (\($0))" } ?? "")
    }

    static func close(for vm: RepoViewModel) {
        let key = vm.repo.url.path
        windows[key]?.close()
        windows.removeValue(forKey: key)
        removeObservers(forKey: key)
    }

    private static func removeObservers(forKey key: String) {
        observers.removeValue(forKey: key)?.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    private static func savedContentSize() -> NSSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: sizeDefaultsKey + ".width")
        let height = defaults.double(forKey: sizeDefaultsKey + ".height")
        guard width > 0, height > 0 else { return defaultSize }
        return NSSize(width: width, height: height)
    }

    private static func saveContentSize(_ size: NSSize) {
        let defaults = UserDefaults.standard
        defaults.set(size.width, forKey: sizeDefaultsKey + ".width")
        defaults.set(size.height, forKey: sizeDefaultsKey + ".height")
    }
}
