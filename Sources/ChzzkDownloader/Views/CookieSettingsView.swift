import SwiftUI
import UniformTypeIdentifiers

struct CookieSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("쿠키 (성인 인증 방송 · VOD)") {
                SecureField("NID_AUT", text: $model.config.cookies.NID_AUT)
                    .onChange(of: model.config.cookies.NID_AUT) { _, value in
                        sanitizeCookieInput(\.NID_AUT, value: value)
                    }
                SecureField("NID_SES", text: $model.config.cookies.NID_SES)
                    .onChange(of: model.config.cookies.NID_SES) { _, value in
                        sanitizeCookieInput(\.NID_SES, value: value)
                    }

                LabeledContent("상태") {
                    Label(model.cookieStatusText,
                          systemImage: model.cookieNeedsRefresh ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.cookieNeedsRefresh ? .orange : .secondary)
                }
                Text(model.cookieStatusDetail)
                    .font(.caption)
                    .foregroundStyle(model.cookieNeedsRefresh ? .orange : .secondary)

                Toggle("앱 시작 시 브라우저 쿠키 자동 불러오기", isOn: $model.config.auto_import_cookies_on_launch)
                Text("기본값은 꺼짐입니다. 켜면 앱 실행 때 로그인된 브라우저에서 NID_AUT/NID_SES를 자동으로 가져옵니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Menu {
                        if model.installedBrowsers.isEmpty {
                            Text("설치된 브라우저 없음")
                        } else {
                            ForEach(model.installedBrowsers) { browser in
                                Button(browser.displayName) { model.importCookies(from: browser) }
                            }
                        }
                    } label: {
                        Label("브라우저에서 가져오기", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("지금 자동 선택") { model.importCookiesFromFirstAvailableBrowser() }
                        .disabled(model.installedBrowsers.isEmpty)
                    Button("쿠키 파일(.txt)…") { pickCookieFile() }
                    Button("갱신 완료로 표시") { model.markCookieRefreshConfirmed() }
                    if let msg = model.cookieImportMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                Text("로그인된 브라우저에서 자동으로 가져오거나, Netscape 형식 cookies.txt 파일에서 가져옵니다. "
                     + "Chrome 계열은 키체인 허용, Safari는 전체 디스크 접근이 필요할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("알림") {
                Toggle("녹화 · 다운로드 완료 시 알림", isOn: $model.config.notify_on_complete)
                TextField("웹훅 URL (선택)", text: $model.config.notify_webhook_url,
                          prompt: Text("Discord/Telegram 웹훅 주소"))
                Text("입력하면 녹화 시작·완료와 다운로드 완료를 해당 웹훅으로도 보냅니다. "
                     + "Discord 웹훅 URL을 그대로 붙여넣거나, Telegram은 "
                     + "https://api.telegram.org/bot<토큰>/sendMessage?chat_id=<ID> 형식을 쓰세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("로깅") {
                Toggle("로그 파일 기록", isOn: $model.config.log_enabled)
                LabeledContent("설정 · 로그") {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
                    }
                }
                Text((ConfigStore.directory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }

            Section("도구") {
                ToolPathRow(name: "ffmpeg", customPath: $model.config.ffmpeg_path, resolved: model.ffmpegPath)
                ToolPathRow(name: "streamlink", customPath: $model.config.streamlink_path, resolved: model.streamlinkPath)
                Text("비워두면 자동으로 찾습니다(Homebrew · MacPorts · ~/.local/bin · PATH 등). "
                     + "직접 설치해 자동으로 못 찾으면 실행 파일 경로를 지정하세요. "
                     + "변경은 새 녹화·다운로드부터 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("쿠키 · 로그")
    }

    private func pickCookieFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        if panel.runModal() == .OK, let url = panel.url {
            model.importCookiesFromFile(url)
        }
    }

    private func sanitizeCookieInput(_ keyPath: WritableKeyPath<Cookies, String>, value: String) {
        let sanitized = Validate.sanitizeCookie(value)
        if sanitized != value {
            model.config.cookies[keyPath: keyPath] = sanitized
            return
        }
        model.markCookiesEdited()
    }
}

/// Editable tool path: a custom override field + file picker, with the resolved
/// path shown below (or a warning when the override is invalid / nothing found).
private struct ToolPathRow: View {
    let name: String
    @Binding var customPath: String
    let resolved: String?

    private var overrideInvalid: Bool {
        !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !Tooling.isValidExecutable(customPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(name).frame(width: 78, alignment: .leading)
                TextField("", text: $customPath, prompt: Text("자동 감지 (비워두기)"))
                    .textFieldStyle(.roundedBorder)
                Button("찾아보기…") { pick() }
                if !customPath.isEmpty {
                    Button { customPath = "" } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("자동 감지로 되돌리기")
                }
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        if overrideInvalid {
            Label("지정한 경로에서 실행 파일을 찾을 수 없어 자동 감지로 대체됩니다.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if let resolved {
            Text("현재: \((resolved as NSString).abbreviatingWithTildeInPath)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            Label("찾을 수 없음 — 경로를 직접 지정하거나 설치하세요.", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "\(name) 실행 파일을 선택하세요"
        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
    }
}
