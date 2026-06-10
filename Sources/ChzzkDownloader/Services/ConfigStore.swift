import Foundation

/// Loads and persists config.json, mirroring save_config in settings.py
/// (normalize on write, atomic replace, 0600 perms).
enum ConfigStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChzzkDownloader", isDirectory: true)
    }()

    static let fileURL = directory.appendingPathComponent("config.json")

    static func load() -> Config {
        restrictPermissions()
        guard let data = try? Data(contentsOf: fileURL) else {
            var c = Config(); c.normalize(); return c
        }
        do {
            var c = try JSONDecoder().decode(Config.self, from: data)
            c.normalize()
            return c
        } catch {
            var c = Config(); c.normalize(); return c
        }
    }

    static func save(_ config: Config) {
        var c = config
        c.normalize()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(c) else { return }
        let tmp = directory.appendingPathComponent("config.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func restrictPermissions() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
