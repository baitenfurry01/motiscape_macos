import SwiftUI

struct WallpaperExplorer: SubviewOfContentView {
    @Bindable var viewModel: ContentViewModel
    @Bindable var wallpaperViewModel: WallpaperViewModel
    let isActive: Bool
    let animatedPreviewMode: GSAnimatedPreviewPlayback

    init(
        contentViewModel viewModel: ContentViewModel,
        wallpaperViewModel: WallpaperViewModel,
        isActive: Bool = true,
        animatedPreviewMode: GSAnimatedPreviewPlayback = .hover
    ) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.isActive = isActive
        self.animatedPreviewMode = animatedPreviewMode
    }

    var body: some View {
        let page = viewModel.wallpaperPage
        let selectedDirectory = wallpaperViewModel.previewWallpaper.wallpaperDirectory
        let currentPage = min(max(viewModel.currentPage, 1), page.pageCount)
        ZStack(alignment: .bottom) {
            ScrollView {
                if page.items.isEmpty {
                    ContentUnavailableView {
                        Label(L("没有找到壁纸"), systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text(L("拖入视频或壁纸文件夹，或调整搜索和筛选条件。"))
                    } actions: {
                        Button(L("导入壁纸")) {
                            AppDelegate.shared.openImportFromFolderPanel()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L("重置筛选")) {
                            viewModel.searchText = ""
                            viewModel.reset()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 64)
                } else {
                    WallpaperGrid(minimumCardWidth: viewModel.explorerIconSize) {
                        ForEach(page.items) { wallpaper in
                            ExplorerItem(
                                wallpaper: wallpaper,
                                isSelected: wallpaper.wallpaperDirectory == selectedDirectory,
                                isActive: isActive,
                                animatedPreviewMode: animatedPreviewMode
                            )
                            .contextMenu {
                                ExplorerItemMenu(
                                    contentViewModel: viewModel,
                                    wallpaperViewModel: wallpaperViewModel,
                                    current: wallpaper
                                )
                                ExplorerGlobalMenu(
                                    contentViewModel: viewModel,
                                    wallpaperViewModel: wallpaperViewModel
                                )
                            }
                        }
                    }
                    .padding(2)
                }

                if page.pageCount > 1 {
                    Color.clear.frame(height: 58)
                }
            }
            // A new committed page gets a fresh native scroll position.
            // ScrollViewReader.scrollTo on a changing lazy grid can retain
            // an intermediate offset while its items are replaced.
            .id(page.effectivePage)

            if page.pageCount > 1 {
                PageNavigator(currentPage: currentPage, pageCount: page.pageCount) { page in
                    viewModel.currentPage = page
                }
                .padding(.bottom, 12)
            }
        }
    }
}
