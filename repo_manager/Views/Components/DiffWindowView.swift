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
    @State private var checkedPaths: Set<String> = []
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var commitError: String?

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
        .onReceive(NotificationCenter.default.publisher(for: .repoFilesDidChange)) { note in
            guard (note.object as? URL) == repo.url else { return }
            Task {
                await loadFiles()
                if let path = selectedPath, let entry = files.first(where: { $0.id == path }) {
                    await loadDiff(entry: entry)
                }
            }
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
            Divider()
            commitPanel
        }
    }

    private var hasConflicts: Bool {
        files.contains { $0.status.contains("U") || ($0.status.first == "A" && $0.status.last == "A") || ($0.status.first == "D" && $0.status.last == "D") }
    }

    private var commitPanel: some View {
        VStack(spacing: 6) {
            if hasConflicts {
                Label("Resolve merge conflicts before committing", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CommitMessageEditor(text: $commitMessage)
                    .frame(height: 60)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if commitMessage.isEmpty {
                            Text("Commit message")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 5)
                                .allowsHitTesting(false)
                        }
                    }

                if let error = commitError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: { Task { await performCommit() } }) {
                    HStack(spacing: 4) {
                        if isCommitting { ProgressView().scaleEffect(0.6).frame(width: 12, height: 12) }
                        Text("Commit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommitting || checkedPaths.isEmpty)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { checkedPaths.contains(entry.id) },
                set: { checked in
                    if checked { checkedPaths.insert(entry.id) }
                    else { checkedPaths.remove(entry.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

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
        .contextMenu {
            Button(role: .destructive) {
                Task { await discardFile(entry) }
            } label: {
                Label("Discard Changes", systemImage: "arrow.uturn.backward")
            }
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

    private func performCommit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = files.filter { checkedPaths.contains($0.id) }.map { $0.path }
        guard !message.isEmpty, !paths.isEmpty else { return }
        isCommitting = true
        commitError = nil
        defer { isCommitting = false }
        do {
            try await git.stageFiles(at: repo.url, paths: paths)
            _ = try await git.commitStaged(at: repo.url, message: message)
            NotificationCenter.default.post(name: .repoDidCommit, object: repo.url)
            DiffWindowManager.close(for: repo)
        } catch {
            commitError = error.localizedDescription
        }
    }

    private func discardFile(_ entry: FileEntry) async {
        do {
            try await git.discardFileChanges(at: repo.url, filePath: entry.path, status: entry.status)
            if selectedPath == entry.id { selectedPath = nil; diffLines = [] }
            await loadFiles()
        } catch {
            print("[ERROR] DiffWindowView discardFile: \(error)")
        }
    }

    private func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let raw = try await git.getChangedFiles(at: repo.url)
            files = raw.map { FileEntry(id: $0.path, status: $0.status, path: $0.path) }
            checkedPaths = Set(files.map { $0.id })
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
        case "!": return .red
        case "+": return .green
        default: return .orange
        }
    }
}

extension Notification.Name {
    static let repoDidCommit = Notification.Name("repoDidCommit")
    static let repoFilesDidChange = Notification.Name("repoFilesDidChange")
}

// MARK: - Commit message editor with consistent text inset

private struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 4, height: 5)
        tv.textContainer?.lineFragmentPadding = 1
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        // Never touch the text storage while the user is actively typing — causes out-of-bounds crash
        guard !context.coordinator.isEditing else { return }
        if tv.string != text { tv.string = text }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var isEditing = false
        init(text: Binding<String>) { _text = text }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}

// MARK: - NSTextView wrapper for multi-line selection

private struct DiffTextView: NSViewRepresentable {
    let lines: [DiffLine]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
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
