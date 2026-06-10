import Foundation

/// App-wide proxy (bypass) applied to API calls, streamlink, ffmpeg, and VOD
/// downloads. The canonical value is a single URL string `config.proxy`:
///   `http://host:port`, `socks5://host:port`, or with auth
///   `http://user:pass@host:port`. A bare `host:port` is treated as HTTP.
enum ProxySupport {
    private static let proxy = Synchronized("", label: "ChzzkDownloader.ProxySupport.proxy")

    static var current: String {
        get { proxy.withValue { $0 } }
        set { proxy.update { $0 = newValue.trimmingCharacters(in: .whitespaces) } }
    }

    static var isEnabled: Bool { parsed(current) != nil }

    struct Parts { var scheme: String; var host: String; var port: Int; var user: String; var pass: String }

    private static func parsed(_ s: String) -> Parts? {
        guard !s.isEmpty else { return nil }
        let str = s.contains("://") ? s : "http://" + s
        guard let url = URL(string: str), let host = url.host, !host.isEmpty else { return nil }
        let scheme = (url.scheme ?? "http").lowercased()
        let port = url.port ?? (scheme.hasPrefix("socks") ? 1080 : 8080)
        return Parts(scheme: scheme, host: host, port: port,
                     user: url.user ?? "", pass: url.password ?? "")
    }

    private static func normalizedURL() -> String {
        current.contains("://") ? current : "http://" + current
    }

    /// Credential for proxy authentication challenges (nil when no user is set).
    static var proxyCredential: URLCredential? {
        guard let p = parsed(current), !p.user.isEmpty else { return nil }
        return URLCredential(user: p.user, password: p.pass, persistence: .forSession)
    }

    // MARK: URLSession

    /// A session routed through the proxy (with auth handling), or `.shared` when none.
    static func session() -> URLSession {
        guard parsed(current) != nil else { return .shared }
        let config = URLSessionConfiguration.ephemeral
        apply(to: config)
        return makeSession(config: config)
    }

    /// Builds a session from `config`, attaching a proxy-auth delegate when credentials exist.
    static func makeSession(config: URLSessionConfiguration) -> URLSession {
        if proxyCredential != nil {
            return URLSession(configuration: config, delegate: ProxyAuthDelegate(), delegateQueue: nil)
        }
        return URLSession(configuration: config)
    }

    static func apply(to config: URLSessionConfiguration) {
        if let dict = proxyDictionary() { config.connectionProxyDictionary = dict }
    }

    private static func proxyDictionary() -> [AnyHashable: Any]? {
        guard let p = parsed(current) else { return nil }
        if p.scheme.hasPrefix("socks") {
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: p.host,
                kCFNetworkProxiesSOCKSPort as String: p.port,
            ]
        }
        return [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: p.host,
            kCFNetworkProxiesHTTPPort as String: p.port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: p.host,
            kCFNetworkProxiesHTTPSPort as String: p.port,
        ]
    }

    // MARK: subprocess args

    /// streamlink supports HTTP and SOCKS proxies (auth via the URL userinfo).
    static func streamlinkArgs() -> [String] {
        parsed(current) != nil ? ["--http-proxy", normalizedURL()] : []
    }

    /// ffmpeg's http protocol only honours an HTTP(S) proxy (no SOCKS).
    static func ffmpegArgs() -> [String] {
        guard let p = parsed(current), !p.scheme.hasPrefix("socks") else { return [] }
        return ["-http_proxy", normalizedURL()]
    }
}

/// Answers proxy authentication challenges with the configured credential.
final class ProxyAuthDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(),
           challenge.previousFailureCount == 0,
           let cred = ProxySupport.proxyCredential {
            completionHandler(.useCredential, cred)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
