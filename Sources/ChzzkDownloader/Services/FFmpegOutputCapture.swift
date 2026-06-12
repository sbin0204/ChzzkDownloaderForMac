import Foundation

final class FFmpegOutputCapture {
    private struct State {
        var summary: [String: String] = [:]
        var buffer = Data()
        var logTail: [String] = []
    }

    private static let progressKeys: Set<String> = [
        "bitrate",
        "drop_frames",
        "dup_frames",
        "fps",
        "frame",
        "out_time",
        "out_time_ms",
        "out_time_us",
        "progress",
        "speed",
        "total_size",
    ]

    private let state = Synchronized(State(), label: "ChzzkDownloader.FFmpegOutputCapture.state")

    func consume(_ chunk: Data, onProgress: (([String: String]) -> Void)? = nil) {
        guard !chunk.isEmpty else { return }
        let snapshots = state.withValue { state -> [[String: String]] in
            var snapshots: [[String: String]] = []
            state.buffer.append(chunk)
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let lineData = state.buffer.subdata(in: state.buffer.startIndex..<newline)
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
                consumeLine(lineData, state: &state, snapshots: &snapshots)
            }
            return snapshots
        }
        for snapshot in snapshots {
            onProgress?(snapshot)
        }
    }

    func finishAndTail() -> [String] {
        state.withValue { state in
            if !state.buffer.isEmpty {
                let lineData = state.buffer
                state.buffer.removeAll()
                var snapshots: [[String: String]] = []
                consumeLine(lineData, state: &state, snapshots: &snapshots)
            }
            return state.logTail
        }
    }

    private func consumeLine(_ lineData: Data, state: inout State,
                             snapshots: inout [[String: String]]) {
        guard let line = String(data: lineData, encoding: .utf8) else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.shouldKeepDiagnosticLine(trimmed) {
            state.logTail.append(trimmed)
            if state.logTail.count > 40 {
                state.logTail.removeFirst(state.logTail.count - 40)
            }
        }
        guard let separator = line.firstIndex(of: "=") else { return }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        state.summary[key] = value
        if key == "progress" {
            snapshots.append(state.summary)
            state.summary.removeAll()
        }
    }

    private static func shouldKeepDiagnosticLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        guard let separator = line.firstIndex(of: "=") else { return true }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("stream_"), key.hasSuffix("_q") { return false }
        return !progressKeys.contains(key)
    }
}
