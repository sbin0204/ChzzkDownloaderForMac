#!/bin/bash
# Runs the checks that should pass before publishing a release.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/release_metadata.py validate
plutil -lint Sources/ChzzkDownloader/Resources/en.lproj/Localizable.strings >/dev/null
plutil -lint Sources/ChzzkDownloader/Resources/ko.lproj/Localizable.strings >/dev/null
swift build
swift test

if [ "${1:-}" = "--package" ]; then
  ./package_dmg.sh
fi

echo "release check OK"
