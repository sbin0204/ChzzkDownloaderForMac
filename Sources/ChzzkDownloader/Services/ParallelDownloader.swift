import Foundation

struct HTTPByteRange: Equatable {
    var start: Int
    var end: Int

    var length: Int { max(0, end - start + 1) }
}

/// Token-bucket limiter shared across parallel workers to cap aggregate speed.
/// `bytesPerSec <= 0` means unlimited.
actor RateLimiter {
    private let rate: Double
    private let capacity: Double
    private var tokens: Double
    private var last = Date()

    init(bytesPerSec: Double) {
        rate = bytesPerSec
        capacity = max(bytesPerSec * 2, 64 * 1024)
        tokens = capacity
    }

    func consume(_ n: Int) async {
        guard rate > 0 else { return }
        var remaining = Double(n)
        while remaining > 0 {
            let now = Date()
            tokens = min(capacity, tokens + now.timeIntervalSince(last) * rate)
            last = now
            let spent = min(tokens, remaining)
            if spent > 0 {
                tokens -= spent
                remaining -= spent
                continue
            }
            let wait = min(remaining / rate, 0.5)
            try? await Task.sleep(nanoseconds: UInt64(min(wait, 0.5) * 1_000_000_000))
        }
    }
}

/// Multi-connection ranged HTTP downloader. Naver's CDN throttles
/// each connection hard, so a single ffmpeg stream crawls (~2 MB then stalls);
/// downloading many byte-ranges in parallel multiplies throughput.
/// Writes to a hidden `.part` file and renames on success.
final class ParallelDownloader {
    private let chunkSize = 8 * 1024 * 1024
    private struct ProgressState {
        var downloaded: Int
        var emaSpeed = 0.0
        var sampleTime: Date
        var sampleBytes: Int
    }

    private let canceled = Synchronized(false, label: "ChzzkDownloader.ParallelDownloader.canceled")

    func cancel() { canceled.update { $0 = true } }
    private var isCanceled: Bool { canceled.withValue { $0 } }

    static func clipWindowRanges(fileTotal: Int, durationSeconds: Double,
                                 clipStart: Double, clipEnd: Double) -> [HTTPByteRange] {
        guard fileTotal > 0, durationSeconds > 0, clipEnd > clipStart else { return [] }
        let headBytes = min(fileTotal, 32 * 1024 * 1024)
        let tailBytes = min(fileTotal, 16 * 1024 * 1024)
        let bytesPerSecond = Double(fileTotal) / durationSeconds
        let startEstimate = Int((max(0, clipStart) / durationSeconds * Double(fileTotal)).rounded(.down))
        let endEstimate = Int((min(durationSeconds, clipEnd) / durationSeconds * Double(fileTotal)).rounded(.up))
        let minPadding = Double(64 * 1024 * 1024)
        let maxPadding = Double(512 * 1024 * 1024)
        let oneMinuteEstimate = bytesPerSecond * 60
        let padding = Int(min(maxPadding, max(minPadding, oneMinuteEstimate)).rounded(.up))
        let windowStart = max(0, min(fileTotal - 1, startEstimate - padding))
        let windowEnd = max(windowStart, min(fileTotal - 1, endEstimate + padding))

        return mergeRanges([
            HTTPByteRange(start: 0, end: max(0, headBytes - 1)),
            HTTPByteRange(start: windowStart, end: windowEnd),
            HTTPByteRange(start: max(0, fileTotal - tailBytes), end: fileTotal - 1),
        ])
    }

