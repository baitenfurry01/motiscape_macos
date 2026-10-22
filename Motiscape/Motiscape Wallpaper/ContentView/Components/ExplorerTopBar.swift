import SwiftUI

struct ExplorerTopBar: SubviewOfContentView {
    @Bindable var viewModel: ContentViewModel
    
    @Environment(GlobalSettingsViewModel.self) var globalSettingsViewModel
    
    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        @Bindable var globalSettingsViewModel = globalSettingsViewModel
        HStack(spacing: BrowseToolbarMetrics.spacing) {
            BrowseSearchField(prompt: L("搜索资料库"), text: $viewModel.searchText)
                .accessibilityIdentifier("library.search")
            HStack(spacing: BrowseToolbarMetrics.spacing) {
                Button {
                    viewModel.refresh()
                } label: {
                    Group {
                        if viewModel.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .disabled(viewModel.isRefreshing)
                .help(L("刷新壁纸库"))
                .accessibilityLabel(Self.refreshLabel(isRefreshing: viewModel.isRefreshing))
                .accessibilityIdentifier("library.refresh")
                .frame(width: BrowseToolbarMetrics.iconButtonWidth)
                WallpaperGridViewMenu(viewModel: viewModel, showsPageSize: true)
                    .frame(width: BrowseToolbarMetrics.viewMenuWidth)
                Button {
                    if viewModel.sortingSequence == .decrease {
                        viewModel.sortingSequence = .increase
                    } else {
                        viewModel.sortingSequence = .decrease
                    }
                } label: {
                    Image(systemName: viewModel.sortingSequence == .increase ?
                          "arrow.up" : "arrow.down")
                        .frame(width: 16, height: 16)
                }
                .help(L("切换排序方向"))
                .accessibilityLabel(L("切换排序方向"))
                .frame(width: BrowseToolbarMetrics.iconButtonWidth)
                Picker("排序", selection: $viewModel.sortingBy) {
                    ForEach(WEWallpaperSortingMethod.allCases) { method in
                        Text(LocalizedStringKey(method.rawValue)).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: BrowseToolbarMetrics.sortMenuWidth)
            }
            .frame(width: BrowseToolbarMetrics.actionsWidth)
        }
        .controlSize(.large)
        .frame(height: BrowseToolbarMetrics.height)
    }

    static func refreshLabel(isRefreshing: Bool) -> String {
        L(isRefreshing ? "正在刷新壁纸库…" : "刷新壁纸库")
    }
}
