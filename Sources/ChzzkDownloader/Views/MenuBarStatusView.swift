import AppKit
import SwiftUI

struct MenuBarStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var activeRecordingCount: Int {
        let writing = Set(model.progress.map(\.id))
        return model.recordingChannels.intersection(writing).count
    }

    private var armedRecordingCount: Int {
        max(0, model.recordingChannels.count - activeRecordingCount)
    }

    private var vodWorkingCount: Int {
        model.vodItems.filter {
            if case .fetching = $0.state { return true }
            if case .downloading = $0.state { return true }
            return false
        }.count
    }

    private var liveCount: Int {
        model.liveStatus.values.filter(\.isLive).count
    }

    private var summary: String {
        let recording = activeRecordingCount
        let armed = armedRecordingCount
        let vod = vodWorkingCount
        if recording == 0 && armed == 0 && vod == 0 { return "대기 중" }
        var parts: [String] = []
        if recording > 0 { parts.append("녹화 \(recording)") }
        if armed > 0 { parts.append("감시 \(armed)") }
        if vod > 0 { parts.append("VOD \(vod)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            openMainWindow()
        } label: {
            Label("창 열기", systemImage: "macwindow")
        }

        Divider()

        Text(summary)
        Text("라이브 채널 \(liveCount) · 예약 \(model.config.schedules.count)")

        if !model.progress.isEmpty {
            Divider()
            ForEach(model.progress.prefix(5)) { item in
                Text("\(menuText(item.channelName, limit: 18)) · \(item.outTime)")
            }
        }

        if vodWorkingCount > 0 {
            Divider()
            ForEach(model.vodItems.filter({ item in
                if case .fetching = item.state { return true }
                if case .downloading = item.state { return true }
                return false
            }).prefix(5)) { item in
                Text("\(menuText(item.title.isEmpty ? "VOD" : item.title, limit: 20)) · \(vodProgressText(item))")
            }
        }

        Divider()

        Button {
            if !UpdateService.shared.checkForUpdates() {
                presentSupport(.updates)
            }
        } label: {
            Label("업데이트 확인…", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button("종료") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        if AppWindowPresenter.revealMainWindow() {
            return
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentSupport(_ sheet: SupportSheet) {
        openMainWindow()
        DispatchQueue.main.async {
            _ = AppWindowPresenter.revealMainWindow()
            model.supportSheet = sheet
        }
    }

    private func menuText(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 1))) + "…"
    }

    private func vodProgressText(_ item: VODItem) -> String {
        if item.percent <= 0 && item.speedText.isEmpty {
            return item.sizeText.isEmpty || item.sizeText == "N/A" ? "준비중" : item.sizeText
        }
        return "\(Int(item.percent * 100))%"
    }
}
