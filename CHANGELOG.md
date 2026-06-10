# Changelog

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
