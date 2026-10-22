import SwiftUI

struct GeneralPage: SettingsPage {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject private var steam = SteamServiceManager.shared
    @Bindable var viewModel: GlobalSettingsViewModel

    @State private var librarySources: [WallpaperLibrarySource]
    @State private var showMirrorWarning = false
    @State private var showLanguageRestartNotice = false
    @State private var showProxyRestartNotice = false
    @State private var showResetConfirmation = false
    @State private var advancedTitleTapCount = 0

    private func proxyBinding(_ field: WritableKeyPath<AppHTTPProxySettings, String>) -> Binding<String> {
        Binding(get: { (viewModel.settings.httpProxy ?? AppHTTPProxySettings())[keyPath: field] }, set: { value in
            var proxy = viewModel.settings.httpProxy ?? AppHTTPProxySettings()
            proxy[keyPath: field] = value
            viewModel.settings.httpProxy = proxy
        })
    }

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
        _librarySources = State(initialValue: WallpaperLibrary.shared.librarySources)
    }

    private func applyEndpointChange() {
        AppDelegate.shared.workshopViewModel.items = []
        AppDelegate.shared.workshopViewModel.currentPage = 1
        AppDelegate.shared.workshopViewModel.search()
    }

    private func refreshLibrarySources() {
        librarySources = WallpaperLibrary.shared.librarySources
    }

    @ViewBuilder
    private func librarySourceRow(_ source: WallpaperLibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(source.title).font(.callout)
                if source.role == .managedWorkshop {
                    Text("当前下载位置")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                } else if !source.exists {
                    Text("尚未创建")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(source.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(source.url.path(percentEncoded: false))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("在访达中显示") {
                if !source.exists {
                    try? FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.activateFileViewerSelecting([source.url])
                refreshLibrarySources()
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("启动时显示", selection: $viewModel.settings.startupSection) {
                    ForEach(MainSection.allCases.filter { !$0.requiresSteamAgent || plugins.hasSteamAgent }, id: \.self) { section in
                        Text(section.title).tag(section)
                    }
                }
                Text("保存后在下次启动 Motiscape 时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("开机时自动启动 Motiscape", isOn: $viewModel.settings.autoStart)
                if viewModel.loginItemStatus == .requiresApproval {
                    HStack {
                        Label(L("需要在系统设置中批准"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("打开登录项设置")) {
                            viewModel.openLoginItemSettings()
                        }
                    }
                } else if let loginItemError = viewModel.loginItemError {
                    Label(loginItemError, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Toggle(L("隐藏菜单栏图标"), isOn: Binding(
                    get: { viewModel.settings.shouldHideMenuBarIcon },
                    set: { viewModel.settings.hideMenuBarIcon = $0 }
                ))
                Picker("菜单栏图标", selection: Binding(
                    get: { viewModel.settings.shouldUseMonochromeMenuBarIcon },
                    set: { viewModel.settings.monochromeMenuBarIcon = $0 }
                )) {
                    Text("彩色").tag(false)
                    Text("黑白").tag(true)
                }
            } header: {
                Label("启动", systemImage: "star.fill")
            }

            Section {
                Picker(L("语言"), selection: Binding(
                    get: { viewModel.settings.language },
                    set: { language in
                        guard language != viewModel.settings.language else { return }
                        viewModel.settings.language = language
                        showLanguageRestartNotice = true
                    }
                )) {
                    Text("跟随系统").tag(GSLocalization.followSystem)
                    Text("English").tag(GSLocalization.en_US)
                    Text("简体中文").tag(GSLocalization.zh_CN)
                    Text("繁體中文").tag(GSLocalization.zh_TW)
                }
            } header: {
                Label("语言", systemImage: "character.bubble")
            }

            Section {
                Picker("外观", selection: $viewModel.settings.appearance) {
                    Text("浅色").tag(GSAppearance.light)
                    Text("深色").tag(GSAppearance.dark)
                    Text("跟随系统").tag(GSAppearance.followSystem)
                }

                Toggle("覆盖壁纸", isOn: Binding(
                    get: { viewModel.settings.shouldOverrideWallpaper },
                    set: { viewModel.settings.overrideWallpaper = $0 }
                ))
                Text("Motiscape 会用当前壁纸的画面替换系统桌面图片，让菜单栏与程序坞的取色与壁纸一致。开启后将持续覆盖，退出 Motiscape 后依然保留；关闭时仅在 Motiscape 运行期间覆盖，退出会自动还原你原本的桌面图片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("外观", systemImage: "paintpalette.fill")
            }

            Section {
                HStack {
                    Text("全局音量")
                    MotiscapeSlider(value: $viewModel.settings.masterVolume, in: 0...1)
                        .onChange(of: viewModel.settings.masterVolume) { _, _ in
                            AppDelegate.shared.wallpaperViewModel.reapplyVolume()
                        }
                    Text("\(Int(viewModel.settings.masterVolume * 100))%")
                        .monospacedDigit().frame(width: 40)
                }
                Toggle("全局静音", isOn: $viewModel.settings.globalMuted)
                    .onChange(of: viewModel.settings.globalMuted) { _, _ in
                        AppDelegate.shared.wallpaperViewModel.reapplyVolume()
                    }
            } header: {
                Label("音频", systemImage: "speaker.wave.3.fill")
            }

            Section {
                ForEach(librarySources) { source in
                    librarySourceRow(source)
                }

                Toggle("自动刷新壁纸库", isOn: $viewModel.settings.autoRefresh)
            } header: {
                Label("壁纸库", systemImage: "folder.fill")
            }

            if plugins.hasSteamAgent {
                Section {
                    Toggle(L("安全模式"), isOn: Binding(
                        get: { viewModel.settings.isWorkshopSafeModeEnabled },
                        set: { viewModel.settings.workshopSafeMode = $0 }
                    ))
                    .accessibilityIdentifier("settings.workshop.safeMode")
                    if MotiscapeRegion.isMainlandChina {
                        Picker("Steam API 线路", selection: $viewModel.settings.steamAPIEndpoint) {
                            Text("Steam 官方 Web API").tag(GSSteamAPIEndpoint.official)
                            Text("SteamCF 镜像").tag(GSSteamAPIEndpoint.mirror)
                        }
                        .onChange(of: viewModel.settings.steamAPIEndpoint) { _, newValue in
                            if newValue == .mirror {
                                showMirrorWarning = true
                            } else {
                                applyEndpointChange()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Steam API Key", systemImage: "key.fill")
                        SteamAPIKeySettingsFields(apiKey: $viewModel.settings.steamAPIKey,
                                                  hasBuiltInKey: steam.hasBuiltInKey,
                                                  isSettingsPresented: viewModel.isSettingsPresented)
                    }
                } header: {
                    Label("创意工坊", systemImage: "network")
                }
                .alert("SteamCF 镜像警告", isPresented: $showMirrorWarning) {
                    Button("仍要使用") {
                        applyEndpointChange()
                    }
                    Button("取消", role: .cancel) {
                        viewModel.settings.steamAPIEndpoint = .official
                    }
                } message: {
                    Text("该镜像仅允许中国大陆用户访问，且并非 Steam 官方服务，不保证安全性和可用性。它只代理浏览 API，不能加速 Steam 登录或壁纸下载。")
                }

            }

            Section {
                Toggle(L("启用 HTTP/HTTPS 代理"), isOn: Binding(
                    get: { viewModel.settings.httpProxy?.enabled ?? false },
                    set: { enabled in
                        var proxy = viewModel.settings.httpProxy ?? AppHTTPProxySettings()
                        proxy.enabled = enabled
                        viewModel.settings.httpProxy = proxy
                        if enabled { showProxyRestartNotice = true }
                    }
                ))
                .accessibilityIdentifier("settings.httpProxy.enabled")
                if viewModel.settings.httpProxy?.enabled == true {
                    TextField(L("代理服务器"), text: proxyBinding(\.host))
                        .accessibilityIdentifier("settings.httpProxy.host")
                    TextField(L("代理端口"), text: proxyBinding(\.port))
                        .accessibilityIdentifier("settings.httpProxy.port")
                }
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.settings.httpProxy?.enabled == true {
                        Text(L("仅填写主机名或 IP 和端口，代理须支持 HTTP CONNECT。暂不支持需要认证的代理。"))
                        if viewModel.settings.httpProxy?.isValid != true {
                            Text(L("代理地址或端口无效。端口范围为 1–65535。"))
                                .foregroundStyle(.red)
                        }
                    }
                    Text(L("代理用于应用内浏览、预览图和 Steam 登录及下载，不包含网页壁纸或外部浏览器。"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if advancedTitleTapCount >= 10 {
                    Toggle(L("开发模式"), isOn: Binding(
                        get: { viewModel.settings.isDeveloperModeEnabled },
                        set: { viewModel.settings.developerMode = $0 }
                    ))
                    .accessibilityIdentifier("settings.developerMode")
                }
                HStack {
                    Text("重置所有设置")
                    Spacer()
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Text("重置").frame(width: 100)
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.resetAll")
                }
            } header: {
                Label {
                    Button {
                        advancedTitleTapCount = min(advancedTitleTapCount + 1, 10)
                    } label: {
                        Text("高级")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.advancedTitle")
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                }
            }

            Section {
                Button {
                    viewModel.selection = 4
                } label: {
                    HStack {
                        Label(L("关于"), systemImage: "info.circle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.about.open")
            }
        }
        .formStyle(.grouped)
        .alert(L("需要重新启动"), isPresented: $showLanguageRestartNotice) {
            Button(L("知道了"), role: .cancel) { }
        } message: {
            Text(L("保存设置后，请重新启动应用以完整应用新语言。"))
        }
        .alert(L("启用代理需要重启"), isPresented: $showProxyRestartNotice) {
            Button(L("知道了"), role: .cancel) { }
        } message: {
            Text(L("保存设置并重新启动应用以启动代理。"))
        }
        .alert(L("重置所有设置？"), isPresented: $showResetConfirmation) {
            Button(L("取消"), role: .cancel) { }
            Button(L("重置"), role: .destructive) {
                viewModel.restoreDefaultSettings()
            }
            .accessibilityIdentifier("settings.resetAll.confirm")
        } message: {
            Text(L("重置后将恢复默认设置，并清除 Steam Web API Key 与 Steam 登录状态。已下载壁纸将保留。"))
        }
        .onDisappear { advancedTitleTapCount = 0 }
    }
}
