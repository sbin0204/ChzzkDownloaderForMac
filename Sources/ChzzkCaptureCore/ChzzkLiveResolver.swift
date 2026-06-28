import Foundation

/// Resolves a Chzzk channel's current live broadcast to a concrete HLS media
/// (chunklist) playlist URL, ready to feed `LiveHLSReader`. Chzzk-specific glue
/// kept here so `LiveHLSReader` stays a generic HLS engine.
public enum ChzzkLiveResolver {
    public enum ResolveError: Error, Equatable {
        case notOpen
        case noHLSMedia
        case noVariant
        case badResponse
    }

    static let liveDetailURLFormat = "https://api.chzzk.naver.com/service/v3/channels/%@/live-detail"

    /// channelID + quality -> absolute media playlist URL. Uses `fetcher` for both
    /// the API call and the master playlist (the fetcher carries the right
    /// headers/cookies), so the whole resolution is testable with a fake fetcher.
    public static func resolveMediaURL(
        channelID: String, quality: String, fetcher: HLSFetching
    ) async throws -> String {
        let detailURL = String(format: liveDetailURLFormat, channelID)
        let detailData = try await fetcher.data(for: detailURL)
        let masterURL = try masterPlaylistURL(from: detailData)
        let masterText = String(decoding: try await fetcher.data(for: masterURL), as: UTF8.self)
        guard let master = HLSMasterPlaylist.parse(masterText, masterURL: masterURL) else {
            throw ResolveError.badResponse
        }
        guard let variant = master.select(quality: quality) else { throw ResolveError.noVariant }
        return variant.uri
    }

    /// Parses live-detail JSON -> the HLS master playlist URL (domain-corrected).
    /// Exposed for testing. nlive-streaming.navercdn.com no longer resolves, so it
    /// is mapped back to the live host that does (mirrors the streamlink plugin fix).
    public static func masterPlaylistURL(from detailData: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any],
              let content = json["content"] as? [String: Any] else {
            throw ResolveError.badResponse
        }
        guard (content["status"] as? String) == "OPEN" else { throw ResolveError.notOpen }
        guard let playbackString = content["livePlaybackJson"] as? String,
              let playbackData = playbackString.data(using: .utf8),
              let playback = try? JSONSerialization.jsonObject(with: playbackData) as? [String: Any],
              let media = playback["media"] as? [[String: Any]] else {
            throw ResolveError.noHLSMedia
        }
        for entry in media where (entry["protocol"] as? String)?.uppercased() == "HLS" {
            if let path = entry["path"] as? String, !path.isEmpty {
                return correctDomain(path)
            }
        }
        throw ResolveError.noHLSMedia
    }

    /// Maps the retired CDN host to the one that still resolves.
    static func correctDomain(_ url: String) -> String {
        guard let parsed = URLComponents(string: url),
              parsed.host == "nlive-streaming.navercdn.com" else { return url }
        var fixed = parsed
        fixed.host = "livecloud.pstatic.net"
        return fixed.string ?? url
    }
}
