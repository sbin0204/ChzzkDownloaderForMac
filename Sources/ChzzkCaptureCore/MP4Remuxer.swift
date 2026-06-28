import AVFoundation
import Foundation

/// Remuxes an AVFoundation-readable media file (e.g. a recorded MPEG-TS) into MP4
/// without re-encoding — sample buffers are copied straight through. This lets the
/// native TS recorder produce an MP4 with no ffmpeg. (AVFoundation cannot write
/// MKV/WebM and cannot encode AV1, so those still need ffmpeg.)
public enum MP4Remuxer {
    public enum RemuxError: Error, Equatable {
        case noTracks
        case readFailed
        case writeFailed
    }

    /// Copies all video/audio tracks from `source` into an MP4 at `output`,
    /// passthrough (no transcode). Overwrites any existing output.
    public static func remux(source: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw RemuxError.noTracks }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        var pumps: [(Unchecked<AVAssetReaderTrackOutput>, Unchecked<AVAssetWriterInput>)] = []
        for track in videoTracks + audioTracks {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // passthrough
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { continue }
            reader.add(readerOutput)

            let formatHint = try await track.load(.formatDescriptions).first
            let writerInput = AVAssetWriterInput(mediaType: track.mediaType,
                                                 outputSettings: nil, sourceFormatHint: formatHint)
            writerInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerInput) else { continue }
            writer.add(writerInput)
            pumps.append((Unchecked(readerOutput), Unchecked(writerInput)))
        }
        guard !pumps.isEmpty else { throw RemuxError.noTracks }

        guard reader.startReading() else { throw RemuxError.readFailed }
        guard writer.startWriting() else { throw RemuxError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (readerOutput, writerInput) in pumps {
                group.addTask { await pump(readerOutput, into: writerInput) }
            }
        }

        if reader.status == .reading { reader.cancelReading() }
        guard reader.status != .failed else { writer.cancelWriting(); throw RemuxError.readFailed }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else { throw RemuxError.writeFailed }
    }

    /// Feeds one reader output into one writer input until drained.
    private static func pump(_ output: Unchecked<AVAssetReaderTrackOutput>,
                             into input: Unchecked<AVAssetWriterInput>) async {
        let queue = DispatchQueue(label: "ChzzkCaptureCore.remux")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.value.requestMediaDataWhenReady(on: queue) {
                while input.value.isReadyForMoreMediaData {
                    if let sample = output.value.copyNextSampleBuffer() {
                        input.value.append(sample)
                    } else {
                        input.value.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    /// Carries a non-Sendable AVFoundation object through `@Sendable` closures.
    /// Safe here: each boxed object is touched only on its own remux queue.
    private final class Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
