import SwiftUI

struct ZIPWorkspaceRecoveryView: View {
    @Bindable var session: ImportSession
    @State private var selected: ZIPWorkspaceSnapshot?
    @State private var recovering = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ZIP 中断快照")).font(.title2.bold())
            Text(L("重新预检会校验并读取原 ZIP，仍需确认导入，不会恢复未保存的编辑。清理仅删除所选临时快照，不能撤销。"))
                .font(.callout).foregroundStyle(.secondary)
            if let root = session.zipWorkspaceRoot {
                Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            if session.isCheckingZIPWorkspaces || session.isManagingZIPWorkspace { ProgressView(L("正在处理 ZIP 工作区…")) }
            if let error = session.zipWorkspaceError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).lineLimit(3).help(error)
            }
            if let message = session.zipWorkspaceMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            if session.zipWorkspaces.activeCount > 0 {
                Text(L("另有 %d 个活跃工作区，已跳过。", session.zipWorkspaces.activeCount)).font(.caption).foregroundStyle(.secondary)
            }
            // These are independent actions, not selectable List rows. AppKit's
            // List row accessibility can merge both buttons into one element.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.zipWorkspaces.items.isEmpty && !session.isCheckingZIPWorkspaces {
                        Text(L("没有待处理的 ZIP 快照")).foregroundStyle(.secondary)
                    }
                    ForEach(session.zipWorkspaces.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.record.map { URL(fileURLWithPath: $0.source).lastPathComponent } ?? item.id).font(.headline).lineLimit(1)
                                Spacer()
                                if let date = item.record?.createdAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }
                            if let record = item.record {
                                Text(Self.stateTitle(record.state)).font(.caption).foregroundStyle(.secondary)
                                Text(record.source).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(record.source)
                            }
                            Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(item.path)
                            if let issue = item.issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            HStack {
                                Button(L("重新预检源 ZIP")) { selected = item; recovering = true; confirming = true }
                                    .accessibilityIdentifier("zipWorkspace.recover")
                                    .disabled(session.isWorking || !item.canRecover)
                                Button(L("清理临时快照"), role: .destructive) { selected = item; recovering = false; confirming = true }
                                    .accessibilityIdentifier("zipWorkspace.discard")
                                    .disabled(session.isWorking || !item.canDiscard)
                            }.controlSize(.small)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }
            HStack {
                Button(L("关闭")) {
                    if session.isCheckingZIPWorkspaces { session.cancel() }
                    session.isZIPWorkspacesPresented = false
                }.keyboardShortcut(.cancelAction).disabled(session.isManagingZIPWorkspace)
                Spacer()
                Button(L("重新检查")) { session.refreshZIPWorkspaces() }.disabled(session.isWorking || session.isPresented)
            }
        }.padding(24).frame(width: 700, height: 540)
        .interactiveDismissDisabled(session.isManagingZIPWorkspace)
        .onDisappear { if session.isCheckingZIPWorkspaces { session.cancel() } }
        .confirmationDialog(recovering ? L("重新预检源 ZIP？") : L("清理此临时快照？"), isPresented: $confirming) {
            if let selected {
                Button(recovering ? L("重新预检源 ZIP") : L("清理临时快照"), role: recovering ? nil : .destructive) {
                    session.manageZIPWorkspace(selected, recover: recovering)
                }
            }
        } message: {
            // Native confirmation dialogs display a single message Text.
            Text(Self.confirmationMessage(selected, recovering: recovering))
        }
    }

    static func confirmationMessage(_ selected: ZIPWorkspaceSnapshot?, recovering: Bool) -> String {
        let path = selected.map { recovering ? $0.record?.source ?? $0.path : $0.path } ?? ""
        let explanation = recovering ? L("预检通过后仍需确认导入；旧快照仅在新预检成功后清理。")
            : L("将永久删除这份临时副本。源 ZIP 和已导入壁纸不受影响。")
        return [path, explanation].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func stateTitle(_ state: ZIPWorkspaceRecord.State) -> String {
        switch state {
        case .preparing: return L("压缩包复制未完成")
        case .extracting: return L("解压过程已中断")
        case .ready: return L("预检完成，等待重新确认")
        }
    }
}
