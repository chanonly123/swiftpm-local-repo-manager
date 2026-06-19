import Foundation
import SwiftUI

@Observable
class TabsManager {
    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var viewModels: [UUID: RepoManagerViewModel] = [:]

    private let userDefaults = UserDefaults.standard
    private let tabsKey = "workspaceTabs"
    private let selectedTabKey = "selectedTabID"

    init() {
        loadTabs()
    }

    var selectedTab: WorkspaceTab? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var currentViewModel: RepoManagerViewModel? {
        guard let id = selectedTabID else { return nil }
        return viewModels[id]
    }

    // MARK: - Tab Management

    func addTab() {
        let newTab = WorkspaceTab(name: "Untitled")
        tabs.append(newTab)
        selectedTabID = newTab.id
        viewModels[newTab.id] = RepoManagerViewModel()
        saveTabs()
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
        saveTabs()
    }

    func closeTab(_ id: UUID) {
        // Don't close if it's the only tab
        guard tabs.count > 1 else { return }

        // If closing the selected tab, select another one
        if selectedTabID == id {
            if let index = tabs.firstIndex(where: { $0.id == id }) {
                let nextIndex = index > 0 ? index - 1 : 1
                selectedTabID = tabs[nextIndex].id
            }
        }

        tabs.removeAll { $0.id == id }
        viewModels.removeValue(forKey: id)
        saveTabs()
    }

    func updateTabName(_ id: UUID, name: String) {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].name = name
            saveTabs()
        }
    }

    func updateTabDirectory(_ id: UUID, directoryURL: URL) {
        if let index = tabs.firstIndex(where: { $0.id == id }),
           let viewModel = viewModels[id] {
            // Get bookmark from ViewModel
            let bookmark = viewModel.createBookmark()
            tabs[index].directoryPath = directoryURL.path
            tabs[index].name = directoryURL.lastPathComponent
            tabs[index].bookmarkData = bookmark
            saveTabs()
        }
    }

    /// Returns the tab ID that already has this directory open, or nil if none.
    func existingTabID(for directoryURL: URL) -> UUID? {
        tabs.first { $0.directoryPath == directoryURL.path }?.id
    }

    // MARK: - Version Check

    var newVersion: String?
    var newVersionDesc: String?
    var newVersionAlert: Bool = false

    func getCurrentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func checkForNewVersion() {
        struct Release: Codable {
            let tag_name: String?
            let body: String?
        }

        func versionToInt(_ ver: String) -> Int? {
            Int(ver.replacingOccurrences(of: ".", with: ""))
        }

        Task { @MainActor in
            guard let current = getCurrentVersion() else { return }
            guard let url = URL(string: "https://api.github.com/repos/chanonly123/swiftpm-local-repo-manager/releases/latest") else { return }
            guard let result = try? await URLSession.shared.data(from: url),
                  let release = try? JSONDecoder().decode(Release.self, from: result.0),
                  let tagName = release.tag_name else { return }
            guard let newVer = versionToInt(tagName),
                  let currentVer = versionToInt(current),
                  newVer > currentVer else { return }
            newVersion = tagName
            newVersionDesc = release.body
            newVersionAlert = true
        }
    }

    // MARK: - Persistence

    private func loadTabs() {
        print("[DEBUG] Loading tabs from UserDefaults...")

        if let data = userDefaults.data(forKey: tabsKey),
           let decodedTabs = try? JSONDecoder().decode([WorkspaceTab].self, from: data),
           !decodedTabs.isEmpty {
            tabs = decodedTabs
            print("[DEBUG] Loaded \(tabs.count) tabs from UserDefaults")
            for tab in tabs {
                print("[DEBUG]   - Tab: \(tab.name), Directory: \(tab.directoryPath ?? "none"), Has Bookmark: \(tab.bookmarkData != nil)")
            }

            // Create ViewModels for each tab
            for tab in tabs {
                let viewModel = RepoManagerViewModel()
                // If tab has bookmark data, restore directory from it
                if let bookmarkData = tab.bookmarkData {
                    print("[DEBUG] Restoring directory for tab: \(tab.name)")
                    Task { @MainActor in
                        await viewModel.loadDirectory(from: bookmarkData)
                    }
                }
                viewModels[tab.id] = viewModel
            }

            // Load selected tab
            if let selectedIDString = userDefaults.string(forKey: selectedTabKey),
               let selectedUUID = UUID(uuidString: selectedIDString),
               tabs.contains(where: { $0.id == selectedUUID }) {
                selectedTabID = selectedUUID
                print("[DEBUG] Restored selected tab: \(selectedUUID)")
            } else {
                selectedTabID = tabs.first?.id
            }
        } else {
            print("[DEBUG] No saved tabs found, creating initial tab")
            // Create initial tab
            let initialTab = WorkspaceTab(name: "Untitled")
            tabs = [initialTab]
            selectedTabID = initialTab.id
            viewModels[initialTab.id] = RepoManagerViewModel()
            saveTabs()
        }
    }

    private func saveTabs() {
        if let encoded = try? JSONEncoder().encode(tabs) {
            userDefaults.set(encoded, forKey: tabsKey)
            print("[DEBUG] Saved \(tabs.count) tabs to UserDefaults")
            for tab in tabs {
                print("[DEBUG]   - Tab: \(tab.name), Directory: \(tab.directoryPath ?? "none"), Has Bookmark: \(tab.bookmarkData != nil)")
            }
        }
        if let selectedID = selectedTabID {
            userDefaults.set(selectedID.uuidString, forKey: selectedTabKey)
            print("[DEBUG] Saved selected tab: \(selectedID)")
        }
    }
}
