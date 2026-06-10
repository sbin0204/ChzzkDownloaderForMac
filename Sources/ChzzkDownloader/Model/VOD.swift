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
    var audioBitrateKbps: Int? = nil
    var segmentPlan: VODSegmentPlan? = nil
    var id: Int { quality }
    var label: String { "\(quality)p" }
    var hasSegmentParts: Bool { segmentPlan?.hasMediaSegments == true }
}

enum VODState: Equatable {
    case fetching          // resolving metadata/manifest
    case ready             // metadata loaded, awaiting download
    case downloading
    case completed
    case failed(String)
    case canceled

    var canRemoveFromVODList: Bool {
        switch self {
        case .downloading:
            return false
        case .fetching, .ready, .completed, .failed, .canceled:
            return true
        }
    }
}

@Observable
final class VODItem: Identifiable {
    let id = UUID()
    let url: String
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

    var hasClip: Bool {
        if let s = clipStart, let e = clipEnd, e > s { return true }
        return false
    }

    // progress
    var percent: Double = 0
    var sizeText: String = "N/A"
    var speedText: String = "N/A"
    var outTime: String = "00:00:00"
    var outputPath: String?

    init(url: String) { self.url = url }

    var selectedVariant: VODVariant? {
        if let q = selectedQuality { return variants.first { $0.quality == q } }
        return variants.last  // highest by default
    }
}
