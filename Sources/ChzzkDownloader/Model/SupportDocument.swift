import Foundation

enum SupportDocument: CaseIterable {
    case license
    case thirdPartyNotices
    case changelog

    var title: String {
        switch self {
        case .license: return "앱 라이선스"
        case .thirdPartyNotices: return "오픈소스 고지"
        case .changelog: return "변경 사항"
        }
    }

    var filename: String {
        switch self {
        case .license: return "LICENSE"
        case .thirdPartyNotices: return "THIRD_PARTY_NOTICES.md"
        case .changelog: return "CHANGELOG.md"
        }
    }

    var fallback: String {
        switch self {
        case .license: return "LICENSE 문서를 찾을 수 없습니다."
        case .thirdPartyNotices: return "THIRD_PARTY_NOTICES.md 문서를 찾을 수 없습니다."
        case .changelog: return "CHANGELOG.md 문서를 찾을 수 없습니다."
        }
    }
}

enum BundledSupportDocument {
    static func read(_ document: SupportDocument) -> String? {
        read(filename: document.filename)
    }

    static func read(filename: String) -> String? {
        candidateURLs(filename: filename)
            .lazy
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .first
    }

    private static func candidateURLs(filename: String) -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("Documents").appendingPathComponent(filename))
            urls.append(resourceURL.appendingPathComponent(filename))
        }
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(filename))
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ChzzkDownloader/Resources/Documents")
            .appendingPathComponent(filename))
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
