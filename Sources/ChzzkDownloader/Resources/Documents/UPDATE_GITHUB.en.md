# GitHub Update Setup

Sparkle lets the app download and replace itself from inside the app. You can run it without your own server by using GitHub Releases together with GitHub Pages.

## 1. Requirements

- A public GitHub repository, or a repository with GitHub Pages enabled
- `ChzzkDownloaderForMac-version.dmg`
- Sparkle EdDSA public and private keys
- `appcast.xml`

## 2. Create Sparkle Keys

Use Sparkle's `generate_keys` tool to create EdDSA keys. The public key is embedded in the app build. The private key is used only when signing releases. Never commit the private key to GitHub.

Build the distribution app with:

```sh
SPARKLE_FEED_URL="https://<user>.github.io/<repo>/appcast.xml" \
SPARKLE_PUBLIC_ED_KEY="<public key>" \
./package_dmg.sh
```

## 3. Publish Files on GitHub

Recommended layout:

- GitHub Releases: upload the DMG file
- GitHub Pages: publish `appcast.xml`

The enclosure URL inside `appcast.xml` should point to the HTTPS download URL of the GitHub Release asset.

## 4. Generate the Appcast

Use Sparkle's `generate_appcast` tool to scan the folder containing the DMG and produce `appcast.xml`. The generated appcast must contain the version, file size, EdDSA signature, and download URL.

Keep this release order:

1. Update the app version and `CHANGELOG.md`
2. Build the DMG with `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`
3. Generate the Sparkle signature for the DMG
4. Upload the DMG to GitHub Releases
5. Upload `appcast.xml` to GitHub Pages
6. Check for updates from the existing app

## 5. Notes

- Sparkle may fail to replace the app if it is running from the DMG. Users should copy the app to Applications first.
- Without Apple Developer ID signing and notarization, the first-launch Gatekeeper warning still applies. Sparkle provides the update flow; it does not replace notarization.
- Never include the private EdDSA key in the repository, release assets, or appcast.
