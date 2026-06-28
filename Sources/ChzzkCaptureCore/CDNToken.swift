import Foundation

/// Chzzk CDN tokens are embedded in the stream URL (e.g. `…hdntl=exp=<ts>~hmac=…`
/// or an `exp=<ts>` query value) and expire. The live reader must re-resolve the
/// stream before expiry. Mirrors the plugin's `_get_expire_time` / `_should_refresh`.
public enum CDNToken {
    /// The first `exp=<digits>` found anywhere in the URL, as a Date. Nil if absent
    /// (then only reactive on-failure refresh applies).
    public static func expiry(in url: String) -> Date? {
        guard let range = url.range(of: #"exp=(\d+)"#, options: .regularExpression) else { return nil }
        let digits = url[range].dropFirst("exp=".count)
        guard let seconds = TimeInterval(digits) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Seconds until the token expires (negative if already expired); nil if no token.
    public static func secondsUntilExpiry(in url: String, now: Date = Date()) -> TimeInterval? {
        expiry(in: url).map { $0.timeIntervalSince(now) }
    }

    /// True when the token is within `before` seconds of expiring (or already
    /// expired). Default 3h matches the plugin's proactive-refresh threshold.
    public static func needsRefresh(in url: String, now: Date = Date(), before: TimeInterval = 3 * 60 * 60) -> Bool {
        guard let remaining = secondsUntilExpiry(in: url, now: now) else { return false }
        return remaining <= before
    }
}
