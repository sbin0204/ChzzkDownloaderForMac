import Foundation

// MARK: - Live recording: polling, control, monitoring persistence, scheduler, channels

extension AppModel {

    // MARK: live status polling (for the dashboard on-demand panel)

    func startLivePolling() {
        livePoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let channels = self.config.channels
                let cookies = self.config.cookies
                await withTaskGroup(of: (String, LiveInfo?, Bool).self) { group in
                    for ch in channels {
                        group.addTask {
                            let result = await ChzzkAPI.fetchLiveInfoResult(channelID: ch.id, cookies: cookies)
                            switch result {
                            case .info(let info):
                                return (ch.id, info, false)
                            case .authFailed:
                                return (ch.id, nil, true)
                            }
                        }
                    }
                    for await (id, info, authFailed) in group {
                        let live = info?.status == "OPEN"
                        self.liveStatus[id] = (
                            live, info?.liveTitle ?? "", info?.category ?? "",
                            info?.tags ?? [], info?.hasMedia ?? false)
                        if authFailed {
                            self.markCookieAuthFailure(context: "라이브 상태 확인")
                        }
                        // Only nudge when the engine could actually record: a live
                        // without media or with non-matching tags would just burn an
                        // extra live-detail fetch every poll.
                        let tagsMatch = self.config.channels.first(where: { $0.id == id })?
                            .acceptsTags(info?.tags ?? []) ?? true
                        if Self.shouldNudgeArmedRecording(
                            isLive: live,
                            isArmed: self.recordingChannels.contains(id),
                            isWriting: self.isWritingRecording(id),
                            canRecord: (info?.hasMedia ?? false) && tagsMatch) {
                            self.nudgeArmedRecording(channelID: id)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            }
        }
    }

    // MARK: per-channel recording (the single recording control)

    /// True while this channel is recording or armed (waiting for it to go live).
    func isRecording(_ id: String) -> Bool { recordingChannels.contains(id) }

    func startRecording(_ channel: Channel, oneShot: Bool = false) {
        guard ensureTools(needStreamlink: true) else { return }
        engine.startRecording(channelID: channel.id, oneShot: oneShot)
        if oneShot {
            oneShotRecordingChannels.insert(channel.id)
        } else {
            oneShotRecordingChannels.remove(channel.id)
        }
        recordingChannels.insert(channel.id)
        appendLog("\(channel.name) 녹화를 시작합니다.")
    }

    func stopRecording(_ channel: Channel) {
        engine.stopRecording(channelID: channel.id)
        recordingChannels.remove(channel.id)
        oneShotRecordingChannels.remove(channel.id)
        appendLog("\(channel.name) 녹화를 중지했습니다.")
    }

    /// True while a channel is actively writing a recording file (not just armed).
    func isWritingRecording(_ id: String) -> Bool { progress.contains { $0.id == id } }

    /// "Save so far": finalize the current segment now and keep recording into a
    /// new file. Only meaningful while the channel is actively writing.
    func saveNow(_ channel: Channel) {
        guard isWritingRecording(channel.id) else { return }
        engine.splitNow(channelID: channel.id)
        appendLog("\(channel.name) 현재까지 녹화를 저장합니다.")
        showToast("현재까지 저장 중…")
    }

    /// Trims a channel's recordings to the configured count/size budget (Trash).
    func enforceCyclicLimit(channelName: String, savedPath: String) {
        guard config.cyclic_recording_enabled,
              config.cyclic_max_files > 0 || config.cyclic_max_size_gb > 0 else { return }
        let maxFiles = config.cyclic_max_files
        let maxSize = config.cyclic_max_size_gb
        Task { @MainActor [weak self] in
            let trashed = await Task.detached(priority: .utility) {
                CyclicRecording.enforce(
                    channelName: channelName, savedPath: savedPath,
                    maxFiles: maxFiles, maxSizeGB: maxSize)
            }.value
            guard !trashed.isEmpty else { return }
            self?.appendLog("순환 녹화: 오래된 파일 \(trashed.count)개를 휴지통으로 이동했습니다.")
        }
    }

    // MARK: monitoring persistence (armed channels survive restarts)

    /// Persists the set of continuously-monitored channels (excluding one-shot
    /// scheduled recordings, which the scheduler resumes on its own) so monitoring
    /// can be restored on the next launch. No-op while restoring at launch.
    func persistArmedChannelsIfChanged(_ oldValue: Set<String>) {
        guard !suppressArmedPersist else { return }
        let desired = recordingChannels.subtracting(oneShotRecordingChannels)
        if Set(config.armed_channels) != desired {
            config.armed_channels = desired.sorted()
        }
    }

    /// Recovers `.part` recordings orphaned by a crash/force quit by renaming them
    /// to their final playable names. Runs before monitoring is restored so a new
    /// session's fresh .part can never be picked up.
    func salvageOrphanRecordings() {
        let dirs = config.channels.map(\.output_dir) + ["."]
        let salvaged = RecordingEngine.salvageOrphanParts(outputDirs: dirs)
        guard !salvaged.isEmpty else { return }
        appendLog("지난 세션의 미완성 녹화 \(salvaged.count)개를 복구했습니다: \(salvaged.joined(separator: ", "))")
    }

    /// Re-arms channels that were being monitored when the app last quit. Each one
    /// starts in the same continuous-monitoring mode (records the current live now
    /// if any, otherwise waits for the next broadcast).
    func restoreArmedChannels() {
        let ids = config.armed_channels.filter { id in
            config.channels.contains { $0.id == id }
        }
        guard !ids.isEmpty else { return }
        guard toolsAvailable else {
            appendLog("이전 감시 복원 보류: 필수 도구(ffmpeg/streamlink)가 없습니다.")
            return
        }
        suppressArmedPersist = true
        defer { suppressArmedPersist = false }
        for id in ids {
            guard let channel = config.channels.first(where: { $0.id == id }),
                  !recordingChannels.contains(id) else { continue }
            engine.startRecording(channelID: id, oneShot: false)
            oneShotRecordingChannels.remove(id)
            recordingChannels.insert(id)
            appendLog("이전 감시 복원: \(channel.name)")
        }
    }

    nonisolated static func shouldNudgeArmedRecording(
        isLive: Bool, isArmed: Bool, isWriting: Bool, canRecord: Bool = true
    ) -> Bool {
        isLive && isArmed && !isWriting && canRecord
    }

    private func nudgeArmedRecording(channelID: String) {
        engine.wake(channelID: channelID)
        guard !engine.hasRecordingTask(channelID: channelID),
              let channel = config.channels.first(where: { $0.id == channelID }) else {
            return
        }
        let oneShot = oneShotRecordingChannels.contains(channelID)
        engine.startRecording(channelID: channelID, oneShot: oneShot)
        appendLog("감시 작업 복구: \(channel.name) 방송이 감지되어 녹화 엔진을 다시 연결합니다.")
    }

    // MARK: scheduled recording

    func startScheduler() {
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tickSchedules()
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            }
        }
    }

    private func tickSchedules() {
        guard !config.schedules.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let plan = SchedulePlanner.tick(
            schedules: config.schedules,
            channels: config.channels,
            recordingChannels: recordingChannels,
            now: now)
        config.schedules = plan.schedules
        for action in plan.actions {
            switch action {
            case .start(let channelID, let oneShot):
                guard let channel = config.channels.first(where: { $0.id == channelID }) else { continue }
                startRecording(channel, oneShot: oneShot)
                appendLog("예약 녹화 시작: \(channel.name)")
            case .stop(let channelID):
                guard let channel = config.channels.first(where: { $0.id == channelID }) else { continue }
                stopRecording(channel)
                appendLog("예약 녹화 종료: \(channel.name)")
            }
        }
    }

    func addSchedule(channelID: String, start: Date, durationMinutes: Int) {
        config.schedules.append(Schedule(
            channelID: channelID, startEpoch: start.timeIntervalSince1970,
            durationMinutes: max(0, durationMinutes)))
    }

    func deleteSchedule(_ id: UUID) {
        let plan = SchedulePlanner.delete(
            schedules: config.schedules,
            id: id,
            recordingChannels: recordingChannels)
        config.schedules = plan.schedules
        if case .stop(let channelID) = plan.action,
           let channel = config.channels.first(where: { $0.id == channelID }) {
            stopRecording(channel)
            appendLog("예약 삭제로 녹화를 종료했습니다: \(channel.name)")
        }
    }

    // MARK: channel management

    enum ChannelEditResult { case ok, invalidID, duplicateID }

    /// Adds a channel after validating the ID format and rejecting duplicates.
    func addChannel(id: String, name: String, outputDir: String, quality: String = Defaults.liveQuality,
                    tagFilter: [String] = [], stopOnTagMismatch: Bool = false) -> ChannelEditResult {
        let cid = id.trimmingCharacters(in: .whitespaces)
        guard Validate.matches(Validate.safeChannelID, cid) else { return .invalidID }
        guard !config.channels.contains(where: { $0.id == cid }) else { return .duplicateID }
        config.channels.append(Channel(
            id: cid, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? cid : name.trimmingCharacters(in: .whitespaces),
            output_dir: Validate.normalizeRecordingOutputDir(outputDir),
            quality: quality,
            tag_filter: tagFilter,
            stop_on_tag_mismatch: stopOnTagMismatch))
        return .ok
    }

    /// Edits an existing channel (identified by its current ID). Rejects a new ID
    /// that collides with a *different* channel.
    func updateChannel(
        originalID: String, id: String, name: String, outputDir: String,
        quality: String = Defaults.liveQuality, tagFilter: [String] = [],
        stopOnTagMismatch: Bool = false
    ) -> ChannelEditResult {
        guard let i = config.channels.firstIndex(where: { $0.id == originalID }) else { return .invalidID }
        let cid = id.trimmingCharacters(in: .whitespaces)
        guard Validate.matches(Validate.safeChannelID, cid) else { return .invalidID }
        if config.channels.enumerated().contains(where: { $0.offset != i && $0.element.id == cid }) {
            return .duplicateID
        }
        // If the ID changed while recording, stop the (now mis-keyed) recording.
        if cid != originalID, recordingChannels.contains(originalID) {
            engine.stopRecording(channelID: originalID)
            recordingChannels.remove(originalID)
            oneShotRecordingChannels.remove(originalID)
        }
        config.channels[i].id = cid
        config.channels[i].name = name.trimmingCharacters(in: .whitespaces).isEmpty ? cid : name.trimmingCharacters(in: .whitespaces)
        config.channels[i].output_dir = Validate.normalizeRecordingOutputDir(outputDir)
        config.channels[i].quality = Validate.normalizeLiveQuality(quality)
        config.channels[i].tag_filter = Validate.normalizeTagFilter(tagFilter)
        config.channels[i].stop_on_tag_mismatch = stopOnTagMismatch
        if cid != originalID {
            config.schedules = SchedulePlanner.renameChannelReferences(
                schedules: config.schedules,
                from: originalID,
                to: cid)
            if let status = liveStatus.removeValue(forKey: originalID) {
                liveStatus[cid] = status
            }
        }
        return .ok
    }

    func deleteChannel(id: String) {
        if recordingChannels.contains(id) {
            engine.stopRecording(channelID: id)
            recordingChannels.remove(id)
            oneShotRecordingChannels.remove(id)
        }
        progress.removeAll { $0.id == id }
        liveStatus.removeValue(forKey: id)
        config.schedules = SchedulePlanner.removeChannelReferences(
            schedules: config.schedules,
            channelID: id)
        config.channels.removeAll { $0.id == id }
    }
}
