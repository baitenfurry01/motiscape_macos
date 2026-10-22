import SwiftUI

struct ImportReviewSheet: View {
    @Bindable var session: ImportSession
    let onCompletion: () -> Void
    @State private var reviewPage = 0

    private var pageCount: Int { ImportReviewPagination.pageCount(session.candidates.count) }
    private var visibleRange: Range<Int> { ImportReviewPagination.range(count: session.candidates.count, page: reviewPage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("导入预检")).font(.title2.bold())
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if session.results.isEmpty {
                List {
                    ForEach(Array($session.candidates[visibleRange]), id: \.wrappedValue.id) { $candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 12) {
                                ImportCoverThumbnail(candidate: candidate)
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField(L("标题"), text: $candidate.title, prompt: Text(L("标题")))
                                        .textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(L("标题"))
                                    TextField(L("标签，用逗号分隔"), text: $candidate.tagsText, prompt: Text(L("标签，用逗号分隔")))
                                        .textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(L("标签，用逗号分隔"))
                                    HStack {
                                        Button(L("选择封面")) { session.chooseCover(for: candidate.id) }
                                            .accessibilityLabel(L("选择封面"))
                                        Menu(L("封面选项")) {
                                            Button(L("保留原封面或自动生成")) { session.setCover(.original, for: candidate.id) }
                                            Button(L("不使用封面")) { session.setCover(.remove, for: candidate.id) }
                                        }
                                        if session.coverLoadingIDs.contains(candidate.id) { ProgressView().controlSize(.small) }
                                    }.controlSize(.small).buttonStyle(.borderless)
                                }.disabled(session.isWorking)
                            }
                            Text(candidate.displaySource).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let issue = candidate.validationIssue {
                                Text(issue).font(.caption).foregroundStyle(.red)
                            } else {
                                Text("\(candidate.kind) · \(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let video = candidate.videoInfo {
                                Text(L("%d × %d · %.1f 秒 · %.1f fps", video.width, video.height, video.duration, video.frameRate))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(candidate.mediaWarnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            }
                            if let error = session.coverErrors[candidate.id] {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .id(reviewPage)
                if pageCount > 1 {
                    HStack {
                        Text(L("共 %d 项", session.candidates.count)).foregroundStyle(.secondary)
                        Spacer()
                        Button { reviewPage -= 1 } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(L("上一页")).help(L("上一页"))
                            .accessibilityIdentifier("importReview.previousPage")
                            .disabled(reviewPage == 0 || session.isWorking)
                        Text(L("第 %d / %d 页", reviewPage + 1, pageCount)).monospacedDigit()
                        Button { reviewPage += 1 } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel(L("下一页")).help(L("下一页"))
                            .accessibilityIdentifier("importReview.nextPage")
                            .disabled(reviewPage >= pageCount - 1 || session.isWorking)
                    }.controlSize(.small)
                }
                Picker(L("重复内容"), selection: $session.duplicatePolicy) {
                    ForEach(ImportDuplicatePolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }.disabled(session.isWorking)
                if session.duplicatePolicy == .replace {
                    Text(L("仅替换已记录的相同内容；旧副本保留在资料库的 .importing 备份中。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                List(session.results) { result in
                    HStack(alignment: .top) {
                        Image(systemName: result.outcome == .imported ? "checkmark.circle" : "info.circle")
                        VStack(alignment: .leading) {
                            Text(session.candidates.first(where: { $0.id == result.id })?.title ?? result.source.lastPathComponent)
                            Text(outcomeTitle(result.outcome)).font(.caption).foregroundStyle(.secondary)
                            if let message = result.message { Text(message).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
            if session.isWorking {
                let activity = session.reviewActivity ?? .checkingLibrary
                Text(activity.message(progress: session.progress)).font(.caption)
                if let fraction = activity.fraction(progress: session.progress) {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                if session.isWorking {
                    Button(L("取消")) { session.cancel() }
                        .accessibilityLabel(L("取消"))
                        .accessibilityIdentifier("importReview.cancel")
                        .help(L("取消当前操作并等待清理完成，再关闭此窗口或退出应用。"))
                } else {
                    Button(L("关闭")) { session.isPresented = false }.keyboardShortcut(.cancelAction)
                        .accessibilityLabel(L("关闭"))
                        .accessibilityIdentifier("importReview.close")
                }
                Spacer()
                if !session.results.isEmpty {
                    Button(L("重试失败项")) { session.retryFailures(onCompletion: onCompletion) }
                        .accessibilityLabel(L("重试失败项"))
                        .accessibilityIdentifier("importReview.retry")
                        .disabled(session.isWorking || !session.results.contains { $0.outcome == .failed || $0.outcome == .cancelled })
                } else {
                    Button(L("确认导入")) { session.start(onCompletion: onCompletion) }
                        .accessibilityLabel(L("确认导入"))
                        .accessibilityIdentifier("importReview.confirm")
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(session.isWorking || session.isPreparingCover || !session.candidates.contains { $0.validationIssue == nil })
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .interactiveDismissDisabled(session.isWorking)
        .onChange(of: session.candidates.map(\.id)) { reviewPage = 0 }
        .onDisappear { session.releasePreparedFiles() }
    }

    private func outcomeTitle(_ outcome: ImportResult.Outcome) -> String {
        switch outcome {
        case .imported: return L("导入成功")
        case .skipped: return L("已跳过重复项")
        case .failed: return L("导入失败")
        case .cancelled: return L("已取消")
        }
    }
}

enum ImportReviewPagination {
    // Bound the editable accessibility tree, not the batch: every binding still
    // points into session.candidates and confirmation submits the whole array.
    static let pageSize = 20

    static func pageCount(_ count: Int) -> Int {
        guard count > 0 else { return 1 }
        return 1 + (count - 1) / pageSize
    }

    static func range(count: Int, page: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let boundedPage = min(max(0, page), pageCount(count) - 1)
        let start = boundedPage * pageSize
        return start..<(start + min(pageSize, count - start))
    }
}

private struct ImportCoverThumbnail: View {
    let candidate: ImportCandidate
    private var data: Data? {
        switch candidate.coverEdit {
        case .original: return candidate.previewThumbnail
        case .remove: return nil
        case .custom(let data): return data
        }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(L("封面预览"))
    }
}
