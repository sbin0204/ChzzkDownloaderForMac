import CryptoKit
import Foundation

enum Filename {
    /// Keep final names well below APFS' 255-byte component limit so temporary
    /// suffixes and uniqueness markers cannot push related paths over the edge.
    static let maxFinalComponentBytes = 120
    static let maxTemporaryComponentBytes = 80

    static func shortenedComponent(_ filename: String, maxBytes: Int = maxFinalComponentBytes) -> String {
        let cleaned = Validate.sanitizeFilename(filename, fallback: "download")
        guard cleaned.utf8.count > maxBytes else { return cleaned }

        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        let compoundExt = ext.isEmpty ? "" : ".\(ext)"
        let hashValue = shortHash(cleaned)
        let reserved = compoundExt.utf8.count + hashValue.utf8.count + 1
        let maxStemBytes = max(1, maxBytes - reserved)
        let prefix = prefixByUTF8Bytes(stem, maxBytes: maxStemBytes)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        let readable = prefix.isEmpty ? "download" : prefix
        return "\(readable)_\(hashValue)\(compoundExt)"
    }

    static func shortenedComponent(
        prefix: String,
        preservingTail tail: String,
        maxBytes: Int = maxFinalComponentBytes
    ) -> String {
        let safePrefix = Validate.sanitizeFilename(prefix, fallback: "download")
        let safeTail = tail
        let full = safePrefix + safeTail
        guard full.utf8.count > maxBytes else { return full }

        let hashValue = shortHash(full)
        let reserved = safeTail.utf8.count + hashValue.utf8.count + 1
        let maxPrefixBytes = max(1, maxBytes - reserved)
        let shortenedPrefix = prefixByUTF8Bytes(safePrefix, maxBytes: maxPrefixBytes)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        let readable = shortenedPrefix.isEmpty ? "download" : shortenedPrefix
        return "\(readable)_\(hashValue)\(safeTail)"
    }

    static func temporaryURL(for finalOutput: URL, suffix: String) -> URL {
        let safeSuffix = Validate.sanitizeFilename(suffix, fallback: "tmp")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        let tail = safeSuffix.isEmpty ? "tmp" : safeSuffix
        let component = "cvd-\(shortHash(finalOutput.path + suffix)).\(tail)"
        let safeComponent = shortenedComponent(component, maxBytes: max(1, maxTemporaryComponentBytes - 1))
        return finalOutput.deletingLastPathComponent().appendingPathComponent("." + safeComponent)
    }

    private static func previousVisibleTemporaryURL(for finalOutput: URL, suffix: String) -> URL {
        let safeSuffix = Validate.sanitizeFilename(suffix, fallback: "tmp")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        let tail = safeSuffix.isEmpty ? "tmp" : safeSuffix
        let component = ".cvd-\(shortHash(finalOutput.path + suffix)).\(tail)"
        let safeComponent = shortenedComponent(component, maxBytes: maxTemporaryComponentBytes)
        return finalOutput.deletingLastPathComponent().appendingPathComponent(safeComponent)
    }

    static func legacyTemporaryURL(for finalOutput: URL, suffix: String) -> URL {
        URL(fileURLWithPath: finalOutput.path + suffix)
    }

    static func migrateLegacyTemporary(for finalOutput: URL, suffix: String) -> URL {
        let safe = temporaryURL(for: finalOutput, suffix: suffix)
        guard !FileManager.default.fileExists(atPath: safe.path) else { return safe }
        for legacy in [
            legacyTemporaryURL(for: finalOutput, suffix: suffix),
            previousVisibleTemporaryURL(for: finalOutput, suffix: suffix)
        ] where legacy.path != safe.path && FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: safe)
            return safe
        }
        return safe
    }

    static func removeTemporary(for finalOutput: URL, suffix: String) {
        let safe = temporaryURL(for: finalOutput, suffix: suffix)
        let legacy = legacyTemporaryURL(for: finalOutput, suffix: suffix)
        let previousVisible = previousVisibleTemporaryURL(for: finalOutput, suffix: suffix)
        try? FileManager.default.removeItem(at: safe)
        if legacy.path != safe.path {
            try? FileManager.default.removeItem(at: legacy)
        }
        if previousVisible.path != safe.path {
            try? FileManager.default.removeItem(at: previousVisible)
        }
    }

    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
            .description
    }

    private static func prefixByUTF8Bytes(_ value: String, maxBytes: Int) -> String {
        var output = ""
        var count = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard count + bytes <= maxBytes else { break }
            output.append(character)
            count += bytes
        }
        return output
    }
}
