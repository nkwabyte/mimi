# Independent system review and improvement plan

Status: proposed

Reviewed: 2026-09-27

Baseline: branch `dev` at commit `8375a62` ("finetune and gui implementation"), `MIMI_VERSION="0.2.1"` plus the Unreleased changelog section.

Scope: the whole repository. The CLI engine (`bin/mimi`, `lib/`), the privileged helper (`libexec/mimi-root-apply`, `libexec/mimi-root-launch.c`), the SwiftUI app (`gui/Mimi`), schemas, tests, CI and release workflows, and the documentation.

This review was done without relying on the earlier plans in this folder. Where it agrees or disagrees with them, it says so. It complements [IMPROVEMENT_PLAN.md](IMPROVEMENT_PLAN.md) (the original destination document) and [CLI_IMPLEMENTATION_SCRATCHPAD.md](CLI_IMPLEMENTATION_SCRATCHPAD.md) (the task log). It does not replace them.

## 1. Method

1. Read every engine module, the root helper and launcher, the GUI engine client and model, the schemas, the CI and release workflows, and the top level docs.
2. Ran ShellCheck 0.9.0 over every shell file, not only the two entry points CI lints.
3. Ran the full Bats suite (597 tests) and reproduced each high severity finding below against a disposable fake `HOME`, with the repository's own command mocks on `PATH` and `MOCK_CALL_LOG` recording every external command.

Environment limits, stated plainly:

- The review ran in a Linux container as root, not on macOS. The engine is written for BSD tools, so a small shim translated `stat -f` and `date -r` to their GNU forms. The shim is only for this review and is not part of the repository.
- With the shim, 493 of 597 tests passed. The failures inspected were caused by the environment: permission tests cannot fail as root, the root helper calls `/usr/bin/stat` and `/sbin/md5` by absolute path, `plutil` and `sed -i ''` do not exist on Linux, and tmpfs reuses inode numbers. Rerunning `uninstall.bats` and `plan.bats` with a `date` shim left 3 failures, all environment related. No claim is made here about the suite's status on macOS.
- Every reproduction in section 3 uses code paths that do not depend on those differences, or was rerun with the shim in place.

## 2. Summary

### What is strong

- The safety core is thoughtful. `path_authorize` canonicalizes one component at a time, refuses `..`, checks containment on component boundaries, never follows the final symlink, and pins device and inode between check and mutation (`lib/safety/path.sh`).
- `fs_remove` judges success by the postcondition, not the exit status, and the byte accounting in `clear_dir_contents` and `remove_path` is measured, not assumed (`lib/safety/action.sh`).
- Confirmation classes are real: `--yes` cannot authorize risky or irreversible cleaner actions, and `--force-risky` has to name each one (`lib/safety/confirm.sh`).
- The root helper follows a good design. It sources nothing, re-derives its own candidates, accepts only candidate ids from a request, requires two independent signals per launchd job, moves into a root-only quarantine, and needs a typed confirmation.
- The config file is parsed, not sourced. Plan and history files are written 0600 and atomically.
- The test suite is large (597 cases), uses sentinel files outside the fixture, and mocks every macOS tool.
- The GUI passes an argument array to a fixed executable with a minimal environment and caps line and stderr sizes.

### What most needs attention

1. `mimi plan` is not read-only. It runs real cleanup commands (section 3, R-01).
2. `mimi apply` bypasses the confirmation classes, and plan files are not authenticated. A plan file plus `--yes` can permanently delete any path under `HOME` (R-02).
3. App uninstall became permanent deletion in the latest commit, but the README, module header, schema and tests still describe quarantine (R-03).
4. The test runner fails before running any test, so CI on `main` is red once this branch merges (R-04).
5. Several data-loss edge cases in quarantine, whitelisting and plan apply (R-05 to R-08).

## 3. Findings

Severity:

- P0: can delete or change user data the user did not ask to change, or blocks the release pipeline. Fix before the next release.
- P1: can lose data in an edge case, weakens a documented guarantee, or will cause a P0 once the GUI grows actions.
- P2: correctness, operability, maintainability, or documentation debt.

