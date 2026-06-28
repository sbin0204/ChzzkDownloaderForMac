import Foundation

/// Fetches bytes for a URL. Injected so the reader is testable without a network.
public protocol HLSFetching: Sendable {
    func data(for url: String) async throws -> Data
}

public enum LiveReaderError: Error, Equatable {
    case notAPlaylist
    case decryptFailed
    case missingKey
}

/// Summary of a finished read.
public struct LiveReadResult: Equatable, Sendable {
    public var segments: Int
    public var bytes: Int
    public var endedNaturally: Bool   // hit #EXT-X-ENDLIST
    public var hadGap: Bool           // a DVR window slid past us at some point
}

/// Drives a live HLS recording end-to-end: poll the media playlist, write only the
/// new segments (decrypting AES-128 when present) to a sink, and re-resolve the
/// stream URL before its CDN token expires. This is the streamlink replacement;
/// the muxing/container step (ffmpeg, or raw TS via the sink) is separate.
///
/// Generic over a `resolveMediaURL` closure so the core stays Chzzk-agnostic — the
/// caller supplies the Chzzk-specific resolution (live-detail → master → variant).
public actor LiveHLSReader {
    public struct Options: Sendable {
        public var refreshBefore: TimeInterval = 3 * 60 * 60   // re-resolve token within 3h of expiry
        public var fallbackPollSeconds: TimeInterval = 2       // when TARGETDURATION is absent
        public init() {}
    }

    private let fetcher: HLSFetching
    private let sink: SegmentSink
    private let resolveMediaURL: @Sendable () async throws -> String
    private let wait: @Sendable (TimeInterval) async -> Void
    private let options: Options
    private var stopped = false

    public init(
        fetcher: HLSFetching,
        sink: SegmentSink,
        options: Options = Options(),
        resolveMediaURL: @escaping @Sendable () async throws -> String,
        wait: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.fetcher = fetcher
        self.sink = sink
        self.options = options
        self.resolveMediaURL = resolveMediaURL
        self.wait = wait
    }

    public func stop() { stopped = true }

    @discardableResult
    public func run() async throws -> LiveReadResult {
        var mediaURL = try await resolveMediaURL()
        var tracker = LiveSegmentTracker()
        var keyCache: [String: Data] = [:]
        var initWritten = false
        var segmentCount = 0
        var sawGap = false

        defer { sink.close() }

        while !stopped, !Task.isCancelled {
            // Re-resolve before the token expires so the next fetch uses a fresh URL.
            if CDNToken.needsRefresh(in: mediaURL, before: options.refreshBefore) {
                mediaURL = try await resolveMediaURL()
            }

            let text = String(decoding: try await fetcher.data(for: mediaURL), as: UTF8.self)
            guard let playlist = HLSMediaPlaylist.parse(text) else { throw LiveReaderError.notAPlaylist }

            // fMP4 streams need their init segment prepended (and a real muxer
            // downstream); plain TS does not.
            if let initURI = playlist.initSegmentURI, !initWritten {
                let data = try await fetcher.data(for: resolve(initURI, against: mediaURL))
                try sink.write(data)
                initWritten = true
            }

            for segment in tracker.newSegments(from: playlist) {
                if stopped || Task.isCancelled { break }
                var data = try await fetcher.data(for: resolve(segment.uri, against: mediaURL))
                if let key = playlist.key, key.isEncrypted {
                    data = try await decrypt(data, key: key, sequence: segment.sequence,
                                             mediaURL: mediaURL, cache: &keyCache)
                }
                try sink.write(data)
                segmentCount += 1
            }
            if tracker.lastPollHadGap { sawGap = true }
            if tracker.ended { break }

            let interval = playlist.targetDuration > 0 ? playlist.targetDuration / 2 : options.fallbackPollSeconds
            await wait(interval)
        }

        let bytes = (sink as? TSFileSink)?.bytesWritten
            ?? (sink as? DataSegmentSink)?.data.count ?? 0
        return LiveReadResult(segments: segmentCount, bytes: bytes,
                              endedNaturally: tracker.ended, hadGap: sawGap)
    }

    // MARK: - helpers

    private func decrypt(_ data: Data, key: HLSMediaPlaylist.Key, sequence: Int,
                         mediaURL: String, cache: inout [String: Data]) async throws -> Data {
        guard let keyURI = key.uri else { throw LiveReaderError.missingKey }
        let keyData: Data
        if let cached = cache[keyURI] {
            keyData = cached
        } else {
            keyData = try await fetcher.data(for: resolve(keyURI, against: mediaURL))
            cache[keyURI] = keyData
        }
        let iv = key.iv.flatMap(AES128.iv(fromHex:)) ?? AES128.iv(forSequence: sequence)
        guard let plain = AES128.decryptCBC(data, key: keyData, iv: iv) else {
            throw LiveReaderError.decryptFailed
        }
        return plain
    }

    /// Resolves a possibly-relative segment/key/init URI against the playlist URL.
    private func resolve(_ reference: String, against base: String) -> String {
        HLSURL.resolve(reference, against: base)
    }
}
