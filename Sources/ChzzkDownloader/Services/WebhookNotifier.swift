import Foundation

/// Fire-and-forget status pings to a user-supplied webhook so you can get
/// "recording started / finished" messages while away from the Mac.
///
/// - Discord / Slack / generic JSON endpoints: POST `{"content": …, "text": …}`.
/// - Telegram bot API (`…/sendMessage?chat_id=<id>`): the message is appended as
///   the `text` query parameter.
enum WebhookNotifier {
    static func isUsableURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    static func makeRequest(urlString: String, message: String) -> URLRequest? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = URL(string: trimmed),
              isUsableURL(base),
              let host = base.host else { return nil }

        if host.contains("telegram.org") {
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                return nil
            }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "text" }
            items.append(URLQueryItem(name: "text", value: message))
            components.queryItems = items
            guard let full = components.url else { return nil }
            var req = URLRequest(url: full)
            req.httpMethod = "GET"
            req.timeoutInterval = 15
            return req
        }

        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        // "content" satisfies Discord; "text" satisfies Slack and most others.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": message, "text": message])
        return req
    }

    static func send(_ urlString: String, _ message: String) {
        guard let request = makeRequest(urlString: urlString, message: message) else { return }

        // Hold the (possibly proxied) session alive until the request completes.
        Task.detached {
            let session = ProxySupport.session()
            _ = try? await session.data(for: request)
        }
    }
}
