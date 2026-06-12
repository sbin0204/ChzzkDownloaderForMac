import Foundation

// MARK: - Cookies: status, import, refresh reminders, auth-failure handling

extension AppModel {

    // MARK: status

    private var hasAnyStoredCookie: Bool {
        !config.cookies.NID_AUT.isEmpty || !config.cookies.NID_SES.isEmpty
    }

    var hasStoredCookies: Bool {
        !config.cookies.NID_AUT.isEmpty && !config.cookies.NID_SES.isEmpty
    }

    var cookieAgeDays: Int? {
        guard let cookieUpdatedAt else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: cookieUpdatedAt)
        let end = calendar.startOfDay(for: Date())
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    var cookieNeedsRefresh: Bool {
        guard hasStoredCookies else { return true }
        return Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt)
    }

    var cookieStatusText: String {
        guard hasStoredCookies else { return hasAnyStoredCookie ? "쿠키 일부 없음" : "쿠키 없음" }
        guard let cookieUpdatedAt else { return "갱신일 기록 없음" }
        if Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt) { return "월초 갱신 필요" }
        if (Self.daysUntilNextCookieRefreshMonth() ?? 99) <= 3 { return "곧 갱신 권장" }
        return "정상"
    }

    var cookieStatusDetail: String {
        guard hasStoredCookies else {
            return "성인 인증 방송이나 일부 VOD에는 NID_AUT/NID_SES가 모두 필요합니다."
        }
        guard let cookieUpdatedAt else {
            return "마지막 갱신 시각이 없습니다. 브라우저에서 다시 가져오면 기록됩니다."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let updated = formatter.string(from: cookieUpdatedAt)
        if Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt) {
            return "마지막 갱신: \(updated). 이번 달 1일 이후 갱신 기록이 없습니다."
        }
        return "마지막 갱신: \(updated). 이번 달 쿠키로 표시됩니다."
    }

    // MARK: import

    var installedBrowsers: [Browser] { Browser.allCases.filter(\.isInstalled) }

    func importCookiesFromFirstAvailableBrowser() {
        guard let browser = installedBrowsers.first else {
            cookieImportMessage = "설치된 브라우저를 찾지 못했습니다."
            return
        }
        importCookies(from: browser)
    }

    func importCookiesOnLaunchIfNeeded() {
        guard config.auto_import_cookies_on_launch else { return }
        guard let browser = installedBrowsers.first else {
            cookieImportMessage = "앱 시작 자동 쿠키 불러오기: 설치된 브라우저를 찾지 못했습니다."
            appendLog("앱 시작 자동 쿠키 불러오기 실패: 설치된 브라우저 없음")
            return
        }
        cookieImportMessage = "앱 시작 자동 쿠키 불러오기: \(browser.displayName) 확인 중…"
        appendLog("앱 시작 자동 쿠키 불러오기: \(browser.displayName)")
        importCookies(from: browser)
    }

    func importCookies(from browser: Browser) {
        cookieImportMessage = "\(browser.displayName)에서 쿠키 가져오는 중…"
        Task {
            do {
                let imported = try await Task.detached { try CookieImporter.importCookies(browser) }.value
                if let aut = imported.aut, !aut.isEmpty { config.cookies.NID_AUT = aut }
                if let ses = imported.ses, !ses.isEmpty { config.cookies.NID_SES = ses }
                if hasStoredCookies { recordCookieRefreshDate() }
                cookieImportMessage = "\(browser.displayName)에서 쿠키를 가져왔습니다."
                appendLog("\(browser.displayName)에서 치지직 쿠키를 가져왔습니다.")
            } catch let error as CookieImportError {
                if case .needsFullDiskAccess = error { fullDiskAccessNeeded = true }
                cookieImportMessage = error.localizedDescription
                appendLog("쿠키 가져오기 실패(\(browser.displayName)): \(error.localizedDescription)")
            } catch {
                cookieImportMessage = error.localizedDescription
                appendLog("쿠키 가져오기 실패(\(browser.displayName)): \(error.localizedDescription)")
            }
        }
    }

    /// Import NID_AUT / NID_SES from a Netscape cookies.txt file.
    func importCookiesFromFile(_ url: URL) {
        do {
            let imported = try CookieImporter.importFromNetscapeFile(url)
            if let aut = imported.aut, !aut.isEmpty { config.cookies.NID_AUT = aut }
            if let ses = imported.ses, !ses.isEmpty { config.cookies.NID_SES = ses }
            if hasStoredCookies { recordCookieRefreshDate() }
            cookieImportMessage = "쿠키 파일에서 가져왔습니다."
            appendLog("쿠키 파일에서 치지직 쿠키를 가져왔습니다.")
        } catch {
            cookieImportMessage = error.localizedDescription
            appendLog("쿠키 파일 가져오기 실패: \(error.localizedDescription)")
        }
    }

    // MARK: refresh bookkeeping

    func markCookiesEdited() {
        guard hasStoredCookies else { return }
        recordCookieRefreshDate()
    }

    func markCookieRefreshConfirmed() {
        recordCookieRefreshDate()
        cookieImportMessage = "쿠키 갱신 시각을 저장했습니다."
        showToast("쿠키 갱신 상태를 저장했습니다")
    }

    private func recordCookieRefreshDate() {
        cookieUpdatedAt = Date()
        cookieAuthWarning = nil
        UserDefaults.standard.removeObject(forKey: Self.cookieRefreshReminderDayKey)
    }

    func checkCookieRefreshReminder(now: Date = Date()) {
        guard hasStoredCookies, Self.cookieNeedsMonthlyRefresh(updatedAt: cookieUpdatedAt, now: now) else { return }
        let today = Self.dayStamp(now)
        guard UserDefaults.standard.string(forKey: Self.cookieRefreshReminderDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.cookieRefreshReminderDayKey)
        cookieImportMessage = "이번 달 1일 이후 쿠키 갱신 기록이 없습니다. 브라우저에서 다시 가져오기를 권장합니다."
        showToast("치지직 쿠키 갱신을 권장합니다")
    }

    // MARK: auth-failure handling

    func markCookieAuthFailure(context: String) {
        let now = Date()
        if let lastCookieAuthWarningAt,
           now.timeIntervalSince(lastCookieAuthWarningAt) < Self.cookieAuthWarningCooldown {
            return
        }
        lastCookieAuthWarningAt = now
        let message = "\(context)에서 인증 실패가 감지되었습니다. 치지직 로그인 쿠키를 다시 가져오세요."
        cookieAuthWarning = message
        cookieImportMessage = message
        appendLog("쿠키 인증 실패 감지: \(context)")
        showToast("치지직 쿠키 갱신이 필요합니다")
    }

    func handleCookieAuthFailureIfNeeded(_ error: Error, context: String) {
        if Self.isCookieAuthError(error) {
            markCookieAuthFailure(context: context)
        }
    }

    func handleCookieAuthFailureIfNeeded(_ message: String, context: String) {
        if ChzzkAPI.looksLikeAuthFailure(message) {
            markCookieAuthFailure(context: context)
        }
    }

    private static func isCookieAuthError(_ error: Error) -> Bool {
        if let vodError = error as? VODError {
            switch vodError {
            case .invalidCookies:
                return true
            case .http(let code):
                return ChzzkAPI.isAuthFailureStatus(code)
            default:
                return false
            }
        }
        return ChzzkAPI.looksLikeAuthFailure(error.localizedDescription)
    }

    private static func dayStamp(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    nonisolated static func cookieNeedsMonthlyRefresh(
        updatedAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let updatedAt else { return true }
        let updated = calendar.dateComponents([.era, .year, .month], from: updatedAt)
        let current = calendar.dateComponents([.era, .year, .month], from: now)
        return updated.era != current.era
            || updated.year != current.year
            || updated.month != current.month
    }

    nonisolated static func daysUntilNextCookieRefreshMonth(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        let startOfToday = calendar.startOfDay(for: now)
        var components = calendar.dateComponents([.era, .year, .month], from: startOfToday)
        components.day = 1
        guard let startOfMonth = calendar.date(from: components),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) else {
            return nil
        }
        return calendar.dateComponents([.day], from: startOfToday, to: nextMonth).day
    }
}
