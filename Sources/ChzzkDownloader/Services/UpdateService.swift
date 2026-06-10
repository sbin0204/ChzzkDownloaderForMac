import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    let feedURL: URL?
    let hasPublicKey: Bool

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController?
    #endif

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedText = (info["SUFeedURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keyText = (info["SUPublicEDKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feed = URL(string: feedText)

        self.feedURL = feed
        self.hasPublicKey = !keyText.isEmpty

        #if canImport(Sparkle)
        if let feed, Self.isUsableFeedURL(feed), !keyText.isEmpty {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            self.updaterController = nil
        }
        #endif
    }

    var isConfigured: Bool {
        guard let feedURL else { return false }
        return Self.isUsableFeedURL(feedURL) && hasPublicKey
    }

    nonisolated static func isUsableFeedURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    var isSparkleLinked: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func checkForUpdates() -> Bool {
        #if canImport(Sparkle)
        guard let updaterController else { return false }
        updaterController.checkForUpdates(nil)
        return true
        #else
        return false
        #endif
    }
}