### R-01 (P0) `mimi plan` runs destructive tool commands

Plan mode is meant to only record proposed actions. Sixteen category functions in `lib/cleaners/categories.sh` decide between "report" and "act" with `if [ "$MODE" = "scan" ]`. In plan mode `MODE` is `plan`, so they fall through to the cleaning branch.

Affected: `cat_quicklook` (line 112), `cat_sim_unavailable` (163), `cat_homebrew` (216), `cat_homebrew_old` (240), `cat_npm` (278), `cat_yarn` (314), `cat_pnpm` (336), `cat_pip` (370), `cat_timemachine` (398), `cat_docker` (424), `cat_docker_cache` (458), `cat_sim_stale` (886), `cat_android` (1071), `cat_dev_caches` (1519, 1542). `cat_dsstore` (96) does not delete in plan mode, but prints "removed 0 .DS_Store files".

Reproduction with the default safe profile and mocks:

```text
$ mimi plan --no-color
...mock call log:
qlmanage -r cache
xcrun simctl delete unavailable
brew cleanup -s --prune=all
npm cache clean --force
```

With `--include-docker --force-risky docker`, plan mode would also run `docker system prune -af --volumes`. With `--include-timemachine` it would thin local snapshots.

Second half of the same defect: none of these categories adds a plan candidate, and `plan_execute_loaded` treats an operation of `tool_cleanup` as success without running anything (`lib/core/core.sh:346`). So `plan` does the work and `apply` claims it did.

Why this matters now: `EngineCommand.plan` already exists in the GUI (`gui/Mimi/Mimi/Engine/EngineCommand.swift`), and its tests assert the arguments. Wiring a Plan button to it today would clean the user's machine while showing "nothing is deleted".

Fix:

1. Add one predicate, for example `is_dry_run() { [ "$MODE" = scan ] || [ "$MODE" = plan ]; }`, and replace every `"$MODE" = "scan"` check that guards a mutation. Grep for the pattern in CI so it cannot return.
2. In plan mode, tool based categories add a `tool_cleanup` candidate that names the category and the exact argument vector, with no path.
3. In apply, run `tool_cleanup` actions through a fixed table keyed by category id, never from the plan's own text, and gate them with the same confirmation class as `clean`.
4. Test: run `plan` for every profile with `MOCK_CALL_LOG` and assert that only read-only invocations appear (an allowlist such as `brew --cache`, `npm config get cache`, `docker info`).

### R-02 (P0) Apply bypasses confirmation classes, and plans are not authenticated

`run_apply` asks one generic `confirm` (`lib/core/core.sh:233`), which `--yes` satisfies. It never calls `confirm_action` per class. Consequences:

- `mimi app uninstall X --plan-only` followed by `mimi apply <plan> --yes` permanently deletes the app and its data. The direct `app uninstall` path requires typing `uninstall` for the same result.
- A plan that clears `~/.Trash` (class `irreversible` when cleaned directly) is applied with `--yes`.

Plan integrity is weaker than the error messages suggest:

- `plan_compute_digest` is an unkeyed SHA-256 over the actions only. Anyone who can write a plan can recompute it. The message "plan file has been tampered with" overstates what is checked.
- `expires_at`, `plan_id`, `user`, `hostname` and `uid` are outside the digest. Editing `expires_at` revives an expired plan (reproduced).
- `hostname` and `uid` are written but never checked. Only `user`, which comes from `$USER`, is compared.
- `risk` is read from the file. Every cleaner candidate is written as `safe` (`lib/safety/action.sh:283` and `:395`), including Trash and iOS backups, so `risk_distribution` in the plan summary is meaningless.
- Containment is `path_authorize`, whose allowed root is all of `HOME`. Nothing ties an action to its category's roots.

