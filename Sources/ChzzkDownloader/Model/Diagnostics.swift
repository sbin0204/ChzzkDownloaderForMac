import AppKit
import Foundation

extension AppModel {
    func diagnosticReport() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info["CFBundleVersion"] as? String) ?? "dev"
        let updateService = UpdateService.shared
        let recentLog = logLines.suffix(50)
            .map(Self.redactDiagnosticLogLine)
            .joined(separator: "\n")
        let channelsWithRelativeDir = config.channels.filter {
            !$0.output_dir.trimmingCharacters(in: .whitespaces).hasPrefix("/")
        }.count
        let liveSplitSize = config.live_split_size_mb > 0
            ? "\(config.live_split_size_mb)MB"
            : "끔"
        let liveSplitDuration = config.live_split_duration_minutes > 0
            ? "\(config.live_split_duration_minutes)분"
            : "끔"
        let cyclic = config.cyclic_recording_enabled
            ? "켬(파일 \(config.cyclic_max_files)개, 용량 \(config.cyclic_max_size_gb)GB)"
            : "끔"
        let vodLimit = vodSpeedLimitMBps > 0
            ? "\(String(format: "%.2f", vodSpeedLimitMBps)) MB/s"
            : "무제한"

        let report = """
        Chzzk Downloader for Mac 진단 정보
        생성 시각: \(Self.timestamp())
        앱 버전: \(appVersion) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        아키텍처: \(Self.architecture)
        번들 ID: \(Bundle.main.bundleIdentifier ?? "없음")

        저장 위치
        설정 파일: \(Self.publicPath(ConfigStore.fileURL.path))
        앱 지원 폴더: \(Self.publicPath(ConfigStore.directory.path))
        VOD 저장 폴더: \(Self.publicPath(vodOutputDir))
        상대 경로 라이브 폴더 채널 수: \(channelsWithRelativeDir)

        도구 상태
        ffmpeg: \(ffmpegPath.map(Self.publicPath) ?? "찾을 수 없음")
        streamlink: \(streamlinkPath.map(Self.publicPath) ?? "찾을 수 없음")
        내장 plugin: \(FileManager.default.fileExists(atPath: (pluginDir as NSString).appendingPathComponent("chzzk.py")) ? "확인됨" : "찾을 수 없음")

        설정 요약
        등록 채널 수: \(config.channels.count)
        예약 녹화 수: \(config.schedules.count)
        진행 중 라이브 녹화 수: \(recordingChannels.count)
        VOD 항목 수: \(vodItems.count)
        다운로드 기록 수: \(downloadRecords.count)
        라이브 포맷: \(config.output_format)
        라이브 용량 분할: \(liveSplitSize)
        라이브 시간 분할: \(liveSplitDuration)
        순환 녹화: \(cyclic)
        세그먼트 스레드: \(config.stream_segment_threads)
        VOD 동시 연결 수: \(vodConnections)
        VOD 속도 제한: \(vodLimit)
        재스캔 간격: \(config.timeout)초
        알림: \(config.notify_on_complete ? "켬" : "끔")
        웹훅 알림: \(config.notify_webhook_url.isEmpty ? "없음" : "설정됨(URL 제외)")
        로그 파일 기록: \(config.log_enabled ? "켬" : "끔")
        쿠키 저장: \((config.cookies.NID_AUT.isEmpty && config.cookies.NID_SES.isEmpty) ? "없음" : "있음(값 제외)")
        프록시: \(config.proxy.trimmingCharacters(in: .whitespaces).isEmpty ? "없음" : "설정됨(URL 제외)")

        업데이트
        Sparkle 연결: \(updateService.isSparkleLinked ? "예" : "아니오")
        Sparkle 설정: \(updateService.isConfigured ? "완료" : "미설정")
        appcast URL: \(updateService.feedURL.map { Self.redactDiagnosticText($0.absoluteString) } ?? "없음")

        최근 로그(최대 50줄, 민감정보 마스킹)
        \(recentLog.isEmpty ? "없음" : recentLog)
        """

        return Self.redactDiagnosticText(report)
    }

    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport(), forType: .string)
        showToast("진단 정보가 복사되었습니다.")
    }

    /// Path helpers used by the Info / Updates panes to show file locations and
    /// the appcast URL without leaking the username or query secrets.
    nonisolated static func abbreviateHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    nonisolated static func publicPath(_ path: String) -> String {
        var redacted = abbreviateHome(path)
        redacted = redacted.replacingOccurrences(
            of: #"/Users/[^/\s]+"#,
            with: "~",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"/Volumes/[^/\n]+"#,
            with: "/Volumes/<volume>",
            options: .regularExpression
        )
        return redacted
    }

    nonisolated static func redactDiagnosticText(_ text: String) -> String {
        var redacted = publicPath(text)
        let replacements: [(String, String)] = [
            (#"(?i)(NID_AUT\s*[=:]\s*)[^;\s]+"#, "$1<redacted>"),
            (#"(?i)(NID_SES\s*[=:]\s*)[^;\s]+"#, "$1<redacted>"),
            (#"(?i)(Cookie:\s*)[^\n]+"#, "$1<redacted>"),
            (#"(https?://)([^:/@\s]+):([^@\s]+)@"#, "$1<redacted>@"),
            (#"(?i)(https://api\.telegram\.org/bot)[^/\s?]+"#, "$1<redacted>"),
            (#"(?i)(https://(?:canary\.)?discord(?:app)?\.com/api/webhooks/)[^/\s?]+/[^?\s]+"#, "$1<redacted>"),
            (#"(?i)(https://hooks\.slack\.com/services/)[^?\s]+"#, "$1<redacted>"),
            (#"(?i)([?&](?:token|key|signature|sig|auth|access_token|inKey)=)[^&\s]+"#, "$1<redacted>"),
            (#"(https?://[^\s?]+)\?[^ \n]+"#, "$1?<redacted>"),
            (#"(volume “)[^”]+(”)"#, "$1<redacted>$2")
        ]
        for (pattern, replacement) in replacements {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return redacted
    }

    nonisolated static func capacitySummary(_ bytes: Int64?) -> String {
        guard let bytes else { return "확인 불가" }
        return ProgressParser.formatSize(Double(bytes))
    }

    nonisolated static func redactDiagnosticLogLine(_ line: String) -> String {
        var redacted = redactDiagnosticText(line)
        redacted = redacted.replacingOccurrences(
            of: #"(?<=VOD 다운로드 시작: ).*(?= \()"#,
            with: "<title redacted>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?<=VOD 저장 완료: ).*$"#,
            with: "<path redacted>",
            options: .regularExpression
        )
        return redacted
    }

    private nonisolated static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
