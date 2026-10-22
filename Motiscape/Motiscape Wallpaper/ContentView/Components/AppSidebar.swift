import SwiftUI

/// Native sidebar selection retains the same navigation model used by menus
/// and Workshop deep links, so every entry point reaches the same destination.
struct AppSidebar: View {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject var navigationModel: MainNavigationModel
    @Bindable var workshopViewModel: WorkshopViewModel

    private var selection: Binding<MainSection?> {
        Binding(get: { navigationModel.selection }, set: {
            if let section = $0 { navigationModel.selection = section }
        })
    }

    var body: some View {
        List(selection: selection) {
            Section(L("壁纸")) {
                row(.installed)
                if plugins.hasSteamAgent {
                    row(.discover)
                    row(.workshop)
                    row(.subscriptions)
                }
            }
            Section(L("管理")) {
                row(.downloads)
                    .badge(workshopViewModel.activeDownloadCount)
                    .tag(MainSection.downloads)
                row(.playlists)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Motiscape")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                AppDelegate.shared.openSettingsWindow()
            } label: {
                Label(L("设置"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(L("设置"))
        }
    }

    private func row(_ section: MainSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
            .padding(.vertical, 3)
            .accessibilityIdentifier("navigation.\(section.rawValue)")
    }
}