    private static func mergeRanges(_ ranges: [HTTPByteRange]) -> [HTTPByteRange] {
        var result: [HTTPByteRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.length > 0 {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.start <= last.end + 1 {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// onProgress(downloadedBytes, totalBytes, bytesPerSecond)
    /// `prefixFraction` (0...1) limits the download to roughly that leading fraction
    /// of the file (+ padding). Do not use this for user-selected clips; direct MP4
    /// clips without DASH/HLS parts use `downloadClipWindow(...)` instead.
    func download(urlString: String, headers: [String: String], finalOutput: URL,
                  connections: Int, rateLimitBytesPerSec: Double = 0,
                  prefixFraction: Double? = nil,
                  onProgress: @escaping (Int, Int, Double) -> Void) async throws {
        let limiter = RateLimiter(bytesPerSec: rateLimitBytesPerSec)
        guard let url = URL(string: urlString) else { throw VODError.invalidURL }
        let partURL = Filename.temporaryURL(for: finalOutput, suffix: ".part")
        let fm = FileManager.default
        try? fm.removeItem(at: partURL)
        Filename.removeTemporary(for: finalOutput, suffix: ".cvdresume")
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully {
                try? fm.removeItem(at: partURL)
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = max(1, connections)   // default is only 6
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true
        config.networkServiceType = .responsiveData
        ProxySupport.apply(to: config)
        let session = ProxySupport.makeSession(config: config)
        defer { session.invalidateAndCancel() }

        let (fileTotal, rangeSupported) = try await probeSize(url: url, headers: headers, session: session)

        // Legacy prefix mode. User-selected clips must not reach this path because
        // late clips would still fetch almost the whole file.
        var total = fileTotal
        if let frac = prefixFraction, rangeSupported, fileTotal > 0 {
            let estimate = Int((Double(fileTotal) * min(1.0, max(0, frac))).rounded(.up))
            let padding = min(max(64 * 1024 * 1024, fileTotal / 20), 512 * 1024 * 1024)
            total = min(fileTotal, estimate + padding)
        }

        // No-range / tiny: single connection.
        if !rangeSupported || total <= chunkSize {
            try await downloadWhole(url: url, headers: headers, session: session,
                                    partURL: partURL, total: total, onProgress: onProgress)
            try finalize(partURL: partURL, finalOutput: finalOutput)
            completedSuccessfully = true
            return
        }

        fm.createFile(atPath: partURL.path, contents: nil)
        let h = try FileHandle(forWritingTo: partURL)
        try h.truncate(atOffset: UInt64(total)); try h.close()

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }

        var ranges: [(Int, Int, Int)] = []
        var idx = 0, start = 0
        while start < total { ranges.append((idx, start, min(start + chunkSize - 1, total - 1))); start += chunkSize; idx += 1 }

        let writer = Synchronized(handle, label: "ChzzkDownloader.ParallelDownloader.writer")
        let startTime = Date()
        let progress = Synchronized(
            ProgressState(downloaded: 0, sampleTime: startTime, sampleBytes: 0),
            label: "ChzzkDownloader.ParallelDownloader.progress")

        func report() {
            let snapshot = progress.withValue { state in
                let now = Date()
                let dt = now.timeIntervalSince(state.sampleTime)
                if dt >= 0.5 {
                    let inst = Double(state.downloaded - state.sampleBytes) / dt
                    state.emaSpeed = state.emaSpeed == 0 ? inst : state.emaSpeed * 0.5 + inst * 0.5
                    state.sampleTime = now
                    state.sampleBytes = state.downloaded
                }
                let speed = state.emaSpeed > 0
                    ? state.emaSpeed
                    : Double(state.downloaded) / max(0.001, now.timeIntervalSince(startTime))
                return (state.downloaded, speed)
            }
            onProgress(snapshot.0, total, snapshot.1)
        }
        report()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = ranges.makeIterator()
            func addNext() -> Bool {
                guard let (_, s, e) = it.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return }
                    if self.isCanceled { throw CancellationError() }
                    await limiter.consume(e - s + 1)   // pace aggregate speed
                    let data = try await self.fetchRange(url: url, headers: headers, session: session, start: s, end: e)
                    try writer.withValue {
                        try $0.seek(toOffset: UInt64(s))
                        $0.write(data)
                    }
                    progress.update {
                        $0.downloaded += data.count
                    }
                    report()
                }
                return true
            }
            for _ in 0..<max(1, connections) where addNext() {}
            while try await group.next() != nil {
                if isCanceled { group.cancelAll(); throw CancellationError() }
                _ = addNext()
            }
        }
        if isCanceled { throw CancellationError() }
        try? handle.close()
        try finalize(partURL: partURL, finalOutput: finalOutput)
        completedSuccessfully = true
    }

    @discardableResult
    func downloadClipWindow(urlString: String, headers: [String: String], finalOutput: URL,
                            connections: Int, rateLimitBytesPerSec: Double = 0,
                            durationSeconds: Double, clipStart: Double, clipEnd: Double,
                            onProgress: @escaping (Int, Int, Double) -> Void) async throws -> Int {
        let limiter = RateLimiter(bytesPerSec: rateLimitBytesPerSec)
        guard let url = URL(string: urlString) else { throw VODError.invalidURL }

        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = max(1, connections)
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true
        config.networkServiceType = .responsiveData
        ProxySupport.apply(to: config)
        let session = ProxySupport.makeSession(config: config)
        defer { session.invalidateAndCancel() }

        let (fileTotal, rangeSupported) = try await probeSize(url: url, headers: headers, session: session)
        guard rangeSupported, fileTotal > 0 else { throw VODError.noManifest }

        // Accurate window from the MP4 sample tables (moov), not a linear time→byte
        // guess: locate the moov + mdat, parse the exact byte span of the clip's
        // samples. On any failure throw so the caller falls back to remote seek.
        guard let layout = try await locateMP4Layout(
                url: url, headers: headers, session: session, fileTotal: fileTotal) else {
            throw VODError.noManifest
        }
        let moovData = try await fetchRange(url: url, headers: headers, session: session,
                                            start: layout.moovStart, end: layout.moovEnd - 1)
        guard let span = MP4ClipIndex.clipByteSpan(
                moov: moovData, clipStart: clipStart, clipEnd: clipEnd, fileTotal: fileTotal) else {
            throw VODError.noManifest
        }
        var metaRanges = [HTTPByteRange(start: 0, end: layout.mdatContentStart - 1)]
        if layout.moovStart >= layout.mdatContentStart {          // moov stored after mdat
            metaRanges.append(HTTPByteRange(start: layout.moovStart, end: layout.moovEnd - 1))
        }
        let logicalRanges = Self.mergeRanges(metaRanges + [HTTPByteRange(start: span.start, end: span.end)])
        guard !logicalRanges.isEmpty else { throw VODError.noManifest }
        let total = logicalRanges.reduce(0) { $0 + $1.length }

        try? FileManager.default.removeItem(at: finalOutput)
        FileManager.default.createFile(atPath: finalOutput.path, contents: nil)
        let handle = try FileHandle(forWritingTo: finalOutput)
        try handle.truncate(atOffset: UInt64(fileTotal))
        defer { try? handle.close() }

        var chunks: [(Int, Int)] = []
        for range in logicalRanges {
            var start = range.start
            while start <= range.end {
                let end = min(range.end, start + chunkSize - 1)
                chunks.append((start, end))
                start = end + 1
            }
        }

        let writer = Synchronized(handle, label: "ChzzkDownloader.ParallelDownloader.clip.writer")
        let startTime = Date()
        let progress = Synchronized(
            ProgressState(downloaded: 0, sampleTime: startTime, sampleBytes: 0),
            label: "ChzzkDownloader.ParallelDownloader.clip.progress")

        func report() {
            let snapshot = progress.withValue { state in
                let now = Date()
                let dt = now.timeIntervalSince(state.sampleTime)
                if dt >= 0.5 {
                    let inst = Double(state.downloaded - state.sampleBytes) / dt
                    state.emaSpeed = state.emaSpeed == 0 ? inst : state.emaSpeed * 0.5 + inst * 0.5
                    state.sampleTime = now
                    state.sampleBytes = state.downloaded
                }
                let speed = state.emaSpeed > 0
                    ? state.emaSpeed
                    : Double(state.downloaded) / max(0.001, now.timeIntervalSince(startTime))
                return (state.downloaded, speed)
            }
            onProgress(snapshot.0, total, snapshot.1)
        }
        report()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = chunks.makeIterator()
            func addNext() -> Bool {
                guard let (start, end) = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return }
                    if self.isCanceled { throw CancellationError() }
                    await limiter.consume(end - start + 1)
                    let data = try await self.fetchRange(url: url, headers: headers, session: session,
                                                         start: start, end: end)
                    try writer.withValue {
                        try $0.seek(toOffset: UInt64(start))
                        try $0.write(contentsOf: data)
                    }
                    progress.update { $0.downloaded += data.count }
                    report()
                }
                return true
            }
            for _ in 0..<max(1, connections) where addNext() {}
            while try await group.next() != nil {
                if isCanceled {
                    group.cancelAll()
                    throw CancellationError()
                }
                _ = addNext()
            }
        }
        if isCanceled { throw CancellationError() }
        report()
        return total
    }

    // MARK: helpers

    private func finalize(partURL: URL, finalOutput: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: partURL.path) else {
            // The temp part vanished (e.g. a duplicate/overlapping run finalized
            // first, or it was cleared externally). If the final file is already in
            // place, accept it; otherwise surface a clear message instead
            // of Foundation's cryptic "The file … doesn't exist".
            if fm.fileExists(atPath: finalOutput.path) { return }
            throw VODError.downloadIncomplete
        }
        try? fm.removeItem(at: finalOutput)
        try fm.moveItem(at: partURL, to: finalOutput)
    }

    private func probeSize(url: URL, headers: [String: String],
                           session: URLSession) async throws -> (Int, Bool) {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return (0, false) }
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let totalStr = cr.split(separator: "/").last, let total = Int(totalStr) {
            return (total, true)
        }
        let len = Int(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
        return (len, false)
    }

    private func fetchRange(url: URL, headers: [String: String], session: URLSession,
                            start: Int, end: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VODError.noManifest }
        if http.statusCode != 206 {
            throw VODError.http(http.statusCode)
        }
        return data
    }

    private struct MP4Layout { let moovStart: Int; let moovEnd: Int; let mdatContentStart: Int }

    /// Walks top-level MP4 box headers (16-byte ranged reads) to find the moov box
    /// and the first mdat content offset. Returns nil for an unexpected layout.
    private func locateMP4Layout(url: URL, headers: [String: String], session: URLSession,
                                 fileTotal: Int) async throws -> MP4Layout? {
        var off = 0
        var moov: (Int, Int)?
        var mdatContent: Int?
        var hops = 0
        while off + 8 <= fileTotal, hops < 128 {
            hops += 1
            let header = try await fetchRange(url: url, headers: headers, session: session,
                                              start: off, end: min(fileTotal - 1, off + 15))
            let hb = [UInt8](header)
            guard hb.count >= 8 else { return nil }
            var size = Int(Self.beU32(hb, 0))
            let type = String(bytes: hb[4..<8], encoding: .ascii) ?? ""
            var headerLen = 8
            if size == 1 {
                guard hb.count >= 16 else { return nil }
                size = Int(Self.beU64(hb, 8)); headerLen = 16
            } else if size == 0 {
                size = fileTotal - off
            }
            if type == "moov" { moov = (off, off + size) }
            if type == "mdat", mdatContent == nil { mdatContent = off + headerLen }
            if moov != nil, mdatContent != nil { break }
            guard size > headerLen else { return nil }
            off += size
        }
        guard let moov, let mdatContent else { return nil }
        return MP4Layout(moovStart: moov.0, moovEnd: moov.1, mdatContentStart: mdatContent)
    }

    private static func beU32(_ b: [UInt8], _ p: Int) -> UInt32 {
        guard p + 4 <= b.count else { return 0 }
        return (UInt32(b[p]) << 24) | (UInt32(b[p + 1]) << 16) | (UInt32(b[p + 2]) << 8) | UInt32(b[p + 3])
    }

    private static func beU64(_ b: [UInt8], _ p: Int) -> UInt64 {
        (UInt64(beU32(b, p)) << 32) | UInt64(beU32(b, p + 4))
    }

    private func downloadWhole(url: URL, headers: [String: String], session: URLSession,
                               partURL: URL, total: Int,
                               onProgress: @escaping (Int, Int, Double) -> Void) async throws {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let start = Date()
        let (tmp, resp) = try await session.download(for: req)
        if isCanceled { try? FileManager.default.removeItem(at: tmp); throw CancellationError() }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw VODError.http(http.statusCode)   // don't save an error page as the video
        }
        try? FileManager.default.removeItem(at: partURL)
        try FileManager.default.moveItem(at: tmp, to: partURL)
        let size = ((try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size]) as? Int) ?? total
        let elapsed = max(0.001, Date().timeIntervalSince(start))
        onProgress(size, max(size, total), Double(size) / elapsed)
    }
}
