import XCTest
@testable import ChzzkCaptureCore

final class HLSMasterPlaylistTests: XCTestCase {
    private let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
    1080p/chunklist.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
    https://cdn/abs/720p.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360
    360p/chunklist.m3u8
    """

    func testParsesVariantsAndResolvesRelativeURIs() throws {
        let pl = try XCTUnwrap(HLSMasterPlaylist.parse(master, masterURL: "https://cdn/live/master.m3u8"))
        XCTAssertEqual(pl.variants.count, 3)
        XCTAssertEqual(pl.variants[0].height, 1080)
        XCTAssertEqual(pl.variants[0].uri, "https://cdn/live/1080p/chunklist.m3u8")  // relative resolved
        XCTAssertEqual(pl.variants[1].uri, "https://cdn/abs/720p.m3u8")              // absolute kept
    }

    func testQualitySelection() throws {
        let pl = try XCTUnwrap(HLSMasterPlaylist.parse(master, masterURL: "https://cdn/live/master.m3u8"))
        XCTAssertEqual(pl.select(quality: "best")?.height, 1080)
        XCTAssertEqual(pl.select(quality: "worst")?.height, 360)
        XCTAssertEqual(pl.select(quality: "720p")?.height, 720)     // exact
        XCTAssertEqual(pl.select(quality: "1080")?.height, 1080)
        XCTAssertEqual(pl.select(quality: "480p")?.height, 360)     // nearest (no 480 -> 360 closer than 720? 480-360=120, 720-480=240)
        XCTAssertEqual(pl.select(quality: "garbage")?.height, 1080) // fallback highest
    }

    func testRejectsMediaPlaylistAsMaster() {
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg0.ts\n"
        XCTAssertNil(HLSMasterPlaylist.parse(media, masterURL: "https://x/m.m3u8"))
    }
}

private final class StubFetcher: HLSFetching, @unchecked Sendable {
    let map: [String: Data]
    init(_ map: [String: Data]) { self.map = map }
    func data(for url: String) async throws -> Data {
        guard let d = map[url] else { throw ChzzkLiveResolver.ResolveError.badResponse }
        return d
    }
}

final class ChzzkLiveResolverTests: XCTestCase {
    func testDomainCorrectionMapsRetiredHost() {
        let retired = "https://nlive-streaming.navercdn.com/chzzk/live/master.m3u8?hdnts=exp=1"
        XCTAssertEqual(ChzzkLiveResolver.correctDomain(retired),
                       "https://livecloud.pstatic.net/chzzk/live/master.m3u8?hdnts=exp=1")
        let other = "https://livecloud.pstatic.net/x.m3u8"
        XCTAssertEqual(ChzzkLiveResolver.correctDomain(other), other)   // untouched
    }

    func testMasterURLExtractionFromLiveDetail() throws {
        // livePlaybackJson is itself a JSON string inside the response.
        let playback = #"{"media":[{"protocol":"DASH","path":"https://x/d.mpd"},{"protocol":"HLS","path":"https://nlive-streaming.navercdn.com/live/master.m3u8"}]}"#
        let detail: [String: Any] = ["content": ["status": "OPEN", "livePlaybackJson": playback]]
        let data = try JSONSerialization.data(withJSONObject: detail)
        let url = try ChzzkLiveResolver.masterPlaylistURL(from: data)
        XCTAssertEqual(url, "https://livecloud.pstatic.net/live/master.m3u8")  // HLS chosen + domain fixed
    }

    func testMasterURLThrowsWhenNotOpen() throws {
        let detail: [String: Any] = ["content": ["status": "CLOSE", "livePlaybackJson": "{}"]]
        let data = try JSONSerialization.data(withJSONObject: detail)
        XCTAssertThrowsError(try ChzzkLiveResolver.masterPlaylistURL(from: data)) {
            XCTAssertEqual($0 as? ChzzkLiveResolver.ResolveError, .notOpen)
        }
    }

    func testResolveMediaURLEndToEndWithFakeFetcher() async throws {
        let detailURL = String(format: ChzzkLiveResolver.liveDetailURLFormat, "chan1")
        let masterURL = "https://livecloud.pstatic.net/live/master.m3u8"
        let playback = #"{"media":[{"protocol":"HLS","path":"https://nlive-streaming.navercdn.com/live/master.m3u8"}]}"#
        let detail = try JSONSerialization.data(withJSONObject: ["content": ["status": "OPEN", "livePlaybackJson": playback]])
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p/chunklist.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360
        360p/chunklist.m3u8
        """
        let fetcher = StubFetcher([detailURL: detail, masterURL: Data(master.utf8)])

        let media = try await ChzzkLiveResolver.resolveMediaURL(channelID: "chan1", quality: "best", fetcher: fetcher)
        XCTAssertEqual(media, "https://livecloud.pstatic.net/live/1080p/chunklist.m3u8")
    }
}
