import Foundation
import AppKit
import Observation

struct ChannelProgress: Identifiable, Hashable {
    var id: String           // channel id
    var channelName: String
    var bitrate: String = "N/A"
    var downloadSpeed: String = "N/A"
    var totalSize: String = "N/A"
    var outTime: String = "N/A"
    var startTime: String = "N/A"
}

/// Describes a missing-tool install prompt shown to the user.
struct ToolAlert: Identifiable {
    let id = UUID()
    let missing: [String]
    var command: String { "brew install " + missing.joined(separator: " ") }
    var message: String {
        "\(missing.joined(separator: ", "))(이)가 설치되어 있지 않습니다.\n\n"
        + "Homebrew가 있다면 터미널에서 아래 명령을 실행한 뒤 다시 시도하세요:\n\n\(command)\n\n"
        + "Homebrew가 없다면 brew.sh 에서 먼저 설치하세요."
    }
}

@MainActor
@Observable
final class AppModel {
    var config: Config {
        didSet {
            ProxySupport.current = config.proxy
            engine.updateSnapshot(config)   // cheap, in-memory — keep immediate
            if oldValue.ffmpeg_path != config.ffmpeg_path
                || oldValue.streamlink_path != config.streamlink_path {
                configureEngineTooling()    // re-resolve when the override changes
            }
            scheduleConfigSave()            // disk write — debounced
        }
    }
    private var configSaveTask: Task<Void, Never>?
    var progress: [ChannelProgress] = []
    var logLines: [String] = []

    var toolAlert: ToolAlert?           // set when an action needs a tool that's missing
    var fullDiskAccessNeeded = false    // set when Safari cookie import needs Full Disk Access
    var toast: String?                  // transient optimistic-UI confirmation
    var supportSheet: SupportSheet?
    private var toastTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // VOD download
    var vodItems: [VODItem] = []
    var downloadRecords: [DownloadRecord] = []
    /// VOD items currently open in a clip-picker window, keyed by id so the
    /// separate (resizable) window can resolve the live object.
    var clipTargets: [UUID: VODItem] = [:]
    var cookieImportMessage: String?
    var cookieAuthWarning: String?
    var cookieUpdatedAt: Date? {
        didSet {
            if let cookieUpdatedAt {
                UserDefaults.standard.set(cookieUpdatedAt.timeIntervalSince1970, forKey: Self.cookieUpdatedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.cookieUpdatedAtKey)
            }
        }
    }
    var vodOutputDir: String {
        didSet { UserDefaults.standard.set(vodOutputDir, forKey: "vodOutputDir") }
    }
    var vodConnections: Int {
        didSet {
            let normalized = Validate.normalizeVODConnections(vodConnections)
            if normalized != vodConnections { vodConnections = normalized }
            UserDefaults.standard.set(normalized, forKey: "vodConnections")
        }
    }
    /// Aggregate VOD download limit in MB/s; 0 = unlimited.
    var vodSpeedLimitMBps: Double {
        didSet {
            let normalized = Validate.normalizeVODSpeedLimitMBps(vodSpeedLimitMBps)
            if normalized != vodSpeedLimitMBps { vodSpeedLimitMBps = normalized }
            UserDefaults.standard.set(normalized, forKey: "vodSpeedLimitMBps")
        }
    }
    private let vodDownloader = VODDownloader()
    private static let cookieUpdatedAtKey = "cookieUpdatedAt"
    private static let cookieRefreshReminderDayKey = "cookieRefreshReminderDay"
    private static let cookieAuthWarningCooldown: TimeInterval = 60 * 60
    private var lastCookieAuthWarningAt: Date?

    /// Live status of registered channels, for the dashboard's on-demand panel.
    var liveStatus: [String: (isLive: Bool, title: String, category: String)] = [:]
    var recordingChannels: Set<String> = [] {
        didSet {
            refreshActivityAssertion()
            persistArmedChannelsIfChanged(oldValue)
        }
    }
    private var oneShotRecordingChannels: Set<String> = []
    /// Suppresses the recordingChannels didSet from rewriting config.armed_channels.
    /// Set during launch-time restore and during termination, so the persisted
    /// monitoring set survives a quit instead of being wiped to empty on shutdown.
    private var suppressArmedPersist = false
    private var activityToken: NSObjectProtocol?

