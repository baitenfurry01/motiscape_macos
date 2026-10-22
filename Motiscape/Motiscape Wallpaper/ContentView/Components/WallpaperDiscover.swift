import SwiftUI

struct WallpaperDiscover: View {
    var body: some View {
        ScrollView {
            WorkingInProgress()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 50)
        }
    }
}

struct WallpaperDiscover_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            viewModel: .init(isStaging: true),
            wallpaperViewModel: .init(),
            navigationModel: MainNavigationModel(selection: .discover)
        )
            .environment(GlobalSettingsViewModel())
    }
}
