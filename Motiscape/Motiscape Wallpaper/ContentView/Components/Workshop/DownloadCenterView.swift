import SwiftUI

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, active, paused, completed, failed
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return L("全部")
        case .active: return L("进行中")
        case .paused: return L("已暂停")
        case .completed: return L("已完成")
        case .failed: return L("失败")
        }
    }

    func includes(_ state: DownloadState) -> Bool {
        switch (self, state) {
        case (.all, _), (.active, .queued), (.active, .resolving),
             (.active, .downloading), (.active, .validating),
             (.paused, .paused), (.completed, .completed), (.failed, .failed), (.failed, .cancelled): return true
        default: return false
        }
    }
}

/// Persistent queue and previous-attempt history, driven by the coordinator.
struct DownloadCenterView: View {
    @ObservedObject private var plugins = PluginManager.shared
    @Bindable var workshopViewModel: WorkshopViewModel
    @ObservedObject var navigationModel: MainNavigationModel
    @State private var filter: DownloadFilter = .all
    @State private var revealError: String?
    @State private var showingHistory = false

    private var tasks: [DownloadTask] {
        workshopViewModel.downloadQueue.filter { filter.includes($0.state) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: BrowseToolbarMetrics.spacing) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("下载中心")).font(.title2.weight(.semibold))
                    Text(L("任务与历史会自动保存，重启后可继续未完成下载。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    workshopViewModel.clearCompletedDownloads()
                } label: {
                    Label(L("清除记录"), systemImage: "checkmark.circle")
                }
                .disabled(!workshopViewModel.downloadQueue.contains(where: \.isClearable) && workshopViewModel.persistentDownloadHistory.isEmpty)
                .controlSize(.large)
                .frame(height: BrowseToolbarMetrics.height)
            }
            .padding(MotiscapeDesign.contentPadding)

            if workshopViewModel.downloadsLoading {
                ProgressView().controlSize(.small).padding(.horizontal, MotiscapeDesign.contentPadding)
            }

            if let error = workshopViewModel.downloadPersistenceError {
                HStack {
                    Label(error, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(L("重试保存")) { workshopViewModel.retryDownloadPersistence() }
                }
                .padding(.horizontal, MotiscapeDesign.contentPadding)
            }

            DownloadQueueControls(
                concurrency: Binding(get: { workshopViewModel.downloadConcurrency },
                                     set: { workshopViewModel.setDownloadConcurrency($0) }),
                pauseAll: { workshopViewModel.pauseAllDownloads() },
                resumeAll: { workshopViewModel.resumeAllDownloads() },
                showHistory: { showingHistory = true }
            )
            .padding(.horizontal, MotiscapeDesign.contentPadding)
            .padding(.bottom, BrowseToolbarMetrics.spacing)

            Picker(L("下载状态"), selection: $filter) {
                ForEach(DownloadFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(height: BrowseToolbarMetrics.height)
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, MotiscapeDesign.contentPadding)
            .padding(.bottom, 16)

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label(L(filter == .all ? "暂无下载任务" : "没有匹配的任务"), systemImage: "arrow.down.circle")
                } description: {
                    Text(L(filter == .all ? "在创意工坊中浏览并下载壁纸" : "选择其他状态查看下载任务。"))
                } actions: {
                    if plugins.hasSteamAgent {
                        Button(L("浏览创意工坊")) { navigationModel.selection = .workshop }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tasks) { task in
                    DownloadRow(task: task,
                                onCancel: { workshopViewModel.cancelDownload(task.workshopItem) },
                                onRetry: { workshopViewModel.retryDownload(task) },
                                onReveal: { reveal(task) },
                                onPause: { workshopViewModel.pauseDownload(task) },
                                onResume: { workshopViewModel.resumeDownload(task) })
                        .contextMenu {
                            if task.state == .queued || task.state == .paused {
                                Button(L("优先下载")) { workshopViewModel.prioritizeDownload(task) }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            HStack(spacing: 8) {
                Label(L("%d 个任务", workshopViewModel.downloadQueue.count), systemImage: "list.bullet")
                Spacer()
                Text(L("下载完成后会自动加入资料库"))
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(MotiscapeDesign.contentPadding)
        }
        .alert(L("无法打开下载目录"), isPresented: Binding(
            get: { revealError != nil }, set: { if !$0 { revealError = nil } }
        )) {
            Button(L("好"), role: .cancel) { revealError = nil }
        } message: { Text(revealError ?? "") }
        .sheet(isPresented: $showingHistory) {
            DownloadHistoryView(jobs: workshopViewModel.persistentDownloadHistory)
        }
    }

    private func reveal(_ task: DownloadTask) {
        guard let url = task.downloadedDirectory else {
            revealError = L("未找到该壁纸的本地下载目录。")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The label and numeric picker have independent widths so translated labels
/// cannot consume the selected count's space. Narrow panes wrap the actions.
struct DownloadQueueControls: View {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject private var localization = MotiscapeLocalization.shared
    @Binding var concurrency: Int
    let pauseAll: () -> Void
    let resumeAll: () -> Void
    let showHistory: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BrowseToolbarMetrics.spacing) {
                concurrencyPicker
                batchActions
                Spacer(minLength: 0)
                historyButton
            }
            VStack(alignment: .leading, spacing: BrowseToolbarMetrics.spacing) {
                concurrencyPicker
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BrowseToolbarMetrics.spacing) {
                        batchActions
                        Spacer(minLength: 0)
                        historyButton
                    }
                    VStack(alignment: .leading, spacing: BrowseToolbarMetrics.spacing) {
                        batchActions
                        historyButton
                    }
                }
            }
        }
        .controlSize(.large)
    }

    private var concurrencyPicker: some View {
        HStack(spacing: 8) {
            Text(L("同时下载")).fixedSize()
            Picker(L("同时下载"), selection: $concurrency) {
                ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 64)
            .accessibilityIdentifier("downloads.concurrency")
        }
        .fixedSize()
    }

    private var batchActions: some View {
        Menu(L("批量操作")) {
            Button(L("暂停全部下载"), action: pauseAll)
            Button(L("继续全部下载"), action: resumeAll)
                .disabled(!plugins.hasSteamAgent)
        }
        .fixedSize()
    }

    private var historyButton: some View {
        Button(L("历史尝试"), action: showHistory)
            .fixedSize()
    }
}

struct DownloadHistoryView: View {
    let jobs: [DownloadJob]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L("历史尝试")).font(.headline)
                Spacer()
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            List(jobs.reversed(), id: \.id) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.item.title).font(.headline)
                    Text(job.completedAt ?? job.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text(job.outputRoot).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L(job.status == .completed ? "已完成" : job.status == .cancelled ? "下载已取消" : "失败"))
                        .font(.caption)
                    if let error = job.error { NetworkErrorText(error).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.frame(width: 560, height: 420)
    }
}
