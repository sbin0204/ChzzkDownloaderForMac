import XCTest
@testable import ChzzkDownloader

final class CoreLogicTests: XCTestCase {
    override func tearDown() {
        ProxySupport.current = ""
        super.tearDown()
    }

    func testVODURLParsingAcceptsSupportedChzzkURLs() {
        let video = ChzzkVODAPI.parseURL("https://chzzk.naver.com/video/123_ABC-def")
        XCTAssertEqual(video?.type, "video")
        XCTAssertEqual(video?.no, "123_ABC-def")

        let clip = ChzzkVODAPI.parseURL("chzzk.naver.com/clips/clip_123")
        XCTAssertEqual(clip?.type, "clips")
        XCTAssertEqual(clip?.no, "clip_123")
    }

    func testVODURLParsingRejectsUnsafeOrOversizedInput() {
        XCTAssertNil(ChzzkVODAPI.parseURL("https://example.com/video/123"))
        XCTAssertNil(ChzzkVODAPI.parseURL("https://chzzk.naver.com/live/123"))
        XCTAssertNil(ChzzkVODAPI.parseURL("https://chzzk.naver.com/video/한글"))
        XCTAssertNil(ChzzkVODAPI.parseURL("https://chzzk.naver.com/video/123\nhttps://example.com"))
        XCTAssertNil(ChzzkVODAPI.parseURL(String(repeating: "a", count: ChzzkVODAPI.maxPageURLLength + 1)))
    }

    func testVODListRemovalIsHiddenOnlyWhileDownloading() {
        XCTAssertTrue(VODState.fetching.canRemoveFromVODList)
        XCTAssertTrue(VODState.ready.canRemoveFromVODList)
        XCTAssertFalse(VODState.downloading.canRemoveFromVODList)
        XCTAssertTrue(VODState.completed.canRemoveFromVODList)
        XCTAssertTrue(VODState.failed("error").canRemoveFromVODList)
        XCTAssertTrue(VODState.canceled.canRemoveFromVODList)
    }

    func testFilenameShorteningKeepsComponentsBelowByteLimits() {
        let longName = String(repeating: "very-long-title-", count: 20) + "segment.mp4"
        let shortened = Filename.shortenedComponent(longName)

        XCTAssertLessThanOrEqual(shortened.utf8.count, Filename.maxFinalComponentBytes)
        XCTAssertTrue(shortened.hasSuffix(".mp4"))
        XCTAssertTrue(shortened.contains("_"))
    }

    func testTemporaryFilenameIsShortAndHidden() {
        let finalURL = URL(fileURLWithPath: "/tmp/" + String(repeating: "download-", count: 30) + ".mp4")
        let temporary = Filename.temporaryURL(for: finalURL, suffix: ".segments")

        XCTAssertLessThanOrEqual(temporary.lastPathComponent.utf8.count, Filename.maxTemporaryComponentBytes)
        XCTAssertTrue(temporary.lastPathComponent.hasPrefix(".cvd-"))
    }

    func testMigrateLegacyTemporaryMovesOldPartFileToHiddenPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let finalURL = directory.appendingPathComponent("video.mp4")
        let legacy = Filename.legacyTemporaryURL(for: finalURL, suffix: ".part")
        try Data("partial".utf8).write(to: legacy)

        let migrated = Filename.migrateLegacyTemporary(for: finalURL, suffix: ".part")

