# Verification record

Verified locally on 2026-10-18 on an Apple silicon Mac.

## Automated verification

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passed all 61 XCTest cases with zero failures.
The test build and release build produced no source warnings.
`scripts/build-app.sh` produced an ad-hoc signed application in `dist/Turnstone.app`.
`codesign --verify --deep --strict` accepted the application.

Tests exercise the 275-route catalog, compatible batches, file validation, safe output naming, process errors, literal command arguments, cancellation, and move collision checks.
Generated image and PDF fixtures exercise codecs, crops, annotations, metadata, capped previews, searchable PDF compression, rotated page rendering at 300 DPI, grouped exports, page order, and failed-export cleanup.
Archive fixtures reject traversal, absolute paths, symlinks, and hardlinks before extraction.
Document fixtures cover DOCX, UTF-16 text, RTFD packages, modern text clippings, scanned PDF OCR, editable PPTX/XLSX, actual LibreOffice reopen, EPUB layouts, spreadsheets, and presentation image exports.
Media fixtures cover audio/video formats, durations, channels and gains, preserved internal silence, timed redaction pixels, spectral bleep replacement, mixed clip joining, compression limits, and rotated video display coordinates.

## Native UI verification

- Launched the application and inspected its welcome screen, settings, conversion wheel, tool wheel, image editor, and jobs.
- Confirmed optional local conversion engines are available in Settings.
- Used the file picker and keyboard wheel to convert a generated PNG to a separate JPEG beside the source.
- Increased image exposure through the native slider and saved a separate edited PNG through the editor.
- Confirmed successful jobs and Finder result reveal.
- Corrected the welcome window so its Choose Files button and entire wheel preview fit without scrolling.
- Corrected initial keyboard selection so Return immediately applies the highlighted first format.

Screenshots in `docs/screenshots` show this implementation using generated test artwork.

## Review and fixes

A separate code reviewer inspected correctness, security, architecture, performance, and interface-to-engine behavior.
The review found four required changes: rotated video dimensions, PDF metadata field naming, PDF editor reset behavior, and accumulation of full-resolution preview renders.
All four were addressed and rechecked by the reviewer.
Preview work is coalesced to one bounded-resolution render while exports retain the requested full resolution.
Batch moves preflight collisions before relocating any original.
Multipage image exports and split PDFs publish a complete folder after successful staging.

## Liquid Glass interface verification

The interface uses native SwiftUI Liquid Glass on macOS 26 and later and retains the macOS 13 deployment target with availability-gated material and button fallbacks.
The compact welcome screen, glass conversion and tool wheels, keyboard selection, image editor Save Copy, recent jobs, settings, and empty floating shelf were inspected through the running native app on macOS 26.6.2.
The updated welcome screen fits its default window without scrolling.
A PNG-to-JPEG conversion and a separate exposure-adjusted PNG export both completed through the native interface.
The full 61-test conversion suite passed after the restyle.
Updated screenshots record the actual app, using generated fixture artwork.

A separate code review identified a translucent selection fill in the Reduce Transparency branch.
Every petal in that branch has an opaque system background beneath its selection tint, and the reviewer approved the fix.
The shelf row retains a rectangular drag target across its empty space.
Older-macOS material fallbacks, dark appearance, and accessibility appearance settings were checked in code but were not exercised on separate runtime configurations.

## System accent theme verification

Replaced decorative orange with the system accent color across the wheel, window controls, crop and selection handles, media timelines and waveforms, and page badges.
The generated application icon uses a blue gradient.
Semantic warning colors and editable annotation colors retain their existing meaning.
The release app builds and passes strict code-signature verification.
Native UI inspection confirms the blue accent on the welcome screen, conversion wheel, and photo editor controls.
Updated welcome and wheel screenshots show the system accent theme.
A separate reviewer found no actionable issues in the color change.
This appearance-only change was checked with a release build and native UI inspection; the conversion suite was not rerun.
Changing the system accent preference during runtime was not exercised.

## Turnstone branding verification

Renamed the application, menus, login label, executable, Swift package, library, tests, and documentation to Turnstone.
The shared original vector stone mark renders in the welcome screen, wheel preview, About view, menu bar template, and generated app icon.
The app retains its stable bundle identity to preserve preferences and macOS permissions.
The renamed release build and all 61 XCTest cases pass without source warnings.
Strict code-signature verification and Info.plist validation succeed.
Extracting the packaged ICNS confirms exact 16, 32, 64, 128, 256, 512, and 1024 pixel representations.
The 16 and 256 pixel artwork was visually inspected.
Native UI inspection confirms the Turnstone app and menu names, welcome screen, About view, and a completed PNG-to-JPEG conversion through the keyboard wheel.
Updated welcome screenshots and icon exports record the new identity.
A separate reviewer checked rename completeness, shared vector rendering, packaging, and regression scope.

## Remaining verification and fidelity limits

The global Finder drag-and-modifier gesture remains unverified end to end.
The UI automation tool rejects a standalone modifier press and serializes its key-hold and drag operations, so it cannot reproduce that exact gesture reliably.
The global detector and actual drag destination are implemented; the native picker and keyboard flow are verified.
Pages output requires Apple Pages and a macOS Automation permission flow that was not exercised against the user's Pages session.
Face detection and RAR extraction do not have dedicated fixture coverage.
Image crop handles permit free resizing after choosing an initial aspect ratio.
Complex Office layout reconstruction, photo-adjustment approximations, and external helper cancellation limits are described in the README.
The application is not notarized or prepared for public binary distribution.
