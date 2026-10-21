#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${CONFIGURATION:-release}"
signing_identity="${SIGNING_IDENTITY:--}"
if [ "$signing_identity" != - ]; then
  case "$signing_identity" in
    "Developer ID Application: "*) ;;
    *) printf '%s\n' 'SIGNING_IDENTITY must be a Developer ID Application certificate name, or - for a local build.' >&2; exit 1 ;;
  esac
  case "$(security find-identity -v -p codesigning)" in
    *"\"$signing_identity\""*) ;;
    *) printf '%s\n' 'The requested Developer ID Application certificate and private key are unavailable in Keychain.' >&2; exit 1 ;;
  esac
fi
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
application="$PWD/dist/Turnstone.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
cp "$binary_directory/Turnstone" "$application/Contents/MacOS/Turnstone"
cp scripts/Info.plist "$application/Contents/Info.plist"
icon_builder="$(mktemp -d "${TMPDIR:-/tmp}/turnstone-icon.XXXXXX")"
trap 'rm -rf "$icon_builder"' EXIT
swiftc Sources/Turnstone/BrandMark.swift scripts/make-icon.swift -o "$icon_builder/make-icon"
"$icon_builder/make-icon" "$application/Contents/Resources"
if [ "$signing_identity" = - ]; then
  codesign --force --sign - "$application"
else
  codesign --force --options runtime --timestamp --entitlements scripts/Entitlements.plist --sign "$signing_identity" "$application"
fi
codesign --verify --deep --strict "$application"
printf '%s\n' "$application"
