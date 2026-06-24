import AppKit
import SwiftUI

/// First-launch onboarding. Explains the two prerequisites a newcomer cannot
/// guess (ffmpeg + streamlink) with a copyable install command and a live
/// installed/not-installed check, then points at the next step. Shown once.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    /// Bumped by "다시 확인" to re-read the (filesystem-derived) tool status after
    /// the user installs the tools in Terminal and returns.
    @State private var recheck = 0

    private static let installCommand = "brew install ffmpeg streamlink"

    private var ffmpegOK: Bool { _ = recheck; return model.ffmpegPath != nil }
    private var streamlinkOK: Bool { _ = recheck; return model.streamlinkPath != nil }
    private var allReady: Bool { ffmpegOK && streamlinkOK }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chzzk Downloader for Mac").font(.title).bold()
                Text("치지직 라이브를 자동으로 녹화하고, VOD·클립을 다운로드합니다.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("1. 필수 도구 설치", systemImage: "wrench.and.screwdriver")
                        .font(.headline)
                    Text("녹화와 다운로드에는 ffmpeg와 streamlink가 필요합니다. "
                         + "터미널에 아래 명령을 붙여넣어 설치하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(Self.installCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        Button("복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.installCommand, forType: .string)
                            model.showToast("설치 명령을 복사했습니다")
                        }
                    }
                    HStack(spacing: 16) {
                        toolStatus("ffmpeg", ok: ffmpegOK)
                        toolStatus("streamlink", ok: streamlinkOK)
                        Spacer()
                        Button("다시 확인") { recheck += 1 }
                    }
                    if !allReady {
                        Link("Homebrew가 없다면 brew.sh에서 먼저 설치하세요.",
                             destination: URL(string: "https://brew.sh")!)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("2. 채널 추가", systemImage: "person.2")
                        .font(.headline)
                    Text("‘채널’ 화면에서 치지직 채널 주소를 붙여넣으면, 방송이 시작될 때 자동으로 녹화합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text("성인 인증 방송이나 로그인 전용 콘텐츠를 받으려면 ‘쿠키 · 로그’에서 "
                 + "치지직 로그인 쿠키를 가져오세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(allReady ? "시작하기" : "나중에 설치하고 시작") { model.dismissWelcome() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func toolStatus(_ name: String, ok: Bool) -> some View {
        Label(name, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .font(.callout)
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}
