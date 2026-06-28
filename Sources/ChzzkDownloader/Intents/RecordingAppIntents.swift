import AppIntents
import Foundation

// Exposes the app's recording actions to Siri, Spotlight, the Shortcuts app and
// Apple Intelligence via App Intents. The app does not embed any AI — these are
// thin adapters over existing AppModel methods. Recording intents open the app
// (openAppWhenRun) because recording spawns streamlink/ffmpeg in the app process;
// the live-status query runs standalone so it works even when the app is closed.

enum RecordingIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case channelNotFound
    case invalidAddress

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "앱을 준비하지 못했습니다. 잠시 후 다시 시도하세요."
        case .channelNotFound: return "해당 채널을 찾을 수 없습니다."
        case .invalidAddress: return "채널/영상 주소를 인식할 수 없습니다."
        }
    }
}

// MARK: - Channel entity (resolves a spoken/typed channel to a registered one)

struct ChannelEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "채널" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = ChannelEntityQuery()
}

struct ChannelEntityQuery: EntityQuery, EntityStringQuery {
    /// Registered (non-ephemeral) channels, read from disk so parameter resolution
    /// works even before the app is running.
    private func registered() -> [ChannelEntity] {
        ConfigStore.load().channels
            .filter { !$0.ephemeral }
            .map { ChannelEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        registered().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        registered()
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        let q = string.lowercased()
        return registered().filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }
}

// MARK: - Record / stop / save

struct RecordChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "채널 녹화"
    static var description = IntentDescription("선택한 채널이 방송을 시작하면 녹화합니다.")
    static var openAppWhenRun = true

    @Parameter(title: "채널") var channel: ChannelEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = channel.id, name = channel.name
        let dialog: String = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            guard let ch = model.config.channels.first(where: { $0.id == id }) else {
                throw RecordingIntentError.channelNotFound
            }
            model.startRecording(ch)
            return "\(name) 녹화를 시작합니다."
        }
        return .result(dialog: "\(dialog)")
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "녹화 중지"
    static var description = IntentDescription("특정 채널, 또는 진행 중인 모든 녹화를 중지합니다.")
    static var openAppWhenRun = true

    @Parameter(title: "채널 (비우면 전체)") var channel: ChannelEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = channel?.id, name = channel?.name
        let dialog: String = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            if let id {
                guard let ch = model.config.channels.first(where: { $0.id == id }) else {
                    throw RecordingIntentError.channelNotFound
                }
                model.stopRecording(ch)
                return "\(name ?? id) 녹화를 중지했습니다."
            }
            let active = model.config.channels.filter { model.isRecording($0.id) }
            for ch in active { model.stopRecording(ch) }
            return active.isEmpty ? "진행 중인 녹화가 없습니다." : "\(active.count)개 녹화를 중지했습니다."
        }
        return .result(dialog: "\(dialog)")
    }
}

struct QuickRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "이번 방송만 녹화"
    static var description = IntentDescription("채널을 등록하지 않고 이번 방송만 녹화합니다.")
    static var openAppWhenRun = true

    @Parameter(title: "채널 주소 또는 ID") var channel: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let query = channel
        let ok: Bool = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            return model.startQuickRecord(urlString: query)
        }
        guard ok else { throw RecordingIntentError.invalidAddress }
        return .result(dialog: "이번 방송만 녹화를 시작합니다.")
    }
}

struct SaveNowIntent: AppIntent {
    static var title: LocalizedStringResource = "지금까지 저장"
    static var description = IntentDescription("진행 중인 녹화를 지금까지 파일로 저장하고 계속 녹화합니다.")
    static var openAppWhenRun = true

    @Parameter(title: "채널") var channel: ChannelEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = channel.id, name = channel.name
        let dialog: String = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            guard let ch = model.config.channels.first(where: { $0.id == id }) else {
                throw RecordingIntentError.channelNotFound
            }
            guard model.isWritingRecording(ch.id) else { return "\(name)은(는) 지금 녹화 중이 아닙니다." }
            model.saveNow(ch)
            return "\(name) 지금까지 녹화를 저장합니다."
        }
        return .result(dialog: "\(dialog)")
    }
}

// MARK: - Batch / query

