import Foundation

/// Wire-only values. The main app remains the sole owner of the download database.
struct SteamAgentConfiguration: Codable, Equatable {
    var apiKey = ""
    var apiBaseURL = "https://api.steampowered.com/"
    var proxy = AppHTTPProxySettings()
    var downloadDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "motiscape/Workshop/content/431960")
    // The main app supplies its readable cache location, including its sandbox container.
    // Optional for compatibility with configurations from older main apps.
    var previewDirectory: URL?
}

struct SteamBrowseQuery: Codable {
    var request: WorkshopBrowseRequest
    var enrichCreatorProfiles = true
    var reuseFilteredPages = false
    var trendDays: Int?
}

struct SteamAgentPage: Codable {
    var items: [WorkshopItem]
    var total: Int
}
struct SteamAgentEmpty: Codable {}
struct SteamAgentEnvelope: Codable {
    var payload: Data = Data()
    var apiError: SteamAPIError?
    var serviceError: SteamServiceRequestError?
}
struct SteamAgentRequest: Codable {
    let id: UUID
    let operation: SteamAgentOperation
}

enum SteamAgentOperation: Codable {
    case configure(SteamAgentConfiguration)
    case status, start, restoreSession
    case loginQR, login(username: String, password: String), guardCode(String), cancelLogin, logout
    case subscriptions(start: Int), subscriptionStates([String])
    case favorites, favorite(id: String, enabled: Bool), subscribe(String), unsubscribe(String)
    case comments(item: WorkshopItem, start: Int, count: Int), postComment(item: WorkshopItem, text: String)
    case download(id: String, attempt: String, root: URL, managed: Bool)
    case stopDownload(attempt: String, pause: Bool)
    case downloadResults, acknowledgeDownload(String)
    case query(SteamBrowseQuery)
    case discover(text: String, sort: WorkshopSortOrder, required: [String], excluded: [String], page: Int, count: Int, days: Int?)
    case details(ids: [String], enrich: Bool)
    case userFiles(id: String, page: Int, count: Int, sort: String?, required: [String], excluded: [String], enrich: Bool)
    case collection(id: String, page: Int, count: Int)
    case creator(String), enrich([WorkshopItem]), invalidateBrowse
    case explore(force: Bool), preview(URL)
}

struct SteamAgentStatus: Codable {
    var isAvailable = false
    var isLoggedIn = false
    var loginState: SteamLoginState = .idle
    var authenticationState: SteamServiceState = .unknown
    var accountName = ""
    var steamId = ""
    var savedUsername = ""
    var favorites: Set<String> = []
    var hasBuiltInKey = false
}

struct SteamAgentDownloadEvent: Codable {
    let attempt: String
    let workshopID: String
    let root: URL
    let state: DownloadState
}
struct SteamAgentPreview: Codable { let file: URL }

struct SteamAgentStopFailure: Codable { let attempt: String; let message: String }
