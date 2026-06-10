# Third-Party Notices

This app is an unofficial tool for CHZZK recording and VOD downloading. It is
not affiliated with NAVER or CHZZK.

## Sparkle

- Project: https://github.com/sparkle-project/Sparkle
- Purpose: macOS app update framework
- License: MIT License

## Streamlink Chzzk Plugin

- Project: https://github.com/streamlink/streamlink
- Bundled file: `Sources/ChzzkDownloader/Resources/plugin/chzzk.py`
- Purpose: resolves CHZZK live streams for Streamlink
- License: BSD-2-Clause License, as used by Streamlink

## External Tools

The app invokes user-installed command line tools when present. These tools are
not bundled in the app package:

- ffmpeg: https://ffmpeg.org
- streamlink: https://streamlink.github.io

## Inspired Projects

The macOS app behavior is inspired by these projects, but it is a Swift
reimplementation rather than a direct embedding of their Python applications:

- Chzzk-Rekoda by munsy0227: https://github.com/munsy0227/Chzzk-Rekoda
- chzzk-vod-downloader-v2 by honey720: https://github.com/honey720/chzzk-vod-downloader-v2
