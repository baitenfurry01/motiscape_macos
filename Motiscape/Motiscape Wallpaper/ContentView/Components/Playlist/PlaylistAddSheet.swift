import SwiftUI
import UniformTypeIdentifiers

struct PlaylistAddSheet: View {
    @Bindable var contentViewModel: ContentViewModel
    @ObservedObject var manager: PlaylistManager
    let screen: Int
    let onAdded: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = PlaylistSelection()
    @State private var search = ""
    @State private var filter = PlaylistLibraryFilter.all
    @State private var drag: PlaylistDragState?

    private var existingIDs: Set<String> {
        Set(manager.current(on: screen).items.map(\.wallpaperID))
    }

    private var availableIDs: Set<String> {
        Set(contentViewModel.wallpapers.lazy.filter { $0.presentationIsValid }.map(\.id))
    }

    private var visibleWallpapers: [WEWallpaper] {
        contentViewModel.wallpapers.filter { filter.includes($0, search: search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                library
                Divider()
                selectedOrder.frame(width: 260)
            }
            Divider()
            HStack {
                Text(L("已选择 %d 张", selection.ids.count))
                    .accessibilityIdentifier("playlistPicker.count")
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(L("关闭窗口，不添加壁纸"))
                Button(L("添加 %d 张壁纸", selection.ids.count), action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.ids.isEmpty)
                    .accessibilityIdentifier("playlistPicker.confirm")
                    .help(L("按已选顺序加入播放列表"))
            }
            .padding(20)
        }
        .frame(width: 920, height: 630)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { drag = nil }
        .onChange(of: availableIDs) { _, available in selection.retain(available: available) }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("添加到播放列表")).font(.title2.bold())
                Text(L("从已添加的壁纸中选择")).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("搜索壁纸"), text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("playlistPicker.search")
                }
                .padding(7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                Picker(L("壁纸类型"), selection: $filter) {
                    ForEach(PlaylistLibraryFilter.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
                .help(L("按类型筛选壁纸"))
            }
            if visibleWallpapers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                    Text(L(contentViewModel.wallpapers.isEmpty ? "暂无已添加的壁纸" : "没有匹配的壁纸"))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                        ForEach(visibleWallpapers) { wallpaper in
                            card(wallpaper)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func card(_ wallpaper: WEWallpaper) -> some View {
        let number = selection.number(for: wallpaper.id)
        let alreadyAdded = existingIDs.contains(wallpaper.id)
        let enabled = wallpaper.presentationIsValid
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) { selection.toggle(wallpaper.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                WorkshopImage(wallpaper: wallpaper)
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(number == nil ? Color.clear : .accentColor, lineWidth: 2)
                    }
                    .overlay(alignment: .topLeading) {
                        selectionBadge(number: number).padding(8)
                    }
                Text(wallpaper.project.title).lineLimit(1).foregroundStyle(.primary)
                Text(alreadyAdded ? L("已在播放列表中") :
                        (wallpaper.presentationIsValid ? wallpaper.kind.displayName : L("壁纸不可用")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(L(number == nil ? "选择这张壁纸" : "取消选择这张壁纸"))
        .accessibilityLabel(wallpaper.project.title)
        .accessibilityValue(number.map { L("第 %d 个已选壁纸", $0) } ??
                            L("未选择"))
        .accessibilityIdentifier("playlistPicker.wallpaper.\(wallpaper.id)")
    }

    private func selectionBadge(number: Int?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(number == nil ? Color.black.opacity(0.3) : Color.accentColor)
            RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
            if let number {
                Text("\(number)").font(.callout.bold().monospacedDigit()).minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var selectedOrder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("已选顺序")).font(.headline).padding(.horizontal, 16).padding(.top, 24)
            if selection.ids.isEmpty {
                Text(L("点击左侧壁纸进行选择"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(selection.ids, id: \.self) { id in
                            if let wallpaper = contentViewModel.wallpapersByID[id] {
                                selectedRow(wallpaper)
                                    .overlay(alignment: drag?.insertion?.after == true ? .bottom : .top) {
                                        if drag?.insertion?.targetID == id {
                                            PlaylistInsertionLine(axis: .vertical)
                                        }
                                    }
                                    .onDrag {
                                        let state = PlaylistDragState(sourceID: id)
                                        drag = state
                                        return state.provider()
                                    }
                                    .onDrop(of: [PlaylistDragState.contentType], delegate: PlaylistReorderDropDelegate(
                                        targetID: id, ids: selection.ids, axis: .vertical, extent: 50,
                                        drag: $drag,
                                        onMove: { source, insertion in
                                            selection.drop(source, relativeTo: insertion.targetID, after: insertion.after)
                                        }))
                                    .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: selection.ids)
                    .padding(.horizontal, 12)
                }
                .accessibilityIdentifier("playlistPicker.order")
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectedRow(_ wallpaper: WEWallpaper) -> some View {
        HStack(spacing: 8) {
            Text("\(selection.number(for: wallpaper.id) ?? 0)")
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            WorkshopImage(wallpaper: wallpaper)
                .frame(width: 46, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(wallpaper.project.title).lineLimit(2).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(L("拖动以调整顺序"))
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { selection.remove(wallpaper.id) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L("取消选择这张壁纸"))
            .accessibilityLabel(L("取消选择 %@", wallpaper.project.title))
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary).accessibilityHidden(true)
                .help(L("拖动以调整顺序"))
        }
        .frame(height: 40)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("向上移动")) { move(wallpaper.id, direction: -1) }
                .disabled(selection.ids.first == wallpaper.id)
                .help(L("将此壁纸提前一位"))
            Button(L("向下移动")) { move(wallpaper.id, direction: 1) }
                .disabled(selection.ids.last == wallpaper.id)
                .help(L("将此壁纸延后一位"))
        }
    }

    private func move(_ id: String, direction: Int) {
        guard let index = selection.ids.firstIndex(of: id) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            selection.move(from: IndexSet(integer: index), to: direction < 0 ? index - 1 : index + 2)
        }
    }

    private func confirm() {
        selection.retain(available: availableIDs)
        let wallpapers = selection.ids.compactMap { contentViewModel.wallpapersByID[$0] }
        guard !wallpapers.isEmpty else { return }
        onAdded(manager.add(wallpapers, to: screen))
        dismiss()
    }

}