        XCTAssertEqual(migrated, Filename.temporaryURL(for: finalURL, suffix: ".part"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(migrated.lastPathComponent.hasPrefix(".cvd-"))
    }

    func testRemoveTemporaryDeletesCurrentLegacyAndPreviousVisibleFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let finalURL = directory.appendingPathComponent("video.mp4")
        let current = Filename.temporaryURL(for: finalURL, suffix: ".part")
        let legacy = Filename.legacyTemporaryURL(for: finalURL, suffix: ".part")
        let previousVisible = current
            .deletingLastPathComponent()
            .appendingPathComponent(String(current.lastPathComponent.dropFirst()))

        try Data("current".utf8).write(to: current)
        try Data("legacy".utf8).write(to: legacy)
        try Data("visible".utf8).write(to: previousVisible)

        Filename.removeTemporary(for: finalURL, suffix: ".part")

        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousVisible.path))
    }

    func testConfigNormalizeClampsAndSanitizesValues() {
        var config = Config()
        config.timeout = -1
        config.stream_segment_threads = 999
        config.output_format = ".bad"
        config.live_split_size_mb = -100
        config.live_split_duration_minutes = 999_999
        config.cyclic_max_files = -10
        config.cyclic_max_size_gb = 9_999_999
        config.notify_webhook_url = " http://example.com/webhook "
        config.hevc_settings.bitrate = "0"
        config.hevc_settings.max_bitrate = "0k"
        config.cookies = Cookies(NID_SES: " ses;\u{0000}value ", NID_AUT: " aut;\u{0007}value ")
        config.channels = [
            Channel(id: "valid_id", name: " Valid\u{0000} Name ", output_dir: "  ", quality: "720p"),
            Channel(id: "bad id", name: "Bad", output_dir: "/tmp", quality: "best")
        ]

        config.normalize()

        XCTAssertEqual(config.timeout, Defaults.minRescanInterval)
        XCTAssertEqual(config.stream_segment_threads, Defaults.maxThreads)
        XCTAssertEqual(config.output_format, Defaults.outputFormat)
        XCTAssertEqual(config.live_split_size_mb, Defaults.minSplitSizeMB)
        XCTAssertEqual(config.live_split_duration_minutes, Defaults.maxSplitDurationMinutes)
        XCTAssertEqual(config.cyclic_max_files, 0)
        XCTAssertEqual(config.cyclic_max_size_gb, 1_000_000)
        XCTAssertEqual(config.notify_webhook_url, "")
        XCTAssertEqual(config.hevc_settings.bitrate, "2500k")
        XCTAssertEqual(config.hevc_settings.max_bitrate, "10000k")
        XCTAssertEqual(config.channels.count, 1)
        XCTAssertEqual(config.channels[0].id, "valid_id")
        XCTAssertEqual(config.channels[0].name, "Valid Name")
        XCTAssertEqual(config.channels[0].output_dir, ".")
        XCTAssertEqual(config.channels[0].quality, "720p")
        XCTAssertEqual(config.cookies.NID_SES, "sesvalue")
        XCTAssertEqual(config.cookies.NID_AUT, "autvalue")
    }

    func testConfigDecodingKeepsDefaultsForMissingKeys() throws {
        let json = """
        {
          "channels": [],
          "cookies": { "NID_SES": "ses", "NID_AUT": "aut" }
        }
        """

        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertEqual(config.timeout, Defaults.rescanInterval)
        XCTAssertEqual(config.stream_segment_threads, Defaults.defaultThreads)
        XCTAssertEqual(config.output_format, Defaults.outputFormat)
        XCTAssertFalse(config.auto_import_cookies_on_launch)
        XCTAssertEqual(config.cookies.NID_SES, "ses")
        XCTAssertEqual(config.cookies.NID_AUT, "aut")
    }

    func testRecordingOutputDirectoryNormalization() {
        XCTAssertEqual(Validate.normalizeRecordingOutputDir("  \n\t"), ".")
        XCTAssertEqual(
            Validate.normalizeRecordingOutputDir(" /Volumes/T5 EVO/Recordings\n"),
            "/Volumes/T5 EVO/Recordings")

        let expanded = Validate.normalizeRecordingOutputDir("~/Movies/ChzzkDownloader")
        XCTAssertTrue(expanded.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertTrue(expanded.hasSuffix("/Movies/ChzzkDownloader"))
    }

    func testArmedRecordingNudgeRequiresLiveArmedAndNotWriting() {
        XCTAssertTrue(AppModel.shouldNudgeArmedRecording(isLive: true, isArmed: true, isWriting: false))
        XCTAssertFalse(AppModel.shouldNudgeArmedRecording(isLive: false, isArmed: true, isWriting: false))
        XCTAssertFalse(AppModel.shouldNudgeArmedRecording(isLive: true, isArmed: false, isWriting: false))
        XCTAssertFalse(AppModel.shouldNudgeArmedRecording(isLive: true, isArmed: true, isWriting: true))
        XCTAssertFalse(AppModel.shouldNudgeArmedRecording(
            isLive: true, isArmed: true, isWriting: false, canRecord: false))
    }

    func testAuthFailureHeuristicAvoidsFalsePositivesFromURLsAndSizes() {
        // Real auth failures.
        XCTAssertTrue(ChzzkAPI.looksLikeAuthFailure("Unable to open URL: ... (401 Client Error: Unauthorized)"))
        XCTAssertTrue(ChzzkAPI.looksLikeAuthFailure("HTTP 403 Forbidden"))
        XCTAssertTrue(ChzzkAPI.looksLikeAuthFailure("ADULT_AUTH_REQUIRED"))
        XCTAssertTrue(ChzzkAPI.looksLikeAuthFailure("invalid cookie value"))

        // Lines that merely contain cookie/digit substrings must not trigger.
        XCTAssertFalse(ChzzkAPI.looksLikeAuthFailure("Opening stream with --http-cookie header"))
        XCTAssertFalse(ChzzkAPI.looksLikeAuthFailure("쿠키 설정을 적용했습니다"))
        XCTAssertFalse(ChzzkAPI.looksLikeAuthFailure("downloaded 14013 bytes"))
        XCTAssertFalse(ChzzkAPI.looksLikeAuthFailure("segment https://cdn.example.com/x401y/seg.ts"))
        XCTAssertFalse(ChzzkAPI.looksLikeAuthFailure("로그인 화면을 건너뜁니다"))
    }

    func testSalvageOrphanPartsRecoversCrashLeftovers() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let orphan = dir.appendingPathComponent("[2026-06-10 12_00_00] ch title.ts.part")
        let collision = dir.appendingPathComponent("[2026-06-10 12_00_00] ch title.ts")
        let unrelated = dir.appendingPathComponent("note.part")   // no "[" prefix -> untouched
        try Data("a".utf8).write(to: orphan)
        try Data("b".utf8).write(to: collision)
        try Data("c".utf8).write(to: unrelated)

        let salvaged = RecordingEngine.salvageOrphanParts(outputDirs: [dir.path])

        XCTAssertEqual(salvaged.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        // Existing final file is preserved; the orphan gets a unique "_1" name.
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "b")
        XCTAssertTrue(salvaged[0].contains("_1"))
    }

    func testTagFilterParsingTrimsDedupesAndCaps() {
        let parsed = Validate.parseTagFilter("  종합게임 , 저챗,종합게임 ,  ,저챗 ")
        XCTAssertEqual(parsed, ["종합게임", "저챗"])

        let many = (1...50).map { "tag\($0)" }.joined(separator: ",")
        XCTAssertEqual(Validate.parseTagFilter(many).count, Validate.maxTagFilterCount)

        let long = String(repeating: "가", count: 100)
        let normalized = Validate.parseTagFilter(long)
        XCTAssertEqual(normalized.first?.count, Validate.maxTagLength)
    }

    func testChannelAcceptsTagsMatchesCaseInsensitivelyAndAllowsEmptyFilter() {
        let noFilter = Channel(id: "c1", name: "n", output_dir: ".", tag_filter: [])
        XCTAssertTrue(noFilter.acceptsTags([]))
        XCTAssertTrue(noFilter.acceptsTags(["아무거나"]))

        let filtered = Channel(id: "c2", name: "n", output_dir: ".", tag_filter: ["저챗", "ASMR"])
        XCTAssertTrue(filtered.acceptsTags(["저챗", "게임"]))
        XCTAssertTrue(filtered.acceptsTags(["asmr"]))             // case-insensitive
        XCTAssertFalse(filtered.acceptsTags(["게임", "노래"]))
        XCTAssertFalse(filtered.acceptsTags([]))                  // no tags can't match a filter
    }

    func testStopOnTagMismatchRequiresOptionFilterAndActualMismatch() {
        let optionOff = Channel(id: "c", name: "n", output_dir: ".", tag_filter: ["asmr"])
        XCTAssertFalse(optionOff.shouldStopOnTagMismatch(["게임"]))

        let optionOn = Channel(id: "c", name: "n", output_dir: ".",
                               tag_filter: ["asmr"], stop_on_tag_mismatch: true)
        XCTAssertTrue(optionOn.shouldStopOnTagMismatch(["게임"]))         // mismatch -> stop
        XCTAssertTrue(optionOn.shouldStopOnTagMismatch([]))               // tags removed -> stop
        XCTAssertFalse(optionOn.shouldStopOnTagMismatch(["ASMR", "게임"])) // still matches -> keep

        let noFilter = Channel(id: "c", name: "n", output_dir: ".",
                               tag_filter: [], stop_on_tag_mismatch: true)
        XCTAssertFalse(noFilter.shouldStopOnTagMismatch(["게임"]))         // option inert without filter
    }

    func testNormalizeDropsArmedChannelsWithoutAMatchingChannel() {
        var config = Config()
        config.channels = [Channel(id: "live1", name: "n", output_dir: ".")]
        config.armed_channels = ["live1", "ghost", "live1"]   // unknown + duplicate
        config.normalize()
        XCTAssertEqual(config.armed_channels, ["live1"])
    }

    func testCookieRefreshUsesMonthlyFirstDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let may31 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 31, hour: 23)))
        let june1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 1)))
        let june15 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)))
        let june30 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 12)))

        XCTAssertTrue(AppModel.cookieNeedsMonthlyRefresh(
            updatedAt: may31, now: june1, calendar: calendar))
        XCTAssertFalse(AppModel.cookieNeedsMonthlyRefresh(
            updatedAt: june1, now: june15, calendar: calendar))
        XCTAssertTrue(AppModel.cookieNeedsMonthlyRefresh(
            updatedAt: nil, now: june15, calendar: calendar))
        XCTAssertEqual(AppModel.daysUntilNextCookieRefreshMonth(now: june30, calendar: calendar), 1)
    }

    func testVODDownloadSettingsNormalizeUnsafeValues() {
        XCTAssertEqual(Validate.normalizeVODConnections(-5), Defaults.minVODConnections)
        XCTAssertEqual(Validate.normalizeVODConnections(0), Defaults.minVODConnections)
        XCTAssertEqual(Validate.normalizeVODConnections(8), 8)
        XCTAssertEqual(Validate.normalizeVODConnections(999), Defaults.maxVODConnections)

        XCTAssertEqual(Validate.normalizeVODSpeedLimitMBps(-1), Defaults.minVODSpeedLimitMBps)
        XCTAssertEqual(Validate.normalizeVODSpeedLimitMBps(12.5), 12.5)
        XCTAssertEqual(Validate.normalizeVODSpeedLimitMBps(.infinity), Defaults.minVODSpeedLimitMBps)
        XCTAssertEqual(
            Validate.normalizeVODSpeedLimitMBps(Defaults.maxVODSpeedLimitMBps * 2),
            Defaults.maxVODSpeedLimitMBps)
    }

    func testWebhookURLValidationAndRequestBuilding() throws {
        XCTAssertEqual(Validate.normalizeWebhookURL(" http://example.com/hook "), "")
        XCTAssertEqual(Validate.normalizeWebhookURL("file:///tmp/hook"), "")
        XCTAssertEqual(
            Validate.normalizeWebhookURL(" https://example.com/hook "),
            "https://example.com/hook")

        XCTAssertNil(WebhookNotifier.makeRequest(urlString: "http://example.com/hook", message: "hi"))

        let generic = try XCTUnwrap(
            WebhookNotifier.makeRequest(urlString: "https://example.com/hook", message: "hi"))
        XCTAssertEqual(generic.httpMethod, "POST")
        XCTAssertEqual(generic.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(generic.httpBody)

        let telegram = try XCTUnwrap(WebhookNotifier.makeRequest(
            urlString: "https://api.telegram.org/botSECRET/sendMessage?chat_id=123",
            message: "hello world"))
        XCTAssertEqual(telegram.httpMethod, "GET")
        let components = try XCTUnwrap(URLComponents(url: telegram.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "chat_id" })?.value, "123")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "text" })?.value, "hello world")
    }

    func testCyclicRecordingFindsSanitizedChannelFinishedFilesOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelName = "A/B:채널"
        let safeChannel = Validate.sanitizeFilename(channelName, fallback: "channel")
        let first = directory.appendingPathComponent("[2026-06-01 10_00_00] \(safeChannel) one.ts")
        let second = directory.appendingPathComponent("[2026-06-01 11_00_00] \(safeChannel) two.ts")
        let temp = directory.appendingPathComponent("[2026-06-01 12_00_00] \(safeChannel) temp.ts.part")
        let sidecar = directory.appendingPathComponent("[2026-06-01 12_00_00] \(safeChannel) temp.ts.cvdresume")
        let other = directory.appendingPathComponent("[2026-06-01 09_00_00] Other Channel show.ts")
        let noStamp = directory.appendingPathComponent("\(safeChannel) no timestamp.ts")

        try writeTestFile(first, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 10))
        try writeTestFile(second, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 20))
        try writeTestFile(temp, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 30))
        try writeTestFile(sidecar, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 40))
        try writeTestFile(other, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 5))
        try writeTestFile(noStamp, bytes: 10, modifiedAt: Date(timeIntervalSince1970: 1))

        let names = CyclicRecording.recordingCandidates(in: directory, channelName: channelName)
            .map { $0.url.lastPathComponent }

        XCTAssertEqual(names, [first.lastPathComponent, second.lastPathComponent])
    }

    func testCyclicRecordingTrashCandidatesKeepProtectedSavedFile() {
        let directory = URL(fileURLWithPath: "/tmp")
        let protected = CyclicRecording.Candidate(
            url: directory.appendingPathComponent("[2026-06-01 10_00_00] Channel current.ts"),
            date: Date(timeIntervalSince1970: 1),
            size: 600 * 1_024 * 1_024)
        let nextOldest = CyclicRecording.Candidate(
            url: directory.appendingPathComponent("[2026-06-01 11_00_00] Channel old.ts"),
            date: Date(timeIntervalSince1970: 2),
            size: 600 * 1_024 * 1_024)
        let newest = CyclicRecording.Candidate(
            url: directory.appendingPathComponent("[2026-06-01 12_00_00] Channel new.ts"),
            date: Date(timeIntervalSince1970: 3),
            size: 100 * 1_024 * 1_024)

        let byCount = CyclicRecording.trashCandidates(
            from: [protected, nextOldest, newest],
            protectedPath: protected.url.path,
            maxFiles: 2,
            maxSizeGB: 0)
        XCTAssertEqual(byCount.map(\.url), [nextOldest.url])

        let bySize = CyclicRecording.trashCandidates(
            from: [protected, nextOldest, newest],
            protectedPath: protected.url.path,
            maxFiles: 0,
            maxSizeGB: 1)
        XCTAssertEqual(bySize.map(\.url), [nextOldest.url])
    }

    func testBundledSupportDocumentsLoadDuringDevelopment() {
        let changelog = BundledSupportDocument.read(.changelog)
        let notices = BundledSupportDocument.read(.thirdPartyNotices)
        let license = BundledSupportDocument.read(.license)
        let updateGuide = BundledSupportDocument.read(.githubUpdates)

        XCTAssertTrue(changelog?.contains("# Changelog") == true)
        XCTAssertTrue(notices?.contains("# 오픈소스 고지") == true)
        XCTAssertTrue(license?.contains("GNU GENERAL PUBLIC LICENSE") == true)
        XCTAssertTrue(updateGuide?.contains("Sparkle") == true)
    }

    func testReleaseMetadataMatchesMaintainedSourceFiles() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("release.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let metadata = try XCTUnwrap(json as? [String: Any])

        let version = try XCTUnwrap(metadata["version"] as? [String: String])
        let legal = try XCTUnwrap(metadata["legal"] as? [String: String])
        let docs = try XCTUnwrap(metadata["supportDocuments"] as? [[String: String]])

        let heading = try XCTUnwrap(version["changelogHeading"])
        let changelogPath = try XCTUnwrap(legal["changelogFile"])
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let changelog = try String(contentsOf: root.appendingPathComponent(changelogPath), encoding: .utf8)
        XCTAssertTrue(changelog.contains("## \(heading)"))

        for key in ["licenseFile", "thirdPartyNoticesFile", "changelogFile"] {
            let path = try XCTUnwrap(legal[key])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        }
        for doc in docs {
            let source = try XCTUnwrap(doc["source"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source), source)
            XCTAssertFalse((doc["dmgName"] ?? "").isEmpty)
        }
    }

    func testProgressParserFormatsTimeSizeAndUpdates() {
        XCTAssertEqual(ProgressParser.parseTime("01:02:03.500"), 3723.5, accuracy: 0.0001)
        XCTAssertEqual(ProgressParser.formatSize(1024), "1.00 KB")

        let parser = ProgressParser(channelID: "cid", channelName: "Channel", startTime: "start")
        var progress: ChannelProgress?
        parser.onUpdate = { progress = $0 }

        parser.feed("total_size=2048")
        parser.feed("out_time=00:00:02.000")
        parser.feed("progress=continue")

        XCTAssertEqual(progress?.id, "cid")
        XCTAssertEqual(progress?.channelName, "Channel")
        XCTAssertEqual(progress?.totalSize, "2.00 KB")
        XCTAssertEqual(progress?.outTime, "00:00:02.000")
        XCTAssertEqual(progress?.bitrate, "8.19 kbps")
    }

    func testProxyArgsNormalizeBareHostAndSkipSocksForFFmpeg() {
        ProxySupport.current = "localhost:8080"
        XCTAssertEqual(ProxySupport.streamlinkArgs(), ["--http-proxy", "http://localhost:8080"])
        XCTAssertEqual(ProxySupport.ffmpegArgs(), ["-http_proxy", "http://localhost:8080"])

        ProxySupport.current = "socks5://localhost:1080"
        XCTAssertEqual(ProxySupport.streamlinkArgs(), ["--http-proxy", "socks5://localhost:1080"])
        XCTAssertEqual(ProxySupport.ffmpegArgs(), [])
    }

    func testProxyPortInputKeepsOnlyValidPortRange() {
        XCTAssertEqual(Validate.normalizePortInput("8080"), "8080")
        XCTAssertEqual(Validate.normalizePortInput(" 80 "), "80")
        XCTAssertEqual(Validate.normalizePortInput("port:8080"), "8080")
        XCTAssertEqual(Validate.normalizePortInput("0"), "1")
        XCTAssertEqual(Validate.normalizePortInput("999999"), "65535")
        XCTAssertEqual(Validate.normalizePortInput("abc"), "")
    }

    func testFFmpegBufsizeUnderstandsMegabitBitrates() {
        XCTAssertEqual(FFmpegArgs.bitrateKbps("5000k"), 5000)
        XCTAssertEqual(FFmpegArgs.bitrateKbps("5m"), 5000)
        XCTAssertEqual(FFmpegArgs.calculateBufsize("5m"), "10000k")
        XCTAssertEqual(FFmpegArgs.calculateBufsize("0m"), "16000k")
        XCTAssertEqual(FFmpegArgs.calculateBufsize("bad"), "16000k")
    }

    func testUpdateServiceRequiresHTTPSFeedURL() {
        XCTAssertTrue(UpdateService.isUsableFeedURL(URL(string: "https://example.com/appcast.xml")!))
        XCTAssertFalse(UpdateService.isUsableFeedURL(URL(string: "http://example.com/appcast.xml")!))
        XCTAssertFalse(UpdateService.isUsableFeedURL(URL(string: "file:///tmp/appcast.xml")!))
        XCTAssertFalse(UpdateService.isUsableFeedURL(URL(string: "https:///appcast.xml")!))
    }

    func testLocalizationResourcesAndGitHubUpdateGuideAreBundled() throws {
        let enStrings = try XCTUnwrap(Bundle.module.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: "en"))
        let data = try Data(contentsOf: enStrings)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let strings = try XCTUnwrap(plist as? [String: String])

        XCTAssertEqual(strings["대시보드"], "Dashboard")
        XCTAssertEqual(strings["업데이트 확인…"], "Check for Updates...")

        XCTAssertNotNil(bundledModuleDocument("UPDATE_GITHUB.en.md"))
        XCTAssertNotNil(bundledModuleDocument("UPDATE_GITHUB.ko.md"))
    }

    func testSchedulePlannerStartsOneShotAndRemovesSchedule() {
        let channel = Channel(id: "channel_1", name: "Channel", output_dir: ".")
        let schedule = Schedule(channelID: channel.id, startEpoch: 900, durationMinutes: 0)

        let result = SchedulePlanner.tick(
            schedules: [schedule],
            channels: [channel],
            recordingChannels: [],
            now: 1_000)

        XCTAssertEqual(result.actions, [.start(channelID: channel.id, oneShot: true)])
        XCTAssertTrue(result.schedules.isEmpty)
    }

    func testSchedulePlannerStartsTimedScheduleThenStopsAtEnd() {
        let channel = Channel(id: "channel_1", name: "Channel", output_dir: ".")
        let schedule = Schedule(channelID: channel.id, startEpoch: 1_000, durationMinutes: 30)

        let started = SchedulePlanner.tick(
            schedules: [schedule],
            channels: [channel],
            recordingChannels: [],
            now: 1_000)

        XCTAssertEqual(started.actions, [.start(channelID: channel.id, oneShot: false)])
        XCTAssertEqual(started.schedules.count, 1)
        XCTAssertTrue(started.schedules[0].started)

        let stopped = SchedulePlanner.tick(
            schedules: started.schedules,
            channels: [channel],
            recordingChannels: [channel.id],
            now: 2_800)

        XCTAssertEqual(stopped.actions, [.stop(channelID: channel.id)])
        XCTAssertTrue(stopped.schedules.isEmpty)
    }

    func testSchedulePlannerDropsSchedulesForRemovedChannels() {
        let schedule = Schedule(channelID: "missing", startEpoch: 1_000, durationMinutes: 30)

        let result = SchedulePlanner.tick(
            schedules: [schedule],
            channels: [],
            recordingChannels: [],
            now: 1_000)

        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.schedules.isEmpty)
    }

    func testSchedulePlannerRenamesChannelReferences() {
        let old = Schedule(channelID: "old_id", startEpoch: 1_000, durationMinutes: 30)
        let other = Schedule(channelID: "other_id", startEpoch: 1_000, durationMinutes: 30)

        let renamed = SchedulePlanner.renameChannelReferences(
            schedules: [old, other],
            from: "old_id",
            to: "new_id")

        XCTAssertEqual(renamed.map(\.channelID), ["new_id", "other_id"])
    }

    func testSchedulePlannerRemovesDeletedChannelReferences() {
        let deleted = Schedule(channelID: "deleted_id", startEpoch: 1_000, durationMinutes: 30)
        let other = Schedule(channelID: "other_id", startEpoch: 1_000, durationMinutes: 30)

        let remaining = SchedulePlanner.removeChannelReferences(
            schedules: [deleted, other],
            channelID: "deleted_id")

        XCTAssertEqual(remaining.map(\.channelID), ["other_id"])
    }

    func testSchedulePlannerStopsActiveTimedScheduleWhenDeleted() {
        var schedule = Schedule(channelID: "channel_1", startEpoch: 1_000, durationMinutes: 30)
        schedule.started = true

        let result = SchedulePlanner.delete(
            schedules: [schedule],
            id: schedule.id,
            recordingChannels: [schedule.channelID])

        XCTAssertTrue(result.schedules.isEmpty)
        XCTAssertEqual(result.action, .stop(channelID: schedule.channelID))
    }

    func testSchedulePlannerDeletingPendingScheduleDoesNotStopRecording() {
        let schedule = Schedule(channelID: "channel_1", startEpoch: 1_000, durationMinutes: 30)

        let result = SchedulePlanner.delete(
            schedules: [schedule],
            id: schedule.id,
            recordingChannels: [schedule.channelID])

        XCTAssertTrue(result.schedules.isEmpty)
        XCTAssertNil(result.action)
    }

    func testDASHParserPreservesSegmentTemplateTimelineParts() throws {
        let xml = """
        <MPD>
          <Period>
            <BaseURL>vod/</BaseURL>
            <AdaptationSet>
              <BaseURL>video/</BaseURL>
              <SegmentTemplate timescale="1000"
                  initialization="$RepresentationID$/init.mp4"
                  media="$RepresentationID$/chunk_$Number%05d$_$Time$.m4s"
                  startNumber="42">
                <SegmentTimeline>
                  <S t="0" d="4000" r="2"/>
                  <S d="2000"/>
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="v1080" bandwidth="5000000" width="1920" height="1080">
                <BaseURL>main/</BaseURL>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let reps = DASHParser.parse(
            Data(xml.utf8),
            manifestURL: try XCTUnwrap(URL(string: "https://cdn.example/path/manifest.mpd")))

        let rep = try XCTUnwrap(reps.first)
        let plan = try XCTUnwrap(rep.segmentPlan)

        XCTAssertEqual(rep.quality, 1080)
        XCTAssertEqual(plan.initializationURL, "https://cdn.example/path/vod/video/main/v1080/init.mp4")
        XCTAssertEqual(plan.media.map(\.url), [
            "https://cdn.example/path/vod/video/main/v1080/chunk_00042_0.m4s",
            "https://cdn.example/path/vod/video/main/v1080/chunk_00043_4000.m4s",
            "https://cdn.example/path/vod/video/main/v1080/chunk_00044_8000.m4s",
            "https://cdn.example/path/vod/video/main/v1080/chunk_00045_12000.m4s",
        ])
        XCTAssertEqual(plan.media.map(\.start), [0, 4, 8, 12])
        XCTAssertEqual(plan.media.map(\.duration), [4, 4, 4, 2])
    }

    func testDASHParserBuildsSegmentsFromTemplateDuration() throws {
        let xml = """
        <MPD mediaPresentationDuration="PT10S">
          <Period>
            <AdaptationSet>
              <SegmentTemplate timescale="1000"
                  initialization="init_$RepresentationID$.mp4"
                  media="chunk_$Number$.m4s"
                  startNumber="7"
                  duration="4000"/>
              <Representation id="v720" bandwidth="3000000" width="1280" height="720">
                <BaseURL>video/</BaseURL>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let reps = DASHParser.parse(
            Data(xml.utf8),
            manifestURL: try XCTUnwrap(URL(string: "https://cdn.example/vod/manifest.mpd")))

        let plan = try XCTUnwrap(try XCTUnwrap(reps.first).segmentPlan)

        XCTAssertEqual(plan.initializationURL, "https://cdn.example/vod/video/init_v720.mp4")
        XCTAssertEqual(plan.media.map(\.url), [
            "https://cdn.example/vod/video/chunk_7.m4s",
            "https://cdn.example/vod/video/chunk_8.m4s",
            "https://cdn.example/vod/video/chunk_9.m4s",
        ])
        XCTAssertEqual(plan.media.map(\.start), [0, 4, 8])
        XCTAssertEqual(plan.media.map(\.duration), [4, 4, 2])
    }

    func testSegmentPlanSelectsOnlyOverlappingClipParts() {
        let plan = VODSegmentPlan(initializationURL: "https://cdn.example/init.mp4", media: [
            VODMediaSegment(url: "https://cdn.example/part0.m4s", start: 0, duration: 4, index: 0),
            VODMediaSegment(url: "https://cdn.example/part1.m4s", start: 4, duration: 4, index: 1),
            VODMediaSegment(url: "https://cdn.example/part2.m4s", start: 8, duration: 4, index: 2),
            VODMediaSegment(url: "https://cdn.example/part3.m4s", start: 12, duration: 4, index: 3),
        ])

        let selected = plan.selectedMedia(clipStart: 8.5, clipEnd: 12.5)

        XCTAssertEqual(selected.map(\.index), [2, 3])
        XCTAssertFalse(selected.contains { $0.index == 0 || $0.index == 1 })
    }

    func testVODDownloadStrategyAvoidsPrefixDownloadForClips() {
        let direct = VODVariant(quality: 1080, url: "https://media.example/video.mp4", isHLS: false)
        let hls = VODVariant(quality: 1080, url: "https://media.example/master.m3u8", isHLS: true)
        let segmented = VODVariant(
            quality: 1080,
            url: "https://media.example/chunk_00001.m4s",
            segmentPlan: VODSegmentPlan(initializationURL: "https://media.example/init.mp4", media: [
                VODMediaSegment(url: "https://media.example/chunk_00001.m4s", start: 0, duration: 4, index: 0),
                VODMediaSegment(url: "https://media.example/chunk_00002.m4s", start: 4, duration: 4, index: 1),
            ]))

        XCTAssertEqual(
            VODDownloader.strategy(variant: direct, audioOnly: false, clipStart: nil, clipEnd: nil),
            .parallel
        )
        XCTAssertEqual(
            VODDownloader.strategy(variant: direct, audioOnly: false, clipStart: 10, clipEnd: 20),
            .parallelClipPostprocess
        )
        XCTAssertEqual(
            VODDownloader.strategy(variant: direct, audioOnly: true, clipStart: 10, clipEnd: 20),
            .parallelClipPostprocess
        )
        XCTAssertEqual(
            VODDownloader.strategy(variant: direct, audioOnly: true, clipStart: nil, clipEnd: nil),
            .parallelPostprocess
        )
        XCTAssertEqual(
            VODDownloader.strategy(variant: hls, audioOnly: false, clipStart: 10, clipEnd: 20),
            .hlsSegmentPrefetch
        )
        XCTAssertEqual(
            VODDownloader.strategy(variant: segmented, audioOnly: false, clipStart: 4.5, clipEnd: 6.5),
            .dashSegmentPrefetch
        )
        XCTAssertEqual(
            VODDownloader.strategy(variant: segmented, audioOnly: false, clipStart: nil, clipEnd: nil),
            .dashSegmentPrefetch
        )
    }

    func testDirectClipWindowRangesAvoidPrefixDownload() {
        let fileTotal = 10 * 1024 * 1024 * 1024
        let duration = 10_000.0
        let clipStart = 8_000.0
        let clipEnd = 8_010.0

        let ranges = ParallelDownloader.clipWindowRanges(
            fileTotal: fileTotal, durationSeconds: duration,
            clipStart: clipStart, clipEnd: clipEnd)
        let totalBytes = ranges.reduce(0) { $0 + $1.length }
        let prefixBytes = Int((Double(fileTotal) * clipEnd / duration).rounded(.up))

        XCTAssertGreaterThanOrEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first?.start, 0)
        XCTAssertEqual(ranges.last?.end, fileTotal - 1)
        XCTAssertTrue(ranges.contains { $0.start > fileTotal / 2 && $0.end < fileTotal - 1 })
        XCTAssertLessThan(totalBytes, prefixBytes / 4)
    }

    func testMP4ClipIndexComputesKeyframeAnchoredByteSpan() {
        // 4 video samples, 1s each (timescale 1000); keyframes at samples 1 and 3
        // (t=0 and t=2). Two chunks of two samples at file offsets 1000 and 5000.
        func be32(_ v: UInt32) -> Data {
            Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
        }
        func box(_ type: String, _ content: Data) -> Data {
            be32(UInt32(8 + content.count)) + Data(type.utf8) + content
        }
        func full(_ type: String, _ content: Data) -> Data { box(type, Data([0, 0, 0, 0]) + content) }

        let mdhd = full("mdhd", be32(0) + be32(0) + be32(1000) + be32(4000) + Data([0, 0, 0, 0]))
        let hdlr = full("hdlr", be32(0) + Data("vide".utf8) + Data(repeating: 0, count: 12) + Data([0]))
        let stts = full("stts", be32(1) + be32(4) + be32(1000))                       // 4 samples × 1s
        let stss = full("stss", be32(2) + be32(1) + be32(3))                          // keyframes 1,3 (0-based 0,2)
        let stsc = full("stsc", be32(1) + be32(1) + be32(2) + be32(1))                // 2 samples/chunk
        let stsz = full("stsz", be32(0) + be32(4) + be32(100) + be32(200) + be32(300) + be32(400))
        let stco = full("stco", be32(2) + be32(1000) + be32(5000))                    // chunk offsets
        let stbl = box("stbl", stts + stss + stsc + stsz + stco)
        let minf = box("minf", stbl)
        let mdia = box("mdia", mdhd + hdlr + minf)
        let moov = box("moov", box("trak", mdia))

        // Clip [1.5, 2.5]: keyframe ≤ 1.5 is t=0 (sample 0), last sample before 2.5 is
        // sample 2 (t=2). Bytes: s0@1000(100), s1@1100(200), s2@5000(300) → [1000, 5299].
        let span = MP4ClipIndex.clipByteSpan(
            moov: moov, clipStart: 1.5, clipEnd: 2.5, fileTotal: 10_000, padding: 0)

        XCTAssertEqual(span?.start, 1000)
        XCTAssertEqual(span?.end, 5299)
    }

    func testMP4ClipIndexReturnsNilForNonMP4() {
        XCTAssertNil(MP4ClipIndex.clipByteSpan(
            moov: Data("not an mp4 at all".utf8), clipStart: 1, clipEnd: 2, fileTotal: 1000))
    }

    func testDownloadRecordDoesNotExpectSourceFileForDirectClips() {
        let clip = makeRecord(path: "/tmp/video.mp4", isHLS: false, clipStart: 10, clipEnd: 20)
        XCTAssertNil(clip.sourcePath)
        XCTAssertTrue(clip.partPath.contains(".cvd-"))

        let wholeAudio = makeRecord(path: "/tmp/audio.m4a", isHLS: false, clipStart: nil, clipEnd: nil)
        XCTAssertNotNil(wholeAudio.sourcePath)

        let hlsAudio = makeRecord(path: "/tmp/hls-audio.m4a", isHLS: true, clipStart: nil, clipEnd: nil)
        XCTAssertNil(hlsAudio.sourcePath)
    }

    func testDownloadRecordTracksHLSWorkDirectoryByRecordID() {
        let hls = makeRecord(path: "/tmp/video.mp4", isHLS: true, clipStart: nil, clipEnd: nil)
        let direct = makeRecord(path: "/tmp/video.mp4", isHLS: false, clipStart: nil, clipEnd: nil)

        XCTAssertNotNil(hls.hlsWorkDirPath)
        XCTAssertTrue(hls.hlsWorkDirPath?.contains(hls.id.uuidString) == true)
        XCTAssertNil(direct.hlsWorkDirPath)
        XCTAssertTrue(hls.dashWorkDirPath.contains(hls.id.uuidString))
    }

    func testDownloadRecordTemporaryArtifactCleanupRemovesPartialFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = makeRecord(path: directory.appendingPathComponent("video.mp4").path,
                                isHLS: true, clipStart: nil, clipEnd: nil)
        let paths = [
            record.partPath,
            record.sidecarPath,
            record.legacyPartPath,
            record.legacySidecarPath,
            record.legacyTransferPartPath,
            record.legacyTransferSidecarPath,
            record.clipSourcePath,
            record.postprocessPartPath,
        ]
        for path in paths {
            try Data("temporary".utf8).write(to: URL(fileURLWithPath: path))
        }
        try FileManager.default.createDirectory(
            atPath: record.dashWorkDirPath, withIntermediateDirectories: true)
        let hlsWorkDirPath = try XCTUnwrap(record.hlsWorkDirPath)
        try FileManager.default.createDirectory(atPath: hlsWorkDirPath, withIntermediateDirectories: true)

        record.removeTemporaryArtifacts()

        for path in paths + [record.dashWorkDirPath, hlsWorkDirPath] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func testRemoteFFmpegClipArgumentsFastSeekBeforeInput() {
        let args = VODDownloader.remoteFFmpegArguments(
            variantURL: "https://media.example/video.mp4",
            cookies: Cookies(NID_SES: "ses", NID_AUT: "aut"),
            outURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            partURL: URL(fileURLWithPath: "/tmp/out.part"),
            audioOnly: false,
            clipStart: 12.345,
            clipDuration: 6.5
        )

        guard let ssIndex = args.firstIndex(of: "-ss"),
              let inputIndex = args.firstIndex(of: "-i"),
              let durationIndex = args.firstIndex(of: "-t") else {
            return XCTFail("expected -ss, -i, and -t in ffmpeg arguments")
        }

        XCTAssertLessThan(ssIndex, inputIndex)
        XCTAssertGreaterThan(durationIndex, inputIndex)
        XCTAssertEqual(args[args.index(after: ssIndex)], "12.345")
        XCTAssertEqual(args[args.index(after: durationIndex)], "6.500")
        XCTAssertEqual(args.filter { $0 == "-ss" }.count, 1)
        XCTAssertEqual(args.filter { $0 == "-map" }.count, 2)
        XCTAssertTrue(args.contains("0:v:0?"))
        XCTAssertTrue(args.contains("0:a:0?"))
        XCTAssertTrue(args.contains("-dn"))
        XCTAssertTrue(args.contains("-sn"))
    }

    func testFormattedFFmpegSpeedAvoidsDoubleXAndRounds() {
        XCTAssertEqual(VODDownloader.formattedFFmpegSpeed("1.22345x", fallback: "N/A"), "1.22x")
        XCTAssertEqual(VODDownloader.formattedFFmpegSpeed("12.345x", fallback: "N/A"), "12.3x")
        XCTAssertEqual(VODDownloader.formattedFFmpegSpeed("0.9", fallback: "N/A"), "0.90x")
        XCTAssertEqual(VODDownloader.formattedFFmpegSpeed(nil, fallback: "N/A"), "N/A")
    }

    func testAudioOnlyFFmpegArgumentsMapOnlyAudio() {
        let args = VODDownloader.copyStreamArgs(audioOnly: true)

        XCTAssertEqual(args, ["-map", "0:a:0?", "-vn", "-sn", "-dn", "-c:a", "copy"])
    }

    func testAACFallbackArgumentsTranscodeOnlyAudio() {
        let audio = VODDownloader.aacFallbackStreamArgs(audioOnly: true)
        let video = VODDownloader.aacFallbackStreamArgs(audioOnly: false)

        XCTAssertEqual(audio, ["-map", "0:a:0?", "-vn", "-sn", "-dn", "-c:a", "aac", "-b:a", "192k"])
        XCTAssertTrue(video.contains("-c:v"))
        XCTAssertTrue(video.contains("copy"))
        XCTAssertTrue(video.contains("-c:a"))
        XCTAssertTrue(video.contains("aac"))
        XCTAssertTrue(video.contains("-movflags"))
    }

    func testPostprocessRetriesWithAACOnlyForCodecContainerFailures() {
        XCTAssertTrue(VODDownloader.shouldRetryPostprocessWithAAC(
            status: 1,
            logTail: [
                "Could not find tag for codec opus in stream #0, codec not currently supported in container",
                "Conversion failed!"
            ]))

        XCTAssertFalse(VODDownloader.shouldRetryPostprocessWithAAC(
            status: 228,
            logTail: ["No space left on device", "Conversion failed!"]))
        XCTAssertFalse(VODDownloader.shouldRetryPostprocessWithAAC(
            status: 1,
            logTail: ["Server returned 403 Forbidden", "Conversion failed!"]))
    }

    func testPostprocessSourceIsNotPreservedOnFailure() {
        let source = URL(fileURLWithPath: "/tmp/audio.source.mp4")

        XCTAssertFalse(VODDownloader.shouldPreservePostprocessSourceOnFailure(
            sourceURL: source, cleanupURL: source,
            audioOnly: true, clipStart: nil, clipDuration: nil))
        XCTAssertFalse(VODDownloader.shouldPreservePostprocessSourceOnFailure(
            sourceURL: source, cleanupURL: source,
            audioOnly: false, clipStart: nil, clipDuration: nil))
        XCTAssertFalse(VODDownloader.shouldPreservePostprocessSourceOnFailure(
            sourceURL: source, cleanupURL: source,
            audioOnly: true, clipStart: 10, clipDuration: 20))
        XCTAssertFalse(VODDownloader.shouldPreservePostprocessSourceOnFailure(
            sourceURL: source, cleanupURL: URL(fileURLWithPath: "/tmp/hls-work"),
            audioOnly: true, clipStart: nil, clipDuration: nil))
    }

    func testEstimatedPostprocessSpaceUsesSmallerAudioEstimate() {
        let sourceSize = 800 * 1024 * 1024
        let videoEstimate = VODDownloader.estimatedPostprocessOutputBytes(
            sourceSize: sourceSize, audioOnly: false)
        let audioEstimate = VODDownloader.estimatedPostprocessOutputBytes(
            sourceSize: sourceSize, audioOnly: true)

        XCTAssertGreaterThan(videoEstimate, sourceSize)
        XCTAssertLessThan(audioEstimate, videoEstimate)
        XCTAssertGreaterThan(audioEstimate, 32 * 1024 * 1024)
    }

    func testPostprocessSpaceFailureMessageShowsRequiredAndAvailable() {
        let message = VODDownloader.postprocessSpaceFailureMessage(
            required: 128 * 1024 * 1024,
            available: 64 * 1024 * 1024)

        XCTAssertTrue(message.contains("저장 공간 부족"))
        XCTAssertTrue(message.contains("128.00 MB"))
        XCTAssertTrue(message.contains("64.00 MB"))
    }

    func testPostprocessUsesConservativeWritableCapacity() {
        XCTAssertEqual(
            VODDownloader.conservativeWritableCapacity(
                important: 512 * 1024 * 1024,
                regular: 64 * 1024 * 1024),
            64 * 1024 * 1024
        )
        XCTAssertEqual(
            VODDownloader.conservativeWritableCapacity(
                important: nil,
                regular: 64 * 1024 * 1024),
            64 * 1024 * 1024
        )
        XCTAssertEqual(
            VODDownloader.conservativeWritableCapacity(
                important: 0,
                regular: 64 * 1024 * 1024),
            64 * 1024 * 1024
        )
        XCTAssertEqual(
            VODDownloader.conservativeWritableCapacity(
                important: 512 * 1024 * 1024,
                regular: 0),
            512 * 1024 * 1024
        )
        XCTAssertEqual(VODDownloader.conservativeWritableCapacity(important: 0, regular: 0), 0)
        XCTAssertNil(VODDownloader.conservativeWritableCapacity(important: nil, regular: nil))
    }

    func testFFmpegFailureMessageExplainsDiskFullInsteadOfGenericConversionFailed() {
        let message = VODDownloader.ffmpegFailureMessage(
            prefix: "ffmpeg 로컬 처리",
            status: 228,
            logTail: [
                "Error writing trailer of /Volumes/T5/video.mp4: No space left on device",
                "Conversion failed!"
            ])

        XCTAssertTrue(message.contains("저장 공간이 부족합니다"))
        XCTAssertFalse(message.contains("Conversion failed"))
    }

    func testFFmpegFailureMessageExplainsExitCode228EvenWhenOnlyGenericLineWasCaptured() {
        let message = VODDownloader.ffmpegFailureMessage(
            prefix: "ffmpeg 로컬 처리",
            status: 228,
            logTail: ["Conversion failed!"])

        XCTAssertTrue(message.contains("저장 공간이 부족합니다"))
        XCTAssertTrue(message.contains("ENOSPC"))
        XCTAssertFalse(message.contains("Conversion failed"))
    }

    func testFFmpegFailureMessageKeepsSpecificReasonBeforeGenericConversionFailed() {
        let message = VODDownloader.ffmpegFailureMessage(
            prefix: "ffmpeg 로컬 처리",
            status: 1,
            logTail: [
                "Could not find tag for codec opus in stream #0, codec not currently supported in container",
                "Conversion failed!"
            ])

        XCTAssertTrue(message.contains("Could not find tag for codec opus"))
        XCTAssertFalse(message.hasSuffix("Conversion failed!"))
    }

    func testFFmpegOutputCaptureKeepsUnterminatedFinalErrorLine() {
        let capture = FFmpegOutputCapture()

        capture.consume(Data("frame=1\nError writing trailer: No space left on device".utf8))

        XCTAssertEqual(
            capture.finishAndTail().suffix(1),
            ["Error writing trailer: No space left on device"])
    }

    func testFFmpegOutputCaptureDoesNotDropErrorsBehindProgressNoise() {
        let capture = FFmpegOutputCapture()

        capture.consume(Data("Error writing trailer: No space left on device\n".utf8))
        for _ in 0..<80 {
            capture.consume(Data("frame=1\ntotal_size=1024\nout_time=00:00:01.000000\nspeed=1.0\nprogress=continue\n".utf8))
        }
        capture.consume(Data("Conversion failed!".utf8))

        let tail = capture.finishAndTail()
        XCTAssertTrue(tail.contains("Error writing trailer: No space left on device"))
        XCTAssertEqual(tail.last, "Conversion failed!")
    }

    func testFFmpegOutputCaptureEmitsProgressSnapshots() {
        let capture = FFmpegOutputCapture()
        var snapshots: [[String: String]] = []

        capture.consume(Data("out_time=00:00:02.000000\ntotal_size=1024\nprogress=continue\n".utf8)) {
            snapshots.append($0)
        }

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?["out_time"], "00:00:02.000000")
        XCTAssertEqual(snapshots.first?["total_size"], "1024")
        XCTAssertEqual(snapshots.first?["progress"], "continue")
    }

    func testRecordingSessionRequestFinishLetsConsumerFinalizeAfterEOF() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let producer = directory.appendingPathComponent("producer.sh")
        let consumer = directory.appendingPathComponent("consumer.sh")
        let marker = directory.appendingPathComponent("finalized.txt")

        try """
        #!/bin/sh
        while true; do
          printf x
          sleep 0.05
        done
        """.write(to: producer, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        cat >/dev/null
        printf finalized > "\(marker.path)"
        """.write(to: consumer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: producer.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: consumer.path)

        let session = RecordingSession(
            streamlinkPath: producer.path, streamlinkArgs: [],
            ffmpegPath: consumer.path, ffmpegArgs: [])

        try session.start(onFfmpegStderr: { _ in }, onStreamlinkStderr: { _ in })
        session.requestFinish(fallbackAfter: 2)
        await session.waitUntilExit()

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "finalized")
    }

    func testDiagnosticTextRedactsPrivateValues() {
        let input = """
        /Users/alice/Movies/secret.mp4
        /Volumes/T5 EVO/Downloads/video.mp4
        Cookie: NID_AUT=aut-secret; NID_SES=ses-secret
        proxy http://proxy-user:proxy-pass@example.com:8080
        https://example.com/appcast.xml?token=feed-secret&sig=signature-secret
        https://media.example/video.mp4?inKey=media-secret&other=value
        https://discord.com/api/webhooks/1234567890/discord-secret
        https://hooks.slack.com/services/T000/B000/slack-secret
        https://api.telegram.org/bottelegram-secret/sendMessage?chat_id=123
        volume “Macintosh HD”
        """

        let redacted = AppModel.redactDiagnosticText(input)

        XCTAssertFalse(redacted.contains("/Users/alice"))
        XCTAssertFalse(redacted.contains("T5 EVO"))
        XCTAssertFalse(redacted.contains("aut-secret"))
        XCTAssertFalse(redacted.contains("ses-secret"))
        XCTAssertFalse(redacted.contains("proxy-user"))
        XCTAssertFalse(redacted.contains("proxy-pass"))
        XCTAssertFalse(redacted.contains("feed-secret"))
        XCTAssertFalse(redacted.contains("signature-secret"))
        XCTAssertFalse(redacted.contains("media-secret"))
        XCTAssertFalse(redacted.contains("discord-secret"))
        XCTAssertFalse(redacted.contains("slack-secret"))
        XCTAssertFalse(redacted.contains("telegram-secret"))
        XCTAssertFalse(redacted.contains("Macintosh HD"))

        XCTAssertTrue(redacted.contains("~/Movies/secret.mp4"))
        XCTAssertTrue(redacted.contains("/Volumes/<volume>/Downloads/video.mp4"))
        XCTAssertTrue(redacted.contains("Cookie: <redacted>"))
        XCTAssertTrue(redacted.contains("http://<redacted>@example.com:8080"))
        XCTAssertTrue(redacted.contains("https://example.com/appcast.xml?<redacted>"))
        XCTAssertTrue(redacted.contains("volume “<redacted>”"))
    }

    func testDiagnosticCapacitySummaryFormatsAndHandlesUnknown() {
        XCTAssertEqual(AppModel.capacitySummary(nil), "확인 불가")
        XCTAssertEqual(AppModel.capacitySummary(128 * 1024 * 1024), "128.00 MB")
    }

    func testDiagnosticLogRedactsVODTitlesAndPaths() {
        let line = "2026-06-03 10:00:00 - VOD 다운로드 시작: 민감한 방송 제목 (1080p, HLS 병렬+로컬처리)"
        let saved = "2026-06-03 10:00:01 - VOD 저장 완료: /Users/alice/Movies/private.mp4"

        XCTAssertEqual(
            AppModel.redactDiagnosticLogLine(line),
            "2026-06-03 10:00:00 - VOD 다운로드 시작: <title redacted> (1080p, HLS 병렬+로컬처리)"
        )
        XCTAssertEqual(
            AppModel.redactDiagnosticLogLine(saved),
            "2026-06-03 10:00:01 - VOD 저장 완료: <path redacted>"
        )
    }

    func testBinaryCookiesIgnoresOutOfRangeStringOffsets() {
        var data = Data("cook".utf8)
        appendBE32(1, to: &data)
        appendBE32(80, to: &data)
        var page = Data(repeating: 0, count: 80)
        writeLE32(1, into: &page, at: 4)
        writeLE32(16, into: &page, at: 8)
        let cookie = 16
        writeLE32(10_000, into: &page, at: cookie + 16)
        writeLE32(10_000, into: &page, at: cookie + 20)
        writeLE32(10_000, into: &page, at: cookie + 28)
        data.append(page)

        XCTAssertTrue(BinaryCookies.parse(data).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChzzkDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeTestFile(_ url: URL, bytes: Int, modifiedAt: Date) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func bundledModuleDocument(_ filename: String) -> URL? {
        Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Documents")
            ?? Bundle.module.url(forResource: filename, withExtension: nil)
    }

    private func appendBE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func writeLE32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func makeRecord(path: String, isHLS: Bool, clipStart: Double?, clipEnd: Double?) -> DownloadRecord {
        DownloadRecord(
            vodURL: "https://chzzk.naver.com/video/123",
            title: "title",
            channelName: "channel",
            quality: 1080,
            isHLS: isHLS,
            duration: 100,
            finalPath: path,
            totalSize: 0,
            fileSize: 0,
            status: .failed,
            createdAt: Date(),
            updatedAt: Date(),
            clipStart: clipStart,
            clipEnd: clipEnd
        )
    }
}
