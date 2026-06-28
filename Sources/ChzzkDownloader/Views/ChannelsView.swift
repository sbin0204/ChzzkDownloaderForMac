import SwiftUI

enum ChannelSheet: Identifiable {
    case add
    case edit(Channel)
    var id: String { if case .edit(let c) = self { return "edit-\(c.id)" }; return "add" }
}

struct ChannelsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: ChannelSheet?
    @State private var search = ""
    @State private var deleteTarget: Channel?

    /// Permanently registered channels only. Ephemeral "quick record" channels are
    /// hidden — they are not registrations and disappear when their broadcast ends.
    private var registeredChannels: [Channel] { model.registeredChannels }

    private var filtered: [Channel] {
        guard !search.isEmpty else { return registeredChannels }
        return registeredChannels.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !registeredChannels.isEmpty {
                HStack {
                    SummaryTile(title: "등록 채널", value: "\(registeredChannels.count)", systemImage: "person.2")
                    SummaryTile(title: "검색 결과", value: "\(filtered.count)", systemImage: "magnifyingglass", tint: .secondary)
                }
            }

            Group {
                if registeredChannels.isEmpty {
                    ContentUnavailableView(
                        "채널 없음", systemImage: "person.2",
                        description: Text("툴바의 +, 또는 ⌘N으로 치지직 채널을 추가하세요."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FadingScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, ch in
                                if idx > 0 { Divider() }
                                ChannelRow(channel: ch, onEdit: { sheet = .edit(ch) })
                                    .hoverHighlight(cornerRadius: 6)
                                    .contextMenu {
                                        Button("편집") { sheet = .edit(ch) }
                                        Button("삭제", role: .destructive) { deleteTarget = ch }
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .cardSurface()
                        .animation(.default, value: filtered.map(\.id))
                    }
                }
            }
        }
        .pageContentPadding()
        .navigationTitle("채널")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .add } label: { Label("채널 추가", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("채널 추가 (⌘N)")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "채널 검색")
        .sheet(item: $sheet) { ChannelEditSheet(mode: $0) }
        .confirmationDialog("이 채널을 삭제할까요?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let channel = deleteTarget {
                    model.deleteChannel(id: channel.id)
                }
                deleteTarget = nil
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(channelDeleteMessage(deleteTarget))
        }
    }

    private func channelDeleteMessage(_ channel: Channel?) -> String {
        let name = channel?.name ?? channel?.id ?? ""
        let active = channel.map { model.isRecording($0.id) } ?? false
        let stopText = active ? " 현재 녹화/감시도 중지됩니다." : ""
        return "‘\(name)’ 채널이 목록에서 제거됩니다.\(stopText) 저장된 녹화 파일은 삭제되지 않습니다."
    }
}

struct ChannelRow: View {
    let channel: Channel
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).fontWeight(.medium)
                Text("id: \(channel.id)").font(.caption).foregroundStyle(.secondary)
                Text("라이브 화질: \(liveQualityLabel(channel.quality))")
                    .font(.caption2).foregroundStyle(.secondary)
                if !channel.tag_filter.isEmpty {
                    Text("녹화 태그: \(channel.tag_filter.joined(separator: ", "))"
                         + (channel.stop_on_tag_mismatch ? " (변경 시 중단)" : ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Text(channel.output_dir == "." ? "기본 저장 폴더" : channel.output_dir)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("편집", action: onEdit).controlSize(.small)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)   // double-click a row to edit
    }

    private func liveQualityLabel(_ value: String) -> String {
        switch value {
        case "best": return "최고"
        case "worst": return "최저"
        default: return value
        }
    }
}

