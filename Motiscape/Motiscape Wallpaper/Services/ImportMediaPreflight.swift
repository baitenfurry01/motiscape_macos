import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ImportMetadataError: LocalizedError {
    case title, tags, cover, video, timeout
    var errorDescription: String? {
        switch self {
        case .title: return L("标题不能为空，且不能超过 256 个字符或包含控制字符。")
        case .tags: return L("最多 32 个标签，每个不超过 64 个字符；请用逗号分隔。")
        case .cover: return L("封面无效：请选择不超过 20 MiB、8000 万像素的图片。")
        case .video: return L("无法读取有效视频或解码首帧；文件可能损坏、仅含音频或受保护。")
        case .timeout: return L("视频预检超时，请检查文件后重试。")
        }
    }
}

enum ImportCoverEdit: Sendable {
    case original, remove, custom(Data)
}

struct ImportVideoInfo: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Float
    let thumbnail: Data?
    let warning: String?
}

enum ImportMediaPreflight {
    static func title(_ text: String) throws -> String {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 256,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportMetadataError.title
        }
        return title
    }

    static func tags(_ text: String) throws -> [String] {
        guard text.utf8.count <= 16_384 else { throw ImportMetadataError.tags }
        var tags: [String] = [], seen = Set<String>()
        for part in text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n")) {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tag.count <= 64, !tag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ImportMetadataError.tags
            }
            if !tag.isEmpty, seen.insert(tag.precomposedStringWithCanonicalMapping.lowercased()).inserted { tags.append(tag) }
        }
        guard tags.count <= 32 else { throw ImportMetadataError.tags }
        return tags
    }

    static func cover(at url: URL, maximumDimension: Int = 1600) throws -> Data {
        guard url.isFileURL else { throw ImportMetadataError.cover }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ImportMetadataError.cover }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= 20 * 1024 * 1024 else { throw ImportMetadataError.cover }
        let data = try file.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 20 * 1024 * 1024 else { throw ImportMetadataError.cover }
        return try cover(data: data, maximumDimension: maximumDimension)
    }

    static func cover(data: Data, maximumDimension: Int = 1600) throws -> Data {
        try Task.checkCancellation()
        guard maximumDimension > 0, maximumDimension <= 1600, !data.isEmpty, data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 80_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { throw ImportMetadataError.cover }
        try Task.checkCancellation()
        return try jpeg(image)
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportMetadataError.cover
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else { throw ImportMetadataError.cover }
        return data as Data
    }

    static func video(at url: URL, timeoutSeconds: Double = 30) async throws -> ImportVideoInfo {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw ImportMetadataError.timeout }
        guard url.isFileURL else { throw ImportMetadataError.video }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ImportMetadataError.video }
        #if DEBUG
        if let info = try await AppFrameCancellationFixture.probeIfRequested(url) { return info }
        #endif
        return try await video(asset: AVURLAsset(url: url), timeoutSeconds: timeoutSeconds)
    }

    /// Shared AVFoundation probe. Production callers use the validated local-file
    /// entry above; integration tests can supply an asset with a controlled
    /// resource loader to exercise actual outstanding media I/O cancellation.
    static func video(asset: AVURLAsset, timeoutSeconds: Double = 30,
                      willGenerateFirstFrame: (@Sendable () -> Void)? = nil) async throws -> ImportVideoInfo {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw ImportMetadataError.timeout }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        // A native decoder failure can finish the worker before task-group
        // cancellation, leaving its input request outstanding. The handler
        // below covers active cancellation; this covers every return/throw.
        defer { asset.cancelLoading(); generator.cancelAllCGImageGeneration() }
        do {
            return try await withThrowingTaskGroup(of: ImportVideoInfo.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        let duration = try await asset.load(.duration).seconds
                        let protected = try await asset.load(.hasProtectedContent)
                        guard !protected, duration.isFinite, duration > 0,
                              let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportMetadataError.video }
                        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                        let displaySize = size.applying(transform)
                        let width = abs(displaySize.width), height = abs(displaySize.height)
                        guard width.isFinite, height.isFinite, width > 0, height > 0,
                              width <= 32768, height <= 32768 else { throw ImportMetadataError.video }
                        let playable = try await asset.load(.isPlayable)
                        var thumbnail: Data?
                        if playable {
                            // Observation only: tests can arm their resource loader
                            // after metadata is ready. No alternate decode path.
                            willGenerateFirstFrame?()
                            let frame = try await generator.image(at: .zero)
                            thumbnail = try jpeg(frame.image)
                        }
                        try Task.checkCancellation()
                        return ImportVideoInfo(duration: duration, width: Int(width.rounded()), height: Int(height.rounded()),
                            frameRate: fps.isFinite ? max(0, fps) : 0, thumbnail: thumbnail,
                            warning: playable ? nil : L("系统无法预览此编码，导入后可能需要转码；尚未验证完整播放。"))
                    } onCancel: {
                        asset.cancelLoading(); generator.cancelAllCGImageGeneration()
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(0, timeoutSeconds)))
                    throw ImportMetadataError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ImportMetadataError.video }
                return result
            }
        } catch {
            #if DEBUG
            if AppIntegrationFixture.frameCancellationSource != nil {
                let failure = error as NSError
                AppIntegrationFixture.record("frame-ui-native-error", fields: ["domain": failure.domain,
                    "code": String(failure.code), "description": String(describing: failure), "cancelled": String(Task.isCancelled)])
            }
            #endif
            if Task.isCancelled { throw CancellationError() }
            if error is ImportMetadataError { throw error }
            throw ImportMetadataError.video
        }
    }
}