Reproduction: a plan written with the repository's own `plan_add_action` and `plan_save`, with one action `uninstall-data wipe <HOME>/Documents`, was applied with `mimi apply plan.json --yes`. Output: `removed: .../Documents`. The folder was permanently deleted in the fixture.

Fix:

1. Apply must gate each action by the class of its category, using `confirm_action`. A `wipe` is always irreversible and needs the typed word or `--force-risky`.
2. Recompute risk from the category registry at apply time. Ignore the file's value, or refuse when they disagree.
3. Enforce category roots: each category declares canonical roots, and an action outside its category's roots is refused.
4. Authenticate plans: an HMAC-SHA256 with a per-user random key kept 0600 under the config directory, computed over the canonical serialization of the whole document, header included.
5. Check `uid` and a host id, not only `$USER`.
6. Bump the plan schema to 3 so older tools refuse new plans.

### R-03 (P0) Uninstall is permanent, while the docs promise quarantine

Commit `8375a62` changed every uninstall action from `quarantine` to `wipe` and made attributable data included by default (`uninstall_data_included` returns true for `ask`). The following still say the opposite:

- `README.md:242`: "Uninstall an app into quarantine (restore undoes it until purge)".
- `lib/apps/uninstall.sh:19-20`: "Nothing is deleted: every action is a move into a quarantine run".
- `lib/apps/uninstall.sh:33-36`: default `ask` "asks once at a terminal; without one (or with --yes), data is kept". The prompt was removed.
- `schemas/plan-v1.json:70`: the `operation` enum has no `wipe`, so every uninstall plan fails its own schema.
- Test names in `tests/uninstall.bats` still say "quarantines app bundle".
- `uninstall_verify_after_apply` classifies leftovers by `quarantine|remove_path|clear_dir_contents`, so a failed `wipe` is reported as "new since the plan was made".
- For `wipe`, reclaimed bytes are the planned size, not a measurement, against the rule stated at the top of `action.sh`.

This is a product decision, but it reverses the core safety property of the original plan ("an app-uninstall apply is restorable until explicit purge"), and it was made in a commit titled as GUI work.

Recommendation: make quarantine the default again, and offer permanent deletion as an explicit `--permanent` option in the `irreversible` class. Restore the one-time data prompt. If the team keeps permanent deletion, then update the README, the header, the schema, the test names and `SECURITY.md` in the same change, and record the decision in the scratchpad's decision log.

### R-04 (P0) The test runner fails before any test runs, and CI coverage is narrow

`tests/run` syntax-checks every file in `libexec/` with `/bin/bash -n`. The new `libexec/mimi-root-launch.c` is C, so the runner exits 1 at the syntax step. CI runs `./tests/run` on macOS, so the macOS job will fail as soon as this branch reaches `main`.

Related CI gaps:

- CI triggers only on `main`. Work on `dev` is never tested until it is merged.
- ShellCheck in CI runs only on `clean.sh` and `bin/mimi`. `lib/load.sh` uses `# shellcheck source=/dev/null`, so none of the 24 library modules are followed, and `libexec/mimi-root-apply`, the file that runs as root, is not linted in CI at all.
- The GUI is never built or tested in CI.

Fix: syntax-check only shell files (by shebang or extension), compile the launcher with `cc -Wall -Wextra -Werror` as its own step, run CI on `dev` and on pull requests to `dev`, run ShellCheck on `lib/*/*.sh`, `libexec/mimi-root-apply` and `scripts/*.sh` at `-S warning`, and add an `xcodebuild test` job.

### R-05 (P1) Cross-volume quarantine can delete the only complete copy

`quarantine_target` (`lib/transaction/quarantine.sh:118-140`) copies the target when it is on another volume, then removes the original. If removing the original fails part way (one file denied inside a tree), it calls `fs_remove "$dest_path"`. The result is a partly deleted original and no copy.

The copy is also only checked for existence, not for size, file count or content.

Fix: on a failed source removal, keep the destination, record the item as `partial` in the manifest, and report it. Before removing the source, compare file count and total size of both trees. Apply the same rule to the cross-volume restore path.

