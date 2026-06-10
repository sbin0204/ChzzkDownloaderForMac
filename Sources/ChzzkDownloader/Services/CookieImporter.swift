import Foundation
import CommonCrypto

struct BrowserCookies {
    var aut: String?
    var ses: String?
    var found: Bool { (aut?.isEmpty == false) || (ses?.isEmpty == false) }
}

/// Imports Chzzk (naver.com) NID_AUT / NID_SES cookies from a local browser,
/// like yt-dlp's --cookies-from-browser. Chromium values are decrypted with the
/// Keychain "Safe Storage" key; Firefox/Safari are read directly.
enum Browser: String, CaseIterable, Identifiable {
    case chrome, whale, edge, brave, vivaldi, chromium, firefox, safari
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .whale: return "Whale"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .vivaldi: return "Vivaldi"
        case .chromium: return "Chromium"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    private static var support: String { "\(NSHomeDirectory())/Library/Application Support" }

    /// Base profile dir for chromium browsers; nil for firefox/safari.
    var chromiumBase: String? {
        switch self {
        case .chrome: return "\(Self.support)/Google/Chrome"
        case .whale: return "\(Self.support)/Naver/Whale"
        case .edge: return "\(Self.support)/Microsoft Edge"
        case .brave: return "\(Self.support)/BraveSoftware/Brave-Browser"
        case .vivaldi: return "\(Self.support)/Vivaldi"
        case .chromium: return "\(Self.support)/Chromium"
        default: return nil
        }
    }

    var keychainService: String? {
        switch self {
        case .chrome: return "Chrome Safe Storage"
        case .whale: return "Whale Safe Storage"
        case .edge: return "Microsoft Edge Safe Storage"
        case .brave: return "Brave Safe Storage"
        case .vivaldi: return "Vivaldi Safe Storage"
        case .chromium: return "Chromium Safe Storage"
        default: return nil
        }
    }

    var isInstalled: Bool {
        switch self {
        case .firefox: return !firefoxProfiles().isEmpty
        case .safari: return FileManager.default.fileExists(atPath: "/Applications/Safari.app")
        default:
            guard let base = chromiumBase else { return false }
            return CookieImporter.chromiumCookiesPath(base) != nil
        }
    }

    func firefoxProfiles() -> [String] {
        let dir = "\(Self.support)/Firefox/Profiles"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return items.map { "\(dir)/\($0)/cookies.sqlite" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

enum CookieImportError: LocalizedError {
    case notInstalled, keychainDenied, noCookies, needsFullDiskAccess, readFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "해당 브라우저를 찾을 수 없습니다."
        case .keychainDenied: return "키체인 접근이 거부되었습니다. 다시 시도하고 '항상 허용'을 눌러주세요."
        case .needsFullDiskAccess: return "Safari 쿠키를 읽으려면 ‘전체 디스크 접근’ 권한이 필요합니다."
        case .noCookies: return "이 브라우저에서 치지직(naver.com) 로그인 쿠키를 찾지 못했습니다. 먼저 브라우저에서 로그인하세요."
        case .readFailed(let m): return "쿠키를 읽지 못했습니다: \(m)"
        }
    }
}

enum CookieImporter {
    /// Imports NID_AUT / NID_SES from a Netscape-format cookies.txt
    /// (the standard yt-dlp / curl / browser-extension cookie jar format).
    static func importFromNetscapeFile(_ url: URL) throws -> BrowserCookies {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CookieImportError.readFailed("파일을 읽을 수 없습니다.")
        }
        var result = BrowserCookies()
        for var line in text.components(separatedBy: .newlines) {
            line = line.replacingOccurrences(of: "#HttpOnly_", with: "")
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let f = line.components(separatedBy: "\t")
            guard f.count >= 7 else { continue }
            let domain = f[0], name = f[5], value = f[6]
            guard domain.contains("naver.com") else { continue }
            if name == "NID_AUT" { result.aut = value }
            if name == "NID_SES" { result.ses = value }
        }
        guard result.found else { throw CookieImportError.noCookies }
        return result
    }

    static func importCookies(_ browser: Browser) throws -> BrowserCookies {
        guard browser.isInstalled else { throw CookieImportError.notInstalled }
        switch browser {
        case .firefox: return try importFirefox(browser)
        case .safari: return try importSafari()
        default: return try importChromium(browser)
        }
    }

    // MARK: Chromium

    static func chromiumCookiesPath(_ base: String) -> String? {
        let fm = FileManager.default
        let def = "\(base)/Default/Cookies"
        if fm.fileExists(atPath: def) { return def }
        // Fall back to the first profile that has a Cookies DB.
        let profiles = (try? fm.contentsOfDirectory(atPath: base)) ?? []
        for p in profiles {
            let cand = "\(base)/\(p)/Cookies"
            if fm.fileExists(atPath: cand) { return cand }
        }
        return nil
    }

