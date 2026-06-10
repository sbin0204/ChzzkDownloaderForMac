import AppKit
import SwiftUI
import WebKit

enum SupportSheet: String, Identifiable, CaseIterable {
    case about
    case licenses
    case privacy
    case releaseNotes
    case troubleshooting
    case updates

    var id: String { rawValue }

    var title: String {
        AppLocalization.string(titleKey)
    }

    private var titleKey: String {
        switch self {
        case .about: return "정보"
        case .licenses: return "라이선스/오픈소스 고지"
        case .privacy: return "개인정보/쿠키 저장 안내"
        case .releaseNotes: return "릴리즈 노트"
        case .troubleshooting: return "문제 해결"
        case .updates: return "업데이트"
        }
    }

    var icon: String {
        switch self {
        case .about: return "info.circle"
        case .licenses: return "doc.text"
        case .privacy: return "lock.shield"
        case .releaseNotes: return "list.bullet.rectangle"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SupportCenterView: View {
    @Environment(AppModel.self) private var model

    private let items: [SupportSheet] = [
        .about, .updates, .releaseNotes, .privacy, .licenses, .troubleshooting
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        Button {
                            model.supportSheet = item
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon)
                                    .font(.title3)
                                    .frame(width: 28)
                                    .foregroundStyle(Color.brand)
                                Text(item.title)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .frame(minHeight: 64)
                            .cardSurface(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                SettingsLink {
                    Label(AppLocalization.string("설정 열기"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(AppLocalization.string("정보 · 도움말"))
    }
}

struct SupportSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sheet: SupportSheet

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(sheet.title, systemImage: sheet.icon)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(AppLocalization.string("완료")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                Group {
                    switch sheet {
                    case .about: AboutPane()
                    case .licenses: LicensesPane()
                    case .privacy: PrivacyPane()
                    case .releaseNotes: ReleaseNotesPane()
                    case .troubleshooting: TroubleshootingPane()
                    case .updates: UpdatesPane()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

private struct AboutPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chzzk Downloader for Mac")
                        .font(.title.weight(.semibold))
                    Text("버전 \(AppVersion.short) (\(AppVersion.build))")
                        .foregroundStyle(.secondary)
                }
            }

            InfoBlock("용도", lines: [
                "CHZZK 라이브 녹화와 VOD 다운로드를 위한 비공식 macOS 앱입니다.",
                "NAVER 또는 CHZZK와 제휴하지 않았으며, 저작권과 서비스 약관 준수 책임은 사용자에게 있습니다."
            ])

            InfoBlock("저장 위치", lines: [
                "설정: \(AppModel.abbreviateHome(ConfigStore.fileURL.path))",
                "현재 VOD 폴더: \(AppModel.publicPath(model.vodOutputDir))",
                "기본 라이브 녹화 폴더: ~/Movies/ChzzkDownloader"
            ])

            InfoBlock("라이선스", lines: [
                "앱 코드는 GNU GPLv3 라이선스로 배포됩니다.",
                "번들된 오픈소스 구성요소 고지는 라이선스/오픈소스 고지 화면에서 확인할 수 있습니다."
            ])
        }
    }
}

private struct UpdatesPane: View {
    @Environment(AppModel.self) private var model
    private let updateService = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppLocalization.string("현재 버전이 최신인지 확인하고, 새 버전이 있으면 안내에 따라 설치합니다."))
                .foregroundStyle(.secondary)

            Button {
                if !updateService.checkForUpdates() {
                    model.showToast(AppLocalization.string("지금은 업데이트를 확인할 수 없습니다. 잠시 후 다시 시도하세요."))
                }
            } label: {
                Label(AppLocalization.string("업데이트 확인"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

private struct PrivacyPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoBlock("로컬 저장", lines: [
                "채널, 예약, 녹화 설정, 쿠키 값은 config.json에 로컬 저장됩니다.",
                "다운로드 기록은 downloads.json에 저장되며 영상 제목과 저장 경로를 포함할 수 있습니다.",
                "웹훅 URL을 입력한 경우 config.json에 저장되며 진단 정보에서는 토큰을 마스킹합니다.",
                "VOD 저장 위치, 동시 연결 수, 속도 제한은 macOS UserDefaults에 저장됩니다.",
                "config.json, downloads.json, log.log는 사용자 앱 지원 폴더에 저장되고 파일 권한은 0600으로 제한됩니다.",
                "로그 파일 기록을 켜면 앱 동작 로그가 같은 폴더의 log.log에 저장됩니다."
            ])

            InfoBlock("쿠키 사용", lines: [
                "NID_AUT / NID_SES는 성인 인증 또는 로그인 필요한 콘텐츠 접근에만 사용됩니다.",
                "브라우저 쿠키 가져오기는 선택한 브라우저의 로컬 쿠키 저장소를 읽으며, Safari는 전체 디스크 접근 권한이 필요할 수 있습니다."
            ])

            InfoBlock("네트워크", lines: [
                "앱은 CHZZK/NAVER 콘텐츠 정보와 미디어 다운로드 요청을 보냅니다.",
                "Sparkle 업데이트가 설정된 경우 appcast URL에 업데이트 확인 요청을 보냅니다.",
                "웹훅 URL을 설정하면 녹화 시작·완료와 다운로드 완료 시 해당 HTTPS 주소로 알림 요청을 보냅니다.",
                "별도 분석, 광고, 사용자 추적용 텔레메트리는 넣지 않았습니다."
            ])
        }
    }
}

private struct LicensesPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoBlock("앱", lines: [
                "Chzzk Downloader for Mac: GNU GPLv3",
                "Chzzk-Rekoda by munsy0227에서 동작 방식을 참고했습니다."
            ])

            InfoBlock("오픈소스 구성요소", lines: [
                "Sparkle: MIT License, macOS 앱 업데이트 프레임워크",
                "streamlink Chzzk plugin: Streamlink 프로젝트의 플러그인 코드",
                "ffmpeg / streamlink: 사용자가 설치한 외부 실행 파일이며 앱 번들에는 포함하지 않습니다."
            ])

            BundledDocumentBlock(
                document: .license
            )

            BundledDocumentBlock(
                document: .thirdPartyNotices
            )
        }
    }
}

private struct ReleaseNotesPane: View {
    @State private var height: CGFloat = 320

    var body: some View {
        // Render the same standalone changelog page that the update dialog shows,
        // instead of the raw CHANGELOG.md text and deployment notes.
        HTMLPageView(html: Self.changelogHTML, height: $height)
            .frame(height: height)
    }

    private static var changelogHTML: String {
        BundledSupportDocument.read(filename: "changelog.html")
            ?? "<html><head><meta name=\"color-scheme\" content=\"light dark\"></head>"
             + "<body style=\"font:15px -apple-system\"><h2>변경 사항</h2>"
             + "<p>변경 사항을 불러올 수 없습니다.</p></body></html>"
    }
}

/// Renders a self-contained HTML page (the changelog) and reports its content
/// height so it sizes naturally inside the surrounding ScrollView.
private struct HTMLPageView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: HTMLPageView
        var loadedHTML: String?
        init(_ parent: HTMLPageView) { self.parent = parent }

        func webView(_ web: WKWebView, didFinish _: WKNavigation!) {
            web.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                if let h = result as? CGFloat, h > 0 {
                    DispatchQueue.main.async { self.parent.height = ceil(h) + 8 }
                }
            }
        }
    }
}