### R-06 (P1) A whitelisted path nested below a cleared entry is deleted

`is_whitelisted` answers "is this target inside a whitelisted path". It never asks "does this target contain a whitelisted path". `clear_dir_contents` checks only one level of children.

Reproduction:

```text
$ mimi clean --only caches --yes --whitelist "$HOME/Library/Caches/com.junk/sub/keep"
  cleared: .../Library/Caches/com.junk  (freed 12.0K)
```

`sub/keep/k` was deleted. The same gap applies to `remove_path`, plan actions and orphan quarantine.

Fix: add an ancestor veto. A target is refused, or descended into, when any path whitelist entry lies inside it. Canonicalize the whitelist once per run instead of once per checked entry. This also removes a subshell per entry.

### R-07 (P1) Applying a `clear_dir_contents` action moves the directory itself

In plan mode `clear_dir_contents` records the directory. At apply, `quarantine_target` moves the whole directory. The semantics differ from `clean`, which keeps the directory:

- `~/.Trash` was moved away in the reproduction, so Finder has to recreate it.
- A running app keeps writing into its cache directory's open handles, now inside the quarantine.
- Whitelisted children inside the directory are moved with it (see R-06).
- Directory ACLs, flags and extended attributes are lost when the system recreates the directory.

Fix: expand `clear_dir_contents` into per-child actions at plan time, or at apply move the children and leave the directory. Apply the whitelist ancestor veto to each child.

### R-08 (P1) Quarantine never frees space and has no lifecycle

- Nothing purges old runs. Every `apply` and every `--remove-orphans` grows `~/.config/mimi/quarantine` until the user runs `purge` by hand.
- The apply summary and the JSON `run_finished` report quarantined bytes as reclaimed. On the same APFS volume, no space is freed.
- The quarantine lives under `~/.config`, which Time Machine backs up and Spotlight indexes. Quarantined caches are backed up again.
- A per-user config directory is the wrong home for gigabytes of data.

Fix: move the quarantine to `~/Library/Application Support/mimi/quarantine`, mark it excluded from backup (`tmutil addexclusion`) and from indexing (`.metadata_never_index`), and add a retention setting (default 7 days) that is enforced at the start of each run, with a summary line. Report "quarantined" and "freed" as separate numbers in text and JSON, and add them to `protocol-v1.json`.

### R-09 (P1) `--remove-orphans` quarantines weak guesses

`--remove-orphans`, and ticking the orphans category for a clean in the TUI, moves every candidate, strong and weak, into quarantine (`lib/cleaners/categories.sh:505-575`). Weak candidates include bare names in `~/Library/Preferences`, `Application Scripts` and `LaunchAgents`, and every candidate when the app index is incomplete. The move is reversible, but an app whose preferences were taken behaves as newly installed until the user finds the right run to restore.

The original plan said weak matches are never selected automatically. This review agrees.

Fix: `--remove-orphans` takes strong candidates only. Weak candidates need `--include-weak` and belong to the `risky` class. When the index is incomplete, `--remove-orphans` refuses and points at the review file.

### R-10 (P1) History breaks on an empty manifest or a restore with no successes

`items="$(grep -c . file 2>/dev/null || echo 0)"` prints `0` twice when the file exists and has no match, because `grep -c` prints `0` and exits 1. The value becomes `"0\n0"`, and `[ "$restored" -gt 0 ]` fails with "integer expression expected". Found at `lib/transaction/quarantine.sh:399`, `:400`, `:438`, `:439` and `libexec/mimi-root-apply:888`.

This happens when every item of a run failed to quarantine (empty manifest), or when a restore produced only conflicts. In `--json` mode it also writes printf errors to stderr.

Fix: use `grep -c . file 2>/dev/null || true` with a numeric default, or count with `awk`. Add a test for both cases.

### R-11 (P1) JSON output can be invalid, which fails the whole GUI scan

