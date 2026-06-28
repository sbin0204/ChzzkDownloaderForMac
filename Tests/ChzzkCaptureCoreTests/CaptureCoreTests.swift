import XCTest
import CommonCrypto
@testable import ChzzkCaptureCore

final class CDNTokenTests: XCTestCase {
    func testExtractsExpiryFromPathAndQueryTokens() {
        let pathToken = "https://cdn/x/hdntl=exp=1782362794~hmac=abc/playlist.m3u8"
        XCTAssertEqual(CDNToken.expiry(in: pathToken),
                       Date(timeIntervalSince1970: 1782362794))
        let queryToken = "https://cdn/playlist.m3u8?exp=1700000000&hmac=z"
        XCTAssertEqual(CDNToken.expiry(in: queryToken),
                       Date(timeIntervalSince1970: 1700000000))
        XCTAssertNil(CDNToken.expiry(in: "https://cdn/no-token/playlist.m3u8"))
    }

    func testNeedsRefreshWithinThreshold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = "exp=\(Int(now.timeIntervalSince1970) + 600)"     // 10 min left
        let later = "exp=\(Int(now.timeIntervalSince1970) + 4 * 3600)" // 4h left
        XCTAssertTrue(CDNToken.needsRefresh(in: soon, now: now))      // within 3h
        XCTAssertFalse(CDNToken.needsRefresh(in: later, now: now))    // beyond 3h
        XCTAssertFalse(CDNToken.needsRefresh(in: "no-token", now: now))
    }
}

final class LiveSegmentTrackerTests: XCTestCase {
    private func playlist(seq: Int, count: Int, endList: Bool = false) -> HLSMediaPlaylist {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:\(seq)\n"
        for i in 0..<count { text += "#EXTINF:4.0,\nseg\(seq + i).ts\n" }
        if endList { text += "#EXT-X-ENDLIST\n" }
        return HLSMediaPlaylist.parse(text)!
    }

    func testEmitsOnlyNewSegmentsAcrossPolls() {
        var tracker = LiveSegmentTracker()
        let first = tracker.newSegments(from: playlist(seq: 100, count: 3))  // 100,101,102
        XCTAssertEqual(first.map(\.sequence), [100, 101, 102])

        // Next poll overlaps (101,102 again) + two new (103,104).
        let second = tracker.newSegments(from: playlist(seq: 101, count: 4)) // 101..104
        XCTAssertEqual(second.map(\.sequence), [103, 104])
        XCTAssertFalse(tracker.lastPollHadGap)

        // Re-feeding the same playlist yields nothing (idempotent).
        XCTAssertTrue(tracker.newSegments(from: playlist(seq: 101, count: 4)).isEmpty)
    }

    func testDetectsGapAndEndList() {
        var tracker = LiveSegmentTracker()
        _ = tracker.newSegments(from: playlist(seq: 0, count: 2))   // 0,1
        // Window slid: next playlist starts at 5 → lost 2,3,4.
        let jumped = tracker.newSegments(from: playlist(seq: 5, count: 2, endList: true))
        XCTAssertEqual(jumped.map(\.sequence), [5, 6])
        XCTAssertTrue(tracker.lastPollHadGap)
        XCTAssertTrue(tracker.ended)
    }
}

final class AES128Tests: XCTestCase {
    func testDecryptRoundTrip() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data((16..<32).map { UInt8($0) })
        let plaintext = Data("the quick brown fox jumps over 13 lazy dogs!!".utf8)

        // Encrypt with CommonCrypto (PKCS7) to get a known ciphertext.
        let capacity = plaintext.count + kCCBlockSizeAES128
        var cipher = Data(count: capacity)
        var moved = 0
        let status = cipher.withUnsafeMutableBytes { out in
            plaintext.withUnsafeBytes { p in key.withUnsafeBytes { k in iv.withUnsafeBytes { i in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, i.baseAddress,
                        p.baseAddress, plaintext.count, out.baseAddress, capacity, &moved)
            }}}
        }
        XCTAssertEqual(Int(status), kCCSuccess)
        cipher.removeSubrange(moved..<cipher.count)

        let decrypted = AES128.decryptCBC(cipher, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertNil(AES128.decryptCBC(cipher, key: Data([1, 2, 3]), iv: iv))  // bad key size
    }

    func testIVFromSequenceAndHex() {
        let iv5 = AES128.iv(forSequence: 5)
        XCTAssertEqual(iv5.count, 16)
        XCTAssertEqual(iv5.last, 5)
        XCTAssertEqual(iv5.prefix(15), Data(repeating: 0, count: 15))

        let hex = AES128.iv(fromHex: "0x000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(hex, Data((0..<16).map { UInt8($0) }))
        XCTAssertNil(AES128.iv(fromHex: "0x1234"))   // wrong length
    }
}

final class SegmentSinkTests: XCTestCase {
    func testTSFileSinkAppendsBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdmcore-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try TSFileSink(url: url)
        try sink.write(Data([0x47, 0x40, 0x00]))   // looks like a TS packet start
        try sink.write(Data([0x47, 0x41, 0x01]))
        sink.close()
        XCTAssertEqual(sink.bytesWritten, 6)
        XCTAssertEqual(try Data(contentsOf: url).count, 6)
    }

    func testDataSinkAccumulates() throws {
        let sink = DataSegmentSink()
        try sink.write(Data([1, 2]))
        try sink.write(Data([3]))
        XCTAssertEqual(sink.data, Data([1, 2, 3]))
    }
}
