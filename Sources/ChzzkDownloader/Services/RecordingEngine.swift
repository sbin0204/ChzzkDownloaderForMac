import Foundation

/// Orchestrates per-channel recording (streamlink piped into ffmpeg).
///
/// Not @MainActor: runs subprocesses off the main thread and delivers updates
/// through callbacks. Config is read from a serial state snapshot.
final class RecordingEngine {
    var onLog: ((String) -> Void)?
    var onProgress: ((ChannelProgress) -> Void)?
    var onProgressRemove: ((String) -> Void)?
    var onSaved: ((_ channelName: String, _ path: String, _ wasSplit: Bool) -> Void)?
    var onRecordingEnded: ((_ channelID: String, _ oneShot: Bool) -> Void)?
    var onAuthFailure: ((_ context: String) -> Void)?
    /// Fires when a live recording actually starts. `isContinuation` is true for
    /// the next segment after a split (so "started" pings fire once per broadcast).
    var onRecordingStarted: ((_ channelName: String, _ channelID: String, _ isContinuation: Bool) -> Void)?

    private struct State {
        var snapshot = Config()
        var recordingTasks: [String: RecordingTask] = [:]
        var sessions: [String: RecordingSession] = [:]
        var manualSplits: Set<String> = []   // channels with a pending "save now"
        var wakeCounters: [String: Int] = [:]
    }

    private struct RecordingTask {
        var id: UUID
        var task: Task<Void, Never>?
    }

    private let state = Synchronized(State(), label: "ChzzkDownloader.RecordingEngine.state")

    private var ffmpegPath = ""
    private var streamlinkPath = ""
    private var pluginDir = ""

    private var pathsConfigured = false

    func updateSnapshot(_ config: Config) {
        state.update { $0.snapshot = config }
    }

    private func currentConfig() -> Config {
        state.withValue { $0.snapshot }
    }

    // MARK: lifecycle

    func configure(ffmpegPath: String, streamlinkPath: String, pluginDir: String) {
        self.ffmpegPath = ffmpegPath
        self.streamlinkPath = streamlinkPath
        self.pluginDir = pluginDir
        pathsConfigured = true
    }

