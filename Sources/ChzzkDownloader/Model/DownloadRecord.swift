import Foundation

enum DownloadStatus: String, Codable {
    case downloading, completed, interrupted, failed
}

/// A persisted download history entry.
struct DownloadRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var vodURL: String          // original page URL, re-resolved when retrying
    var title: String
    var channelName: String
    var quality: Int
    var isHLS: Bool
    var duration: Int
    var finalPath: String       // destination .mp4 path
    var totalSize: Int          // bytes (0 until known)
    var fileSize: Int           // bytes written (for completed)
    var status: DownloadStatus
    var createdAt: Date
    var updatedAt: Date
    var clipStart: Double?          // segment range (optionals → old records decode fine)
    var clipEnd: Double?

    private var finalURL: URL { URL(fileURLWithPath: finalPath) }
    private var usesPostprocessSource: Bool {
        !isHLS && clipStart == nil && clipEnd == nil && finalURL.pathExtension.lowercased() == "m4a"
    }
    private var transferURL: URL {
        usesPostprocessSource ? Filename.temporaryURL(for: finalURL, suffix: ".source.mp4") : finalURL
    }

    var partPath: String { Filename.temporaryURL(for: transferURL, suffix: ".part").path }
    var sidecarPath: String { Filename.temporaryURL(for: transferURL, suffix: ".cvdresume").path }
    var legacyPartPath: String { finalPath + ".part" }
    var legacySidecarPath: String { finalPath + ".cvdresume" }
    var legacyTransferPartPath: String { Filename.legacyTemporaryURL(for: transferURL, suffix: ".part").path }
    var legacyTransferSidecarPath: String { Filename.legacyTemporaryURL(for: transferURL, suffix: ".cvdresume").path }
    var sourcePath: String? { usesPostprocessSource ? transferURL.path : nil }
    var clipSourcePath: String { Filename.temporaryURL(for: finalURL, suffix: ".clip-source.mp4").path }
    var postprocessPartPath: String { Filename.temporaryURL(for: finalURL, suffix: ".postprocess.part").path }
    var dashWorkDirPath: String { Filename.temporaryURL(for: finalURL, suffix: ".dash-\(id.uuidString)").path }
    var hlsWorkDirPath: String? {
        isHLS ? Filename.temporaryURL(for: finalURL, suffix: ".hls-\(id.uuidString)").path : nil
    }

    func removeTemporaryArtifacts() {
        for path in [
            partPath, sidecarPath,
            legacyPartPath, legacySidecarPath,
            legacyTransferPartPath, legacyTransferSidecarPath,
            clipSourcePath, postprocessPartPath,
            dashWorkDirPath,
        ] {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let hlsWorkDirPath {
            try? FileManager.default.removeItem(atPath: hlsWorkDirPath)
        }
        if let sourcePath {
            try? FileManager.default.removeItem(atPath: sourcePath)
        }
    }
}

/// Persists download history to downloads.json (atomic write).
enum DownloadStore {
    static let fileURL = ConfigStore.directory.appendingPathComponent("downloads.json")

    static func load() -> [DownloadRecord] {
        restrictPermissions()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([DownloadRecord].self, from: data) else { return [] }
        return records
    }

    static func save(_ records: [DownloadRecord]) {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        let tmp = ConfigStore.directory.appendingPathComponent("downloads.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { try? FileManager.default.removeItem(at: tmp) }
    }

    private static func restrictPermissions() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
