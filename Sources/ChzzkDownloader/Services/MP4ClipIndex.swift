import Foundation

/// Parses an MP4 `moov` (progressive/faststart) sample tables to compute the
/// exact byte span of the samples needed to play a `[clipStart, clipEnd]` time
/// window. This lets a direct-MP4 clip download an accurate byte-range window
/// (anchored on the keyframe at/just before `clipStart`) instead of a linear
/// time→byte guess, which drifts badly on VBR content.
///
/// All offsets returned are absolute file offsets, so they map directly to HTTP
/// `Range` requests and to positions in a sparse output file.
enum MP4ClipIndex {
    struct ByteSpan: Equatable {
        var start: Int
        var end: Int   // inclusive
        var length: Int { max(0, end - start + 1) }
    }

    struct Track {
        var isVideo: Bool
        var timescale: Double
        var startTimes: [Double]   // per-sample decode start time (seconds)
        var offsets: [Int]         // per-sample absolute byte offset
        var sizes: [Int]           // per-sample byte size
        var syncSamples: Set<Int>? // 0-based sync indices; nil = every sample is sync
        var count: Int { min(startTimes.count, min(offsets.count, sizes.count)) }
        func isSync(_ i: Int) -> Bool { syncSamples?.contains(i) ?? true }
    }

