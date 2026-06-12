import Foundation

/// Downloads a resolved VOD variant to `outURL`.
/// - Direct MP4 (whole video): multi-connection ranged download.
/// - DASH segment VOD: parallel part/segment prefetch, then local ffmpeg postprocess.
/// - Direct MP4 clip: multi-connection byte-range window prefetch, then local ffmpeg postprocess.
/// - Direct MP4 clip fallback: ffmpeg HTTP range seek from the requested time.
/// - Direct MP4 audio-only: multi-connection ranged prefetch, then local ffmpeg postprocess.
/// - HLS (live-rewind): parallel segment prefetch, then local ffmpeg postprocess.
final class VODDownloader {
    private struct State {
        var processes: [UUID: Process] = [:]
        var parallel: [UUID: ParallelDownloader] = [:]
        var hlsDownloads: [UUID: HLSParallelDownloader] = [:]
        var dashDownloads: [UUID: DASHSegmentDownloader] = [:]
    }

    enum DownloadStrategy: Equatable {
        case parallel
        case parallelPostprocess
        case parallelClipPostprocess
        case hlsSegmentPrefetch
        case dashSegmentPrefetch
        case remoteFFmpegSeek
    }

    private let state = Synchronized(State(), label: "ChzzkDownloader.VODDownloader.state")

    static func strategy(variant: VODVariant, audioOnly: Bool,
                         clipStart: Double?, clipEnd: Double?) -> DownloadStrategy {
        if variant.isHLS { return .hlsSegmentPrefetch }
        let hasClip = clipStart != nil && clipEnd != nil && (clipEnd ?? 0) > (clipStart ?? 0)
        // Do not move segmented DASH clips back to "download from 0 then cut".
        // If the manifest gives us parts, partial downloads must fetch only the
        // overlapping segments. See docs/VOD_PARTIAL_DOWNLOAD_POLICY.md.
        if variant.hasSegmentParts { return .dashSegmentPrefetch }
        // Direct MP4/CDN clips without a part list use a parallel byte-range
        // window, not `0 -> clipEnd`. ffmpeg HTTP range seek is only fallback.
        if hasClip { return .parallelClipPostprocess }
        if audioOnly { return .parallelPostprocess }
        return .parallel
    }

    static func remoteFFmpegArguments(variantURL: String, cookies: Cookies, outURL: URL, partURL: URL,
                                      audioOnly: Bool, clipStart: Double?, clipDuration: Double?) -> [String] {
        let seekPre = clipStart.map { ["-ss", String(format: "%.3f", $0)] } ?? []
        let durArgs = clipDuration.map { ["-t", String(format: "%.3f", $0)] } ?? []
        let muxer = outURL.pathExtension.lowercased() == "m4a" ? "ipod" : "mp4"
        // HTTP-protocol resilience options for the direct-MP4 network seek. Note:
        // `-allowed_extensions` / `-extension_picky` are HLS-demuxer options and must
        // NOT be passed here — the mov/mp4 demuxer rejects them with
        // "Option not found", which aborts the whole clip download.
        let reconnectArgs = [
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_on_http_error", "4xx,5xx",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "15000000",
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
        ]
        // Built incrementally: one long `+` chain makes the type checker time out
        // on slower toolchains (e.g. the CI runner).
        var args: [String] = ["-y", "-user_agent", VODRequestHeaders.userAgent]
        args += ProxySupport.ffmpegArgs()
        args += reconnectArgs
        args += seekPre
        args += ["-headers", VODRequestHeaders.ffmpegHeaders(cookies: cookies), "-i", variantURL]
        args += durArgs
        args += copyStreamArgs(audioOnly: audioOnly)
        args += ["-progress", "pipe:2", "-f", muxer, partURL.path]
        return args
    }

    static func copyStreamArgs(audioOnly: Bool) -> [String] {
        if audioOnly {
            return ["-map", "0:a:0?", "-vn", "-sn", "-dn", "-c:a", "copy"]
        }
        return ["-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn", "-c", "copy",
                "-movflags", "+faststart"]
    }

    static func aacFallbackStreamArgs(audioOnly: Bool) -> [String] {
        if audioOnly {
            return ["-map", "0:a:0?", "-vn", "-sn", "-dn", "-c:a", "aac", "-b:a", "192k"]
        }
        return ["-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart"]
    }

