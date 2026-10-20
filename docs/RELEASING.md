# Releasing a preview

The current download is an Apple Silicon preview, ad-hoc signed and not notarized by Apple.
A low-friction public release needs an Apple Developer ID Application certificate, notarization, and stapling.
An Apple Development certificate does not replace a Developer ID certificate for distribution.
Keep the preview status and Gatekeeper installation guidance visible until those steps are complete.

## Verify and build

Run from the repository root on an Apple Silicon Mac with full Xcode installed.
Use a clean, committed source tree for a release so the tag identifies the binary's source.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh
codesign --verify --deep --strict dist/Turnstone.app
test "$(lipo -archs dist/Turnstone.app/Contents/MacOS/Turnstone)" = arm64
```

Exercise the actual picker, keyboard wheel, and relevant editor flows with disposable files.
Check the [verification gaps](LIMITATIONS.md#verification-gaps) before changing any readiness claims.

## Package the disk image

The image contains the application, an Applications shortcut, the MIT license, and first-launch guidance.
It does not bundle optional conversion engines.
Run these commands from the repository root after building:

```sh
release_version=0.1.0-preview.1
release_stage=$(mktemp -d /tmp/turnstone-preview.XXXXXX)
ditto dist/Turnstone.app "$release_stage/Turnstone.app"
cp LICENSE "$release_stage/LICENSE"
ln -s /Applications "$release_stage/Applications"
cat > "$release_stage/Read Me.txt" <<'INSTALL'
Drag Turnstone into Applications and open it from there.
Look for the stone icon in the menu bar, then choose Choose Files.
This Apple Silicon preview requires macOS 13 or later.
It is ad-hoc signed and is not notarized by Apple.
If you trust this download and macOS blocks the first launch, follow:
https://support.apple.com/en-us/102445
Setup, limitations, and source: https://github.com/Brian-An/turnstone
INSTALL
hdiutil create -volname Turnstone -srcfolder "$release_stage" -format UDZO "dist/Turnstone-$release_version-arm64.dmg"
hdiutil verify "dist/Turnstone-$release_version-arm64.dmg"
(cd dist && shasum -a 256 "Turnstone-$release_version-arm64.dmg" > "Turnstone-$release_version-arm64.dmg.sha256")
rm -rf "$release_stage"
```

Mount the result, verify its app signature, and confirm that its executable matches the built application.
Test first launch from a browser download on a separate Mac or clean user account before describing the installation as verified.
Only the Apple Silicon architecture is packaged by this procedure.

## Publish on GitHub

Prepare release notes describing system requirements, optional engines, installation, preview limitations, and verification scope.
Publish as a **prerelease**, with the exact committed source SHA as the tag target:

```sh
gh release create v0.1.0-preview.1 \
  dist/Turnstone-0.1.0-preview.1-arm64.dmg \
  dist/Turnstone-0.1.0-preview.1-arm64.dmg.sha256 \
  --repo Brian-An/turnstone \
  --target COMMITTED_SOURCE_SHA \
  --prerelease \
  --title 'Turnstone 0.1.0 preview 1' \
  --notes-file /absolute/path/to/release-notes.md
```

Replace `COMMITTED_SOURCE_SHA` with the full source commit.
Prereleases are not selected by GitHub's stable `releases/latest` route.
Use the explicit versioned download URL in the README and the [website repository](https://github.com/Brian-An/turnstone-site).
Update both URLs and their visible version labels when shipping a newer preview.
Verify the published asset by downloading it and comparing its SHA-256 checksum.
