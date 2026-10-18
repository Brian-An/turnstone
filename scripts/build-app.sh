#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
application="$PWD/dist/Open Tangerine.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
cp "$binary_directory/OpenTangerine" "$application/Contents/MacOS/OpenTangerine"
cp scripts/Info.plist "$application/Contents/Info.plist"
swift scripts/make-icon.swift "$application/Contents/Resources"
codesign --force --deep --sign - "$application"
printf '%s\n' "$application"
