import SwiftUI

/// A row with both arrow steppers and a directly-editable number field.
struct IntFieldStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: $value, format: .number)
                .frame(width: 88)                       // wide enough for grouped digits
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .onChange(of: value) { _, v in
                    let clamped = min(range.upperBound, max(range.lowerBound, v))
                    if clamped != v { value = clamped }
                }
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary).frame(minWidth: 26, alignment: .leading) }
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

/// Capacity unit for the auto-split size. Storage is always MB; this only
/// changes how the value is shown/entered so large sizes stay readable.
enum SizeUnit: String, CaseIterable, Identifiable {
    case mb = "MB"
    case gb = "GB"
    var id: String { rawValue }
    var mbPerUnit: Double { self == .gb ? 1024 : 1 }
    var step: Double { self == .gb ? 1 : 100 }
}

/// Auto-split size row: edited in a user-chosen unit (MB/GB), stored in MB.
struct SplitSizeRow: View {
    let title: String
    @Binding var megabytes: Int
    let maxMB: Int
    @AppStorage("splitSizeUnit") private var unitRaw = SizeUnit.mb.rawValue

    private var unit: SizeUnit { SizeUnit(rawValue: unitRaw) ?? .mb }
    private var maxInUnit: Double { Double(maxMB) / unit.mbPerUnit }

    private var amount: Binding<Double> {
        Binding(
            get: { Double(megabytes) / unit.mbPerUnit },
            set: { newValue in
                let mb = Int((max(0, newValue) * unit.mbPerUnit).rounded())
                megabytes = min(maxMB, max(0, mb))
            })
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: amount, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 88)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Picker("", selection: Binding(get: { unit }, set: { unitRaw = $0.rawValue })) {
                ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 70)
            Stepper("", value: amount, in: 0...maxInUnit, step: unit.step).labelsHidden()
        }
    }
}

struct RecordingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("출력 (라이브 녹화 전용)") {
                Picker("포맷", selection: $model.config.output_format) {
                    ForEach(Defaults.supportedFormats, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("라이브 녹화 컨테이너입니다 (ts·mkv·webm). 중단 내성은 ts > mkv 순. "
                     + "VOD 다운로드는 mp4(또는 오디오만 m4a)로 저장되며 이 설정과 무관합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("감지") {
                IntFieldStepper(title: "재스캔 간격", value: $model.config.timeout,
                                range: Defaults.minRescanInterval...Defaults.maxRescanInterval,
                                suffix: "초")
                Text("각 채널의 방송 여부를 확인하는 주기입니다. 화살표로 조절하거나 숫자를 직접 입력하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("성능") {
                IntFieldStepper(title: "세그먼트 스레드", value: $model.config.stream_segment_threads,
                                range: Defaults.minThreads...Defaults.maxThreads)
                Text("streamlink 다운로드 스레드 수. 저사양은 2, 고사양은 4를 권장합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("파일 분할") {
                SplitSizeRow(title: "자동 분할 크기", megabytes: $model.config.live_split_size_mb,
                             maxMB: Defaults.maxSplitSizeMB)
                IntFieldStepper(title: "자동 분할 시간", value: $model.config.live_split_duration_minutes,
                                range: Defaults.minSplitDurationMinutes...Defaults.maxSplitDurationMinutes,
                                suffix: "분")
                Text("라이브 녹화가 지정한 크기나 시간에 먼저 도달하면 현재 파일을 저장하고 바로 다음 파일로 이어서 녹화합니다. 0이면 해당 기준은 꺼집니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("순환 녹화") {
                Toggle("오래된 녹화 자동 정리", isOn: $model.config.cyclic_recording_enabled)
                if model.config.cyclic_recording_enabled {
                    IntFieldStepper(title: "채널당 최대 파일 수",
                                    value: $model.config.cyclic_max_files, range: 0...100_000, suffix: "개")
                    IntFieldStepper(title: "채널당 최대 용량",
                                    value: $model.config.cyclic_max_size_gb, range: 0...1_000_000, suffix: "GB")
                }
                Text("채널마다 최근 녹화를 설정한 개수·용량 이내로만 보관합니다. 새 파일이 저장돼 "
                     + "개수가 ‘최대 파일 수’보다 많아지거나 총 용량이 ‘최대 용량’을 넘으면, "
                     + "가장 오래된 파일부터 휴지통으로 옮깁니다(복구 가능). "
                     + "각 채널의 저장 폴더에 있는 그 채널 완성 파일만 대상이며, 0이면 그 기준은 끔.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Re-encoding (was separate HEVC / AV1 tabs)
            EncoderSection(kind: .hevc)
            EncoderSection(kind: .av1)
        }
        .formStyle(.grouped)
        .navigationTitle("녹화 설정")
    }
}
