import SwiftUI

// MARK: - New Branch Sheet

struct NewBranchSheet: View {
    let repo: GitRepo
    let onCreate: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var changeHandling: ChangeHandling = .bring

    private enum ChangeHandling { case bring, stash }

    private var trimmedName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Create New Branch")
                    .font(.headline)
                Text(repo.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Source branch the new branch will be created from
            HStack(spacing: 5) {
                Image(systemName: "arrow.branch")
                    .font(.system(size: 11))
                Text("From")
                    .foregroundStyle(.secondary)
                Text(repo.currentBranch ?? "current branch")
                    .fontWeight(.medium)
            }
            .font(.system(size: 12))

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            if repo.hasUncommittedChanges {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This repo has uncommitted changes:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $changeHandling) {
                        Text("Bring changes to the new branch").tag(ChangeHandling.bring)
                        Text("Stash changes (new branch starts clean)").tag(ChangeHandling.stash)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName, changeHandling == .stash)
        dismiss()
    }
}
