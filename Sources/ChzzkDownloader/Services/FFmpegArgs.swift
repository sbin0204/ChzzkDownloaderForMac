import Foundation

/// Builds the streamlink and ffmpeg argument lists.
enum FFmpegArgs {

    // MARK: helpers

    static func calculateBufsize(_ maxBitrate: String, fallback: String = "16000k") -> String {
        guard let kbps = bitrateKbps(maxBitrate) else { return fallback }
        return "\(kbps * 2)k"
    }

    static func bitrateKbps(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        let digits = text.filter(\.isNumber)
        guard let amount = Int(digits), amount > 0 else { return nil }
        if text.hasSuffix("m") { return amount * 1000 }
        if text.hasSuffix("k") || text.last?.isNumber == true { return amount }
        return nil
    }

    static func numericPreset(_ value: String, default def: String) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        return t.allSatisfy(\.isNumber) && !t.isEmpty ? t : def
    }

    static func nvencPreset(_ value: String, default def: String = "p4") -> String {
        let t = value.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("p"), t.count == 2, t.last?.isNumber == true { return t }
        if t.contains("fast") || t.contains("super") || t.contains("ultra") { return "p1" }
        if t.contains("slow") { return "p6" }
        return def
    }

    // MARK: AV1

    static func av1EncodingArgs(_ s: EncoderSettings, format: String) -> [String] {
        let bitrate = s.bitrate
        let maxBitrate = s.max_bitrate
        let preset = s.preset.trimmingCharacters(in: .whitespaces)
        let bufsize = calculateBufsize(maxBitrate)
        var args: [String]

        switch s.encoder {
        case "libaom-av1":
            args = ["-c:v", "libaom-av1", "-cpu-used", numericPreset(preset, default: "6"),
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize]
        case "av1_nvenc":
            args = ["-c:v", "av1_nvenc", "-preset", nvencPreset(preset),
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize, "-rc", "vbr"]
        case "av1_qsv":
            args = ["-c:v", "av1_qsv", "-preset", preset,
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize]
        case "av1_amf":
            args = ["-c:v", "av1_amf", "-usage", "transcoding", "-rc", "vbr_peak",
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize]
        case "av1_vaapi":
            args = ["-vf", "format=nv12,hwupload", "-c:v", "av1_vaapi",
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize]
        default: // libsvtav1
            args = ["-c:v", "libsvtav1", "-preset", numericPreset(preset, default: "8"),
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize]
        }

        if format == "webm" {
            args += ["-c:a", "libopus", "-b:a", "128k"]
        } else {
            args += ["-c:a", "copy"]
        }
        return args
    }

    // MARK: HEVC

    static func hevcEncodingArgs(_ s: EncoderSettings, format: String) -> [String] {
        let bitrate = s.bitrate
        let maxBitrate = s.max_bitrate
        let preset = s.preset
        let bufsize = calculateBufsize(maxBitrate)

        var common = ["-map_metadata:s:a", "0:s:a", "-map_metadata:s:v", "0:s:v"]
        if format == "ts" {
            common += ["-bsf:a", "aac_adtstoasc", "-bsf:v", "hevc_mp4toannexb"]
        }

        var args: [String]
        switch s.encoder {
        case "hevc_nvenc":
            var nv = "p4"
            if preset.contains("fast") || preset.contains("super") || preset.contains("ultra") {
                nv = "p1"
            } else if preset.contains("slow") {
                nv = "p6"
            } else if preset.hasPrefix("p"), preset.count == 2, preset.last?.isNumber == true {
                nv = preset
            }
            args = ["-c:v", "hevc_nvenc", "-preset", nv, "-b:v", bitrate,
                    "-maxrate", maxBitrate, "-bufsize", bufsize, "-rc", "vbr",
                    "-spatial-aq", "1", "-tag:v", "hvc1", "-c:a", "copy"]
        case "hevc_qsv":
            args = ["-c:v", "hevc_qsv", "-preset", preset, "-b:v", bitrate,
                    "-maxrate", maxBitrate, "-bufsize", bufsize, "-tag:v", "hvc1", "-c:a", "copy"]
        case "hevc_amf":
            args = ["-c:v", "hevc_amf", "-usage", "transcoding", "-rc", "vbr_peak",
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize,
                    "-tag:v", "hvc1", "-c:a", "copy"]
            args += preset.contains("fast") ? ["-quality", "speed"] : ["-quality", "balanced"]
        case "hevc_vaapi":
            args = ["-vf", "format=nv12,hwupload", "-c:v", "hevc_vaapi", "-b:v", bitrate,
                    "-maxrate", maxBitrate, "-bufsize", bufsize, "-tag:v", "hvc1", "-c:a", "copy"]
        case "hevc_videotoolbox":
            args = ["-c:v", "hevc_videotoolbox", "-allow_sw", "1", "-realtime", "true",
                    "-b:v", bitrate, "-maxrate", maxBitrate, "-bufsize", bufsize,
                    "-tag:v", "hvc1", "-c:a", "copy"]
        default: // libx265
            let x265 = "rc-lookahead=20:b-adapt=2:bframes=3:scenecut=40"
            args = ["-c:v", "libx265", "-preset", preset, "-b:v", bitrate,
                    "-maxrate", maxBitrate, "-bufsize", bufsize, "-tune", "zerolatency",
                    "-tag:v", "hvc1", "-x265-params", x265, "-c:a", "copy"]
        }
        return args + common
    }

    // MARK: full ffmpeg command (arguments only; executable passed separately)

    static func ffmpegArguments(
        config: Config, format: String, outputPath: String
    ) -> [String] {
        let av1 = config.av1_settings
        let hevc = config.hevc_settings
        let enableAV1 = av1.enable
        let enableHEVC = hevc.enable && !enableAV1

        let metadata = ["-map_metadata:s:a", "0:s:a", "-map_metadata:s:v", "0:s:v"]
        var encoding: [String]

        if enableAV1 {
            encoding = av1EncodingArgs(av1, format: format) + metadata
        } else if format == "webm" {
            encoding = ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "5",
                        "-b:v", "0", "-crf", "32", "-c:a", "libopus", "-b:a", "128k"]
        } else if enableHEVC {
            encoding = hevcEncodingArgs(hevc, format: format)
        } else {
            encoding = ["-c", "copy"] + metadata
            if format == "ts" {
                encoding += ["-bsf:v", "h264_mp4toannexb", "-bsf:a", "aac_adtstoasc"]
            }
        }

        var output = ["-progress", "pipe:2"]
        if format == "ts" || format == "mkv" { output.append("-copy_unknown") }

        switch format {
        case "ts":
            output += ["-f", "mpegts", "-mpegts_flags", "resend_headers",
                       "-bsf", "setts=pts=PTS-STARTPTS",
                       "-fflags", "+genpts+discardcorrupt+nobuffer",
                       "-avioflags", "direct", outputPath]
        case "mkv":
            output += ["-f", "matroska", outputPath]
        case "webm":
            output += ["-f", "webm", outputPath]
        default:
            output += [outputPath]
        }

        return ["-i", "pipe:0", "-y"] + encoding + output
    }

    // MARK: streamlink command (arguments only)

    static func streamlinkArguments(
        channelID: String, cookies: Cookies, pluginDir: String,
        threads: Int, ffmpegPath: String, quality: String = Defaults.liveQuality
    ) -> [String] {
        let streamURL = "https://chzzk.naver.com/live/\(channelID)"
        let liveQuality = Validate.normalizeLiveQuality(quality)
        let headers = [
            "Cookie=\(ChzzkAPI.cookieHeader(cookies))",
            "User-Agent=Mozilla/5.0 (X11; Unix x86_64)",
            "Origin=https://chzzk.naver.com",
            "DNT=1", "Sec-GPC=1", "Connection=keep-alive", "Referer=",
        ]
        var args = ["--stdout", streamURL, liveQuality, "--hls-live-restart",
                    "--plugin-dirs", pluginDir,
                    "--stream-segment-threads", String(threads),
                    // Survive transient CDN/network hiccups when opening the stream
                    // instead of giving up after a single attempt.
                    "--retry-streams", "3", "--retry-max", "5", "--retry-open", "5"]
        for h in headers { args += ["--http-header", h] }
        args += ProxySupport.streamlinkArgs()
        args += ["--ffmpeg-ffmpeg", ffmpegPath, "--ffmpeg-copyts", "--hls-segment-stream-data"]
        return args
    }
}
