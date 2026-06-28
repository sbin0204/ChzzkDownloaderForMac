import Foundation
import ChzzkCaptureCore

/// The control surface RecordingEngine needs from a running recording, regardless
/// of whether it is the legacy streamlink→ffmpeg pipeline or the native engine.
protocol RecordingBackend: AnyObject {
    func waitUntilExit() async
    func requestFinish(fallbackAfter seconds: UInt64)
    func terminate()
}

extension RecordingBackend {
    func requestFinish() { requestFinish(fallbackAfter: 10) }
}

/// A live recording driven entirely by ChzzkCaptureCore — no streamlink, no
/// ffmpeg. Writes MPEG-TS via `LiveHLSReader`; for the MP4 format it remuxes the
/// finished TS in place (passthrough, no re-encode). MKV/AV1 are not handled here
/// (RecordingEngine keeps those on the legacy pipeline).
final class NativeRecordingSession: RecordingBackend {
    private enum Container { case ts, mp4 }

    private let reader: LiveHLSReader
    private let tsURL: URL          // where TSFileSink writes
    private let finalPartURL: URL   // the `.part` RecordingEngine will rename
    private let container: Container
    private let onLog: (String) -> Void

    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var finished = false
        var runTask: Task<Void, Never>?
        var fallback: Task<Void, Never>?
    }
    private let state = Synchronized(State(), label: "ChzzkDownloader.NativeRecordingSession.state")

    /// - Parameter tempURL: the `.part` path RecordingEngine renames on completion,
    ///   already carrying the final extension (e.g. `….ts.part` or `….mp4.part`).
    init(channelID: String, quality: String, cookies: Cookies,
         tempURL: URL, format: String, onLog: @escaping (String) -> Void) throws {
        self.onLog = onLog
        self.finalPartURL = tempURL
        self.container = (format == "mp4") ? .mp4 : .ts
        // For MP4 the reader writes TS to a sidecar; the final .part is produced by
        // the remux. For TS the reader writes the .part directly.
        self.tsURL = (container == .mp4) ? tempURL.appendingPathExtension("tsdata") : tempURL

        let sink = try TSFileSink(url: tsURL)
        let headers = URLSessionHLSFetcher.chzzkHeaders(nidAut: cookies.NID_AUT, nidSes: cookies.NID_SES)
        let fetcher = URLSessionHLSFetcher(headers: headers)
        self.reader = LiveHLSReader(
            fetcher: fetcher,
            sink: sink,
            resolveMediaURL: {
                try await ChzzkLiveResolver.resolveMediaURL(
                    channelID: channelID, quality: quality, fetcher: fetcher)
            })
    }

    /// Begins polling/downloading. Returns immediately; completion is observed via
    /// `waitUntilExit()`.
    func start() {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.reader.run()
                self.onLog("네이티브 엔진: 세그먼트 \(result.segments)개, "
                    + "\(Self.human(result.bytes)) 수신"
                    + (result.hadGap ? " (중간 누락 감지)" : "")
                    + (result.endedNaturally ? " — 방송 종료" : ""))
            } catch {
                self.onLog("네이티브 엔진 오류: \(error)")
            }
            // TS already written; for MP4 remux the finished TS in place.
            if self.container == .mp4 {
                do {
                    try await MP4Remuxer.remux(source: self.tsURL, to: self.finalPartURL)
                    try? FileManager.default.removeItem(at: self.tsURL)
                } catch {
                    self.onLog("네이티브 엔진 MP4 변환 오류: \(error)")
                }
            }
            self.finish()
        }
        state.update { $0.runTask = task }
    }

    func waitUntilExit() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withValue { state -> Bool in
                if state.finished { return true }
                state.continuation = cont
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    /// Graceful stop: ask the reader to stop so `run()` (and any MP4 remux) finishes
    /// normally, then `finish()` fires from the run task. Hard-terminate only if it
    /// does not wind down within the fallback window.
    func requestFinish(fallbackAfter seconds: UInt64 = 10) {
        let reader = reader
        Task { await reader.stop() }
        let fallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self else { return }
            let stillRunning = self.state.withValue { !$0.finished }
            if stillRunning { self.terminate() }
        }
        state.update { $0.fallback = fallback }
    }

    func terminate() {
        let reader = reader
        Task { await reader.stop() }
        let task = state.withValue { $0.runTask }
        task?.cancel()
        finish()
    }

    private func finish() {
        let cont: CheckedContinuation<Void, Never>? = state.withValue { state in
            guard !state.finished else { return nil }
            state.finished = true
            state.fallback?.cancel()
            let cont = state.continuation
            state.continuation = nil
            return cont
        }
        cont?.resume()
    }

    private static func human(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes), i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
    }
}
