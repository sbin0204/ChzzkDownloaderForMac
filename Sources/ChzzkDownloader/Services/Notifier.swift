import AppKit
import Foundation
import UserNotifications

/// Posts local "completion" notifications (recording saved / download finished).
/// When a file path is attached, the notification gains "열기 / Finder에서 보기"
/// action buttons handled by the shared delegate.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let fileCategory = "FILE_DONE"
    private static let openAction = "OPEN_FILE"
    private static let revealAction = "REVEAL_IN_FINDER"

    private var configured = false

    /// UNUserNotificationCenter aborts without a real app bundle (e.g. running the
    /// bare binary), so only use it when a bundle identifier is present.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard available else { return }
        shared.configureIfNeeded()
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: "열기", options: [.foreground])
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Finder에서 보기", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.fileCategory, actions: [open, reveal],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, filePath: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let filePath {
            content.categoryIdentifier = fileCategory
            content.userInfo = ["path": filePath]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Reveal/open the saved file when an action (or the notification body) is tapped.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            switch response.actionIdentifier {
            case Self.openAction:
                NSWorkspace.shared.open(url)
            case Self.revealAction, UNNotificationDefaultActionIdentifier:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            default:
                break
            }
        }
        completionHandler()
    }
}
