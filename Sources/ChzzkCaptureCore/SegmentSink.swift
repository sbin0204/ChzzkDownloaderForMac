import Foundation

/// Where decoded live segments are written. The default path appends MPEG-TS
/// segments straight to a `.ts` file — TS is concatenatable, so this yields a
/// playable recording with no ffmpeg. Fragmented-MP4 or container conversion
/// (MP4/MKV) needs a muxer and is handled elsewhere.
public protocol SegmentSink: AnyObject {
    func write(_ data: Data) throws
    func close()
}

/// Appends raw segment bytes to a file. For MPEG-TS this is a complete recorder.
public final class TSFileSink: SegmentSink {
    private let handle: FileHandle
    public private(set) var bytesWritten: Int = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    public func close() {
        try? handle.close()
    }
}

/// In-memory sink for tests and for piping into a muxer's stdin later.
public final class DataSegmentSink: SegmentSink {
    public private(set) var data = Data()
    public init() {}
    public func write(_ data: Data) throws { self.data.append(data) }
    public func close() {}
}
