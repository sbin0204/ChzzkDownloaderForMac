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

    private var filtered: [Channel] {
        guard !search.isEmpty else { return model.config.channels }
        return model.config.channels.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if model.config.channels.isEmpty {
                ContentUnavailableView(
                    "채널 없음", systemImage: "person.2",
                    description: Text("툴바의 +, 또는 ⌘N으로 치지직 채널을 추가하세요."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { ch in
                        ChannelRow(channel: ch, onEdit: { sheet = .edit(ch) })
                            .contextMenu {
                                Button("편집") { sheet = .edit(ch) }
                                Button("삭제", role: .destructive) { deleteTarget = ch }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
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
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
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

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var originalID: String { if case .edit(let c) = mode { return c.id }; return "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "채널 편집" : "채널 추가").font(.title3).bold()

            Form {
                TextField("채널 ID", text: $id,
                          prompt: Text("예: chzzk.naver.com/abc1234 의 abc1234"))
                TextField("이름 (선택)", text: $name)
                Picker("라이브 녹화 화질", selection: $quality) {
                    Text("최고").tag("best")
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("480p").tag("480p")
                    Text("360p").tag("360p")
                    Text("최저").tag("worst")
                }
                HStack {
                    TextField("저장 폴더 (선택)", text: $outputDir,
                              prompt: Text("비우면 기본 폴더에 저장"))
                    Button("찾아보기…") { browse() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    TextField("녹화 태그 (선택)", text: $tags,
                              prompt: Text("쉼표로 구분, 예: 종합게임, 저챗"))
                    Text("입력하면 방송 태그가 하나라도 일치할 때만 녹화합니다. 비우면 항상 녹화합니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("방송 중 태그가 바뀌어 일치하지 않으면 녹화 중단", isOn: $stopOnTagMismatch)
                        .font(.caption)
                        .disabled(Validate.parseTagFilter(tags).isEmpty)
                        .padding(.top, 4)
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
                    .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("이 채널을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { model.deleteChannel(id: originalID); dismiss() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(channelDeleteMessage)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if case .edit(let c) = mode {
                id = c.id; name = c.name
                quality = c.quality
                outputDir = (c.output_dir == "." ? "" : c.output_dir)
                tags = c.tag_filter.joined(separator: ", ")
                stopOnTagMismatch = c.stop_on_tag_mismatch
            }
        }
    }

    private func save() {
        let tagFilter = Validate.parseTagFilter(tags)
        let stopOption = stopOnTagMismatch && !tagFilter.isEmpty
        let result: AppModel.ChannelEditResult = isEdit
            ? model.updateChannel(originalID: originalID, id: id, name: name, outputDir: outputDir,
                                  quality: quality, tagFilter: tagFilter, stopOnTagMismatch: stopOption)
            : model.addChannel(id: id, name: name, outputDir: outputDir,
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
}