struct RecordAllLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "라이브 채널 모두 녹화"
    static var description = IntentDescription("지금 방송 중인 등록 채널을 모두 녹화합니다.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started: Int = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            var count = 0
            for ch in model.config.channels where !ch.ephemeral {
                if model.liveStatus[ch.id]?.isLive == true, !model.isRecording(ch.id) {
                    model.startRecording(ch)
                    count += 1
                }
            }
            return count
        }
        return .result(dialog: started > 0
                       ? "\(started)개 라이브 채널 녹화를 시작합니다."
                       : "지금 녹화할 라이브 채널이 없습니다.")
    }
}

struct WhatsLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "지금 라이브 중인 채널"
    static var description = IntentDescription("등록한 채널 중 지금 방송 중인 채널을 알려줍니다.")

    func perform() async throws -> some IntentResult & ReturnsValue<[ChannelEntity]> & ProvidesDialog {
        let config = ConfigStore.load()
        let channels = config.channels.filter { !$0.ephemeral }
        guard !channels.isEmpty else {
            return .result(value: [], dialog: "등록된 채널이 없습니다.")
        }
        let cookies = config.cookies
        var live: [ChannelEntity] = []
        await withTaskGroup(of: ChannelEntity?.self) { group in
            for ch in channels {
                group.addTask {
                    guard case .info(let info?) = await ChzzkAPI.fetchLiveInfoResult(channelID: ch.id, cookies: cookies),
                          info.status == "OPEN" else { return nil }
                    let name = info.channelName.isEmpty ? ch.name : info.channelName
                    return ChannelEntity(id: ch.id, name: name)
                }
            }
            for await entity in group { if let entity { live.append(entity) } }
        }
        guard !live.isEmpty else {
            return .result(value: [], dialog: "지금 라이브 중인 채널이 없습니다.")
        }
        let names = live.map(\.name).joined(separator: ", ")
        return .result(value: live, dialog: "\(live.count)개 채널이 라이브 중입니다. \(names).")
    }
}

// MARK: - Schedule / VOD

struct ScheduleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "녹화 예약"
    static var description = IntentDescription("채널을 지정한 시각에 녹화하도록 예약합니다.")
    static var openAppWhenRun = true

    @Parameter(title: "채널") var channel: ChannelEntity
    @Parameter(title: "시작 시각") var date: Date
    @Parameter(title: "녹화 길이(분, 0=방송 끝까지)", default: 0) var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = channel.id, name = channel.name, start = date, mins = max(0, minutes)
        let dialog: String = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            guard model.config.channels.contains(where: { $0.id == id && !$0.ephemeral }) else {
                throw RecordingIntentError.channelNotFound
            }
            model.addSchedule(channelID: id, start: start, durationMinutes: mins)
            return "\(name) 녹화를 예약했습니다."
        }
        return .result(dialog: "\(dialog)")
    }
}

struct DownloadVODIntent: AppIntent {
    static var title: LocalizedStringResource = "VOD 다운로드"
    static var description = IntentDescription("치지직 영상/클립 주소를 다운로드합니다.")
    static var openAppWhenRun = true

    @Parameter(title: "영상/클립 주소") var url: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let address = url
        let ok: Bool = try await MainActor.run {
            guard let model = AppModel.shared else { throw RecordingIntentError.appNotReady }
            return model.addVOD(urlString: address, autoStart: true)
        }
        guard ok else { throw RecordingIntentError.invalidAddress }
        return .result(dialog: "VOD 다운로드를 시작합니다.")
    }
}

// MARK: - Spoken phrases (Siri / Apple Intelligence)

struct ChzzkAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordChannelIntent(),
            phrases: [
                "\(.applicationName)에서 \(\.$channel) 녹화",
                "\(.applicationName) \(\.$channel) 녹화해줘",
            ],
            shortTitle: "채널 녹화",
            systemImageName: "record.circle")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "\(.applicationName) 녹화 중지",
                "\(.applicationName) 녹화 멈춰",
            ],
            shortTitle: "녹화 중지",
            systemImageName: "stop.circle")
        AppShortcut(
            intent: WhatsLiveIntent(),
            phrases: [
                "\(.applicationName)에서 지금 라이브 중인 채널",
                "\(.applicationName) 지금 방송 중인 채널 알려줘",
            ],
            shortTitle: "지금 라이브",
            systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(
            intent: RecordAllLiveIntent(),
            phrases: [
                "\(.applicationName) 라이브 채널 모두 녹화",
                "\(.applicationName)에서 방송 중인 채널 다 녹화해줘",
            ],
            shortTitle: "라이브 모두 녹화",
            systemImageName: "rectangle.stack.badge.record")
    }
}
