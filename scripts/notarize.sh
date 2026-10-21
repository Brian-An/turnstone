#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [ "$#" -ne 1 ] || [ -z "${NOTARYTOOL_PROFILE:-}" ]; then
  printf '%s\n' 'Usage: NOTARYTOOL_PROFILE=turnstone ./scripts/notarize.sh path/to/Turnstone.app-or.dmg' >&2
  exit 1
fi
target="$1"
case "$target" in /*) ;; *) target="$PWD/$target" ;; esac
codesign --verify --deep --strict "$target"
signature="$(codesign --display --verbose=4 "$target" 2>&1)"
case "$signature" in
  *"Authority=Developer ID Application: "*) ;;
  *) printf '%s\n' 'Notarization requires Developer ID Application signing. Build with SIGNING_IDENTITY first.' >&2; exit 1 ;;
esac
case "$target" in
  *.app)
    case "$signature" in
      *"(runtime)"*) ;;
      *) printf '%s\n' 'The app must be signed with hardened runtime enabled.' >&2; exit 1 ;;
    esac ;;
  *.dmg) ;;
  *) printf '%s\n' 'Choose a signed .app or .dmg.' >&2; exit 1 ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/turnstone-notary.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$target"
if [[ "$target" == *.app ]]; then
  archive="$work/Turnstone.zip"
  ditto -c -k --keepParent "$target" "$archive"
fi
xcrun notarytool submit "$archive" --keychain-profile "$NOTARYTOOL_PROFILE" --wait --output-format plist > "$work/submission.plist"
status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/submission.plist")"
submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$work/submission.plist")"
printf 'Notarization %s: %s\n' "$submission_id" "$status"
if [ "$status" != Accepted ]; then
  xcrun notarytool log "$submission_id" --keychain-profile "$NOTARYTOOL_PROFILE"
  exit 1
fi
xcrun stapler staple "$target"
xcrun stapler validate "$target"
codesign --verify --deep --strict "$target"
if [[ "$target" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$target"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi
