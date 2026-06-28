#!/bin/bash
# Generates the App Intents metadata bundle (Metadata.appintents) inside an
# assembled .app so Siri / Spotlight / Shortcuts / Apple Intelligence can
# discover the app's intents. SwiftPM does not do this (it is an Xcode build
# phase), so we reproduce it: extract Swift const values for the AppIntents
# protocols, then run Xcode's appintentsmetadataprocessor.
#
# Usage: generate_appintents_metadata.sh <App.app> <swiftpm-bin-dir> <module> <min-macos>
#
# Best effort: if full Xcode (not just Command Line Tools) is unavailable, it
# warns and exits 0 so a normal app build still succeeds — only Siri discovery
# is skipped.
set -euo pipefail

APP="${1:?app bundle path}"
BIN_DIR="${2:?swiftpm bin dir}"
MODULE="${3:-ChzzkDownloader}"
MIN_MACOS="${4:-14.0}"
SOURCE_ROOT="Sources/${MODULE}"

TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
PROC="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
PROTO_SRC="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"

if [ ! -x "$PROC" ] || [ ! -f "$PROTO_SRC" ]; then
  echo "note: App Intents metadata skipped — full Xcode toolchain not found." >&2
  echo "      (Siri/Shortcuts discovery needs Xcode; the app still builds.)" >&2
  exit 0
fi

SDK="$(xcrun --show-sdk-path)"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')"

# Resolve the SwiftPM-generated resource accessor (defines Bundle.module) and the
# Sparkle.framework search dir. Layout differs between native and universal
# builds, so search rather than assume.
ACCESSOR="$(find "$BIN_DIR" -name resource_bundle_accessor.swift 2>/dev/null | head -1)"
[ -z "$ACCESSOR" ] && ACCESSOR="$(find .build -name resource_bundle_accessor.swift 2>/dev/null | head -1)"
SPARKLE_FW="$(find "$BIN_DIR" -path '*Sparkle.framework' -prune 2>/dev/null | head -1)"
[ -z "$SPARKLE_FW" ] && SPARKLE_FW="$(find .build -path '*Sparkle.framework' -prune 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "note: App Intents metadata skipped — Sparkle.framework not found in build output." >&2
  exit 0
fi
SPARKLE_FW_DIR="$(dirname "$SPARKLE_FW")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Xcode passes a flat array of protocol names; the shipped file wraps them in an
# object, so unwrap constValueProtocols here.
/usr/bin/python3 -c "import json,sys; json.dump(json.load(open('$PROTO_SRC'))['constValueProtocols'], open('$WORK/protocols.json','w'))"

# 1) Extract const values for the whole module (objects are throwaway).
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$SOURCE_ROOT" -name "*.swift")
[ -f "$ACCESSOR" ] && SOURCES+=("$ACCESSOR")

swiftc -module-name "$MODULE" -wmo -parse-as-library -c -o "$WORK/throwaway.o" \
  -sdk "$SDK" -target "arm64-apple-macosx${MIN_MACOS}" \
  -F "$SPARKLE_FW_DIR" -framework Sparkle \
  -emit-const-values-path "$WORK/${MODULE}.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" \
  "${SOURCES[@]}"

if [ ! -s "$WORK/${MODULE}.swiftconstvalues" ]; then
  echo "warning: const-value extraction produced nothing; skipping App Intents metadata." >&2
  exit 0
fi

# 2) Produce Metadata.appintents inside the app (under Contents/Resources).
find "$SOURCE_ROOT" -name "*.swift" > "$WORK/sources.txt"
echo "$WORK/${MODULE}.swiftconstvalues" > "$WORK/constvals.txt"
rm -rf "$APP/Contents/Resources/Metadata.appintents"

"$PROC" \
  --output "$APP/Contents/Resources" \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name "$MODULE" \
  --sdk-root "$SDK" \
  --xcode-version "$XCODE_VERSION" \
  --platform-family macOS \
  --deployment-target "$MIN_MACOS" \
  --target-triple "arm64-apple-macosx${MIN_MACOS}" \
  --source-file-list "$WORK/sources.txt" \
  --swift-const-vals-list "$WORK/constvals.txt" \
  --force >/dev/null

if [ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
  echo "App Intents metadata embedded (Siri/Shortcuts discovery enabled)."
else
  echo "warning: App Intents metadata bundle was not produced." >&2
fi