private struct TroubleshootingPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("진단 정보")
                    .font(.headline)
                HStack {
                    Button {
                        model.copyDiagnosticReport()
                    } label: {
                        Label("진단 정보 복사", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("버그 리포트에 붙여넣을 수 있는 앱 상태 요약을 복사합니다. 쿠키, 토큰, 사용자 경로는 마스킹됩니다.")
                        .foregroundStyle(.secondary)
                }
            }

            InfoBlock("앱이 열리지 않을 때", lines: [
                "DMG에서 바로 실행하지 말고 Applications 폴더로 복사한 뒤 실행하세요.",
                "서명/공증되지 않은 빌드는 처음 한 번 Finder에서 우클릭 > 열기로 실행해야 할 수 있습니다.",
                "업데이트 기능도 앱이 /Volumes의 DMG 안에서 실행 중이면 교체에 실패할 수 있습니다."
            ])

            InfoBlock("녹화/다운로드 실패", lines: [
                "ffmpeg와 streamlink가 설치되어 있는지 확인하세요.",
                "성인 인증 또는 로그인 필요한 콘텐츠는 쿠키 설정이 필요합니다.",
                "프록시를 쓰는 경우 연결 설정에서 주소를 다시 확인하세요."
            ])

            InfoBlock("Safari 쿠키 가져오기", lines: [
                "시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근에서 앱을 허용한 뒤 다시 실행하세요.",
                "권한 변경 후에도 실패하면 Chrome/Whale/Firefox에서 가져오거나 cookies.txt 파일을 사용하세요."
            ])

            InfoBlock("업데이트", lines: [
                "업데이트 확인 버튼이 설정 필요 상태라면 배포 빌드에 Sparkle appcast URL과 공개 키가 들어가지 않은 상태입니다.",
                "앱을 DMG의 읽기 전용 위치에서 실행 중이면 자동 교체가 실패할 수 있습니다."
            ])
        }
    }
}

private struct InfoBlock: View {
    let title: String
    let lines: [String]

    init(_ title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title))
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                        Text(AppLocalization.string(line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct BundledDocumentBlock: View {
    let title: String
    let filename: String
    let fallback: String

    init(document: SupportDocument) {
        self.title = document.title
        self.filename = document.filename
        self.fallback = document.fallback
    }

    init(title: String, filename: String, fallback: String) {
        self.title = title
        self.filename = filename
        self.fallback = fallback
    }

    private var text: String {
        BundledSupportDocument.read(filename: filename) ?? fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.string(title))
                    .font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label(AppLocalization.string("복사"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

private enum AppVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"
    }
}
