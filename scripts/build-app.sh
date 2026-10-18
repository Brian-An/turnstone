#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${CONFIGURATION:-release}"
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
codesign --force --deep --sign - "$application"
printf '%s\n' "$application"
