import Foundation
import Observation

/// One DASH media part/segment with its timeline position.
struct VODMediaSegment: Hashable {
    var url: String
    var start: Double
    var duration: Double
    var index: Int
}

/// Concrete part list from a DASH manifest.
///
/// Important invariant: when a VOD clip has this plan, partial download must
/// fetch only the overlapping media segments, plus the init segment if present.
/// Do not replace that path with "download from 0 then cut"; late clips would
/// waste the user's time and bandwidth. See docs/VOD_PARTIAL_DOWNLOAD_POLICY.md.
struct VODSegmentPlan: Hashable {
    var initializationURL: String?
    var media: [VODMediaSegment]

    var hasMediaSegments: Bool { !media.isEmpty }

    func selectedMedia(clipStart: Double?, clipEnd: Double?) -> [VODMediaSegment] {
        guard let clipStart, let clipEnd, clipEnd > clipStart else { return media }
        return media.filter { segment in
            let segmentEnd = segment.start + segment.duration
            return segmentEnd > clipStart && segment.start < clipEnd
        }
    }
}

/// A selectable quality variant: `quality` is min(width,height) (e.g. 1080).
/// `url` is the direct media URL for whole-file ranged download when available;
/// `segmentPlan` is preferred for DASH part downloads.
struct VODVariant: Hashable, Identifiable {
    var quality: Int
    var url: String
    var isHLS: Bool = false   // live-rewind streams need ffmpeg, not ranged download
    var requiresRemoteHLS: Bool = false
    var audioBitrateKbps: Int? = nil
    var segmentPlan: VODSegmentPlan? = nil
    var id: String { "\(quality)-\(url)" }
    var label: String { quality > 0 ? "\(quality)p" : "소스" }
    var hasSegmentParts: Bool { segmentPlan?.hasMediaSegments == true }
}

enum VODState: Equatable {
    case fetching          // resolving metadata/manifest
    case ready             // metadata loaded, awaiting download
    case downloading
    case paused            // download stopped, partial kept (resumable)
    case completed
    case failed(String)
    case canceled

    var canRemoveFromVODList: Bool {
        switch self {
        case .downloading:
            return false
        case .fetching, .ready, .paused, .completed, .failed, .canceled:
            return true
        }
    }
}

@Observable
final class VODItem: Identifiable {
    let id = UUID()
    let url: String
    var importedSource: Bool = false
    var recordID: UUID?        // links to a persisted DownloadRecord
    var title: String = ""
    var channelName: String = ""
    var durationSeconds: Int = 0
    var variants: [VODVariant] = []
    var selectedQuality: Int?          // chosen min(w,h)
    var audioOnly: Bool = false        // extract audio (.m4a) instead of a video quality
    var clipStart: Double?             // segment start (seconds); nil = whole video
    var clipEnd: Double?               // segment end (seconds)
    var state: VODState = .fetching
    var resumeVariant: VODVariant?     // remembered for pause → resume
    var resumeOutURL: URL?
    /// True only while a download whose strategy genuinely supports pause/resume is
    /// active (HLS/DASH segment prefetch — already-fetched segments are kept). Direct
    /// MP4 and ffmpeg-based downloads can't pause without losing progress, so the UI
    /// hides their pause button.
    var supportsPause: Bool = false

    var hasClip: Bool {
        if let s = clipStart, let e = clipEnd, e > s { return true }
        return false
    }

    // progress
    var percent: Double = 0
    var sizeText: String = "N/A"
    var speedText: String = "N/A"
    var bytesPerSecond: Double = 0   // numeric speed, drives the gallop animation
    var outTime: String = "00:00:00"
    var outputPath: String?

    init(url: String) { self.url = url }

    var selectedVariant: VODVariant? {
        if let q = selectedQuality { return variants.first { $0.quality == q } }
        return variants.last  // highest by default
    }
}
