import SwiftUI

struct ExplorerGlobalMenu: SubviewOfContentView {
    
    @Bindable var viewModel: ContentViewModel
    @Bindable var wallpaperViewModel: WallpaperViewModel
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
    }
    
    var body: some View {
        Section {
            WallpaperGridViewMenu(viewModel: viewModel, showsPageSize: true)
        }
        .labelStyle(.titleAndIcon)
    }
}
