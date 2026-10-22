import SwiftUI

struct FirstLaunchView: View {
    @Environment(GlobalSettingsViewModel.self) private var globalSettingsViewModel
    
    @ObservedObject private var localization = MotiscapeLocalization.shared
    @ObservedObject private var plugins = PluginManager.shared
    @State var checked = !(UserDefaults.standard.object(forKey: "IsFirstLaunch") as? Bool ?? true)
    @State private var guidePage: OnboardingPage?
    @State private var showingPrivacy = false
    
    var body: some View {
        Group {
            if showingPrivacy {
                PrivacyPolicyView(onBack: { showingPrivacy = false }, onAgree: {
                    PrivacyPolicy.acceptCurrentVersion()
                    showingPrivacy = false
                    guidePage = .library
                })
            } else if let guidePage {
                OnboardingGuideView(page: guidePage,
                                    onBack: goBack, onNext: goNext, onFinish: finish)
            } else {
                welcomeContent
            }
        }
        .environment(\.locale, localization.locale)
        .interactiveDismissDisabled(!PrivacyPolicy.hasAcceptedCurrentVersion())
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text(L("欢迎使用 Motiscape"))
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 12) {
                    NewSection(title: "三类壁纸，一站渲染",
                               text: "支持 Wallpaper Engine 的场景、网页、视频三类壁纸，由专用引擎以独立进程渲染到桌面，兼顾画质与稳定。",
                               systemImage: "square.stack.3d.up",
                               imageColor: .purple)
                    NewSection(title: "下载与导入壁纸",
                               text: "通过 Steam 插件下载创意工坊壁纸，或导入本地壁纸文件夹、视频和 ZIP，统一保存在 motiscape 的默认壁纸库中。",
                               systemImage: "square.and.arrow.down",
                               footnote: plugins.plugins.contains(where: { $0.role == .steam }) ? nil : steamAvailabilityNotice)
                    NewSection(title: "简洁易用的界面",
                               text: "针对macOS优化的界面，上手无门槛。\n轻松导入，个性化，使用您的壁纸。",
                               systemImage: "macwindow.on.rectangle",
                               imageColor: .orange)
                    NewSection(title: "实时属性调节",
                               text: "根据壁纸自带的属性动态生成调节控件，音量、速度、颜色、开关等即改即生效。",
                               systemImage: "slider.horizontal.3",
                               imageColor: .green)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(appStoreAvailabilityNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tint(.accentColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("onboarding.appStoreAvailability")
                }
                HStack {
                    Toggle(L("不再显示"), isOn: $checked)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("onboarding.welcome.dontShowAgain")
                    Spacer()
                    Button {
                        globalSettingsViewModel.saveWelcomePreference(dontShowAgain: checked)
                        showingPrivacy = true
                    } label: {
                        Text(L("下一步"))
                            .frame(minWidth: 88)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.welcome.next")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .textSelection(.enabled)
        .frame(width: 600, height: 640)
        .background(Color.primary.opacity(0.035))
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, localization.locale)
    }

    private var steamAvailabilityNotice: AttributedString {
        let linkLabel = L("此网页")
        return linkedNotice(L("Steam 下载与浏览功能在 App Store 版本中不提供。有关详细信息，请查看%@。", linkLabel), linkLabel: linkLabel)
    }

    private var appStoreAvailabilityNotice: AttributedString {
        let linkLabel = L("这里")
        return linkedNotice(L("某些功能在 App Store 版本中不提供，如果您想要使用这些功能，请查看%@。", linkLabel), linkLabel: linkLabel)
    }

    private func linkedNotice(_ message: String, linkLabel: String) -> AttributedString {
        var notice = AttributedString(message)
        if let range = notice.range(of: linkLabel) {
            notice[range].link = PluginLinks.steamFeaturesInformationURL
            notice[range].underlineStyle = .single
        }
        return notice
    }

    private func goBack() {
        guidePage = guidePage.flatMap { current in OnboardingPage.availablePages.last { $0.rawValue < current.rawValue } }
        if guidePage == nil { showingPrivacy = true }
    }

    private func goNext() {
        guard let page = guidePage else { return }
        guidePage = OnboardingPage.availablePages.first { $0.rawValue > page.rawValue } ?? page
    }

    private func finish() {
        globalSettingsViewModel.finishWelcome(dontShowAgain: checked)
    }

}

extension FirstLaunchView {
    struct NewSection: View {
        @ObservedObject private var localization = MotiscapeLocalization.shared
        var title: String
        var text: String
        var textColor: Color = .primary
        var systemImage: String
        var imageColor: Color = .accentColor
        var footnote: AttributedString? = nil
        
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(imageColor)
                    .frame(width: 36, height: 36)
                    .background(imageColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(title))
                        .foregroundStyle(textColor)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L(text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .tint(.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                            .accessibilityIdentifier("onboarding.steamAvailability")
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: MotiscapeDesign.cardRadius))
        }
    }
}

extension AppDelegate {
    @objc func showQuickStartGuide() {
        openMainWindow()
        globalSettingsViewModel.presentWelcome()
    }

    @objc func resetFirstLaunch() {
        UserDefaults.standard.set(true, forKey: "IsFirstLaunch")
    }
}

struct FirstLaunchView_Previews: PreviewProvider {
    static var previews: some View {
        FirstLaunchView()
    }
}
