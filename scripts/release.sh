#!/bin/bash
# One-command release: push source + GitHub Release + DMG + signed appcast
# (release notes -> changelog.html page) + publish changelog.html & appcast.xml
# to the gh-pages branch.
#
# Usage:
#   GHTOKEN=ghp_xxx ./scripts/release.sh
#
# Prereqs (already in place in this repo):
#   - ChzzkDownloaderForMac-<version>.dmg built (./package_dmg.sh with SPARKLE_*)
#   - sparkle_private_key.pem  (EdDSA signing key, kept out of git)
#   - changelog.html           (release-notes page shown in the update dialog)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GHTOKEN:?Set GHTOKEN=<github personal access token>}"

echo "▶ 0/4 릴리즈 사전 검증 (build + test)"
./scripts/release_check.sh

OWNER=sbin0204
REPO=ChzzkDownloaderForMac
PAGES="https://${OWNER}.github.io/${REPO}"
KEY=sparkle_private_key.pem
GA=./.build/artifacts/sparkle/Sparkle/bin/generate_appcast

eval "$(./scripts/release_metadata.py env)"
VER="$MARKETING_VERSION"
TAG="v${VER}"
DMG="${DMG_BASENAME}-${VER}.dmg"
NOTES_URL="${PAGES}/changelog.html"

CHANGELOG_HTML="Sources/ChzzkDownloader/Resources/Documents/changelog.html"
for f in "$DMG" "$KEY" "$CHANGELOG_HTML"; do
  [ -f "$f" ] || { echo "필요 파일 없음: $f" >&2; exit 1; }
done
echo "▶ 배포 버전 $VER  (tag $TAG, dmg $DMG)"

echo "▶ 1/4 소스 push (main)"
git push "https://${OWNER}:${GHTOKEN}@github.com/${OWNER}/${REPO}.git" main

echo "▶ 2/4 appcast 생성·서명 (pem, 키체인 프롬프트 없음) + changelog 링크"
STAGE="$(mktemp -d)"; cp "$DMG" "$STAGE/"
"$GA" --ed-key-file "$KEY" \
  --download-url-prefix "https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/" \
  "$STAGE" >/dev/null
python3 - "$STAGE/appcast.xml" "$NOTES_URL" <<'PY'
import sys, re
path, link = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r"\s*<description>.*?</description>", "", s, flags=re.S)   # no inline notes
if "releaseNotesLink" not in s:
    # inside each <item> (every release links to the same changelog page)
    s = s.replace("<item>",
                  f"<item>\n            <sparkle:releaseNotesLink>{link}</sparkle:releaseNotesLink>")
open(path, "w").write(s)
PY
cp "$STAGE/appcast.xml" ./appcast.generated.xml

echo "▶ 3/4 + 4/4 GitHub 릴리즈 + DMG 업로드 + gh-pages(changelog.html, appcast.xml)"
GHTOKEN="$GHTOKEN" OWNER="$OWNER" REPO="$REPO" TAG="$TAG" VER="$VER" DMG="$DMG" python3 - <<'PY'
import os, json, base64, mimetypes, urllib.request, urllib.error
T=os.environ["GHTOKEN"]; OWNER=os.environ["OWNER"]; REPO=os.environ["REPO"]
TAG=os.environ["TAG"]; VER=os.environ["VER"]; DMG=os.environ["DMG"]; API="https://api.github.com"
def req(m,u,data=None,binary=False,headers=None):
    h={"Authorization":f"Bearer {T}","Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28","User-Agent":"release"}
    if headers: h.update(headers)
    body=data if binary else (json.dumps(data).encode() if data is not None else None)
    if data is not None and not binary: h["Content-Type"]="application/json"
    r=urllib.request.Request(u,data=body,method=m,headers=h)
    try: x=urllib.request.urlopen(r); return x.status, json.loads(x.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw=e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"_raw":raw[:200].decode(errors="replace")}

# release
code,rel=req("POST",f"{API}/repos/{OWNER}/{REPO}/releases",
             {"tag_name":TAG,"name":TAG,"body":f"변경 사항: https://{OWNER}.github.io/{REPO}/changelog.html","draft":False,"prerelease":False})
if code==422:
    code,rel=req("GET",f"{API}/repos/{OWNER}/{REPO}/releases/tags/{TAG}")
print("  release:",code,rel.get("html_url") or rel.get("message"))
rid=rel["id"]; up=rel["upload_url"].split("{")[0]
# replace existing asset if any
_,assets=req("GET",f"{API}/repos/{OWNER}/{REPO}/releases/{rid}/assets")
for a in (assets if isinstance(assets,list) else []):
    if a.get("name")==os.path.basename(DMG):
        req("DELETE",f"{API}/repos/{OWNER}/{REPO}/releases/assets/{a['id']}")
code,asset=req("POST",up+f"?name={os.path.basename(DMG)}",open(DMG,"rb").read(),binary=True,
               headers={"Content-Type":"application/octet-stream"})
print("  asset  :",code,asset.get("browser_download_url") or asset.get("message"))
# gh-pages: changelog.html + appcast.xml (orphan commit, force-update)
tree=[]
for path,local in [("appcast.xml","appcast.generated.xml"),("changelog.html","Sources/ChzzkDownloader/Resources/Documents/changelog.html")]:
    _,blob=req("POST",f"{API}/repos/{OWNER}/{REPO}/git/blobs",
               {"content":base64.b64encode(open(local,'rb').read()).decode(),"encoding":"base64"})
    tree.append({"path":path,"mode":"100644","type":"blob","sha":blob["sha"]})
_,tr=req("POST",f"{API}/repos/{OWNER}/{REPO}/git/trees",{"tree":tree})
_,cm=req("POST",f"{API}/repos/{OWNER}/{REPO}/git/commits",{"message":f"Publish {TAG} appcast + changelog","tree":tr["sha"],"parents":[]})
code,ref=req("PATCH",f"{API}/repos/{OWNER}/{REPO}/git/refs/heads/gh-pages",{"sha":cm["sha"],"force":True})
if code>=400:
    code,ref=req("POST",f"{API}/repos/{OWNER}/{REPO}/git/refs",{"ref":"refs/heads/gh-pages","sha":cm["sha"]})
print("  gh-pages:",code,ref.get("ref") or ref.get("message"))
print(f"\n  feed   : https://{OWNER}.github.io/{REPO}/appcast.xml")
print(f"  notes  : https://{OWNER}.github.io/{REPO}/changelog.html")
PY
rm -rf "$STAGE" ./appcast.generated.xml
echo "✅ 배포 완료. (Pages 재배포에 1~2분 소요될 수 있음)"
