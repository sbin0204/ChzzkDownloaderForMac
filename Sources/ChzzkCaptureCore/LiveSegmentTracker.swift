import Foundation

/// Tracks which live HLS segments have already been consumed, so each poll of the
/// media playlist yields only the new ones. Pure state machine — no network — so
/// the live-reader polling logic is fully unit-testable.
public struct LiveSegmentTracker: Sendable {
    /// Highest segment sequence already emitted; -1 before anything is seen.
    public private(set) var lastSequence: Int = -1
    /// True once an `#EXT-X-ENDLIST` playlist has been seen.
    public private(set) var ended = false
    /// True when a poll skipped ahead of `lastSequence + 1` — segments rolled off
    /// the DVR window before we fetched them (a recording gap).
    public private(set) var lastPollHadGap = false

    public init() {}

    /// Feeds a freshly parsed playlist and returns the not-yet-seen segments in
    /// order. Idempotent: re-feeding the same playlist returns nothing.
    public mutating func newSegments(from playlist: HLSMediaPlaylist) -> [HLSMediaPlaylist.Segment] {
        if playlist.endList { ended = true }
        let fresh = playlist.segments.filter { $0.sequence > lastSequence }
        guard let first = fresh.first else {
            lastPollHadGap = false
            return []
        }
        // If the first new segment is past lastSequence + 1 (and we had seen
        // something before), the window slid and we lost the segments in between.
        lastPollHadGap = lastSequence >= 0 && first.sequence > lastSequence + 1
        lastSequence = fresh.last!.sequence
        return fresh
    }
}
