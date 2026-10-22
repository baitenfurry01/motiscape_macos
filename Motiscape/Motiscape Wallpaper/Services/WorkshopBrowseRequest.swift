import Foundation

/// Immutable input shared by the view model, real API and controllable test service.
struct WorkshopBrowseRequest: Equatable, Codable {
    var text = ""
    var tags: Set<String> = []
    var sort: WorkshopSortOrder = .trending
    var types: Set<WorkshopTypeFilter> = [.all]
    var ageRating: WorkshopAgeRatingFilter = .default
    var widescreen: FRWidescreenResolution = .all
    var ultraWidescreen: FRUltraWidescreenResolution = .all
    var dualscreen: FRDualscreenResolution = .all
    var triplescreen: FRTriplescreenResolution = .all
    var portrait: FRPortraitScreenResolution = .all
    var misc: FRMiscResolution = .all
    var showOnly: FRShowOnly = .none
    var favoriteIDs: Set<String> = []
    var trendPeriod: WorkshopTrendPeriod = .week
    var page = 1
    var perPage = 50

    func hasSameFilters(as other: Self) -> Bool {
        var lhs = self; var rhs = other
        lhs.page = 1; rhs.page = 1
        if !lhs.showOnly.contains(.myFavourites) { lhs.favoriteIDs = [] }
        if !rhs.showOnly.contains(.myFavourites) { rhs.favoriteIDs = [] }
        return lhs == rhs
    }

    func matches(_ item: WorkshopItem) -> Bool {
        let selectable = Set(WorkshopTag.allCases.map { $0.rawValue.lowercased() })
        let normalizedTags = Set(tags.map { $0.lowercased() })
        let selected = normalizedTags.intersection(selectable)
        let itemTags = Set(item.tags.map { $0.lowercased() })
        let external = normalizedTags.subtracting(selectable)
        return types.matches(item) &&
            (ageRating.isEmpty || ageRating == .all || ageRating.contains(item.ageRating ?? .everyone)) &&
            (selected.isEmpty || selectable.isSubset(of: selected) || !selected.isDisjoint(with: itemTags)) &&
            external.isSubset(of: itemTags) &&
            showOnly.matches(workshopItem: item, favoriteIDs: favoriteIDs) &&
            FRResolutionFilter.matches(tags: item.tags, widescreen: widescreen, ultraWidescreen: ultraWidescreen,
                dualscreen: dualscreen, triplescreen: triplescreen, portrait: portrait, misc: misc)
    }
}

struct WorkshopBrowseResult: Codable {
    var items: [WorkshopItem]
    var total: Int
    var isTotalExact = true
    var creator: WorkshopCreator?
}

protocol WorkshopBrowsing {
    func browse(_ request: WorkshopBrowseRequest) async throws -> WorkshopBrowseResult
    func creatorFiles(steamId: String, page: Int, perPage: Int) async throws -> WorkshopBrowseResult
    func invalidateBrowseCache()
}

extension WorkshopBrowsing {
    func invalidateBrowseCache() {}
}

#if !STEAM_AGENT
extension SteamWebAPI: WorkshopBrowsing {
    func browse(_ request: WorkshopBrowseRequest) async throws -> WorkshopBrowseResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isASCIIID = !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) } && (UInt64(text) ?? 0) > 0
        if isASCIIID { invalidateBrowseCache() }
        if isASCIIID, text.count == 17, text.hasPrefix("7656119") {
            return WorkshopBrowseResult(items: [], total: 0, creator: await creatorProfile(steamId: text))
        }
        if isASCIIID {
            let details = try await getFileDetails(workshopIds: [text])
            let items = details.filter { $0.publishedFileId == text && $0.consumerAppId == 431960 && request.matches($0) }
            return WorkshopBrowseResult(items: items, total: items.count)
        }
        return try await queryFiles(searchText: text, tags: request.tags.sorted(), sortOrder: request.sort,
            typeFilters: request.types, ageRating: request.ageRating,
            widescreenResolution: request.widescreen, ultraWidescreenResolution: request.ultraWidescreen,
            dualscreenResolution: request.dualscreen, triplescreenResolution: request.triplescreen,
            portraitResolution: request.portrait, miscResolution: request.misc, showOnly: request.showOnly,
            favoriteIDs: request.favoriteIDs, page: request.page, perPage: request.perPage,
            trendDays: request.sort.usesTrendPeriod ? request.trendPeriod.rawValue : nil,
            reuseFilteredPages: true)
    }

    func creatorFiles(steamId: String, page: Int, perPage: Int) async throws -> WorkshopBrowseResult {
        let result = try await getUserFiles(steamId: steamId, page: page, perPage: perPage)
        return WorkshopBrowseResult(items: result.items, total: result.total)
    }
}
#endif

/// One bounded, short-lived scan per API instance. A lease prevents an older
/// request from restoring cache state after refresh or a newer query.
final class WorkshopFilteredPageCache {
    struct Snapshot: Codable {
        var cursor = "*"
        var seenCursors: Set<String> = []
        var seenIDs: Set<String> = []
        var items: [WorkshopItem] = []
        var exhausted = false
    }
    struct Lease {
        fileprivate let token: UUID
        let snapshot: Snapshot
    }
    private struct Entry {
        let filters: WorkshopBrowseRequest
        let parameters: [String: String]
        let endpoint: String
        let created: TimeInterval
        var snapshot: Snapshot
    }
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var token = UUID()
    private var entry: Entry?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        token = UUID(); entry = nil
    }

    func begin(filters: WorkshopBrowseRequest, parameters: [String: String], endpoint: String, restart: Bool) -> Lease {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        if restart || entry.map({
            !$0.filters.hasSameFilters(as: filters) || $0.parameters != parameters || $0.endpoint != endpoint ||
            time < $0.created || time - $0.created >= 60
        }) != false {
            entry = Entry(filters: filters, parameters: parameters, endpoint: endpoint, created: time, snapshot: Snapshot())
        }
        token = UUID()
        return Lease(token: token, snapshot: entry!.snapshot)
    }

    func commit(_ snapshot: Snapshot, lease: Lease) {
        // Bound retained data, not the query result. A larger scan still returns
        // its correct page but is not retained. No API credentials go to disk.
        let fits = snapshot.items.count <= 1_000 && snapshot.seenIDs.count <= 20_000 &&
            snapshot.seenCursors.count <= 200 &&
            ((try? JSONEncoder().encode(snapshot).count).map { $0 <= 8 * 1024 * 1024 } ?? false)
        lock.lock(); defer { lock.unlock() }
        guard token == lease.token else { return }
        if fits { entry?.snapshot = snapshot } else { entry = nil }
    }
}

enum FilePathScope {
    /// A path component boundary matters: Wallpapers-backup is not inside Wallpapers.
    /// This is a presentation classification, not a symlink/security authorization check.
    static func contains(_ path: String, directory: String) -> Bool {
        guard !directory.isEmpty else { return false }
        let base = (directory as NSString).standardizingPath
        let candidate = (path as NSString).standardizingPath
        return candidate == base || candidate.hasPrefix(base == "/" ? base : base + "/")
    }
}
