# Development

Turnstone is a native Swift menu bar app targeting macOS 13 or later.
Build with Xcode 26 or later and its macOS SDK.
Use full Xcode to run the XCTest suite.

## Build and run

```sh
./scripts/build-app.sh
open dist/Turnstone.app
```

The build script generates the app icon and ad-hoc signs `dist/Turnstone.app`.
For a debug build, use `CONFIGURATION=debug ./scripts/build-app.sh`.
The application lives in the menu bar; choose **Turnstone** from its menu to open the welcome window.

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

If full Xcode is already selected, `swift test` also works.
Optional-engine tests skip explicitly when their helper is unavailable.
See the [README](../README.md#add-more-formats-optional) to install the local engines.

Tests generate real fixtures and check conversion outputs, source preservation, filename collisions, archive safety, process argument handling, cancellation, media duration and channels, redaction pixels, audio bleep frequencies, editable Office exports, and malformed inputs.
The [verification record](research/verification.md) documents native UI checks and remaining gaps.

## Source layout

- `Sources/TurnstoneCore` owns format rules, validation, safe output publication, and native/media/document engines.
- `Sources/Turnstone` owns the menu bar, wheel, file actions, jobs, settings, and native editors.
- `Tests/TurnstoneCoreTests` checks file processing and safety.
- `Tests/TurnstoneAppTests` checks native UI behavior and interactions.

The [design](superpowers/specs/2026-10-18-macos-design.md) and [implementation plan](superpowers/plans/2026-10-18-macos-app.md) record the researched target and implementation decisions.
See the [feature inventory](research/feature-inventory.md) for supported operations and fidelity limits.

## Interface and branding

The interface uses native Liquid Glass on macOS 26 and later, with translucent material and standard controls on older Macs.
Controls and selection highlights follow the Mac's system accent color, with a blue application icon.
The faceted stone mark is defined in `Sources/Turnstone/BrandMark.swift` and rendered for the menu bar, interface, and app icon.
The build script generates every standard icon representation at its exact pixel size.
PNG exports are available in `docs/brand`.
The stable bundle identifier preserves preferences and macOS permissions.

Wheel slice targets include decorative gaps, with a small overlap to prevent flicker near boundaries.
Hovering inside a slice highlights it without requiring focus.
The highlighted slice moves subtly outward without resizing or bouncing; Reduce Motion keeps it still.
Its outward edge remains a valid drop target.
The wheel confirms copy acceptance before highlighting and remains available until the native drop finishes.
If a held shortcut prevents copying, release the key while continuing to drag the file.

## Contributing

Check the [known limitations](LIMITATIONS.md) before extending a format or workflow.
Run the relevant tests and exercise the actual picker, editor, or drag flow affected by your change.
Use disposable input files when checking file actions.
