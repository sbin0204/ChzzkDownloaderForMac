import QuickLook
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var records: [DownloadRecord] {
        let base = model.downloadRecords.sorted { $0.updatedAt > $1.updatedAt }
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            $0.channelName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if model.downloadRecords.isEmpty {
                ContentUnavailableView(
                    "기록 없음", systemImage: "clock.arrow.circlepath",
                    description: Text("다운로드한 영상의 기록이 여기에 표시됩니다. 실패한 항목은 다시 받을 수 있습니다."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in HistoryRow(record: record) }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("다운로드 기록")
        .searchable(text: $search, placement: .toolbar, prompt: "기록 검색")
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    @State private var showDeleteConfirm = false
    @State private var previewURL: URL?
    let record: DownloadRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).fontWeight(.medium).lineLimit(2)
                Text("\(record.channelName) · \(record.quality)p · \(dateText)\(sizeSuffix)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            actions
        }
        .padding(12)
        .cardSurface()
        .quickLookPreview($previewURL)
        .confirmationDialog("이 기록을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { model.deleteRecord(record) }
            Button("취소", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch record.status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .interrupted: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
        }
    }

    @ViewBuilder private var actions: some View {
        switch record.status {
        case .completed:
            if FileManager.default.fileExists(atPath: record.finalPath) {
                let url = URL(fileURLWithPath: record.finalPath)
                Button { previewURL = url } label: { Image(systemName: "eye") }
                    .controlSize(.small).buttonStyle(.borderless).help("미리보기 (Quick Look)")
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .controlSize(.small).help("공유")
                Button("Finder에서 보기") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }.controlSize(.small)
            }
            deleteButton
        case .interrupted, .failed:
            Button { model.retryRecord(record) } label: { Label("다시 받기", systemImage: "arrow.clockwise") }
                .controlSize(.small)
            deleteButton
        case .downloading:
            Text("진행 중").font(.caption).foregroundStyle(.blue)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { showDeleteConfirm = true } label: {
            Image(systemName: "trash").foregroundStyle(.red)
        }
        .buttonStyle(.borderless).controlSize(.small).help("기록 삭제")
    }

    private var deleteMessage: String {
        return "기록만 삭제됩니다. 완성된 영상 파일은 삭제되지 않습니다."
    }

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: record.updatedAt)
    }

    private var sizeSuffix: String {
        record.fileSize > 0 ? " · \(ProgressParser.formatSize(Double(record.fileSize)))" : ""
    }
}
