import XCTest
@testable import ChzzkCaptureCore

final class HLSMediaPlaylistTests: XCTestCase {
    func testParsesLiveMediaPlaylistWithSequenceAndDurations() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:4.000,
        seg100.ts
        #EXTINF:3.500,
        seg101.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:4.000,
        seg102.ts
        """
        let pl = try XCTUnwrap(HLSMediaPlaylist.parse(text))
        XCTAssertEqual(pl.targetDuration, 4)
        XCTAssertEqual(pl.mediaSequence, 100)
        XCTAssertFalse(pl.endList)
        XCTAssertEqual(pl.segments.map(\.sequence), [100, 101, 102])
        XCTAssertEqual(pl.segments[1].duration, 3.5, accuracy: 0.0001)
        XCTAssertEqual(pl.segments[1].uri, "seg101.ts")
        XCTAssertFalse(pl.segments[1].discontinuity)
        XCTAssertTrue(pl.segments[2].discontinuity)   // after #EXT-X-DISCONTINUITY
        XCTAssertFalse(pl.isFragmentedMP4)
    }

    func testDetectsEndListAndAESKeyAndInitSegment() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn/key",IV=0x1234
        #EXTINF:6.000,
        seg0.m4s
        #EXT-X-ENDLIST
        """
        let pl = try XCTUnwrap(HLSMediaPlaylist.parse(text))
        XCTAssertTrue(pl.endList)
        XCTAssertEqual(pl.initSegmentURI, "init.mp4")
        XCTAssertTrue(pl.isFragmentedMP4)
        XCTAssertEqual(pl.key?.method, "AES-128")
        XCTAssertEqual(pl.key?.uri, "https://cdn/key")
        XCTAssertEqual(pl.key?.iv, "0x1234")
        XCTAssertEqual(pl.key?.isEncrypted, true)
    }

    func testKeyMethodNoneIsNotEncrypted() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        seg0.ts
        """
        let pl = try XCTUnwrap(HLSMediaPlaylist.parse(text))
        XCTAssertEqual(pl.key?.isEncrypted, false)
    }

    func testRejectsMasterPlaylistAndNonPlaylist() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080
        1080p/chunklist.m3u8
        """
        XCTAssertNil(HLSMediaPlaylist.parse(master))   // master, not media
        XCTAssertNil(HLSMediaPlaylist.parse("not a playlist"))
        XCTAssertNil(HLSMediaPlaylist.parse(""))
    }

    func testDefaultMediaSequenceIsZeroWhenAbsent() throws {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\na.ts\n#EXTINF:2.0,\nb.ts\n"
        let pl = try XCTUnwrap(HLSMediaPlaylist.parse(text))
        XCTAssertEqual(pl.segments.map(\.sequence), [0, 1])
    }
}
