import SwiftUI

extension AppDelegate {
    @objc func showAboutUs() {
        globalSettingsViewModel.selection = 4
        openSettingsWindow()
    }
}

struct AboutUsView: View {
    @ObservedObject private var localization = MotiscapeLocalization.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.34"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? L("开发构建")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                    }
                    Text(verbatim: "motiscape")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text("macOS 动态壁纸引擎")
                        .foregroundStyle(.secondary)
                    Text(L("版本 %@（构建 %@）", version, build))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "BaiTenG").font(.headline)
                            Text("本项目开发者")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                }

                OpenSourceAcknowledgementsView()

                HStack(alignment: .top, spacing: 16) {
                    Text("本项目遵守 GPLv3 协议开源。")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "https://github.com/baitenfurry01/macwallpaperengine")!) {
                        Label("项目主页", systemImage: "arrow.up.right")
                    }
                }
                .font(.caption)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .textSelection(.enabled)
        .environment(\.locale, localization.locale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OpenSourceAcknowledgementsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("开源项目鸣谢", systemImage: "heart.text.clipboard")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(verbatim: "\(OpenSourceCredits.all.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel(L("%lld 个开源项目", OpenSourceCredits.all.count))
                }
                Text("感谢这些项目及其贡献者，为 motiscape 的应用、插件与渲染器提供支持。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(OpenSourceCreditGroup.allCases) { group in
                let credits = OpenSourceCredits.all.filter { $0.group == group }
                if !credits.isEmpty {
                    OpenSourceCreditSection(group: group, credits: credits)
                }
            }

            Text("点击项目名称访问主页，点击许可证查看原文。各组件遵循其各自许可证。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OpenSourceCreditSection: View {
    let group: OpenSourceCreditGroup
    let credits: [OpenSourceCredit]

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(credits) { credit in
                    if credit.id != credits.first?.id {
                        Divider()
                    }
                    OpenSourceCreditRow(credit: credit)
                }
            }
            .padding(.horizontal, 8)
        } label: {
            Label(L(group.title), systemImage: group.symbol)
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct OpenSourceCreditRow: View {
    let credit: OpenSourceCredit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: credit.projectURL) {
                HStack(spacing: 6) {
                    Text(verbatim: credit.name)
                        .font(.headline)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .help(L("访问 %@ 项目主页", credit.name))
            .accessibilityIdentifier("settings.about.project.\(credit.id)")

            Text(L(credit.purpose))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: credit.licenseURL) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "doc.text")
                        .accessibilityHidden(true)
                    Text(verbatim: credit.license)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
            .help(L("查看 %@ 的许可证", credit.name))
            .accessibilityLabel(L("%@ 的许可证：%@", credit.name, credit.license))
            .accessibilityIdentifier("settings.about.license.\(credit.id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }
}

struct AboutUsView_Previews: PreviewProvider {
    static var previews: some View { AboutUsView() }
}
