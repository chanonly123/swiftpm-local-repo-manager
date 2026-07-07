import SwiftUI

@main
struct repo_managerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Touch the logger at launch so the session file is created and old logs pruned
        // even before the first log line is emitted.
        _ = FileLogger.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove New Window command
            }
            CommandGroup(after: .appInfo) {
                Button("Show Logs in Finder") { FileLogger.shared.revealLogsInFinder() }
                Button("Open Current Log") { FileLogger.shared.openCurrentLog() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                debugLog("[DEBUG] App moved to background")
            }
        }
    }
}
