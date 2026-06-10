import Foundation

/// Parses ffmpeg `-progress` key=value output into ChannelProgress
/// (bitrate, rolling download speed, sizes).
final class ProgressParser {
    var onUpdate: ((ChannelProgress) -> Void)?

    private let channelID: String
    private let channelName: String
    private let startTime: String
    private var summary: [String: String] = [:]
    private var speedSamples: [Double] = []
    private var prevTotalSize: Int?
    private var prevTime: TimeInterval?

    init(channelID: String, channelName: String, startTime: String) {
        self.channelID = channelID
        self.channelName = channelName
        self.startTime = startTime
    }

    func feed(_ line: String) {
        guard let eq = line.firstIndex(of: "=") else { return }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        summary[key] = value
        guard key == "progress" else { return }

        let totalSize = Int(summary["total_size"] ?? "0") ?? 0
        let outTime = summary["out_time"] ?? "0"
        let outSeconds = Self.parseTime(outTime)

        let bitrate: String
        if outSeconds > 0 {
            let kbps = (Double(totalSize) * 8) / outSeconds / 1000
            bitrate = String(format: "%.2f kbps", kbps)
        } else {
            bitrate = "N/A"
        }

        let now = Date().timeIntervalSince1970
        var downloadSpeed = "N/A"
        if let pSize = prevTotalSize, let pTime = prevTime {
            let bytesDiff = Double(totalSize - pSize)
            let timeDiff = now - pTime
            if timeDiff > 0 {
                speedSamples.append(bytesDiff / timeDiff)
                if speedSamples.count > 5 { speedSamples.removeFirst(speedSamples.count - 5) }
                let avg = speedSamples.reduce(0, +) / Double(speedSamples.count)
                downloadSpeed = Self.formatSize(avg) + "/s"
            }
        }
        prevTotalSize = totalSize
        prevTime = now

        onUpdate?(ChannelProgress(
            id: channelID, channelName: channelName,
            bitrate: bitrate, downloadSpeed: downloadSpeed,
            totalSize: Self.formatSize(Double(totalSize)),
            outTime: outTime, startTime: startTime))
        summary.removeAll()
    }

    static func parseTime(_ s: String) -> Double {
        // HH:MM:SS.frac
        let parts = s.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let secParts = parts[2].split(separator: ".")
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let sec = Double(secParts[0]) ?? 0
        var frac = 0.0
        if secParts.count == 2, let f = Double(secParts[1]) {
            frac = f / pow(10.0, Double(secParts[1].count))
        }
        return h * 3600 + m * 60 + sec + frac
    }

    static func formatSize(_ bytes: Double) -> String {
        if bytes <= 0 { return "0 B" }
        let names = ["B", "KB", "MB", "GB", "TB"]
        var size = bytes, i = 0
        while size >= 1024 && i < names.count - 1 { size /= 1024; i += 1 }
        return String(format: "%.2f %@", size, names[i])
    }
}
