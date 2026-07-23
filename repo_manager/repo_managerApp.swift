import SwiftUI

@main
struct repo_managerApp: App {
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
    }
}
