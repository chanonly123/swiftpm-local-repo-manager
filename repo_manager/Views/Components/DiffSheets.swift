import SwiftUI

// MARK: - Move-branch-to-commit (reset) sheet

struct MoveBranchSheet: View {
    let commit: CommitEntry
    let currentBranch: String?
    let onConfirm: (Bool) -> Void   // hard

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ResetMode = .soft

    private enum ResetMode { case soft, hard }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text(commit.subject)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(.secondary)

            modePicker

            if mode == .hard {
                Label("Permanently discards uncommitted changes and any commits after this one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            actionButtons
        }
        .padding(20)
        .frame(width: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Move Branch to Commit")
                .font(.headline)
            Text("\(currentBranch ?? "current branch")  →  \(commit.shortHash)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("Soft — keep changes staged").tag(ResetMode.soft)
            Text("Hard — discard all changes").tag(ResetMode.hard)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode == .hard ? "Hard Reset" : "Soft Reset") {
                onConfirm(mode == .hard)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Squash commits sheet

struct SquashSheet: View {
    let count: Int
    let defaultMessage: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text("Commit message")
                .font(.caption)
                .foregroundStyle(.secondary)

            messageEditor

            actionButtons
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { message = defaultMessage }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Squash \(count) Commits")
                .font(.headline)
            Text("Combine the top \(count) commits into a single commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var messageEditor: some View {
        CommitMessageEditor(text: $message)
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Squash") {
                onConfirm(message)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
