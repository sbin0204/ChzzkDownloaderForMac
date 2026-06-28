import XCTest
import CommonCrypto
@testable import ChzzkCaptureCore

/// Scripted fetcher: each URL maps to a queue of responses (last repeats).
private final class FakeFetcher: HLSFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [Data]]
    private(set) var requests: [String] = []

    init(_ responses: [String: [Data]]) { self.responses = responses }

    func data(for url: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        requests.append(url)
        guard var queue = responses[url], let first = queue.first else {
            throw LiveReaderError.notAPlaylist   // unexpected URL
        }
        if queue.count > 1 { queue.removeFirst(); responses[url] = queue }
        return first
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private func aesEncrypt(_ plaintext: Data, key: Data, iv: Data) -> Data {
    let capacity = plaintext.count + kCCBlockSizeAES128
    var out = Data(count: capacity)
    var moved = 0
    _ = out.withUnsafeMutableBytes { o in plaintext.withUnsafeBytes { p in
        key.withUnsafeBytes { k in iv.withUnsafeBytes { i in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, key.count, i.baseAddress, p.baseAddress, plaintext.count,
                    o.baseAddress, capacity, &moved)
        }}}
    }
    out.removeSubrange(moved..<out.count)
    return out
}

final class LiveHLSReaderTests: XCTestCase {
    private let noWait: @Sendable (TimeInterval) async -> Void = { _ in }
    private let farToken = "exp=99999999999"   // never needs refresh

    func testWritesNewSegmentsAcrossPollsUntilEndList() async throws {
        let url = "https://cdn/\(farToken)/chunklist.m3u8"
        let poll1 = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\nhttps://cdn/s0.ts\n#EXTINF:2,\nhttps://cdn/s1.ts\n"
        let poll2 = poll1 + "#EXTINF:2,\nhttps://cdn/s2.ts\n#EXT-X-ENDLIST\n"
        let fetcher = FakeFetcher([
            url: [Data(poll1.utf8), Data(poll2.utf8)],
            "https://cdn/s0.ts": [Data([0])],
            "https://cdn/s1.ts": [Data([1])],
            "https://cdn/s2.ts": [Data([2])],
        ])
        let sink = DataSegmentSink()
        let reader = LiveHLSReader(fetcher: fetcher, sink: sink, resolveMediaURL: { url }, wait: noWait)

        let result = try await reader.run()
        XCTAssertEqual(result.segments, 3)
        XCTAssertTrue(result.endedNaturally)
        XCTAssertEqual(sink.data, Data([0, 1, 2]))   // each segment once, in order
    }

    func testReResolvesWhenTokenNearExpiry() async throws {
        let nearExpiry = "https://cdn/exp=1000/chunklist.m3u8"            // long past -> needs refresh
        let fresh = "https://cdn/\(farToken)/chunklist.m3u8"
        let endlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\nhttps://cdn/s0.ts\n#EXT-X-ENDLIST\n"
        let fetcher = FakeFetcher([
            fresh: [Data(endlist.utf8)],
            "https://cdn/s0.ts": [Data([9])],
        ])
        let counter = Counter()
        let reader = LiveHLSReader(
            fetcher: fetcher, sink: DataSegmentSink(),
            resolveMediaURL: { counter.next() == 1 ? nearExpiry : fresh },
            wait: noWait)

        let result = try await reader.run()
        // Iteration 1: initial URL is near-expiry -> re-resolve to fresh before fetch.
        XCTAssertGreaterThanOrEqual(counter.count, 2)
        XCTAssertTrue(result.endedNaturally)
    }

    func testDecryptsAES128Segments() async throws {
        let url = "https://cdn/\(farToken)/chunklist.m3u8"
        let key = Data((0..<16).map { UInt8($0) })
        let plaintext = Data("encrypted live segment payload!".utf8)
        let cipher = aesEncrypt(plaintext, key: key, iv: AES128.iv(forSequence: 0))   // seq 0 -> zero IV
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn/key"
        #EXTINF:2,
        https://cdn/enc0.ts
        #EXT-X-ENDLIST
        """
        let fetcher = FakeFetcher([
            url: [Data(playlist.utf8)],
            "https://cdn/key": [key],
            "https://cdn/enc0.ts": [cipher],
        ])
        let sink = DataSegmentSink()
        let reader = LiveHLSReader(fetcher: fetcher, sink: sink, resolveMediaURL: { url }, wait: noWait)

        let result = try await reader.run()
        XCTAssertEqual(result.segments, 1)
        XCTAssertEqual(sink.data, plaintext)   // decrypted back to the original
    }
}
