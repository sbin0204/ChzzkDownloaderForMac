# Maintaining Chzzk Downloader for Mac

This project keeps release-facing metadata in `release.json`. Update that file first when preparing a new version, then update the human-readable documents.

## Common Release Edits

1. Update `release.json`
   - `version.marketing`: value shown as `CFBundleShortVersionString`
   - `version.build`: value shown as `CFBundleVersion`; keep it increasing for Sparkle
   - `version.changelogHeading`: the heading expected in `CHANGELOG.md`
2. Update `CHANGELOG.md`
   - Add a `## <version.changelogHeading>` section at the top.
3. Update notices when dependencies change
   - `LICENSE`: app license
   - `THIRD_PARTY_NOTICES.md`: bundled or referenced third-party components
4. Update the in-app release notes page
   - `Sources/ChzzkDownloader/Resources/Documents/changelog.html`
5. Update localization when adding user-facing strings
   - `Sources/ChzzkDownloader/Resources/en.lproj/Localizable.strings`
   - Korean source strings intentionally fall back to the source key.

## Checks

Run the normal release gate:

```sh
./scripts/release_check.sh
```

Run the full package gate:

```sh
./scripts/release_check.sh --package
```

## Sparkle / GitHub Updates

Use GitHub Releases for the DMG and GitHub Pages for `appcast.xml`. Build distribution packages with:

```sh
SPARKLE_FEED_URL="https://<user>.github.io/<repo>/appcast.xml" \
SPARKLE_PUBLIC_ED_KEY="<public key>" \
./package_dmg.sh
```

Do not commit the Sparkle private EdDSA key.

After the DMG is built, publish everything (GitHub Release + DMG upload + signed
appcast + changelog page on gh-pages) in one command. It runs
`scripts/release_check.sh` first and aborts if the build or tests fail:

```sh
GHTOKEN=<github personal access token> ./scripts/release.sh
```
