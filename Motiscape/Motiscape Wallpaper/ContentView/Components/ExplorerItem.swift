import SwiftUI

struct ExplorerItem: View {
    let wallpaper: WEWallpaper
    // Selection is passed in as a plain value so the cell no longer observes the
    // shared view models. Hovering or selecting one cell then cannot force every
    // other cell in the grid to rebuild.
    let isSelected: Bool
    let isActive: Bool
    let animatedPreviewMode: GSAnimatedPreviewPlayback

    @State private var hovering = false

    var body: some View {
        Button {
            AppDelegate.shared.workshopViewModel.openInstalledWallpaper(wallpaper)
        } label: {
        VStack(alignment: .leading, spacing: 0) {
            WorkshopImage(
                wallpaper: wallpaper,
                contentMode: .fill,
                     // Only the hovered cell or the active wallpaper animates its
                     // preview; every other cell stays a cheap static thumbnail.
                isAnimating: isActive && (hovering || isSelected ||
                    animatedPreviewMode == .visible),
                isLoadingEnabled: isActive,
                preloadsWhenInactive: false
            )
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipped()

            VStack(alignment: .leading, spacing: 5) {
                Text(wallpaper.project.title)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(wallpaper.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topLeading) {
            if wallpaper.isPreset {
                VStack(alignment: .leading, spacing: 3) {
                    Label("预设", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.purple, in: RoundedRectangle(cornerRadius: 4))
                    if let status = wallpaper.presetStatusDescription {
                        Label(status, systemImage: "exclamationmark.triangle.fill")
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
        }
        .buttonStyle(.plain)
        .modifier(WallpaperCardSurface(selected: isSelected, hovered: hovering))
        .accessibilityLabel(wallpaper.project.title)
        .accessibilityValue(wallpaper.kind.displayName)
        .help(wallpaper.project.title)
        .onHover { hovering = $0 }
    }
}
