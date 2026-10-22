import SwiftUI

struct WorkshopItemCard: View {
    var item: WorkshopItem
    @State private var isHovered = false
    var isSelected: Bool
    var isDownloaded: Bool
    var presetNeedsDependency: Bool
    var downloadTask: DownloadTask?

    private var downloadState: DownloadState? { isActive ? downloadTask?.state : nil }
    var isFavorite: Bool = false
    var isActive: Bool = true
    var animatedPreviewMode: GSAnimatedPreviewPlayback = .hover

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkshopImage(
                url: item.previewImageURL,
                contentMode: .fill,
                isAnimating: isActive && (isHovered || isSelected ||
                    animatedPreviewMode == .visible),
                isLoadingEnabled: isActive,
                preloadsWhenInactive: false
            )
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipped()
        .overlay {
            GeometryReader { proxy in
                topBadges
                    .frame(width: max(0, proxy.size.width - 16), alignment: .leading)
                    .padding(8)
            }
            .allowsHitTesting(false)
        }
            captionStrip
        }
        .frame(maxWidth: .infinity)
        .modifier(WallpaperCardSurface(selected: isSelected, hovered: isHovered))
        .onHover { isHovered = $0 }
        .help(item.title)
    }

    private var captionStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 10) {
                Label(item.formattedSubscriptions, systemImage: "arrow.down.circle.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text(item.displayTypeName)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topBadges: some View {
        VStack {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    leadingBadges
                    Spacer(minLength: 6)
                    statusBadge
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 5) {
                    leadingBadges
                    statusBadge
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var leadingBadges: some View {
        VStack(alignment: .leading, spacing: 5) {
            if item.isPreset {
                Label("预设", systemImage: "slider.horizontal.3")
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.purple, in: Capsule())
                    .foregroundStyle(.white)
            }
            ageRatingBadge
        }
    }

    /// Only restricted ratings are called out; badging every all-ages wallpaper
    /// would mark almost the whole grid.
    @ViewBuilder
    private var ageRatingBadge: some View {
        if let rating = item.ageRating, rating != .everyone {
            Text(rating.displayName)
                .font(.caption2.bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(rating == .mature ? .red : .orange, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let state = downloadState, !(presetNeedsDependency && state == .completed) {
            downloadBadge(state)
                .fixedSize()
        } else if isDownloaded {
            HStack(spacing: 3) {
                Image(systemName: presetNeedsDependency ? "exclamationmark.triangle.fill" : "checkmark")
                    .font(.caption2).bold()
                Text(LocalizedStringKey(presetNeedsDependency ? "缺少基础壁纸" : "已下载"))
                    .font(.caption2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(presetNeedsDependency ? .orange : .green, in: Capsule())
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .scene: return .purple
        case .web: return .orange
        case .video: return .blue
        case .unsupported: return .gray
        }
    }

    @ViewBuilder
    private func downloadBadge(_ state: DownloadState) -> some View {
        switch state {
        case .downloading(let progress):
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                        .frame(width: 14, height: 14)
                    Circle()
                        .trim(from: 0, to: progress.fraction)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(-90))
                }
                Text("\(Int(progress.fraction * 100))%")
                    .font(.caption2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.blue, in: Capsule())
            .foregroundStyle(.white)
        case .queued:
            badge("排队中", systemImage: "clock", color: .orange)
        case .resolving, .validating:
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text("处理中").font(.caption2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.blue, in: Capsule())
            .foregroundStyle(.white)
        case .failed:
            badge("失败", systemImage: "exclamationmark.triangle", color: .red)
        case .paused:
            badge("已暂停", systemImage: "pause", color: .orange)
        case .cancelled:
            badge("下载已取消", systemImage: "xmark", color: .secondary)
        case .waitingForLogin:
            badge("等待 Steam 登录后开始下载", systemImage: "person.crop.circle", color: .orange)
        case .completed:
            badge("已下载", systemImage: "checkmark", color: .green)
        }
    }

    private func badge(_ text: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color, in: Capsule())
        .foregroundStyle(.white)
    }
}
