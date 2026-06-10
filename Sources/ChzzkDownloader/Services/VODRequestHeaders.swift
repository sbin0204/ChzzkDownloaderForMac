import Foundation

enum VODRequestHeaders {
    static let userAgent = "Mozilla/5.0"
    static let referer = "https://chzzk.naver.com/"
    static let origin = "https://chzzk.naver.com"

    static func media(cookies: Cookies) -> [String: String] {
        var headers = [
            "User-Agent": userAgent,
            "Referer": referer,
            "Origin": origin,
            "Accept": "*/*",
            "Accept-Encoding": "identity",
            "Connection": "keep-alive",
        ]
        if !cookies.NID_AUT.isEmpty || !cookies.NID_SES.isEmpty {
            headers["Cookie"] = ChzzkAPI.cookieHeader(cookies)
        }
        return headers
    }

    static func ffmpegHeaders(cookies: Cookies) -> String {
        media(cookies: cookies)
            .filter { $0.key != "User-Agent" }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n") + "\r\n"
    }
}
