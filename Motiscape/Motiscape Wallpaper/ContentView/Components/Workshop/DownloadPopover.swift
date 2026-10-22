import SwiftUI

struct DownloadPopover: View {
    @Bindable var workshopViewModel: WorkshopViewModel
    @State private var revealError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("下载管理")
                    .font(.headline)
                Spacer()
                if hasCompleted {
                    Button {
                        workshopViewModel.clearCompletedDownloads()
                    } label: {
                        Text("清除记录")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if workshopViewModel.downloadQueue.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("暂无下载任务")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("在创意工坊中浏览并下载壁纸")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(workshopViewModel.downloadQueue) { task in
                            DownloadRow(
                                task: task,
                                onCancel: { workshopViewModel.cancelDownload(task.workshopItem) },
                                onRetry: { workshopViewModel.retryDownload(task) },
                                onReveal: { revealInFinder(task) },
                                onPause: { workshopViewModel.pauseDownload(task) },
                                onResume: { workshopViewModel.resumeDownload(task) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()

            HStack {
                let active = workshopViewModel.downloadQueue.filter(\.isActive).count
                let completed = workshopViewModel.downloadQueue.filter(\.isCompleted).count

                Label("\(active) 下载中", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Label("\(completed) 已完成", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
        .alert("无法打开下载目录", isPresented: Binding(
            get: { revealError != nil },
            set: { if !$0 { revealError = nil } }
        )) {
            Button("好", role: .cancel) { revealError = nil }
        } message: {
            Text(revealError ?? L("未知错误"))
        }
    }

    private var hasCompleted: Bool {
        workshopViewModel.downloadQueue.contains(where: \.isClearable)
    }

    private func revealInFinder(_ task: DownloadTask) {
        guard let path = task.downloadedDirectory else {
            revealError = L("未找到该壁纸的本地下载目录。")
            return
        }
        if !NSWorkspace.shared.open(path) {
            revealError = L("Finder 无法打开该壁纸目录。")
        }
    }
}

struct DownloadRow: View {
    @ObservedObject private var plugins = PluginManager.shared
    var task: DownloadTask
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onReveal: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            WorkshopImage(url: task.workshopItem.previewImageURL, contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.workshopItem.title)
                        .font(.callout)
                    .lineLimit(2)
                    if task.workshopItem.isPreset {
                        Text("预设")
                            .font(.caption2.bold())
                            .foregroundStyle(.purple)
                    } else if task.purpose == .presetDependency {
                        Text("基础壁纸")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                }

                switch task.state {
                case .paused:
                    Text(L("下载已暂停，继续时将校验并复用已下载分块"))
                        .font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text(L("下载已取消")).font(.caption).foregroundStyle(.secondary)
                case .waitingForLogin(let message):
                    NetworkErrorText(message).font(.caption).foregroundStyle(.secondary)
                case .queued:
                    HStack(spacing: 6) {
                        Text(L(task.waitingForLogin ? "等待 Steam 登录后开始下载" : "等待可用下载槽…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(task.workshopItem.formattedFileSize)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                case .resolving:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在解析创意工坊内容…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .downloading(let progress):
                    ProgressView(value: progress.fraction)
                        .animation(.linear, value: progress.fraction)
                    Text(progressSummary(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                case .validating:
                    Text("验证中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .completed:
                    HStack {
                        Text("已完成 ✓")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Spacer()
                        Text(task.workshopItem.formattedFileSize)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                case .failed(let msg):
                    NetworkErrorText(L("失败: %@", msg))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(msg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let error = task.controlError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
            }
            if task.isActive || task.state == .queued {
                Button(action: onPause) {
                    Image(systemName: task.isPausing ? "hourglass" : "pause.circle")
                }
                .disabled(task.isPausing)
                .help(L(task.isPausing ? "正在暂停下载…" : "暂停下载"))
                .accessibilityLabel(L("暂停下载"))
            }

            switch task.state {
            case .paused:
                Button(action: onResume) { Image(systemName: "play.circle") }
                    .disabled(!plugins.hasSteamAgent)
                    .help(L("继续下载")).accessibilityLabel(L("继续下载"))
                Button(action: onCancel) { Image(systemName: "xmark.circle") }
                    .help(L("取消下载")).accessibilityLabel(L("取消下载"))
            case .downloading, .resolving, .queued, .waitingForLogin:
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(L("取消下载"))
                .accessibilityLabel(L("取消下载"))
            case .failed, .cancelled:
                Button { onRetry() } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.body)
                }
                .disabled(!plugins.hasSteamAgent)
                .buttonStyle(.plain)
                .help(L("重试下载"))
                .accessibilityLabel(L("重试下载"))
            case .completed:
                Button { onReveal() } label: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(L("在 Finder 中显示"))
                .accessibilityLabel(L("在 Finder 中显示"))
            case .validating:
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func progressSummary(_ progress: DownloadProgress) -> String {
        let percent = Int(progress.fraction * 100)
        let received = ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
        let total = progress.totalBytes > 0
            ? ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
            : L("未知大小")
        let speed = progress.bytesPerSecond > 0
            ? L("%@/秒", ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file))
            : L("正在连接 Steam…")
        if let eta = progress.etaSeconds, eta.isFinite {
            return L("%d%% · %@ / %@ · %@ · 剩余 %@", percent, received, total, speed, etaText(eta))
        }
        return L("%d%% · %@ / %@ · %@", percent, received, total, speed)
    }

    private func etaText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return L("%d 秒", value) }
        if value < 3600 { return L("%d 分 %d 秒", value / 60, value % 60) }
        return L("%d 小时 %d 分", value / 3600, value % 3600 / 60)
    }
}
