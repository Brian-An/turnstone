# Contributing to Turnstone

Contributions are welcome, including reproducible bug reports, clearer instructions, regression tests, and code changes.
You can contribute through a fork and pull request; direct write access is not required.
For a larger change, open an issue first so the scope and expected behavior are clear.
Be respectful and constructive when reporting problems or reviewing someone else's work.

## Set up a development copy

Use a Mac that can run full Xcode 26 or later, including its macOS SDK and Command Line Tools.
The resulting app targets macOS 13 or later.
The downloadable preview and CI builds use Apple Silicon.

1. Fork [Brian-An/turnstone](https://github.com/Brian-An/turnstone) on GitHub.
2. Clone your fork, add the upstream repository, and create a branch:

```sh
git clone https://github.com/YOUR_USERNAME/turnstone.git
cd turnstone
git remote add upstream https://github.com/Brian-An/turnstone.git
git switch -c fix/describe-your-change
```

Build and launch the app:

```sh
./scripts/build-app.sh
open dist/Turnstone.app
```

The app lives in the menu bar.
Choose **Turnstone** from its menu to open the welcome window.
For a debug build, run `CONFIGURATION=debug ./scripts/build-app.sh`.
Local builds are ad-hoc signed and do not need an Apple Developer account or notarization credentials.

## Install optional test engines

Basic native features work without these tools, but the complete conversion tests need them:

```sh
brew install ffmpeg imagemagick exiftool pandoc
brew install --cask libreoffice
```

Settings → Engines shows availability.
Tests that require an unavailable engine report a skip.
Native Pages export requires Apple Pages and its Automation permission; that permission flow is outside CI.

## Test your change

Run the complete suite using full Xcode:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh
```

If Xcode is installed elsewhere, set `DEVELOPER_DIR` to that installation's `Contents/Developer` directory.
For a focused run while developing, use `swift test --filter TestClassName/testMethodName` with the same developer directory.
Use disposable input files when testing conversions, editors, file moves, or archive extraction.
For bug fixes, reproduce the problem through the app first and add a focused regression test.
Exercise the affected picker, editor, keyboard, or Finder drag flow manually as well.
Preserve originals, validate inputs, and keep cancellation and partial batch failures in mind.

## Find the relevant code

- `Sources/TurnstoneCore` contains the format catalog, validation, output publication, conversion engines, and file moves.
- `Sources/Turnstone` contains the menu bar, wheel, jobs, settings, and native editors.
- `Tests/TurnstoneCoreTests` covers conversion behavior and file safety using generated fixtures.
- `Tests/TurnstoneAppTests` covers native AppKit and SwiftUI interactions.
- `scripts` contains app packaging and optional Developer ID signing and notarization tools.
- `assets` contains public README images and the looping demonstration.

Use existing patterns and keep changes focused.
Add short comments for intent or workarounds that the code cannot explain on its own.
AI notes, plans, and personal workflow files belong in the ignored `docs/` directory or ignored tool directories.
Build outputs and those local notes should stay out of pull requests.

## Open a pull request

Push your branch to your fork and open a pull request against `Brian-An/turnstone`'s `main` branch.
Explain the user-visible behavior, link any related issue, and describe how you verified the change.
Include a screenshot or short recording for interface changes.
Small changes are easier to review than unrelated fixes bundled together.
You do not need to change the app version or publish a binary to contribute.

The **CI / macOS tests and build** check installs the optional engines, runs the XCTest suite, validates shell scripts and property lists, and builds an ad-hoc-signed app.
Logs, test results, and a development app archive are available from the workflow run for seven days.
These archives are development builds rather than notarized releases.
The first workflow run from a new contributor's fork may need maintainer approval.
WindowServer-only checks can skip when a runner has no GUI session; manual Finder dragging and Gatekeeper first launch remain separate checks.

## Report problems

Use the [issue forms](https://github.com/Brian-An/turnstone/issues/new/choose) for bugs, feature requests, and setup questions.
Include your macOS version, chip type, app version, steps to reproduce, and relevant error text.
Share a minimal disposable sample when possible; omit private documents, passwords, signing keys, and other sensitive data.
For suspected vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of filing a public issue.

Contributions are made under this repository's [MIT license](LICENSE).
