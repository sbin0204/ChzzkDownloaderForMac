import Foundation

// MARK: - VOD downloads and download history

extension AppModel {

    // MARK: VOD download

    @discardableResult
    func addVOD(urlString: String, autoStart: Bool = false) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= ChzzkVODAPI.maxPageURLLength else {
            cookieImportMessage = nil
            appendLog("VOD URL이 너무 깁니다.")
            showToast("URL은 \(ChzzkVODAPI.maxPageURLLength)자까지만 입력할 수 있습니다")
            return false
        }
        guard ChzzkVODAPI.parseURL(trimmed) != nil else {
            cookieImportMessage = nil
            appendLog("잘못된 VOD URL: \(trimmed)")
            return false
        }
        let item = VODItem(url: trimmed)
        vodItems.insert(item, at: 0)
        let cookies = config.cookies
        Task {
            do {
                let (meta, variants) = try await ChzzkVODAPI.resolve(urlString: trimmed, cookies: cookies)
                item.title = meta.title
                item.channelName = meta.channelName
                item.durationSeconds = meta.duration
                item.variants = variants
                item.selectedQuality = variants.last?.quality
                item.state = .ready
                // App Intents path: begin downloading as soon as it resolves so a
                // "download this VOD" command actually downloads, not just queues.
                if autoStart { self.startVOD(item) }
            } catch {
                item.state = .failed(error.localizedDescription)
                handleCookieAuthFailureIfNeeded(error, context: "VOD 정보 조회")
                appendLog("VOD 정보 조회 실패: \(error.localizedDescription)")
            }
        }
        return true
    }

    func addImportedVODSource(urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VODSourceImporter.isSupportedSourceURL(trimmed) else { return false }
        let item = VODItem(url: trimmed)
        item.importedSource = true
        item.title = URL(string: trimmed)?.deletingPathExtension().lastPathComponent ?? "가져온 소스"
        item.channelName = "가져온 소스"
        vodItems.insert(item, at: 0)
        appendLog("VOD 소스 URL 가져오기: \(item.title)")

        Task {
            do {
                let imported = try await VODSourceImporter.importURLString(trimmed)
                item.title = imported.title
                item.channelName = imported.channelName
                item.durationSeconds = imported.duration
                item.variants = imported.variants
                item.selectedQuality = imported.variants.last?.quality
                item.audioOnly = false
                item.state = .ready
                appendLog("VOD 소스 URL 가져오기 완료: \(imported.variants.count)개 화질")
            } catch {
                item.state = .failed(error.localizedDescription)
                appendLog("VOD 소스 URL 가져오기 실패: \(error.localizedDescription)")
            }
        }
        return true
    }

    func startVOD(_ item: VODItem) {
        switch item.state {
        case .fetching, .downloading:
            showToast("이미 처리 중인 VOD입니다")
            return
        case .ready, .paused, .completed, .failed, .canceled:
            break
        }

        let preferredQuality = item.selectedQuality
        let audioOnly = item.audioOnly
        let clipStart = item.clipStart
        let clipEnd = item.clipEnd
        let cookies = config.cookies

        item.state = .fetching
        item.percent = 0
        item.sizeText = "N/A"
        item.speedText = "N/A"
        item.outTime = "00:00:00"

        Task {
            do {
                if item.importedSource {
                    guard let variant = item.variants.first(where: { $0.quality == preferredQuality }) ?? item.variants.last else {
                        item.state = .failed("가져온 소스에서 다운로드 가능한 항목을 찾지 못했습니다.")
                        return
                    }
                    item.selectedQuality = variant.quality
                    item.audioOnly = audioOnly
                    item.clipStart = clipStart
                    item.clipEnd = clipEnd
                    startResolvedVOD(item, variant: variant)
                    return
                }
                // Re-resolve at the moment the download starts so old in-memory
                // HLS variants do not keep routing normal VODs through ffmpeg.
                let (meta, variants) = try await ChzzkVODAPI.resolve(urlString: item.url, cookies: cookies)
                guard let variant = variants.first(where: { $0.quality == preferredQuality }) ?? variants.last else {
                    item.state = .failed("해당 화질을 찾을 수 없습니다.")
                    return
                }
                item.title = meta.title
                item.channelName = meta.channelName
                item.durationSeconds = meta.duration
                item.variants = variants
                item.selectedQuality = variant.quality
                item.audioOnly = audioOnly
                item.clipStart = clipStart
                item.clipEnd = clipEnd
                startResolvedVOD(item, variant: variant)
            } catch {
                item.state = .failed(error.localizedDescription)
                handleCookieAuthFailureIfNeeded(error, context: "VOD 정보 갱신")
                appendLog("VOD 정보 갱신 실패: \(error.localizedDescription)")
            }
        }
    }

    private func startResolvedVOD(_ item: VODItem, variant: VODVariant) {
        let strategy = VODDownloader.strategy(
            variant: variant, audioOnly: item.audioOnly,
            clipStart: item.clipStart, clipEnd: item.clipEnd,
            useNativeMux: config.use_native_engine)
        // Only segment-prefetch downloads keep partial data across a pause; everything
        // else (direct MP4, ffmpeg remote seek) would restart, so don't offer pause.
        item.supportsPause = (strategy == .hlsSegmentPrefetch || strategy == .dashSegmentPrefetch)
        // ffmpeg is required for segment prefetch and local postprocess modes.
        if strategy != .parallel && ffmpegPath == nil {
            ensureTools(needStreamlink: false)
            item.state = .failed("ffmpeg가 필요합니다.")
            return
        }
        let dir = URL(fileURLWithPath: vodOutputDir)
        let clipSuffix = clipRangeSuffix(start: item.clipStart, end: item.clipEnd)
        let outURL = VODDownloader.makeOutputURL(
            channelName: item.channelName, title: item.title, quality: variant.quality, dir: dir,
            ext: item.audioOnly ? "m4a" : "mp4", suffix: clipSuffix)
        let record = DownloadRecord(
            vodURL: item.url, title: item.title, channelName: item.channelName,
            quality: variant.quality, isHLS: variant.isHLS, duration: item.durationSeconds,
            finalPath: outURL.path, totalSize: 0, fileSize: 0,
            status: .downloading, createdAt: Date(), updatedAt: Date(),
            clipStart: item.clipStart, clipEnd: item.clipEnd)
        item.recordID = record.id
        upsertRecord(record)
        appendLog("VOD 다운로드 시작: \(item.title) (\(variant.label), \(downloadModeLabel(item: item, variant: variant)))")
        runDownload(item: item, variant: variant, outURL: outURL)
    }

    /// Parses a formatted speed like "5.2 MB/s" / "850 KB/s" into bytes/sec.
    /// Returns 0 for non-rate strings (e.g. during the combine phase), which makes
    /// the gallop animation stand still.
    static func parseSpeedToBytesPerSec(_ text: String) -> Double {
        guard let range = text.range(of: #"[0-9]+(\.[0-9]+)?\s*(GB|MB|KB|B)/s"#,
                                     options: .regularExpression) else { return 0 }
        let token = String(text[range])
        let number = Double(token.prefix { $0.isNumber || $0 == "." }) ?? 0
        if token.contains("GB") { return number * 1_073_741_824 }
        if token.contains("MB") { return number * 1_048_576 }
        if token.contains("KB") { return number * 1024 }
        return number
    }

    private func downloadModeLabel(item: VODItem, variant: VODVariant) -> String {
        let nativeFull = config.use_native_engine && !item.hasClip && !item.audioOnly
        if variant.requiresRemoteHLS {
            if nativeFull { return "권한 HLS 내장(복호화+병렬)" }
            return item.hasClip ? "권한 HLS 구간 ffmpeg" : "권한 HLS ffmpeg"
        }
        if variant.isHLS {
            if nativeFull { return "HLS 병렬+내장 mux" }
            return item.hasClip ? "HLS 구간 세그먼트+로컬처리" : "HLS 병렬+로컬처리"
        }
        if variant.hasSegmentParts {
            if nativeFull { return "DASH 파트+내장 mux" }
            return item.hasClip ? "DASH 구간 파트+로컬처리" : "DASH 파트+로컬처리"
        }
        if item.hasClip { return "구간 병렬 range+로컬처리" }
        if item.audioOnly { return "병렬+로컬처리" }
        return "병렬"
    }

    private func runDownload(item: VODItem, variant: VODVariant, outURL: URL) {
        item.resumeVariant = variant
        item.resumeOutURL = outURL
        item.state = .downloading
        item.percent = 0
        item.sizeText = "다운로드 준비 중…"
        item.speedText = ""
        item.outTime = ""
        refreshActivityAssertion()
        let audioOnly = outURL.pathExtension.lowercased() == "m4a"
        let rate = vodSpeedLimitMBps > 0 ? vodSpeedLimitMBps * 1_048_576 : 0
        vodDownloader.start(
            item: item, variant: variant, ffmpegPath: ffmpegPath ?? "",
            cookies: config.cookies, outURL: outURL, connections: vodConnections,
            audioOnly: audioOnly, rateLimit: rate,
            useNativeMux: config.use_native_engine,
            clipStart: item.clipStart, clipEnd: item.clipEnd,
            onProgress: { [weak item] pct, size, speed, outTime in
                Task { @MainActor in
                    guard let item else { return }
                    item.percent = pct; item.sizeText = size
                    item.speedText = speed; item.outTime = outTime
                    item.bytesPerSecond = AppModel.parseSpeedToBytesPerSec(speed)
                }
            },
            onFinish: { [weak self, weak item] state, path in
                Task { @MainActor in
                    guard let self, let item else { return }
                    item.state = state
                    item.outputPath = path
                    if case .completed = state {
                        item.percent = 1; self.appendLog("VOD 저장 완료: \(path ?? "")")
                        if self.config.notify_on_complete {
                            Notifier.notify(title: "다운로드 완료", body: item.title, filePath: path)
                        }
                        WebhookNotifier.send(self.config.notify_webhook_url, "⬇️ 다운로드 완료: \(item.title)")
                    }
                    self.finishRecord(item: item, state: state, path: path)
                    if case .failed(let m) = state {
                        self.handleCookieAuthFailureIfNeeded(m, context: "VOD 다운로드")
                        self.appendLog("VOD 다운로드 실패: \(m)")
                    }
                    self.refreshActivityAssertion()
                }
            })
    }

    func cancelVOD(_ item: VODItem) {
        vodDownloader.cancel(item: item)
    }

    func pauseVOD(_ item: VODItem) {
        guard case .downloading = item.state, item.supportsPause else { return }
        item.state = .paused
        item.speedText = ""
        item.bytesPerSecond = 0
        vodDownloader.pause(item: item)
    }

    func resumeVOD(_ item: VODItem) {
        guard case .paused = item.state else { return }
        if let variant = item.resumeVariant, let outURL = item.resumeOutURL {
            runDownload(item: item, variant: variant, outURL: outURL)
        } else {
            startVOD(item)
        }
    }

    func removeVOD(_ item: VODItem) {
        vodDownloader.cancel(item: item)
        vodItems.removeAll { $0.id == item.id }
    }

    /// Filename-safe clip duration suffix, e.g. " (37s)".
    private func clipRangeSuffix(start: Double?, end: Double?) -> String {
        guard let start, let end, end > start else { return "" }
        let seconds = Int(max(1, ceil(end - start)))
        return " (\(seconds)s)"
    }

    // MARK: download history

    func retryRecord(_ record: DownloadRecord) {
        // Avoid two overlapping runs writing the same temp/output file.
        if vodItems.contains(where: { $0.recordID == record.id && Self.isWorkingVOD($0) }) {
            showToast("이미 다시 받는 중입니다")
            return
        }
        record.removeTemporaryArtifacts()
        let item = VODItem(url: record.vodURL)
        item.recordID = record.id
        item.title = record.title
        item.channelName = record.channelName
        item.durationSeconds = record.duration
        item.clipStart = record.clipStart
        item.clipEnd = record.clipEnd
        item.state = .fetching
        vodItems.insert(item, at: 0)
        appendLog("다시 받기: \(record.title)")
        let cookies = config.cookies
        Task {
            do {
                let variants: [VODVariant]
                if VODSourceImporter.isSupportedSourceURL(record.vodURL) {
                    let imported = try await VODSourceImporter.importURLString(record.vodURL)
                    item.importedSource = true
                    item.title = imported.title
                    item.channelName = imported.channelName
                    item.durationSeconds = imported.duration
                    variants = imported.variants
                } else {
                    // Re-resolve to get a fresh media URL because CDN tokens expire.
                    let resolved = try await ChzzkVODAPI.resolve(urlString: record.vodURL, cookies: cookies)
                    variants = resolved.1
                }
                guard let variant = variants.first(where: { $0.quality == record.quality }) ?? variants.last else {
                    item.state = .failed("해당 화질을 찾을 수 없습니다."); return
                }
                item.variants = variants
                item.selectedQuality = variant.quality
                let existingOutURL = URL(fileURLWithPath: record.finalPath)
                let audioOnly = existingOutURL.pathExtension.lowercased() == "m4a"
                item.audioOnly = audioOnly
                let outURL: URL
                if existingOutURL.lastPathComponent.utf8.count > Filename.maxFinalComponentBytes {
                    outURL = VODDownloader.makeOutputURL(
                        channelName: record.channelName, title: record.title, quality: variant.quality,
                        dir: existingOutURL.deletingLastPathComponent(),
                        ext: audioOnly ? "m4a" : (existingOutURL.pathExtension.isEmpty ? "mp4" : existingOutURL.pathExtension),
                        suffix: clipRangeSuffix(start: record.clipStart, end: record.clipEnd))
                } else {
                    outURL = existingOutURL
                }
                if (variant.isHLS || audioOnly || item.hasClip) && ffmpegPath == nil {
                    ensureTools(needStreamlink: false)
                    item.state = .failed("ffmpeg가 필요합니다.")
                    return
                }
                if let i = downloadRecords.firstIndex(where: { $0.id == record.id }) {
                    downloadRecords[i].quality = variant.quality
                    downloadRecords[i].isHLS = variant.isHLS
                    downloadRecords[i].finalPath = outURL.path
                    downloadRecords[i].status = .downloading
                    downloadRecords[i].updatedAt = Date()
                    DownloadStore.save(downloadRecords)
                } else {
                    updateRecordStatus(record.id, .downloading)
                }
                appendLog("다시 받기 시작: \(record.title) (\(variant.label), \(downloadModeLabel(item: item, variant: variant)))")
                runDownload(item: item, variant: variant, outURL: outURL)
            } catch {
                item.state = .failed(error.localizedDescription)
                handleCookieAuthFailureIfNeeded(error, context: "다시 받기")
                appendLog("다시 받기 실패: \(error.localizedDescription)")
            }
        }
    }

    func deleteRecord(_ record: DownloadRecord) {
        // Remove partial artifacts; keep completed files on disk.
        record.removeTemporaryArtifacts()
        downloadRecords.removeAll { $0.id == record.id }
        DownloadStore.save(downloadRecords)
    }

    private func upsertRecord(_ record: DownloadRecord) {
        if let i = downloadRecords.firstIndex(where: { $0.id == record.id }) {
            downloadRecords[i] = record
        } else {
            downloadRecords.insert(record, at: 0)
        }
        DownloadStore.save(downloadRecords)
    }

    private func updateRecordStatus(_ id: UUID, _ status: DownloadStatus) {
        guard let i = downloadRecords.firstIndex(where: { $0.id == id }) else { return }
        downloadRecords[i].status = status
        downloadRecords[i].updatedAt = Date()
        DownloadStore.save(downloadRecords)
    }

    private func finishRecord(item: VODItem, state: VODState, path: String?) {
        guard let rid = item.recordID,
              let i = downloadRecords.firstIndex(where: { $0.id == rid }) else { return }
        switch state {
        case .completed:
            downloadRecords[i].status = .completed
            downloadRecords[i].fileSize =
                ((try? FileManager.default.attributesOfItem(atPath: path ?? "")[.size]) as? Int) ?? 0
        case .canceled:
            downloadRecords.remove(at: i)
            DownloadStore.save(downloadRecords)
            return
        case .failed:
            downloadRecords[i].status = .failed
            downloadRecords[i].removeTemporaryArtifacts()
        default:
            return
        }
        downloadRecords[i].updatedAt = Date()
        DownloadStore.save(downloadRecords)
    }
}
