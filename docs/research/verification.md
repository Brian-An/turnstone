# Verification record

Verified locally on 2026-10-18 on an Apple silicon Mac.

## Automated verification

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passed all 78 XCTest cases with zero failures: 61 core cases and 17 app interaction cases.
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

## Quiet conversions and wheel feedback verification

Reproduced automatic Recent Jobs opening and automatic Finder output reveal through a native PNG-to-JPEG conversion before changing the behavior.
Regression tests initially failed for an automatically opened jobs window and for dropping on the enlarged edge of an active slice.
The app test target performs a real conversion and confirms that its output and source exist while Recent Jobs stays closed.
A real WheelCanvas test checks all four cardinal expanded edges, normal neighboring targets, center cancellation, and inactive outer space.
Both tests pass alongside all 61 core cases.

Conversions retain their jobs and errors for manual inspection without opening windows or Finder automatically.
The obsolete automatic-reveal preference is removed; manual Recent Jobs and its Finder reveal button remain available.
A native keyboard conversion produced a separate JPEG while leaving Recent Jobs closed and Finder's window and selection unchanged.
Opening Recent Jobs manually confirmed the completed outputs.

The selected slice enlarges by eight percent, lifts outward by eight points, and uses a spring transition with a stronger accent tint and outline.
The glass fill, outline, and extended hit target use the same transformed path.
The reduced-motion appearance retains color highlighting without spatial movement.
The native lower-slice preview confirmed aligned glass and outline geometry and clearance above the shortcut strip.
The release app builds, passes strict code-signature verification, and was approved by a separate reviewer after the native glass correction.
The updated wheel screenshot records the selected lower slice.
The full global Finder drag gesture and separate accessibility appearance configurations retain the manual verification limits below.

## Subtle selection feedback

Reviewed Apple's [Motion](https://developer.apple.com/design/human-interface-guidelines/motion) and [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) guidance.
Apple recommends brief, precise feedback, subdued trackpad effects, and restrained color on Liquid Glass.
The chosen implementation uses a 140 ms ease-out, a two-point lift, and 2.5 percent enlargement.
These numerical values are implementation choices rather than Apple-prescribed parameters.
The selected petal uses a light accent tint and the system glass edge, with no custom glow, colored outline, bounce, or text scaling.
The existing Reduce Motion and opaque Reduce Transparency branches remain in place.
The updated regression test initially failed against the oversized target, then passed with the compact highlight geometry.
It retains the selected edge at radius 142 and cancels at radius 150 in all four directions.
All 63 tests and the release build pass.
Native wheel inspection confirms a readable light selection tint and compact lower-slice geometry.
The updated wheel screenshot records this appearance.

## Whole-slice outward movement

The selected slice translates as one piece away from the wheel center, with a uniform two-point displacement and no resizing.
Its label, glass path, and active drop target share the same outward displacement.
Deselecting the slice returns it inward to its resting position.
The light tint, 140 ms ease-out, and reduced-motion behavior remain unchanged.
The direction regression checks constant slice size and monotonically outward travel at five angles and five intermediate animation states.
That regression failed against the resizing effect and passes against uniform translation.
All 64 tests, the release build, and strict code-signature verification pass.
The native wheel was inspected and its screenshot updated.
A separate reviewer approved the transformation and hit-target changes.

## Consistent slice entry animation

Each petal has a fixed local glass shape and animates its complete surface outward through a view offset.
Glass surfaces use independent bounds and fixed stacking rather than a shared glass container or selection-dependent stacking.
Labels use the same two-point displacement and 140 ms ease-out timing.
This keeps selection feedback independent of the neighboring slice and the pointer's approach direction.
Reduce Motion suppresses displacement and animation.

The approach regression exercises the actual WheelCanvas hit testing for every slice in four-item and seven-item wheels.
It approaches from the center, outer rim, and both neighboring slices, and asserts that selection remains stable from first entry through the rest of the path and stationary hover.
The initial endpoint diagnostic passed before the rendering change; it did not reproduce the visual artifact.
All 65 tests, the release build, and strict code-signature verification pass.
A separate reviewer found no blocking issues in the local shape geometry, offset order, or fixed stacking.
Native inspection confirms aligned glass and labels for right-side, left-side, and PDF selections.
Pointer entry timing and the full drag gesture retain the automation limits below; native inspection verifies rendered selection endpoints rather than the complete temporal motion.

## Reliable drag lifecycle and immediate highlighting

