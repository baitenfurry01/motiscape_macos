import SwiftUI

struct PrivacyPolicyView: View {
    let onBack: () -> Void
    let onAgree: () -> Void
    @ObservedObject private var localization = MotiscapeLocalization.shared

    private var policy: String? { PrivacyPolicy.text(language: localization.locale.identifier) }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("隐私声明"))
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            Divider()
            ScrollView {
                if let policy {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(policy.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                            paragraph(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(32)
                    .textSelection(.enabled)
                } else {
                    Text(L("无法读取隐私声明，请重新打开 App 后重试。"))
                        .padding(32)
                }
            }
            .id(localization.locale.identifier)
            .accessibilityIdentifier("onboarding.privacy.content")
            Divider()
            HStack(spacing: 16) {
                Button(L("上一步"), action: onBack)
                    .accessibilityIdentifier("onboarding.privacy.back")
                Spacer()
                Text(L("第 %d 页，共 %d 页", 2, OnboardingPage.availablePages.count + 2))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L("同意")) {
                    guard policy != nil else { return }
                    onAgree()
                }
                .buttonStyle(.borderedProminent)
                .disabled(policy == nil)
                .accessibilityIdentifier("onboarding.privacy.agree")
            }
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .frame(width: 920, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func paragraph(_ raw: String) -> some View {
        let block = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = block.hasPrefix("### ") ? 3 : (block.hasPrefix("## ") ? 2 : (block.hasPrefix("# ") ? 1 : 0))
        let body = level == 0 ? block : String(block.dropFirst(level + 1))
        let text = (try? AttributedString(markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
        return Text(text)
            .font(level == 1 ? .title.bold() : (level == 2 ? .title3.bold() : (level == 3 ? .headline : .body)))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(level == 0 ? [] : .isHeader)
    }
}
