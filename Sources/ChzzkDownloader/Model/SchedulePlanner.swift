import Foundation

enum ScheduleAction: Equatable {
    case start(channelID: String, oneShot: Bool)
    case stop(channelID: String)
}

enum SchedulePlanner {
    static func renameChannelReferences(
        schedules: [Schedule],
        from oldID: String,
        to newID: String
    ) -> [Schedule] {
        guard oldID != newID else { return schedules }
        var updated = schedules
        for index in updated.indices where updated[index].channelID == oldID {
            updated[index].channelID = newID
        }
        return updated
    }

    static func removeChannelReferences(
        schedules: [Schedule],
        channelID: String
    ) -> [Schedule] {
        schedules.filter { $0.channelID != channelID }
    }

    static func delete(
        schedules: [Schedule],
        id: UUID,
        recordingChannels: Set<String>
    ) -> (schedules: [Schedule], action: ScheduleAction?) {
        guard let target = schedules.first(where: { $0.id == id }) else {
            return (schedules, nil)
        }
        let updated = schedules.filter { $0.id != id }
        let shouldStop = target.started
            && target.durationMinutes > 0
            && recordingChannels.contains(target.channelID)
        return (updated, shouldStop ? .stop(channelID: target.channelID) : nil)
    }

    static func tick(
        schedules: [Schedule],
        channels: [Channel],
        recordingChannels: Set<String>,
        now: TimeInterval
    ) -> (schedules: [Schedule], actions: [ScheduleAction]) {
        var updated = schedules
        var toRemove: [UUID] = []
        var actions: [ScheduleAction] = []

        for i in updated.indices {
            var schedule = updated[i]
            guard channels.contains(where: { $0.id == schedule.channelID }) else {
                toRemove.append(schedule.id)
                continue
            }

            if !schedule.started, now >= schedule.startEpoch {
                schedule.started = true
                updated[i] = schedule
                if !recordingChannels.contains(schedule.channelID) {
                    actions.append(.start(
                        channelID: schedule.channelID,
                        oneShot: schedule.durationMinutes == 0))
                }
                if schedule.durationMinutes == 0 {
                    toRemove.append(schedule.id)
                }
            }

            if schedule.started, schedule.durationMinutes > 0,
               now >= schedule.startEpoch + Double(schedule.durationMinutes) * 60 {
                if recordingChannels.contains(schedule.channelID) {
                    actions.append(.stop(channelID: schedule.channelID))
                }
                toRemove.append(schedule.id)
            }
        }

        if !toRemove.isEmpty {
            updated.removeAll { toRemove.contains($0.id) }
        }
        return (updated, actions)
    }
}
