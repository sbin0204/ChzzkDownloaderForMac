import Foundation

struct ImportedVODSource {
    var title: String
    var channelName: String
    var duration: Int
    var variants: [VODVariant]
}

enum VODSourceImportError: LocalizedError {
    case noCandidates
    case noUsableSource

    var errorDescription: String? {
        switch self {
        case .noCandidates:
            return "입력한 내용에서 vod_chunklist.m3u8, vod_playlist.m3u8, mpd 소스를 찾지 못했습니다."
        case .noUsableSource:
            return "찾은 소스가 만료되었거나 접근할 수 없습니다."
        }
    }
}

enum VODSourceImporter {
    static let maxSourceURLLength = 4096

    static func importURLString(_ value: String) async throws -> ImportedVODSource {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSupportedSourceURL(trimmed) else { throw VODError.invalidURL }
        let sourceName = URL(string: trimmed)?.deletingPathExtension().lastPathComponent ?? "가져온 소스"
        return try await importText(trimmed, sourceName: sourceName.isEmpty ? "가져온 소스" : sourceName)
    }

    static func isSupportedSourceURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxSourceURLLength else { return false }
        return mediaKind(from: trimmed) != nil && !isAudioOnly(trimmed)
    }

    static func importText(_ text: String, sourceName: String = "가져온 소스") async throws -> ImportedVODSource {
        let candidates = sourceCandidates(from: text)

        for candidate in candidates {
            do {
                let variants = try await variants(from: candidate)
                if !variants.isEmpty {
                    return ImportedVODSource(
                        title: ChzzkVODAPI.sanitize(sourceName.isEmpty ? "가져온 VOD" : sourceName),
                        channelName: "가져온 소스",
                        duration: 0,
                        variants: variants.sorted { $0.quality < $1.quality })
                }
            } catch {
                continue
            }
        }
        if let imported = importHARSegments(from: text, sourceName: sourceName) {
            return imported
        }
        guard !candidates.isEmpty else { throw VODSourceImportError.noCandidates }
        throw VODSourceImportError.noUsableSource
    }

    static func sourceCandidates(from text: String) -> [String] {
        if let harCandidates = collectHARCandidates(from: text) {
            return rankedUnique(harCandidates)
        }

        var candidates: [String] = []
        collectJSONStringCandidates(from: text, into: &candidates)
        collectRegexCandidates(from: text, into: &candidates)
        return rankedUnique(candidates)
    }

    private static func variants(from candidate: String) async throws -> [VODVariant] {
        guard let url = URL(string: candidate) else { throw VODError.invalidURL }
        let lower = url.path.lowercased()
        if lower.hasSuffix(".mp4") || candidate.lowercased().contains(".mp4?") {
            return [VODVariant(quality: inferredQuality(from: candidate), url: candidate)]
        }
        if lower.hasSuffix(".mpd") || candidate.lowercased().contains(".mpd?") {
            return try await dashVariants(url: url)
        }
        if lower.hasSuffix(".m3u8") || candidate.lowercased().contains(".m3u8?") {
            return try await hlsVariants(url: url)
        }
        throw VODSourceImportError.noUsableSource
    }

    private static func dashVariants(url: URL) async throws -> [VODVariant] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/dash+xml", forHTTPHeaderField: "Accept")
        for (key, value) in VODRequestHeaders.media(cookies: Cookies(NID_SES: "", NID_AUT: "")) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await ProxySupport.session().data(for: request)
        try check(response)
        return DASHParser.parse(data, manifestURL: url)
            .map { VODVariant(quality: $0.quality, url: $0.url, segmentPlan: $0.segmentPlan) }
    }

    private static func hlsVariants(url: URL) async throws -> [VODVariant] {
        let text = try await fetchText(url: url)
        if text.contains("#EXT-X-STREAM-INF") {
            let variants = parseMasterPlaylist(text, baseURL: url)
            if !variants.isEmpty { return variants }
        }
        if text.contains("#EXTINF") {
            // AES-encrypted media playlists must go through ffmpeg: the parallel
            // segment downloader fetches raw segments and cannot decrypt them.
            let needsRemote = isAESEncrypted(playlist: text, url: url.absoluteString)
            return [VODVariant(quality: inferredQuality(from: url.absoluteString),
                               url: url.absoluteString, isHLS: true, requiresRemoteHLS: needsRemote)]
        }
        throw VODSourceImportError.noUsableSource
    }

    /// True when an HLS playlist (or its URL) signals AES encryption, which the
    /// parallel raw-segment downloader cannot handle — ffmpeg must demux it.
    static func isAESEncrypted(playlist: String, url: String) -> Bool {
        if url.lowercased().contains("hls-aes") { return true }
        guard playlist.contains("#EXT-X-KEY") else { return false }
        // METHOD=NONE means the key line only clears a previous key (not encrypted).
        return !playlist.localizedCaseInsensitiveContains("METHOD=NONE")
    }

    private static func fetchText(url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (key, value) in VODRequestHeaders.media(cookies: Cookies(NID_SES: "", NID_AUT: "")) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await ProxySupport.session().data(for: request)
        try check(response)
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseMasterPlaylist(_ text: String, baseURL: URL) -> [VODVariant] {
        let lines = text.components(separatedBy: .newlines)
        var variants: [VODVariant] = []
        for (index, raw) in lines.enumerated() where raw.contains("#EXT-X-STREAM-INF") {
            guard index + 1 < lines.count else { continue }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let rel = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rel.isEmpty, !rel.hasPrefix("#"),
                  let url = URL(string: rel, relativeTo: baseURL)?.absoluteURL else { continue }
            // A child URL (or the master URL) marked hls-aes is AES-encrypted and
            // must be demuxed by ffmpeg, not the parallel segment downloader.
            let needsRemote = url.absoluteString.lowercased().contains("hls-aes")
                || baseURL.absoluteString.lowercased().contains("hls-aes")
            variants.append(VODVariant(quality: playlistQuality(from: line), url: url.absoluteString,
                                       isHLS: true, requiresRemoteHLS: needsRemote))
        }
        return variants
    }

    private static func playlistQuality(from line: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"RESOLUTION=(\d+)x(\d+)"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let wRange = Range(match.range(at: 1), in: line),
              let hRange = Range(match.range(at: 2), in: line) else {
            return 0
        }
        let width = Int(line[wRange]) ?? 0
        let height = Int(line[hRange]) ?? 0
        return min(width, height)
    }

    private static func inferredQuality(from url: String) -> Int {
        let patterns = [#"(?i)(\d{3,4})p"#, #"(?i)[_/](\d{3,4})[_/]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
                  let range = Range(match.range(at: 1), in: url),
                  let quality = Int(url[range]) else { continue }
            return quality
        }
        return 0
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw VODError.noManifest }
        guard (200..<300).contains(http.statusCode) else { throw VODError.http(http.statusCode) }
    }

    private static func collectJSONStringCandidates(from text: String, into candidates: inout [String]) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        collectJSONValues(json, into: &candidates)
    }

    private static func collectHARCandidates(from text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let log = root["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else {
            return nil
        }

        var candidates: [String] = []
        for entry in entries {
            let request = entry["request"] as? [String: Any]
            let requestURL = request?["url"] as? String ?? ""
            appendCandidate(requestURL, into: &candidates)

            guard shouldInspectHARBody(entry: entry, requestURL: requestURL) else { continue }
            if let response = entry["response"] as? [String: Any],
               let content = response["content"] as? [String: Any],
               let body = content["text"] as? String {
                collectJSONValues(body, into: &candidates)
            }
        }
        return candidates
    }

    private struct HARMediaSegment {
        var url: String
        var timestampMS: Int64?
        var sequence: Int?
        var quality: Int
        var entryIndex: Int
    }

    private static func importHARSegments(from text: String, sourceName: String) -> ImportedVODSource? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let log = root["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else {
            return nil
        }

        var grouped: [String: [HARMediaSegment]] = [:]
        for (index, entry) in entries.enumerated() {
            guard let request = entry["request"] as? [String: Any],
                  let response = entry["response"] as? [String: Any],
                  let content = response["content"] as? [String: Any],
                  let mimeType = content["mimeType"] as? String,
                  mimeType.localizedCaseInsensitiveContains("video/mp4"),
                  let requestURL = request["url"] as? String else {
                continue
            }
            let cleaned = cleanURL(requestURL)
            guard isSegmentURL(cleaned), let group = segmentGroupKey(cleaned) else { continue }
            var parsed = parseSegmentIdentity(cleaned)
            parsed.url = cleaned
            parsed.entryIndex = index
            grouped[group, default: []].append(parsed)
        }

        guard let best = grouped.values.max(by: { $0.count < $1.count }), !best.isEmpty else {
            return nil
        }
        let sorted = sortSegments(best)
        let media = buildMediaSegments(sorted)
        guard !media.isEmpty else { return nil }
        let quality = sorted.first(where: { $0.quality > 0 })?.quality ?? 0
        let plan = VODSegmentPlan(initializationURL: nil, media: media)
        return ImportedVODSource(
            title: ChzzkVODAPI.sanitize(sourceName.isEmpty ? "가져온 VOD" : sourceName),
            channelName: "HAR 캡처 조각",
            duration: Int(ceil(media.reduce(0) { max($0, $1.start + $1.duration) })),
            variants: [VODVariant(quality: quality, url: media.first?.url ?? "", segmentPlan: plan)])
    }

    private static func isSegmentURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("/live_rewind/") &&
            (lower.contains(".m4v") || lower.contains(".m4s") || lower.contains(".mp4"))
    }

    private static func segmentGroupKey(_ raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        var path = url.path
        guard let slash = path.lastIndex(of: "/") else { return nil }
        path.removeSubrange(slash...)
        return "\(url.host ?? "")\(path)"
    }

    private static func parseSegmentIdentity(_ url: String) -> HARMediaSegment {
        let quality = inferredQuality(from: url)
        guard let regex = try? NSRegularExpression(pattern: #"_(\d{13})_(\d+)_"#),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else {
            return HARMediaSegment(url: url, timestampMS: nil, sequence: nil,
                                   quality: quality, entryIndex: 0)
        }
        let timestamp = Range(match.range(at: 1), in: url).flatMap { Int64(url[$0]) }
        let sequence = Range(match.range(at: 2), in: url).flatMap { Int(url[$0]) }
        return HARMediaSegment(url: url, timestampMS: timestamp, sequence: sequence,
                               quality: quality, entryIndex: 0)
    }

    private static func sortSegments(_ segments: [HARMediaSegment]) -> [HARMediaSegment] {
        var seen = Set<String>()
        return segments
            .filter { seen.insert($0.url).inserted }
            .sorted {
                switch ($0.timestampMS, $1.timestampMS) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs < rhs
                case _ where $0.sequence != $1.sequence:
                    return ($0.sequence ?? Int.max) < ($1.sequence ?? Int.max)
                default:
                    return $0.entryIndex < $1.entryIndex
                }
            }
    }

    private static func buildMediaSegments(_ segments: [HARMediaSegment]) -> [VODMediaSegment] {
        guard !segments.isEmpty else { return [] }
        let defaultDuration = inferredSegmentDuration(segments) ?? 2.0
        let firstTimestamp = segments.first?.timestampMS
        return segments.enumerated().map { offset, segment in
            let start: Double
            if let firstTimestamp, let timestamp = segment.timestampMS {
                start = max(0, Double(timestamp - firstTimestamp) / 1000.0)
            } else {
                start = Double(offset) * defaultDuration
            }
            let duration: Double
            if offset + 1 < segments.count,
               let timestamp = segment.timestampMS,
               let nextTimestamp = segments[offset + 1].timestampMS,
               nextTimestamp > timestamp {
                duration = Double(nextTimestamp - timestamp) / 1000.0
            } else {
                duration = defaultDuration
            }
            return VODMediaSegment(url: segment.url, start: start, duration: duration, index: offset)
        }
    }

    private static func inferredSegmentDuration(_ segments: [HARMediaSegment]) -> Double? {
        let timestamps = segments.compactMap(\.timestampMS).sorted()
        let deltas = zip(timestamps, timestamps.dropFirst())
            .map { Double($1 - $0) / 1000.0 }
            .filter { $0 > 0 && $0 <= 30 }
        guard !deltas.isEmpty else { return nil }
        return deltas.sorted()[deltas.count / 2]
    }

    private static func shouldInspectHARBody(entry: [String: Any], requestURL: String) -> Bool {
        let lowerURL = requestURL.lowercased()
        if requestURL.isEmpty { return true }
        if lowerURL.contains("/service/") &&
            (lowerURL.contains("/videos/") || lowerURL.contains("/clips/") || lowerURL.contains("/vod/")) {
            return true
        }

        guard let response = entry["response"] as? [String: Any],
              let content = response["content"] as? [String: Any],
              let body = content["text"] as? String else {
            return false
        }
        return body.contains("liveRewindPlaybackJson") ||
            body.contains("playbackJson") ||
            body.contains("vod_playlist.m3u8") ||
            body.contains("slitvod")
    }

    private static func collectJSONValues(_ value: Any, into candidates: inout [String]) {
        if let string = value as? String {
            appendURLs(in: string, into: &candidates)
            if let data = string.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data) {
                collectJSONValues(nested, into: &candidates)
            }
        } else if let array = value as? [Any] {
            for item in array { collectJSONValues(item, into: &candidates) }
        } else if let dict = value as? [String: Any] {
            for item in dict.values { collectJSONValues(item, into: &candidates) }
        }
    }

    private static func collectRegexCandidates(from text: String, into candidates: inout [String]) {
        appendURLs(in: text, into: &candidates)
    }

    private static func appendURLs(in text: String, into candidates: inout [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)]+"#) else { return }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let cleaned = cleanURL(String(text[range]))
            appendCandidate(cleaned, into: &candidates)
        }
    }

    private static func appendCandidate(_ raw: String, into candidates: inout [String]) {
        let cleaned = cleanURL(raw)
        guard mediaKind(from: cleaned) != nil, !isAudioOnly(cleaned) else { return }
        candidates.append(cleaned)
    }

    private enum MediaKind {
        case hls
        case dash
        case mp4
    }

    private static func mediaKind(from raw: String) -> MediaKind? {
        let lower = raw.lowercased()
        guard let url = URL(string: raw) else { return nil }
        let path = url.path.lowercased()

        if path.hasSuffix(".m3u8") || lower.contains(".m3u8?") { return .hls }
        if path.hasSuffix(".mpd") || lower.contains(".mpd?") { return .dash }
        if path.hasSuffix(".mp4") || lower.contains(".mp4?") { return .mp4 }
        return nil
    }

    private static func isAudioOnly(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("audioonly") || lower.contains("audio_only")
    }

    private static func cleanURL(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\\u0026"#, with: "&")
            .replacingOccurrences(of: #"\/"#, with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: #""',;\"[]{}"#))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    }

    private static func rankedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result.enumerated()
            .sorted {
                let left = candidateRank($0.element)
                let right = candidateRank($1.element)
                if left == right { return $0.offset < $1.offset }
                return left > right
            }
            .map(\.element)
    }

    private static func candidateRank(_ url: String) -> Int {
        let lower = url.lowercased()
        var score = 0
        if lower.contains(".mpd") { score += 40 }
        if lower.contains(".m3u8") { score += 30 }
        if lower.contains(".mp4") { score += 10 }
        if lower.contains("vod_playlist") { score += 30 }
        if lower.contains("slitvod") { score += 20 }
        if lower.contains("live_rewind") { score += 10 }
        if lower.contains("_hls_playlist") { score += 5 }
        return score
    }
}
