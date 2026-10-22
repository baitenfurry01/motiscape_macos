import Foundation

enum WallpaperKind: String {
    case scene, web, video, unsupported

    init(rawType: String) {
        switch rawType.lowercased() {
        case "scene": self = .scene
        case "web": self = .web
        case "video": self = .video
        default: self = .unsupported
        }
    }

    var displayName: String {
        switch self {
        case .scene: return L("场景")
        case .web: return L("网页")
        case .video: return L("视频")
        case .unsupported: return L("不支持")
        }
    }
}
