import Foundation

/// Owns one streamlink->ffmpeg recording: streamlink stdout is piped into
/// ffmpeg stdin; ffmpeg stderr carries `-progress pipe:2` output.
final class RecordingSession {
    private let streamlink = Process()
    private let ffmpeg = Process()
    private let bridge = Pipe()          // streamlink stdout -> ffmpeg stdin
    private let ffmpegErr = Pipe()
    private let streamlinkErr = Pipe()

    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var finished = false
    }

    private let state = Synchronized(State(), label: "ChzzkDownloader.RecordingSession.state")

    init(streamlinkPath: String, streamlinkArgs: [String],
         ffmpegPath: String, ffmpegArgs: [String]) {
        streamlink.executableURL = URL(fileURLWithPath: streamlinkPath)
        streamlink.arguments = streamlinkArgs
        streamlink.standardOutput = bridge
        streamlink.standardError = streamlinkErr

        ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpeg.arguments = ffmpegArgs
        ffmpeg.standardInput = bridge
        ffmpeg.standardError = ffmpegErr
        ffmpeg.standardOutput = FileHandle.nullDevice
    }

    func start(onFfmpegStderr: @escaping (String) -> Void,
               onStreamlinkStderr: @escaping (String) -> Void) throws {
        lineReader(ffmpegErr.fileHandleForReading, onFfmpegStderr)
        lineReader(streamlinkErr.fileHandleForReading, onStreamlinkStderr)

        ffmpeg.terminationHandler = { [weak self] _ in self?.finish() }

        try ffmpeg.run()
        try streamlink.run()

        // Drop the parent's copies so EOF propagates to ffmpeg when streamlink exits.
        try? bridge.fileHandleForReading.close()
        try? bridge.fileHandleForWriting.close()
    }

    func waitUntilExit() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume = state.withValue { state in
                if state.finished { return true }
                state.continuation = cont
                return false
            }
            if shouldResume { cont.resume() }
        }
    }

    /// Ask streamlink to stop first, letting ffmpeg receive EOF and finalize the
    /// container normally. If ffmpeg does not exit soon after, fall back to terminate.
    func requestFinish(fallbackAfter seconds: UInt64 = 10) {
        if streamlink.isRunning {
            streamlink.terminate()
        } else if !ffmpeg.isRunning {
            finish()
            return
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, self.ffmpeg.isRunning else { return }
            self.terminate()
        }
    }

    func terminate() {
        if ffmpeg.isRunning { ffmpeg.terminate() }
        if streamlink.isRunning { streamlink.terminate() }
        if !ffmpeg.isRunning { finish() }
    }

    private func finish() {
        let cont: CheckedContinuation<Void, Never>? = state.withValue { state in
            guard !state.finished else { return nil }
            state.finished = true
            let cont = state.continuation
            state.continuation = nil
            return cont
        }
        cont?.resume()
    }

    private func lineReader(_ handle: FileHandle, _ onLine: @escaping (String) -> Void) {
        var buffer = Data()
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    onLine(line)
                }
            }
        }
    }
}
