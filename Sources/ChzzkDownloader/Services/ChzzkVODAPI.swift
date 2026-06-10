import Foundation

struct VODMeta {
    var title: String
    var channelName: String
    var duration: Int
}

private extension String {
    func localizedCaseInsensitiveComparePrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}

enum VODError: LocalizedError {
    case invalidURL
    case invalidCookies
    case unencoded
    case noManifest
    case http(Int)
    case downloadIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "잘못된 VOD URL입니다. (chzzk.naver.com/video/... 또는 /clips/...)"
        case .invalidCookies: return "쿠키가 유효하지 않습니다. 성인 인증이 필요한 영상일 수 있습니다."
        case .unencoded: return "아직 인코딩되지 않은 영상입니다 (.m3u8)."
        case .noManifest: return "매니페스트를 가져오지 못했습니다."
        case .http(let code): return "네트워크 오류 (HTTP \(code))."
        case .downloadIncomplete: return "다운로드 임시 파일이 사라져 완료하지 못했습니다. 다시 시도해 주세요(처음부터 다시 받습니다)."
        }
    }
}

/// Resolves Chzzk VOD/clip URLs to downloadable media variants.
enum ChzzkVODAPI {
    static let chzzk = "https://api.chzzk.naver.com"
    static let naver = "https://apis.naver.com"
    static let videohub = "https://api-videohub.naver.com"
    static let maxPageURLLength = 512
    private static let maxContentIDLength = 128

    static func parseURL(_ raw: String) -> (type: String, no: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= maxPageURLLength else { return nil }
        guard s.rangeOfCharacter(from: .newlines) == nil else { return nil }
        if !s.localizedCaseInsensitiveComparePrefix("http://"),
           !s.localizedCaseInsensitiveComparePrefix("https://") {
            s = "https://" + s
        }
        guard let components = URLComponents(string: s),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              host == "chzzk.naver.com" || host == "www.chzzk.naver.com" else {
            return nil
        }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let type = String(parts[0])
        let no = String(parts[1])
        guard ["video", "clips"].contains(type),
              no.count <= maxContentIDLength,
              Validate.matches(Validate.safeChannelID, no) else {
            return nil
        }
        return (type, no)
    }

    static func resolve(urlString: String, cookies: Cookies) async throws -> (VODMeta, [VODVariant]) {
        guard let (type, no) = parseURL(urlString) else { throw VODError.invalidURL }
        if type == "video" { return try await resolveVideo(no, cookies: cookies) }
        return try await resolveClip(no, cookies: cookies)
    }

    // MARK: video

    private static func resolveVideo(_ no: String, cookies: Cookies) async throws -> (VODMeta, [VODVariant]) {
        let json = try await getJSON("\(chzzk)/service/v2/videos/\(no)", cookies: cookies)
        let content = json["content"] as? [String: Any] ?? [:]
        let videoId = content["videoId"] as? String
        let inKey = content["inKey"] as? String
        let adult = content["adult"] as? Bool ?? false
        let liveRewind = content["liveRewindPlaybackJson"] as? String

        let meta = VODMeta(
            title: sanitize(content["videoTitle"] as? String ?? "video"),
            channelName: (content["channel"] as? [String: Any])?["channelName"] as? String ?? "Chzzk",
            duration: content["duration"] as? Int ?? 0)

        if adult && (videoId == nil) { throw VODError.invalidCookies }

        let variants: [VODVariant]
        if let videoId, let inKey {
            do {
                variants = try await dashVariants(videoId: videoId, inKey: inKey)
            } catch {
                if let rewind = liveRewind, !rewind.isEmpty {
                    variants = try await m3u8Variants(rewindJson: rewind)
                } else {
                    throw error
                }
            }
        } else if let rewind = liveRewind, !rewind.isEmpty {
            variants = try await m3u8Variants(rewindJson: rewind)
        } else {
            throw VODError.noManifest
        }
        if variants.isEmpty { throw VODError.noManifest }
        return (meta, variants)
    }

