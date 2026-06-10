import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct VODView: View {
    @Environment(AppModel.self) private var model
    @State private var urlInput = ""
    @State private var showOptions = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("치지직 영상/클립 URL (chzzk.naver.com/video/… 또는 /clips/…)", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: urlInput) { _, newValue in
                        guard newValue.count > ChzzkVODAPI.maxPageURLLength else { return }
                        urlInput = String(newValue.prefix(ChzzkVODAPI.maxPageURLLength))
                        model.showToast("URL은 \(ChzzkVODAPI.maxPageURLLength)자까지만 입력할 수 있습니다")
                    }
                Button("추가", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddURL(urlInput))
            }
            .padding([.horizontal, .top], 20)

            content
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .background(Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(Label("여기에 링크를 놓아 추가", systemImage: "bolt.fill")
                                .font(.headline).foregroundStyle(Color.brand))
                            .padding(12)
                    }
                }
        }
        .navigationTitle("VOD 다운로드")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showOptions.toggle() } label: { Label("옵션", systemImage: "slider.horizontal.3") }
                    .help("다운로드 옵션")
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) { optionsPopover }
            }
        }
        .onDrop(of: [.url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
    }

    @ViewBuilder private var content: some View {
        if model.vodItems.isEmpty {
            ContentUnavailableView(
                "다운로드 항목 없음", systemImage: "bolt.circle",
                description: Text("URL을 붙여넣어 추가하거나, 영상 링크를 이 영역으로 끌어다 놓으세요."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.vodItems) { VODCard(item: $0) }
                }
                .padding(20)
            }
        }
    }

    // MARK: options popover (progressive disclosure)

    @ViewBuilder private var optionsPopover: some View {
        @Bindable var model = model
        Form {
            Section("저장") {
                LabeledContent("저장 위치") {
                    HStack {
                        Text(model.vodOutputDir).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("변경") { pickFolder() }
                    }
                }
            }

            VODDownloadSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }

    // MARK: actions

    private func add() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard url.count <= ChzzkVODAPI.maxPageURLLength else {
            model.showToast("URL은 \(ChzzkVODAPI.maxPageURLLength)자까지만 입력할 수 있습니다")
            return
        }
        if model.addVOD(urlString: url) {
            model.showToast("추가됨")
            urlInput = ""
        } else {
            model.showToast("치지직 영상 URL이 아닙니다")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in addDropped(url.absoluteString) } }
                }
                return true
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text { Task { @MainActor in addDropped(text) } }
                }
                return true
            }
        }
        return false
    }

    private func addDropped(_ string: String) {
        let url = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.count > ChzzkVODAPI.maxPageURLLength {
            model.showToast("URL은 \(ChzzkVODAPI.maxPageURLLength)자까지만 입력할 수 있습니다")
        } else if model.addVOD(urlString: url) {
            model.showToast("추가됨")
        } else {
            model.showToast("치지직 영상 URL이 아닙니다")
        }
    }

    private func canAddURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= ChzzkVODAPI.maxPageURLLength
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.vodOutputDir = url.path }
    }
}

struct VODCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Bindable var item: VODItem
    @State private var previewURL: URL?

    /// Picker selection: a quality value, or -1 for audio-only.
    private var qualitySelection: Binding<Int> {
        Binding(
            get: { item.audioOnly ? -1 : (item.selectedQuality ?? item.variants.last?.quality ?? -1) },
            set: { sel in
                if sel == -1 { item.audioOnly = true }
                else { item.audioOnly = false; item.selectedQuality = sel }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? item.url : item.title)
                        .fontWeight(.medium).lineLimit(2)
                    if !item.channelName.isEmpty {
                        Text("\(item.channelName) · \(durationText)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if canRemoveFromList {
                    itemMenu
                }
            }

            content
        }
        .padding(12)
        .cardSurface()
        .quickLookPreview($previewURL)
        .contextMenu {
            if canRemoveFromList {
                removeButton
            }
        }
    }

    private func openClipPicker() {
        model.clipTargets[item.id] = item
        openWindow(id: "clipPicker", value: item.id)
    }

    private var canRemoveFromList: Bool {
        item.state.canRemoveFromVODList
    }

    private var itemMenu: some View {
        Menu {
            removeButton
        } label: {
            Label("추가 작업", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help("추가 작업")
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            model.removeVOD(item)
        } label: {
            Label("목록에서 제거", systemImage: "trash")
        }
    }

    @ViewBuilder private var content: some View {
        switch item.state {
        case .fetching:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("정보 불러오는 중…").font(.caption) }

        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("화질", selection: qualitySelection) {
                        ForEach(item.variants) { v in Text(v.label).tag(v.quality) }
                        Divider()
                        Text("오디오만 (m4a)").tag(-1)
                    }
                    .frame(width: 150)
                    Button { openClipPicker() } label: {
                        Label(item.hasClip ? "구간 변경" : "구간 선택", systemImage: "scissors")
                    }
                    .controlSize(.small)
                    Spacer()
                    Button { model.startVOD(item) } label: { Label("다운로드", systemImage: "bolt.fill") }
                        .buttonStyle(.borderedProminent)
                }
                if item.hasClip, let s = item.clipStart, let e = item.clipEnd {
                    HStack(spacing: 6) {
                        Image(systemName: "scissors").foregroundStyle(Color.brand)
                        Text("구간 \(hms(s)) ~ \(hms(e))  (길이 \(hms(e - s)))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button("해제") { item.clipStart = nil; item.clipEnd = nil }
                            .controlSize(.mini).buttonStyle(.borderless)
                    }
                }
            }

        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                if isPreparingDownload {
                    ProgressView()
                } else {
                    ProgressView(value: item.percent)
                }
                HStack {
                    Text(progressText)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("취소") { model.cancelVOD(item) }.controlSize(.small)
                }
            }

        case .completed:
            HStack {
                Label("완료", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Spacer()
                if let path = item.outputPath {
                    let url = URL(fileURLWithPath: path)
                    Button { previewURL = url } label: { Image(systemName: "eye") }
                        .controlSize(.small).buttonStyle(.borderless).help("미리보기 (Quick Look)")
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .controlSize(.small).help("공유")
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }.controlSize(.small)
                }
            }

        case .failed(let msg):
            HStack {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption).lineLimit(2)
                Spacer()
                if !item.variants.isEmpty {
                    Button("다시 시도") { model.startVOD(item) }.controlSize(.small)
                }
            }

        case .canceled:
            HStack {
                Text("취소됨").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !item.variants.isEmpty {
                    Button("다시 시도") { model.startVOD(item) }.controlSize(.small)
                }
            }
        }
    }

    private var durationText: String {
        // For a clip, show the selected segment length instead of the full video
        // duration. (Display only — the download engine is untouched.)
        if item.hasClip, let start = item.clipStart, let end = item.clipEnd, end > start {
            return "구간 " + hms(end - start)
        }
        let d = item.durationSeconds
        let h = d / 3600, m = (d % 3600) / 60, s = d % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var isPreparingDownload: Bool {
        item.percent <= 0 && item.speedText.isEmpty
    }

    private var progressText: String {
        if isPreparingDownload {
            return item.sizeText.isEmpty || item.sizeText == "N/A" ? "다운로드 준비중…" : item.sizeText
        }
        return "\(Int(item.percent * 100))% · \(item.sizeText) · \(item.speedText)"
    }

    private func hms(_ sec: Double) -> String {
        let t = Int(max(0, sec).rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