`json_escape` and `json_escape_to` (`lib/ui/json.sh:16-36`) escape only backslash, quote, newline, return and tab. Any other control character in a file name (escape, backspace, form feed, 0x01 to 0x1f) produces invalid JSON. `EngineEventDecoder.decode` then throws, and the GUI ends the whole scan as failed. File names that are not valid UTF-8 (possible on non-APFS volumes) are silently dropped by `String(data:encoding:)`.

`json_unescape_to` uses byte 0x01 as a placeholder, so a path containing 0x01 changes on a round trip. The digest check then fails, which is safe but confusing.

Fix: escape every character below 0x20 as `\u00XX`, and represent paths that are not valid UTF-8 with an explicit field (for example `path_b64`). In the GUI, report and skip an undecodable line instead of failing the stream.

### R-12 (P1) Root helper hardening

The design is sound. These are defense-in-depth gaps in code that runs as root:

- `cmd_restore` (`libexec/mimi-root-apply:735-770`) does not check that the quarantined source `q` is inside the run directory. The user-scope restore does. LaunchDaemon, LaunchAgent and helper destinations are accepted by lexical prefix (`"$LD"/*`) with no `..` check. The manifest is root-written, so this is not exploitable today, but it is the only restore path without containment.
- The manifest is line-based TSV. A path containing a tab or newline would shift fields. Candidates come from root-owned files and `pkgutil`, so this is not reachable today. Refuse such paths at derivation time.
- `mimi-root-launch` finds the helper from `argv[0]` (`libexec/mimi-root-launch.c:29`). Use a compiled-in absolute path, or resolve the executable with `_NSGetExecutablePath` and `realpath`, and check that the directory is root-owned and not writable, not only the file.
- `--install` compiles `mimi-root-launch.c` as root from a user-writable directory (`libexec/mimi-root-apply:855`), and needs a C compiler on the user's machine. Ship a prebuilt, signed and notarized launcher, and check the helper's hash against a value in the signed release.
- `stop_job` stops a system LaunchAgent only in the sudo user's GUI domain. Other logged-in users keep running it until logout.
- `payload_allowed` includes `/Library/Extensions`, `/Library/SystemExtensions` and `/Library/DriverExtensions`. Moving a kernel or system extension is not an uninstall. Report these, and point to `systemextensionsctl` or the vendor.
- Between the final checks and `mv -n`, an intermediate directory that is writable by a non-root user (for example `/usr/local/*` on Intel Homebrew setups) can be swapped. Refuse payload items whose parent chain is not root-owned and non-writable, as `_self_trusted` already does for the helper itself.

### R-13 (P1) No run lock

Nothing stops two engine processes at once: the GUI scanning while a terminal cleans, or two terminals applying plans. Log names have one-second resolution. Quarantine runs, history and plans share one directory. The earlier plan asked for interrupted-run records, and those need a lock to be reliable.

Fix: take a lock directory (`mkdir` is atomic) holding the PID and start time. A second mutating run fails with a clear message and a dedicated exit code. Read-only commands may run concurrently.

### R-14 (P2) Exit codes

`EXIT_PARTIAL` and `EXIT_FAILURE` are both 3, so a script cannot tell "some items failed" from "nothing could be done". A stale, expired or edited plan exits with `EXIT_USAGE` (1), the same as a typo. The original plan listed separate codes for a stale plan and a missing permission.

Proposal: keep 0, 1, 3, 4 and 5 as they are, and add 6 for a refused plan (stale, expired, digest, host) and 7 for a missing permission (Full Disk Access, root). Emit the code in `run_finished`, and document every code in `mimi(1)` and `USAGE.md`.

### R-15 (P2) Output streams and log privacy

- In text mode, `warn` and `err` write to stdout. Diagnostics should go to stderr so `mimi scan > report.txt` keeps errors visible.
- The log directory and files use the default umask. They list full paths under `HOME`. Create the directory 0700 and files 0600, as plans and history already are.
- `--no-log` creates its scratch file with the old `cleanmymac-` prefix.

