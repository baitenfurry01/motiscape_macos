import SwiftUI

/// Native split views propose several intermediate widths while their inspector
/// slides. Commit one grid layout after that motion settles, rather than changing
/// the adaptive column count repeatedly in the middle of the slide.
struct WallpaperGrid<Content: View>: View {
    let minimumCardWidth: CGFloat
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableWidth: CGFloat = 0
    @State private var layoutWidth: CGFloat = 0

    init(minimumCardWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.minimumCardWidth = minimumCardWidth
        self.content = content()
    }

    private var columns: [GridItem] {
        guard layoutWidth > 0 else {
            return [GridItem(.adaptive(minimum: minimumCardWidth,
                                       maximum: minimumCardWidth * 2), spacing: 14)]
        }
        return Array(repeating: GridItem(.flexible(minimum: 0, maximum: minimumCardWidth * 2),
                                          spacing: 14),
                     count: WallpaperGridMetrics.columnCount(width: layoutWidth,
                                                             minimum: minimumCardWidth))
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            content
        }
        .frame(width: layoutWidth > 0 ? layoutWidth : nil, alignment: .leading)
        // The explicit column count belongs to the final width. It cannot cross
        // adaptive thresholds again as this one reflow animates.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: layoutWidth)
        // This outer envelope must accept a smaller proposal even while the
        // inner grid still holds its previous width; otherwise it feeds its old
        // minimum width back into the split view and prevents shrinking.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width.rounded(.down)
        } action: { width in
            availableWidth = width
        }
        .task(id: availableWidth) {
            guard availableWidth > 0, availableWidth != layoutWidth else { return }
            if layoutWidth > 0 {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            layoutWidth = availableWidth
        }
        // Inspector/toolbar transactions must not animate every intermediate
        // proposal. The local animation above owns only the settled reflow.
        .transaction { $0.animation = nil }
    }
}

enum WallpaperGridMetrics {
    static func columnCount(width: CGFloat, minimum: CGFloat) -> Int {
        max(1, Int((width + 14) / (minimum + 14)))
    }
}