    static func shouldRetryPostprocessWithAAC(status: Int32, logTail: [String]) -> Bool {
        guard !isFFmpegNoSpaceFailure(status: status, logTail: logTail) else {
            return false
        }
        let retrySignals = [
            "codec not currently supported in container",
            "Could not find tag for codec",
            "Tag",
            "not currently supported in container",
            "Invalid audio stream",
        ]
        return logTail.contains { line in
            retrySignals.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }

    static func ffmpegFailureMessage(prefix: String, status: Int32, logTail: [String]) -> String {
        if isFFmpegNoSpaceFailure(status: status, logTail: logTail) {
            return "\(prefix) 종료 코드 \(status): 저장 공간이 부족합니다(ENOSPC). 저장 위치와 임시 작업 파일 위치의 여유 공간을 확보한 뒤 다시 시도하세요."
        }

        let generic = ["Conversion failed!", "Conversion failed"]
        let keywords = ["Error", "Invalid", "Unable", "No such", "Failed", "not found",
                        "Permission", "HTTP error", "moov atom not found",
                        "Could not", "does not contain any stream"]
        let candidates = logTail
            .map(sanitizedFFmpegLine)
            .filter { line in
                !generic.contains { line.localizedCaseInsensitiveCompare($0) == .orderedSame }
            }
        let reason = candidates.last { line in
            keywords.contains { line.localizedCaseInsensitiveContains($0) }
        } ?? candidates.last
        let detail = reason.map { ": \($0)" } ?? ""
        return "\(prefix) 종료 코드 \(status)\(detail)"
    }

    private static func isFFmpegNoSpaceFailure(status: Int32, logTail: [String]) -> Bool {
        status == 228 || logTail.contains {
            $0.localizedCaseInsensitiveContains("No space left on device")
                || $0.localizedCaseInsensitiveContains("ENOSPC")
        }
    }

    static func shouldPreservePostprocessSourceOnFailure(sourceURL _: URL, cleanupURL _: URL?,
                                                         audioOnly _: Bool, clipStart _: Double?,
                                                         clipDuration _: Double?) -> Bool {
        false
    }

    static func estimatedPostprocessOutputBytes(sourceSize: Int, audioOnly: Bool) -> Int {
        let overhead = 16 * 1024 * 1024
        if audioOnly {
            return min(sourceSize, max(32 * 1024 * 1024, sourceSize / 8)) + overhead
        }
        return sourceSize + overhead
    }

    static func formattedFFmpegSpeed(_ raw: String?, fallback: String) -> String {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return fallback
        }
        if text.hasSuffix("x") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value.isFinite else {
            return raw?.hasSuffix("x") == true ? (raw ?? fallback) : "\(raw ?? fallback)x"
        }
        let decimals = abs(value) >= 10 ? 1 : 2
        return String(format: "%.\(decimals)fx", value)
    }

    static func postprocessSpaceFailureMessage(required: Int, available: Int64) -> String {
        "로컬 처리 저장 공간 부족: 최소 \(ProgressParser.formatSize(Double(required))) 필요, "
            + "사용 가능 \(ProgressParser.formatSize(Double(available))). 저장 위치의 여유 공간을 확보한 뒤 다시 시도하세요."
    }

    static func conservativeWritableCapacity(important: Int64?, regular: Int64?) -> Int64? {
        let values = [important, regular].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        let positive = values.filter { $0 > 0 }
        return positive.min() ?? 0
    }

