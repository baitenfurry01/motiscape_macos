import SwiftUI

struct ImportHistoryView: View {
    @Bindable var session: ImportSession
    @State private var query = ""

    private var filtered: [ImportHistoryEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.historyEntries.filter {
            text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || $0.source.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("导入历史与恢复")).font(.title2.bold())
            Text(L("记录预检失败和已确认的导入结果；旧事务记录保持可见。"))
                .font(.callout).foregroundStyle(.secondary)
            if let root = session.historyRoot {
                Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            if session.isRecovering {
                ProgressView(L("正在检查导入事务…"))
            }
            if session.isAutomaticallyIndexing {
                HStack {
                    ProgressView(L("自动补全资料库索引…"))
                    Spacer()
                    Button(L("暂停检查")) { session.cancel() }
                }
            }
            if session.automaticIndexRoot == session.historyRoot {
                if let error = session.automaticIndexError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let report = session.automaticIndexReport {
                    Text(L("自动索引：新增 %d 项，已有 %d 项，需检查 %d 项。", report.scan.inserted, report.scan.preserved, report.scan.issues.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = session.historyError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            if !session.recoveryReport.recovered.isEmpty {
                Text(L("已处理 %d 项中断事务；未完成的复制不会自动重新导入。", session.recoveryReport.recovered.count))
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField(L("搜索标题或来源"), text: $query).textFieldStyle(.roundedBorder)
            List {
                if session.automaticIndexRoot == session.historyRoot, let scan = session.automaticIndexReport?.scan,
                   !scan.issues.isEmpty {
                    Section(L("需要处理的索引问题")) {
                        ForEach(scan.issues, id: \.historyListID) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: issue.id).lastPathComponent)
                                Text(issue.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                Text(issue.id).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(issue.id)
                            }
                        }
                    }
                }
                if !session.recoveryReport.issues.isEmpty {
                    Section(L("需要处理的恢复错误")) {
                        ForEach(session.recoveryReport.issues, id: \.historyListID) { issue in
                            VStack(alignment: .leading) {
                                Text(issue.title)
                                Text(issue.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    }
                }
                if filtered.isEmpty && session.historyError == nil && !session.isRecovering {
                    Text(query.isEmpty ? L("暂无导入记录") : L("没有匹配的导入记录"))
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered, id: \.id) { job in
                    HStack(alignment: .top) {
                        Image(systemName: job.state == .imported ? "checkmark.circle" : "info.circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title.isEmpty ? job.source : job.title).font(.headline)
                            HStack {
                                Text(Self.title(job.state))
                                Text(job.date, style: .date)
                                Text(job.date, style: .time)
                            }.font(.caption).foregroundStyle(.secondary)
                            if job.phase == .preflight { Text(L("预检阶段")).font(.caption).foregroundStyle(.secondary) }
                            Text(job.source).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        }
                        Spacer(minLength: 8)
                        if let url = Self.revealURL(job, root: session.historyRoot) {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                                Label(L("在 Finder 中显示"), systemImage: "folder")
                            }.labelStyle(.iconOnly).help(L("在 Finder 中显示"))
                        }
                    }.padding(.vertical, 4)
                }
            }
            HStack {
                Button(L("关闭")) { session.isHistoryPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Menu(L("维护")) {
                    Button(L("元数据库维护")) { session.isMetadataPresented = true; session.metadataMaintenance.refresh() }
                    Button(L("ZIP 快照")) { session.showZIPWorkspaces() }
                    Button(L("补全索引")) { session.showIndexRebuild() }
                    Button(L("替换备份")) { session.showBackups() }
                }.disabled(session.isWorking || session.isPresented)
                Button(L("重新检查")) { session.recoverAtLaunch() }
                    .disabled(session.isWorking || session.isPresented)
            }
        }.padding(24).frame(width: 680, height: 540)
        .sheet(isPresented: $session.isBackupsPresented) { ImportBackupView(session: session) }
        .sheet(isPresented: $session.isIndexRebuildPresented) { LibraryIndexRebuildView(session: session) }
        .sheet(isPresented: $session.isZIPWorkspacesPresented) { ZIPWorkspaceRecoveryView(session: session) }
        .sheet(isPresented: $session.isMetadataPresented) { LibraryMetadataMaintenanceView(session: session.metadataMaintenance) }
    }

    static func title(_ state: ImportAttemptRecord.State) -> String {
        switch state {
        case .pending: return L("未完成，等待恢复核对")
        case .imported: return L("导入成功")
        case .skipped: return L("已跳过重复项")
        case .restored: return L("已恢复备份")
        case .trashed: return L("备份已移到废纸篓")
        case .failed: return L("导入失败")
        case .cancelled: return L("已取消")
        case .interrupted: return L("已中断，请重新选择源文件")
        }
    }

    static func revealURL(_ job: ImportJob, root: URL?) -> URL? {
        guard job.state == .completed, job.record.id == job.destination else { return nil }
        return revealPath(job.destination, root: root)
    }

    static func revealURL(_ entry: ImportHistoryEntry, root: URL?) -> URL? {
        guard [.imported, .skipped, .restored].contains(entry.state), let path = entry.destination else { return nil }
        return revealPath(path, root: root)
    }

    private static func revealPath(_ path: String, root: URL?) -> URL? {
        guard let root else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.path,
              !url.lastPathComponent.hasPrefix("."),
              url.resolvingSymlinksInPath().path == url.path,
              let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              attributes.isDirectory == true, attributes.isSymbolicLink != true else { return nil }
        return url
    }
}

private extension ImportRecoveryIssue {
    // List flattens child collections; error and transaction rows may share a job ID.
    var historyListID: String { "recovery-error:" + id }
}

private extension LibraryIndexScanRecord.Issue {
    var historyListID: String { "index-issue:" + id }
}
