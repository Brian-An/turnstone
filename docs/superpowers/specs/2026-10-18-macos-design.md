# Turnstone macOS design

Build an independently implemented, open source, offline macOS file utility with Tangerine's contextual conversion wheel and editing workflow.
Brian requested feature parity and directed implementation to start without further design questions.
The working title is Turnstone; original code, bundled art, sounds, and branding are excluded.

## Product behavior

A menu-bar utility watches active file drags and modifier state.
Shift opens conversions, Command opens applicable tools, and Control opens the six file actions.
The wheel anchors near the pointer, remains visible after modifier release, and commits only when an actual file drop lands inside a valid segment.
An inactive center and gaps between petals cancel the action.
The wheel stays inside the active screen's visible bounds.
Open Files provides a keyboard-accessible alternative with arrow navigation, Return to apply, and Escape to cancel.
The website's Enter gesture belongs to its simulated playground and is not assumed to replace Finder's rename shortcut.

All conversions and edits create a separate output beside the original.
Name conflicts receive numeric suffixes, and cancellation or failure must preserve sources and completed outputs.
Jobs display progress and cancellation, report individual failures, and reveal successful results in Finder.
Mixed selections expose common conversions and compatible tools; actions also accept folders and unknown types.

## Scope

The conversion catalog contains 275 directed routes for 45 normalized input formats, extracted as factual format relationships from the public demo.
The implementation supports the 26 listed tools: compression, metadata, photo adjustment, annotation, backgrounds, image crop, audio normalization, video mute, video trim, PDF split, PDF organization, extraction, PDF creation, PDF merge, video crop, playback speed, video join, snapshots, video split, audio visualization, audio trim, audio channels, collage, image redaction, video redaction, and audio bleeping.
File actions are AirDrop, Float, Copy, Move, Copy Path, and Terminal.
The floating shelf supports dragging files back into other apps.
Settings cover shortcuts, launch at login, sound, Finder reveal, pause, and conversion-engine availability.
There is no account, payment, usage allowance, telemetry, or network conversion service.

## Appearance

Use macOS system typography, translucent materials, rounded separated wheel petals, orange selection, and SF Symbols.
The wheel center identifies the current operation and selection.
Editors use a centered title, large preview, compact native controls, reset where applicable, and a fixed footer with the export action.
Video editors use frame strips and precise time controls; audio editors use waveform previews and draggable ranges.
Photo editors support direct canvas manipulation and live previews.
PDF organization uses movable page thumbnails with rotation, duplication, removal, and optional consistent widths.
Respect dark appearance, reduced motion, readable contrast, keyboard navigation, and accessibility labels.

## Implementation choices

Use Swift 5.9 language compatibility, Swift Package Manager, macOS 13 minimum, SwiftUI, and AppKit.
Work in the explicitly supplied empty directory, on a new codex/initial-macos-app branch.
A separate worktree offers no protection from existing work here because none exists.
Use ImageIO, Core Image, Core Graphics, PDFKit, Vision, and AVFoundation for native processing and previews.
Use FFmpeg for broad media codec support, ImageMagick for unavailable image encoders, ExifTool for broad metadata support, Pandoc and LibreOffice for document and Office interchange, and system archive utilities for archive operations.
External tools are discovered locally and reported clearly in Settings; never show an available operation as completed when its required engine is absent.
Processes receive argument arrays, never file-derived shell commands.
Temporary output is published with a non-overwriting move after a successful operation.

## Acceptance

Compile a runnable .app with a reproducible local build script.
Exercise genuine image, PDF, subtitle, archive, media, and document conversions using generated fixtures.
Test route intersections, unknown types, batch applicability, collision behavior, process failures, source preservation, malformed inputs, and cancellation.
Launch the native app and inspect the wheel, settings, editor, and result flows through the UI.
Record any unverified behavior or remaining parity gaps honestly in the README and parity inventory.
Do not advertise perfect layout recovery from PDF to editable Office documents.

## Reference evidence

- [Product site](https://tangerineformac.com/): format families and current modifier gestures.
- [Editor gallery](https://tangerineformac.com/tools): 22 published editor screenshots and controls.
- [Press kit](https://tangerineformac.com/press): wheel appearance and adjacent output behavior.
- [App Store](https://apps.apple.com/us/app/tangerine-file-converter/id6813034065): batch processing, job windows, menu-bar lifecycle, and version history.

The App Store description retains older shortcuts and the press page retains an older version number.
The current website's shortcuts are the target behavior.
Public screenshots do not establish every settings panel, codec parameter, or native failure state.
