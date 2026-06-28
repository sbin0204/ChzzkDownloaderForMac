import XCTest
import AVFoundation
@testable import ChzzkCaptureCore

/// Verifies the passthrough remux plumbing end-to-end with NO ffmpeg: a tiny
/// H.264 movie is synthesized via AVAssetWriter, remuxed, and the output is
/// re-opened to confirm it carries a playable video track.
final class MP4RemuxerTests: XCTestCase {
    func testRemuxesSyntheticMovieToReadableMP4() async throws {
        let dir = FileManager.default.temporaryDirectory
        let source = dir.appendingPathComponent("remux-src-\(UUID().uuidString).mov")
        let output = dir.appendingPathComponent("remux-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }

        try await makeSyntheticMovie(at: source, frames: 20, size: 160)

        try await MP4Remuxer.remux(source: source, to: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1, "remuxed MP4 should have one video track")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "remuxed MP4 should have non-zero duration")
    }

    func testThrowsOnSourceWithoutTracks() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).mp4")
        do {
            try await MP4Remuxer.remux(source: empty, to: output)
            XCTFail("expected remux of a non-media file to throw")
        } catch {
            // any error is acceptable (noTracks, or AVAssetReader init failure)
        }
    }

    // MARK: - synthetic source

    private func makeSyntheticMovie(at url: URL, frames: Int, size: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard writer.canAdd(input) else { throw XCTSkip("AVAssetWriter cannot add H.264 input here") }
        writer.add(input)
        guard writer.startWriting() else { throw XCTSkip("AVAssetWriter could not start (no encoder?)") }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let pb = try makePixelBuffer(size: size, value: UInt8((i * 12) % 255))
            let pts = CMTime(value: CMTimeValue(i), timescale: fps)
            adaptor.append(pb, withPresentationTime: pts)
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else { throw XCTSkip("synthetic encode failed: \(String(describing: writer.error))") }
    }

    private func makePixelBuffer(size: Int, value: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { throw XCTSkip("CVPixelBuffer alloc failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(value), CVPixelBufferGetBytesPerRow(buffer) * size)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
