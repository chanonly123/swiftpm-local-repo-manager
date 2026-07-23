import SwiftUI

// Top-right stack of dismissable error banners. Used by both ContentView (tab-wide) and the
// diff window (its repo). Banners persist until the user closes them.
struct BannerStackView: View {
    let banners: [BannerItem]
    let onDismiss: (UUID) -> Void
    var onDismissAll: (() -> Void)? = nil

    var body: some View {
        if !banners.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                dismissAllButton
                // Newest on top.
                ForEach(banners.reversed()) { banner in
                    bannerRow(banner)
                }
            }
            .padding(10)
            .frame(maxWidth: 380, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var dismissAllButton: some View {
        if banners.count > 1, let onDismissAll {
            Button(action: onDismissAll) {
                Text("Dismiss all (\(banners.count))")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func bannerRow(_ banner: BannerItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                if let repoName = banner.repoName {
                    Text(repoName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(banner.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
            Spacer(minLength: 4)
            Button(action: { onDismiss(banner.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
        .frame(maxWidth: 360, alignment: .leading)
    }
}
