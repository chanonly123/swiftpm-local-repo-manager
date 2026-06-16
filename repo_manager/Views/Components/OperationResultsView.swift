import SwiftUI

struct OperationResultsView: View {
    let results: [OperationResult]
    let onClose: () -> Void

    var successCount: Int {
        results.filter { $0.success }.count
    }

    var failureCount: Int {
        results.filter { !$0.success }.count
    }

    var errors: [OperationResult] {
        results.filter { !$0.success }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Operation Errors")
                        .font(.headline)

                    Text("\(successCount) succeeded, \(failureCount) failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if errors.isEmpty {
                Spacer()
                Text("All operations succeeded")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(errors) { result in
                            resultRow(for: result)
                            Divider()
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(width: 400, height: 500)
    }

    @ViewBuilder
    private func resultRow(for result: OperationResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.repoName)
                        .font(.headline)

                    Spacer()

                    Text(result.operation.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
            }
        }
        .padding()
    }
}
