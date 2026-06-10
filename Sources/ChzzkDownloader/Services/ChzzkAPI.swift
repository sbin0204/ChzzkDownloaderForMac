import Foundation

struct LiveInfo {
    var status: String      // "OPEN" | "CLOSE" | "BLOCK" | ""
    var liveTitle: String
    var channelName: String
    var adult: Bool
    var tags: [String] = []
    var category: String = ""  // liveCategoryValue (human-readable game/category name)
}

enum LiveInfoFetchResult {
    case info(LiveInfo?)
    case authFailed(Int)
}

/// Polls the Chzzk live-detail API, mirroring get_live_info / get_auth_headers.
enum ChzzkAPI {
    static let liveDetailURL = "https://api.chzzk.naver.com/service/v3/channels/%@/live-detail"

    static func cookieHeader(_ cookies: Cookies) -> String {
        let aut = Validate.sanitizeCookie(cookies.NID_AUT)
        let ses = Validate.sanitizeCookie(cookies.NID_SES)
        return "NID_AUT=\(aut); NID_SES=\(ses)"
    }

    static func authHeaders(_ cookies: Cookies) -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (X11; Unix x86_64)",
            "Cookie": cookieHeader(cookies),
            "Origin": "https://chzzk.naver.com",
            "DNT": "1",
            "Sec-GPC": "1",
            "Connection": "keep-alive",
            "Referer": "",
        ]
    }

    /// Returns nil on transport error (treated like "not open yet").
    static func fetchLiveInfo(channelID: String, cookies: Cookies) async -> LiveInfo? {
        if case .info(let info) = await fetchLiveInfoResult(channelID: channelID, cookies: cookies) {
            return info
        }
        return nil
    }

    static func fetchLiveInfoResult(channelID: String, cookies: Cookies) async -> LiveInfoFetchResult {
        guard let url = URL(string: String(format: liveDetailURL, channelID)) else { return .info(nil) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in authHeaders(cookies) { request.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await ProxySupport.session().data(for: request)
            guard let http = response as? HTTPURLResponse else { return .info(nil) }
            guard http.statusCode == 200 else {
                return isAuthFailureStatus(http.statusCode) ? .authFailed(http.statusCode) : .info(nil)
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = json?["content"] as? [String: Any] ?? [:]
            let status = content["status"] as? String ?? ""
            let title = content["liveTitle"] as? String ?? ""
            let adult = content["adult"] as? Bool ?? false
            var channelName = ""
            if let channel = content["channel"] as? [String: Any] {
                channelName = channel["channelName"] as? String ?? ""
            }
            let tags = (content["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
            let category = content["liveCategoryValue"] as? String ?? ""
            return .info(LiveInfo(
                status: status, liveTitle: title, channelName: channelName,
                adult: adult, tags: tags, category: category))
        } catch {
            return .info(nil)
        }
    }

    static func isAuthFailureStatus(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("401")
            || lower.contains("403")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("adult_auth_required")
            || lower.contains("invalid cookie")
            || lower.contains("cookie")
            || lower.contains("쿠키")
            || lower.contains("인증")
            || lower.contains("로그인")
    }
}
