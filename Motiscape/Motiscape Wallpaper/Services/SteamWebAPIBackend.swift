#if STEAM_AGENT || DEBUG
//
//  Motiscape Wallpaper
//
//

import Foundation

final class SteamWebAPIBackend {
    static let shared = SteamWebAPIBackend()

    static func validatedKey(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil ? normalized : nil
    }

    private static let builtInKey: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "MotiscapeSteamWebAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return validatedKey(value) ?? ""
    }()
    static var hasBuiltInKey: Bool { !builtInKey.isEmpty }
    private var apiKey: String {
        if let overrideKey { return overrideKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Self.builtInKey
    }
    private let appId = "431960"
    private let session: URLSession
    private let overrideKey: String?
    private let overrideBaseURL: String?
    private let requestThrottle: SteamRequestThrottle
    private let filteredPageCache = WorkshopFilteredPageCache()

    func invalidateBrowseCache() { filteredPageCache.invalidate() }

    init(session: URLSession? = nil, apiKey: String? = nil, baseURL: String? = nil,
         throttleInterval: TimeInterval = 0.35, proxy: AppHTTPProxy? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        (proxy ?? AppHTTPProxy.runtime).configure(configuration)
        self.session = session ?? URLSession(configuration: configuration)
        self.overrideKey = apiKey
        self.overrideBaseURL = baseURL
        self.requestThrottle = SteamRequestThrottle(interval: max(0, throttleInterval))
    }
    private let decoder = JSONDecoder()
    private let imageCache = NSCache<NSString, CacheEntry>()
    private let creatorCache = NSCache<NSString, CreatorCacheEntry>()

    private static let officialBase = "https://api.steampowered.com/"
    private static let mirrorBase = "https://steams.524228.xyz/"

    private var baseURL: String {
        if let overrideBaseURL { return overrideBaseURL }
        return Self.officialBase
    }

    private let cacheDirectory: URL = {
        let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "motiscape/WorkshopCache")
        #if STEAM_AGENT
        let dir = defaultDirectory
        #else
        let dir = AppIntegrationFixture.supportDirectory?.appending(path: "WorkshopCache") ?? defaultDirectory
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    final class CacheEntry {
        let data: Data
        let date: Date
        init(data: Data) {
            self.data = data
            self.date = Date()
        }
    }

    final class CreatorCacheEntry {
        let creator: WorkshopCreator
        let date: Date

        init(creator: WorkshopCreator) {
            self.creator = creator
            self.date = Date()
        }
    }

    // MARK: - Query Workshop Files

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
        try Task.checkCancellation()
        let queryEndpoint = baseURL
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: String] = [
            "key": apiKey,
            "query_type": "\(sortOrder.apiValue)",
            "appid": appId,
            "filetype": "18",
            "return_tags": "true",
            "return_previews": "true",
            "return_metadata": "true",
            "strip_description_bbcode": "true",
            "match_all_tags": "true",
        ]

        if sortOrder.usesTrendPeriod {
            let days = min(WorkshopTrendPeriod.year.rawValue,
                           max(1, trendDays ?? WorkshopTrendPeriod.week.rawValue))
            params["days"] = "\(days)"
        }

        if !normalizedSearchText.isEmpty {
            params["search_text"] = normalizedSearchText
        }

        let selectableTags = Set(WorkshopTag.allCases.map(\.rawValue))
        let canonicalTags = Dictionary(uniqueKeysWithValues: selectableTags.map { ($0.lowercased(), $0) })
        let requestedTags = Set(tags.map { tag in
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            return canonicalTags[normalized.lowercased()] ?? normalized
        }.filter { !$0.isEmpty })
        let selectedSelectableTags = requestedTags.intersection(selectableTags)
        let activeSelectedTags = selectableTags.isSubset(of: selectedSelectableTags)
            ? Set<String>()
            : selectedSelectableTags
        let selectedTagKeys = Set(activeSelectedTags.map { $0.lowercased() })
        let baseTags = requestedTags.filter { !selectableTags.contains($0) }.sorted()
        var allTags = baseTags
        if activeSelectedTags.count == 1, let selectedTag = activeSelectedTags.first {
            allTags.append(selectedTag)
        }
        let requestedTypes = typeFilters.normalizedWorkshopTypes
        let filterTypesLocally = !requestedTypes.hasNoWorkshopTypeConstraint &&
            requestedTypes.singleWorkshopType == nil
        if let typeTag = requestedTypes.singleWorkshopType?.steamTag {
            allTags.append(typeTag)
        }
        let selectedRatings = ageRating.selectedRatings
        let hasEveryone = selectedRatings.contains(WorkshopAgeRating.everyone)
        var filterRatingsLocally = false

        if selectedRatings.count == 1 && !hasEveryone {
            allTags.append(selectedRatings[0].steamTag)
        } else if selectedRatings.count == 2 && !hasEveryone {
            filterRatingsLocally = true
        } else {
            let excluded = ageRating.excludedRatings
            for (index, rating) in excluded.enumerated() {
                params["excludedtags[\(index)]"] = rating.steamTag
            }
        }

        let resolutionTags = FRResolutionFilter.selectedSteamTags(
            widescreen: widescreenResolution,
            ultraWidescreen: ultraWidescreenResolution,
            dualscreen: dualscreenResolution,
            triplescreen: triplescreenResolution,
            portrait: portraitResolution,
            misc: miscResolution
        )
        if resolutionTags?.isEmpty == true {
            if reuseFilteredPages { invalidateBrowseCache() }
            return WorkshopBrowseResult(items: [], total: 0)
        }
        let filterFavoritesLocally = showOnly.contains(.myFavourites)
        if filterFavoritesLocally && favoriteIDs.isEmpty {
            if reuseFilteredPages { invalidateBrowseCache() }
            return WorkshopBrowseResult(items: [], total: 0)
        }
        var filterResolutionLocally = false
        if let resolutionTags {
            if resolutionTags.count == 1 {
                allTags.append(resolutionTags[0])
            } else {
                filterResolutionLocally = true
            }
        }

        for tag in showOnly.requiredSteamTags where !allTags.contains(where: {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }) {
            allTags.append(tag)
        }
        let filterTagsLocally = activeSelectedTags.count > 1 && !allTags.isEmpty
        for (index, tag) in allTags.enumerated() {
            params["requiredtags[\(index)]"] = tag
        }
        let requestedPage = max(1, min(page, 1000))
        let requestedPageSize = max(1, min(perPage, 100))
        if activeSelectedTags.count > 1 && !filterTagsLocally {
            params["match_all_tags"] = "false"
            for (index, tag) in activeSelectedTags.sorted().enumerated() {
                params["requiredtags[\(index)]"] = tag
            }
        }
        let resultItems: [WorkshopItem]
        let resultTotal: Int
        var isTotalExact = true
        if filterTagsLocally || filterTypesLocally || filterRatingsLocally || filterResolutionLocally || filterFavoritesLocally {
            let filters = WorkshopBrowseRequest(text: normalizedSearchText, tags: requestedTags, sort: sortOrder,
                types: requestedTypes, ageRating: ageRating, widescreen: widescreenResolution,
                ultraWidescreen: ultraWidescreenResolution, dualscreen: dualscreenResolution,
                triplescreen: triplescreenResolution, portrait: portraitResolution, misc: miscResolution,
                showOnly: showOnly, favoriteIDs: favoriteIDs, perPage: requestedPageSize)
            let lease = reuseFilteredPages ? filteredPageCache.begin(filters: filters, parameters: params,
                endpoint: queryEndpoint, restart: requestedPage == 1) : nil
            var scan = lease?.snapshot ?? WorkshopFilteredPageCache.Snapshot()
            let requestedEnd = requestedPage * requestedPageSize
            while !scan.exhausted && scan.items.count < requestedEnd + 1 {
                try Task.checkCancellation()
                guard scan.seenCursors.insert(scan.cursor).inserted else { throw SteamAPIError.invalidResponse }
                guard scan.seenCursors.count <= 200 else { throw SteamAPIError.filterScanLimit }
                var cursorParams = params
                cursorParams["numperpage"] = "100"
                cursorParams["cursor"] = scan.cursor
                let batch = try await fetchQueryBatch(params: cursorParams, endpoint: queryEndpoint)
                try Task.checkCancellation()
                let matches = batch.items.filter { item in
                    scan.seenIDs.insert(item.id).inserted &&
                        (!filterTagsLocally || item.tags.contains { selectedTagKeys.contains($0.lowercased()) }) &&
                        (!filterTypesLocally || requestedTypes.matches(item)) &&
                        (!filterRatingsLocally || item.ageRating.map(selectedRatings.contains) == true) &&
                        (!filterResolutionLocally || FRResolutionFilter.matches(
                            tags: item.tags,
                            widescreen: widescreenResolution,
                            ultraWidescreen: ultraWidescreenResolution,
                            dualscreen: dualscreenResolution,
                            triplescreen: triplescreenResolution,
                            portrait: portraitResolution,
                            misc: miscResolution
                        )) &&
                        (!filterFavoritesLocally || favoriteIDs.contains(item.publishedFileId))
                }
                scan.items.append(contentsOf: matches)
                guard let nextCursor = batch.nextCursor,
                      !nextCursor.isEmpty,
                      batch.rawCount > 0 else {
                    scan.exhausted = true
                    break
                }
                scan.cursor = nextCursor
            }
            try Task.checkCancellation()
            if let lease { filteredPageCache.commit(scan, lease: lease) }
            let start = (requestedPage - 1) * requestedPageSize
            if start < scan.items.count {
                let end = min(start + requestedPageSize, scan.items.count)
                resultItems = Array(scan.items[start..<end])
            } else {
                resultItems = []
            }
            resultTotal = scan.exhausted ? scan.items.count : max(scan.items.count, requestedEnd + 1)
            isTotalExact = scan.exhausted
        } else {
            if reuseFilteredPages { invalidateBrowseCache() }
            params["page"] = "\(requestedPage)"
            params["numperpage"] = "\(requestedPageSize)"
            let batch = try await fetchQueryBatch(params: params, endpoint: queryEndpoint)
            resultItems = batch.items
            resultTotal = batch.total
        }

        let items = enrichCreatorProfiles ? await enrichCreators(in: resultItems) : resultItems
        return WorkshopBrowseResult(items: items, total: resultTotal, isTotalExact: isTotalExact)
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
        var params: [String: String] = [
            "key": apiKey,
            "query_type": "\(sortOrder.apiValue)",
            "appid": appId,
            "filetype": "18",
            "page": "\(max(1, page))",
            "numperpage": "\(max(1, perPage))",
            "return_tags": "true",
            "return_previews": "true",
            "return_metadata": "true",
            "strip_description_bbcode": "true",
            "match_all_tags": "true"
        ]
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSearch.isEmpty {
            params["search_text"] = normalizedSearch
        }
        if sortOrder.usesTrendPeriod, let trendDays {
            params["days"] = "\(max(1, min(365, trendDays)))"
        }
        for (index, tag) in requiredTags.enumerated() {
            params["requiredtags[\(index)]"] = tag
        }
        for (index, tag) in excludedTags.enumerated() {
            params["excludedtags[\(index)]"] = tag
        }
        let batch = try await fetchQueryBatch(params: params)
        return (batch.items, batch.total)
    }

    private func fetchQueryBatch(
        params: [String: String], endpoint: String? = nil
    ) async throws -> (items: [WorkshopItem], total: Int, nextCursor: String?, rawCount: Int) {
        try Task.checkCancellation()
        guard !(params["key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SteamAPIError.missingAPIKey
        }
        try await throttle()
        var components = URLComponents(string: (endpoint ?? baseURL) + "IPublishedFileService/QueryFiles/v1/")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw SteamAPIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw SteamAPIError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)
        let decodedItems = apiResponse.response.publishedfiledetails?.map { $0.toWorkshopItem() } ?? []
        var seen = Set<String>()
        let items = decodedItems.filter { !$0.id.isEmpty && $0.fileSize > 0 && seen.insert($0.id).inserted }
        return (items, max(0, apiResponse.response.total ?? items.count), apiResponse.response.next_cursor, decodedItems.count)
    }

    // MARK: - Get File Details

    func getFileDetails(
        workshopIds: [String],
        enrichCreatorProfiles: Bool = true
    ) async throws -> [WorkshopItem] {
        try await throttle()

        let components = URLComponents(string: baseURL + "ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

        var bodyParams = "itemcount=\(workshopIds.count)"
        for (index, id) in workshopIds.enumerated() {
            bodyParams += "&publishedfileids[\(index)]=\(id)"
        }

        guard let url = components.url else {
            throw SteamAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyParams.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SteamAPIError.httpError(httpResponse.statusCode)
        }

        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)
        let items = (apiResponse.response.publishedfiledetails ?? [])
            .filter { $0.result == nil || $0.result == 1 }
            .map { $0.toWorkshopItem() }
            .filter { $0.fileSize > 0 }
        return enrichCreatorProfiles ? await enrichCreators(in: items) : items
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
        try Task.checkCancellation()
        let key = apiKey
        guard !key.isEmpty else { throw SteamAPIError.missingAPIKey }
        try await throttle()
        var components = URLComponents(string: baseURL + "IPublishedFileService/GetUserFiles/v1/")!
        var queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "steamid", value: steamId),
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "numperpage", value: "\(perPage)"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_previews", value: "true"),
            URLQueryItem(name: "return_metadata", value: "true"),
            URLQueryItem(name: "strip_description_bbcode", value: "true"),
        ]
        if let sortMethod, !sortMethod.isEmpty {
            queryItems.append(URLQueryItem(name: "sortmethod", value: sortMethod))
        }
        for (index, tag) in requiredTags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in excludedTags.enumerated() {
            queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw SteamAPIError.invalidURL }
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw SteamAPIError.invalidResponse }
        guard httpResponse.statusCode == 200 else { throw SteamAPIError.httpError(httpResponse.statusCode) }
        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)
        let decodedItems = apiResponse.response.publishedfiledetails?.map { $0.toWorkshopItem() } ?? []
        let visibleItems = decodedItems.filter { $0.fileSize > 0 }
        let items = enrichCreatorProfiles ? await enrichCreators(in: visibleItems) : visibleItems
        let total = apiResponse.response.total ?? items.count
        return (items, total)
    }

    func getCollectionItems(
        collectionId: String,
        page: Int = 1,
        perPage: Int = 12
    ) async throws -> (items: [WorkshopItem], total: Int) {
        try await throttle()
        let components = URLComponents(string: baseURL + "ISteamRemoteStorage/GetCollectionDetails/v1/")!
        guard let url = components.url else { throw SteamAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "collectioncount=1&publishedfileids[0]=\(collectionId)".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw SteamAPIError.invalidResponse }
        guard httpResponse.statusCode == 200 else { throw SteamAPIError.httpError(httpResponse.statusCode) }
        let decoded = try decoder.decode(SteamCollectionResponse.self, from: data)
        guard let details = decoded.response.collectiondetails?.first,
              details.result == 1 else { return ([], 0) }
        let ids = (details.children ?? [])
            .sorted { ($0.sortorder ?? 0) < ($1.sortorder ?? 0) }
            .compactMap(\.publishedfileid)
        let start = max(0, (max(1, page) - 1) * max(1, perPage))
        guard start < ids.count else { return ([], ids.count) }
        let end = min(ids.count, start + max(1, perPage))
        let items = try await getFileDetails(
            workshopIds: Array(ids[start..<end]),
            enrichCreatorProfiles: false
        )
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return (items.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }, ids.count)
    }

    func creatorProfile(steamId: String) async -> WorkshopCreator? {
        let normalized = steamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let cached = cachedCreator(steamId: normalized) {
            return cached
        }
        let profiles = try? await fetchCreatorProfiles(steamIds: [normalized])
        return profiles?[normalized]
    }

    // MARK: - Trending / Featured

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

    func enrichCreatorDetails(in items: [WorkshopItem]) async -> [WorkshopItem] {
        await enrichCreators(in: items)
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

    // MARK: - Image Download

    func downloadPreviewImage(url: URL) async throws -> Data {
        let cacheKey = NSString(string: url.absoluteString)

        if let cached = imageCache.object(forKey: cacheKey),
           Date().timeIntervalSince(cached.date) < 300 {
            return cached.data
        }

        let diskPath = cacheDirectory.appending(path: url.absoluteString.hash.description + ".gif")
        if let diskData = try? Data(contentsOf: diskPath) {
            let entry = CacheEntry(data: diskData)
            imageCache.setObject(entry, forKey: cacheKey)
            return diskData
        }

        let (data, _) = try await session.data(from: url)

        let entry = CacheEntry(data: data)
        imageCache.setObject(entry, forKey: cacheKey)

        try? data.write(to: diskPath, options: .atomic)

        return data
    }

    // MARK: - Throttle

    private func throttle() async throws {
        try await requestThrottle.wait()
    }

    private func enrichCreators(in items: [WorkshopItem]) async -> [WorkshopItem] {
        let steamIds = Set(items.map(\.creatorSteamId).filter { !$0.isEmpty })
        guard !steamIds.isEmpty else { return items }

        var creators: [String: WorkshopCreator] = [:]
        var missingIds: [String] = []
        for steamId in steamIds {
            if let creator = cachedCreator(steamId: steamId) {
                creators[steamId] = creator
            } else {
                missingIds.append(steamId)
            }
        }

        if !missingIds.isEmpty,
           let fetched = try? await fetchCreatorProfiles(steamIds: missingIds) {
            creators.merge(fetched) { _, new in new }
        }

        return items.map { item in
            guard let creator = creators[item.creatorSteamId] else { return item }
            var enriched = item
            enriched.creatorName = creator.name
            enriched.creatorAvatarURL = creator.avatarURL
            enriched.creatorProfileURL = creator.profileURL
            return enriched
        }
    }

    private func cachedCreator(steamId: String) -> WorkshopCreator? {
        let key = NSString(string: steamId)
        guard let entry = creatorCache.object(forKey: key) else { return nil }
        if Date().timeIntervalSince(entry.date) > 3_600 {
            creatorCache.removeObject(forKey: key)
            return nil
        }
        return entry.creator
    }

    private func fetchCreatorProfiles(steamIds: [String]) async throws -> [String: WorkshopCreator] {
        guard !apiKey.isEmpty else { return [:] }
        var result: [String: WorkshopCreator] = [:]

        for start in stride(from: 0, to: steamIds.count, by: 100) {
            let end = min(start + 100, steamIds.count)
            let batch = Array(steamIds[start..<end])
            try await throttle()

            var components = URLComponents(string: baseURL + "ISteamUser/GetPlayerSummaries/v2/")!
            components.queryItems = [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "steamids", value: batch.joined(separator: ","))
            ]
            guard let url = components.url else { throw SteamAPIError.invalidURL }

            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SteamAPIError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw SteamAPIError.httpError(httpResponse.statusCode)
            }

            let apiResponse = try decoder.decode(SteamPlayerSummariesResponse.self, from: data)
            for player in apiResponse.response.players {
                let creator = WorkshopCreator(
                    steamId: player.steamid,
                    name: player.personaname,
                    avatarURL: player.avatarmedium.flatMap(URL.init(string:)),
                    profileURL: player.profileurl.flatMap(URL.init(string:))
                )
                result[player.steamid] = creator
                creatorCache.setObject(CreatorCacheEntry(creator: creator), forKey: NSString(string: player.steamid))
            }
        }

        return result
    }
}

private actor SteamRequestThrottle {
    private let interval: TimeInterval
    private var nextAllowed = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func wait() async throws {
        try Task.checkCancellation()
        let now = Date()
        let scheduled = max(now, nextAllowed)
        nextAllowed = scheduled.addingTimeInterval(interval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
    }
}

#endif
