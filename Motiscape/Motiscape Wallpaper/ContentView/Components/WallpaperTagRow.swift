import SwiftUI

/// Keep each tag intact; overflow belongs to the row, not the tag's text.
struct WallpaperTagRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                content
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            // Editable tags have a delete button outside their top-right edge.
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
