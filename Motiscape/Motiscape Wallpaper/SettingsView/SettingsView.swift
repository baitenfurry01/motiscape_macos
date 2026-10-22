import Cocoa
import SwiftUI

protocol SettingsPage: View {
    var viewModel: GlobalSettingsViewModel { get set }

    init(globalSettings: GlobalSettingsViewModel)
}

struct SettingsView: View {
    @Environment(GlobalSettingsViewModel.self) var viewModel
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject private var localization = MotiscapeLocalization.shared

    // Compares against an in-memory snapshot of the last-saved settings instead
    // of decoding GlobalSettings JSON from UserDefaults on every footer render.
    private var hasUnsavedChanges: Bool {
        viewModel.settings != viewModel.savedSettings || viewModel.isResetAllPending
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.selection != 4 {
                settingsNavigation
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                Divider()
            }
            Group {
                if viewModel.selection == 4 {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                viewModel.selection = 1
                            } label: {
                                Label(L("返回"), systemImage: "chevron.left")
                            }
                            .accessibilityIdentifier("settings.about.back")
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        AboutUsView()
                    }
                } else {
                    settingsPage
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 620)
        .environment(\.locale, localization.locale)
        .onAppear {
            if viewModel.selection == 3 && !plugins.hasWallpaperAgent { viewModel.selection = 1 }
        }
        .onChange(of: plugins.hasWallpaperAgent) { _, installed in
            if !installed && viewModel.selection == 3 { viewModel.selection = 1 }
        }
    }

    private var settingsNavigation: some View {
        let tabs: [(id: Int, title: String)] = [(1, "通用"), (0, "性能"), (2, "插件")]
            + (plugins.hasWallpaperAgent ? [(3, "屏保与锁屏")] : [])
        return HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 20)
                        .opacity(viewModel.selection == tab.id || viewModel.selection == tabs[index - 1].id ? 0 : 1)
                        .accessibilityHidden(true)
                }
                Button {
                    viewModel.selection = tab.id
                } label: {
                    Text(L(tab.title))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .frame(minWidth: 76)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(viewModel.selection == tab.id ? Color.primary.opacity(0.10) : Color.clear,
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selection == tab.id ? .isSelected : [])
                .accessibilityIdentifier("settings.tab.\(tab.id)")
            }
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .shadow(color: .black.opacity(0.07), radius: 16, y: 4)
    }

    @ViewBuilder private var settingsPage: some View {
        switch viewModel.selection {
        case 0: PerformancePage(globalSettings: viewModel)
        case 2: PluginsPage(globalSettings: viewModel)
        case 3 where plugins.hasWallpaperAgent: ScreenSaverPage(globalSettings: viewModel)
        default: GeneralPage(globalSettings: viewModel)
        }
    }

    private var footer: some View {
        HStack {
            if hasUnsavedChanges {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.yellow)
                Text("已修改")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                AppDelegate.shared.closeSettingsWindow(commit: false)
            } label: {
                Text("取消").frame(width: 50)
            }
            .keyboardShortcut(.cancelAction)
            Button {
                AppDelegate.shared.closeSettingsWindow(commit: true)
            } label: {
                Text("好").frame(width: 50)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.settings.httpProxy?.enabled == true && viewModel.settings.httpProxy?.isValid != true)
        }
        .padding(20)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environment({ () -> GlobalSettingsViewModel in
                let viewModel = GlobalSettingsViewModel()
                viewModel.selection = 2
                return viewModel
            }())
            .frame(width: 780, height: 620)
    }
}
