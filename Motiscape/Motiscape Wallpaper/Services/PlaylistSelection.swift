import SwiftUI

/// Draft selection is separate from the saved playlist until confirmation.
struct PlaylistSelection {
    private(set) var ids: [String] = []

    func number(for id: String) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { remove(id) } else { ids.append(id) }
    }

    mutating func remove(_ id: String) {
        ids.removeAll { $0 == id }
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ ids.indices.contains($0) }),
              (0...ids.count).contains(destination) else { return }
        ids.move(fromOffsets: offsets, toOffset: destination)
    }

    mutating func retain(available: Set<String>) {
        ids.removeAll { !available.contains($0) }
    }

    mutating func drop(_ sourceID: String, relativeTo targetID: String, after: Bool) {
        guard let source = ids.firstIndex(of: sourceID),
              let target = ids.firstIndex(of: targetID), source != target else { return }
        move(from: IndexSet(integer: source), to: target + (after ? 1 : 0))
    }
}

enum PlaylistLibraryFilter: CaseIterable {
    case all, scene, web, video

    var title: String {
        switch self {
        case .all: return L("全部")
        case .scene: return L("场景")
        case .web: return L("网页")
        case .video: return L("视频")
        }
    }

    func includes(_ wallpaper: WEWallpaper, search: String) -> Bool {
        let matchesType: Bool
        switch self {
        case .all: matchesType = true
        case .scene: matchesType = wallpaper.kind == .scene
        case .web: matchesType = wallpaper.kind == .web
        case .video: matchesType = wallpaper.kind == .video
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesType && (query.isEmpty || wallpaper.project.title.localizedStandardContains(query))
    }
}
