import Foundation

// MARK: - Errors

enum SteamAPIError: LocalizedError, Codable {
    case missingAPIKey
    case filterScanLimit
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return L("尚未设置 Steam Web API Key。请在“设置 → 通用”中填写；扫码登录不能替代浏览所需的 Key。")
        case .filterScanLimit: return L("筛选扫描范围过大，请增加关键词或缩小筛选范围后重试")
        case .invalidURL: return L("无效的 API 地址")
        case .invalidResponse: return L("无效的服务器响应")
        case .httpError(401), .httpError(403): return L("Steam API Key 无效、权限不足或当前线路拒绝访问")
        case .httpError(429): return L("Steam Web API 请求过于频繁，请稍后重试或设置专属 API Key")
        case .httpError(let code): return L("HTTP 错误: %@", String(code))
        case .decodingError(let msg): return L("数据解析错误: %@", msg)
        }
    }
}

