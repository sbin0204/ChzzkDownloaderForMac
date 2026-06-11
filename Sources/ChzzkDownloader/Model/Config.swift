import Foundation

// MARK: - Constants

enum Defaults {
    static let rescanInterval = 60
    static let minRescanInterval = 1
    static let maxRescanInterval = 3600
    static let outputFormat = "ts"
    static let supportedFormats = ["ts", "mkv", "webm"]
    static let minThreads = 1
    static let maxThreads = 16
    static let defaultThreads = 2
    static let minVODConnections = 1
    static let maxVODConnections = 32
    static let defaultVODConnections = 16
    static let minVODSpeedLimitMBps = 0.0
    static let maxVODSpeedLimitMBps = 10_000.0
    static let minSplitSizeMB = 0
    static let maxSplitSizeMB = 1_048_576
    static let minSplitDurationMinutes = 0
    static let maxSplitDurationMinutes = 10_080
    static let liveQualities = ["best", "1080p", "720p", "480p", "360p", "worst"]
    static let liveQuality = "best"

    // macOS-relevant encoders only (NVENC/QSV/AMF/VAAPI are Windows/Linux GPUs).
    static let hevcEncoders = ["libx265", "hevc_videotoolbox"]
    static let av1Encoders = ["libsvtav1", "libaom-av1"]
}

// MARK: - Validation helpers

enum Validate {
    static let safeChannelID = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,128}$")
    static let safeFfmpegValue = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,32}$")
    static let safeBitrate = try! NSRegularExpression(pattern: "^\\d+[kKmM]?$")
    static let specialChars = try! NSRegularExpression(pattern: "[\\\\/:*?\"<>|]")
    static let controlChars = try! NSRegularExpression(pattern: "[\\x00-\\x1f\\x7f]")

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range) else { return false }
        return m.range == range
    }

    static func clampInt(_ value: Int, _ min: Int, _ max: Int) -> Int {
        Swift.max(min, Swift.min(max, value))
    }

    static func normalizeBitrate(_ value: String, default def: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard matches(safeBitrate, text) else { return def }
        let digits = text.filter(\.isNumber)
        guard (Int(digits) ?? 0) > 0 else { return def }
        if let last = text.last, last.isNumber { text += "k" }
        return text.lowercased()
    }

    static func normalizeFormat(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasPrefix(".") { text.removeFirst() }
        return Defaults.supportedFormats.contains(text) ? text : Defaults.outputFormat
    }

    static func normalizeLiveQuality(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        return Defaults.liveQualities.contains(text) ? text : Defaults.liveQuality
    }

    static func normalizePortInput(_ value: String) -> String {
        let digits = value.filter { ("0"..."9").contains($0) }
        guard !digits.isEmpty else { return "" }
        let port = Int(digits) ?? 65_535
        return String(clampInt(port, 1, 65_535))
    }

    static func normalizeVODConnections(_ value: Int) -> Int {
        clampInt(value, Defaults.minVODConnections, Defaults.maxVODConnections)
    }

    static func normalizeVODSpeedLimitMBps(_ value: Double) -> Double {
        guard value.isFinite else { return Defaults.minVODSpeedLimitMBps }
        return min(Defaults.maxVODSpeedLimitMBps, max(Defaults.minVODSpeedLimitMBps, value))
    }

    static func normalizeWebhookURL(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text),
              WebhookNotifier.isUsableURL(url) else {
            return ""
        }
        return text
    }

    static let maxTagFilterCount = 20
    static let maxTagLength = 30

    /// Parses a comma-separated tag filter string from the channel edit UI.
    static func parseTagFilter(_ text: String) -> [String] {
        normalizeTagFilter(text.split(separator: ",").map(String.init))
    }

    /// Trims, strips control characters, dedupes case-insensitively, and caps
    /// tag count/length so config.json stays bounded.
    static func normalizeTagFilter(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            var tag = controlChars.stringByReplacingMatches(
                in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { continue }
            if tag.count > maxTagLength { tag = String(tag.prefix(maxTagLength)) }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
            if result.count == maxTagFilterCount { break }
        }
        return result
    }

    static func normalizeRecordingOutputDir(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "." }
        if text.hasPrefix("~") {
            return (text as NSString).expandingTildeInPath
        }
        return text
    }

    static func sanitizeCookie(_ value: String) -> String {
        let stripped = controlChars.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        return stripped.replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Replicates sanitize_filename_component for live titles / names.
    static func sanitizeFilename(_ value: String, fallback: String = "untitled") -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        text = specialChars.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = controlChars.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return text.isEmpty ? fallback : text
    }
}

// MARK: - Codable model (matches config.json schema)

