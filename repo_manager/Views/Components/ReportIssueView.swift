import SwiftUI

// Lightweight "Report Issue" dialog. Points the user at the logs so they can attach them
// when reporting a problem. The image is a placeholder for now.
struct ReportIssueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let issuesURL = URL(string: "https://github.com/chanonly123/swiftpm-local-repo-manager/issues")!

    var body: some View {
        VStack(spacing: 16) {
            Text("Report an Issue")
                .font(.title2.weight(.semibold))

            imagePlaceholder

            instructions

            actionButtons
        }
        .padding(24)
        .frame(width: 380)
    }

    // Dummy image placeholder — swap for real artwork/QR/contact later.
    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.12))
            Image("info_1")
                .resizable()
                .foregroundStyle(.secondary)
        }
        .frame(width: 260, height: 150)
    }

    private var instructions: some View {
        VStack(spacing: 6) {
            Text("Found a bug or something not working?")
                .font(.callout)
            Text("Create an issue on GitHub. Choose **“Open Current Log”** from the app menu to view today's log, then attach it so the issue can be diagnosed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)
    }

    private var actionButtons: some View {
        VStack {
            Button("Open Current Log") { FileLogger.shared.openCurrentLog() }
            Button(action: { openURL(issuesURL) }) {
                Label("Report on GitHub", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }
}
