import SwiftUI
import Foundation

/// Existing network view models expose display strings rather than Error values.
/// Keep the original error and add guidance only for a timeout, not every failure.
enum NetworkErrorPresentation {
    static func isTimeout(_ message: String) -> Bool {
        let normalized = message.lowercased()
        // Expired authentication challenges are not network timeouts.
        if normalized.contains("steam guard") || normalized.contains("验证码") || normalized.contains("驗證碼") {
            return false
        }
        let timeout = URLError(.timedOut).localizedDescription.lowercased()
        return (!timeout.isEmpty && normalized.contains(timeout)) ||
            ["请求超时", "請求超時", "要求逾時", "連線逾時", "超时", "超時", "逾時", "timed out", "timeout", "time-out"]
                .contains(where: normalized.contains)
    }
}

struct NetworkErrorText: View {
    let message: String
    @Environment(\.multilineTextAlignment) private var textAlignment
    @ObservedObject private var localization = MotiscapeLocalization.shared

    init(_ message: String) { self.message = message }

    private var alignment: HorizontalAlignment {
        switch textAlignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }
    var body: some View {
        if NetworkErrorPresentation.isTimeout(message) {
            VStack(alignment: alignment, spacing: 4) {
                Text(message)
                Text(L("请检查代理或网络连接"))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.red)
        } else {
            Text(message)
        }
    }
}