The discovery timer finds file drags and shortcut changes; native AppKit destination callbacks own hover selection inside the wheel.
Mouse-move and mouse-exit tracking cannot clear an active native drag's selection.
Mouse release keeps the destination panel available until AppKit concludes or ends the drag.
A release outside the destination still dismisses it.
Drop preparation rechecks the release position and freezes the accepted entry and file URLs.
The commit consumes that snapshot once and runs the selection callback asynchronously after the source's copy session.
Sequence checks keep stale end callbacks from cancelling a later drag.

Highlighting requires matching file URLs and a source operation mask that permits copying.
The same checks protect the final commit.
A held shortcut that restricts the source to another operation produces a release-key hint rather than a misleading blue target.
The glass tint and label emphasis change without animation; only the two-point outward offset uses the 140 ms ease-out.
Hosting layout is resolved when selection changes, including during AppKit drag tracking.

Hit targets cover the complete annulus between radii 50 and 140, independent of decorative path gaps.
A three-degree angular overlap, capped at 12 percent of a sector's width, absorbs boundary jitter.
The center and outside remain cancellation regions; an already selected outward edge retains its additional two points with Reduce Motion off.
Sampling every two degrees at radii 51, 98, and 139 confirms no dead gaps in four-, seven-, and twelve-slice wheels.

New tests failed against the original code for decorative gaps, boundary jitter, invalid copy masks, stale release positions, mouse-exit interference, frozen drop commits, and the mouse-up panel race.
The callback harness uses actual AppKit panels and views with a protocol fixture for NSDraggingInfo; it does not synthesize an OS drag session.
It also checks exit and re-entry, duplicate commits, stale end callbacks, idempotent cleanup, stationary mode changes, mismatched file URLs, and outside cancellation.
All 76 tests, the release build, and strict code-signature verification pass without source warnings.
A separate reviewer found no blocking issues.
The rebuilt native app shows aligned blue selection and completed a generated PNG-to-JPEG conversion with no automatic Jobs window.
The wheel screenshot records the rebuilt application.
The exact Finder drag-and-shortcut gesture and frame-by-frame highlight latency retain the manual verification limits below.

## Immediate first-entry acceptance

Valid file drags advertise copy acceptance as soon as they enter the wheel, including its center.
Selection updates on the first movement onto a slice without a dwell timer.
Drop preparation still requires a selected slice at the release position, and center drops still cancel.
The copy cursor can appear over the center and outer cancellation regions while the payload is valid.
The first-entry regression failed against the initial rejection and passes against immediate acceptance, including center cancellation and selection on the first slice update.
Apple documents that updates continue after an initial rejection, so this callback change does not establish the cause of the reported Finder hover delay.
The full 77-test suite passes; actual first-entry timing during the Finder drag gesture remains unverified.

## Full glass input surface before focus

Reproduced the label-only input mask in the actual running application using the WindowServer mouse-down hit test, `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`, from a separate NSApplication-initialized process.
Before the fix, the label radius hit the wheel in all seven slices, while blank points at radii 65, 80, 120, and 135 hit it in none of the seven slices.
The decorative glass was visible but its clear parent-window pixels passed input through to windows underneath.
This is separate from the wheel's full-annulus selection geometry and native drag acceptance logic.

The panel uses a system background with one 8-bit alpha step, 1/255, to give the complete window a stable input surface.
Native glass styling and the nonactivating panel behavior remain intact.
The same external probe against the rebuilt running app hits all seven slices at every sampled radius, including blank glass and labels.
A new regression creates the production panel without making it key and checks 84 blank-glass positions through WindowServer rather than calling the selection method directly.
That regression failed against the clear background and passes with the input backing.
It skips only when no GUI screen is available.

All 78 tests, the release build, and strict code-signature verification pass without source warnings.
A separate reviewer found no blocking issues.
Native inspection confirms the glass appearance remains intact.
Clicking a blank area near the JPG slice's outer edge in the rebuilt app produced a separate JPEG from the generated PNG fixture, without opening Recent Jobs.
The exact Finder drag-and-shortcut gesture remains outside the automation tool's capabilities.

## Remaining verification and fidelity limits

The global Finder drag-and-modifier gesture remains unverified end to end.
The UI automation tool rejects a standalone modifier press and serializes its key-hold and drag operations, so it cannot reproduce that exact gesture reliably.
The global detector and actual drag destination are implemented; the native picker and keyboard flow are verified.
Pages output requires Apple Pages and a macOS Automation permission flow that was not exercised against the user's Pages session.
Face detection and RAR extraction do not have dedicated fixture coverage.
Image crop handles permit free resizing after choosing an initial aspect ratio.
Complex Office layout reconstruction, photo-adjustment approximations, and external helper cancellation limits are described in the README.
The application is not notarized or prepared for public binary distribution.
