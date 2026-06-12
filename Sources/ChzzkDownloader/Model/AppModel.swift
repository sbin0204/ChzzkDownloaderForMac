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

/// Central app state and orchestration. Split across focused files:
/// - AppModel.swift            — stored state, init, tooling, lifecycle, logging
/// - AppModel+Recording.swift  — live polling, recording control, scheduler, channels
/// - AppModel+VOD.swift        — VOD downloads and download history
/// - AppModel+Cookies.swift    — cookie status, import, auth-failure handling
///
/// Stored properties must live in this file (the class declaration); the
/// extensions only add behavior. Members are `internal` when another of the
/// model's files needs them, `private` when used in this file only.
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
    let vodDownloader = VODDownloader()
    static let cookieUpdatedAtKey = "cookieUpdatedAt"
    static let cookieRefreshReminderDayKey = "cookieRefreshReminderDay"
    static let cookieAuthWarningCooldown: TimeInterval = 60 * 60
    var lastCookieAuthWarningAt: Date?

    /// Live status of registered channels, for the dashboard's on-demand panel.
    var liveStatus: [String: (isLive: Bool, title: String, category: String, tags: [String], hasMedia: Bool)] = [:]
    var recordingChannels: Set<String> = [] {
        didSet {
            refreshActivityAssertion()
            persistArmedChannelsIfChanged(oldValue)
        }
    }
    var oneShotRecordingChannels: Set<String> = []
    /// Suppresses the recordingChannels didSet from rewriting config.armed_channels.
    /// Set during launch-time restore and during termination, so the persisted
    /// monitoring set survives a quit instead of being wiped to empty on shutdown.
    var suppressArmedPersist = false
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

    let engine = RecordingEngine()
    private let logStore = LogStore(url: ConfigStore.directory.appendingPathComponent("log.log"))

    // Long-lived background loops (started from init, canceled on termination).
    var livePoll: Task<Void, Never>?
    var schedulerTask: Task<Void, Never>?

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
        salvageOrphanRecordings()
        restoreArmedChannels()
        startLivePolling()
        startScheduler()
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
    func ensureTools(needStreamlink: Bool) -> Bool {
        let missing = missingTools(needStreamlink: needStreamlink)
        guard missing.isEmpty else {
            toolAlert = ToolAlert(missing: missing)
            appendLog("필수 도구 없음: \(missing.joined(separator: ", "))")
            return false
        }
        return true
    }

    // MARK: activity / lifecycle

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

    static func isWorkingVOD(_ item: VODItem) -> Bool {
        if case .fetching = item.state { return true }
        if case .downloading = item.state { return true }
        return false
    }

    // MARK: logging / persistence

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
