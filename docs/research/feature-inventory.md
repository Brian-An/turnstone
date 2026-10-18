# Feature inventory and evidence

Research date: 2026-10-18.
This is an independently implemented utility, with original code and system artwork.
The catalog records advertised routes; a catalog entry is not proof that every document layout, codec, or installed engine works.

## Reference behavior

The current [product site](https://tangerineformac.com/) advertises 275 directed conversion routes, 26 tools, and six file actions.
Its interactive demo supplies 45 normalized input formats and the directed route matrix in `Catalog.swift`.
Shift selects conversion, Command selects tools, and Control selects file actions.
The wheel remains open after the modifier is released and waits for the file drop.
The demo's Enter and touch gestures belong to a simulated web playground and do not establish Finder behavior.

The [tools gallery](https://tangerineformac.com/tools) provides published editor screenshots.
The local research set contains 22 screenshots under `/tmp/open-tangerine-research/`.
The screenshots establish visible controls and approximate layout, not undocumented algorithms or failure behavior.
The [press kit](https://tangerineformac.com/press) supports adjacent output files and the general wheel appearance.
The [App Store listing](https://apps.apple.com/us/app/tangerine-file-converter/id6813034065) contains older shortcut wording, so the current site takes precedence.

## Catalog and implementation boundaries

| Area | Catalog scope | Implementation and limits |
| --- | --- | --- |
| Images | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP; SVG input; PDF output | Native image frameworks plus installed ImageMagick for unavailable encoders. Native tools and tests live in `NativeEngine.swift`. |
| Audio and video | Eight audio inputs, seven video/animation inputs, MP3 extraction | Installed FFmpeg and FFprobe. Codec availability depends on the actual local build. Media tools and fixture tests live in `MediaEngine.swift`. |
| PDF | Editable document, presentation, spreadsheet, EPUB, text, Markdown and page images | PDFKit and Vision OCR. DOCX and slides use editable text reflow. Spreadsheet columns infer tabs or repeated spaces. Complex layout, charts, forms, and original formulas are not reconstructed. |
| Text documents | DOCX, Pages, Markdown, TXT, EPUB, RTF, RTFD, text clipping; HTML export | AppKit reads and writes DOCX/RTF/RTFD and paginates text into PDF. Pandoc provides semantic Markdown/HTML/EPUB interchange. DOCX graphics and advanced Office features may lose fidelity through the AppKit text model. |
| Pages | Pages input and output | LibreOffice imports supported Pages documents. Actual Pages output uses Apple Pages' supported document save command and requires Pages plus macOS Automation permission. This path is implemented but was not run against the user's Pages session. |
| Presentations | PPT/PPTX to PDF or all-page JPG/PNG | LibreOffice produces PDF; PDFKit renders every page at a 300 DPI target. PDF to PPTX creates editable text slides rather than recovering original slide objects. |
| Spreadsheets | XLSX, XLS, ODS, CSV, TSV; PDF export | LibreOffice with explicit CSV/TSV delimiters. CSV and TSV preserve a single sheet and cannot retain workbook styling or formulas as workbook objects. |
| EPUB layouts | Reflow and fixed PDF exports | Pandoc writes reflow EPUB. Fixed EPUB preserves each PDF page as an image and includes EPUB navigation, viewport metadata, an uncompressed first mimetype entry, and package metadata. |
| Text clippings | Text and rich text representations | Modern plist `UTI-Data` UTF-8 and RTF representations are read. Legacy resource-fork-only text clippings are not supported. |
| Subtitles and archives | SRT/VTT/TXT and ZIP/TAR/GZIP with RAR input | Native engine owns parsing, archive process execution, validation, and failure handling. RAR is input-only and requires an installed extraction tool. |
| File actions | AirDrop, Float, Copy, Move, Copy Path, Terminal | App layer owns Finder integration, clipboard, floating shelf, destination selection, and terminal opening. |

## Editor and application scope

The tool catalog names compression, metadata, image adjustments, annotation, backgrounds, crop, audio normalization, video mute and trim, PDF split and organization, extraction, PDF creation and merge, video crop and speed, join, snapshots, split, audio visualization, audio trim and channels, collage, redaction, and audio bleeping.
Models expose the corresponding editor options.
The app layer owns actual editor controls, drag detection, keyboard support, cancellation, results, launch at login, and settings.
These controls require native UI inspection before claiming complete visual parity.
No public reference establishes every native settings panel, transition, error state, or processing parameter.

## Document verification

`DocumentEngineTests.swift` uses generated real text, DOCX, PDF, EPUB, and spreadsheet fixtures.
It checks source preservation, output collisions, multipage rendering, EPUB archive content, editable Office text, malformed input failure, and helper-based round trips.
Optional Pandoc and LibreOffice tests skip explicitly when the helper is absent.
Pages output is an explicitly unverified integration because testing it would open and control the user's installed Pages application.
Modern plist text clipping and text-only RTFD package input are covered by real fixtures.
Complex RTFD attachment fidelity remains unverified.

LibreOffice's [conversion filter reference](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html) documents the headless filter interface and available input/output filter families.
The installed Pages scripting dictionary documents its native Pages save format and supported exports.
External processes receive argument arrays, and temporary results are published beside source files with non-overwriting names.
No conversion uploads the file to a service.
