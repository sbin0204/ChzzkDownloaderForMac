#!/bin/bash
# Builds "Chzzk Downloader for Mac.app" (a double-clickable macOS app bundle).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ARCH_MODE="${2:-native}"   # native | universal
eval "$(./scripts/release_metadata.py env)"
APP="${APP_NAME}.app"

ARCH_FLAGS=""
if [ "$ARCH_MODE" = "universal" ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
fi
DEBUG_INFO_FLAGS=""
if [ "$CONFIG" = "release" ]; then
  DEBUG_INFO_FLAGS="-Xswiftc -gnone -Xswiftc -debug-prefix-map -Xswiftc $(pwd)=."
fi
LINKER_FLAGS="-Xlinker -rpath -Xlinker @executable_path/../Frameworks"

plist_escape() {
  /usr/bin/python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=False))' "$1"
}

SPARKLE_KEYS=""
if [ -n "${SPARKLE_FEED_URL:-}" ] || [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  if [ -z "${SPARKLE_FEED_URL:-}" ] || [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    echo "error: set both SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY, or neither." >&2
    exit 1
  fi
  case "$SPARKLE_FEED_URL" in
    https://*) ;;
    *)
      echo "error: SPARKLE_FEED_URL must start with https:// for distribution updates." >&2
      exit 1
      ;;
  esac
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>$(plist_escape "$SPARKLE_FEED_URL")</string>
  <key>SUPublicEDKey</key><string>$(plist_escape "$SPARKLE_PUBLIC_ED_KEY")</string>
  <key>SUEnableInstallerLauncherService</key><true/>
  <key>SUShowReleaseNotes</key><true/>"
fi

echo "Building ($CONFIG, $ARCH_MODE)…"
# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCH_FLAGS $DEBUG_INFO_FLAGS $LINKER_FLAGS

# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" $ARCH_FLAGS $DEBUG_INFO_FLAGS $LINKER_FLAGS --show-bin-path)"

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

python3 - <<'PY'
from pathlib import Path
import ast

path = Path("Sources/ChzzkDownloader/Resources/plugin/chzzk.py")
ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY

ICON_OUTPUT="Sources/ChzzkDownloader/Resources/cdm.icns"
if [ ! -f "$ICON_OUTPUT" ] || find "Sources/ChzzkDownloader/cdm.icon" -type f -newer "$ICON_OUTPUT" | grep -q .; then
  ./scripts/generate_app_icon.sh "Sources/ChzzkDownloader/cdm.icon" "$ICON_OUTPUT"
fi

cp "$BIN_DIR/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
/usr/bin/strip -S -x "$APP/Contents/MacOS/$BIN_NAME" 2>/dev/null || true

SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  SPARKLE_FRAMEWORK="$(find .build -path "*Sparkle.framework" -type d -prune | head -n 1)"
fi
if [ -z "$SPARKLE_FRAMEWORK" ] || [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "error: Sparkle.framework was not found in the SwiftPM build output." >&2
  exit 1
fi
echo "Embedding $(basename "$SPARKLE_FRAMEWORK")..."
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/$(basename "$SPARKLE_FRAMEWORK")"

# Copy the streamlink plugin into Contents/Resources/plugin. The app resolves it
# via Bundle.main.resourceURL (see AppModel.pluginDir).
cp -R "Sources/ChzzkDownloader/Resources/plugin" "$APP/Contents/Resources/plugin"
find "$APP/Contents/Resources/plugin" \( -name "__pycache__" -type d -o -name "*.pyc" -type f \) -prune -exec rm -rf {} +
cp "$ICON_OUTPUT" "$APP/Contents/Resources/cdm.icns"
cp "Sources/ChzzkDownloader/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
cp "Sources/ChzzkDownloader/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
find "Sources/ChzzkDownloader/Resources" -maxdepth 1 -name "*.lproj" -type d -exec cp -R {} "$APP/Contents/Resources/" \;
if [ -d "Sources/ChzzkDownloader/Resources/Documents" ]; then
  cp -R "Sources/ChzzkDownloader/Resources/Documents" "$APP/Contents/Resources/Documents"
fi
cp "$LICENSE_FILE" "$APP/Contents/Resources/LICENSE"
cp "$THIRD_PARTY_NOTICES_FILE" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$CHANGELOG_FILE" "$APP/Contents/Resources/CHANGELOG.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$(plist_escape "$APP_NAME")</string>
  <key>CFBundleDisplayName</key><string>$(plist_escape "$APP_NAME")</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ko</string>
  </array>
  <key>CFBundleIdentifier</key><string>$(plist_escape "$BUNDLE_ID")</string>
  <key>CFBundleVersion</key><string>$(plist_escape "$BUILD_NUMBER")</string>
  <key>CFBundleShortVersionString</key><string>$(plist_escape "$MARKETING_VERSION")</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIconFile</key><string>cdm.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$(plist_escape "$MIN_MACOS")</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>$(plist_escape "$COPYRIGHT_TEXT")</string>
$SPARKLE_KEYS
</dict>
</plist>
PLIST

for required in \
  "$APP/Contents/MacOS/$BIN_NAME" \
  "$APP/Contents/Frameworks/Sparkle.framework" \
  "$APP/Contents/Resources/plugin/chzzk.py" \
  "$APP/Contents/Resources/cdm.icns" \
  "$APP/Contents/Resources/MenuBarIcon.png" \
  "$APP/Contents/Resources/MenuBarIcon@2x.png" \
  "$APP/Contents/Resources/en.lproj/Localizable.strings" \
  "$APP/Contents/Resources/ko.lproj/Localizable.strings" \
  "$APP/Contents/Resources/LICENSE" \
  "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" \
  "$APP/Contents/Resources/CHANGELOG.md" \
  "$APP/Contents/Info.plist"
do
  if [ ! -e "$required" ]; then
    echo "error: required bundle item is missing: $required" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc sign so the app runs locally without Gatekeeper complaints.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Done: $(pwd)/${APP}"