    private static func importChromium(_ browser: Browser) throws -> BrowserCookies {
        guard let base = browser.chromiumBase, let dbPath = chromiumCookiesPath(base),
              let service = browser.keychainService else { throw CookieImportError.notInstalled }

        guard let password = keychainPassword(service: service), !password.isEmpty else {
            throw CookieImportError.keychainDenied
        }
        guard let key = pbkdf2SHA1(password: password, salt: "saltysalt", rounds: 1003, keyLen: 16) else {
            throw CookieImportError.readFailed("키 유도 실패")
        }

        let rows = try queryCookies(dbPath: dbPath,
            sql: "SELECT name, hex(encrypted_value) FROM cookies " +
                 "WHERE host_key LIKE '%naver.com%' AND name IN ('NID_AUT','NID_SES');")
        var result = BrowserCookies()
        let iv = Data(repeating: 0x20, count: 16)
        for (name, hex) in rows {
            guard let enc = dataFromHex(hex), enc.count > 3 else { continue }
            let prefix = String(decoding: enc.prefix(3), as: UTF8.self)
            let body = (prefix == "v10" || prefix == "v11") ? enc.dropFirst(3) : enc[...]
            guard let dec = aesCBCDecrypt(Data(body), key: key, iv: iv) else { continue }
            let value = cleanDecrypted(dec)
            if name == "NID_AUT" { result.aut = value }
            if name == "NID_SES" { result.ses = value }
        }
        guard result.found else { throw CookieImportError.noCookies }
        return result
    }

    /// Strip a possible 32-byte domain-hash prefix some Chrome versions prepend,
    /// then decode the remaining ASCII cookie value.
    private static func cleanDecrypted(_ data: Data) -> String {
        func printable(_ d: Data) -> Bool { d.allSatisfy { $0 >= 0x20 && $0 < 0x7f } }
        if printable(data) { return String(decoding: data, as: UTF8.self) }
        if data.count > 32 {
            let tail = data.dropFirst(32)
            if printable(tail) { return String(decoding: tail, as: UTF8.self) }
        }
        return String(decoding: data.filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self)
    }

    // MARK: Firefox

    private static func importFirefox(_ browser: Browser) throws -> BrowserCookies {
        guard let db = browser.firefoxProfiles().first else { throw CookieImportError.notInstalled }
        let rows = try queryCookies(dbPath: db,
            sql: "SELECT name, value FROM moz_cookies " +
                 "WHERE host LIKE '%naver.com%' AND name IN ('NID_AUT','NID_SES');")
        var result = BrowserCookies()
        for (name, value) in rows {
            if name == "NID_AUT" { result.aut = value }
            if name == "NID_SES" { result.ses = value }
        }
        guard result.found else { throw CookieImportError.noCookies }
        return result
    }

    // MARK: Safari (binarycookies)

    static func safariPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "\(home)/Library/Cookies/Cookies.binarycookies",
        ]
    }

    private static func importSafari() throws -> BrowserCookies {
        // The cookie file is TCC-protected: an unreadable file almost always means
        // the app hasn't been granted Full Disk Access yet.
        var data: Data?
        for path in safariPaths() {
            if let d = FileManager.default.contents(atPath: path) { data = d; break }
        }
        guard let data else { throw CookieImportError.needsFullDiskAccess }
        let cookies = BinaryCookies.parse(data)
        var result = BrowserCookies()
        for c in cookies where c.domain.contains("naver.com") {
            if c.name == "NID_AUT" { result.aut = c.value }
            if c.name == "NID_SES" { result.ses = c.value }
        }
        guard result.found else { throw CookieImportError.noCookies }
        return result
    }

    // MARK: shared helpers

    private static func keychainPassword(service: String) -> String? {
        let out = runCommand("/usr/bin/security", ["find-generic-password", "-ws", service])
        let trimmed = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Copies the (possibly locked) DB to a temp file, then queries via sqlite3.
    private static func queryCookies(dbPath: String, sql: String) throws -> [(String, String)] {
        let tmp = NSTemporaryDirectory() + "ck_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do { try FileManager.default.copyItem(atPath: dbPath, toPath: tmp) }
        catch { throw CookieImportError.readFailed(error.localizedDescription) }

        let sqlite = FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")
            ? "/usr/bin/sqlite3" : (Tooling.locate("sqlite3") ?? "/usr/bin/sqlite3")
        guard let out = runCommand(sqlite, [tmp, "-separator", "\u{1}", sql]) else {
            throw CookieImportError.readFailed("sqlite3 실행 실패")
        }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1}")
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
    }

    private static func runCommand(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next > idx, let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }

    private static func pbkdf2SHA1(password: String, salt: String, rounds: Int, keyLen: Int) -> Data? {
        let pw = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: keyLen)
        let status = pw.withUnsafeBufferPointer { pwPtr in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress, pw.count,
                    saltPtr.baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(rounds),
                    &derived, keyLen)
            }
        }
        return status == kCCSuccess ? Data(derived) : nil
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        let bufLen = data.count + kCCBlockSizeAES128
        var buf = [UInt8](repeating: 0, count: bufLen)
        var moved = 0
        let status = data.withUnsafeBytes { inPtr in
            key.withUnsafeBytes { kPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kPtr.baseAddress, key.count, ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            &buf, bufLen, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(buf.prefix(moved))
    }
}
