import SwiftUI

struct ProjectFeedbackBanner: View {
    var showsActions = true

    private let issuesURL = URL(string: "https://github.com/baitenfurry01/macwallpaperengine/issues/new/choose")!

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Motiscape 仍处于早期阶段")
                    .font(.headline)
                Text("遇到问题请在 GitHub 提交 Issue，并附上复现步骤。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if showsActions {
                Link(destination: issuesURL) {
                    Label("提交 Issue", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)

            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.45))
        }
    }
}