    private static func availableCapacityForWriting(to directory: URL) -> Int64? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? directory.resourceValues(forKeys: keys) else { return nil }
        return conservativeWritableCapacity(
            important: values.volumeAvailableCapacityForImportantUsage,
            regular: values.volumeAvailableCapacity.map(Int64.init))
    }

    private static func sanitizedFFmpegLine(_ line: String) -> String {
        var sanitized = line
        if let users = try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#) {
            sanitized = users.stringByReplacingMatches(
                in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized), withTemplate: "~")
        }
        if let volumes = try? NSRegularExpression(pattern: #"/Volumes/[^/\s]+"#) {
            sanitized = volumes.stringByReplacingMatches(
                in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized), withTemplate: "/Volumes/<volume>")
        }
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s'"]+"#) {
            let nsRange = NSRange(sanitized.startIndex..., in: sanitized)
            let matches = regex.matches(in: sanitized, range: nsRange).reversed()
            for match in matches {
                guard let range = Range(match.range, in: sanitized) else { continue }
                let rawURL = String(sanitized[range])
                if var components = URLComponents(string: rawURL), components.queryItems != nil {
                    components.query = nil
                    sanitized.replaceSubrange(range, with: (components.string ?? "https://<redacted>") + "?<redacted>")
                }
            }
        }
        return sanitized
    }

    /// Deterministic destination path; unique only when a *completed* file already exists.
    static func makeOutputURL(channelName: String, title: String, quality: Int, dir: URL,
                              ext: String = "mp4", suffix: String = "") -> URL {
        let safeChannel = Validate.sanitizeFilename(channelName, fallback: "channel")
        let safeTitle = Validate.sanitizeFilename(title, fallback: "video")
        let safeExt = Validate.sanitizeFilename(ext, fallback: "mp4")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let name = Filename.shortenedComponent(
            prefix: "[\(safeChannel)] \(safeTitle)",
            preservingTail: " \(quality)p\(suffix).\(safeExt)")
        let base = dir.appendingPathComponent(name)
        return uniquePath(base)
    }

    func start(item: VODItem, variant: VODVariant, ffmpegPath: String,
               cookies: Cookies, outURL: URL, connections: Int,
               audioOnly: Bool = false, rateLimit: Double = 0,
               clipStart: Double? = nil, clipEnd: Double? = nil,
               onProgress: @escaping (Double, String, String, String) -> Void,
               onFinish: @escaping (VODState, String?) -> Void) {
        // The output directory must exist and be writable, otherwise every strategy
        // fails with a cryptic ffmpeg ("output … No such file or directory") or
        // Foundation ("part … doesn't exist") error. Check once, up front.
        let outputDir = outURL.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            onFinish(.failed("저장 폴더를 만들 수 없습니다: \(outputDir.path)\n"
                             + "VOD 다운로드 옵션의 ‘저장 위치’가 존재하고 쓰기 가능한지 확인하세요."), nil)
            return
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue,
              fm.isWritableFile(atPath: outputDir.path) else {
            onFinish(.failed("저장 폴더에 접근할 수 없습니다: \(outputDir.path)\n"
                             + "외장/네트워크 드라이브라면 연결 상태를, 그 외에는 쓰기 권한을 확인하세요."), nil)
            return
        }

        let clipDuration: Double?
        if let clipStart, let clipEnd, clipEnd > clipStart {
            clipDuration = clipEnd - clipStart
        } else {
            clipDuration = nil
        }

        switch Self.strategy(variant: variant, audioOnly: audioOnly, clipStart: clipStart, clipEnd: clipEnd) {
        case .dashSegmentPrefetch:
            let postDuration = clipDuration ?? Double(item.durationSeconds)
            startDASHSegmentPostprocess(item: item, variant: variant, ffmpegPath: ffmpegPath,
                                        cookies: cookies, connections: connections,
                                        rateLimit: rateLimit, outURL: outURL,
                                        audioOnly: audioOnly, clipStart: clipStart,
                                        clipDuration: clipDuration, progressDuration: postDuration,
                                        onProgress: onProgress, onFinish: onFinish)
        case .hlsSegmentPrefetch:
            let postDuration = clipDuration ?? Double(item.durationSeconds)
            startHLSParallelPostprocess(item: item, variant: variant, ffmpegPath: ffmpegPath,
                                        cookies: cookies, connections: connections,
                                        rateLimit: rateLimit, outURL: outURL,
                                        audioOnly: audioOnly, clipStart: clipStart,
                                        clipDuration: clipDuration, progressDuration: postDuration,
                                        onProgress: onProgress, onFinish: onFinish)
        case .remoteFFmpegSeek:
            let progressDuration = clipDuration ?? Double(item.durationSeconds)
            startFFmpeg(item: item, variant: variant, ffmpegPath: ffmpegPath,
                        cookies: cookies, duration: progressDuration, outURL: outURL,
                        audioOnly: audioOnly, clipStart: clipStart, clipDuration: clipDuration,
                        onProgress: onProgress, onFinish: onFinish)
        case .parallelClipPostprocess:
            let postDuration = clipDuration ?? Double(item.durationSeconds)
            startParallelClipPostprocess(item: item, variant: variant, ffmpegPath: ffmpegPath,
                                         cookies: cookies, connections: connections,
                                         rateLimit: rateLimit, outURL: outURL,
                                         audioOnly: audioOnly, clipStart: clipStart,
                                         clipDuration: clipDuration, progressDuration: postDuration,
                                         onProgress: onProgress, onFinish: onFinish)
        case .parallelPostprocess:
            let postDuration = clipDuration ?? Double(item.durationSeconds)
            startParallelPostprocess(item: item, variant: variant, ffmpegPath: ffmpegPath,
                                     cookies: cookies, connections: connections,
                                     rateLimit: rateLimit, outURL: outURL,
                                     audioOnly: audioOnly, clipStart: clipStart,
                                     clipDuration: clipDuration, progressDuration: postDuration,
                                     onProgress: onProgress, onFinish: onFinish)
        case .parallel:
            startParallel(item: item, variant: variant, cookies: cookies, connections: connections,
                          rateLimit: rateLimit, outURL: outURL, onProgress: onProgress, onFinish: onFinish)
        }
    }

    func cancel(item: VODItem) {
        let (proc, par, hls, dash) = state.withValue { state in
            let proc = state.processes.removeValue(forKey: item.id)
            return (proc, state.parallel[item.id], state.hlsDownloads[item.id], state.dashDownloads[item.id])
        }
        proc?.terminate()
        par?.cancel()
        hls?.cancel()
        dash?.cancel()
    }

    // MARK: parallel ranged download (direct MP4)

    private func startDASHSegmentPostprocess(item: VODItem, variant: VODVariant, ffmpegPath: String,
                                             cookies: Cookies, connections: Int, rateLimit: Double,
                                             outURL: URL, audioOnly: Bool, clipStart: Double?,
                                             clipDuration: Double?, progressDuration: Double,
                                             onProgress: @escaping (Double, String, String, String) -> Void,
                                             onFinish: @escaping (VODState, String?) -> Void) {
        guard let segmentPlan = variant.segmentPlan, segmentPlan.hasMediaSegments else {
            onFinish(.failed("DASH 파트 목록이 없어 구간 다운로드를 시작할 수 없습니다."), nil)
            return
        }

        let downloader = DASHSegmentDownloader()
        state.update { $0.dashDownloads[item.id] = downloader }
        let headers = VODRequestHeaders.media(cookies: cookies)
        onProgress(0, "DASH 파트 목록 확인중…", "", "")

        Task {
            do {
                let local = try await downloader.download(
                    segmentPlan: segmentPlan, headers: headers, finalOutput: outURL,
                    workID: item.recordID ?? item.id,
                    connections: connections, rateLimitBytesPerSec: rateLimit,
                    clipStart: clipStart, clipDuration: clipDuration
                ) { doneSegments, totalSegments, bytes, bps in
                    let networkPct = totalSegments > 0 ? min(1.0, Double(doneSegments) / Double(totalSegments)) : 0
                    let pct = min(0.92, networkPct * 0.92)
                    let size = doneSegments == 0
                        ? "DASH 파트 수신 대기중…"
                        : "\(doneSegments)/\(totalSegments) 파트 · \(ProgressParser.formatSize(Double(bytes)))"
                    let speed = doneSegments == 0 ? "" : ProgressParser.formatSize(bps) + "/s"
                    onProgress(pct, size, speed, "")
                }
                state.update { $0.dashDownloads.removeValue(forKey: item.id) }
                startLocalPostprocess(item: item, ffmpegPath: ffmpegPath, sourceURL: local.sourceURL,
                                      outURL: outURL, audioOnly: audioOnly,
                                      clipStart: local.localClipStart, clipDuration: clipDuration,
                                      progressDuration: progressDuration, cleanupURL: local.workDir,
                                      onProgress: onProgress, onFinish: onFinish)
            } catch is CancellationError {
                downloader.cleanup()
                state.update { $0.dashDownloads.removeValue(forKey: item.id) }
                onFinish(.canceled, nil)
            } catch {
                downloader.cleanup()
                state.update { $0.dashDownloads.removeValue(forKey: item.id) }
                onFinish(.failed(error.localizedDescription), nil)
            }
        }
    }

    private func startHLSParallelPostprocess(item: VODItem, variant: VODVariant, ffmpegPath: String,
                                             cookies: Cookies, connections: Int, rateLimit: Double,
                                             outURL: URL, audioOnly: Bool, clipStart: Double?,
                                             clipDuration: Double?, progressDuration: Double,
                                             onProgress: @escaping (Double, String, String, String) -> Void,
                                             onFinish: @escaping (VODState, String?) -> Void) {
        let downloader = HLSParallelDownloader()
        state.update { $0.hlsDownloads[item.id] = downloader }
        let headers = VODRequestHeaders.media(cookies: cookies)
        onProgress(0, "HLS 세그먼트 목록 확인중…", "", "")

        Task {
            do {
                let local = try await downloader.download(
                    playlistURLString: variant.url, headers: headers, finalOutput: outURL,
                    workID: item.recordID ?? item.id,
                    connections: connections, rateLimitBytesPerSec: rateLimit,
                    clipStart: clipStart, clipDuration: clipDuration
                ) { doneSegments, totalSegments, bytes, bps in
                    let networkPct = totalSegments > 0 ? min(1.0, Double(doneSegments) / Double(totalSegments)) : 0
                    let pct = min(0.92, networkPct * 0.92)
                    let size = doneSegments == 0
                        ? "HLS 세그먼트 수신 대기중…"
                        : "\(doneSegments)/\(totalSegments) 조각 · \(ProgressParser.formatSize(Double(bytes)))"
                    let speed = doneSegments == 0 ? "" : ProgressParser.formatSize(bps) + "/s"
                    onProgress(pct, size, speed, "")
                }
                state.update { $0.hlsDownloads.removeValue(forKey: item.id) }
                startLocalPostprocess(item: item, ffmpegPath: ffmpegPath, sourceURL: local.sourceURL,
                                      outURL: outURL, audioOnly: audioOnly,
                                      clipStart: local.localClipStart, clipDuration: clipDuration,
                                      progressDuration: progressDuration, cleanupURL: local.workDir,
                                      onProgress: onProgress, onFinish: onFinish)
            } catch is CancellationError {
                downloader.cleanup()
                state.update { $0.hlsDownloads.removeValue(forKey: item.id) }
                onFinish(.canceled, nil)
            } catch {
                downloader.cleanup()
                state.update { $0.hlsDownloads.removeValue(forKey: item.id) }
                onFinish(.failed(error.localizedDescription), nil)
            }
        }
    }

    private func startParallelPostprocess(item: VODItem, variant: VODVariant, ffmpegPath: String,
                                          cookies: Cookies, connections: Int, rateLimit: Double,
                                          outURL: URL, audioOnly: Bool, clipStart: Double?,
                                          clipDuration: Double?, progressDuration: Double,
                                          prefixFraction: Double? = nil,
                                          onProgress: @escaping (Double, String, String, String) -> Void,
                                          onFinish: @escaping (VODState, String?) -> Void) {
        let headers = VODRequestHeaders.media(cookies: cookies)
        let sourceURL = Filename.temporaryURL(for: outURL, suffix: ".source.mp4")
        try? FileManager.default.removeItem(at: sourceURL)
        Filename.removeTemporary(for: sourceURL, suffix: ".part")
        Filename.removeTemporary(for: sourceURL, suffix: ".cvdresume")
        onProgress(0, audioOnly ? "오디오 추출용 원본 확인중…" : "서버 Range 확인중…", "", "")

        let downloader = ParallelDownloader()
        state.update { $0.parallel[item.id] = downloader }

        Task {
            do {
                try await downloader.download(
                    urlString: variant.url, headers: headers, finalOutput: sourceURL,
                    connections: connections, rateLimitBytesPerSec: rateLimit,
                    prefixFraction: prefixFraction) { done, total, bps in
                        let networkPct = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
                        let pct = min(0.92, networkPct * 0.92)
                        let size = done == 0
                            ? "데이터 수신 대기중…"
                            : "\(ProgressParser.formatSize(Double(done))) / \(ProgressParser.formatSize(Double(total)))"
                        let speed = done == 0 ? "" : ProgressParser.formatSize(bps) + "/s"
                        onProgress(pct, size, speed, "")
                    }
                state.update { $0.parallel.removeValue(forKey: item.id) }
                startLocalPostprocess(item: item, ffmpegPath: ffmpegPath, sourceURL: sourceURL,
                                      outURL: outURL, audioOnly: audioOnly,
                                      clipStart: clipStart, clipDuration: clipDuration,
                                      progressDuration: progressDuration, cleanupURL: sourceURL,
                                      onProgress: onProgress, onFinish: onFinish)
            } catch is CancellationError {
                state.update { $0.parallel.removeValue(forKey: item.id) }
                try? FileManager.default.removeItem(at: sourceURL)
                Filename.removeTemporary(for: sourceURL, suffix: ".part")
                onFinish(.canceled, nil)
            } catch {
                state.update { $0.parallel.removeValue(forKey: item.id) }
                try? FileManager.default.removeItem(at: sourceURL)
                Filename.removeTemporary(for: sourceURL, suffix: ".part")
                onFinish(.failed(error.localizedDescription), nil)
            }
        }
    }

    private func startParallelClipPostprocess(item: VODItem, variant: VODVariant, ffmpegPath: String,
                                              cookies: Cookies, connections: Int, rateLimit: Double,
                                              outURL: URL, audioOnly: Bool, clipStart: Double?,
                                              clipDuration: Double?, progressDuration: Double,
                                              onProgress: @escaping (Double, String, String, String) -> Void,
                                              onFinish: @escaping (VODState, String?) -> Void) {
        guard let clipStart, let clipDuration, clipDuration > 0, item.durationSeconds > 0 else {
            startFFmpeg(item: item, variant: variant, ffmpegPath: ffmpegPath,
                        cookies: cookies, duration: progressDuration, outURL: outURL,
                        audioOnly: audioOnly, clipStart: clipStart, clipDuration: clipDuration,
                        onProgress: onProgress, onFinish: onFinish)
            return
        }

        let headers = VODRequestHeaders.media(cookies: cookies)
        let sourceURL = Filename.temporaryURL(for: outURL, suffix: ".clip-source.mp4")
        try? FileManager.default.removeItem(at: sourceURL)
        onProgress(0, "구간 Range 확인중…", "", "")

        let downloader = ParallelDownloader()
        state.update { $0.parallel[item.id] = downloader }

        func fallbackToRemoteSeek(reason _: String) {
            onProgress(0.92, "원격 seek 재시도", Self.formattedFFmpegSpeed(nil, fallback: "N/A"), "")
            startFFmpeg(item: item, variant: variant, ffmpegPath: ffmpegPath,
                        cookies: cookies, duration: progressDuration, outURL: outURL,
                        audioOnly: audioOnly, clipStart: clipStart, clipDuration: clipDuration,
                        onProgress: onProgress, onFinish: onFinish)
        }

        Task {
            do {
                let fetchedBytes = try await downloader.downloadClipWindow(
                    urlString: variant.url, headers: headers, finalOutput: sourceURL,
                    connections: connections, rateLimitBytesPerSec: rateLimit,
                    durationSeconds: Double(item.durationSeconds),
                    clipStart: clipStart, clipEnd: clipStart + clipDuration
                ) { done, total, bps in
                    let networkPct = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
                    let pct = min(0.92, networkPct * 0.92)
                    let size = done == 0
                        ? "구간 데이터 수신 대기중…"
                        : "\(ProgressParser.formatSize(Double(done))) / \(ProgressParser.formatSize(Double(total)))"
                    let speed = done == 0 ? "" : ProgressParser.formatSize(bps) + "/s"
                    onProgress(pct, size, speed, "")
                }
                state.update { $0.parallel.removeValue(forKey: item.id) }
                startLocalPostprocess(item: item, ffmpegPath: ffmpegPath, sourceURL: sourceURL,
                                      outURL: outURL, audioOnly: audioOnly,
                                      clipStart: clipStart, clipDuration: clipDuration,
                                      progressDuration: progressDuration, cleanupURL: sourceURL,
                                      sourceByteEstimate: fetchedBytes,
                                      onProgress: onProgress, onFinish: onFinish,
                                      onFailureFallback: fallbackToRemoteSeek)
            } catch is CancellationError {
                state.update { $0.parallel.removeValue(forKey: item.id) }
                try? FileManager.default.removeItem(at: sourceURL)
                onFinish(.canceled, nil)
            } catch {
                state.update { $0.parallel.removeValue(forKey: item.id) }
                try? FileManager.default.removeItem(at: sourceURL)
                fallbackToRemoteSeek(reason: error.localizedDescription)
            }
        }
    }

    private func startParallel(item: VODItem, variant: VODVariant, cookies: Cookies,
                               connections: Int, rateLimit: Double, outURL: URL,
                               onProgress: @escaping (Double, String, String, String) -> Void,
                               onFinish: @escaping (VODState, String?) -> Void) {
        let downloader = ParallelDownloader()
        state.update { $0.parallel[item.id] = downloader }

        let headers = VODRequestHeaders.media(cookies: cookies)
        onProgress(0, "서버 Range 확인중…", "", "")

        Task {
            do {
                try await downloader.download(
                    urlString: variant.url, headers: headers, finalOutput: outURL,
                    connections: connections, rateLimitBytesPerSec: rateLimit) { done, total, bps in
                        let pct = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
                        let size = done == 0
                            ? "데이터 수신 대기중…"
                            : "\(ProgressParser.formatSize(Double(done))) / \(ProgressParser.formatSize(Double(total)))"
                        let speed = done == 0 ? "" : ProgressParser.formatSize(bps) + "/s"
                        onProgress(pct, size, speed, "")
                    }
                state.update { $0.parallel.removeValue(forKey: item.id) }
                onFinish(.completed, outURL.path)
            } catch is CancellationError {
                // Explicit cancel: discard partial data.
                state.update { $0.parallel.removeValue(forKey: item.id) }
                Filename.removeTemporary(for: outURL, suffix: ".part")
                onFinish(.canceled, nil)
            } catch {
                state.update { $0.parallel.removeValue(forKey: item.id) }
                Filename.removeTemporary(for: outURL, suffix: ".part")
                onFinish(.failed(error.localizedDescription), nil)
            }
        }
    }

    // MARK: ffmpeg (HLS live-rewind)

    private func startLocalPostprocess(item: VODItem, ffmpegPath: String, sourceURL: URL,
                                       outURL: URL, audioOnly: Bool, clipStart: Double?,
                                       clipDuration: Double?, progressDuration: Double,
                                       cleanupURL: URL? = nil,
                                       sourceByteEstimate: Int? = nil,
                                       onProgress: @escaping (Double, String, String, String) -> Void,
                                       onFinish: @escaping (VODState, String?) -> Void,
                                       onFailureFallback: ((String) -> Void)? = nil) {
        let cleanupTarget = cleanupURL ?? sourceURL
        let sourceSize = ((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]) as? Int) ?? -1
        guard sourceSize > 0 else {
            try? FileManager.default.removeItem(at: cleanupTarget)
            let reason = sourceSize == 0 ? "비어 있음" : "없음"
            let message = "로컬 처리 입력 파일 \(reason): \(sourceURL.lastPathComponent)"
            if let onFailureFallback {
                onFailureFallback(message)
            } else {
                onFinish(.failed(message), nil)
            }
            return
        }

        let preserveSourceOnFailure = Self.shouldPreservePostprocessSourceOnFailure(
            sourceURL: sourceURL, cleanupURL: cleanupURL,
            audioOnly: audioOnly, clipStart: clipStart, clipDuration: clipDuration)
        let sourceSizeForEstimate = sourceByteEstimate ?? sourceSize
        let requiredBytes = Self.estimatedPostprocessOutputBytes(sourceSize: sourceSizeForEstimate, audioOnly: audioOnly)
        if let available = Self.availableCapacityForWriting(to: outURL.deletingLastPathComponent()),
           available < Int64(requiredBytes) {
            if !preserveSourceOnFailure {
                try? FileManager.default.removeItem(at: cleanupTarget)
            }
            onFinish(.failed(Self.postprocessSpaceFailureMessage(
                required: requiredBytes, available: available)), nil)
            return
        }

        let processedPartURL = Filename.temporaryURL(for: outURL, suffix: ".postprocess.part")
        try? FileManager.default.removeItem(at: processedPartURL)
        let seekArgs = clipStart.map { ["-ss", String(format: "%.3f", $0)] } ?? []
        let durArgs = clipDuration.map { ["-t", String(format: "%.3f", $0)] } ?? []
        let muxer = audioOnly ? "ipod" : "mp4"
        let localHLSArgs = sourceURL.pathExtension.lowercased() == "m3u8"
            ? ["-allowed_extensions", "ALL", "-extension_picky", "0",
               "-protocol_whitelist", "file,crypto,pipe", "-i", sourceURL.path]
            : ["-i", sourceURL.path]
        func runFFmpegPostprocess(transcodeAudio: Bool) {
            let streamArgs = transcodeAudio
                ? Self.aacFallbackStreamArgs(audioOnly: audioOnly)
                : Self.copyStreamArgs(audioOnly: audioOnly)
            var args: [String] = ["-y"]
            args += seekArgs
            args += localHLSArgs
            args += durArgs
            args += streamArgs
            args += ["-progress", "pipe:2", "-f", muxer, processedPartURL.path]

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = args
            if sourceURL.pathExtension.lowercased() == "m3u8" {
                proc.currentDirectoryURL = sourceURL.deletingLastPathComponent()
            }
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice

            let output = FFmpegOutputCapture()
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { return }
                output.consume(chunk) { summary in
                    let outTime = summary["out_time"] ?? "00:00:00"
                    let secs = ProgressParser.parseTime(outTime)
                    let size = Int(summary["total_size"] ?? "0") ?? 0
                    let postPct = progressDuration > 0 ? min(1.0, secs / progressDuration) : 0
                    let speed = transcodeAudio
                        ? Self.formattedFFmpegSpeed(summary["speed"], fallback: "AAC 변환")
                        : Self.formattedFFmpegSpeed(summary["speed"], fallback: "로컬 처리")
                    onProgress(0.92 + postPct * 0.08,
                               ProgressParser.formatSize(Double(size)), speed, outTime)
                }
            }

            proc.terminationHandler = { [weak self] p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                output.consume(errPipe.fileHandleForReading.readDataToEndOfFile())
                let logTail = output.finishAndTail()
                let canceled = self?.state.withValue { state in
                    let canceled = state.processes[item.id] == nil
                    state.processes.removeValue(forKey: item.id)
                    return canceled
                } ?? false
                if canceled {
                    try? FileManager.default.removeItem(at: processedPartURL)
                    try? FileManager.default.removeItem(at: cleanupTarget)
                    onFinish(.canceled, nil)
                } else if p.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: cleanupTarget)
                    do {
                        try FileManager.default.moveItem(at: processedPartURL, to: outURL)
                        onFinish(.completed, outURL.path)
                    } catch {
                        onFinish(.failed(error.localizedDescription), nil)
                    }
                } else if !transcodeAudio,
                          Self.shouldRetryPostprocessWithAAC(status: p.terminationStatus, logTail: logTail) {
                    try? FileManager.default.removeItem(at: processedPartURL)
                    onProgress(0.92, ProgressParser.formatSize(Double(sourceSizeForEstimate)), "AAC 변환 재시도", "")
                    runFFmpegPostprocess(transcodeAudio: true)
                } else {
                    try? FileManager.default.removeItem(at: processedPartURL)
                    if !preserveSourceOnFailure {
                        try? FileManager.default.removeItem(at: cleanupTarget)
                    }
                    let prefix = transcodeAudio ? "ffmpeg AAC 변환" : "ffmpeg 로컬 처리"
                    let message = Self.ffmpegFailureMessage(
                        prefix: prefix, status: p.terminationStatus, logTail: logTail)
                    if let onFailureFallback,
                       !Self.isFFmpegNoSpaceFailure(status: p.terminationStatus, logTail: logTail) {
                        onFailureFallback(message)
                    } else {
                        onFinish(.failed(message), nil)
                    }
                }
            }

            state.update { $0.processes[item.id] = proc }
            do { try proc.run() }
            catch {
                state.update { $0.processes.removeValue(forKey: item.id) }
                errPipe.fileHandleForReading.readabilityHandler = nil
                output.consume(errPipe.fileHandleForReading.readDataToEndOfFile())
                try? FileManager.default.removeItem(at: processedPartURL)
                if !preserveSourceOnFailure {
                    try? FileManager.default.removeItem(at: cleanupTarget)
                }
                if let onFailureFallback {
                    onFailureFallback(error.localizedDescription)
                } else {
                    onFinish(.failed(error.localizedDescription), nil)
                }
            }
        }

        runFFmpegPostprocess(transcodeAudio: false)
    }

    private func startFFmpeg(item: VODItem, variant: VODVariant, ffmpegPath: String,
                             cookies: Cookies, duration: Double, outURL: URL, audioOnly: Bool,
                             clipStart: Double? = nil, clipDuration: Double? = nil,
                             onProgress: @escaping (Double, String, String, String) -> Void,
                             onFinish: @escaping (VODState, String?) -> Void) {
        let partURL = Filename.temporaryURL(for: outURL, suffix: ".part")
        try? FileManager.default.removeItem(at: partURL)   // ffmpeg path restarts from scratch
        // Clip seek: keep -ss before -i so ffmpeg can use HTTP range requests.
        // Do not fall back to accurate seek after -i; that reads from the beginning
        // and defeats the purpose of partial download.
        let args = Self.remoteFFmpegArguments(
            variantURL: variant.url, cookies: cookies, outURL: outURL, partURL: partURL,
            audioOnly: audioOnly, clipStart: clipStart, clipDuration: clipDuration)
        onProgress(0, clipStart != nil ? "ffmpeg 구간 요청 준비중…" : "ffmpeg 요청 준비중…", "", "")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        let output = FFmpegOutputCapture()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            output.consume(chunk) { summary in
                let outTime = summary["out_time"] ?? "00:00:00"
                let secs = ProgressParser.parseTime(outTime)
                let size = Int(summary["total_size"] ?? "0") ?? 0
                let pct = duration > 0 ? min(1.0, secs / duration) : 0
                onProgress(pct, ProgressParser.formatSize(Double(size)),
                           Self.formattedFFmpegSpeed(summary["speed"], fallback: "N/A"), outTime)
            }
        }

        proc.terminationHandler = { [weak self] p in
            errPipe.fileHandleForReading.readabilityHandler = nil
            output.consume(errPipe.fileHandleForReading.readDataToEndOfFile())
            let logTail = output.finishAndTail()
            let canceled = self?.state.withValue { state in
                let canceled = state.processes[item.id] == nil
                state.processes.removeValue(forKey: item.id)
                return canceled
            } ?? false
            if canceled {
                try? FileManager.default.removeItem(at: partURL); onFinish(.canceled, nil)
            } else if p.terminationStatus == 0 {
                do {
                    try? FileManager.default.removeItem(at: outURL)
                    try FileManager.default.moveItem(at: partURL, to: outURL)
                    onFinish(.completed, outURL.path)
                } catch {
                    onFinish(.failed(error.localizedDescription), nil)
                }
            } else {
                try? FileManager.default.removeItem(at: partURL)
                let failure = Self.ffmpegFailureMessage(
                    prefix: clipStart != nil ? "ffmpeg 구간 다운로드" : "ffmpeg",
                    status: p.terminationStatus, logTail: logTail)
                // The "range seek" hint only makes sense for input/seek failures.
                // Don't show it for output errors (e.g. missing folder).
                let looksOutputError = logTail.contains {
                    $0.localizedCaseInsensitiveContains("Error opening output")
                        || $0.localizedCaseInsensitiveContains("No such file")
                }
                let hint = (clipStart != nil && !looksOutputError)
                    ? " 서버가 HTTP range seek를 거부했을 수도 있습니다." : ""
                onFinish(.failed(failure + hint), nil)
            }
        }

        state.update { $0.processes[item.id] = proc }
        do { try proc.run() }
        catch {
            state.update { $0.processes.removeValue(forKey: item.id) }
            errPipe.fileHandleForReading.readabilityHandler = nil
            output.consume(errPipe.fileHandleForReading.readDataToEndOfFile())
            onFinish(.failed(error.localizedDescription), nil)
        }
    }

    private static func uniquePath(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for i in 1..<1000 {
            let name = ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)"
            let cand = dir.appendingPathComponent(Filename.shortenedComponent(name))
            if !FileManager.default.fileExists(atPath: cand.path) { return cand }
        }
        return url
    }
}