### R-16 (P2) A test escape hatch in production path code

`path_init_roots` skips the TMPDIR provenance check when `TEST_TMPDIR` or `BATS_TEST_DIRNAME` is set in the environment (`lib/safety/path.sh:251`). Any process that sets one of these names disables a safety check. Move the relaxation behind a test-only hook that the harness installs by redefining a function after `load.sh`, and never read test variables in engine code.

### R-17 (P2) The plan reader depends on exact formatting

`plan_load` parses JSON line by line and expects the serializer's exact layout. A plan reformatted by `jq`, an editor or a future GUI loads zero actions, and then fails the digest with a "tampered" message. It fails safe, but the message is wrong and the format is fragile.

Fix: when R-02 lands, define a canonical serialization, and either validate it strictly (reject unknown layout with "not a canonical mimi plan") or move plan parsing into the native helper the original plan's language gate anticipated.

### R-18 (P2) Documentation drift

- `docs/SECURITY_REMEDIATION_PLAN.md` is linked from `README.md:273`, `SECURITY.md:36`, `docs/guide.md:5`, `docs/guide.md:70` and `docs/GUI_WRAPPER_PLAN.md:3`, but the file does not exist.
- `SECURITY.md:36` says the root helper "can still be pointed at a user-writable copy". The launcher and trusted-copy checks now address that, so the statement needs updating either way.
- The GUI profile descriptions in `AppModel.swift` disagree with `mimi --profile list`. Safe already includes Xcode DerivedData and simulator caches. Developer adds `claude-cache`, `docker-cache`, `xcode-archives`, `device-support`, `ide-stale` and `toolchains`. Generate the text from the engine, for example from a `--profile list --json` output.
- `IMPROVEMENT_PLAN.md` still describes the `clean.sh` baseline and the `cleanmymac` command name.
- `CLI_IMPLEMENTATION_SCRATCHPAD.md` is 1,721 lines. Archive completed phases so the active checklist stays readable.

### R-19 (P2) GUI hygiene

- Per-user Xcode state is committed: `gui/Mimi/Mimi.xcodeproj/xcuserdata/` and `project.xcworkspace/xcuserdata/`. Add `xcuserdata/` to `.gitignore` and remove them from the index.
- `DEVELOPMENT_TEAM` is hard-coded in `project.pbxproj`. Move it to an untracked `.xcconfig` so other contributors can build.
- The engine fallback uses `#filePath`, which embeds the build machine's source path in release binaries. Limit that fallback to Debug builds.
- The build phase copies `libexec/` into the app, including the launcher's C source. Copy only what the app needs, and never make the bundled root helper a sudo target (the engine already refuses to, keep it that way).
- `AppModel.cancel` sets the state to cancelled right away, while the engine is still finishing its current action after SIGTERM. Show "stopping" until the process exits.

### R-20 (P2) Static analysis and portability

- ShellCheck over all files, excluding the repository's disabled SC2034, reports: 10 of SC2015 (`A && B || C` used as if/else), 3 of SC2120 and SC2119 (functions whose optional arguments are never passed), 3 of SC2086, 3 of SC2162 (`read` without `-r` in `lib/ui/tui.sh`), 2 of SC2012, and 21 style notes. The SC2088 and SC2053 warnings are false positives and should get inline directives with a reason.
- The suite only runs on macOS, which is the slowest and most expensive CI runner. A small `lib/platform/` layer for `stat`, `date` and `md5` would let most tests run on Linux in seconds, with macOS kept for integration.
- Permission tests assume a non-root user. Skip them when `id -u` is 0 so a container run gives a clean signal.

### R-21 (P2) Performance

`tests/bench` exists, which is good. Hot spots seen while reading:

- `is_whitelisted` canonicalizes every whitelist entry on every call (R-06 fix removes this).
- `dir_size_kb` forks `du` per entry; sizing and deleting walk each tree twice.
- `cat_dsstore` walks the whole home directory on every scan.
- `_receipt_index` in the root helper lists every file of every third party package on each call.

