import SwiftUI

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    private var schedules: [Schedule] {
        model.config.schedules.sorted { $0.startEpoch < $1.startEpoch }
    }

    var body: some View {
        Group {
            if model.config.channels.isEmpty {
                ContentUnavailableView("채널 없음", systemImage: "person.2",
                    description: Text("먼저 ‘채널’에서 채널을 추가하세요."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if schedules.isEmpty {
                ContentUnavailableView("예약 없음", systemImage: "calendar.badge.clock",
                    description: Text("툴바의 +, 또는 ⌘N으로 채널을 지정한 시각에 자동 녹화하도록 예약하세요."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(schedules) { ScheduleRow(schedule: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("예약 녹화")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("예약 추가", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.config.channels.isEmpty)
                    .help("예약 추가 (⌘N)")
            }
        }
        .sheet(isPresented: $showAdd) { ScheduleAddSheet() }
    }
}

struct ScheduleRow: View {
    @Environment(AppModel.self) private var model
    @State private var showDeleteConfirm = false
    let schedule: Schedule

    var body: some View {
        let ch = model.config.channels.first { $0.id == schedule.channelID }
        HStack(spacing: 12) {
            Image(systemName: schedule.started ? "record.circle.fill" : "calendar.badge.clock")
                .foregroundStyle(schedule.started ? Color.onAir : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ch?.name ?? schedule.channelID).fontWeight(.medium)
                Text("\(dateText) · \(schedule.durationMinutes == 0 ? "방송 끝까지" : "\(schedule.durationMinutes)분")"
                     + (schedule.started ? " · 진행 중" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless).controlSize(.small).help("예약 삭제")
        }
        .padding(.vertical, 4)
        .confirmationDialog("이 예약을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { model.deleteSchedule(schedule.id) }
            Button("취소", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        if schedule.started, model.isRecording(schedule.channelID) {
            return "예약 목록에서 제거되고 현재 녹화/감시도 중지됩니다. 이미 저장된 녹화 파일은 삭제되지 않습니다."
        }
        return "예약 목록에서 제거됩니다. 이미 저장된 녹화 파일은 삭제되지 않습니다."
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E) HH:mm"
        return f.string(from: schedule.startDate)
    }
}

struct ScheduleAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var channelID = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var duration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("예약 추가").font(.title3).bold()
            Form {
                Picker("채널", selection: $channelID) {
                    ForEach(model.config.channels) { Text($0.name).tag($0.id) }
                }
                DatePicker("시작 시각", selection: $start, in: Date()...)
                Stepper(value: $duration, in: 0...1440, step: 10) {
                    Text(duration == 0 ? "녹화 길이: 방송 끝까지" : "녹화 길이: \(duration)분")
                }
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("추가") {
                    model.addSchedule(channelID: channelID, start: start, durationMinutes: duration)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(channelID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if channelID.isEmpty { channelID = model.config.channels.first?.id ?? "" } }
    }
}
