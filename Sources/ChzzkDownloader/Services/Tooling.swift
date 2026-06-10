import Foundation

/// Locates ffmpeg and streamlink. A user-specified override path wins; otherwise
/// it searches PATH plus common install locations (GUI apps launched from Finder
/// don't inherit the shell PATH, so the fixed list below does the real work).
enum Tooling {
    static let searchDirs = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",   // Homebrew (Apple Silicon)
        "/usr/local/bin", "/usr/local/sbin",          // Homebrew (Intel) / manual copy
        "/opt/local/bin", "/opt/local/sbin",          // MacPorts
        "/usr/bin", "/bin",
        "\(NSHomeDirectory())/.local/bin",            // pipx / pip --user
        "\(NSHomeDirectory())/bin",                   // common personal bin
    ]

    /// True when `path` resolves to an existing executable file (expands `~`).
    static func isValidExecutable(_ path: String) -> Bool {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return !expanded.isEmpty && FileManager.default.isExecutableFile(atPath: expanded)
    }

    /// Resolves a tool. A valid `override` is used directly; an empty or invalid
    /// override falls through to auto-detection so a typo never fully breaks the app.
    static func locate(_ name: String, override: String? = nil) -> String? {
        if let override, isValidExecutable(override) {
            return (override.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var ffmpegPath: String? { locate("ffmpeg") }
    static var streamlinkPath: String? { locate("streamlink") }
}
