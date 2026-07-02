import SwiftUI

@main
struct repo_managerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove New Window command
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                debugLog("[DEBUG] App moved to background")
            }
        }
    }
}