    /// Start recording a channel. Records the current live immediately, or — if the
    /// channel is offline — waits and records when it goes live, then keeps recording
    /// each subsequent live session until stopped. This is the single recording path.
    func startRecording(channelID: String, oneShot: Bool = false) {
        guard pathsConfigured else { return }
        let taskID = UUID()
        let inserted = state.withValue { state in
            guard state.recordingTasks[channelID] == nil else { return false }
            state.recordingTasks[channelID] = RecordingTask(id: taskID, task: nil)
            return true
        }
        guard inserted else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.recordChannel(channelID, oneShot: oneShot)
            self.finishRecordingTask(channelID: channelID, taskID: taskID, oneShot: oneShot)
        }
        let stillCurrent = state.withValue { state in
            guard var current = state.recordingTasks[channelID], current.id == taskID else { return false }
            current.task = task
            state.recordingTasks[channelID] = current
            return true
        }
        if !stillCurrent { task.cancel() }
    }

    func hasRecordingTask(channelID: String) -> Bool {
        state.withValue { $0.recordingTasks[channelID] != nil }
    }

    /// Interrupts a monitoring sleep so a live-status poll can make an armed
    /// channel re-check immediately instead of waiting for the full rescan interval.
    func wake(channelID: String) {
        state.update { $0.wakeCounters[channelID, default: 0] += 1 }
    }

    func stopRecording(channelID: String) {
        let (recordingTask, session) = state.withValue { state in
            let task = state.recordingTasks.removeValue(forKey: channelID)
            let session = state.sessions.removeValue(forKey: channelID)
            state.manualSplits.remove(channelID)
            state.wakeCounters.removeValue(forKey: channelID)
            return (task, session)
        }
        recordingTask?.task?.cancel()
        session?.requestFinish()
        onProgressRemove?(channelID)
    }

    /// "Save so far": finalize the current segment now and immediately continue
    /// recording into a new file. No-op when the channel isn't actively writing.
    func splitNow(channelID: String) {
        let session = state.withValue { state -> RecordingSession? in
            guard let session = state.sessions[channelID] else { return nil }
            state.manualSplits.insert(channelID)
            return session
        }
        session?.requestFinish()
    }

    func terminateAll() {
        let (tasks, sessions) = state.withValue { state in
            let tasks = state.recordingTasks
            let sessions = state.sessions
            state.recordingTasks.removeAll()
            state.sessions.removeAll()
            state.wakeCounters.removeAll()
            return (tasks, sessions)
        }
        for task in tasks.values {
            task.task?.cancel()
        }
        for (channelID, session) in sessions {
            session.terminate()
            onProgressRemove?(channelID)
        }
    }

    private func finishRecordingTask(channelID: String, taskID: UUID, oneShot: Bool) {
        let removed = state.withValue { state in
            guard state.recordingTasks[channelID]?.id == taskID else { return false }
            state.recordingTasks.removeValue(forKey: channelID)
            state.wakeCounters.removeValue(forKey: channelID)
            return true
        }
        if removed {
            onRecordingEnded?(channelID, oneShot)
        }
    }

    // MARK: per-channel recording loop

    private func recordChannel(_ channelID: String, oneShot: Bool) async {
        guard let channel0 = currentConfig().channels.first(where: { $0.id == channelID }) else { return }
        let channelName = channel0.name
        var cameFromSplit = false   // true when the previous segment ended on a split
        var consecutiveFailures = 0 // short back-to-back failures -> capped backoff
        // A session that ends sooner than this is treated as a transient failure
        // (stream hiccup) rather than a real broadcast end.
        let transientThreshold: TimeInterval = 20

        while !Task.isCancelled {
            let cfg = currentConfig()
            guard cfg.channels.contains(where: { $0.id == channelID }) else { return }

            // Wait for the channel to go live (and, if a tag filter is set, for a
            // live whose tags match it). The timeout is re-clamped here because the
            // settings UI can briefly hold an out-of-range value before its own
            // clamping kicks in, and UInt64(negative) would crash.
            let waitSeconds = UInt64(max(1, cfg.timeout))
            var live: LiveInfo?
            var loggedTagSkip = false
            var loggedNoMedia = false
            while !Task.isCancelled {
                let pollConfig = currentConfig()
                let channel = pollConfig.channels.first(where: { $0.id == channelID })
                let result = await ChzzkAPI.fetchLiveInfoResult(
                    channelID: channelID, cookies: pollConfig.cookies)
                let info: LiveInfo?
                switch result {
                case .info(let value):
                    info = value
                case .authFailed:
                    onAuthFailure?("\(channelName) 라이브 상태 확인")
                    info = nil
                }
                if let info, info.status == "OPEN" {
                    // OPEN but no playback media (adult stream without auth, region
                    // block, …): streamlink would fail instantly and the transient
                    // retry would spin forever, so wait here instead.
                    if !info.hasMedia {
                        if !loggedNoMedia {
                            onLog?("'\(channelName)' 방송 재생 정보를 가져올 수 없어 대기합니다"
                                   + (info.adult ? " (성인 인증 방송 — 쿠키를 확인하세요)." : "."))
                            loggedNoMedia = true
                        }
                        await sleepOrWake(channelID: channelID, seconds: waitSeconds)
                        continue
                    }
                    loggedNoMedia = false
                    if let channel, !channel.acceptsTags(info.tags) {
                        if !loggedTagSkip {
                            let tagText = info.tags.isEmpty ? "없음" : info.tags.joined(separator: ", ")
                            onLog?("'\(channelName)' 방송 중이지만 태그가 일치하지 않아 건너뜁니다 (방송 태그: \(tagText)).")
                            loggedTagSkip = true
                        }
                        await sleepOrWake(channelID: channelID, seconds: waitSeconds)
                        continue
                    }
                    live = info
                    break
                }
                loggedTagSkip = false
                loggedNoMedia = false
                if info?.status == "BLOCK" {
                    onLog?("'\(channelName)' 채널이 차단되었습니다.")
                }
                onLog?("'\(channelName)' 채널의 방송 시작을 기다리는 중…")
                await sleepOrWake(channelID: channelID, seconds: waitSeconds)
            }
            guard !Task.isCancelled, let liveInfo = live else { return }

            // The channel may be edited while it is armed and waiting for live.
            // Refresh right before creating the output path so a newly selected
            // recording folder is used for the first file of the session.
            let sessionConfig = currentConfig()
            guard let sessionChannel = sessionConfig.channels.first(where: { $0.id == channelID }) else { return }
            let sessionStart = Date()
            let shouldContinueImmediately = await runSession(
                channel: sessionChannel, liveInfo: liveInfo, config: sessionConfig,
                isContinuation: cameFromSplit)
            let sessionSeconds = Date().timeIntervalSince(sessionStart)
            cameFromSplit = shouldContinueImmediately

            if shouldContinueImmediately {
                consecutiveFailures = 0
                continue   // hit a split limit -> start the next segment immediately
            }
            if Task.isCancelled { return }

            // Ended almost immediately -> treat as a transient stream hiccup, not a
            // real broadcast end: retry quickly (capped backoff) so a live channel is
            // not left unrecorded for a whole rescan interval.
            if sessionSeconds < transientThreshold {
                consecutiveFailures += 1
                let backoff = min(UInt64(max(cfg.timeout, 1)),
                                  UInt64(pow(2.0, Double(min(consecutiveFailures, 5)))))
                onLog?("'\(channelName)' 녹화가 시작 직후 끊겨 \(backoff)초 후 다시 시도합니다.")
                await sleepOrWake(channelID: channelID, seconds: backoff)
                continue
            }

            // Recorded for a while -> the broadcast has ended.
            consecutiveFailures = 0
            if oneShot { return }
            await sleepOrWake(channelID: channelID, seconds: UInt64(max(1, cfg.timeout)))
        }
    }

    private func wakeCounter(channelID: String) -> Int {
        state.withValue { $0.wakeCounters[channelID] ?? 0 }
    }

    private func sleepOrWake(channelID: String, seconds: UInt64) async {
        guard seconds > 0 else { return }
        let startCounter = wakeCounter(channelID: channelID)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while !Task.isCancelled {
            if wakeCounter(channelID: channelID) != startCounter { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            let interval = min(1.0, remaining)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Returns true when the session ended because it hit a split limit and the
    /// caller should start the next recording segment immediately.
    private func runSession(channel: Channel, liveInfo: LiveInfo, config: Config,
                            isContinuation: Bool) async -> Bool {
        let channelID = channel.id
        let channelName = channel.name

        // Resolve output format (AV1 + ts -> mkv fallback).
        var format = config.output_format
        if config.av1_settings.enable && format == "ts" {
            onLog?("\(channelName): AV1은 TS와 함께 쓸 수 없어 MKV로 전환합니다.")
            format = "mkv"
        }

        // Build filenames: "[YYYY-MM-DD HH_MM_SS] name title.fmt[.part]".
        let now = AppModel.timestamp()
        let title = Validate.sanitizeFilename(liveInfo.liveTitle, fallback: "untitled")
        let stampForName = now.replacingOccurrences(of: ":", with: "_")
        let baseName = Filename.shortenedComponent("[\(stampForName)] \(channelName) \(title).\(format)")
        let outputDir = Self.resolveOutputDir(channel.output_dir)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        // Guard against a vanished/read-only destination (e.g. an unplugged external
        // drive) so we surface a clear error instead of silently failing to write.
        var isDir: ObjCBool = false
        let dirUsable = FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDir)
            && isDir.boolValue && FileManager.default.isWritableFile(atPath: outputDir.path)
        if !dirUsable {
            onLog?("\(channelName) 녹화 실패: 저장 폴더에 쓸 수 없습니다 (\(outputDir.path)). 폴더·디스크 연결을 확인하세요.")
            return false
        }
        let tempURL = outputDir.appendingPathComponent(baseName + ".part")
        let finalURL = outputDir.appendingPathComponent(baseName)
        let splitLimitBytes = config.live_split_size_mb > 0
            ? Int64(config.live_split_size_mb) * 1_048_576
            : 0
        let splitLimitSeconds = config.live_split_duration_minutes > 0
            ? UInt64(config.live_split_duration_minutes) * 60
            : 0

        // Build commands.
        let streamlinkArgs = FFmpegArgs.streamlinkArguments(
            channelID: channelID, cookies: config.cookies, pluginDir: pluginDir,
            threads: config.stream_segment_threads, ffmpegPath: ffmpegPath,
            quality: channel.quality)
        let ffmpegArgs = FFmpegArgs.ffmpegArguments(
            config: config, format: format, outputPath: tempURL.path)

        let session = RecordingSession(
            streamlinkPath: streamlinkPath, streamlinkArgs: streamlinkArgs,
            ffmpegPath: ffmpegPath, ffmpegArgs: ffmpegArgs)
        state.update { $0.sessions[channelID] = session }
        let splitReason = Synchronized<String?>(nil, label: "ChzzkDownloader.RecordingEngine.split.\(channelID)")

        let parser = ProgressParser(channelID: channelID, channelName: channelName, startTime: now)
        parser.onUpdate = { [weak self] p in self?.onProgress?(p) }
        let splitMonitor: Task<Void, Never>? = splitLimitBytes > 0 ? Task { [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                if Task.isCancelled { return }
                let size = Self.fileSize(tempURL)
                guard size >= splitLimitBytes else { continue }
                let alreadyRequested = splitReason.withValue { reason in
                    if reason != nil { return true }
                    reason = "용량 \(config.live_split_size_mb)MB"
                    return false
                }
                if alreadyRequested { return }
                self?.onLog?("\(channelName) 녹화 파일이 \(config.live_split_size_mb)MB에 도달해 새 파일로 분할합니다.")
                session?.requestFinish()
                return
            }
        } : nil
        let timeSplitMonitor: Task<Void, Never>? = splitLimitSeconds > 0 ? Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: splitLimitSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            let alreadyRequested = splitReason.withValue { reason in
                if reason != nil { return true }
                reason = "시간 \(config.live_split_duration_minutes)분"
                return false
            }
            if alreadyRequested { return }
            self?.onLog?("\(channelName) 녹화 시간이 \(config.live_split_duration_minutes)분에 도달해 새 파일로 분할합니다.")
            session?.requestFinish()
        } : nil

        do {
            try session.start(
                onFfmpegStderr: { line in parser.feed(line) },
                onStreamlinkStderr: { [weak self] line in
                    self?.onLog?("streamlink [\(channelID)]: \(line)")
                    if ChzzkAPI.looksLikeAuthFailure(line) {
                        self?.onAuthFailure?("\(channelName) 라이브 녹화")
                    }
                })
            onLog?("\(channelName) 녹화를 시작했습니다 (\(now)).")
            onRecordingStarted?(channelName, channelID, isContinuation)
            await session.waitUntilExit()
        } catch {
            onLog?("\(channelName) 녹화 오류: \(error.localizedDescription)")
        }
        splitMonitor?.cancel()
        timeSplitMonitor?.cancel()

        session.terminate()
        state.update { $0.sessions.removeValue(forKey: channelID) }
        onProgressRemove?(channelID)
        // A split is either an automatic size/time split or a manual "save now".
        let manualSplit = state.withValue { $0.manualSplits.remove(channelID) != nil }
        let reason = splitReason.withValue { $0 } ?? (manualSplit ? "수동 저장" : nil)
        let split = reason != nil && !Task.isCancelled
        if let reason, split {
            onLog?("\(channelName) 녹화 파일을 분할했습니다 (\(reason)).")
        } else {
            onLog?("\(channelName) 녹화를 종료했습니다.")
        }

        // Atomically rename temp -> final (unique). Only report success when the
        // rename actually succeeded — otherwise the file is still a .part and a
        // "saved" notification would be a lie.
        if FileManager.default.fileExists(atPath: tempURL.path) {
            let dest = Self.uniquePath(finalURL)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                onLog?("녹화 파일 저장: \(dest.path)")
                onSaved?(channelName, dest.path, split)
            } catch {
                onLog?("\(channelName) 녹화 파일 이름 변경 실패: \(error.localizedDescription)"
                       + " — 임시 파일로 남아 있습니다: \(tempURL.path)")
            }
        }
        return split
    }

    // MARK: filename helpers

    static func resolveOutputDir(_ value: String) -> URL {
        let text = Validate.normalizeRecordingOutputDir(value)
        let expanded = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if url.path.hasPrefix("/") && text.hasPrefix("/") { return url }
        if expanded.hasPrefix("/") { return url }
        // Relative path -> resolve under ~/Movies/ChzzkDownloader.
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChzzkDownloader", isDirectory: true)
        return text == "." ? movies : movies.appendingPathComponent(text)
    }

    static func uniquePath(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for i in 1..<1000 {
            let name = ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)"
            let candidate = dir.appendingPathComponent(Filename.shortenedComponent(name))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// Renames orphaned `[timestamp] ….part` recordings (left behind by a crash or
    /// force quit) to their playable final names. Safe to call at launch, before any
    /// recording starts. Returns the recovered file names.
    static func salvageOrphanParts(outputDirs: [String]) -> [String] {
        let fm = FileManager.default
        var salvaged: [String] = []
        var visited = Set<String>()
        for dirValue in outputDirs {
            let dir = resolveOutputDir(dirValue)
            guard visited.insert(dir.path).inserted,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for url in entries {
                let name = url.lastPathComponent
                guard name.hasPrefix("["), name.hasSuffix(".part") else { continue }
                let dest = uniquePath(dir.appendingPathComponent(String(name.dropLast(".part".count))))
                if (try? fm.moveItem(at: url, to: dest)) != nil {
                    salvaged.append(dest.lastPathComponent)
                }
            }
        }
        return salvaged
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let value = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return value?.int64Value ?? 0
    }

}
