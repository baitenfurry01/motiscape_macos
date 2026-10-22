import SwiftUI

struct SteamAPIKeySettingsFields: View {
    @Binding var apiKey: String
    let hasBuiltInKey: Bool
    var isSettingsPresented = true
    @State private var isAPIKeyVisible = false
    private var apiKeyIsEmpty: Bool { apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isValid: Bool { SteamWebAPI.validatedKey(apiKey) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isValid {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: apiKeyIsEmpty ? "info.circle" : "exclamationmark.triangle.fill")
                        .font(.body)
                        .foregroundStyle(apiKeyIsEmpty ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(apiKeyIsEmpty ? "请设置您自己的 Steam Web API Key" : "Steam Web API Key 格式无效"))
                            .font(.callout)
                            .bold()
                        Text(L(SteamAPIKeyGuidance(hasBuiltInKey: hasBuiltInKey)
                            .settingsMessage(isCustomEmpty: apiKeyIsEmpty)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

            HStack {
                Group {
                    if isAPIKeyVisible {
                        TextField("Steam Web API Key", text: $apiKey)
                    } else {
                        SecureField("Steam Web API Key", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("settings.steamAPIKey.field")

                Button {
                    isAPIKeyVisible.toggle()
                } label: {
                    Label(L(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key"),
                          systemImage: isAPIKeyVisible ? "eye.slash" : "eye")
                }
                .labelStyle(.iconOnly)
                .help(L(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key"))
                .accessibilityIdentifier("settings.steamAPIKey.visibility")
            }
            if isValid {
                Label("已设置专属 API Key", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text("可前往 [Steam API Key 申请页面](https://steamcommunity.com/dev/apikey) 申请，并按页面要求填写域名。Key 仅用于 Motiscape 在本机请求创意工坊浏览数据，请勿分享。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear { isAPIKeyVisible = false }
        .onChange(of: isSettingsPresented) { _, _ in isAPIKeyVisible = false }
    }
}
