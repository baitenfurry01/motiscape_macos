import AppKit
import SwiftUI

/// AsyncImage-compatible presentation, with Steam resource fetching owned by the Agent.
struct SteamAgentImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @State private var phase = AsyncImagePhase.empty

    var body: some View {
        content(phase).task(id: url) {
            phase = .empty
            guard let url else { return }
            do {
                let data = try await SteamWebAPI.shared.downloadPreviewImage(url: url)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else { throw SteamAPIError.invalidResponse }
                phase = .success(Image(nsImage: image))
            } catch {
                if !Task.isCancelled { phase = .failure(error) }
            }
        }
    }
}
