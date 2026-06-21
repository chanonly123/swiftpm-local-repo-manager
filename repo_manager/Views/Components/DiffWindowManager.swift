import AppKit
import SwiftUI

@MainActor
enum DiffWindowManager {
    private static var windows: [String: NSWindow] = [:]

    static func open(for repo: GitRepo) {
        let key = repo.url.path

        if let existing = windows[key], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: DiffWindowView(repo: repo))
        let window = NSWindow(contentViewController: controller)
        window.title = "Diff - \(repo.url.lastPathComponent)"
        window.setContentSize(NSSize(width: 900, height: 600))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[key] = window
    }
}
