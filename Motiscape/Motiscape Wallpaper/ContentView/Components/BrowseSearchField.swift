import SwiftUI

enum BrowseToolbarMetrics {
    static let height: CGFloat = 28
    static let spacing: CGFloat = 8
    static let iconButtonWidth: CGFloat = 40
    static let viewMenuWidth: CGFloat = 88
    static let sortMenuWidth: CGFloat = 108
    static let actionsWidth = iconButtonWidth * 2 + viewMenuWidth + sortMenuWidth + spacing * 3
    static let wideButtonWidth = actionsWidth - iconButtonWidth - viewMenuWidth - spacing * 2
}

/// Shared search geometry across wallpaper browsing pages.
struct BrowseSearchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if let onClear, !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("清除搜索"))
                .accessibilityLabel(L("清除搜索"))
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 100, maxWidth: .infinity)
        .frame(height: BrowseToolbarMetrics.height)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