struct Channel: Codable, Identifiable, Hashable {
    var id: String          // chzzk channel id
    var name: String
    var output_dir: String
    var quality: String = Defaults.liveQuality
    /// Record only when the live's tags match one of these (empty = always record).
    var tag_filter: [String] = []
    /// When on (and a tag filter is set), an in-progress recording is finalized
    /// once the live's tags stop matching the filter.
    var stop_on_tag_mismatch: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, output_dir, quality, tag_filter, stop_on_tag_mismatch
    }

    init(id: String, name: String, output_dir: String, quality: String = Defaults.liveQuality,
         tag_filter: [String] = [], stop_on_tag_mismatch: Bool = false) {
        self.id = id
        self.name = name
        self.output_dir = output_dir
        self.quality = Validate.normalizeLiveQuality(quality)
        self.tag_filter = Validate.normalizeTagFilter(tag_filter)
        self.stop_on_tag_mismatch = stop_on_tag_mismatch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        output_dir = try c.decode(String.self, forKey: .output_dir)
        quality = Validate.normalizeLiveQuality(
            try c.decodeIfPresent(String.self, forKey: .quality) ?? Defaults.liveQuality)
        tag_filter = Validate.normalizeTagFilter(
            try c.decodeIfPresent([String].self, forKey: .tag_filter) ?? [])
        stop_on_tag_mismatch = try c.decodeIfPresent(Bool.self, forKey: .stop_on_tag_mismatch) ?? false
    }

    /// True when this channel's tag filter accepts a live with the given tags
    /// (case-insensitive exact match against any filter entry).
    func acceptsTags(_ tags: [String]) -> Bool {
        guard !tag_filter.isEmpty else { return true }
        let liveTags = Set(tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return tag_filter.contains { liveTags.contains($0.lowercased()) }
    }

    /// True when an in-progress recording should stop because the live's tags no
    /// longer match the filter (only meaningful with the option on and a filter set).
    func shouldStopOnTagMismatch(_ tags: [String]) -> Bool {
        stop_on_tag_mismatch && !tag_filter.isEmpty && !acceptsTags(tags)
    }
}

struct EncoderSettings: Codable, Hashable {
    var enable: Bool
    var encoder: String
    var bitrate: String
    var max_bitrate: String
    var preset: String
}

struct Cookies: Codable, Hashable {
    var NID_SES: String
    var NID_AUT: String
}

/// A scheduled recording: start `channelID` at `startEpoch`, optionally stopping
/// after `durationMinutes` (0 = record until the stream ends).
struct Schedule: Codable, Identifiable, Hashable {
    var id = UUID()
    var channelID: String
    var startEpoch: Double
    var durationMinutes: Int = 0
    var started: Bool = false

    var startDate: Date { Date(timeIntervalSince1970: startEpoch) }
}

struct Config: Codable, Hashable {
    var channels: [Channel] = []
    var timeout: Int = Defaults.rescanInterval
    var stream_segment_threads: Int = Defaults.defaultThreads
    var output_format: String = Defaults.outputFormat
    var hevc_settings = EncoderSettings(
        enable: false, encoder: "libx265",
        bitrate: "2500k", max_bitrate: "10000k", preset: "ultrafast")
    var av1_settings = EncoderSettings(
        enable: false, encoder: "libsvtav1",
        bitrate: "2500k", max_bitrate: "10000k", preset: "8")
    var log_enabled: Bool = true
    var cookies = Cookies(NID_SES: "", NID_AUT: "")
    /// Off by default. When enabled, app launch imports Chzzk cookies from the
    /// first available logged-in browser, which may show a Keychain/TCC prompt.
    var auto_import_cookies_on_launch: Bool = false
    var proxy: String = ""   // e.g. http://host:port or socks5://host:port
    var notify_on_complete: Bool = true
    var schedules: [Schedule] = []
    /// Live recording auto-split threshold in MB. 0 disables splitting.
    var live_split_size_mb: Int = 0
    /// Live recording auto-split interval in minutes. 0 disables splitting.
    var live_split_duration_minutes: Int = 0
    /// Cyclic recording: when a channel's saved files exceed these limits, the
    /// oldest are moved to the Trash. 0 = that limit is off.
    var cyclic_recording_enabled: Bool = false
    var cyclic_max_files: Int = 0
    var cyclic_max_size_gb: Int = 0
    /// Optional Discord/Telegram/generic webhook for recording start & completion.
    var notify_webhook_url: String = ""
    /// Optional explicit paths to ffmpeg / streamlink. Empty = auto-detect.
    var ffmpeg_path: String = ""
    var streamlink_path: String = ""
    /// Channels that were being monitored/recorded when the app last quit,
    /// so monitoring resumes automatically on the next launch.
    var armed_channels: [String] = []

    init() {}

