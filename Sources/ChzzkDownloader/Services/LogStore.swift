import Foundation
import Darwin

/// Append-only log file writer. Uses POSIX writes because FileHandle.write can
/// raise Objective-C exceptions that Swift cannot catch reliably.
final class LogStore {
    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.chzzkdownloader.log", qos: .utility)
    private var fd: Int32 = -1

    init(url: URL, maxBytes: Int = 2_000_000) {
        self.url = url
        self.maxBytes = maxBytes
        queue.async { [self] in openHandle(rotateIfLarge: true) }
    }

    func write(_ line: String) {
        queue.async { [self] in
            if fd < 0 { openHandle(rotateIfLarge: false) }
            guard fd >= 0 else { return }
            let data = Data((line + "\n").utf8)
            let ok = data.withUnsafeBytes { rawBuffer -> Bool in
                guard let base = rawBuffer.baseAddress else { return true }
                var written = 0
                while written < data.count {
                    let result = Darwin.write(fd, base.advanced(by: written), data.count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    if result == 0 { return false }
                    written += result
                }
                return true
            }
            if !ok { closeHandle() }
        }
    }

    private func openHandle(rotateIfLarge: Bool) {
        closeHandle()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if rotateIfLarge,
           let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            try? fm.removeItem(at: url)
        }
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        if fd >= 0 {
            _ = Darwin.fchmod(fd, S_IRUSR | S_IWUSR)
        }
    }

    private func closeHandle() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        queue.sync { closeHandle() }
    }
}
