import SwiftUI

struct ImportWallpaperSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var navigationModel: MainNavigationModel
    @ObservedObject private var plugins = PluginManager.shared
    @State private var workshopImport: WorkshopImportSession
    var enqueueWorkshop: @MainActor (WorkshopItem) async throws -> WorkshopImportReceipt

    init(navigationModel: MainNavigationModel,
         workshopImport: WorkshopImportSession? = nil,
         enqueueWorkshop: @escaping @MainActor (WorkshopItem) async throws -> WorkshopImportReceipt = { _ in
             throw WorkshopImportError.queueUnavailable
         }) {
        self.navigationModel = navigationModel
        self._workshopImport = State(initialValue: workshopImport ?? WorkshopImportSession())
        self.enqueueWorkshop = enqueueWorkshop
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("导入壁纸")).font(.title2.bold())
                    Text(L(plugins.hasSteamAgent ? "从本机添加，或前往创意工坊查找。" : "从本机添加壁纸。"))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Form {
                Section(L("本地文件")) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("视频文件"))
                            Text("MP4 · MOV · M4V")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "film") }

                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("壁纸文件夹"))
                            Text(L("选择单个壁纸文件夹，支持视频，场景和网页壁纸。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "folder") }
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("ZIP 壁纸包"))
                            Text(L("支持批量导入视频，网页和场景壁纸。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "doc.zipper") }
                }
                if plugins.hasSteamAgent {
                Section(L("通过工坊链接或 ID 导入")) {
                    WorkshopImportForm(session: workshopImport, enqueue: enqueueWorkshop) { receipt in
                        navigationModel.selection = receipt == .installed ? .installed : .downloads
                        dismiss()
                    }
                }
                }
                Section {
                    if plugins.hasSteamAgent {
                        Button {
                            navigationModel.selection = .workshop
                            dismiss()
                        } label: {
                            Label(L("浏览创意工坊"), systemImage: "globe")
                        }
                        .disabled(workshopImport.isSubmitting)
                    }
                    Text(L("也可以将文件或文件夹直接拖入资料库。导入会复制文件到壁纸库。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(workshopImport.isSubmitting)
                Spacer()
                Button(L("选择文件或文件夹…")) {
                    navigationModel.selection = .installed
                    dismiss()
                    // Let SwiftUI dismiss the sheet before presenting AppKit's panel.
                    DispatchQueue.main.async {
                        AppDelegate.shared.openImportFromFolderPanel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workshopImport.isSubmitting)
            }
            .padding(20)
        }
        .frame(width: 540, height: 650)
        .interactiveDismissDisabled(workshopImport.isSubmitting)
        .onDisappear { workshopImport.invalidate() }
    }
}

struct WorkshopImportForm: View {
    @Bindable var session: WorkshopImportSession
    let enqueue: @MainActor (WorkshopItem) async throws -> WorkshopImportReceipt
    let openDestination: (WorkshopImportReceipt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("Steam 工坊作品链接或数字 ID"), text: $session.input,
                          prompt: Text(L("Steam 工坊作品链接或数字 ID")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel(L("Steam 工坊作品链接或数字 ID"))
                    .accessibilityIdentifier("import.workshop.reference")
                    .disabled(session.isSubmitting)
                    .onSubmit { session.resolve() }
                Button(L("解析作品")) { session.resolve() }
                    .disabled(session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSubmitting || session.isResolving)
            }
            Text(L("仅支持 Wallpaper Engine 单个作品。"))
                .font(.caption).foregroundStyle(.secondary)
            if session.isResolving { ProgressView(L("正在解析工坊作品…")).controlSize(.small) }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let item = session.item {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline).lineLimit(2)
                    Text("\(item.displayTypeName) · \(item.formattedFileSize) · ID \(item.id)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.isPreset {
                        Text(L("预设可能依赖其他壁纸，下载后仍需确认依赖与信任。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let receipt = session.receipt {
                    Label(receiptText(receipt), systemImage: "checkmark.circle").font(.caption)
                    Button(receipt == .installed ? L("打开资料库") : L("查看下载队列")) { openDestination(receipt) }
                } else {
                    Button(L("确认加入下载队列")) { session.confirm(enqueue: enqueue) }
                        .buttonStyle(.borderedProminent).disabled(session.isSubmitting)
                    if session.isSubmitting { ProgressView(L("正在保存下载任务…")).controlSize(.small) }
                }
            }
        }
    }

    private func receiptText(_ receipt: WorkshopImportReceipt) -> String {
        switch receipt {
        case .queued: return L("已保存到下载队列。")
        case .existing: return L("下载记录已存在；可在下载页继续或重试，不会重复添加。")
        case .installed: return L("该作品已在资料库中，无需重复下载。")
        }
    }
}
