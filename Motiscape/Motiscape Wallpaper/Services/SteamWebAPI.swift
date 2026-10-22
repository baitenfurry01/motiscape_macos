import Foundation

/// Compatibility facade: existing UI/business callers retain their public API.
/// Only explicitly injected Debug fixtures may execute the local query backend.
final class SteamWebAPI {
    static let shared = SteamWebAPI()
    static func validatedKey(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil ? normalized : nil
    }
    static var hasBuiltInKey: Bool { SteamServiceManager.shared.hasBuiltInKey }
    #if DEBUG
    private let fixture: SteamWebAPIBackend?
    init(session: URLSession? = nil, apiKey: String? = nil, baseURL: String? = nil, throttleInterval: TimeInterval = 0.35) {
        fixture = session.map { SteamWebAPIBackend(session: $0, apiKey: apiKey, baseURL: baseURL, throttleInterval: throttleInterval) }
    }
    #else
    init() {}
    #endif
    func invalidateBrowseCache() {
        #if DEBUG
        if let fixture { fixture.invalidateBrowseCache(); return }
        #endif
        Task { @MainActor in let _: SteamAgentEmpty? = try? await SteamAgentClient.shared.call(.invalidateBrowse) }
    }
    func queryFiles(
        searchText: String = "",
        tags: [String] = [],
        sortOrder: WorkshopSortOrder = .trending,
        typeFilters: Set<WorkshopTypeFilter> = [.all],
        ageRating: WorkshopAgeRatingFilter = .all,
        widescreenResolution: FRWidescreenResolution = .all,
        ultraWidescreenResolution: FRUltraWidescreenResolution = .all,
        dualscreenResolution: FRDualscreenResolution = .all,
        triplescreenResolution: FRTriplescreenResolution = .all,
        portraitResolution: FRPortraitScreenResolution = .all,
        miscResolution: FRMiscResolution = .all,
        showOnly: FRShowOnly = .none,
        favoriteIDs: Set<String> = [],
        page: Int = 1,
        perPage: Int = 30,
        trendDays: Int? = nil,
        enrichCreatorProfiles: Bool = true,
        reuseFilteredPages: Bool = false
    ) async throws -> WorkshopBrowseResult {
        #if DEBUG
        if let fixture { return try await fixture.queryFiles(searchText: searchText, tags: tags, sortOrder: sortOrder, typeFilters: typeFilters, ageRating: ageRating, widescreenResolution: widescreenResolution, ultraWidescreenResolution: ultraWidescreenResolution, dualscreenResolution: dualscreenResolution, triplescreenResolution: triplescreenResolution, portraitResolution: portraitResolution, miscResolution: miscResolution, showOnly: showOnly, favoriteIDs: favoriteIDs, page: page, perPage: perPage, trendDays: trendDays, enrichCreatorProfiles: enrichCreatorProfiles, reuseFilteredPages: reuseFilteredPages) }
        #endif
        let request = WorkshopBrowseRequest(text: searchText, tags: Set(tags), sort: sortOrder, types: typeFilters,
            ageRating: ageRating, widescreen: widescreenResolution, ultraWidescreen: ultraWidescreenResolution,
            dualscreen: dualscreenResolution, triplescreen: triplescreenResolution, portrait: portraitResolution,
            misc: miscResolution, showOnly: showOnly, favoriteIDs: favoriteIDs, page: page, perPage: perPage)
        return try await SteamAgentClient.shared.call(.query(SteamBrowseQuery(request: request,
            enrichCreatorProfiles: enrichCreatorProfiles, reuseFilteredPages: reuseFilteredPages, trendDays: trendDays)))
    }

    func queryDiscoverFiles(
        searchText: String,
        sortOrder: WorkshopSortOrder,
        requiredTags: [String],
        excludedTags: [String],
        page: Int,
        perPage: Int,
        trendDays: Int?
    ) async throws -> (items: [WorkshopItem], total: Int) {
        #if DEBUG
        if let fixture { return try await fixture.queryDiscoverFiles(searchText: searchText, sortOrder: sortOrder, requiredTags: requiredTags, excludedTags: excludedTags, page: page, perPage: perPage, trendDays: trendDays) }
        #endif
        let result: SteamAgentPage = try await SteamAgentClient.shared.call(.discover(text: searchText, sort: sortOrder, required: requiredTags, excluded: excludedTags, page: page, count: perPage, days: trendDays))
        return (result.items, result.total)
    }

