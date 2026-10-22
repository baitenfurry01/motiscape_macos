import SwiftUI

struct PlaylistStrip: View {
    @ObservedObject var manager: PlaylistManager
    @Bindable var wallpaperViewModel: WallpaperViewModel
    @Bindable var contentViewModel: ContentViewModel
    let screen: Int
    @Binding var selectedItemID: String?
    var isActive = true
    @State private var drag: PlaylistDragState?
    @State private var dragTranslation: CGSize = .zero
    @Namespace private var reorderSpace
    private let cardExtent: CGFloat = 82

    private var items: [PlaylistItem] {
        manager.current(on: screen).items
    }

    private var libraryByID: [String: WEWallpaper] {
        contentViewModel.wallpapersByID
    }

    private var playingID: String? {
        wallpaperViewModel.currentByScreen[screen]?.id
    }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            PlaylistThumb(
                                item: item,
                                index: idx,
                                wallpaper: libraryByID[item.wallpaperID],
                                isPlaying: playingID == item.wallpaperID,
                                isSelected: selectedItemID == item.id,
                                isActive: isActive,
                                onTap: { tap(item) },
                                onRemove: { manager.remove(itemID: item.id, from: screen) }
                            )
                            .padding(.horizontal, 5)
                            .contentShape(Rectangle())
                            .anchorPreference(key: PlaylistCardFramesKey.self, value: .bounds) { [item.id: $0] }
                            .opacity(drag?.sourceID == item.id ? 0.25 : 1)
                            .highPriorityGesture(reorderGesture(for: item.id))

                        }
                    }
                    .coordinateSpace(name: reorderSpace)
                    .animation(.easeInOut(duration: 0.22), value: items.map(\.id))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .overlayPreferenceValue(PlaylistCardFramesKey.self) { frames in
                    GeometryReader { geometry in
                        if let drag, let anchor = frames[drag.sourceID],
                           let index = items.firstIndex(where: { $0.id == drag.sourceID }) {
                            let item = items[index]
                            let frame = geometry[anchor]
                            PlaylistThumb(
                                item: item, index: index, wallpaper: libraryByID[item.wallpaperID],
                                isPlaying: playingID == item.wallpaperID,
                                isSelected: selectedItemID == item.id, isActive: isActive,
                                onTap: {}, onRemove: {}
                            )
                            .padding(.horizontal, 5)
                            .frame(width: frame.width, height: frame.height)
                            .opacity(0.92)
                            .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                            .position(x: frame.midX + dragTranslation.width,
                                      y: frame.midY + dragTranslation.height)
                            .transaction { $0.animation = nil }
                        }
                        if let insertion = drag?.insertion, let anchor = frames[insertion.targetID] {
                            let frame = geometry[anchor]
                            PlaylistInsertionLine(axis: .horizontal, thickness: 1)
                                .frame(height: max(0, frame.height - 4))
                                .position(x: insertion.after ? frame.maxX : frame.minX, y: frame.midY)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: screen) { _, _ in drag = nil }
        .onDisappear { drag = nil }
        .frame(height: 124)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // Keep reordering inside the strip. Native item-provider drag sessions can
    // lose the card's mouse sequence to its tap/thumbnail interactions on macOS.
    private func reorderGesture(for sourceID: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(reorderSpace))
            .onChanged { value in
                if drag?.sourceID != sourceID { drag = PlaylistDragState(sourceID: sourceID) }
                dragTranslation = value.translation
                drag?.insertion = insertion(at: value.location, sourceID: sourceID)
            }
            .onEnded { value in
                let insertion = insertion(at: value.location, sourceID: sourceID)
                drag = nil
                let ids = items.map(\.id)
                guard let insertion, let from = ids.firstIndex(of: sourceID),
                      let to = insertion.destination(in: ids, sourceID: sourceID) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    manager.move(from: from, to: to, on: screen)
                }
            }
    }

    private func insertion(at location: CGPoint, sourceID: String) -> PlaylistInsertion? {
        guard (0...124).contains(location.y) else { return nil }
        return PlaylistInsertion.horizontal(at: location.x, itemExtent: cardExtent,
                                            ids: items.map(\.id), sourceID: sourceID)
    }

    private func tap(_ item: PlaylistItem) {
        selectedItemID = item.id
        guard let wallpaper = libraryByID[item.wallpaperID], wallpaper.presentationIsValid else { return }
        // Via requestApply so an unconfirmed web wallpaper gets the trust sheet
        // on every screen, not just the main one.
        if let key = DisplayRegistry.shared.key(forScreenIndex: screen) {
            wallpaperViewModel.requestApply(wallpaper, to: key)
        }
        manager.kickRotator(on: screen, selectedItemID: item.id)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(L("尚未添加壁纸，右键壁纸选择“加入播放列表”，或点击右上角“添加壁纸”。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }
}

private struct PlaylistCardFramesKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PlaylistThumb: View {
    let item: PlaylistItem
    let index: Int
    let wallpaper: WEWallpaper?
    let isPlaying: Bool
    let isSelected: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @Environment(GlobalSettingsViewModel.self) private var globalSettingsViewModel
    @State private var hovering = false

    private let side: CGFloat = 72

    var body: some View {
        @Bindable var globalSettingsViewModel = globalSettingsViewModel
        VStack(spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                thumbnail
                    .allowsHitTesting(false)
                    .frame(width: side, height: side)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: borderWidth)
                    )
                    .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: hovering ? 6 : 0, y: 2)

                if isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(5)
                }
            }
            .help(L("点击播放，拖动调整顺序"))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.65))
                            .symbolRenderingMode(.palette)
                    }
                    .buttonStyle(.plain)
                    .help(L("从列表移除，不删除壁纸"))
                    .padding(4)
                }
            }

            Text(wallpaper?.project.title ?? item.wallpaperID)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(hovering || isPlaying ? .primary : .secondary)
                .frame(width: side)
                .help(wallpaper?.project.title ?? item.wallpaperID)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }

    private var borderColor: Color {
        if isPlaying { return .accentColor }
        if isSelected { return .accentColor.opacity(0.6) }
        return hovering ? .accentColor.opacity(0.3) : .clear
    }

    private var borderWidth: CGFloat {
        if isPlaying { return 2 }
        if isSelected { return 2 }
        return hovering ? 1 : 0
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let wallpaper, !wallpaper.project.preview.isEmpty {
            WorkshopImage(
                wallpaper: wallpaper, contentMode: .fit,
                isAnimating: isActive && (hovering || isPlaying ||
                    globalSettingsViewModel.animatedPreviewPlaybackMode == .visible),
                isLoadingEnabled: isActive
            )
                .aspectRatio(1.0, contentMode: .fit)
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