    private static func dashVariants(videoId: String, inKey: String) async throws -> [VODVariant] {
        let manifestURL = try playbackURL(videoId: videoId, inKey: inKey)
        var req = URLRequest(url: manifestURL, timeoutInterval: 30)
        req.setValue("application/dash+xml", forHTTPHeaderField: "Accept")
        req.setValue(VODRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(VODRequestHeaders.referer, forHTTPHeaderField: "Referer")
        req.setValue(VODRequestHeaders.origin, forHTTPHeaderField: "Origin")
        let (data, resp) = try await ProxySupport.session().data(for: req)
        try check(resp)
        let reps = DASHParser.parse(data, manifestURL: manifestURL)
        return reps.map { VODVariant(quality: $0.quality, url: $0.url, segmentPlan: $0.segmentPlan) }
            .sorted { $0.quality < $1.quality }
    }

    private static func m3u8Variants(rewindJson: String) async throws -> [VODVariant] {
        guard let data = rewindJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = obj["media"] as? [[String: Any]],
              let master = media.first?["path"] as? String,
              let masterURL = URL(string: master) else { throw VODError.noManifest }

        var req = URLRequest(url: masterURL, timeoutInterval: 30)
        for (k, v) in VODRequestHeaders.media(cookies: Cookies(NID_SES: "", NID_AUT: "")) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (mdata, resp) = try await ProxySupport.session().data(for: req)
        try check(resp)
        let text = String(decoding: mdata, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines)
        var variants: [VODVariant] = []
        for (i, line) in lines.enumerated() where line.contains("#EXT-X-STREAM-INF") {
            guard let r = try? NSRegularExpression(pattern: #"RESOLUTION=(\d+)x(\d+)"#),
                  let m = r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let wR = Range(m.range(at: 1), in: line), let hR = Range(m.range(at: 2), in: line),
                  i + 1 < lines.count else { continue }
            let w = Int(line[wR]) ?? 0, h = Int(line[hR]) ?? 0
            let rel = lines[i + 1].trimmingCharacters(in: .whitespaces)
            guard !rel.isEmpty, let abs = URL(string: rel, relativeTo: masterURL)?.absoluteString else { continue }
            variants.append(VODVariant(quality: min(w, h), url: abs, isHLS: true))
        }
        return variants.sorted { $0.quality < $1.quality }
    }

    // MARK: clip

    private static func resolveClip(_ no: String, cookies: Cookies) async throws -> (VODMeta, [VODVariant]) {
        let json = try await getJSON(
            "\(chzzk)/service/v1/clips/\(no)/detail?optionalProperties=OWNER_CHANNEL", cookies: cookies)
        let content = json["content"] as? [String: Any] ?? [:]
        if (content["vodStatus"] as? String) == "NONE" { throw VODError.unencoded }
        guard let clipId = content["videoId"] as? String else { throw VODError.noManifest }

        let owner = ((content["optionalProperty"] as? [String: Any])?["ownerChannel"] as? [String: Any])
        let meta = VODMeta(
            title: sanitize(content["clipTitle"] as? String ?? "clip"),
            channelName: owner?["channelName"] as? String ?? "Chzzk",
            duration: content["duration"] as? Int ?? 0)

        let card = try await getJSON(
            "\(videohub)/shortformhub/feeds/v3/card?serviceType=CHZZK&seedMediaId=\(clipId)&mediaType=VOD",
            cookies: cookies)
        let cardContent = ((card["card"] as? [String: Any])?["content"] as? [String: Any]) ?? [:]
        if let err = cardContent["error"] as? [String: Any] {
            if (err["errorCode"] as? String) == "ADULT_AUTH_REQUIRED" { throw VODError.invalidCookies }
            throw VODError.noManifest
        }
        let list = ((((cardContent["vod"] as? [String: Any])?["playback"] as? [String: Any])?["videos"]
                     as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        var variants: [VODVariant] = []
        for v in list {
            let enc = v["encodingOption"] as? [String: Any] ?? [:]
            guard let w = enc["width"] as? Int, let h = enc["height"] as? Int,
                  let src = v["source"] as? String else { continue }
            variants.append(VODVariant(quality: min(w, h), url: src))
        }
        if variants.isEmpty { throw VODError.noManifest }
        return (meta, variants.sorted { $0.quality < $1.quality })
    }

    // MARK: helpers

    private static func getJSON(_ urlString: String, cookies: Cookies) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw VODError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(VODRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(VODRequestHeaders.referer, forHTTPHeaderField: "Referer")
        req.setValue(ChzzkAPI.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        let (data, resp) = try await ProxySupport.session().data(for: req)
        try check(resp)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func check(_ resp: URLResponse) throws {
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            if ChzzkAPI.isAuthFailureStatus(http.statusCode) {
                throw VODError.invalidCookies
            }
            throw VODError.http(http.statusCode)
        }
    }

    private static func playbackURL(videoId: String, inKey: String) throws -> URL {
        guard let base = URL(string: "\(naver)/neonplayer/vodplay/v2/playback") else {
            throw VODError.noManifest
        }
        let pathURL = base.appendingPathComponent(videoId)
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else {
            throw VODError.noManifest
        }
        components.queryItems = [URLQueryItem(name: "key", value: inKey)]
        guard let url = components.url else { throw VODError.noManifest }
        return url
    }

    static func sanitize(_ s: String) -> String {
        Validate.sanitizeFilename(s, fallback: "video")
    }
}

/// DASH MPD parser: collects Representation URLs and, when present, concrete
/// SegmentTemplate/SegmentTimeline parts. Partial VOD downloads rely on this
/// part list to avoid downloading from 0 seconds before cutting locally.
final class DASHParser: NSObject, XMLParserDelegate {
    struct Rep { var quality: Int; var url: String; var segmentPlan: VODSegmentPlan? }

    private struct SegmentTemplateInfo {
        var timescale: Double = 1
        var media: String?
        var initialization: String?
        var startNumber: Int = 1
        var duration: Int64?
        var timeline: [TimelineEntry] = []
    }

    private struct TimelineEntry {
        var t: Int64?
        var d: Int64
        var r: Int
    }

    private enum TemplateScope {
        case adaptation
        case representation
    }

    private var reps: [Rep] = []
    private var curW = 0, curH = 0
    private var curRepresentationID = ""
    private var curBandwidth: Int?
    private var inRep = false
    private var inAdaptation = false
    private var capturingBaseURL = false
    private var baseURLScope: String?
    private var baseURLText = ""
    private var mpdBaseURL: String?
    private var periodBaseURL: String?
    private var adaptationBaseURL: String?
    private var representationBaseURL: String?
    private var adaptationTemplate: SegmentTemplateInfo?
    private var representationTemplate: SegmentTemplateInfo?
    private var openTemplateScope: TemplateScope?
    private var elementStack: [String] = []
    private var mediaPresentationDuration: Double?

    static func parse(_ data: Data, manifestURL: URL) -> [Rep] {
        let p = DASHParser()
        p.manifestURL = manifestURL
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.reps
    }

    private var manifestURL: URL?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        let element = localName(element)
        elementStack.append(element)

        if element == "MPD" {
            mediaPresentationDuration = Self.parseISODuration(attrs["mediaPresentationDuration"] ?? "")
        } else if element == "AdaptationSet" {
            inAdaptation = true
            adaptationBaseURL = nil
            adaptationTemplate = nil
        } else if element == "Representation" {
            inRep = true
            curW = Int(attrs["width"] ?? "") ?? 0
            curH = Int(attrs["height"] ?? "") ?? 0
            curRepresentationID = attrs["id"] ?? ""
            curBandwidth = Int(attrs["bandwidth"] ?? "")
            representationBaseURL = nil
            representationTemplate = nil
        } else if element == "BaseURL" {
            capturingBaseURL = true
            baseURLText = ""
            baseURLScope = currentBaseURLScope()
        } else if element == "SegmentTemplate" {
            let template = SegmentTemplateInfo(
                timescale: max(1, Double(Int64(attrs["timescale"] ?? "") ?? 1)),
                media: attrs["media"],
                initialization: attrs["initialization"],
                startNumber: Int(attrs["startNumber"] ?? "") ?? 1,
                duration: Int64(attrs["duration"] ?? ""),
                timeline: [])
            if inRep {
                representationTemplate = template
                openTemplateScope = .representation
            } else if inAdaptation {
                adaptationTemplate = template
                openTemplateScope = .adaptation
            }
        } else if element == "S", let openTemplateScope,
                  let duration = Int64(attrs["d"] ?? "") {
            let entry = TimelineEntry(
                t: Int64(attrs["t"] ?? ""),
                d: duration,
                r: Int(attrs["r"] ?? "") ?? 0)
            switch openTemplateScope {
            case .adaptation:
                adaptationTemplate?.timeline.append(entry)
            case .representation:
                representationTemplate?.timeline.append(entry)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingBaseURL { baseURLText += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let element = localName(element)
        if element == "BaseURL", capturingBaseURL {
            capturingBaseURL = false
            let url = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch baseURLScope {
            case "Representation":
                representationBaseURL = url
            case "AdaptationSet":
                adaptationBaseURL = url
            case "Period":
                periodBaseURL = url
            default:
                mpdBaseURL = url
            }
            baseURLScope = nil
        } else if element == "SegmentTemplate" {
            openTemplateScope = nil
        } else if element == "Representation" {
            finishRepresentation()
            inRep = false
        } else if element == "AdaptationSet" {
            inAdaptation = false
            adaptationBaseURL = nil
            adaptationTemplate = nil
        } else if element == "Period" {
            periodBaseURL = nil
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private func finishRepresentation() {
        guard curW > 0, curH > 0, let baseURL = resolvedBaseURL() else { return }
        let directURL = baseURL.absoluteString
        guard !directURL.hasSuffix("/hls/") else { return }

        let template = representationTemplate ?? adaptationTemplate
        let segmentPlan = buildSegmentPlan(template: template, baseURL: baseURL)
        let mediaURL = segmentPlan?.media.first?.url
        reps.append(Rep(quality: min(curW, curH), url: mediaURL ?? directURL, segmentPlan: segmentPlan))
    }

    private func currentBaseURLScope() -> String {
        if inRep { return "Representation" }
        if inAdaptation { return "AdaptationSet" }
        if elementStack.contains("Period") { return "Period" }
        return "MPD"
    }

    private func resolvedBaseURL() -> URL? {
        guard var base = manifestURL else { return nil }
        for raw in [mpdBaseURL, periodBaseURL, adaptationBaseURL, representationBaseURL] {
            guard let raw, !raw.isEmpty else { continue }
            guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL else { continue }
            base = resolved
        }
        return base
    }

    private func buildSegmentPlan(template: SegmentTemplateInfo?, baseURL: URL) -> VODSegmentPlan? {
        guard let template, let mediaTemplate = template.media else { return nil }
        let representationID = curRepresentationID
        let bandwidth = curBandwidth

        let initURL: String?
        if let initialization = template.initialization {
            let initPath = Self.replaceTemplateTokens(
                initialization, representationID: representationID, bandwidth: bandwidth,
                number: nil, time: nil)
            initURL = URL(string: initPath, relativeTo: baseURL)?.absoluteString
        } else {
            initURL = nil
        }

        let segments: [VODMediaSegment]
        if template.timeline.isEmpty {
            segments = buildDurationSegments(
                template: template, mediaTemplate: mediaTemplate,
                representationID: representationID, bandwidth: bandwidth, baseURL: baseURL)
        } else {
            segments = buildTimelineSegments(
                template: template, mediaTemplate: mediaTemplate,
                representationID: representationID, bandwidth: bandwidth, baseURL: baseURL)
        }

        guard !segments.isEmpty else { return nil }
        return VODSegmentPlan(initializationURL: initURL, media: segments)
    }

    private func buildTimelineSegments(template: SegmentTemplateInfo, mediaTemplate: String,
                                       representationID: String, bandwidth: Int?,
                                       baseURL: URL) -> [VODMediaSegment] {
        var segments: [VODMediaSegment] = []
        var currentTime: Int64 = 0
        var number = template.startNumber

        for (entryIndex, entry) in template.timeline.enumerated() {
            if let t = entry.t { currentTime = t }
            let repeatCount = repeatCount(for: entry, at: entryIndex,
                                          entries: template.timeline, currentTime: currentTime)
            for _ in 0..<repeatCount {
                let mediaPath = Self.replaceTemplateTokens(
                    mediaTemplate, representationID: representationID, bandwidth: bandwidth,
                    number: number, time: currentTime)
                if let url = URL(string: mediaPath, relativeTo: baseURL)?.absoluteString {
                    segments.append(VODMediaSegment(
                        url: url,
                        start: Double(currentTime) / template.timescale,
                        duration: Double(entry.d) / template.timescale,
                        index: segments.count))
                }
                currentTime += entry.d
                number += 1
            }
        }
        return segments
    }

    private func buildDurationSegments(template: SegmentTemplateInfo, mediaTemplate: String,
                                       representationID: String, bandwidth: Int?,
                                       baseURL: URL) -> [VODMediaSegment] {
        guard let duration = template.duration, duration > 0,
              let totalDuration = mediaPresentationDuration, totalDuration > 0 else {
            return []
        }

        let segmentDuration = Double(duration) / template.timescale
        guard segmentDuration > 0 else { return [] }

        let count = max(1, Int(ceil(totalDuration / segmentDuration)))
        var segments: [VODMediaSegment] = []
        for offset in 0..<count {
            let number = template.startNumber + offset
            let time = Int64(offset) * duration
            let start = Double(time) / template.timescale
            let mediaPath = Self.replaceTemplateTokens(
                mediaTemplate, representationID: representationID, bandwidth: bandwidth,
                number: number, time: time)
            guard let url = URL(string: mediaPath, relativeTo: baseURL)?.absoluteString else { continue }
            segments.append(VODMediaSegment(
                url: url,
                start: start,
                duration: min(segmentDuration, max(0, totalDuration - start)),
                index: segments.count))
        }
        return segments.filter { $0.duration > 0 }
    }

    private func repeatCount(for entry: TimelineEntry, at index: Int,
                             entries: [TimelineEntry], currentTime: Int64) -> Int {
        if entry.r >= 0 { return entry.r + 1 }
        guard index + 1 < entries.count, let nextTime = entries[index + 1].t,
              entry.d > 0, nextTime > currentTime else {
            return 1
        }
        return max(1, Int((nextTime - currentTime) / entry.d))
    }

    private static func replaceTemplateTokens(_ template: String, representationID: String,
                                              bandwidth: Int?, number: Int?, time: Int64?) -> String {
        var result = template.replacingOccurrences(of: "$RepresentationID$", with: representationID)
        if let bandwidth {
            result = replaceFormattedToken("Bandwidth", value: Int64(bandwidth), in: result)
        }
        if let number {
            result = replaceFormattedToken("Number", value: Int64(number), in: result)
        }
        if let time {
            result = replaceFormattedToken("Time", value: time, in: result)
        }
        return result.replacingOccurrences(of: "$$", with: "$")
    }

    private static func replaceFormattedToken(_ name: String, value: Int64, in input: String) -> String {
        let pattern = "\\$" + NSRegularExpression.escapedPattern(for: name) + "(?:%0?(\\d+)d)?\\$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed()
        var output = input
        for match in matches {
            guard let range = Range(match.range, in: output) else { continue }
            let replacement: String
            if match.range(at: 1).location != NSNotFound,
               let widthRange = Range(match.range(at: 1), in: input),
               let width = Int(input[widthRange]) {
                replacement = String(format: "%0\(width)lld", value)
            } else {
                replacement = "\(value)"
            }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    private static func parseISODuration(_ raw: String) -> Double? {
        guard !raw.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else {
            return nil
        }
        func value(_ index: Int) -> Double {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: raw) else { return 0 }
            return Double(raw[range]) ?? 0
        }
        return value(1) * 86_400 + value(2) * 3_600 + value(3) * 60 + value(4)
    }

    private func localName(_ element: String) -> String {
        element.split(separator: ":").last.map(String.init) ?? element
    }
}
