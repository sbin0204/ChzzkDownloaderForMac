import SwiftUI
import AVKit
import AVFoundation

/// AppKit AVPlayerView wrapped for SwiftUI. Avoids SwiftUI's `VideoPlayer`,
/// whose `_AVKit_SwiftUI` metadata crashes when built as an SPM executable.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        if #available(macOS 13.0, *) { v.allowsVideoFrameAnalysis = false }
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// Streams the VOD in a player and lets the user scrub to mark in/out points,
/// so they don't have to know exact timestamps. Sets item.clipStart/clipEnd.
struct ClipPickerView: View {
    @Bindable var item: VODItem
    let cookies: Cookies
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var current: Double = 0
    @State private var startSel: Double?
    @State private var endSel: Double?
    @State private var observer: Any?

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("구간 선택").font(.title3).bold()
                Text(item.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            ZStack {
                if let player {
                    PlayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.6))
                        .overlay(ProgressView("불러오는 중…").tint(.white).foregroundStyle(.white))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 280)

            HStack {
                Label("현재 \(hms(current))", systemImage: "timer").monospacedDigit()
                Spacer()
                Button { startSel = current } label: { Label("시작 지점", systemImage: "arrow.down.to.line") }
                Button { endSel = current } label: { Label("끝 지점", systemImage: "arrow.up.to.line") }
            }
            .font(.callout)

            HStack {
                Text(rangeText)
                    .font(.callout)
                    .foregroundStyle(rangeValid ? AnyShapeStyle(Color.brand) : AnyShapeStyle(.secondary))
                Spacer()
                if startSel != nil || endSel != nil {
                    Button("초기화") { startSel = nil; endSel = nil }.controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("이 구간으로 설정") { item.clipStart = startSel; item.clipEnd = endSel; dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rangeValid)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .onAppear { startSel = item.clipStart; endSel = item.clipEnd; setup() }
        .onDisappear { teardown() }
    }

    private var rangeValid: Bool {
        if let s = startSel, let e = endSel, e > s { return true }; return false
    }

    private var rangeText: String {
        switch (startSel, endSel) {
        case let (s?, e?):
            return e > s ? "구간  \(hms(s)) ~ \(hms(e))   (길이 \(hms(e - s)))"
                         : "끝이 시작보다 빠릅니다 — 다시 지정하세요"
        case let (s?, nil): return "시작 \(hms(s)) — 끝 지점을 지정하세요"
        case let (nil, e?): return "끝 \(hms(e)) — 시작 지점을 지정하세요"
        default: return "영상을 재생·탐색하며 시작/끝 지점을 지정하세요"
        }
    }

    private func setup() {
        guard let variant = item.selectedVariant ?? item.variants.last,
              let url = URL(string: variant.url) else { return }
        let headers = VODRequestHeaders.media(cookies: cookies)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
                let s = t.seconds
                if s.isFinite { current = s }
            }
        player = p
    }

    private func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
    }

    private func hms(_ s: Double) -> String {
        let t = Int(max(0, s).rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
