import SwiftUI

private struct MotiscapeGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let fallback: AnyShapeStyle
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content.background(fallback, in: shape)
        }
    }
}

/// Content stays flat; Liquid Glass is reserved for floating controls.
enum MotiscapeDesign {
    static let sectionDividerColor = Color(white: 0.8)
    static let contentPadding: CGFloat = 20
    static let cardRadius: CGFloat = 12
    static let minimumWindowWidth: CGFloat = 820
    static let minimumWindowHeight: CGFloat = 600
}

struct InspectorCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: MotiscapeDesign.cardRadius))
    }
}

struct InspectorSectionTitle: View {
    let title: LocalizedStringKey
    let systemImage: String?

    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

struct WallpaperCardSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selected: Bool
    let hovered: Bool

    func body(content: Content) -> some View {
        content
            .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: MotiscapeDesign.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: MotiscapeDesign.cardRadius)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovered ? 0.22 : 0.08),
                                  lineWidth: selected ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension View {
    func motiscapeGlass<S: Shape>(in shape: S, fallback: AnyShapeStyle, interactive: Bool = true) -> some View {
        modifier(MotiscapeGlassModifier(shape: shape, fallback: fallback, interactive: interactive))
    }
}
