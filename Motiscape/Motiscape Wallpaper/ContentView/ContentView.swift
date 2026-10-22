import SwiftUI

protocol SubviewOfContentView: View {
    var viewModel: ContentViewModel { get set }
}

enum MainSection: String, CaseIterable, Hashable {
    case installed
    case discover
    case workshop
    case subscriptions
    case downloads
    case playlists

    var title: String {
        switch self {
        case .installed: return L("资料库")
        case .discover: return L("发现")
        case .workshop: return L("创意工坊")
        case .subscriptions: return L("已订阅")
        case .downloads: return L("下载")
        case .playlists: return L("播放列表")
        }
    }

    var systemImage: String {
        switch self {
        case .installed: return "square.grid.2x2"
        case .discover: return "sparkles"
        case .workshop: return "globe"
        case .subscriptions: return "checkmark.circle"
        case .downloads: return "arrow.down.circle"
        case .playlists: return "rectangle.stack"
        }
    }

    var requiresSteamAgent: Bool { self == .discover || self == .workshop || self == .subscriptions }

    var supportsInspector: Bool { self != .downloads && self != .playlists }
    var supportsFilters: Bool { self == .installed || self == .workshop || self == .subscriptions }
}

final class MainNavigationModel: ObservableObject {
    @Published var selection: MainSection {
        didSet {
            if selection.requiresSteamAgent && !PluginManager.shared.hasSteamAgent { selection = .installed; return }
            #if DEBUG
            if oldValue != selection, AppIntegrationFixture.isLibraryUI {
                AppIntegrationFixture.record("library-ui-navigation", fields: ["from": oldValue.rawValue,
                    "to": selection.rawValue, "caller": Thread.callStackSymbols.prefix(10).joined(separator: "\n")])
            }
            #endif
        }
    }

    init(selection: MainSection = .installed) {
        self.selection = selection.requiresSteamAgent && !PluginManager.shared.hasSteamAgent ? .installed : selection
    }
}

struct ContentView: View {
    @Environment(GlobalSettingsViewModel.self) var globalSettingsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject private var localization = MotiscapeLocalization.shared

    @Bindable var viewModel: ContentViewModel
    @Bindable var wallpaperViewModel: WallpaperViewModel
    @Bindable var workshopViewModel: WorkshopViewModel
    @ObservedObject var navigationModel: MainNavigationModel
    @ObservedObject private var shortcutManager = WallpaperShortcutManager.shared
    @ObservedObject private var dynamicLockScreenManager = DynamicLockScreenManager.shared
    @ObservedObject private var screenSaverDynamicLockScreenManager = ScreenSaverDynamicLockScreenManager.shared
    @StateObject private var steamSetupViewModel = SteamSetupViewModel()
    @State private var loadedSections: Set<MainSection>
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorPresentation = InspectorPresentationState()
    @State private var isImportPresented = false
    @State private var isCompact = false
    @State private var toolbarShowsFilters: Bool

