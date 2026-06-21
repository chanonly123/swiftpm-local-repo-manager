import SwiftUI
import AppKit

private struct FileEntry: Identifiable {
    let id: String
    let status: String
    let path: String
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

private struct DiffLine: Identifiable {
    let id: Int
    let text: String
    let kind: Kind
    enum Kind { case added, removed, hunk, meta, context }
}

struct DiffWindowView: View {
    let repo: GitRepo

    @State private var files: [FileEntry] = []
    @State private var selectedPath: String?
    @State private var diffLines: [DiffLine] = []
    @State private var loadingFiles = true
    @State private var loadingDiff = false
    @State private var tooLarge = false

    private let git = GitService()
    private let sizeLimit = 100_000

    var body: some View {
        HSplitView {
            fileListPanel
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            diffPanel
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        .frame(minWidth: 700, minHeight: 450)
        .task { await loadFiles() }
        .onChange(of: selectedPath) { _, path in
            guard let path, let entry = files.first(where: { $0.id == path }) else { return }
            Task { await loadDiff(entry: entry) }
        }
    }

    // MARK: - File list

    private var fileListPanel: some View {
        VStack(spacing: 0) {
            Text("CHANGED FILES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            if loadingFiles {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                Text("No changes")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPath) {
                    ForEach(files) { file in
                        fileRow(file).tag(file.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Text(badge(entry.status))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(badgeColor(entry.status))
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(entry.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .help(entry.path)
        }
    }

    // MARK: - Diff panel

    private var diffPanel: some View {
        VStack(spacing: 0) {
            Text(selectedPath ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            diffContent
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedPath == nil {
            Text("Select a file to view changes")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tooLarge {
            Text("Diff too large to display")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diffLines.isEmpty {
            Text("No diff available")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffTextView(lines: diffLines)
        }
    }

    // MARK: - Data loading

    private func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let raw = try await git.getChangedFiles(at: repo.url)
            files = raw.map { FileEntry(id: $0.path, status: $0.status, path: $0.path) }
            if let first = files.first {
                selectedPath = first.id
            }
        } catch {
            print("[ERROR] DiffWindowView loadFiles: \(error)")
        }
    }

    private func loadDiff(entry: FileEntry) async {
        loadingDiff = true
        tooLarge = false
        diffLines = []
        defer { loadingDiff = false }
        do {
            let raw = try await entry.status.hasPrefix("??")
                ? git.getDiffUntracked(at: repo.url, filePath: entry.path)
                : git.getDiff(at: repo.url, filePath: entry.path)
            guard raw.count <= sizeLimit else { tooLarge = true; return }
            diffLines = parseDiff(raw)
        } catch {
            print("[ERROR] DiffWindowView loadDiff: \(error)")
        }
    }

    private func parseDiff(_ text: String) -> [DiffLine] {
        text.components(separatedBy: .newlines)
            .enumerated()
            .compactMap { i, line -> DiffLine? in
                if line.hasPrefix("diff --git") || line.hasPrefix("index ") { return nil }
                let kind: DiffLine.Kind
                if line.hasPrefix("+++") || line.hasPrefix("---") { kind = .meta }
                else if line.hasPrefix("+") { kind = .added }
                else if line.hasPrefix("-") { kind = .removed }
                else if line.hasPrefix("@@") { kind = .hunk }
                else { kind = .context }
                return DiffLine(id: i, text: line, kind: kind)
            }
    }

    // MARK: - Status badge helpers

    private func badge(_ xy: String) -> String {
        if xy == "??" { return "+" }
        if xy.contains("U") || (xy.first == "A" && xy.last == "A") { return "!" }
        if xy.hasPrefix("R") { return "R" }
        if xy.hasPrefix("A") || xy.hasSuffix("A") { return "A" }
        if xy.hasPrefix("D") || xy.hasSuffix("D") { return "D" }
        return "M"
    }

    private func badgeColor(_ xy: String) -> Color {
        switch badge(xy) {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "!": return .gray
        case "+": return .green
        default: return .orange
        }
    }
}

// MARK: - NSTextView wrapper for multi-line selection

private struct DiffTextView: NSViewRepresentable {
    let lines: [DiffLine]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let attrString = NSMutableAttributedString()
        for line in lines {
            let (fg, bg) = nsColors(line.kind)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: fg,
                .backgroundColor: bg
            ]
            attrString.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(attrString)
    }

    private func nsColors(_ kind: DiffLine.Kind) -> (NSColor, NSColor) {
        switch kind {
        case .added:   return (.labelColor, NSColor.systemGreen.withAlphaComponent(0.15))
        case .removed: return (.labelColor, NSColor.systemRed.withAlphaComponent(0.15))
        case .hunk:    return (.systemBlue, NSColor.systemBlue.withAlphaComponent(0.06))
        case .meta:    return (.secondaryLabelColor, .clear)
        case .context: return (.labelColor, .clear)
        }
    }
}
