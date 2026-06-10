import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusAnchor                       // dominant element / visual anchor

            if !model.toolsAvailable { toolWarning }

            liveSection

            progressSection

            logSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("대시보드")
    }

    // MARK: dominant anchor — recording status summary

    private var statusAnchor: some View {
        let recording = model.recordingChannels
        let writing = Set(model.progress.map(\.id))
        let nRec = recording.intersection(writing).count       // actively saving
        let nArm = recording.count - nRec                       // armed, waiting for live
        let active = !recording.isEmpty

        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill((active ? Color.onAir : Color.brand).opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: active
                      ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(active ? Color.onAir : Color.brand)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(active ? statusTitle(recording: nRec, armed: nArm) : AppLocalization.string("대기 중"))
                    .font(.title2).fontWeight(.semibold)
                Text(AppLocalization.string(active
                     ? "녹화는 아래 ‘현재 라이브’에서 채널별로 제어합니다."
                     : "아래 ‘현재 라이브’에서 채널을 선택해 녹화를 시작하세요."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background((active ? Color.onAir : Color.brand).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder((active ? Color.onAir : Color.brand).opacity(0.22), lineWidth: 1)
        )
    }

    private func statusTitle(recording: Int, armed: Int) -> String {
        if recording > 0 && armed > 0 {
            return AppLocalization.pick(
                korean: "녹화 \(recording) · 감시 \(armed)",
                english: "Recording \(recording) · watching \(armed)")
        }
        if recording > 0 {
            return AppLocalization.pick(
                korean: "\(recording)개 채널 녹화 중",
                english: "Recording \(recording) channel\(recording == 1 ? "" : "s")")
        }
        return AppLocalization.pick(
            korean: "\(armed)개 채널 감시 중",
            english: "Watching \(armed) channel\(armed == 1 ? "" : "s")")
    }

    // MARK: live channels — the single recording control

    @ViewBuilder private var liveSection: some View {
        sectionHeader("현재 라이브", trailing: "채널별로 녹화를 켜고 끕니다")
        if model.config.channels.isEmpty {
            Text(AppLocalization.string("‘채널’에서 채널을 추가하면 여기에 라이브 상태가 표시됩니다."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.config.channels.enumerated()), id: \.element.id) { idx, ch in
                    if idx > 0 { Divider() }
                    liveRow(ch)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .cardSurface()
        }
    }

    @ViewBuilder private func liveRow(_ ch: Channel) -> some View {
        let status = model.liveStatus[ch.id]
        let isLive = status?.isLive ?? false
        let isRecording = model.isRecording(ch.id)
        let isWriting = model.progress.contains { $0.id == ch.id }
        HStack(spacing: 11) {
            if isLive { LiveDot() }
            else { Circle().fill(.tertiary).frame(width: 8, height: 8) }

            VStack(alignment: .leading, spacing: 1) {
                Text(ch.name).fontWeight(.medium)
                Text(liveStatusText(isLive: isLive, title: status?.title))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)

            // Fixed-width status + button so rows align regardless of state.
            monitorStatus(isRecording: isRecording, isWriting: isWriting)
                .frame(width: 72, alignment: .trailing)
            if isWriting {
                Button(AppLocalization.string("저장")) { model.saveNow(ch) }
                    .controlSize(.small)
                    .help(AppLocalization.string("지금까지 녹화한 내용을 파일로 저장하고 계속 녹화합니다"))
            }
            Button(AppLocalization.string(isRecording ? "중지" : "녹화")) {
                isRecording ? model.stopRecording(ch) : model.startRecording(ch)
            }
            .controlSize(.small)
            .frame(width: 52)
        }
        .padding(.vertical, 8)
    }

    private func liveStatusText(isLive: Bool, title: String?) -> String {
        guard isLive else { return AppLocalization.string("오프라인") }
        guard let title, !title.isEmpty else { return AppLocalization.string("방송 중") }
        return title
    }

    /// Shows whether monitoring is off / armed (watching for live) / actively recording.
    @ViewBuilder private func monitorStatus(isRecording: Bool, isWriting: Bool) -> some View {
        if isWriting {
            HStack(spacing: 4) {
                Circle().fill(Color.onAir).frame(width: 6, height: 6)
                Text(AppLocalization.string("녹화 중"))
            }
            .font(.caption).foregroundStyle(Color.onAir)
        } else if isRecording {
            Text(AppLocalization.string("감시 중")).font(.caption).foregroundStyle(.orange)
        } else {
            Text(AppLocalization.string("감시 꺼짐")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: recording progress

    @ViewBuilder private var progressSection: some View {
        sectionHeader("녹화 진행 상황")
        if model.progress.isEmpty {
            Text(AppLocalization.string("진행 중인 녹화가 없습니다."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Table(model.progress) {
                TableColumn("채널", value: \.channelName)
                TableColumn("비트레이트", value: \.bitrate)
                TableColumn("속도", value: \.downloadSpeed)
                TableColumn("크기", value: \.totalSize)
                TableColumn("경과", value: \.outTime)
                TableColumn("시작", value: \.startTime)
            }
            .font(.callout.monospacedDigit())
            .frame(minHeight: 132)
        }
    }

    // MARK: logs (secondary, a native console well)

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("로그")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(maxHeight: .infinity)
                .onChange(of: model.logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: helpers

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppLocalization.string(title)).font(.headline)
            if let trailing {
                Spacer()
                Text(AppLocalization.string(trailing)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var toolWarning: some View {
        let missing = [model.ffmpegPath == nil ? "ffmpeg" : nil,
                       model.streamlinkPath == nil ? "streamlink" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return Label(
            AppLocalization.pick(
                korean: "필수 도구가 없습니다: \(missing). 녹화 시작 시 설치 안내가 표시됩니다.",
                english: "Missing required tools: \(missing). Installation help appears when recording starts."),
            systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
