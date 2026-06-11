import SwiftUI
import AppKit

extension Notification.Name {
    static let chzzkSelectSidebarItem = Notification.Name("ChzzkDownloader.SelectSidebarItem")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the background when the window is closed, so live recordings
    /// and VOD downloads continue. Quit explicitly with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no visible window re-opens it (the same model,
    /// so in-progress recordings/downloads are shown again).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            _ = AppWindowPresenter.revealMainWindow()
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.confirmQuitIfNeeded() else { return .terminateCancel }
        model.prepareForTermination()
        return .terminateNow
    }
}

struct ChzzkDownloaderCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(AppLocalization.string("Chzzk Downloader for Mac에 관하여")) {
                presentSupport(.about)
            }
        }

        CommandGroup(after: .appInfo) {
            Button(AppLocalization.string("업데이트 확인…")) {
                if !UpdateService.shared.checkForUpdates() {
                    presentSupport(.updates)
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button(AppLocalization.string("문제 해결")) { presentSupport(.troubleshooting) }
            Divider()
            Button(AppLocalization.string("개인정보/쿠키 저장 안내")) { presentSupport(.privacy) }
            Button(AppLocalization.string("라이선스/오픈소스 고지")) { presentSupport(.licenses) }
            Button(AppLocalization.string("릴리즈 노트")) { presentSupport(.releaseNotes) }
        }

        CommandMenu(AppLocalization.string("이동")) {
            Button(AppLocalization.string("대시보드")) { select(.dashboard) }
                .keyboardShortcut("1", modifiers: .command)
            Button(AppLocalization.string("채널")) { select(.channels) }
                .keyboardShortcut("2", modifiers: .command)
            Button(AppLocalization.string("예약 녹화")) { select(.schedule) }
                .keyboardShortcut("3", modifiers: .command)
            Button(AppLocalization.string("VOD 다운로드")) { select(.vod) }
                .keyboardShortcut("4", modifiers: .command)
            Button(AppLocalization.string("다운로드 기록")) { select(.history) }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button(AppLocalization.string("녹화 설정")) { select(.recording) }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button(AppLocalization.string("연결")) { select(.connection) }
                .keyboardShortcut("6", modifiers: .command)
            Button(AppLocalization.string("쿠키 · 로그")) { select(.cookies) }
                .keyboardShortcut("7", modifiers: .command)
            Button(AppLocalization.string("정보 · 도움말")) { select(.support) }
                .keyboardShortcut("8", modifiers: .command)
        }
    }

    private func presentSupport(_ sheet: SupportSheet) {
        if !AppWindowPresenter.revealMainWindow() {
            openWindow(id: "main")
        }
        DispatchQueue.main.async {
            _ = AppWindowPresenter.revealMainWindow()
            model.supportSheet = sheet
        }
    }

    private func select(_ item: SidebarItem) {
        if !AppWindowPresenter.revealMainWindow() {
            openWindow(id: "main")
        }
        DispatchQueue.main.async {
            _ = AppWindowPresenter.revealMainWindow()
            NotificationCenter.default.post(
                name: .chzzkSelectSidebarItem,
                object: item.rawValue)
        }
    }
}

@main
struct ChzzkDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = AppModel()

    /// Menu bar template icon. Loaded from the app bundle (build_app.sh copies
    /// MenuBarIcon.png/@2x into Contents/Resources); falls back to the SF Symbol
    /// when running outside the assembled bundle (e.g. `swift run`).
    private static let menuBarIcon: NSImage = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Chzzk Downloader")!
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        // A singleton `Window` (not `WindowGroup`): closing the window only hides it
        // (WindowIdentifierMarker.hidesOnClose) and reopening reveals that same
        // instance. `WindowGroup` would instead spawn a *second* window on reopen,
        // which is why two windows were appearing after close → reopen.
        Window("Chzzk Downloader for Mac", id: "main") {
            ContentView()
                .environment(model)
                .environment(\.locale, AppLocalization.locale)
                .tint(.brand)
                .frame(minWidth: 860, minHeight: 600)
                .background(WindowIdentifierMarker(
                    identifier: AppWindowIdentifiers.main,
                    hidesOnClose: true))
                .onAppear { appDelegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.flushConfigSave()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 680)
        .commands { ChzzkDownloaderCommands(model: model) }

        Settings {
            AppSettingsView()
                .environment(model)
                .environment(\.locale, AppLocalization.locale)
                .tint(.brand)
                .onAppear { appDelegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.flushConfigSave()
                }
        }

        // Clip picker in its own freely-resizable window (a sheet can't be resized).
        WindowGroup("구간 선택", id: "clipPicker", for: UUID.self) { $id in
            if let id, let item = model.clipTargets[id] {
                ClipPickerView(item: item, cookies: model.config.cookies)
                    .environment(model)
                    .environment(\.locale, AppLocalization.locale)
                    .tint(.brand)
                    .onAppear { appDelegate.model = model }
            } else {
                Text("영상을 찾을 수 없습니다").frame(width: 400, height: 200)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 720)

        MenuBarExtra {
            MenuBarStatusView()
                .environment(model)
                .environment(\.locale, AppLocalization.locale)
                .onAppear { appDelegate.model = model }
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}