    /// Exact byte span (absolute offsets) covering every video/audio sample needed
    /// to decode `[clipStart, clipEnd]`, anchored on the keyframe ≤ clipStart.
    /// Returns nil if the moov can't be parsed or the result looks unreasonable
    /// (caller should then fall back to remote ffmpeg seek).
    static func clipByteSpan(moov: Data, clipStart: Double, clipEnd: Double,
                             fileTotal: Int, padding: Int = 64 * 1024) -> ByteSpan? {
        guard clipEnd > clipStart, fileTotal > 0 else { return nil }
        let bytes = [UInt8](moov)
        guard let moovBox = firstBox(bytes, 0, bytes.count, "moov") else { return nil }

        var tracks: [Track] = []
        for trak in boxes(bytes, moovBox.start, moovBox.end) where trak.type == "trak" {
            if let track = parseTrack(bytes, trak.start, trak.end), track.count > 0 {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { return nil }

        // Anchor on the keyframe ≤ clipStart in the video track (or the primary
        // track when there is no video), so a stream-copy cut starts cleanly.
        let videoTrack = tracks.first(where: { $0.isVideo })
        let anchorTrack = videoTrack ?? tracks[0]
        let anchorTime = keyframeStart(anchorTrack, atOrBefore: clipStart)

        var minByte = Int.max
        var maxByte = 0
        var matched = false
        for track in tracks {
            guard let (lo, hi) = sampleRange(track, from: anchorTime, until: clipEnd) else { continue }
            matched = true
            for i in lo...hi {
                minByte = min(minByte, track.offsets[i])
                maxByte = max(maxByte, track.offsets[i] + track.sizes[i])
            }
        }
        guard matched, minByte != Int.max, maxByte > minByte else { return nil }

        let start = max(0, minByte - padding)
        let end = min(fileTotal - 1, maxByte - 1 + padding)
        guard end > start else { return nil }
        // Sanity: a real clip window must be a small slice of the file. If the
        // computed span is almost the whole file something is wrong → fall back.
        if clipEnd - clipStart < 0.5 * estimatedDuration(tracks),
           end - start + 1 > Int(Double(fileTotal) * 0.97) {
            return nil
        }
        return ByteSpan(start: start, end: end)
    }

    // MARK: - track parsing

    private static func estimatedDuration(_ tracks: [Track]) -> Double {
        tracks.compactMap { $0.startTimes.last }.max() ?? .greatestFiniteMagnitude
    }

    private static func keyframeStart(_ track: Track, atOrBefore time: Double) -> Double {
        var anchor = 0.0
        for i in 0..<track.count {
            let start = track.startTimes[i]
            if start > time { break }
            if track.isSync(i) { anchor = start }
        }
        return anchor
    }

    /// Inclusive sample index range whose times overlap `[from, until)`.
    private static func sampleRange(_ track: Track, from: Double, until: Double) -> (Int, Int)? {
        let n = track.count
        guard n > 0, until > from else { return nil }
        // First sample whose start ≥ from, then step back to include the sample
        // that contains `from`.
        var lo = n
        for i in 0..<n where track.startTimes[i] >= from { lo = i; break }
        if lo == n { lo = n - 1 }
        if lo > 0, track.startTimes[lo] > from { lo -= 1 }
        // Last sample that begins before `until`.
        var hi = lo
        for i in lo..<n {
            if track.startTimes[i] < until { hi = i } else { break }
        }
        return (lo, hi)
    }

    private static func parseTrack(_ b: [UInt8], _ start: Int, _ end: Int) -> Track? {
        guard let mdia = firstBox(b, start, end, "mdia") else { return nil }
        guard let mdhd = firstBox(b, mdia.start, mdia.end, "mdhd"),
              let timescale = parseTimescale(b, mdhd.start, mdhd.end), timescale > 0 else { return nil }
        let isVideo = handlerIsVideo(b, mdia)
        guard let minf = firstBox(b, mdia.start, mdia.end, "minf"),
              let stbl = firstBox(b, minf.start, minf.end, "stbl") else { return nil }

        guard let stts = firstBox(b, stbl.start, stbl.end, "stts"),
              let stsc = firstBox(b, stbl.start, stbl.end, "stsc") else { return nil }
        let sizesBox = firstBox(b, stbl.start, stbl.end, "stsz")
            ?? firstBox(b, stbl.start, stbl.end, "stz2")
        guard let sizesBox else { return nil }
        let chunkBox = firstBox(b, stbl.start, stbl.end, "stco")
            ?? firstBox(b, stbl.start, stbl.end, "co64")
        guard let chunkBox else { return nil }

        let sizes = parseSampleSizes(b, sizesBox)
        guard !sizes.isEmpty else { return nil }
        let startTimes = parseDecodeTimes(b, stts.start, stts.end, timescale: Double(timescale), count: sizes.count)
        guard startTimes.count == sizes.count else { return nil }
        let chunkOffsets = parseChunkOffsets(b, chunkBox)
        guard !chunkOffsets.isEmpty else { return nil }
        let offsets = computeSampleOffsets(b, stsc.start, stsc.end,
                                           chunkOffsets: chunkOffsets, sizes: sizes)
        guard offsets.count == sizes.count else { return nil }
        let sync = firstBox(b, stbl.start, stbl.end, "stss").map {
            parseSyncSamples(b, $0.start, $0.end)
        }

        return Track(isVideo: isVideo, timescale: Double(timescale),
                     startTimes: startTimes, offsets: offsets, sizes: sizes, syncSamples: sync)
    }

    private static func handlerIsVideo(_ b: [UInt8], _ mdia: (type: String, start: Int, end: Int)) -> Bool {
        guard let hdlr = firstBox(b, mdia.start, mdia.end, "hdlr") else { return false }
        // fullbox(4) + pre_defined(4) + handler_type(4)
        let typePos = hdlr.start + 8
        guard typePos + 4 <= hdlr.end else { return false }
        return asciiType(b, typePos) == "vide"
    }

    private static func parseTimescale(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt32? {
        guard start < end else { return nil }
        let version = b[start]
        // fullbox version(1)+flags(3); v1: creation(8)+mod(8)+timescale(4); v0: creation(4)+mod(4)+timescale(4)
        let tsPos = version == 1 ? start + 4 + 8 + 8 : start + 4 + 4 + 4
        return beU32(b, tsPos, end)
    }

    private static func parseDecodeTimes(_ b: [UInt8], _ start: Int, _ end: Int,
                                         timescale: Double, count: Int) -> [Double] {
        guard let entryCount = beU32(b, start + 4, end) else { return [] }
        var p = start + 8
        var times: [Double] = []
        times.reserveCapacity(count)
        var t: UInt64 = 0
        for _ in 0..<Int(entryCount) {
            guard let sampleCount = beU32(b, p, end), let delta = beU32(b, p + 4, end) else { break }
            p += 8
            for _ in 0..<Int(sampleCount) {
                times.append(Double(t) / timescale)
                t += UInt64(delta)
                if times.count >= count { return times }
            }
        }
        return times
    }

    private static func parseSampleSizes(_ b: [UInt8], _ box: (type: String, start: Int, end: Int)) -> [Int] {
        if box.type == "stsz" {
            guard let sampleSize = beU32(b, box.start + 4, box.end),
                  let count = beU32(b, box.start + 8, box.end) else { return [] }
            if sampleSize != 0 {
                return Array(repeating: Int(sampleSize), count: Int(count))
            }
            var p = box.start + 12
            var sizes: [Int] = []
            sizes.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let s = beU32(b, p, box.end) else { break }
                sizes.append(Int(s)); p += 4
            }
            return sizes
        }
        // stz2: fullbox(4) + reserved(3) + field_size(1) + sample_count(4) + entries
        guard box.start + 12 <= box.end else { return [] }
        let fieldSize = Int(b[box.start + 7])
        guard let count = beU32(b, box.start + 8, box.end) else { return [] }
        var sizes: [Int] = []
        sizes.reserveCapacity(Int(count))
        var p = box.start + 12
        switch fieldSize {
        case 16:
            for _ in 0..<Int(count) { guard let s = beU16(b, p, box.end) else { break }; sizes.append(Int(s)); p += 2 }
        case 8:
            for _ in 0..<Int(count) { guard p < box.end else { break }; sizes.append(Int(b[p])); p += 1 }
        case 4:
            var i = 0
            while i < Int(count) {
                guard p < box.end else { break }
                let byte = Int(b[p]); p += 1
                sizes.append(byte >> 4); i += 1
                if i < Int(count) { sizes.append(byte & 0x0F); i += 1 }
            }
        default:
            return []
        }
        return sizes
    }

    private static func parseChunkOffsets(_ b: [UInt8], _ box: (type: String, start: Int, end: Int)) -> [Int] {
        guard let entryCount = beU32(b, box.start + 4, box.end) else { return [] }
        var p = box.start + 8
        var offsets: [Int] = []
        offsets.reserveCapacity(Int(entryCount))
        if box.type == "co64" {
            for _ in 0..<Int(entryCount) { guard let v = beU64(b, p, box.end) else { break }; offsets.append(Int(v)); p += 8 }
        } else {
            for _ in 0..<Int(entryCount) { guard let v = beU32(b, p, box.end) else { break }; offsets.append(Int(v)); p += 4 }
        }
        return offsets
    }

    private static func computeSampleOffsets(_ b: [UInt8], _ start: Int, _ end: Int,
                                             chunkOffsets: [Int], sizes: [Int]) -> [Int] {
        guard let entryCount = beU32(b, start + 4, end) else { return [] }
        // stsc entries: first_chunk(1-based), samples_per_chunk, sample_description_index
        var entries: [(firstChunk: Int, perChunk: Int)] = []
        var p = start + 8
        for _ in 0..<Int(entryCount) {
            guard let first = beU32(b, p, end), let per = beU32(b, p + 4, end) else { break }
            entries.append((Int(first), Int(per))); p += 12
        }
        guard !entries.isEmpty else { return [] }

        var offsets: [Int] = []
        offsets.reserveCapacity(sizes.count)
        var sampleIndex = 0
        var entryIdx = 0
        for chunk in 0..<chunkOffsets.count {
            while entryIdx + 1 < entries.count && entries[entryIdx + 1].firstChunk <= chunk + 1 {
                entryIdx += 1
            }
            let perChunk = max(0, entries[entryIdx].perChunk)
            var offsetInChunk = 0
            for _ in 0..<perChunk {
                guard sampleIndex < sizes.count else { return offsets }
                offsets.append(chunkOffsets[chunk] + offsetInChunk)
                offsetInChunk += sizes[sampleIndex]
                sampleIndex += 1
            }
        }
        return offsets
    }

    private static func parseSyncSamples(_ b: [UInt8], _ start: Int, _ end: Int) -> Set<Int> {
        guard let entryCount = beU32(b, start + 4, end) else { return [] }
        var p = start + 8
        var set = Set<Int>()
        for _ in 0..<Int(entryCount) {
            guard let n = beU32(b, p, end) else { break }
            set.insert(Int(n) - 1)   // stss is 1-based
            p += 4
        }
        return set
    }

    // MARK: - box walking

    /// Top-level child boxes within [start, end), returned as content ranges.
    static func boxes(_ b: [UInt8], _ start: Int, _ end: Int) -> [(type: String, start: Int, end: Int)] {
        var result: [(String, Int, Int)] = []
        var p = start
        while p + 8 <= end {
            guard let size32 = beU32(b, p, end) else { break }
            let type = asciiType(b, p + 4)
            var size = Int(size32)
            var header = 8
            if size == 1 {
                guard let large = beU64(b, p + 8, end) else { break }
                size = Int(large); header = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= header, p + size <= end else { break }
            result.append((type, p + header, p + size))
            p += size
        }
        return result
    }

    private static func firstBox(_ b: [UInt8], _ start: Int, _ end: Int,
                                 _ type: String) -> (type: String, start: Int, end: Int)? {
        boxes(b, start, end).first { $0.type == type }
    }

    private static func asciiType(_ b: [UInt8], _ pos: Int) -> String {
        guard pos + 4 <= b.count else { return "" }
        return String(bytes: b[pos..<pos + 4], encoding: .ascii) ?? ""
    }

    // MARK: - big-endian readers (bounds-checked)

    private static func beU16(_ b: [UInt8], _ p: Int, _ end: Int) -> UInt16? {
        guard p >= 0, p + 2 <= end, p + 2 <= b.count else { return nil }
        return (UInt16(b[p]) << 8) | UInt16(b[p + 1])
    }

    private static func beU32(_ b: [UInt8], _ p: Int, _ end: Int) -> UInt32? {
        guard p >= 0, p + 4 <= end, p + 4 <= b.count else { return nil }
        return (UInt32(b[p]) << 24) | (UInt32(b[p + 1]) << 16) | (UInt32(b[p + 2]) << 8) | UInt32(b[p + 3])
    }

    private static func beU64(_ b: [UInt8], _ p: Int, _ end: Int) -> UInt64? {
        guard let hi = beU32(b, p, end), let lo = beU32(b, p + 4, end) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }
}
