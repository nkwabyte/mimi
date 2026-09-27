# Mimi macOS app

The Xcode project is already at `gui/Mimi/Mimi.xcodeproj`. Do not create a second one. Open that project, select the Mimi scheme, and run it.

The app is a SwiftUI window over the same engine as `bin/mimi`. It scans. It does not clean, restore, purge, or uninstall. Those stay in Terminal until [SYSTEM_REVIEW_2026-09-27.md](SYSTEM_REVIEW_2026-09-27.md) says the matching phase is done.

## What you can do in the window

- **Cleaner.** Pick Safe, Developer, or Aggressive, then Scan Mac. Rows appear as the engine reports them. Filter them, reveal a path in Finder, or copy it. Cancel stops the scan. Nothing is deleted.
- **Overview.** Engine path, version, capabilities, and the last scan's counts.
- **History.** Explains why restore and purge are still Terminal commands.
- **Settings.** Shows the engine path. It does not write `~/.config/mimi`, and it does not offer `--force-risky` or system-scope uninstall.

A scan runs `mimi --jsonl --no-prompt --no-color scan --profile <name>`. Arguments are an array. The app never builds a shell string.

## Where the code lives

```text
gui/Mimi/Mimi.xcodeproj
gui/Mimi/Mimi/
  MimiApp.swift              entry
  ContentView.swift          sidebar
  App/AppModel.swift         scan state
  Engine/                    command, events, decoder, process, mock
  Features/                  Cleaner, Overview, History, Settings
  Resources/Fixtures/scan-safe.jsonl
gui/Mimi/MimiTests/          Swift Testing
```

Xcode 16 folder synchronization picks up new Swift files under `Mimi/` and `MimiTests/` without editing the project file.

The build copies `bin/mimi`, `lib/`, and `libexec/` into the app at `Contents/Resources/engine/` and sets the executable bit. If that copy is missing, the process client looks next to the source tree, then Homebrew. The GUI does not invoke `mimi-root-apply`.

## Corrections to the setup draft

The draft described creating the project and pasting a first client. That project now exists, and the pasted client was wrong in a few places:

| Draft | What the app does instead |
|---|---|
| `--candidate` and a `doctor` command | Neither exists in the CLI. They are not sent |
| Copy the user's whole environment | The process gets `HOME`, `TMPDIR`, a fixed `PATH`, `LANG`, `USER`, and `LOGNAME` only |
| Require `candidate_id` | A scan omits it. The row id becomes `category\|path` |
| Warning is only `message` | The engine sends `code` and `message`. Both are read |
| Non-zero exit always fails the UI | If `run_finished` already arrived, the summary stays. Exit status without that event is a failure |
| App Sandbox with no file access | Left off. A sandboxed app could not read the home directory the engine scans, and the broad home exception is the one we will not add. Hardened runtime stays on. Sandbox comes back with a reviewed entitlement, not before |
| `NSHumanReadableDescription` | Not an Info.plist key. The deployment target is macOS 14.0. Automatic and sudden termination are off |
| Swift packages | None. SwiftUI, Observation, and Swift Testing are in the SDK |
| Apply button | Not shown |

Tests: in Xcode, Product → Test, or from the repository root:

```bash
xcodebuild -project gui/Mimi/Mimi.xcodeproj -scheme Mimi -destination 'platform=macOS' test
```

The fixture and the recorded engine lines live in `MimiTests/EngineEventTests.swift`.

## Security status the app has to respect

Do not add a control that papers over an open engine bug.

| Topic | App rule |
|---|---|
| Root helper, receipt paths, and `BASH_ENV` | Fixed in the engine. The app still does not offer system uninstall |
| `purge .` and restore containment | Fixed in the engine. The app still does not restore or purge |
| Temp-directory mode bit | A `0700` parent is allowed; a world-writable parent is not |
| `clear_dir_contents` | The child is re-checked immediately before `rm`. A swap inside `rm` itself is still possible, so the app still does not clean |
| Plan fields | Actions are length-prefixed. A path containing `::` no longer shifts the inode. Plan files are schema version 3 |

The phased fix is [SYSTEM_REVIEW_2026-09-27.md](SYSTEM_REVIEW_2026-09-27.md). The architecture that this window is growing into is [GUI_WRAPPER_PLAN.md](GUI_WRAPPER_PLAN.md).
