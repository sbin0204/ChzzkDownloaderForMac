import Foundation

/// Shared result of the DASH/HLS segment prefetch downloaders: a local,
/// concatenated media file ready for ffmpeg postprocess.
struct SegmentLocalSource {
    let sourceURL: URL
    let workDir: URL
    let localClipStart: Double?
}

final class DASHSegmentDownloader {
    private struct State {
        var canceled = false
        var workDir: URL?
    }

    private struct ProgressState {
        var doneSegments = 0
        var downloadedBytes = 0
        var emaSpeed = 0.0
        var sampleTime = Date()
        var sampleBytes = 0
    }

    private struct Asset {
        let remote: URL
        let local: URL
        let logicalSegment: Bool
    }

    private let state = Synchronized(State(), label: "ChzzkDownloader.DASHSegmentDownloader.state")

    func cancel() {
        let dir = state.withValue { state in
            state.canceled = true
            return state.workDir
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private var isCanceled: Bool {
        state.withValue { $0.canceled }
    }

    func download(segmentPlan: VODSegmentPlan, headers: [String: String], finalOutput: URL,
                  workID: UUID,
                  connections: Int, rateLimitBytesPerSec: Double,
                  clipStart: Double?, clipDuration: Double?,
                  onProgress: @escaping (Int, Int, Int, Double) -> Void) async throws -> SegmentLocalSource {
        let fm = FileManager.default
        let dir = Filename.temporaryURL(for: finalOutput, suffix: ".dash-\(workID.uuidString)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        state.update { $0.workDir = dir }

        let clipEnd = clipStart.flatMap { start in clipDuration.map { start + $0 } }
        let selected = segmentPlan.selectedMedia(clipStart: clipStart, clipEnd: clipEnd)
        guard !selected.isEmpty else { throw VODError.noManifest }

        let firstStart = selected.first?.start ?? 0
        let localClipStart = clipStart.map { max(0, $0 - firstStart) }
        let limiter = RateLimiter(bytesPerSec: rateLimitBytesPerSec)

        var assets: [Asset] = []
        if let initializationURL = segmentPlan.initializationURL,
           let url = URL(string: initializationURL) {
            assets.append(Asset(remote: url, local: dir.appendingPathComponent("init.mp4"), logicalSegment: false))
        }
        for (offset, segment) in selected.enumerated() {
            guard let remote = URL(string: segment.url) else { throw VODError.invalidURL }
            assets.append(Asset(remote: remote,
                                local: dir.appendingPathComponent(String(format: "part_%06d.m4s", offset)),
                                logicalSegment: true))
        }

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

        let progress = Synchronized(ProgressState(), label: "ChzzkDownloader.DASHSegmentDownloader.progress")

        func report(addedBytes: Int, logicalSegment: Bool) {
            let snapshot = progress.withValue { state in
                if logicalSegment { state.doneSegments += 1 }
                state.downloadedBytes += addedBytes
                let now = Date()
                let dt = now.timeIntervalSince(state.sampleTime)
                if dt >= 0.5 {
                    let inst = Double(state.downloadedBytes - state.sampleBytes) / dt
                    state.emaSpeed = state.emaSpeed == 0 ? inst : state.emaSpeed * 0.5 + inst * 0.5
                    state.sampleTime = now
                    state.sampleBytes = state.downloadedBytes
                }
                let speed = state.emaSpeed > 0
                    ? state.emaSpeed
                    : Double(state.downloadedBytes) / max(0.001, now.timeIntervalSince(state.sampleTime))
                return (state.doneSegments, state.downloadedBytes, speed)
            }
            onProgress(snapshot.0, selected.count, snapshot.1, snapshot.2)
        }
        onProgress(0, selected.count, 0, 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = assets.makeIterator()
            func addNext() -> Bool {
                guard let asset = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return }
                    if self.isCanceled { throw CancellationError() }
                    let data = try await self.fetchData(url: asset.remote, headers: headers, session: session)
                    await limiter.consume(data.count)
                    if self.isCanceled { throw CancellationError() }
                    try data.write(to: asset.local)
                    report(addedBytes: data.count, logicalSegment: asset.logicalSegment)
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

        for asset in assets where !fm.fileExists(atPath: asset.local.path) {
            throw SegmentLocalError.missingLocalFile(asset.local.lastPathComponent)
        }
        let localSource = try makeLocalMedia(assets: assets, mediaURL: dir.appendingPathComponent("source.mp4"))
        return SegmentLocalSource(sourceURL: localSource, workDir: dir, localClipStart: localClipStart)
    }

    func cleanup() {
        let dir = state.withValue { $0.workDir }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func fetchData(url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            if isCanceled { throw CancellationError() }
            do {
                var request = URLRequest(url: url)
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw VODError.noManifest }
                guard (200..<300).contains(http.statusCode) else { throw VODError.http(http.statusCode) }
                return data
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? VODError.noManifest
    }

    private func makeLocalMedia(assets: [Asset], mediaURL: URL) throws -> URL {
        try? FileManager.default.removeItem(at: mediaURL)
        FileManager.default.createFile(atPath: mediaURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: mediaURL)
        defer { try? output.close() }

        for asset in assets {
            let input = try FileHandle(forReadingFrom: asset.local)
            do {
                defer { try? input.close() }
                while true {
                    let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                }
            }
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size]) as? Int) ?? 0
        guard size > 0 else { throw SegmentLocalError.missingLocalFile(mediaURL.lastPathComponent) }
        return mediaURL
    }
}

private struct HLSRemoteSegment {
    let url: URL
    let duration: Double
    let start: Double
    let index: Int
}

final class HLSParallelDownloader {
    private struct State {
        var canceled = false
        var workDir: URL?
    }

    private struct ProgressState {
        var doneSegments = 0
        var downloadedBytes = 0
        var emaSpeed = 0.0
        var sampleTime = Date()
        var sampleBytes = 0
    }

    private struct Asset {
        let remote: URL
        let local: URL
        let logicalSegment: Bool
    }

    private let state = Synchronized(State(), label: "ChzzkDownloader.HLSParallelDownloader.state")

    func cancel() {
        let dir = state.withValue { state in
            state.canceled = true
            return state.workDir
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private var isCanceled: Bool {
        state.withValue { $0.canceled }
    }

    func download(playlistURLString: String, headers: [String: String], finalOutput: URL,
                  workID: UUID,
                  connections: Int, rateLimitBytesPerSec: Double,
                  clipStart: Double?, clipDuration: Double?,
                  onProgress: @escaping (Int, Int, Int, Double) -> Void) async throws -> SegmentLocalSource {
        guard let playlistURL = URL(string: playlistURLString) else { throw VODError.invalidURL }
        let fm = FileManager.default
        let dir = Filename.temporaryURL(for: finalOutput, suffix: ".hls-\(workID.uuidString)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        state.update { $0.workDir = dir }

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

        let text = try await fetchText(url: playlistURL, headers: headers, session: session)
        let parsed = try parsePlaylist(text, baseURL: playlistURL)
        let clipEnd = clipStart.flatMap { start in clipDuration.map { start + $0 } }
        let selected = selectSegments(parsed.segments, clipStart: clipStart, clipEnd: clipEnd)
        guard !selected.isEmpty else { throw VODError.noManifest }

        let firstStart = selected.first?.start ?? 0
        let localClipStart = clipStart.map { max(0, $0 - firstStart) }
        let limiter = RateLimiter(bytesPerSec: rateLimitBytesPerSec)

        var assets: [Asset] = []
        let initFile = "init.mp4"
        if let mapURL = parsed.mapURL {
            assets.append(Asset(remote: mapURL, local: dir.appendingPathComponent(initFile), logicalSegment: false))
        }
        for (offset, segment) in selected.enumerated() {
            assets.append(Asset(remote: segment.url,
                                local: dir.appendingPathComponent(String(format: "seg_%06d.m4v", offset)),
                                logicalSegment: true))
        }

        let progress = Synchronized(ProgressState(), label: "ChzzkDownloader.HLSParallelDownloader.progress")

        func report(addedBytes: Int, logicalSegment: Bool) {
            let snapshot = progress.withValue { state in
                if logicalSegment { state.doneSegments += 1 }
                state.downloadedBytes += addedBytes
                let now = Date()
                let dt = now.timeIntervalSince(state.sampleTime)
                if dt >= 0.5 {
                    let inst = Double(state.downloadedBytes - state.sampleBytes) / dt
                    state.emaSpeed = state.emaSpeed == 0 ? inst : state.emaSpeed * 0.5 + inst * 0.5
                    state.sampleTime = now
                    state.sampleBytes = state.downloadedBytes
                }
                let speed = state.emaSpeed > 0
                    ? state.emaSpeed
                    : Double(state.downloadedBytes) / max(0.001, now.timeIntervalSince(state.sampleTime))
                return (state.doneSegments, state.downloadedBytes, speed)
            }
            onProgress(snapshot.0, selected.count, snapshot.1, snapshot.2)
        }
        onProgress(0, selected.count, 0, 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = assets.makeIterator()
            func addNext() -> Bool {
                guard let asset = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return }
                    if self.isCanceled { throw CancellationError() }
                    let data = try await self.fetchData(url: asset.remote, headers: headers, session: session)
                    await limiter.consume(data.count)
                    if self.isCanceled { throw CancellationError() }
                    // HLS segment temp files can be very large. Avoid Foundation's
                    // atomic write path here because it may stage through the
                    // system temporary volume; write directly into the final
                    // output folder's work directory instead.
                    try data.write(to: asset.local)
                    report(addedBytes: data.count, logicalSegment: asset.logicalSegment)
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

        for asset in assets where !fm.fileExists(atPath: asset.local.path) {
            throw SegmentLocalError.missingLocalFile(asset.local.lastPathComponent)
        }
        let localSource = try makeLocalMedia(assets: assets, mediaURL: dir.appendingPathComponent("source.mp4"))
        return SegmentLocalSource(sourceURL: localSource, workDir: dir, localClipStart: localClipStart)
    }

    func cleanup() {
        let dir = state.withValue { $0.workDir }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func fetchText(url: URL, headers: [String: String], session: URLSession) async throws -> String {
        let data = try await fetchData(url: url, headers: headers, session: session)
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchData(url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            if isCanceled { throw CancellationError() }
            do {
                var request = URLRequest(url: url)
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw VODError.noManifest }
                guard (200..<300).contains(http.statusCode) else { throw VODError.http(http.statusCode) }
                return data
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? VODError.noManifest
    }

    private func parsePlaylist(_ text: String, baseURL: URL) throws -> (mapURL: URL?, segments: [HLSRemoteSegment]) {
        let lines = text.components(separatedBy: .newlines)
        var mapURL: URL?
        var pendingDuration: Double?
        var cursor = 0.0
        var segments: [HLSRemoteSegment] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MAP:"),
               let uri = quotedAttribute("URI", in: line),
               let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                mapURL = resolved
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if !line.hasPrefix("#"), let duration = pendingDuration,
                      let resolved = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                segments.append(HLSRemoteSegment(url: resolved, duration: duration,
                                                 start: cursor, index: segments.count))
                cursor += duration
                pendingDuration = nil
            }
        }
        if segments.isEmpty { throw VODError.noManifest }
        return (mapURL, segments)
    }

    private func selectSegments(_ segments: [HLSRemoteSegment], clipStart: Double?, clipEnd: Double?) -> [HLSRemoteSegment] {
        guard let clipStart, let clipEnd, clipEnd > clipStart else { return segments }
        return segments.filter { segment in
            let segmentEnd = segment.start + segment.duration
            return segmentEnd > clipStart && segment.start < clipEnd
        }
    }

    private func makeLocalMedia(assets: [Asset], mediaURL: URL) throws -> URL {
        try? FileManager.default.removeItem(at: mediaURL)
        FileManager.default.createFile(atPath: mediaURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: mediaURL)
        defer { try? output.close() }

        for asset in assets {
            let input = try FileHandle(forReadingFrom: asset.local)
            do {
                defer { try? input.close() }
                while true {
                    let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                }
            }
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size]) as? Int) ?? 0
        guard size > 0 else { throw SegmentLocalError.missingLocalFile(mediaURL.lastPathComponent) }
        return mediaURL
    }

    private func quotedAttribute(_ name: String, in line: String) -> String? {
        let needle = "\(name)=\""
        guard let start = line.range(of: needle) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

private enum SegmentLocalError: LocalizedError {
    case missingLocalFile(String)

    var errorDescription: String? {
        switch self {
        case .missingLocalFile(let name):
            return "세그먼트 로컬 작업 파일이 누락되었습니다: \(name)"
        }
    }
}