Measure before changing anything. The likely wins are one `du` per category root with per-child output, and caching the receipt index for the duration of one request.

## 4. Improvement plan

Each phase is one or a few small pull requests. A phase is done when its acceptance checks pass on macOS CI.

### Phase A: stop the bleeding (target: before any release or GUI action work)

| Task | Finding | Acceptance |
|---|---|---|
| A1. Syntax-check only shell files, compile the launcher separately | R-04 | `./tests/run` reaches the Bats stage on macOS |
| A2. Run CI on `dev` and PRs to `dev`, ShellCheck all shell files at warning level | R-04 | CI runs on this branch, lint covers `lib/` and `libexec/` |
| A3. `is_dry_run` predicate, replace the 16 scan-only checks, add a CI grep guard | R-01 | Plan for every profile produces only allowlisted read-only mock calls |
| A4. Apply gates each action by its category's confirmation class; `wipe` is irreversible | R-02 | `apply --yes` on a Trash plan or an uninstall plan exits 5 without a typed word or `--force-risky` |
| A5. Decide uninstall semantics and make code, schema, README, header and tests agree | R-03 | A single test name and doc sentence describe what actually happens; the schema enum matches |
| A6. Keep the copy when cross-volume source removal fails | R-05 | Failure-injection test: original partly removed, copy intact, manifest says `partial` |
| A7. Fix the `grep -c` counters | R-10 | `history` and `--runs` work with an empty manifest and a conflicts-only restore |

### Phase B: make plans trustworthy

| Task | Finding | Acceptance |
|---|---|---|
| B1. Plan schema 3: HMAC over the canonical whole document, uid and host id checked | R-02 | Editing any byte, including `expires_at`, is refused with exit 6 |
| B2. Risk recomputed from the registry; category roots enforced at apply | R-02 | A plan that puts `~/Documents` under any category is refused |
| B3. Tool cleanups become `tool_cleanup` actions run from a fixed table | R-01 | `plan` then `apply` runs `brew cleanup` exactly once, at apply |
| B4. `clear_dir_contents` applies to children, never the directory | R-07 | `~/.Trash` still exists after apply; whitelisted children stay |
| B5. Whitelist ancestor veto, canonicalized once per run | R-06, R-21 | The nested whitelist reproduction keeps `sub/keep/k` in clean, plan and apply |
| B6. Strict canonical plan reader with an accurate error message | R-17 | A reformatted plan is refused as "not canonical", not as "tampered" |

### Phase C: quarantine lifecycle and honest numbers

| Task | Finding | Acceptance |
|---|---|---|
| C1. Move the quarantine to Application Support, exclude it from Time Machine and Spotlight, migrate existing runs | R-08 | `tmutil isexcluded` reports excluded; old runs are still restorable |
| C2. Retention setting (default 7 days), enforced at start with a summary | R-08 | A run older than the setting is purged and recorded in history |
| C3. Separate "quarantined" and "freed" in text, JSON and the protocol schema | R-08 | GUI and CLI totals agree with `df` before and after purge |
| C4. `--remove-orphans` is strong-only; `--include-weak` is risky; refuse on an incomplete index | R-09 | Weak candidates are never moved without the named flag |
| C5. Run lock for mutating commands | R-13 | A second concurrent `clean` exits with the lock code and a clear message |

### Phase D: root helper hardening

| Task | Finding | Acceptance |
|---|---|---|
| D1. Restore checks source containment and destination `..`; refuse tab or newline paths at derivation | R-12 | Forged manifest lines are skipped in tests |
| D2. Launcher resolves itself without `argv[0]` and checks its directory | R-12 | A launcher run through a symlink in a user directory refuses |
| D3. Prebuilt signed launcher and helper hash check; no compiler needed at install | R-12 | `--install` works without Xcode tools and refuses a modified helper |
| D4. Parent-chain ownership check before each root `mv` | R-12 | A payload under a user-writable parent is reported, not selected |
| D5. Report kernel and system extensions instead of moving them | R-12 | Fixture with `/Library/SystemExtensions` payload yields a "near" item |

