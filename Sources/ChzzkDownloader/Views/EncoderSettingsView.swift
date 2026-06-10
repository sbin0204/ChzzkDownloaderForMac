import SwiftUI

enum EncoderKind { case hevc, av1 }

private struct PresetOption: Identifiable, Hashable { let value: String; let label: String; var id: String { value } }

/// One collapsible Section for HEVC or AV1 re-encoding, embedded in 녹화 설정.
/// Shows only the enable toggle until turned on, then reveals the parameters.
struct EncoderSection: View {
    @Environment(AppModel.self) private var model
    let kind: EncoderKind

    private var title: String { kind == .hevc ? "HEVC (H.265) 재인코딩" : "AV1 재인코딩" }
    private var encoders: [String] {
        kind == .hevc ? Defaults.hevcEncoders : Defaults.av1Encoders
    }

    /// Bitrate is stored as e.g. "2500k"; expose it as a plain kbps integer for input.
    private func kbps(_ text: Binding<String>) -> Binding<Int> {
        Binding(
            get: {
                let s = text.wrappedValue.lowercased()
                let n = Int(s.filter(\.isNumber)) ?? 0
                return s.hasSuffix("m") ? n * 1000 : n
            },
            set: { text.wrappedValue = "\(max(1, $0))k" })
    }

    /// Human-readable presets for the chosen encoder (always includes the current value).
    private func presets(_ encoder: String, current: String) -> [PresetOption] {
        let list: [(String, String)]
        switch encoder {
        case "libsvtav1":
            list = [("4", "4 — 느림·고품질"), ("6", "6"), ("8", "8 — 기본"), ("10", "10"), ("12", "12 — 빠름")]
        case "libaom-av1":
            list = [("4", "4 — 느림"), ("6", "6 — 기본"), ("8", "8 — 빠름")]
        default: // libx265
            list = [("ultrafast", "ultrafast — 가장 빠름"), ("superfast", "superfast"),
                    ("veryfast", "veryfast"), ("faster", "faster"), ("fast", "fast"),
                    ("medium", "medium — 기본"), ("slow", "slow — 고품질")]
        }
        var opts = list.map { PresetOption(value: $0.0, label: $0.1) }
        if !current.isEmpty && !opts.contains(where: { $0.value == current }) {
            opts.insert(PresetOption(value: current, label: current), at: 0)
        }
        return opts
    }

    var body: some View {
        @Bindable var model = model
        let binding = kind == .hevc ? $model.config.hevc_settings : $model.config.av1_settings
        let encoder = binding.wrappedValue.encoder
        let usesPreset = !encoder.contains("videotoolbox")

        Section(title) {
            Toggle("사용", isOn: binding.enable)
                .onChange(of: binding.wrappedValue.enable) { _, on in
                    // HEVC와 AV1은 동시에 사용할 수 없습니다.
                    if on {
                        if kind == .hevc { model.config.av1_settings.enable = false }
                        else { model.config.hevc_settings.enable = false }
                    }
                }

            if binding.wrappedValue.enable {
                if kind == .av1 && model.config.output_format == "ts" {
                    Text("AV1 + TS 조합은 지원되지 않아 MKV로 자동 전환됩니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("인코더", selection: binding.encoder) {
                    ForEach(encoders, id: \.self) { Text($0).tag($0) }
                }
                if kind == .hevc {
                    Text("libx265는 CPU(고압축), hevc_videotoolbox는 Mac 하드웨어 가속(가벼움)입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("목표 비트레이트") { bitrateField(kbps(binding.bitrate)) }
                LabeledContent("최대 비트레이트") { bitrateField(kbps(binding.max_bitrate)) }
                Text("숫자(kbps)만 입력하세요. 예: 목표 6000, 최대 10000.")
                    .font(.caption).foregroundStyle(.secondary)

                if usesPreset {
                    Picker("프리셋", selection: binding.preset) {
                        ForEach(presets(encoder, current: binding.wrappedValue.preset)) {
                            Text($0.label).tag($0.value)
                        }
                    }
                } else {
                    LabeledContent("프리셋", value: "하드웨어 인코더는 프리셋을 사용하지 않습니다")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bitrateField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .frame(width: 80).multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder).labelsHidden()
            Text("kbps").foregroundStyle(.secondary)
        }
    }
}