    /// Resolved tool paths — a valid override in config wins, else auto-detect.
    var ffmpegPath: String? { Tooling.locate("ffmpeg", override: config.ffmpeg_path) }
    var streamlinkPath: String? { Tooling.locate("streamlink", override: config.streamlink_path) }
    var toolsAvailable: Bool { ffmpegPath != nil && streamlinkPath != nil }

    /// Bundled streamlink plugin directory (contains chzzk.py).
    /// Avoids Bundle.module (which can fatalError when its build-path is absent).
    let pluginDir: String = {
        let fm = FileManager.default
        let sourcePlugin = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Sources/ChzzkDownloader/Resources/plugin")
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("plugin"),  // .app: Contents/Resources/plugin
            sourcePlugin,                                               // swift run from source tree
        ].compactMap { $0 }
        for url in candidates where fm.fileExists(atPath: url.appendingPathComponent("chzzk.py").path) {
            return url.path
        }
        return Bundle.main.resourceURL?.appendingPathComponent("plugin").path ?? sourcePlugin.path
    }()

    private let engine = RecordingEngine()
    private let logStore = LogStore(url: ConfigStore.directory.appendingPathComponent("log.log"))

    init() {
        self.config = ConfigStore.load()
        self.vodOutputDir = UserDefaults.standard.string(forKey: "vodOutputDir")
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChzzkDownloader").path
        let savedConn = UserDefaults.standard.integer(forKey: "vodConnections")
        self.vodConnections = Validate.normalizeVODConnections(
            savedConn == 0 ? Defaults.defaultVODConnections : savedConn)
        self.vodSpeedLimitMBps = Validate.normalizeVODSpeedLimitMBps(
            UserDefaults.standard.double(forKey: "vodSpeedLimitMBps"))
        let savedCookieUpdatedAt = UserDefaults.standard.double(forKey: Self.cookieUpdatedAtKey)
        self.cookieUpdatedAt = savedCookieUpdatedAt > 0
            ? Date(timeIntervalSince1970: savedCookieUpdatedAt)
            : nil
        ProxySupport.current = config.proxy

        // Any download still marked "downloading" means the app died mid-download.
        // Resume support is intentionally disabled, so stale temporary artifacts
        // are removed and the record is left as interrupted history only.
        var records = DownloadStore.load()
        var changed = false
        for i in records.indices {
            if records[i].status == .downloading {
                records[i].status = .interrupted
                changed = true
            }
            if records[i].status == .interrupted || records[i].status == .failed {
                records[i].removeTemporaryArtifacts()
            }
        }
        self.downloadRecords = records
        if changed { DownloadStore.save(records) }

        engine.updateSnapshot(config)
        let pluginOK = FileManager.default.fileExists(
            atPath: (pluginDir as NSString).appendingPathComponent("chzzk.py"))
        appendLog("내장 플러그인 확인: \(pluginOK ? "성공" : "실패")")
        engine.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        engine.onProgress = { [weak self] p in
            Task { @MainActor in self?.upsertProgress(p) }
        }
        engine.onProgressRemove = { [weak self] id in
            Task { @MainActor in self?.progress.removeAll { $0.id == id } }
        }
        engine.onSaved = { [weak self] channelName, path, wasSplit in
            Task { @MainActor in
                guard let self else { return }
                if self.config.notify_on_complete {
                    Notifier.notify(title: "녹화 저장 완료", body: channelName, filePath: path)
                }
                // Webhook "완료" only when the broadcast actually ended (not a split segment).
                if !wasSplit {
                    WebhookNotifier.send(self.config.notify_webhook_url, "✅ 녹화 완료: \(channelName)")
                }
                self.enforceCyclicLimit(channelName: channelName, savedPath: path)
            }
        }
        engine.onRecordingStarted = { [weak self] channelName, _, isContinuation in
            Task { @MainActor in
                guard let self, !isContinuation else { return }
                WebhookNotifier.send(self.config.notify_webhook_url, "▶️ 녹화 시작: \(channelName)")
            }
        }
        engine.onAuthFailure = { [weak self] context in
            Task { @MainActor in self?.markCookieAuthFailure(context: context) }
        }
        engine.onRecordingEnded = { [weak self] channelID, oneShot in
            Task { @MainActor in
                guard let self else { return }
                self.recordingChannels.remove(channelID)
                self.oneShotRecordingChannels.remove(channelID)
                if oneShot {
                    let name = self.config.channels.first(where: { $0.id == channelID })?.name ?? channelID
                    self.appendLog("예약 녹화 완료: \(name)")
                }
            }
        }
        configureEngineTooling()
        Notifier.requestAuthorizationIfNeeded()
        checkCookieRefreshReminder()
        importCookiesOnLaunchIfNeeded()
        restoreArmedChannels()
        startLivePolling()
        startScheduler()
    }

    // MARK: live status polling (for the dashboard on-demand panel)

    private var livePoll: Task<Void, Never>?

    private func startLivePolling() {
        livePoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let channels = self.config.channels
                let cookies = self.config.cookies
                await withTaskGroup(of: (String, Bool, String, String, Bool).self) { group in
                    for ch in channels {
                        group.addTask {
                            let result = await ChzzkAPI.fetchLiveInfoResult(channelID: ch.id, cookies: cookies)
                            switch result {
                            case .info(let info):
                                return (ch.id, info?.status == "OPEN", info?.liveTitle ?? "", info?.category ?? "", false)
                            case .authFailed:
                                return (ch.id, false, "", "", true)
                            }
                        }
                    }
                    for await (id, live, title, category, authFailed) in group {
                        self.liveStatus[id] = (live, title, category)
                        if authFailed {
                            self.markCookieAuthFailure(context: "라이브 상태 확인")
                        }
                        if Self.shouldNudgeArmedRecording(
                            isLive: live,
                            isArmed: self.recordingChannels.contains(id),
                            isWriting: self.isWritingRecording(id)) {
                            self.nudgeArmedRecording(channelID: id)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            }
        }
    }

    // MARK: missing-tool prompting

    /// (Re)points the recording engine at the currently resolved tool paths, so a
    /// custom path entered in settings takes effect for new recordings.
    private func configureEngineTooling() {
        guard let ffmpeg = ffmpegPath, let streamlink = streamlinkPath else { return }
        engine.configure(ffmpegPath: ffmpeg, streamlinkPath: streamlink, pluginDir: pluginDir)
    }

    private func missingTools(needStreamlink: Bool) -> [String] {
        var m: [String] = []
        if ffmpegPath == nil { m.append("ffmpeg") }
        if needStreamlink && streamlinkPath == nil { m.append("streamlink") }
        return m
    }

    /// Returns false (and raises an install prompt) if a required tool is missing.
    @discardableResult
    private func ensureTools(needStreamlink: Bool) -> Bool {
        let missing = missingTools(needStreamlink: needStreamlink)
        guard missing.isEmpty else {
            toolAlert = ToolAlert(missing: missing)
            appendLog("필수 도구 없음: \(missing.joined(separator: ", "))")
            return false
        }
        return true
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
    private func enforceCyclicLimit(channelName: String, savedPath: String) {
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

    /// Persists the set of continuously-monitored channels (excluding one-shot
    /// scheduled recordings, which the scheduler resumes on its own) so monitoring
    /// can be restored on the next launch. No-op while restoring at launch.
    private func persistArmedChannelsIfChanged(_ oldValue: Set<String>) {
        guard !suppressArmedPersist else { return }
        let desired = recordingChannels.subtracting(oneShotRecordingChannels)
        if Set(config.armed_channels) != desired {
            config.armed_channels = desired.sorted()
        }
    }

    /// Re-arms channels that were being monitored when the app last quit. Each one
    /// starts in the same continuous-monitoring mode (records the current live now
    /// if any, otherwise waits for the next broadcast).
    private func restoreArmedChannels() {
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

    /// Holds an activity assertion while any recording or download is in progress,
    /// preventing App Nap throttling and idle system sleep so background work runs.
    func refreshActivityAssertion() {
        let busy = !recordingChannels.isEmpty || vodItems.contains { $0.state == .downloading }
        if busy, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "녹화/다운로드 진행 중")
        } else if !busy, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private var hasAnyStoredCookie: Bool {
        !config.cookies.NID_AUT.isEmpty || !config.cookies.NID_SES.isEmpty
    }

    var hasStoredCookies: Bool {
        !config.cookies.NID_AUT.isEmpty && !config.cookies.NID_SES.isEmpty
    }

    var cookieAgeDays: Int? {
        guard let cookieUpdatedAt else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: cookieUpdatedAt)
        let end = calendar.startOfDay(for: Date())
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    var cookieNeedsRefresh: Bool {
        guard hasStoredCookies else { return true }
        return Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt)
    }

    var cookieStatusText: String {
        guard hasStoredCookies else { return hasAnyStoredCookie ? "쿠키 일부 없음" : "쿠키 없음" }
        guard let cookieUpdatedAt else { return "갱신일 기록 없음" }
        if Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt) { return "월초 갱신 필요" }
        if (Self.daysUntilNextCookieRefreshMonth() ?? 99) <= 3 { return "곧 갱신 권장" }
        return "정상"
    }

    var cookieStatusDetail: String {
        guard hasStoredCookies else {
            return "성인 인증 방송이나 일부 VOD에는 NID_AUT/NID_SES가 모두 필요합니다."
        }
        guard let cookieUpdatedAt else {
            return "마지막 갱신 시각이 없습니다. 브라우저에서 다시 가져오면 기록됩니다."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let updated = formatter.string(from: cookieUpdatedAt)
        if Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt) {
            return "마지막 갱신: \(updated). 이번 달 1일 이후 갱신 기록이 없습니다."
        }
        return "마지막 갱신: \(updated). 이번 달 쿠키로 표시됩니다."
    }

    func importCookiesFromFirstAvailableBrowser() {
        guard let browser = installedBrowsers.first else {
            cookieImportMessage = "설치된 브라우저를 찾지 못했습니다."
            return
        }
        importCookies(from: browser)
    }

    private func importCookiesOnLaunchIfNeeded() {
        guard config.auto_import_cookies_on_launch else { return }
        guard let browser = installedBrowsers.first else {
            cookieImportMessage = "앱 시작 자동 쿠키 불러오기: 설치된 브라우저를 찾지 못했습니다."
            appendLog("앱 시작 자동 쿠키 불러오기 실패: 설치된 브라우저 없음")
            return
        }
        cookieImportMessage = "앱 시작 자동 쿠키 불러오기: \(browser.displayName) 확인 중…"
        appendLog("앱 시작 자동 쿠키 불러오기: \(browser.displayName)")
        importCookies(from: browser)
    }

    func markCookiesEdited() {
        guard hasStoredCookies else { return }
        recordCookieRefreshDate()
    }

    func markCookieRefreshConfirmed() {
        recordCookieRefreshDate()
        cookieImportMessage = "쿠키 갱신 시각을 저장했습니다."
        showToast("쿠키 갱신 상태를 저장했습니다")
    }

    private func recordCookieRefreshDate() {
        cookieUpdatedAt = Date()
        cookieAuthWarning = nil
        UserDefaults.standard.removeObject(forKey: Self.cookieRefreshReminderDayKey)
    }

    private func checkCookieRefreshReminder(now: Date = Date()) {
        guard hasStoredCookies, Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt, now: now) else { return }
        let today = Self.dayStamp(now)
        guard UserDefaults.standard.string(forKey: Self.cookieRefreshReminderDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.cookieRefreshReminderDayKey)
        cookieImportMessage = "이번 달 1일 이후 쿠키 갱신 기록이 없습니다. 브라우저에서 다시 가져오기를 권장합니다."
        showToast("치지직 쿠키 갱신을 권장합니다")
    }

    private func markCookieAuthFailure(context: String) {
        let now = Date()
        if let lastCookieAuthWarningAt,
           now.timeIntervalSince(lastCookieAuthWarningAt) < Self.cookieAuthWarningCooldown {
            return
        }
        lastCookieAuthWarningAt = now
        let message = "\(context)에서 인증 실패가 감지되었습니다. 치지직 로그인 쿠키를 다시 가져오세요."
        cookieAuthWarning = message
        cookieImportMessage = message
        appendLog("쿠키 인증 실패 감지: \(context)")
        showToast("치지직 쿠키 갱신이 필요합니다")
    }

    private func handleCookieAuthFailureIfNeeded(_ error: Error, context: String) {
        if Self.isCookieAuthError(error) {
            markCookieAuthFailure(context: context)
        }
    }

    private func handleCookieAuthFailureIfNeeded(_ message: String, context: String) {
        if ChzzkAPI.looksLikeAuthFailure(message) {
            markCookieAuthFailure(context: context)
        }
    }

    private static func isCookieAuthError(_ error: Error) -> Bool {
        if let vodError = error as? VODError {
            switch vodError {
            case .invalidCookies:
                return true
            case .http(let code):
                return ChzzkAPI.isAuthFailureStatus(code)
            default:
                return false
            }
        }
        return ChzzkAPI.looksLikeAuthFailure(error.localizedDescription)
    }

    private static func dayStamp(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    nonisolated static func cookieNeedsMonthlyRefresh(
        updatedAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let updatedAt else { return true }
        let updated = calendar.dateComponents([.era, .year, .month], from: updatedAt)
        let current = calendar.dateComponents([.era, .year, .month], from: now)
        return updated.era != current.era
            || updated.year != current.year
            || updated.month != current.month
    }

    nonisolated static func daysUntilNextCookieRefreshMonth(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        let startOfToday = calendar.startOfDay(for: now)
        var components = calendar.dateComponents([.era, .year, .month], from: startOfToday)
        components.day = 1
        guard let startOfMonth = calendar.date(from: components),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) else {
            return nil
        }
        return calendar.dateComponents([.day], from: startOfToday, to: nextMonth).day
    }

    nonisolated static func shouldNudgeArmedRecording(isLive: Bool, isArmed: Bool, isWriting: Bool) -> Bool {
        isLive && isArmed && !isWriting
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

    var hasActiveWork: Bool {
        !recordingChannels.isEmpty || vodItems.contains(where: Self.isWorkingVOD)
    }

    func confirmQuitIfNeeded() -> Bool {
        guard hasActiveWork else { return true }

        let recording = recordingChannels.count
        let vod = vodItems.filter(Self.isWorkingVOD).count
        var parts: [String] = []
        if recording > 0 { parts.append("녹화/감시 \(recording)개") }
        if vod > 0 { parts.append("VOD \(vod)개") }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "진행 중인 작업을 중지하고 종료할까요?"
        alert.informativeText = "\(parts.joined(separator: ", "))가 진행 중입니다. 종료하면 진행 중인 녹화와 다운로드가 중지됩니다."
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func prepareForTermination() {
        livePoll?.cancel()
        schedulerTask?.cancel()
        toastTask?.cancel()

        for item in vodItems where Self.isWorkingVOD(item) {
            vodDownloader.cancel(item: item)
        }
        engine.terminateAll()
        // Keep config.armed_channels intact so monitoring resumes next launch;
        // clearing the in-memory set here must not wipe the persisted list.
        suppressArmedPersist = true
        recordingChannels.removeAll()
        oneShotRecordingChannels.removeAll()
        suppressArmedPersist = false
        progress.removeAll()
        refreshActivityAssertion()
        flushConfigSave()
    }

    private static func isWorkingVOD(_ item: VODItem) -> Bool {
        if case .fetching = item.state { return true }
        if case .downloading = item.state { return true }
        return false
    }

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

    // MARK: cookie import

    func importCookies(from browser: Browser) {
        cookieImportMessage = "\(browser.displayName)에서 쿠키 가져오는 중…"
        Task {
            do {
                let imported = try await Task.detached { try CookieImporter.importCookies(browser) }.value
                if let aut = imported.aut, !aut.isEmpty { config.cookies.NID_AUT = aut }
                if let ses = imported.ses, !ses.isEmpty { config.cookies.NID_SES = ses }
                if hasStoredCookies { recordCookieRefreshDate() }
                cookieImportMessage = "\(browser.displayName)에서 쿠키를 가져왔습니다."
                appendLog("\(browser.displayName)에서 치지직 쿠키를 가져왔습니다.")
            } catch let error as CookieImportError {
                if case .needsFullDiskAccess = error { fullDiskAccessNeeded = true }
                cookieImportMessage = error.localizedDescription
                appendLog("쿠키 가져오기 실패(\(browser.displayName)): \(error.localizedDescription)")
            } catch {
                cookieImportMessage = error.localizedDescription
                appendLog("쿠키 가져오기 실패(\(browser.displayName)): \(error.localizedDescription)")
            }
        }
    }

    /// Import NID_AUT / NID_SES from a Netscape cookies.txt file.
    func importCookiesFromFile(_ url: URL) {
        do {
            let imported = try CookieImporter.importFromNetscapeFile(url)
            if let aut = imported.aut, !aut.isEmpty { config.cookies.NID_AUT = aut }
            if let ses = imported.ses, !ses.isEmpty { config.cookies.NID_SES = ses }
            if hasStoredCookies { recordCookieRefreshDate() }
            cookieImportMessage = "쿠키 파일에서 가져왔습니다."
            appendLog("쿠키 파일에서 치지직 쿠키를 가져왔습니다.")
        } catch {
            cookieImportMessage = error.localizedDescription
            appendLog("쿠키 파일 가져오기 실패: \(error.localizedDescription)")
        }
    }

    var installedBrowsers: [Browser] { Browser.allCases.filter(\.isInstalled) }

    // MARK: scheduled recording

    private var schedulerTask: Task<Void, Never>?

    private func startScheduler() {
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
                    tagFilter: [String] = []) -> ChannelEditResult {
        let cid = id.trimmingCharacters(in: .whitespaces)
        guard Validate.matches(Validate.safeChannelID, cid) else { return .invalidID }
        guard !config.channels.contains(where: { $0.id == cid }) else { return .duplicateID }
        config.channels.append(Channel(
            id: cid, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? cid : name.trimmingCharacters(in: .whitespaces),
            output_dir: Validate.normalizeRecordingOutputDir(outputDir),
            quality: quality,
            tag_filter: tagFilter))
        return .ok
    }

    /// Edits an existing channel (identified by its current ID). Rejects a new ID
    /// that collides with a *different* channel.
    func updateChannel(
        originalID: String, id: String, name: String, outputDir: String,
        quality: String = Defaults.liveQuality, tagFilter: [String] = []
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

    // MARK: logging

    /// Coalesces rapid edits (e.g. typing in a settings field) into one disk write,
    /// performed off the main thread, instead of re-encoding config.json per keystroke.
    private func scheduleConfigSave() {
        configSaveTask?.cancel()
        let snapshot = config
        configSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            ConfigStore.save(snapshot)
        }
    }

    func flushConfigSave() {
        configSaveTask?.cancel()
        configSaveTask = nil
        ConfigStore.save(config)
    }

    func appendLog(_ line: String) {
        let stamped = "\(Self.timestamp()) - \(line)"
        logLines.append(stamped)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        if config.log_enabled { logStore.write(stamped) }
    }

    /// Filename-safe clip duration suffix, e.g. " (37s)".
    private func clipRangeSuffix(start: Double?, end: Double?) -> String {
        guard let start, let end, end > start else { return "" }
        let seconds = Int(max(1, ceil(end - start)))
        return " (\(seconds)s)"
    }

    private func upsertProgress(_ p: ChannelProgress) {
        if let i = progress.firstIndex(where: { $0.id == p.id }) {
            progress[i] = p
        } else {
            progress.append(p)
        }
    }

    nonisolated static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
