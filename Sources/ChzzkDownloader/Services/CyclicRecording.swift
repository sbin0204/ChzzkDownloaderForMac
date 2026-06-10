import Foundation

/// Keeps each channel's recordings within a file-count and/or total-size budget
/// by moving the oldest finished files to the Trash (recoverable, not erased).
enum CyclicRecording {
    struct Candidate: Equatable {
        let url: URL
        let date: Date
        let size: Int64
    }

    /// Enforces the limits for `channelName` in the folder that holds `savedPath`.
    /// `0` limits are ignored. Returns the names of the files moved to Trash.
    static func enforce(channelName: String, savedPath: String,
                        maxFiles: Int, maxSizeGB: Int) -> [String] {
        guard maxFiles > 0 || maxSizeGB > 0 else { return [] }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: savedPath).deletingLastPathComponent()
        let files = recordingCandidates(in: dir, channelName: channelName)
        let selected = trashCandidates(
            from: files,
            protectedPath: savedPath,
            maxFiles: maxFiles,
            maxSizeGB: maxSizeGB)
        var trashed: [String] = []
        for item in selected {
            guard (try? fm.trashItem(at: item.url, resultingItemURL: nil)) != nil else { continue }
            trashed.append(item.url.lastPathComponent)
        }
        return trashed
    }

    /// Finished recording files for a channel in the given directory. Hidden temp
    /// files and legacy sidecars are deliberately ignored.
    static func recordingCandidates(in dir: URL, channelName: String) -> [Candidate] {
        let fm = FileManager.default
        // RecordingEngine runs the full component through Filename.shortenedComponent,
        // so the channel token must be sanitized the same way before matching.
        let safeChannelName = Validate.sanitizeFilename(channelName, fallback: "channel")
        let marker = "] \(safeChannelName) "
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var files: [Candidate] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("["), name.contains(marker) else { continue }
            if name.hasSuffix(".part") || name.hasSuffix(".cvdresume") { continue }
            let vals = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            files.append(Candidate(
                url: url,
                date: vals?.contentModificationDate ?? .distantPast,
                size: Int64(vals?.fileSize ?? 0)))
        }
        return files.sorted {
            if $0.date == $1.date { return $0.url.path < $1.url.path }
            return $0.date < $1.date
        }
    }

    /// Returns the oldest files that should be moved to Trash. `protectedPath`
    /// is the file that was just saved and is never selected.
    static func trashCandidates(from files: [Candidate], protectedPath: String,
                                maxFiles: Int, maxSizeGB: Int) -> [Candidate] {
        guard maxFiles > 0 || maxSizeGB > 0 else { return [] }
        let files = files.sorted {
            if $0.date == $1.date { return $0.url.path < $1.url.path }
            return $0.date < $1.date
        }
        let maxBytes = Int64(maxSizeGB) * 1_073_741_824
        var count = files.count
        var totalSize = files.reduce(Int64(0)) { $0 + $1.size }
        let protected = normalizedPath(protectedPath)
        var selected: [Candidate] = []

        var index = 0
        while index < files.count {
            let overCount = maxFiles > 0 && count > maxFiles
            let overSize = maxSizeGB > 0 && totalSize > maxBytes
            guard overCount || overSize else { break }
            let item = files[index]
            index += 1
            if normalizedPath(item.url.path) == protected { continue }
            selected.append(item)
            count -= 1
            totalSize -= item.size
        }
        return selected
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
