#!/bin/bash
# Builds a universal (Apple Silicon + Intel) release and packages it as a DMG.
set -euo pipefail
cd "$(dirname "$0")"

eval "$(./scripts/release_metadata.py env)"
APP="${APP_NAME}.app"

# 1) Universal release .app
./build_app.sh release universal

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="${DMG_BASENAME}-${VERSION}.dmg"

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME")"

# 2) Stage a DMG layout: app + drag-to-Applications shortcut + install note
echo "Creating ${DMG}..."
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/처음 실행 방법.txt" <<'TXT'
Chzzk Downloader for Mac — 설치 / 첫 실행 방법
=============================================

[설치]
1) 왼쪽의 "Chzzk Downloader for Mac.app" 을 오른쪽 "Applications" 폴더로
   끌어다 놓으세요.

[첫 실행 — 보안 허용]
이 앱은 Apple 공증(notarize)을 받지 않아, 처음 실행할 때 macOS가 막습니다.
아래 방법으로 "한 번만" 허용하면, 이후로는 그냥 실행됩니다.

● 방법 A (권장 · 최신 macOS)
   1) 응용 프로그램에서 앱을 한 번 실행 → "열 수 없습니다" 경고가 뜨면 닫기
   2) 화면 위 메뉴(  ) → "시스템 설정" 열기
   3) 왼쪽에서 "개인정보 보호 및 보안" 클릭
   4) 아래로 스크롤 → "Chzzk Downloader for Mac 이(가) 차단되었습니다" 문구 옆
      [ 그래도 열기 ] 버튼 클릭 (암호 입력 요청 시 입력)
   5) 다시 앱 실행 → 경고창에서 [ 열기 ] 클릭 → 완료

● 방법 B (우클릭)
   응용 프로그램에서 앱을 마우스 오른쪽 클릭 → "열기" → 경고창에서 "열기"

● 방법 C (터미널)
   xattr -dr com.apple.quarantine "/Applications/Chzzk Downloader for Mac.app"

[참고]
- VOD / 클립 다운로드는 추가 설치 없이 동작합니다.
- 라이브 녹화에는 ffmpeg 와 streamlink 가 필요합니다:
     brew install ffmpeg streamlink
  (없으면 앱이 안내 창을 띄우며, 설정에서 경로를 직접 지정할 수도 있습니다.)
TXT

# 3) Build the compressed DMG
rm -f "$DMG"
hdiutil create -volname "$DMG_VOLUME_NAME" -srcfolder "$STAGE" -ov -fs HFS+ -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
sync
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if hdiutil imageinfo "$DMG" >/dev/null 2>&1 && hdiutil verify "$DMG" >/dev/null; then
    break
  fi
  if [ "$attempt" = "10" ]; then
    hdiutil verify "$DMG"
  fi
  sleep 2
done

echo ""
echo "Done: $(pwd)/${DMG}"
echo "Size: $(du -h "$DMG" | cut -f1)"
echo ""
echo "참고: 정식 배포(다른 Mac에서 경고 없이 실행)하려면 Apple Developer ID"
echo "서명 + 공증(notarytool)이 필요합니다. 현재는 ad-hoc 서명 상태입니다."
