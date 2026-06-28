import Foundation

/// Real-network `HLSFetching` over URLSession with fixed headers (User-Agent,
/// Cookie, Referer, …). Thin by design: all logic lives in the testable pure
/// components; this only performs the HTTP GET. The app builds one with its
/// cookies/headers and hands it to `LiveHLSReader` / `ChzzkLiveResolver`.
public final class URLSessionHLSFetcher: HLSFetching, @unchecked Sendable {
    public enum FetchError: Error { case badStatus(Int) }

    private let session: URLSession
    private let headers: [String: String]
    private let timeout: TimeInterval

    public init(headers: [String: String], session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.headers = headers
        self.session = session
        self.timeout = timeout
    }

    public func data(for url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw LiveReaderError.notAPlaylist }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        return data
    }

    /// Standard Chzzk headers for a given cookie pair. Convenience for callers.
    public static func chzzkHeaders(nidAut: String, nidSes: String) -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            "Cookie": "NID_AUT=\(nidAut); NID_SES=\(nidSes)",
            "Origin": "https://chzzk.naver.com",
            "Referer": "https://chzzk.naver.com/",
        ]
    }
}
