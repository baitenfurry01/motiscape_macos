import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PluginsPage: SettingsPage {
    @Bindable var viewModel: GlobalSettingsViewModel
    @ObservedObject private var plugins = PluginManager.shared
    @State private var showingRestart = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var errorTitle = "无法添加插件"
    @State private var pluginToRemove: InstalledAgent?
    @State private var showingRemoveConfirmation = false

    private var pluginLibraryIntroduction: AttributedString {
        var text = AttributedString(L("点击此处浏览和下载第三方插件。"))
        text.link = PluginLinks.thirdPartyPluginLibraryURL
        text += AttributedString(" " + L("第三方插件的可用性和兼容性不作保证。"))
        return text
    }
    
    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                Text("暂无内置插件。")
                    .foregroundStyle(.secondary)
            } header: {
                Label("内置", systemImage: "square.dashed.inset.filled")
            }
            Section {
                if plugins.plugins.isEmpty {
                    Text("尚未添加插件")
                        .foregroundStyle(.secondary)
                }
                ForEach(plugins.plugins) { plugin in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.localizedName)
                            Text(plugin.version).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L(plugin.isActive ? "已启用" : "重启后启用"))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            pluginToRemove = plugin
                            showingRemoveConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(L("删除插件"))
                        .accessibilityLabel(L("删除%@插件", plugin.localizedName))
                        .accessibilityIdentifier("settings.plugins.remove." + plugin.id)
                        .disabled(plugins.isBusy)
                    }
                }
                if let error = plugins.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Label("第三方", systemImage: "person.3.fill")
                    Spacer()
                    Button(action: chooseAgent) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L("添加下载的插件 App"))
                    .accessibilityLabel(L("添加插件"))
                    .accessibilityIdentifier("settings.plugins.add")
                    .disabled(plugins.isBusy)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择已下载的插件 App。配置完成后，重新启动主程序即可使用对应功能。")
                    Text(pluginLibraryIntroduction)
                        .accessibilityIdentifier("settings.plugins.library")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { plugins.isBusy }, set: { _ in })) {
            VStack(spacing: 16) {
                ProgressView()
                Text(L(plugins.removingPluginID == nil ? "正在配置插件…" : "正在删除插件…")).font(.headline)
                Text(L(plugins.removingPluginID == nil ? "正在读取插件信息，请稍候。" : "正在停止插件并恢复设置，请稍候。"))
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(width: 320)
            .interactiveDismissDisabled()
        }
        .alert("插件配置完成", isPresented: $showingRestart) {
            Button("好", role: .cancel) {}
        } message: {
            Text("启用插件需要重新启动 App。重新打开后，将显示对应功能的设置。")
        }
        .alert(L(errorTitle), isPresented: $showingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("删除插件？", isPresented: $showingRemoveConfirmation) {
            Button("取消", role: .cancel) { pluginToRemove = nil }
            Button("删除", role: .destructive) { removeSelectedAgent() }
        } message: {
            Text(L("将停止并删除“%@”，相关功能将不再显示。你下载的原始 App 将保留。", pluginToRemove?.localizedName ?? ""))
        }
    }

    private func chooseAgent() {
        let panel = NSOpenPanel()
        panel.title = L("添加插件")
        panel.prompt = L("添加")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await plugins.install(from: url)
                    showingRestart = true
                } catch {
                    errorTitle = "无法添加插件"
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    private func removeSelectedAgent() {
        guard let plugin = pluginToRemove else { return }
        pluginToRemove = nil
        Task { @MainActor in
            do { try await plugins.remove(plugin) }
            catch {
                errorTitle = "无法删除插件"
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

}

struct PluginPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environment({ () -> GlobalSettingsViewModel in
                let viewModel = GlobalSettingsViewModel()
                viewModel.selection = 2
                return viewModel
            }())
            .frame(width: 500, height: 600)
    }
}