struct ChannelEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: ChannelSheet

    @State private var id = ""
    @State private var name = ""
    @State private var outputDir = ""
    @State private var quality = Defaults.liveQuality
    @State private var tags = ""
    @State private var stopOnTagMismatch = false
    @State private var error: String?
    @State private var showDeleteConfirm = false
    @State private var channelLookupIsLoading = false
    @State private var channelLookupMessage: String?
    @State private var channelLookupFailed = false
    @State private var nameWasEdited = false
    @State private var autoFilledName: String?

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var originalID: String { if case .edit(let c) = mode { return c.id }; return "" }
    private var normalizedChannelID: String { Validate.extractChannelID(id) }
    private var canAutoFillName: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !nameWasEdited
    }
    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { newValue in
                name = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                nameWasEdited = !trimmed.isEmpty && trimmed != autoFilledName
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEdit ? "채널 편집" : "채널 추가").font(.title3).bold()

            Form {
                LabeledContent("채널") {
                    HStack(spacing: 8) {
                        TextField("채널", text: $id,
                                  prompt: Text("채널 ID 또는 주소"))
                            .textFieldStyle(.roundedBorder)
                            .help("채널 ID 또는 chzzk.naver.com 주소를 붙여넣으세요")
                        channelLookupIndicator
                    }
                }
                TextField("이름", text: nameBinding, prompt: Text("자동 입력"))
                Picker("화질", selection: $quality) {
                    Text("최고").tag("best")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                    Text("360p").tag("360p")
                    Text("최저").tag("worst")
                }
                HStack {
                    TextField("저장 폴더", text: $outputDir,
                              prompt: Text("비우면 기본 폴더에 저장"))
                    Button("찾아보기…") { browse() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    TextField("녹화 태그", text: $tags,
                              prompt: Text("쉼표로 구분, 예: 종합게임, 저챗"))
                        .help("방송 태그가 하나라도 일치할 때만 녹화합니다. 비우면 항상 녹화합니다.")
                    Toggle("태그 불일치 시 녹화 중단", isOn: $stopOnTagMismatch)
                        .font(.caption)
                        .disabled(Validate.parseTagFilter(tags).isEmpty)
                        .padding(.top, 2)
                        .help("방송 중 태그가 바뀌어 일치하지 않으면 녹화를 중단합니다.")
                }
            }

            if let error { Text(error).foregroundStyle(.red).font(.caption) }

            HStack {
                if isEdit {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("삭제", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Spacer()
                Button("취소") { dismiss() }
                Button(isEdit ? "저장" : "추가") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(Validate.extractChannelID(id).isEmpty)
            }
        }
        .confirmationDialog("이 채널을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { model.deleteChannel(id: originalID); dismiss() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(channelDeleteMessage)
        }
        .padding(18)
        .frame(width: 430)
        .onAppear {
            if case .edit(let c) = mode {
                id = c.id; name = c.name
                quality = c.quality
                outputDir = (c.output_dir == "." ? "" : c.output_dir)
                tags = c.tag_filter.joined(separator: ", ")
                stopOnTagMismatch = c.stop_on_tag_mismatch
                nameWasEdited = !c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && c.name != c.id
            }
        }
        .task(id: normalizedChannelID) {
            await lookupChannelProfileIfNeeded(for: normalizedChannelID)
        }
    }

    private func save() {
        let channelID = Validate.extractChannelID(id)
        let tagFilter = Validate.parseTagFilter(tags)
        let stopOption = stopOnTagMismatch && !tagFilter.isEmpty
        let result: AppModel.ChannelEditResult = isEdit
            ? model.updateChannel(originalID: originalID, id: channelID, name: name, outputDir: outputDir,
                                  quality: quality, tagFilter: tagFilter, stopOnTagMismatch: stopOption)
            : model.addChannel(id: channelID, name: name, outputDir: outputDir,
                               quality: quality, tagFilter: tagFilter, stopOnTagMismatch: stopOption)
        switch result {
        case .ok: dismiss()
        case .invalidID: error = "잘못된 채널 ID입니다. 영문, 숫자, '_', '-'만 사용하세요."
        case .duplicateID: error = "이미 등록된 채널 ID입니다."
        }
    }

    private var channelDeleteMessage: String {
        let active = model.isRecording(originalID)
        let stopText = active ? " 현재 녹화/감시도 중지됩니다." : ""
        return "‘\(name.isEmpty ? originalID : name)’ 채널이 목록에서 제거됩니다.\(stopText) 저장된 녹화 파일은 삭제되지 않습니다."
    }

    private func browse() {
        DirectoryPicker.chooseRecordingDirectory(initialPath: outputDir) { selectedPath in
            outputDir = selectedPath
        }
    }

    @ViewBuilder
    private var channelLookupIndicator: some View {
        if channelLookupIsLoading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18)
                .help("채널 확인 중")
        } else if let channelLookupMessage {
            Image(systemName: channelLookupFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(channelLookupFailed ? .orange : .secondary)
                .frame(width: 18)
                .help(channelLookupMessage)
        }
    }

    @MainActor
    private func lookupChannelProfileIfNeeded(for channelID: String) async {
        channelLookupMessage = nil
        channelLookupFailed = false

        guard Validate.matches(Validate.safeChannelID, channelID) else {
            channelLookupIsLoading = false
            return
        }
        guard !isEdit || channelID != originalID || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            channelLookupIsLoading = false
            return
        }

        channelLookupIsLoading = true
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }

        let profile = await ChzzkAPI.fetchChannelProfile(channelID: channelID)
        guard !Task.isCancelled else { return }

        channelLookupIsLoading = false
        guard let profile else {
            channelLookupFailed = true
            channelLookupMessage = "채널을 찾지 못했습니다."
            return
        }

        if canAutoFillName {
            name = profile.channelName
            autoFilledName = profile.channelName
            nameWasEdited = false
            channelLookupMessage = profile.channelName
        } else {
            channelLookupMessage = profile.channelName
        }
    }
}
