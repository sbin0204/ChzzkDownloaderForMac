import Foundation

/// A parsed HLS *media* playlist (the per-quality chunklist), as needed by a
/// live recorder: media sequence, target duration, per-segment sequence numbers,
/// AES key, init segment (fMP4), discontinuities, and the end-list marker.
///
/// Pure value type with a pure parser — the foundation of the native live reader,
/// fully unit-testable without any network.
public struct HLSMediaPlaylist: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// Absolute media sequence number (mediaSequence + index), so a live poll
        /// can fetch only segments newer than the last one it saw.
        public let sequence: Int
        public let uri: String
        public let duration: Double
        /// True when preceded by `#EXT-X-DISCONTINUITY` (timeline break).
        public let discontinuity: Bool
    }

    /// `#EXT-X-KEY` — encryption for the following segments. `method == "NONE"`
    /// clears encryption.
    public struct Key: Equatable, Sendable {
        public let method: String
        public let uri: String?
        public let iv: String?
        public var isEncrypted: Bool { method.uppercased() != "NONE" && !method.isEmpty }
    }

    public let targetDuration: Double
    public let mediaSequence: Int
    public let segments: [Segment]
    /// `#EXT-X-MAP` URI — present for fMP4/CMAF streams (needs a muxer, not raw append).
    public let initSegmentURI: String?
    public let key: Key?
    /// `#EXT-X-ENDLIST` — the stream has ended (VOD-ified); stop polling.
    public let endList: Bool

    /// True when segments are fragmented MP4 (an init segment is declared), which
    /// cannot be raw-concatenated like MPEG-TS.
    public var isFragmentedMP4: Bool { initSegmentURI != nil }

    /// Parses a media playlist. Returns nil if it is not a media playlist
    /// (e.g. a master playlist with `#EXT-X-STREAM-INF`, or missing `#EXTM3U`).
    public static func parse(_ text: String) -> HLSMediaPlaylist? {
        let rawLines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard rawLines.first == "#EXTM3U" else { return nil }
        // A master playlist is not a media playlist.
        if rawLines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) { return nil }

        var targetDuration = 0.0
        var mediaSequence = 0
        var initSegmentURI: String?
        var key: Key?
        var endList = false
        var segments: [Segment] = []

        var pendingDuration: Double?
        var pendingDiscontinuity = false
        var nextSequence = 0

        for line in rawLines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(value(after: "#EXT-X-TARGETDURATION:", in: line)) ?? targetDuration
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(value(after: "#EXT-X-MEDIA-SEQUENCE:", in: line)) ?? 0
                nextSequence = mediaSequence
            } else if line.hasPrefix("#EXT-X-MAP:") {
                initSegmentURI = quotedAttribute("URI", in: line)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                key = parseKey(line)
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXTINF:") {
                let v = value(after: "#EXTINF:", in: line)
                pendingDuration = Double(v.split(separator: ",").first.map(String.init) ?? v) ?? 0
            } else if line == "#EXT-X-ENDLIST" {
                endList = true
            } else if !line.hasPrefix("#") {
                // A URI line: the segment for the most recent #EXTINF.
                segments.append(Segment(
                    sequence: nextSequence,
                    uri: line,
                    duration: pendingDuration ?? 0,
                    discontinuity: pendingDiscontinuity))
                nextSequence += 1
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }
        return HLSMediaPlaylist(
            targetDuration: targetDuration, mediaSequence: mediaSequence,
            segments: segments, initSegmentURI: initSegmentURI, key: key, endList: endList)
    }

    // MARK: - parsing helpers

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseKey(_ line: String) -> Key {
        Key(method: quotedOrBareAttribute("METHOD", in: line) ?? "NONE",
            uri: quotedAttribute("URI", in: line),
            iv: quotedOrBareAttribute("IV", in: line))
    }

    /// Reads a quoted attribute value (e.g. `URI="https://…"`).
    private static func quotedAttribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Reads an attribute value that may be quoted or bare up to the next comma
    /// (e.g. `METHOD=AES-128` or `IV=0x...`).
    private static func quotedOrBareAttribute(_ name: String, in line: String) -> String? {
        if let quoted = quotedAttribute(name, in: line) { return quoted }
        guard let r = line.range(of: "\(name)=") else { return nil }
        let rest = line[r.upperBound...]
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
