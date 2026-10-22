import Foundation
import Network
import WebKit

/// Optional in GlobalSettings so settings from earlier versions still decode.
struct AppHTTPProxySettings: Codable, Equatable {
    var enabled = false
    var host = "127.0.0.1"
    var port = "7890"

    var normalizedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var portNumber: UInt16? {
        let value = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt16(value), number > 0 else { return nil }
        return number
    }
    var isValid: Bool {
        let host = normalizedHost
        let domain = !host.isEmpty && host.utf8.count <= 253 &&
            host.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
        return portNumber != nil && (domain || IPv6Address(host) != nil)
    }
    var endpointURL: String? {
        guard isValid, let portNumber else { return nil }
        let authority = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        return "http://\(authority):\(portNumber)"
    }
}

/// One immutable startup snapshot shared by every in-scope network client.
/// Never substitute a different proxy or a direct connection after a failure.
struct AppHTTPProxy {
    private struct Envelope: Decodable { let httpProxy: AppHTTPProxySettings? }
    static let runtime = AppHTTPProxy(settingsData: UserDefaults.standard.data(forKey: "GlobalSettings"))
    let settings: AppHTTPProxySettings
    let hasInvalidSettings: Bool

    init(settings: AppHTTPProxySettings) {
        self.settings = settings
        hasInvalidSettings = settings.enabled && !settings.isValid
    }
    init(settingsData: Data?) {
        guard let settingsData else { self.init(settings: .init()); return }
        do {
            self.init(settings: try JSONDecoder().decode(Envelope.self, from: settingsData).httpProxy ?? .init())
        } catch {
            // A malformed persisted proxy must never silently become direct access.
            self.init(settings: AppHTTPProxySettings(enabled: true, host: "", port: ""))
        }
    }
    var proxyConfigurations: [ProxyConfiguration] {
        guard settings.enabled, !hasInvalidSettings, let port = settings.portNumber else { return [] }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(
            host: .init(settings.normalizedHost), port: .init(rawValue: port)!))
        proxy.allowFailover = false
        proxy.excludedDomains = []
        return [proxy]
    }
    func configure(_ configuration: URLSessionConfiguration) {
        guard settings.enabled else { return }
        if hasInvalidSettings {
            configuration.protocolClasses = [InvalidProxyURLProtocol.self]
        } else {
            configuration.proxyConfigurations = proxyConfigurations
        }
    }
    func configure(_ configuration: WKWebViewConfiguration) {
        guard settings.enabled else { return }
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = proxyConfigurations
    }
    func serviceEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result["MOTISCAPE_HTTP_PROXY_ENABLED"] = settings.enabled ? "1" : "0"
        result["MOTISCAPE_HTTP_PROXY_URL"] = settings.endpointURL ?? ""
        return result
    }
}

private final class InvalidProxyURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: L("代理配置无效，请检查地址和端口，保存后重启应用。")]))
    }
    override func stopLoading() { }
}
