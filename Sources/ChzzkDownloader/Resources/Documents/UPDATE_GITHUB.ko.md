# GitHub 업데이트 준비

Sparkle 업데이트는 앱 안에서 직접 새 버전을 내려받아 교체하는 기능입니다. 별도 서버가 없어도 GitHub Releases와 GitHub Pages 조합으로 운영할 수 있습니다.

## 1. 준비물

- 공개 GitHub 저장소 또는 GitHub Pages를 켤 수 있는 저장소
- `ChzzkDownloaderForMac-버전.dmg`
- Sparkle EdDSA 공개 키와 개인 키
- `appcast.xml`

## 2. Sparkle 키 만들기

Sparkle의 `generate_keys` 도구로 EdDSA 키를 만듭니다. 공개 키는 앱 빌드에 들어가고, 개인 키는 릴리즈 서명에만 사용합니다. 개인 키는 GitHub 저장소에 올리면 안 됩니다.

빌드할 때는 아래 값을 넣습니다.

```sh
SPARKLE_FEED_URL="https://<user>.github.io/<repo>/appcast.xml" \
SPARKLE_PUBLIC_ED_KEY="<public key>" \
./package_dmg.sh
```

## 3. GitHub에 파일 올리기

권장 구조는 다음 중 하나입니다.

- GitHub Releases: DMG 파일 업로드
- GitHub Pages: `appcast.xml` 업로드

`appcast.xml`의 enclosure URL은 GitHub Release asset의 HTTPS 다운로드 주소를 가리키면 됩니다.

## 4. appcast 생성

Sparkle의 `generate_appcast` 도구로 DMG가 있는 폴더를 스캔해 `appcast.xml`을 만듭니다. 생성된 appcast에는 버전, 파일 크기, EdDSA 서명, 다운로드 URL이 들어가야 합니다.

릴리즈할 때마다 순서는 다음처럼 유지하세요.

1. 앱 버전과 `CHANGELOG.md` 업데이트
2. `SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_ED_KEY`를 넣어 DMG 빌드
3. DMG에 Sparkle 서명 생성
4. DMG를 GitHub Releases에 업로드
5. `appcast.xml`을 GitHub Pages에 업로드
6. 기존 앱에서 업데이트 확인

## 5. 주의

- 앱이 DMG 안에서 실행 중이면 Sparkle이 앱을 교체하지 못할 수 있습니다. 사용자는 Applications 폴더에 복사해 실행해야 합니다.
- Apple Developer ID 서명/공증이 없으면 첫 실행 경고는 계속 뜹니다. Sparkle은 업데이트 흐름을 제공하지만 Apple 공증을 대신하지 않습니다.
- 개인 EdDSA 키는 절대 저장소, 릴리즈, appcast에 포함하지 마세요.
