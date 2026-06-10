import SwiftUI

/// Single home for all network/connection settings: download concurrency &
/// speed limit, plus a detailed proxy (bypass) configurator. Replaces the
/// proxy fields that used to be scattered across several screens.
struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            VODDownloadSettingsSection()

            ProxyEditor()
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("연결")
    }
}

struct VODDownloadSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("다운로드") {
            IntFieldStepper(
                title: "동시 연결 수",
                value: $model.vodConnections,
                range: Defaults.minVODConnections...Defaults.maxVODConnections)

            SpeedLimitFieldStepper(
                title: "속도 제한",
                value: $model.vodSpeedLimitMBps,
                range: Defaults.minVODSpeedLimitMBps...Defaults.maxVODSpeedLimitMBps,
                suffix: "MB/s")

            Text("연결 수가 많을수록 VOD 다운로드가 빨라질 수 있습니다. 속도 제한은 0이면 무제한입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpeedLimitFieldStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix: String = ""

    private var normalizedValue: Binding<Double> {
        Binding(
            get: { Validate.normalizeVODSpeedLimitMBps(value) },
            set: { value = Validate.normalizeVODSpeedLimitMBps($0) })
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: normalizedValue, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 88)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            Stepper("", value: normalizedValue, in: range, step: 0.5)
                .labelsHidden()
        }
    }
}

private enum ProxyKind: String, CaseIterable, Identifiable {
    case none = "사용 안 함", http = "HTTP", socks5 = "SOCKS5"
    var id: String { rawValue }
    var scheme: String { self == .socks5 ? "socks5" : "http" }
}

/// Detailed proxy editor. The discrete fields are the editing model; they are
/// composed into the single canonical `config.proxy` URL string on every change.
private struct ProxyEditor: View {
    @Environment(AppModel.self) private var model

    @State private var kind: ProxyKind = .none
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var loaded = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section("프록시 (우회)") {
            Picker("방식", selection: $kind) {
                ForEach(ProxyKind.allCases) { Text($0.rawValue).tag($0) }
            }

            if kind != .none {
                LabeledContent("서버 주소") {
                    HStack(spacing: 6) {
                        TextField("", text: $host, prompt: Text("127.0.0.1"))
                            .textFieldStyle(.roundedBorder).frame(minWidth: 130)
                        Text(":").foregroundStyle(.secondary)
                        TextField("", text: $port, prompt: Text(kind == .socks5 ? "1080" : "8080"))
                            .frame(width: 68).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                    }
                }
                LabeledContent("인증 (선택)") {
                    HStack(spacing: 6) {
                        TextField("", text: $user, prompt: Text("사용자 이름"))
                            .textFieldStyle(.roundedBorder)
                        SecureField("", text: $pass, prompt: Text("비밀번호"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text("연결 테스트") }
                    }
                    .disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let testResult {
                        Text(testResult).font(.caption)
                            .foregroundStyle(testResult.hasPrefix("성공") ? .green : .secondary)
                    }
                    Spacer()
                }
            }

            Text("라이브 녹화 · VOD 다운로드 · API 호출에 모두 적용됩니다. "
                 + "HTTP·SOCKS5와 사용자 인증을 지원합니다. (단, ffmpeg HLS 되감기는 SOCKS 미지원)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
        .onChange(of: kind) { _, _ in store() }
        .onChange(of: host) { _, _ in store() }
        .onChange(of: port) { _, value in
            let normalized = Validate.normalizePortInput(value)
            if normalized != value {
                port = normalized
            } else {
                store()
            }
        }
        .onChange(of: user) { _, _ in store() }
        .onChange(of: pass) { _, _ in store() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let s = model.config.proxy.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { kind = .none; return }
        let str = s.contains("://") ? s : "http://" + s
        guard let c = URLComponents(string: str), let h = c.host else { kind = .none; return }
        kind = (c.scheme ?? "http").lowercased().hasPrefix("socks") ? .socks5 : .http
        host = h
        port = c.port.map(String.init) ?? ""
        user = c.user ?? ""
        pass = c.password ?? ""
    }

    private func store() {
        guard loaded else { return }
        model.config.proxy = compose()
        testResult = nil
    }

    private func compose() -> String {
        guard kind != .none else { return "" }
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return "" }
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? $0 }
        let creds = user.isEmpty ? "" : "\(enc(user)):\(enc(pass))@"
        let p = Validate.normalizePortInput(port)
        let portPart = p.isEmpty ? "" : ":\(p)"
        return "\(kind.scheme)://\(creds)\(h)\(portPart)"
    }

    private func testConnection() {
        store()                       // make sure ProxySupport.current is up to date
        testing = true; testResult = nil
        Task {
            var message: String
            do {
                guard let url = URL(string: "https://www.chzzk.naver.com/") else {
                    await MainActor.run {
                        testResult = "실패: 테스트 URL 오류"
                        testing = false
                    }
                    return
                }
                var req = URLRequest(url: url, timeoutInterval: 12)
                req.setValue(VODRequestHeaders.userAgent, forHTTPHeaderField: "User-Agent")
                let (_, resp) = try await ProxySupport.session().data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                message = "성공 (HTTP \(code))"
            } catch {
                message = "실패: \(error.localizedDescription)"
            }
            let result = message
            await MainActor.run { testing = false; testResult = result }
        }
    }
}
