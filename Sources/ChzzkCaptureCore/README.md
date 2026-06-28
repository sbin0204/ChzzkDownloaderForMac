# ChzzkCaptureCore

Long-term effort to replace the external `streamlink` + `ffmpeg` dependencies
with a native Swift capture core, so recording no longer breaks across users'
differing tool versions.

This module is **dependency-free and independently testable**. It is developed
in isolation and is **not yet used by the app** — the app keeps using
streamlink/ffmpeg until the native path is proven, then switches behind a flag.

## Roadmap

1. **HLS plumbing (in progress)** — parse live media playlists (sequence,
   target duration, keys, init segment, discontinuity, end-list). ← first brick
2. **Live reader** — poll the media playlist, fetch only new segments, refresh
   the CDN token before expiry, surface the segment stream.
3. **AES-128** — decrypt `hls-aes` segments (CBC).
4. **Output** — raw TS append (ffmpeg-free) for the default path; pipe to a muxer
   for MP4/MKV.
5. **Engine seam** — a `CaptureEngine` protocol so the app can switch between the
   legacy (streamlink/ffmpeg) and native engines.
6. **Muxing** — reduce/remove ffmpeg via AVFoundation for the common containers.

Reliability is the priority: streamlink/ffmpeg are battle-tested, so the native
path ships behind a toggle with the legacy path as fallback until validated.