### Phase E: operability, docs and GUI hygiene

| Task | Finding | Acceptance |
|---|---|---|
| E1. Exit codes 6 and 7, documented in `mimi(1)` and `USAGE.md` | R-14 | Tests assert each code |
| E2. Diagnostics to stderr; log directory 0700 and files 0600 | R-15 | `mimi scan 2>/dev/null` shows no warnings; modes asserted in tests |
| E3. Remove the environment based test bypass | R-16 | Setting `TEST_TMPDIR` in a real run changes nothing |
| E4. Fix or restore the missing security remediation doc; update `SECURITY.md`; archive the scratchpad's finished phases | R-18 | No broken relative links (add a link check to CI) |
| E5. JSON control-character escaping and a non-UTF-8 path field; GUI skips bad lines | R-11 | A fixture file named with ESC and 0x01 scans in the GUI tests |
| E6. GUI: ignore `xcuserdata`, move the team id to xcconfig, Debug-only source fallback, profile text from the engine | R-18, R-19 | Fresh clone builds for another team; profile text matches `--profile list` |
| E7. Linux lane for platform-neutral tests; skip permission tests as root | R-20 | Linux CI job passes in minutes |

### Phase F: gates before the GUI may clean, apply or uninstall

The GUI docs already say actions stay in Terminal until security work is done. This review makes those gates concrete. The GUI may offer:

- Plan: only after A3 and B3. Today it would clean the machine.
- Apply: only after A4, B1, B2, B4, C3 and C5, and with the confirmation class shown in the UI for each row.
- Restore and purge: after A6, A7 and C1.
- Uninstall: after A5 and D1 to D4 for anything touching system scope. System scope stays a Terminal action.

## 5. Tests to add

Each of these turns a finding into a permanent regression check:

1. Plan mode makes no mutating external call, for every profile and every opt-in category (R-01).
2. `apply --yes` refuses every `risky` and `irreversible` action without `--force-risky` (R-02).
3. Editing any single field of a saved plan causes refusal (R-02).
4. A plan action outside its category's roots is refused (R-02).
5. Uninstall semantics match the chosen design, and every plan validates against its schema with a JSON Schema validator in CI (R-03).
6. Cross-volume quarantine with an injected source-removal failure keeps the copy (R-05).
7. Nested whitelist entries survive clean, plan plus apply, and orphan quarantine (R-06).
8. Applying a `clear_dir_contents` action leaves the directory in place (R-07).
9. History with an empty manifest and with a conflicts-only restore (R-10).
10. JSON output with every control character parses with a strict decoder (R-11).
11. Two concurrent mutating runs: the second is refused (R-13).

## 6. Verification log

Commands run during the review, for anyone repeating it on macOS (drop the shim):

```bash
# static analysis over every shell file
shellcheck -x -f gcc lib/*/*.sh libexec/mimi-root-apply install.sh scripts/*.sh

# the runner stops at the syntax step
./tests/run < /dev/null        # "libexec/mimi-root-launch.c failed /bin/bash -n"

# R-01: plan runs cleanups
HOME=$FAKE TMPDIR=$FAKE_TMP PATH="$PWD/tests/mocks/bin:$PATH" \
  MOCK_CALL_LOG=$LOG ./bin/mimi plan --no-color
cat "$LOG"

# R-06: nested whitelist
mkdir -p "$FAKE/Library/Caches/com.junk/sub/keep"
HOME=$FAKE ./bin/mimi clean --only caches --yes \
  --whitelist "$FAKE/Library/Caches/com.junk/sub/keep"

# R-10: grep -c fallback
: > empty; x="$(grep -c . empty 2>/dev/null || echo 0)"; [ "$x" -gt 0 ]
```

R-02 was reproduced by building a plan with `plan_add_action` and `plan_save` from `lib/load.sh`, then running `mimi apply <file> --yes` against the fake home.