    init(
        viewModel: ContentViewModel,
        wallpaperViewModel: WallpaperViewModel,
        workshopViewModel: WorkshopViewModel = AppDelegate.shared.workshopViewModel,
        navigationModel: MainNavigationModel = AppDelegate.shared.navigationModel
    ) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
        self.workshopViewModel = workshopViewModel
        self.navigationModel = navigationModel
        _loadedSections = State(initialValue: [navigationModel.selection])
        _toolbarShowsFilters = State(initialValue: navigationModel.selection.supportsFilters)
    }

    var body: some View {
        @Bindable var globalSettingsViewModel = globalSettingsViewModel
        let interfaceActive = viewModel.isStaging && viewModel.isWindowVisible
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                AppSidebar(navigationModel: navigationModel, workshopViewModel: workshopViewModel)
                    .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 240)
            } detail: {
                sectionContent(interfaceActive: interfaceActive)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .navigationTitle(navigationModel.selection.title)
                    .toolbar { windowToolbar }
                    .inspector(isPresented: inspectorBinding) {
                        inspectorContent(interfaceActive: interfaceActive)
                            .inspectorColumnWidth(min: 300, ideal: 320, max: 400)
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .onAppear { updateLayout(width: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateLayout(width: width) }
            .onChange(of: columnVisibility) { _, visibility in
                if isCompact && visibility != .detailOnly {
                    inspectorPresentation.setAutomaticallyHidden(true)
                }
            }
        }
        .confirmationDialog("删除壁纸",
                            isPresented: $viewModel.isUnsubscribeConfirming) {
            if let wallpaper = viewModel.hoveredWallpaper {
                let url = wallpaper.wallpaperDirectory
                Button("立即删除", role: .destructive) {
                    WEWallpaper.invalidateSizeCache()
                    try? WallpaperLibrary.shared.delete(wallpaper)
                    wallpaperViewModel.removeWallpaper(at: url)
                    viewModel.hoveredWallpaper = nil
                    viewModel.refresh()
                }
                Button("移到废纸篓") {
                    WEWallpaper.invalidateSizeCache()
                    try? WallpaperLibrary.shared.trash(wallpaper)
                    wallpaperViewModel.removeWallpaper(at: url)
                    viewModel.hoveredWallpaper = nil
                    viewModel.refresh()
                }
            }
            Button("取消", role: .cancel) {
                viewModel.hoveredWallpaper = nil
            }
        } message: {
            Text(L("确定要删除“%@”吗？", viewModel.hoveredWallpaper?.project.title ?? L("该壁纸")))
        }
        .alert(isPresented: $viewModel.importAlertPresented, error: viewModel.importAlertError) { }
        .alert(item: $viewModel.screenSaverFeedback) { feedback in
            if feedback.action == .openFullDiskAccess {
                return Alert(
                    title: Text(feedback.title),
                    message: Text(feedback.message),
                    primaryButton: .default(Text("打开完全磁盘访问权限设置")) {
                        dynamicLockScreenManager.openFullDiskAccessSettings()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            return Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(isPresented: $dynamicLockScreenManager.isConfirmationPresented) {
            DynamicLockScreenConfirmationSheet(manager: dynamicLockScreenManager)
        }
        .sheet(isPresented: $screenSaverDynamicLockScreenManager.isConfirmationPresented) {
            ScreenSaverDynamicLockScreenConfirmationSheet(manager: screenSaverDynamicLockScreenManager)
        }
        .alert(
            "Steam 收藏",
            isPresented: Binding(
                get: { workshopViewModel.favoriteActionError != nil },
                set: { if !$0 { workshopViewModel.dismissFavoriteActionError() } }
            )
        ) {
            Button("确定", role: .cancel) {
                workshopViewModel.dismissFavoriteActionError()
            }
        } message: {
            Text(workshopViewModel.favoriteActionError ?? "")
        }
        .alert(
            "需要基础壁纸",
            isPresented: Binding(
                get: { workshopViewModel.presetDependencyPrompt != nil },
                set: { if !$0 { workshopViewModel.dismissPresetDependencyPrompt() } }
            ),
            presenting: workshopViewModel.presetDependencyPrompt
        ) { prompt in
            Button("一起下载") {
                workshopViewModel.confirmPresetDependencyDownload(prompt)
            }
            Button("暂不", role: .cancel) {
                workshopViewModel.dismissPresetDependencyPrompt()
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .sheet(isPresented: $globalSettingsViewModel.isFirstLaunch) {
            FirstLaunchView()
                .id(globalSettingsViewModel.welcomePresentationID)
                .environment(globalSettingsViewModel)
        }
        .sheet(item: $shortcutManager.recordingWallpaper, onDismiss: {
            shortcutManager.cancelRecording()
        }) { wallpaper in
            WallpaperShortcutRecorderSheet(
                wallpaper: wallpaper,
                manager: shortcutManager
            )
        }
        .sheet(item: $viewModel.pendingTrustRequest) { request in
            UnsafeWallpaper(request: request)
                .frame(width: 600, height: 300)
        }
        .sheet(isPresented: $viewModel.isSteamSetupPresented, onDismiss: {
            steamSetupViewModel.reset()
        }) {
            SteamSetupView(viewModel: steamSetupViewModel)
                .frame(width: 560, height: 640)
        }
        // Applied outside the sheets so the card also floats over an open sheet,
        // and after them so it is the topmost layer in the window.
        .overlay(alignment: .bottomTrailing) {
            VideoTranscodeOverlay()
                .allowsHitTesting(false)
        }
        .environment(\.locale, localization.locale)
        .environment(\.motiscapeContentActive, interfaceActive)
        .frame(minWidth: MotiscapeDesign.minimumWindowWidth, minHeight: MotiscapeDesign.minimumWindowHeight)
        .sheet(isPresented: $isImportPresented) {
            ImportWallpaperSheet(navigationModel: navigationModel,
                enqueueWorkshop: { try await workshopViewModel.enqueueImportedWorkshopItem($0) })
        }
        .sheet(isPresented: Binding(get: { viewModel.importSession.isPresented },
                                    set: { viewModel.importSession.isPresented = $0 })) {
            ImportReviewSheet(session: viewModel.importSession) {
                WEWallpaper.invalidateSizeCache()
                viewModel.refresh()
            }
        }
        .sheet(isPresented: Binding(get: { viewModel.importSession.isHistoryPresented },
                                   set: { viewModel.importSession.isHistoryPresented = $0 })) {
            ImportHistoryView(session: viewModel.importSession)
        }
        .onChange(of: plugins.hasSteamAgent) { _, enabled in
            guard !enabled else { return }
            if navigationModel.selection.requiresSteamAgent { navigationModel.selection = .installed }
            loadedSections = loadedSections.filter { !$0.requiresSteamAgent }
            viewModel.isSteamSetupPresented = false
            workshopViewModel.showCreatorProfile = false
        }
        .onChange(of: workshopViewModel.detailsPresentationRequest) { _, _ in
            withAnimation(chromeAnimation) {
                if isCompact { columnVisibility = .detailOnly }
                inspectorPresentation.show(supportsInspector: navigationModel.selection.supportsInspector)
            }
        }
        .onChange(of: navigationModel.selection) { _, section in
            viewModel.isFilterReveal = false
            withAnimation(chromeAnimation) {
                toolbarShowsFilters = section.supportsFilters
            }
            if viewModel.isStaging { loadedSections.insert(section) }
        }
        .task(id: viewModel.isStaging) {
            guard viewModel.isStaging else { return }
            loadedSections.insert(navigationModel.selection)
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: {
            inspectorPresentation.isPresented(supportsInspector: navigationModel.selection.supportsInspector)
        }, set: {
            inspectorPresentation.receiveSystemPresentation($0,
                supportsInspector: navigationModel.selection.supportsInspector)
        })
    }

    private func updateLayout(width: CGFloat) {
        let compact = width < 1100
        guard compact != isCompact else { return }
        isCompact = compact
        inspectorPresentation.setAutomaticallyHidden(compact)
        columnVisibility = compact ? .detailOnly : .all
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(id: "import", placement: .primaryAction) {
            importButton
        }
        // Keep native item identities stable. Hide the entire item, so AppKit
        // lays out its control and shared Liquid Glass background together.
        if #available(macOS 15.0, *) {
            ToolbarItem(id: "importHistory", placement: .primaryAction) {
                importHistoryButton
            }
            .hidden(!globalSettingsViewModel.settings.isDeveloperModeEnabled)
            ToolbarItem(id: "filters", placement: .primaryAction) {
                filterButton
            }
            .hidden(!toolbarShowsFilters)
        } else {
            if globalSettingsViewModel.settings.isDeveloperModeEnabled {
                ToolbarItem(id: "importHistory", placement: .primaryAction) {
                    importHistoryButton
                }
            }
            if toolbarShowsFilters {
                ToolbarItem(id: "filters", placement: .primaryAction) {
                    filterButton
                }
            }
        }
        ToolbarItem(id: "display", placement: .primaryAction) {
            DisplayPicker(wallpaperViewModel: wallpaperViewModel)
        }
        ToolbarItem(id: "downloads", placement: .primaryAction) {
            downloadsButton
        }
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            inspectorButton
        }
    }

    #if DEBUG
    // Capture the actual toolbar controls without snapshotting AppKit's
    // composited titlebar material. Used only by OnboardingCapture.swift.
    var onboardingToolbarCapture: some View {
        HStack(spacing: 24) {
            importButton
            filterButton
            DisplayPicker(wallpaperViewModel: wallpaperViewModel)
            downloadsButton
            inspectorButton
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
        .padding(24)
    }
    #endif

    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private var importButton: some View {
        Button {
            isImportPresented = true
        } label: {
            Label(L("导入壁纸"), systemImage: "plus")
        }
        .help(L("导入壁纸"))
        .accessibilityIdentifier("toolbar.import")
    }

    private var importHistoryButton: some View {
        Button { viewModel.importSession.showHistory() } label: {
            Label(L("导入历史与恢复"), systemImage: viewModel.importSession.historyError != nil || !viewModel.importSession.recoveryReport.issues.isEmpty
                || viewModel.importSession.automaticIndexError != nil || !(viewModel.importSession.automaticIndexReport?.scan.issues.isEmpty ?? true)
                || viewModel.importSession.zipWorkspaceError != nil || !viewModel.importSession.zipWorkspaces.items.isEmpty
                  ? "exclamationmark.arrow.triangle.2.circlepath" : "clock.arrow.circlepath")
        }
        .help(L("导入历史与恢复"))
        .accessibilityIdentifier("toolbar.importHistory")
    }

    private var filterButton: some View {
        Button {
            viewModel.isFilterReveal.toggle()
        } label: {
            Label(L("筛选"), systemImage: "line.3.horizontal.decrease")
        }
        .help(L("筛选"))
        .accessibilityIdentifier("toolbar.filters")
        .popover(isPresented: $viewModel.isFilterReveal) {
            filterContent
                .frame(width: 280, height: 480)
                .padding(12)
        }
    }

    private var downloadsButton: some View {
        Button {
            navigationModel.selection = .downloads
        } label: {
            Label(L("下载"), systemImage: workshopViewModel.activeDownloadCount > 0
                  ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .help(L("下载"))
        .accessibilityValue(String(workshopViewModel.activeDownloadCount))
        .accessibilityIdentifier("toolbar.downloads")
    }

    private var inspectorButton: some View {
        Button {
            withAnimation(chromeAnimation) {
                if isCompact { columnVisibility = .detailOnly }
                inspectorPresentation.toggle(supportsInspector: navigationModel.selection.supportsInspector)
            }
        } label: {
            Label(L("显示或隐藏详情"), systemImage: "sidebar.right")
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(!navigationModel.selection.supportsInspector)
        .help(L("显示或隐藏详情"))
        .accessibilityIdentifier("toolbar.inspector")
    }

    @ViewBuilder
    private var filterContent: some View {
        switch navigationModel.selection {
        case .installed: FilterResults(viewModel: viewModel)
        case .workshop: WorkshopFilterSidebar(workshopViewModel: workshopViewModel)
        case .subscriptions: SubscribedWorkshopFilterSidebar(workshopViewModel: workshopViewModel)
        default: EmptyView()
        }
    }

    private func sectionContent(interfaceActive: Bool) -> some View {
        // Keep visited pages alive: switching navigation preserves scroll and
        // search state, while inactive pages stop animated thumbnails/network work.
        ZStack {
            if loadedSections.contains(.installed) {
                VStack(spacing: 16) {
                    ExplorerTopBar(contentViewModel: viewModel)
                    WallpaperExplorer(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel,
                                      isActive: interfaceActive && navigationModel.selection == .installed,
                                      animatedPreviewMode: globalSettingsViewModel.animatedPreviewPlaybackMode)
                        .onDrop(of: [.fileURL], delegate: viewModel)
                        .contextMenu {
                            ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                        }
                }
                .padding(MotiscapeDesign.contentPadding)
                .sectionVisibility(navigationModel.selection == .installed)
            }
            if plugins.hasSteamAgent && loadedSections.contains(.discover) {
                DiscoverView(workshopViewModel: workshopViewModel, viewModel: viewModel,
                             wallpaperViewModel: wallpaperViewModel, navigationModel: navigationModel,
                             isActive: interfaceActive && navigationModel.selection == .discover)
                    .sectionVisibility(navigationModel.selection == .discover)
            }
            if plugins.hasSteamAgent && loadedSections.contains(.workshop) {
                WorkshopView(workshopViewModel: workshopViewModel, viewModel: viewModel,
                             wallpaperViewModel: wallpaperViewModel,
                             isActive: interfaceActive && navigationModel.selection == .workshop)
                    .padding(MotiscapeDesign.contentPadding)
                    .sectionVisibility(navigationModel.selection == .workshop)
            }
            if plugins.hasSteamAgent && loadedSections.contains(.subscriptions) {
                SubscribedWorkshopView(workshopViewModel: workshopViewModel, viewModel: viewModel,
                                       wallpaperViewModel: wallpaperViewModel,
                                       isActive: interfaceActive && navigationModel.selection == .subscriptions)
                    .padding(MotiscapeDesign.contentPadding)
                    .sectionVisibility(navigationModel.selection == .subscriptions)
            }
            if loadedSections.contains(.downloads) {
                DownloadCenterView(workshopViewModel: workshopViewModel, navigationModel: navigationModel)
                    .sectionVisibility(navigationModel.selection == .downloads)
            }
            if loadedSections.contains(.playlists) {
                VStack(alignment: .leading, spacing: 20) {
                    Label(L("按显示器管理播放列表"), systemImage: "rectangle.stack")
                        .font(.title2.weight(.semibold))
                    ExplorerBottomBar(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel,
                                      isActive: interfaceActive && navigationModel.selection == .playlists)
                    Spacer(minLength: 0)
                }
                .padding(MotiscapeDesign.contentPadding)
                .sectionVisibility(navigationModel.selection == .playlists)
            }
        }
        .isolatedFromParentLayout()
    }

    @ViewBuilder
    private func inspectorContent(interfaceActive: Bool) -> some View {
        if workshopViewModel.showCreatorProfile, let creator = workshopViewModel.selectedCreator {
            CreatorProfileView(creator: creator, workshopViewModel: workshopViewModel,
                               animatedPreviewMode: globalSettingsViewModel.animatedPreviewPlaybackMode)
        } else if navigationModel.selection == .installed || workshopViewModel.showCustomization {
            if wallpaperViewModel.previewWallpaper.presentationIsValid {
                WallpaperPreview(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel,
                                 workshopViewModel: workshopViewModel, isActive: interfaceActive)
            } else {
                ContentUnavailableView(L("选择一张壁纸"), systemImage: "photo.on.rectangle.angled",
                                       description: Text(L("在资料库中选择壁纸，查看预览和播放设置。")))
            }
        } else {
            WorkshopItemDetail(item: workshopViewModel.selectedItem, workshopViewModel: workshopViewModel,
                               isActive: interfaceActive)
        }
    }
}

private extension View {
    func isolatedFromParentLayout() -> some View {
        Color.clear
            .overlay { self }
            .clipped()
    }

    func sectionVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            viewModel: .init(isStaging: true),
            wallpaperViewModel: .init(),
            navigationModel: MainNavigationModel()
        )
            .environment(GlobalSettingsViewModel())
    }
}
