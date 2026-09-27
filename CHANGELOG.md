# Changelog

All notable changes to `mimi`. Versions follow [Semantic Versioning](https://semver.org);
the version printed by `mimi --version` is `MIMI_VERSION` in `lib/core/globals.sh`,
and a release tag must match it.

## [Unreleased]

### Security

- `mimi plan` no longer runs cleanup commands. Sixteen categories treated
  plan mode as clean mode and ran `brew cleanup`, `npm cache clean`,
  `simctl delete`, `qlmanage -r`, and (when selected) `docker system prune`
  and snapshot thinning while "only planning". Those categories now record a
  `tool_cleanup` action that `apply` runs.
- `mimi apply` asks the same confirmations `clean` asks: `--yes` no longer
  approves a risky or irreversible category, or an uninstall plan, without
  the typed word or `--force-risky`.
- `mimi apply` re-derives every action and refuses anything mimi would not
  select right now, so an edited or hand-made plan cannot widen what is
  removed. The plan digest now covers the header too (expiry, host, user,
  uid), and host and uid are checked. Plan files are schema version 3.
- A whitelisted path inside a folder being cleared is kept; before, only a
  whitelist entry one level down was honoured.
- Root helper: restore only takes files from inside the run it names,
  payload under a parent that is not root-owned (or is world-writable) is
  reported instead of moved, kernel/system/driver extensions are never
  selected, and the launcher finds the helper from its own resolved path
  rather than `argv[0]`.

### Fixed

- A cross-volume quarantine whose original could not be fully removed
  deleted the complete copy. The copy is now kept and recorded as partial,
  and copies are compared before the original is removed.
- Applying a plan that clears a folder moved the folder itself (for example
  `~/.Trash`); now its contents are quarantined and the folder stays.
- `mimi history` failed on a quarantine run with an empty manifest or a
  restore that only hit conflicts.
- JSON output escapes every control character, so a file name holding ESC
  or 0x01 no longer produces invalid JSON (which ended the GUI's scan).
- `pip` cleanup reported success without checking the command's result.

### Changed

- Quarantine runs live in `~/Library/Application Support/mimi/quarantine`
  (moved from `~/.config/mimi` on first run), excluded from Time Machine and
  Spotlight, and are released after `--quarantine-days` (default 7; `0`
  keeps them until `mimi purge`). Summaries report quarantined and freed
  space separately; `run_finished` gained `quarantined_kb`.
- `--remove-orphans` moves only [strong] leftovers; `--include-weak` adds
  the [weak] guesses.
- One mutating run at a time: a second `clean`, `apply`, `restore`, `purge`
  or uninstall exits 7 while another holds the lock.
- New exit code 6 for a refused plan (was 1).
- New exit code 8 when the work could not be done at all (a plan that could
  not be saved, a quarantine run that could not be created, a failed Homebrew
  or vendor uninstaller hand-off). These exited 3 before, the same as a run
  where some items failed; scripts that treat 3 as "could not run" should
  also check for 8.
- Root helper: a system-wide LaunchAgent is stopped in every logged-in GUI
  session, not only the session of the user who ran `sudo`. `--install`
  compiles the launcher from a root-owned copy of its source with an empty
  environment, and names the files it trusts.
- The GUI keeps its source-path fallbacks (`#filePath`) in Debug builds only.
  Its signing team moved to an untracked `gui/Mimi/Config/Local.xcconfig`.
- Warnings and errors go to stderr; logs are private (0700/0600); colours
  honour `NO_COLOR`; warnings are also sent as JSON `warning` events.
- CI runs on `dev`, lints every module and the root helper, compiles the
  launcher, and builds the GUI and runs its unit tests.
- A test that loads the engine into its own shell keeps the test runner's
  exit trap, so a failure there is reported instead of vanishing.

### Removed

- Dead code: `app_detect_cask_token`, `app_detect_provenance`,
  `get_token_for_entry`, `is_installed_cli_tool`, `category_risk_facets`,
  `category_capability`, `plan_candidate_count`, `plan_validate_schema`,
  `log`, and unused globals.

### Added

- `mimi history`: what mimi has done and which quarantine runs can still be
  restored (`--limit N`, `--json` → `schemas/history-v1.json`).
- Shell completions for bash and zsh, and a `mimi(1)` man page, installed by
  the Homebrew formula.
- An older mimi run after a newer one now says so, once.

### Fixed

- Failure paths that should exit with status 3 (a plan that could not be
  saved, a failed Homebrew hand-off, …) aborted with "unbound variable".
- A plan whose path contains `"` or `\` failed its own integrity check.
- The leftover scan is about 2.5× faster; `app inspect <bundle id>` resolves
  through Spotlight instead of listing every installed app first.

### Changed

- `SECURITY.md` rewritten: supported versions and platforms, private
  reporting, the privilege model, and a privacy statement.

## [0.2.1] - 2026-09-26

### Fixed

- `app uninstall --system` found nothing to remove on macOS 14. Its `plutil`
  prints "Could not extract value" to standard output when a key is missing,
  and that text was read as data. It now uses `plutil` output only when the
  command succeeds, in the root tool and in the app evidence and inventory
  code.

### Changed

- CI and the release workflow use `actions/checkout@v7` and
  `actions/upload-artifact@v7` (Node 24), removing the Node 20 deprecation
  warning.
- `scripts/release.sh` waits for the release pull request's CI checks and
  stops if they fail, before merging.

## [0.2.0] - 2026-09-26

### Added

- `app inspect` shows what an app's Installer packages put on disk
  (`package_payload`) and which items other packages share. Apps installed by
  a package to its own folder are now recognised as package-installed.
- `mimi app uninstall <app> --vendor-uninstaller` launches the app's own
  uninstaller, only if it is an app signed by the same developer as the app,
  after a typed confirmation. Scripts are never run.
- `mimi app uninstall <app> --system` prepares removal of an app's system
  LaunchDaemons, LaunchAgents, and privileged helper tools. mimi writes a
  request and prints the `sudo` command for `libexec/mimi-root-apply`, a small
  standalone tool that re-checks everything, asks you to type the bundle id,
  and moves the items to a root-only quarantine (`--restore`, `--purge`).
  It also handles files an Installer package put on disk for the app when no
  other package shares them, and forgets the package receipt at `--purge`
  once every file is gone. mimi itself never runs as root.
- `sudo libexec/mimi-root-apply --install` installs a root-owned copy of the
  root tool; mimi uses it while it matches and says when it is out of date.
- `scripts/release.sh`, `scripts/bump-version.sh`, `scripts/version.sh` for
  maintainers (see `scripts/README.md`).

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

- A bundle id ending in `.app` (such as `com.acme.app`) is now found as a
  bundle id instead of being treated as a missing path.
- Scans are about 6× faster on large Library folders, and building a plan no
  longer slows down quadratically with its size.
- The interactive screens no longer flash on every keypress.
- LaunchAgent label extraction on invalid plists.

## [0.1.0] - 2026-09-24

First public release: safe-by-default junk and developer-cache cleaner with
scan/clean modes, profiles, whitelist, typed confirmations, the plan → apply →
restore → purge workflow with quarantine, JSON Lines protocol v1, and the
interactive menus. Available through `brew install nkwabyte/mimi/mimi`.

[Unreleased]: https://github.com/nkwabyte/mimi/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/nkwabyte/mimi/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nkwabyte/mimi/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nkwabyte/mimi/releases/tag/v0.1.0
