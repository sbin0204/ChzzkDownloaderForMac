import Foundation

/// Resolves a possibly-relative HLS URI against a base URL. Shared by the reader
/// and resolver so segment/variant URL handling is identical everywhere.
public enum HLSURL {
    public static func resolve(_ reference: String, against base: String) -> String {
        if reference.hasPrefix("http://") || reference.hasPrefix("https://") { return reference }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: reference, relativeTo: baseURL)?.absoluteString else {
            return reference
        }
        return resolved
    }
}

/// A parsed HLS *master* playlist: the quality variants and how to pick one.
public struct HLSMasterPlaylist: Equatable, Sendable {
    public struct Variant: Equatable, Sendable {
        public let bandwidth: Int
        public let width: Int
        public let height: Int
        public let uri: String           // resolved to absolute against the master URL
        public var shortSide: Int { height > 0 ? height : width }
    }

    public let variants: [Variant]

    /// Parses a master playlist, resolving each variant URI against `masterURL`.
    /// Returns nil if there are no `#EXT-X-STREAM-INF` variants (i.e. not a master).
    public static func parse(_ text: String, masterURL: String) -> HLSMasterPlaylist? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var variants: [Variant] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                // The URI is the next non-comment, non-empty line.
                var uriLine: String?
                var j = index + 1
                while j < lines.count {
                    let candidate = lines[j]
                    if !candidate.isEmpty, !candidate.hasPrefix("#") { uriLine = candidate; break }
                    j += 1
                }
                if let uriLine {
                    let (w, h) = resolution(in: line)
                    variants.append(Variant(
                        bandwidth: intAttribute("BANDWIDTH", in: line) ?? 0,
                        width: w, height: h,
                        uri: HLSURL.resolve(uriLine, against: masterURL)))
                }
                index = j + 1
            } else {
                index += 1
            }
        }
        return variants.isEmpty ? nil : HLSMasterPlaylist(variants: variants)
    }

    /// Picks a variant for a quality token: "best"/"worst", or a height like
    /// "1080p"/"720" (exact match preferred, else nearest). Falls back to highest.
    public func select(quality: String) -> Variant? {
        guard !variants.isEmpty else { return nil }
        let q = quality.lowercased().trimmingCharacters(in: .whitespaces)
        if q == "best" || q.isEmpty { return variants.max(by: { $0.shortSide < $1.shortSide }) }
        if q == "worst" { return variants.min(by: { $0.shortSide < $1.shortSide }) }
        let digits = q.filter(\.isNumber)
        guard let target = Int(digits) else { return variants.max(by: { $0.shortSide < $1.shortSide }) }
        if let exact = variants.first(where: { $0.shortSide == target }) { return exact }
        return variants.min(by: { abs($0.shortSide - target) < abs($1.shortSide - target) })
    }

    // MARK: helpers

    private static func intAttribute(_ name: String, in line: String) -> Int? {
        guard let r = line.range(of: "\(name)=") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix(while: \.isNumber)
        return Int(digits)
    }

    private static func resolution(in line: String) -> (Int, Int) {
        guard let r = line.range(of: "RESOLUTION=") else { return (0, 0) }
        let rest = line[r.upperBound...]
        let token = rest.prefix(while: { $0.isNumber || $0 == "x" })
        let parts = token.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return (0, 0) }
        return (w, h)
    }
}
