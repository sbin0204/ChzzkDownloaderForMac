import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var quickURL = ""
    @AppStorage("dashboardLiveLayout") private var liveLayoutRaw = "list"
    private static let visibleLogLineLimit = 120

    private var latestLogLines: [(offset: Int, element: String)] {
        Array(model.logLines.enumerated().suffix(Self.visibleLogLineLimit).reversed())
    }
    private var logSectionDetail: String {
        "최근 \(min(model.logLines.count, Self.visibleLogLineLimit))줄"
    }

    var body: some View {
        FadingScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusSummary

                if !model.toolsAvailable { toolWarning }

                quickRecordBar

                liveSection

                progressSection

                logSection
            }
            .pageContentPadding()
        }
        .background(.background)
        .navigationTitle("대시보드")
    }

    // MARK: status summary — one box: state + the four counts

    private var statusSummary: some View {
        let recording = model.recordingChannels
        let writingIDs = Set(model.progress.map(\.id))
        let nRec = recording.intersection(writingIDs).count     // actively saving
        let nArm = recording.count - nRec                       // armed, waiting for live
        let active = !recording.isEmpty
        let registered = model.config.channels.filter { !$0.ephemeral }.count
        let liveCount = model.config.channels.filter { model.liveStatus[$0.id]?.isLive ?? false }.count

        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: active ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(active ? Color.onAir : Color.brand)
                    .frame(width: 44, height: 44)
                    .background((active ? Color.onAir : Color.brand).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    // A one-word state; the exact counts live in the row below, so
                    // this stays a scannable headline rather than repeating numbers.
                    Text(AppLocalization.string(nRec > 0 ? "녹화 중" : (nArm > 0 ? "감시 중" : "대기 중")))
                        .font(.title2).fontWeight(.semibold)
                    Text(AppLocalization.string(active
                         ? "녹화는 아래 ‘현재 라이브’에서 채널별로 제어합니다."
                         : "아래 ‘현재 라이브’에서 채널을 선택해 녹화를 시작하세요."))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
            }

            Divider()

            HStack(spacing: 0) {
                metricItem("등록", registered, "person.2", .secondary)
                metricSeparator
                metricItem("라이브", liveCount, "dot.radiowaves.left.and.right", liveCount > 0 ? .onAir : .secondary)
                metricSeparator
                metricItem("녹화", nRec, "record.circle", nRec > 0 ? .onAir : .secondary)
                metricSeparator
                metricItem("감시", nArm, "eye", nArm > 0 ? .orange : .secondary)
            }
        }
        .padding(18)
        .cardSurface()
    }

    private func metricItem(_ label: String, _ value: Int, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)").font(.title3.monospacedDigit()).fontWeight(.semibold).foregroundStyle(tint)
            Label(AppLocalization.string(label), systemImage: icon)
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricSeparator: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 30)
    }

    // MARK: live channels — the single recording control

    @ViewBuilder private var liveSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppLocalization.string("현재 라이브")).font(.headline)
            Spacer()
            if !model.config.channels.isEmpty {
                Picker("", selection: $liveLayoutRaw) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(AppLocalization.string("목록 / 격자 보기 전환"))
            }
        }
        if model.config.channels.isEmpty {
            Text(AppLocalization.string("‘채널’에서 채널을 추가하면 여기에 라이브 상태가 표시됩니다."))
                .font(.callout).foregroundStyle(.secondary)
        } else if liveLayoutRaw == "grid" {
            liveGrid
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
            .animation(.default, value: model.config.channels.map(\.id))
            .animation(.default, value: model.recordingChannels)
        }
    }

    private var liveGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(model.config.channels) { liveCard($0) }
        }
        .animation(.default, value: model.config.channels.map(\.id))
        .animation(.default, value: model.recordingChannels)
    }

    @ViewBuilder private func liveRow(_ ch: Channel) -> some View {
        let status = model.liveStatus[ch.id]
        let isLive = status?.isLive ?? false
        let isRecording = model.isRecording(ch.id)
        let isWriting = model.progress.contains { $0.id == ch.id }
        HStack(spacing: 11) {
            thumbnail(status, width: 64, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(ch.name).fontWeight(.medium)
                Text(liveStatusText(isLive: isLive, title: status?.title))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if isLive, let status, let meta = liveMetaText(status) {
                    meta.font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)

            // Fixed-width status + button so rows align regardless of state.
            monitorStatus(isRecording: isRecording, isWriting: isWriting, isOneShot: model.isOneShot(ch.id))
                .frame(width: 72, alignment: .trailing)
            recordControls(ch, isRecording: isRecording, isWriting: isWriting)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 6)
    }

    @ViewBuilder private func liveCard(_ ch: Channel) -> some View {
        let status = model.liveStatus[ch.id]
        let isLive = status?.isLive ?? false
        let isRecording = model.isRecording(ch.id)
        let isWriting = model.progress.contains { $0.id == ch.id }
        // Every line is fixed to one line (and the meta line is always reserved,
        // even when empty) so all grid cards are exactly the same height.
        let meta = (isLive ? status.flatMap(liveMetaText) : nil) ?? Text(" ")
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                thumbnail(status, width: nil, height: 116)
                if isLive { LiveDot().padding(7) }
            }
            Text(ch.name).fontWeight(.medium).lineLimit(1)
            Text(liveStatusText(isLive: isLive, title: status?.title))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            meta.font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 6) {
                monitorStatus(isRecording: isRecording, isWriting: isWriting, isOneShot: model.isOneShot(ch.id))
                Spacer(minLength: 4)
                recordControls(ch, isRecording: isRecording, isWriting: isWriting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .hoverHighlight(cornerRadius: 8)
        .cardSurface()
    }

    @ViewBuilder private func recordControls(_ ch: Channel, isRecording: Bool, isWriting: Bool) -> some View {
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

    /// Thumbnail of the current live frame; a placeholder while offline or loading.
    /// `width == nil` fills the available width (grid cards).
    @ViewBuilder private func thumbnail(_ status: LiveSnapshot?, width: CGFloat?, height: CGFloat) -> some View {
        let urlString = status?.thumbnailURL ?? ""
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                if let url = URL(string: urlString), !urlString.isEmpty {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "tv").foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Image(systemName: (status?.isLive ?? false) ? "tv" : "tv.slash")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Live meta line as a single Text: "􀋭 1,234 · 2시간 13분 · 카테고리 #태그".
    /// Built with Text so the viewer-count uses the SF Symbol `eye` inline rather
    /// than an emoji. Returns nil when there is nothing to show.
    private func liveMetaText(_ status: LiveSnapshot) -> Text? {
        var pieces: [Text] = []
        if status.viewerCount > 0 {
            let n = NumberFormatter.localizedString(from: NSNumber(value: status.viewerCount), number: .decimal)
            pieces.append(Text(Image(systemName: "eye")) + Text(" \(n)"))
        }
        let up = Self.uptimeText(status.openDate)
        if !up.isEmpty { pieces.append(Text(up)) }
        let catTag = categoryTagLine(category: status.category, tags: status.tags)
        if !catTag.isEmpty { pieces.append(Text(catTag)) }
        guard var line = pieces.first else { return nil }
        for piece in pieces.dropFirst() { line = line + Text(" · ") + piece }
        return line
    }

    /// Broadcast uptime from the KST openDate ("yyyy-MM-dd HH:mm:ss").
    private static func uptimeText(_ openDate: String) -> String {
        guard !openDate.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        guard let start = formatter.date(from: openDate) else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분"
    }

    /// "카테고리 · #태그1 #태그2" — empty parts are omitted.
    private func categoryTagLine(category: String, tags: [String]) -> String {
        var parts: [String] = []
        if !category.isEmpty { parts.append(category) }
        if !tags.isEmpty { parts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private func liveStatusText(isLive: Bool, title: String?) -> String {
        guard isLive else { return AppLocalization.string("오프라인") }
        guard let title, !title.isEmpty else { return AppLocalization.string("방송 중") }
        return title
    }

    /// Shows whether monitoring is off / armed (watching for live) / actively recording.
    @ViewBuilder private func monitorStatus(isRecording: Bool, isWriting: Bool, isOneShot: Bool) -> some View {
        if isWriting {
            HStack(spacing: 4) {
                Circle().fill(Color.onAir).frame(width: 6, height: 6)
                Text(AppLocalization.string(isOneShot ? "1회 녹화" : "녹화 중"))
            }
            .font(.caption).foregroundStyle(Color.onAir)
        } else if isRecording {
            Text(AppLocalization.string(isOneShot ? "1회 대기" : "감시 중"))
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text(AppLocalization.string("감시 꺼짐")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: quick record — record one broadcast without registering a channel

    private var quickRecordBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill").foregroundStyle(Color.brand)
                TextField(AppLocalization.string("채널 주소로 이번 방송만 빠르게 녹화"), text: $quickURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startQuickRecord)
                Button(AppLocalization.string("이번 방송만 녹화"), action: startQuickRecord)
                    .disabled(Validate.extractChannelID(quickURL).isEmpty)
            }
            Text(AppLocalization.string("채널로 등록하지 않고 이번 방송만 받습니다. 방송이 끝나면 자동으로 정리됩니다."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .cardSurface()
    }

    private func startQuickRecord() {
        let value = quickURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if model.startQuickRecord(urlString: value) {
            quickURL = ""
        } else {
            model.showToast(AppLocalization.string("채널 주소를 인식할 수 없습니다"))
        }
    }

    // MARK: recording progress

    @ViewBuilder private var progressSection: some View {
        SectionTitle(title: "녹화 진행 상황")
        if model.progress.isEmpty {
            Text(AppLocalization.string("진행 중인 녹화가 없습니다."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            // Deliberately minimal: ordinary users only need "is it recording?"
            // and "how long / how big". Bitrate, download speed, and start time
            // are omitted as technical noise.
            VStack(spacing: 8) {
                ForEach(model.progress) { p in
                    HStack(spacing: 10) {
                        Circle().fill(Color.onAir).frame(width: 8, height: 8)
                        Text(p.channelName).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(Self.elapsedText(p.outTime))
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(p.totalSize)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.vertical, 9)
                    .padding(.horizontal, 13)
                    .cardSurface()
                }
            }
        }
    }

    /// "00:12:34.50" -> "00:12:34"; drops ffmpeg's fractional seconds for a clean
    /// elapsed display.
    private static func elapsedText(_ raw: String) -> String {
        let base = raw.split(separator: ".").first.map(String.init) ?? raw
        return base.isEmpty ? "00:00:00" : base
    }

    // MARK: logs (secondary, a native console well)

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "로그", detail: logSectionDetail)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(latestLogLines, id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .frame(minHeight: 140, maxHeight: 240)
        }
    }

    // MARK: helpers

    private var toolWarning: some View {
        let missing = [model.ffmpegPath == nil ? "ffmpeg" : nil,
                       model.streamlinkPath == nil ? "streamlink" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        let command = "brew install ffmpeg streamlink"
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                AppLocalization.pick(
                    korean: "녹화하려면 \(missing)이(가) 필요합니다. 터미널에 아래 명령을 붙여넣어 설치하세요.",
                    english: "Recording needs \(missing). Paste this command into Terminal to install."),
                systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                Button(AppLocalization.string("복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    model.showToast(AppLocalization.string("설치 명령을 복사했습니다"))
                }
                Link(AppLocalization.string("Homebrew"), destination: URL(string: "https://brew.sh")!)
                    .font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
