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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                // Ensure UserDefaults are synchronized when app goes to background
                UserDefaults.standard.synchronize()
                print("[DEBUG] App moved to background, synchronized UserDefaults")
            }
        }
    }
}
