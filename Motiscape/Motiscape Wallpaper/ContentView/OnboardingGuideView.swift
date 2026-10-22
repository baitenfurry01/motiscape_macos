import SwiftUI

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case library, discover, workshop, subscriptions, downloads, playlists, toolbar, inspector

    static var availablePages: [Self] {
        allCases.filter { PluginManager.shared.hasSteamAgent || ![.discover, .workshop, .subscriptions].contains($0) }
    }
    var id: Int { rawValue }
    var assetName: String {
        ["library", "discover", "workshop", "subscriptions", "downloads", "playlists", "toolbar", "inspector"][rawValue]
    }
    var title: String {
        L(["资料库", "发现", "创意工坊", "已订阅", "下载", "播放列表", "右上角工具栏", "右侧详情栏"][rawValue])
    }
    var headline: String {
        L(["你的壁纸，集中于此。", "下一张心动，从这里开始。", "更多创意，等你发现。", "喜欢的作品，随时找到。",
           "下载进度，一目了然。", "让喜欢，轮流上场。", "常用操作，触手可及。", "让每张壁纸，更合你意。"][rawValue])
    }
    var summary: String {
        L(["浏览已添加的壁纸，点选喜欢的一张。搜索和筛选，让选择更轻松。",
           "浏览推荐内容和不同主题，找到值得收藏的新壁纸。",
           "搜索 Steam 创意工坊中的作品，查看详情，下载喜欢的壁纸。",
           "登录 Steam 后，集中查看已订阅的作品，管理它们的下载。",
           "查看正在下载的壁纸，随时暂停、继续，或重试失败的任务。",
           "为显示器挑选一组壁纸，调整顺序，再设置自动切换方式。",
           "常用按钮集中在窗口右上角。部分按钮只在适用页面显示。",
           "查看作品信息，调整播放效果。操作前，先确认当前选中的显示器。"][rawValue])
    }
    var tips: [(icon: String, title: String, detail: String)] {
        let keys: [(String, String, String)]
        switch self {
        case .library:
            keys = [("magnifyingglass", "查找壁纸", "按名称搜索，或用筛选缩小范围。"),
                    ("play.fill", "播放壁纸", "点选壁纸，应用到所选显示器。"),
                    ("heart", "收藏壁纸", "标记喜欢的作品，方便再次找到。")]
        case .discover:
            keys = [("sparkles", "浏览推荐", "从推荐主题中寻找灵感。"),
                    ("arrow.right", "查看更多", "打开感兴趣的分类，继续浏览。"),
                    ("info.circle", "查看作品", "选择作品，查看详情与下载选项。")]
        case .workshop:
            keys = [("magnifyingglass", "搜索作品", "按关键词、类型和标签查找壁纸。"),
                    ("arrow.down.circle", "下载壁纸", "喜欢的作品下载后会加入资料库。"),
                    ("person.crop.circle", "登录 Steam", "下载与订阅功能需要 Steam 登录。")]
        case .subscriptions:
            keys = [("person.crop.circle", "登录 Steam", "使用订阅壁纸的 Steam 账户。"),
                    ("arrow.clockwise", "刷新订阅", "同步当前账户已订阅的作品。"),
                    ("arrow.down.circle", "下载全部", "为尚未下载的订阅作品安排下载。")]
        case .downloads:
            keys = [("chart.bar", "查看进度", "查看下载状态、速度和剩余时间。"),
                    ("pause.circle", "暂停与继续", "按需要暂停任务，之后继续下载。"),
                    ("arrow.clockwise", "重试下载", "失败后检查网络，再点击重试。")]
        case .playlists:
            keys = [("plus", "添加壁纸", "从资料库选择多张壁纸加入列表。"),
                    ("hand.draw", "调整顺序", "拖动缩略图，安排播放顺序。"),
                    ("gearshape", "配置", "设置有序或随机播放，以及切换时间。")]
        case .toolbar:
            keys = [("plus", "导入壁纸", "导入本地视频、壁纸文件夹或 ZIP。"),
                    ("line.3.horizontal.decrease", "筛选", "展开当前页面的筛选条件。"),
                    ("display", "显示器", "选择要设置壁纸的显示器。"),
                    ("arrow.down.circle", "下载", "打开下载中心，查看和管理任务。"),
                    ("sidebar.right", "详情", "显示或隐藏右侧壁纸详情栏。")]
        case .inspector:
            keys = [("info.circle", "作品信息", "查看预览、作者和标签。"),
                    ("slider.horizontal.3", "播放与属性", "调整音量及作品支持的其他选项。"),
                    ("display", "显示器操作", "应用到所有显示器，或停止所选显示器的壁纸。")]
        }
        return keys.map { ($0.0, L($0.1), L($0.2)) }
    }

    func screenshot(language: String, dark: Bool, bundle: Bundle = .main) -> NSImage? {
        let name = "onboarding-\(assetName)-\(language)-\(dark ? "dark" : "light")"
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Onboarding")
            ?? bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct OnboardingGuideView: View {
    let page: OnboardingPage
    let onBack: () -> Void
    let onNext: () -> Void
    let onFinish: () -> Void

    @ObservedObject private var localization = MotiscapeLocalization.shared
    @Environment(GlobalSettingsViewModel.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSkipHovered = false

    private var language: String {
        let identifier = localization.locale.identifier
        return identifier.hasPrefix("zh-Hant") ? "zh-Hant" : (identifier.hasPrefix("zh") ? "zh-Hans" : "en")
    }
    private var screenshot: NSImage? { page.screenshot(language: language, dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageContent
                    .id(page)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)

            Divider()
            HStack(spacing: 16) {
                Button(L("跳过指引"), action: onFinish)
                    .buttonStyle(.plain)
                    .foregroundStyle(isSkipHovered ? Color.accentColor : Color.secondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onHover { isSkipHovered = $0 }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSkipHovered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("onboarding.skip")
                Spacer()
                Text(L("第 %d 页，共 %d 页", (OnboardingPage.availablePages.firstIndex(of: page) ?? 0) + 3, OnboardingPage.availablePages.count + 2))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("onboarding.page")
                Spacer()
                Button(L("上一步"), action: onBack)
                    .accessibilityIdentifier("onboarding.back")
                Button(L(page == .inspector ? "开始使用" : "下一步"),
                       action: page == .inspector ? onFinish : onNext)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.next")
            }
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .frame(width: 920, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageContent: some View {
        HStack(spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(page.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(page.headline)
                        .font(.system(size: 30, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: page == .toolbar ? 12 : 18) {
                        ForEach(Array(page.tips.enumerated()), id: \.offset) { _, tip in
                            tipRow(icon: tip.icon, title: tip.title, detail: tip.detail)
                        }
                        if page == .toolbar && settings.settings.isDeveloperModeEnabled {
                            tipRow(icon: "clock.arrow.circlepath", title: L("导入历史与恢复"),
                                   detail: L("开发者模式下，查看导入记录与恢复选项。"))
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 276)

            VStack(spacing: 14) {
                Spacer(minLength: 0)
                screenshotView
                    .frame(maxWidth: .infinity, maxHeight: 420)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(32)
    }

    private func tipRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 21, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var screenshotView: some View {
        if let screenshot {
            Image(nsImage: screenshot)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)) }
                .accessibilityLabel(L("%@界面截图", page.title))
        } else {
            ContentUnavailableView(L("界面预览暂不可用"), systemImage: "photo",
                                   description: Text(page.title))
        }
    }
}
