# Known limitations

Turnstone is preview software.
The downloadable app is ad-hoc signed, not Developer ID signed or notarized.
It is an Apple Silicon build; an Intel download is not provided yet.
See the [README](../README.md#install) for installation and [Releasing](RELEASING.md) for packaging.

## Formats and fidelity

Catalog entries describe supported routes; successful conversion depends on the input, available engines, and codecs.
Engines are discovered locally and are not redistributed in this repository or preview download.

PDF-to-Office exports recover editable text and inferred table columns rather than reconstructing complex page layouts, charts, formulas, or slide objects.
Document conversions through AppKit can lose advanced Word formatting and attachments.
Pages output uses the actual native format, but that Automation integration needs verification on a Mac with Pages permission granted.
Legacy resource-fork-only text clippings are unsupported.
Ogg output uses Opus audio.
Compression refuses unattainable targets and keeps the original.
Image whites, blacks, clarity, and dehaze controls use Core Image approximations.
Image crop handles permit free resizing after choosing an initial aspect ratio.

External helper processes receive termination on cancellation; descendants and helpers that ignore termination may require manual cleanup.
Pages, LibreOffice, and other independently installed applications retain their own behavior and preferences.

## Verification gaps

The global Finder drag-and-shortcut gesture remains unverified end to end.
The native picker and keyboard wheel flows have been exercised end to end.
The UI automation tool cannot reliably hold a modifier independently during its drag operation.

Pages output needs Apple Pages and a macOS Automation permission flow that has not been exercised against the user's Pages session.
Positive face detection remains unverified; negative detection and positive text detection are covered.
Stored RAR extraction and conversion are covered, while compressed/encrypted RAR and RAR5 variants remain unverified.
AirDrop delivery, login/restart behavior, audible selection feedback, and the Terminal/iTerm2 destination window have not been verified end to end.
See the [verification record](research/verification.md) for the scope of completed checks.

## Independent implementation

The radial workflow and editor controls are independently recreated from Tangerine's public site and 22 published editor screenshots.
Turnstone uses original Swift code, an original stone logo, and macOS system artwork.
It does not include Tangerine's proprietary code, artwork, sounds, or payment system.
The [feature inventory](research/feature-inventory.md) records research evidence and fidelity limits.
