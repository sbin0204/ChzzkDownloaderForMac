import Foundation

struct LiveInfo {
    var status: String      // "OPEN" | "CLOSE" | "BLOCK" | ""
    var liveTitle: String
    var channelName: String
    var adult: Bool
    var tags: [String] = []
    var category: String = ""  // liveCategoryValue (human-readable game/category name)
    /// False when the live is OPEN but exposes no playback media (adult stream
    /// without auth, region block, …) — streamlink would fail instantly.
    var hasMedia: Bool = true
    /// Current-frame thumbnail (liveImageUrl with its {type} size token resolved).
    var thumbnailURL: String = ""
    var viewerCount: Int = 0
    var openDate: String = ""   // "yyyy-MM-dd HH:mm:ss" — used to show uptime
}

struct ChannelProfile: Equatable {
    var channelID: String
    var channelName: String
    var channelImageURL: String?
    var followerCount: Int?
    var openLive: Bool
}

enum LiveInfoFetchResult {
    case info(LiveInfo?)
    case authFailed(Int)
}

/// Polls the Chzzk live-detail API, mirroring get_live_info / get_auth_headers.
enum ChzzkAPI {
    static let liveDetailURL = "https://api.chzzk.naver.com/service/v3/channels/%@/live-detail"
    static let channelProfileURL = "https://api.chzzk.naver.com/service/v1/channels/%@"

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
            let hasMedia = (content["livePlaybackJson"] as? String).map { !$0.isEmpty } ?? false
            // liveImageUrl carries a {type} token for the size variant, e.g.
            // ".../live_xxx_{type}.jpg" — resolve it to a 480p thumbnail.
            let thumbnail = (content["liveImageUrl"] as? String)?
                .replacingOccurrences(of: "{type}", with: "480") ?? ""
            let viewerCount = content["concurrentUserCount"] as? Int ?? 0
            let openDate = content["openDate"] as? String ?? ""
            return .info(LiveInfo(
                status: status, liveTitle: title, channelName: channelName,
                adult: adult, tags: tags, category: category, hasMedia: hasMedia,
                thumbnailURL: thumbnail, viewerCount: viewerCount, openDate: openDate))
        } catch {
            return .info(nil)
        }
    }

    static func fetchChannelProfile(channelID: String) async -> ChannelProfile? {
        guard Validate.matches(Validate.safeChannelID, channelID),
              let url = URL(string: String(format: channelProfileURL, channelID)) else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://chzzk.naver.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chzzk.naver.com/", forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await ProxySupport.session().data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parseChannelProfileResponse(data)
        } catch {
            return nil
        }
    }

    static func parseChannelProfileResponse(_ data: Data) -> ChannelProfile? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any] else {
            return nil
        }
        let channelID = content["channelId"] as? String ?? ""
        let channelName = content["channelName"] as? String ?? ""
        guard !channelID.isEmpty, !channelName.isEmpty else { return nil }

        let rawImageURL = (content["channelImageUrl"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let followerCount = (content["followerCount"] as? NSNumber)?.intValue
        return ChannelProfile(
            channelID: channelID,
            channelName: channelName,
            channelImageURL: rawImageURL?.isEmpty == false ? rawImageURL : nil,
            followerCount: followerCount,
            openLive: content["openLive"] as? Bool ?? false)
    }

    static func isAuthFailureStatus(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    /// Heuristic over error/log text. Deliberately narrow: this runs on every
    /// streamlink stderr line, so bare substrings like "cookie" or "403" inside a
    /// URL/size would otherwise raise false "re-import cookies" warnings.
    static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("adult_auth_required")
            || lower.contains("invalid cookie")
            || lower.contains("쿠키가 유효하지")
            || lower.contains("로그인이 필요") {
            return true
        }
        // Status codes only as standalone tokens (e.g. "HTTP 403", "error 401").
        return lower.range(of: #"\b40[13]\b"#, options: .regularExpression) != nil
    }
}