    /// Mirrors normalize_config in settings.py: validate & coerce every field.
    mutating func normalize() {
        timeout = Validate.clampInt(timeout, Defaults.minRescanInterval, Defaults.maxRescanInterval)
        stream_segment_threads = Validate.clampInt(
            stream_segment_threads, Defaults.minThreads, Defaults.maxThreads)
        live_split_size_mb = Validate.clampInt(
            live_split_size_mb, Defaults.minSplitSizeMB, Defaults.maxSplitSizeMB)
        live_split_duration_minutes = Validate.clampInt(
            live_split_duration_minutes,
            Defaults.minSplitDurationMinutes,
            Defaults.maxSplitDurationMinutes)
        output_format = Validate.normalizeFormat(output_format)
        proxy = proxy.trimmingCharacters(in: .whitespaces)
        cyclic_max_files = Validate.clampInt(cyclic_max_files, 0, 100_000)
        cyclic_max_size_gb = Validate.clampInt(cyclic_max_size_gb, 0, 1_000_000)
        notify_webhook_url = Validate.normalizeWebhookURL(notify_webhook_url)
        ffmpeg_path = ffmpeg_path.trimmingCharacters(in: .whitespacesAndNewlines)
        streamlink_path = streamlink_path.trimmingCharacters(in: .whitespacesAndNewlines)

        var cleaned: [Channel] = []
        for var ch in channels {
            let cid = ch.id.trimmingCharacters(in: .whitespaces)
            guard Validate.matches(Validate.safeChannelID, cid) else { continue }
            ch.id = cid
            let nm = Validate.controlChars.stringByReplacingMatches(
                in: ch.name, range: NSRange(ch.name.startIndex..., in: ch.name), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            ch.name = nm.isEmpty ? cid : nm
            ch.output_dir = Validate.normalizeRecordingOutputDir(ch.output_dir)
            ch.quality = Validate.normalizeLiveQuality(ch.quality)
            ch.tag_filter = Validate.normalizeTagFilter(ch.tag_filter)
            cleaned.append(ch)
        }
        channels = cleaned

        let channelIDs = Set(channels.map(\.id))
        var seenArmed = Set<String>()
        armed_channels = armed_channels.filter {
            channelIDs.contains($0) && seenArmed.insert($0).inserted
        }

        normalize(encoder: &hevc_settings, allowed: Defaults.hevcEncoders,
                  fallbackEncoder: "libx265", fallbackPreset: "ultrafast")
        normalize(encoder: &av1_settings, allowed: Defaults.av1Encoders,
                  fallbackEncoder: "libsvtav1", fallbackPreset: "8")
        if av1_settings.enable { hevc_settings.enable = false }

        cookies.NID_SES = Validate.sanitizeCookie(cookies.NID_SES)
        cookies.NID_AUT = Validate.sanitizeCookie(cookies.NID_AUT)
    }

    private func normalize(encoder s: inout EncoderSettings, allowed: [String],
                           fallbackEncoder: String, fallbackPreset: String) {
        if !allowed.contains(s.encoder) { s.encoder = fallbackEncoder }
        s.bitrate = Validate.normalizeBitrate(s.bitrate, default: "2500k")
        s.max_bitrate = Validate.normalizeBitrate(s.max_bitrate, default: "10000k")
        let preset = s.preset.trimmingCharacters(in: .whitespaces)
        s.preset = Validate.matches(Validate.safeFfmpegValue, preset) ? preset : fallbackPreset
    }
}

extension Config {
    private enum CodingKeys: String, CodingKey {
        case channels, timeout, stream_segment_threads, output_format
        case hevc_settings, av1_settings, log_enabled, cookies, auto_import_cookies_on_launch, proxy
        case notify_on_complete, schedules, live_split_size_mb, live_split_duration_minutes
        case cyclic_recording_enabled, cyclic_max_files, cyclic_max_size_gb, notify_webhook_url
        case ffmpeg_path, streamlink_path, armed_channels
    }

    /// Lenient decoding: any missing key keeps its default, so loading a
    /// config.json written by an older version (without newer fields) never fails.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent([Channel].self, forKey: .channels) { channels = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .timeout) { timeout = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .stream_segment_threads) { stream_segment_threads = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .output_format) { output_format = v }
        if let v = try c.decodeIfPresent(EncoderSettings.self, forKey: .hevc_settings) { hevc_settings = v }
        if let v = try c.decodeIfPresent(EncoderSettings.self, forKey: .av1_settings) { av1_settings = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .log_enabled) { log_enabled = v }
        if let v = try c.decodeIfPresent(Cookies.self, forKey: .cookies) { cookies = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .auto_import_cookies_on_launch) {
            auto_import_cookies_on_launch = v
        }
        if let v = try c.decodeIfPresent(String.self, forKey: .proxy) { proxy = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .notify_on_complete) { notify_on_complete = v }
        if let v = try c.decodeIfPresent([Schedule].self, forKey: .schedules) { schedules = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .live_split_size_mb) { live_split_size_mb = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .live_split_duration_minutes) { live_split_duration_minutes = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .cyclic_recording_enabled) { cyclic_recording_enabled = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .cyclic_max_files) { cyclic_max_files = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .cyclic_max_size_gb) { cyclic_max_size_gb = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .notify_webhook_url) { notify_webhook_url = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .ffmpeg_path) { ffmpeg_path = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .streamlink_path) { streamlink_path = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .armed_channels) { armed_channels = v }
    }
}
