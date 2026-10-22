import SwiftUI

struct ExplorerBottomBar: View {
    @Bindable var contentViewModel: ContentViewModel
    @Bindable var wallpaperViewModel: WallpaperViewModel
    var isActive = true
    @ObservedObject private var manager: PlaylistManager

    init(contentViewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel,
         isActive: Bool = true, manager: PlaylistManager = .shared) {
        self.contentViewModel = contentViewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.isActive = isActive
        _manager = ObservedObject(wrappedValue: manager)
    }

    @AppStorage("PlaylistCollapsed") private var isCollapsed = false

    @State private var targetScreen = 0
    @State private var selectedItemID: String?
    @State private var isOpenPresented = false
    @State private var isSavePresented = false
    @State private var isSettingsPresented = false
    @State private var isAddPresented = false
    @State private var isClearConfirming = false

    private var displays: [DisplayInfo] {
        wallpaperViewModel.connectedDisplays
    }

    private var itemCount: Int {
        manager.current(on: targetScreen).items.count
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            if !isCollapsed {
                PlaylistStrip(manager: manager,
                              wallpaperViewModel: wallpaperViewModel,
                              contentViewModel: contentViewModel,
                              screen: targetScreen,
                              selectedItemID: $selectedItemID,
                              isActive: isActive)
                footer
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
        .onAppear { manager.ensureScreen(targetScreen) }
        .onChange(of: targetScreen) { _ in
            manager.ensureScreen(targetScreen)
            selectedItemID = nil
        }
        .sheet(isPresented: $isOpenPresented) {
            PlaylistOpenSheet(manager: manager, screen: targetScreen, isPresented: $isOpenPresented)
        }
        .sheet(isPresented: $isSavePresented) {
            PlaylistSaveSheet(manager: manager, screen: targetScreen, isPresented: $isSavePresented)
        }
        .sheet(isPresented: $isSettingsPresented) {
            PlaylistSettingsSheet(manager: manager, screen: targetScreen, isPresented: $isSettingsPresented)
        }
        .sheet(isPresented: $isAddPresented) {
            PlaylistAddSheet(contentViewModel: contentViewModel, manager: manager, screen: targetScreen) { added in
                selectedItemID = manager.current(on: targetScreen).items.last?.id
            }
        }
        .confirmationDialog(L("清空播放列表"),
                            isPresented: $isClearConfirming) {
            Button(L("清空"), role: .destructive) {
                manager.clear(screen: targetScreen)
                selectedItemID = nil
            }
            .help(L("清空列表，不删除壁纸"))
            Button(L("取消"), role: .cancel) {}
                .help(L("保留当前列表"))
        } message: {
            Text(L("确定要清空当前播放列表中的全部壁纸吗？"))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isCollapsed.toggle()
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.body.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? L("展开播放列表") : L("收起播放列表"))

            Text(itemCount > 0 ? L("播放列表 (%d)", itemCount) : L("播放列表"))
                .font(.headline)
                .lineLimit(1)

            if displays.count > 1 {
                Picker("", selection: $targetScreen) {
                    ForEach(displays) { info in
                        Text(L("显示器 %d", info.index + 1) + " · " + info.name).tag(info.index)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .help(L("选择要管理播放列表的显示器"))
            }

            Spacer()

            Button {
                isOpenPresented = true
            } label: {
                Label(L("载入"), systemImage: "folder.fill")
            }
            .disabled(manager.saved.isEmpty)
            .help(L("载入已保存的播放列表"))

            Button {
                isSavePresented = true
            } label: {
                Label(L("保存"), systemImage: "square.and.arrow.down.fill")
            }
            .disabled(itemCount == 0)
            .help(L("保存当前列表，方便下次使用"))

            Button {
                isSettingsPresented = true
            } label: {
                Label(L("配置"), systemImage: "gearshape.2.fill")
            }
            .help(L("设置播放顺序和切换方式"))

            Button {
                isAddPresented = true
            } label: {
                Label(L("添加壁纸"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help(L("从壁纸库选择要加入的壁纸"))
            .accessibilityIdentifier("playlist.addWallpapers")
        }
        .labelStyle(.iconOnly)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                AppDelegate.shared.openImportFromFolderPanel()
            } label: {
                Label(L("导入壁纸"), systemImage: "arrow.up.bin.fill")
            }
            .help(L("导入本地壁纸、视频或 ZIP"))

            Spacer()

            Button {
                guard let id = selectedItemID else { return }
                manager.remove(itemID: id, from: targetScreen)
                selectedItemID = nil
            } label: {
                Label(L("移除壁纸"), systemImage: "minus")
                    .frame(width: 16, height: 16)
            }
            .disabled(selectedItemID == nil)
            .help(L("从列表移除选中项，不删除壁纸"))

            Button(role: .destructive) {
                isClearConfirming = true
            } label: {
                Label(L("清理"), systemImage: "trash")
                    .frame(width: 16, height: 16)
            }
            .disabled(itemCount == 0)
            .help(L("清空列表，不删除壁纸"))
        }
        .labelStyle(.iconOnly)
    }

}
