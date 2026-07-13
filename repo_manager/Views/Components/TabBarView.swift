import SwiftUI

struct TabBarView: View {
    let tabs: [WorkspaceTab]
    let selectedTabID: UUID?
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    let onAddTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                TabItemView(
                    tab: tab,
                    isSelected: selectedTabID == tab.id,
                    onSelect: { onSelectTab(tab.id) },
                    onClose: { onCloseTab(tab.id) }
                )
            }

            addTabButton

            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // Add tab button
    private var addTabButton: some View {
        Button(action: onAddTab) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("New Tab")
        .padding(.horizontal, 8)
        .padding(.trailing, 4)
    }
}

struct TabItemView: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    // Full path with the last path component bold
    private var titleText: Text {
        let path = tab.directoryPath ?? tab.name
        let last = (path as NSString).lastPathComponent
        let prefix = String(path.dropLast(last.count))
        return Text(prefix).font(.system(size: 12))
            + Text(last).font(.system(size: 12, weight: .bold))
    }

    var body: some View {
        HStack(spacing: 4) {
            titleText
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 90, maxWidth: 220, alignment: .leading)
                .textSelection(.disabled)
                .help(tab.directoryPath ?? tab.name)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: isSelected ? 0.5 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.leading, 2)
    }
}

#Preview {
    VStack {
        TabBarView(
            tabs: [
                WorkspaceTab(name: "Project A", directoryPath: "/Users/test/project-a"),
                WorkspaceTab(name: "Project B", directoryPath: "/Users/test/project-b"),
                WorkspaceTab(name: "Untitled", directoryPath: nil)
            ],
            selectedTabID: WorkspaceTab(name: "Project A").id,
            onSelectTab: { _ in },
            onCloseTab: { _ in },
            onAddTab: {}
        )
        Spacer()
    }
    .frame(width: 600, height: 200)
}
