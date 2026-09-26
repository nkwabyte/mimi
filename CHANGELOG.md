# Changelog

All notable changes to `mimi`. Versions follow [Semantic Versioning](https://semver.org);
the version printed by `mimi --version` is `MIMI_VERSION` in `lib/core/globals.sh`,
and a release tag must match it.

## [Unreleased]

## [0.2.0]

### Added

- **Application inventory and inspection**: `mimi apps list` and
  `mimi app inspect <target>`, read-only, with `--json`
  (`schemas/apps-list-v1.json`, `schemas/app-inspect-v1.json`). Reports
  provenance (App Store, Homebrew cask, Installer package), code signing,
  nested helpers and extensions, and leftover evidence with confidence levels.
- **App uninstall**: `mimi app uninstall <target>` moves an app, its
  LaunchAgents, and optionally its data (`--purge-data` / `--keep-data`) to a
  quarantine run. Plan-bound (`--plan-only`, then `mimi apply`), verified
  afterwards, restorable with `mimi restore` until `mimi purge`. A running app
  is asked to quit; force-quitting needs a terminal or
  `--force-risky app-terminate`. `--cask` / `--zap` hand off to Homebrew with
  a preview.
- **One-step leftover removal**: `mimi clean --only orphans --remove-orphans`
  (or ticking `orphans` in the menus) moves every leftover found to quarantine,
  with no review file to edit.
- `--report` now lists the largest single files (by space actually used) and
  downloads not opened in 90 days (`--large-file-mb`, `--downloads-stale-days`).
  Both are report-only.
- `mimi --version`.
- `~/.config/mimi/history.jsonl`: an append-only record of uninstalls and
  Homebrew hand-offs.

### Changed

- **Menu cleans ask no questions**: in the interactive menus the category
  selection is the confirmation, including for risky and irreversible
  categories that were ticked. Command-line confirmation rules are unchanged.
- Leftover detection no longer flags macOS's own data (`ByHost`,
  `WebKit/Databases`, `DifferentialPrivacy`, …) or folders of command-line
  tools that are installed (`pnpm`, `dotnet`, `watchman`, …).
- Items protected by System Integrity Protection (such as daemon folders in
  `$TMPDIR`) are skipped as "protected" instead of being reported as
  permission failures.
- `mimi restore` can be run again safely, never overwrites a reinstalled app,
  and says when restored LaunchAgents will start.

### Fixed

- Scans are about 6× faster on large Library folders, and building a plan no
  longer slows down quadratically with its size.
- The interactive screens no longer flash on every keypress.
- LaunchAgent label extraction on invalid plists.

## [0.1.0] - 2026-09-24

First public release: safe-by-default junk and developer-cache cleaner with
scan/clean modes, profiles, whitelist, typed confirmations, the plan → apply →
restore → purge workflow with quarantine, JSON Lines protocol v1, and the
interactive menus. Available through `brew install nkwabyte/mimi/mimi`.

[Unreleased]: https://github.com/nkwabyte/mimi/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nkwabyte/mimi/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nkwabyte/mimi/releases/tag/v0.1.0
