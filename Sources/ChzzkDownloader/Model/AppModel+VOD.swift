import Foundation

// MARK: - VOD downloads and download history

extension AppModel {

    // MARK: VOD download

    @discardableResult
    func addVOD(urlString: String) -> Bool {
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
            } catch {
                item.state = .failed(error.localizedDescription)
                handleCookieAuthFailureIfNeeded(error, context: "VOD 정보 조회")
                appendLog("VOD 정보 조회 실패: \(error.localizedDescription)")
            }
        }
        return true
    }

    func startVOD(_ item: VODItem) {
        switch item.state {
        case .fetching, .downloading:
            showToast("이미 처리 중인 VOD입니다")
            return
        case .ready, .completed, .failed, .canceled:
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
            clipStart: item.clipStart, clipEnd: item.clipEnd)
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

    private func downloadModeLabel(item: VODItem, variant: VODVariant) -> String {
        if variant.isHLS { return item.hasClip ? "HLS 구간 세그먼트+로컬처리" : "HLS 병렬+로컬처리" }
        if variant.hasSegmentParts { return item.hasClip ? "DASH 구간 파트+로컬처리" : "DASH 파트+로컬처리" }
        if item.hasClip { return "구간 병렬 range+로컬처리" }
        if item.audioOnly { return "병렬+로컬처리" }
        return "병렬"
    }

    private func runDownload(item: VODItem, variant: VODVariant, outURL: URL) {
        item.state = .downloading
        item.percent = 0
        item.sizeText = "다운로드 준비중…"
        item.speedText = ""
        item.outTime = ""
        refreshActivityAssertion()
        let audioOnly = outURL.pathExtension.lowercased() == "m4a"
        let rate = vodSpeedLimitMBps > 0 ? vodSpeedLimitMBps * 1_048_576 : 0
        vodDownloader.start(
            item: item, variant: variant, ffmpegPath: ffmpegPath ?? "",
            cookies: config.cookies, outURL: outURL, connections: vodConnections,
            audioOnly: audioOnly, rateLimit: rate,
            clipStart: item.clipStart, clipEnd: item.clipEnd,
            onProgress: { [weak item] pct, size, speed, outTime in
                Task { @MainActor in
                    guard let item else { return }
                    item.percent = pct; item.sizeText = size
                    item.speedText = speed; item.outTime = outTime
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
                // Re-resolve to get a fresh media URL because CDN tokens expire.
                let (_, variants) = try await ChzzkVODAPI.resolve(urlString: record.vodURL, cookies: cookies)
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
