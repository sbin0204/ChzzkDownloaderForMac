import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "대시보드"
    case schedule = "예약 녹화"
    case vod = "VOD 다운로드"
    case history = "다운로드 기록"
    case channels = "채널"
    case recording = "녹화 설정"
    case connection = "연결"
    case cookies = "쿠키 · 로그"
    case support = "정보 · 도움말"
    var id: String { rawValue }
    var title: String { AppLocalization.string(rawValue) }

    var icon: String {
        switch self {
        case .dashboard: return "record.circle"
        case .schedule: return "calendar.badge.clock"
        case .vod: return "bolt.circle"
        case .history: return "clock.arrow.circlepath"
        case .channels: return "person.2"
        case .recording: return "gearshape"
        case .connection: return "network"
        case .cookies: return "key"
        case .support: return "questionmark.circle"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("mainSidebarSelection") private var selection: SidebarItem = .dashboard

    // Slightly larger, comfortable sidebar rows (bigger SF Symbol + a little
    // vertical breathing room). This follows Apple's source-list conventions —
    // System Settings and Mail use similarly sized rows — so it stays HIG-correct
    // while being easier to read and click.
    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title).font(.body)
        } icon: {
            Image(systemName: item.icon).imageScale(.large)
        }
        .padding(.vertical, 2)
        .tag(item)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(AppLocalization.string("녹화")) { row(.dashboard); row(.channels); row(.schedule); row(.recording) }
                Section(AppLocalization.string("다운로드")) { row(.vod); row(.history) }
                Section(AppLocalization.string("앱 설정")) { row(.connection); row(.cookies) }
                Section(AppLocalization.string("지원")) { row(.support) }
            }
            .listStyle(.sidebar)                       // native vibrancy
            .navigationSplitViewColumnWidth(min: 212, ideal: 226, max: 280)
        } detail: {
            Group {
                switch selection {
                case .dashboard: DashboardView()
                case .schedule: SchedulesView()
                case .vod: VODView()
                case .history: HistoryView()
                case .channels: ChannelsView()
                case .recording: RecordingSettingsView()
                case .connection: ConnectionSettingsView()
                case .cookies: CookieSettingsView()
                case .support: SupportCenterView()
                }
            }
        }
        .sheet(item: Binding(
            get: { model.supportSheet },
            set: { model.supportSheet = $0 }
        )) { sheet in
            SupportSheetView(sheet: sheet)
                .environment(model)
                .tint(.brand)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chzzkSelectSidebarItem)) { notification in
            guard let rawValue = notification.object as? String,
                  let item = SidebarItem(rawValue: rawValue) else { return }
            selection = item
        }
        .overlay(alignment: .bottom) { ToastView(message: model.toast) }
        .alert(AppLocalization.string("필수 도구가 필요합니다"), isPresented: Binding(
            get: { model.toolAlert != nil },
            set: { if !$0 { model.toolAlert = nil } }
        ), presenting: model.toolAlert) { alert in
            Button(AppLocalization.string("설치 명령 복사")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(alert.command, forType: .string)
            }
            Button(AppLocalization.string("Homebrew 설치 페이지")) {
                if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
            }
            Button(AppLocalization.string("취소"), role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(AppLocalization.string("전체 디스크 접근 권한 필요"), isPresented: Binding(
            get: { model.fullDiskAccessNeeded },
            set: { model.fullDiskAccessNeeded = $0 }
        )) {
            Button(AppLocalization.string("시스템 설정 열기")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(AppLocalization.string("취소"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("Safari 쿠키를 읽으려면 ‘전체 디스크 접근’ 권한이 필요합니다.\n\n시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근에서 ‘Chzzk Downloader for Mac’을 켠 뒤, 앱을 다시 실행해 주세요."))
        }
        .alert("치지직 쿠키 갱신 필요", isPresented: Binding(
            get: { model.cookieAuthWarning != nil },
            set: { if !$0 { model.cookieAuthWarning = nil } }
        )) {
            Button("쿠키 설정 열기") {
                selection = .cookies
                model.cookieAuthWarning = nil
            }
            Button("나중에", role: .cancel) {
                model.cookieAuthWarning = nil
            }
        } message: {
            Text(model.cookieAuthWarning ?? "치지직 로그인 쿠키를 다시 가져오세요.")
        }
    }
}