    func getFileDetails(
        workshopIds: [String],
        enrichCreatorProfiles: Bool = true
    ) async throws -> [WorkshopItem] {
        #if DEBUG
        if let fixture { return try await fixture.getFileDetails(workshopIds: workshopIds, enrichCreatorProfiles: enrichCreatorProfiles) }
        #endif
        return try await SteamAgentClient.shared.call(.details(ids: workshopIds, enrich: enrichCreatorProfiles))
    }

    func getUserFiles(
        steamId: String,
        page: Int = 1,
        perPage: Int = 30,
        sortMethod: String? = nil,
        requiredTags: [String] = [],
        excludedTags: [String] = [],
        enrichCreatorProfiles: Bool = true
    ) async throws -> (items: [WorkshopItem], total: Int) {
        #if DEBUG
        if let fixture { return try await fixture.getUserFiles(steamId: steamId, page: page, perPage: perPage, sortMethod: sortMethod, requiredTags: requiredTags, excludedTags: excludedTags, enrichCreatorProfiles: enrichCreatorProfiles) }
        #endif
        let result: SteamAgentPage = try await SteamAgentClient.shared.call(.userFiles(id: steamId, page: page, count: perPage, sort: sortMethod, required: requiredTags, excluded: excludedTags, enrich: enrichCreatorProfiles))
        return (result.items, result.total)
    }

    func getCollectionItems(
        collectionId: String,
        page: Int = 1,
        perPage: Int = 12
    ) async throws -> (items: [WorkshopItem], total: Int) {
        #if DEBUG
        if let fixture { return try await fixture.getCollectionItems(collectionId: collectionId, page: page, perPage: perPage) }
        #endif
        let result: SteamAgentPage = try await SteamAgentClient.shared.call(.collection(id: collectionId, page: page, count: perPage))
        return (result.items, result.total)
    }

    func creatorProfile(steamId: String) async -> WorkshopCreator? {
        #if DEBUG
        if let fixture { return await fixture.creatorProfile(steamId: steamId) }
        #endif
        return try? await SteamAgentClient.shared.call(.creator(steamId))
    }

    func enrichCreatorDetails(in items: [WorkshopItem]) async -> [WorkshopItem] {
        #if DEBUG
        if let fixture { return await fixture.enrichCreatorDetails(in: items) }
        #endif
        return (try? await SteamAgentClient.shared.call(.enrich(items))) ?? items
    }

    func downloadPreviewImage(url: URL) async throws -> Data {
        #if DEBUG
        if let fixture { return try await fixture.downloadPreviewImage(url: url) }
        #endif
        let result: SteamAgentPreview = try await SteamAgentClient.shared.call(.preview(url))
        return try await Task.detached { try Data(contentsOf: result.file, options: .mappedIfSafe) }.value
    }

    func fetchDiscover(
        category: WorkshopDiscoverCategory,
        period: WorkshopTrendPeriod,
        count: Int = 12
    ) async throws -> [WorkshopItem] {
        let sortOrder = category.sortOrder ?? .trending
        let result = try await queryFiles(
            tags: category.tag.map { [$0] } ?? [],
            sortOrder: sortOrder,
            page: 1,
            perPage: count,
            trendDays: category.usesTrendPeriod ? period.rawValue : nil,
            enrichCreatorProfiles: false
        )
        return result.items
    }

    func fetchTrending(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .trending, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchMostSubscribed(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .mostSubscribed, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchTopRated(count: Int = 10, ageRating: WorkshopAgeRatingFilter = .all) async throws -> [WorkshopItem] {
        let result = try await queryFiles(sortOrder: .topRated, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func fetchByTag(
        _ tag: String,
        sortOrder: WorkshopSortOrder = .trending,
        count: Int = 10,
        ageRating: WorkshopAgeRatingFilter = .all
    ) async throws -> [WorkshopItem] {
        let result = try await queryFiles(
            tags: [tag], sortOrder: sortOrder, ageRating: ageRating, page: 1, perPage: count)
        return result.items
    }

    func isItemDownloaded(_ workshopId: String) -> Bool {
        downloadedItemURL(workshopId) != nil
    }

    func downloadedItemURL(_ workshopId: String) -> URL? {
        let directory = WallpaperLibrary.shared.managedWorkshopDirectory.appending(path: workshopId)
        return FileManager.default.fileExists(atPath: directory.appending(path: "project.json").path)
            ? directory : nil
    }

}
