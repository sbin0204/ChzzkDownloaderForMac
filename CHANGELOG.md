# Changelog

## 1.3.2

- Fixed Chrome/Firefox cookie import failing with a "permission to access 'T'" error: the cookie database is now snapshotted by reading its bytes (instead of a metadata-preserving file copy) and falls back to the app caches directory when the system temp folder is not writable.

## 1.3.1

- Added an optional built-in capture engine that records live streams and downloads VODs natively (HLS polling, AES-128 decryption, MP4 remux) with minimal reliance on streamlink and ffmpeg. It is opt-in under Recording Settings → Experimental.
- Full VOD downloads can now run entirely through the built-in engine, including permission-gated and AES-encrypted (membership) videos.
- Added pause and resume for VOD downloads: paused work is kept on disk and already-downloaded segments are skipped on resume.
- Added all-phase VOD progress labels (downloading, merging, preparing) so the download no longer looks frozen during long steps.
- The dashboard now shows live thumbnails, viewer counts, and uptime, with a grid/list toggle for the current-live section.
- Added an optional galloping-horse indicator next to active downloads — a nod to Muybridge's 1878 "The Horse in Motion" — that runs faster or slower with the download speed. It is off by default; enable it under the VOD download options.
- Added a bottom fade on long lists, row/card hover highlights, list animations, and a right-click menu on download history (reveal in Finder, copy path, retry, delete).
- Added Siri / Shortcuts / Spotlight actions (App Intents) for recording channels, scheduling, recording all live channels, and downloading VODs (active when the app is signed with a real identity).
- Fixed a bug where "Reveal in Finder" in the download history could fail to open Finder.
- Quick-record files now use the streamer's nickname instead of the raw channel ID.

## 1.3.0

- Added VOD source import: paste a direct `vod_chunklist.m3u8` / `vod_playlist.m3u8` / `.mpd` / `.mp4` URL to download it, in addition to regular Chzzk video/clip links.
- Routed AES-encrypted imported HLS sources through ffmpeg so they decode correctly instead of producing a broken file.
- Added a first-launch welcome guide that explains the required tools (ffmpeg, streamlink) with a copyable install command and a live installed/not-installed check.
- The dashboard now shows an actionable banner with a copyable install command when ffmpeg or streamlink is missing, instead of only warning when recording starts.
- The channel field now accepts a full channel address pasted as-is and extracts the ID automatically.
- Renamed jargon settings labels to plainer terms and marked recommended values.
- Added a "reset recording settings to defaults" button that preserves channels, cookies, schedules, and folders.
- Recordings now finish writing their container (and rename the file) before the app quits, so long MKV/MP4 recordings stay playable instead of showing 00:00.
- Fixed a crash that could occur while importing cookies from a corrupt or truncated Safari cookie file.

## 1.2.0

- Added live broadcast category and tag display in the dashboard for channels that are currently live.
- Added optional stop-on-tag-mismatch toggle per channel: when enabled, recording stops gracefully if the broadcast tags change and no longer match the configured tag filter.
- Fixed a race condition where a recording file could be left with a `.part` extension if the app crashed mid-recording; orphaned parts are recovered automatically on next launch.
- Fixed process cleanup: ffmpeg now receives SIGKILL after a 5-second grace period if it does not exit after SIGTERM, preventing zombie processes.
- Fixed adult/media-unavailable streams from retrying too aggressively; the engine now waits the configured timeout interval before re-checking.
- Narrowed the auth-failure heuristic to avoid false positives from CDN URLs and normal log lines that happen to contain cookie-related words.

## 1.1.0

- Added monitoring state persistence: channels being watched when the app closes resume monitoring on next launch.
- Added tag-based recording filters: select tags per channel so recording only starts when the broadcast matches one of the chosen tags.

## 1.0.3

- In-app release notes now render the same changelog page shown in the update dialog.
- Further stability improvements to live auto-recording.

## 1.0.2

- Made live auto-recording substantially more reliable against transient stream/network hiccups:
  - The bundled Chzzk plugin no longer lets a non-`StreamError` (network, parse, or attribute error) escape the HLS worker thread, which previously crashed the worker and silently stalled recording.
  - Rewrote the stream-token refresh: it now re-resolves the stream (adopting the fresh path-based CDN token while keeping the current quality) instead of calling a non-existent helper and splicing an obsolete query token — token refresh actually works now.
  - streamlink now retries opening the stream (`--retry-open`, `--retry-streams`, `--retry-max`) instead of giving up after a single attempt.
  - A recording that ends almost immediately is treated as a transient failure and retried quickly with a capped backoff, instead of leaving a live channel unrecorded for a full rescan interval.
- Added a clear error when the recording destination is missing or read-only (e.g. an unplugged external drive) instead of silently failing.

## 1.0.1

- Fixed live recording stopping on newer streamlink versions: the stream-token refresh path no longer relies on the removed `StreamError.response` attribute, and now refreshes the token and retries once on a playlist fetch error.

## 1.0.0

- Added live recording quality selection per channel.
- Added live recording auto-splitting by file size and elapsed time.
- Added one-shot scheduled recording behavior for "record until broadcast ends" schedules.
- Changed direct MP4 partial downloads to download only the required byte range in parallel, then cut locally.
- Changed HLS partial downloads to prefetch only overlapping playlist segments before local remuxing.
- Added cyclic recording cleanup, webhook notifications, About, Help, privacy/cookie storage notice, open source notices, release notes, and diagnostic report copy UI.
- Added Sparkle updater integration that is enabled in distribution builds when `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` are provided.
- Added English localization resources, Korean/English support documents, and a GitHub-based Sparkle update setup guide.
- Added `release.json`, release validation scripts, and a maintainer guide so versions, licenses, changelogs, and update documents are easier to keep in sync.
- Fixed a log file write crash by replacing `FileHandle` writes with a POSIX write path.
- Hardened cookie entry fields with secure text inputs.
- Added release packaging cleanup so local user paths are stripped from release binaries.
