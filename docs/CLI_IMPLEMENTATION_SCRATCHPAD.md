# CLI implementation scratchpad

Status: active planning

Created: 2026-09-14

Primary plan: [CLI improvement and uninstaller plan](IMPROVEMENT_PLAN.md)

GUI work: deferred until the CLI safety and protocol gates in [GUI wrapper plan](GUI_WRAPPER_PLAN.md) are complete.

Archive: completed phase plans, the progress log and past handoffs are in [archive/CLI_IMPLEMENTATION_LOG_2026-09.md](archive/CLI_IMPLEMENTATION_LOG_2026-09.md).

## 1. Purpose

This is the working checklist for improving the CLI in small, reviewable increments. The main improvement plan explains the destination; this file controls execution order, records decisions, and defines how each task is verified.

The immediate goal is not to add more cleanup targets. It is to make the existing tool safe, testable, predictable, and ready for a future plan/apply uninstaller.

## 2. Status legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Complete and verified
- `[!]` Blocked; reason must be recorded in the blocker log
- `[-]` Removed from scope; reason must be recorded in the decision log

Only one task should normally be `[~]` at a time. A task is not complete because code was written; its tests, documentation, and acceptance checks must also pass.

## 3. Current focus

Phases 0 to 4 are complete; Phase 5 option B and the selected Phase 6 items are done (details in the archive). The independent review ([SYSTEM_REVIEW_2026-09-27.md](SYSTEM_REVIEW_2026-09-27.md)) and its fix pass are done; its open items O-1 to O-8 were implemented on 2026-09-27 (DEC-072 to DEC-074). O-9 (Linux CI) and the signed prebuilt launcher (O-5, second step) wait on the owner.

Current task: none in progress.

## 4. Open tasks

Carried over from the archived phase checklists.

- [ ] `P6-T02` Add age-based Xcode archives/device logs.
- [ ] `P6-T03` Add tool-native SwiftPM cleanup/reporting.
- [ ] `P6-T04` Add iOS backup inventory and per-backup plans.
- [ ] `P6-T06` Add duplicate-candidate reporting without auto-delete.
- [ ] `P6-T08` Add declarative cleaner-rule format, provenance, versioning, and fixtures.
- [ ] `P6-T09` Cache read-only metadata with safe invalidation.
- [ ] `P6-T10` Add bounded concurrency for discovery/sizing only.
- [ ] `P7-T05` Release verification. Needs more than one macOS version/architecture to run on. Partly covered: CI runs on macOS 14 (found the plutil bug), `scripts/release.sh` gates on CI.
  - [ ] Test clean install, upgrade, recovery, purge, and complete self-uninstall.
  - [ ] Test supported macOS versions and architectures.
  - [ ] Produce reproducible checksums and release notes.

## 5. Working rules

### Task size

Each task should fit one focused change set. Split a task if it mixes more than one of these concerns:

- behavior change;
- structural refactor;
- persistence/schema change;
- new external command integration;
- user-facing CLI change;
- destructive-action policy change.

### Change discipline

- Add a failing regression test before fixing a safety defect whenever practical.
- Keep fixtures inside disposable test roots; never aim tests at the real home directory.
- Preserve Bash 3.2 compatibility until a recorded architecture decision changes it.
- Do not combine Phase 0 safety changes with large modularization diffs.
- Do not add a destructive path without an explicit allowed root and failure test.
- Treat README/help/config behavior as part of the public API.
- Record material design choices in the decision log below.

### Task definition of done

Every implementation task must satisfy all applicable items (a checklist to apply per task, not open work):

- Acceptance criteria are demonstrably met.
- New/changed behavior has tests.
- `/bin/bash -n` passes for every shell file.
- ShellCheck passes at the agreed severity.
- Formatting check passes.
- Existing tests pass under macOS Bash 3.2.
- No test touched data outside its disposable fixture.
- Help text and README match behavior.
- Error and cancellation paths have been exercised.
- `git diff --check` passes.
- Scratchpad status and progress log are updated.

## 6. Verification commands

Current commands:

```bash
/bin/bash -n clean.sh
git diff --check
```

Target commands after `P0-T01`/`P0-T11`:

```bash
./tests/run
shellcheck -s bash clean.sh bin/cleanmymac lib/**/*.sh
shfmt -d -ln bash -i 2 -ci clean.sh bin/cleanmymac lib tests
git diff --check
```

Destructive integration tests must run only inside a disposable fixture or VM snapshot and must assert sentinel integrity afterward.

## 7. Open decisions

- [x] `D-001` Keep Bash 3.2 for the entire engine or introduce a small Swift safety/JSON helper after Phase 1? **Resolved 2026-09-24: Bash 3.2 throughout, Bash-owned JSON** (DEC-040, DEC-041). Revisit only for the Phase 5 privileged helper.
- [x] `D-002` Use product-managed quarantine, macOS Trash, or both based on action type? **Resolved 2026-09-24: product-managed quarantine** (DEC-048); plan/apply, uninstall, and orphan removal all use it.
- [x] `D-003` Sign plans cryptographically or rely on private storage, digest, host/user binding, and file identity? **Resolved 2026-09-24: no signature; 0600 storage + SHA-256 digest + user binding + expiry + file identity** (DEC-046, DEC-049). Reopen with Phase 5, where a privileged helper must not trust a caller-supplied plan.
- [x] `D-004` What is the initial minimum supported macOS version? **Resolved 2026-09-24: macOS 12+** (DEC-040).
- [x] `D-005` How long should legacy `clean.sh` flags remain supported? **Resolved 2026-09-24: indefinitely** (DEC-043).
- [x] `D-006` Which one low-risk category should pilot plan/apply/restore? **Resolved 2026-09-24: `caches`** (`P2-T08`).
- [x] `D-007` What is the final project/command name? **Resolved 2026-09-22: `mimi`** (see DEC-027).

Resolve decisions only when their owning phase needs them. Do not let later-phase choices block Phase 0 safety work.

## 8. Decision log

| Date | ID | Decision | Reason | Affected tasks |
|---|---|---|---|---|
| 2026-09-14 | DEC-001 | CLI safety work takes priority over the GUI wrapper. | The GUI must not wrap unsafe or unstable mutation behavior. | All Phase 0-2 tasks |
| 2026-09-14 | DEC-002 | New uninstall behavior will use evidence-based plan/apply and recovery. | A broader name heuristic is not safe enough for app removal. | Phase 2-5 |
| 2026-09-14 | DEC-003 | Phase 0 avoids large modularization changes. | Small safety patches are easier to review and regression-test. | Phase 0-1 |
| 2026-09-21 | DEC-004 | All invalid usage exits `1`, not a new dedicated code. | `1` is already the documented exit for an unknown option and is asserted by an existing test. Introducing `2` would break a published contract for no safety gain. The stability the task asked for is delivered by a single `clean.sh: error: <msg>` prefix on stderr via `die_usage`. | `P0-T08` |
| 2026-09-21 | DEC-005 | Comma lists reject empty and unknown ids, but silently de-duplicate. | `--only caches,caches` is unambiguous and harmless, so erroring would be hostile. `--only ""` is almost always a shell-expansion accident, and running the full default set would be the worst possible reading of it. | `P0-T08` |
| 2026-09-21 | DEC-006 | An invalid config file fails the run even when the CLI overrides that same key. | Validating only the final effective value would let a broken config sit unnoticed until the day the flag is omitted. `--help` and `--list` still work, so the user can always reach the documentation that explains the fix. | `P0-T08` |
| 2026-09-22 | DEC-008 | A literal `..` component is rejected outright rather than resolved and then re-checked. | Resolving it and testing containment afterwards would also be safe, but "no target may contain `..`" is a rule a reviewer can verify by reading one function, and no internal caller ever produces one. A file genuinely named `..config` is unaffected — only a whole `..` component matches. | `P0-T03`, `P0-T04` |
| 2026-09-22 | DEC-009 | The final path component is *not* followed when authorizing; intermediate components always are. | `rm` unlinks a symlink rather than following it, so the link is the object being authorized and its own location is what must be inside an allowed root. Intermediate links are a different matter: they change which directory the path actually names, so they are resolved and the result re-checked. `clear_dir_contents` passes `no-symlink` because globbing through a directory symlink *would* follow it. | `P0-T03`, `P0-T05` |
| 2026-09-22 | DEC-010 | Volume identity is carried by `path_identity` (`stat -f '%d:%i'`) rather than by a separate mount check. | The device number *is* the volume. A target that moved to another volume, or whose mount disappeared and was replaced, gets a different device number and fails the pre-mutation recheck, so one comparison covers both cases without a second mount-table code path. | `P0-T03` |
| 2026-09-22 | DEC-011 | The allowed-root envelope stays as wide as current behavior (`$HOME`, the per-user temp folder, plus explicitly registered roots) instead of being narrowed per category now. | Phase 0 freezes deletion behavior except for safety fixes, and narrowing the envelope per category is `P0-T09`'s job. The value delivered here is that authorization is *decided by canonical identity against an explicit list* at all; tightening that list is a separate, separately testable change. | `P0-T03`, `P0-T09` |
| 2026-09-22 | DEC-012 | The review file stays line-based and gains a version marker rather than becoming a manifest now. | A human edits this file by hand — that is its entire purpose — and a manifest would make that worse for no safety gain, because the safety comes from validating each path against the scanner's own roots, not from the container format. The real manifest is `P2-T01`'s plan schema, and building a throwaway one here would mean designing it twice. The marker (`# cleanmymac-orphan-review v1`) delivers the part that mattered: a file this tool did not write is refused. | `P0-T04`, `P2-T01` |
| 2026-09-22 | DEC-013 | A candidate whose name contains a newline is reported and left out of the review file instead of being written. | A line-based file cannot represent it: writing it emits two lines that each resolve to something else, and at least one of them could name a real, different directory. Silently mangling a path in a file whose only job is deciding what gets deleted is the worst option available. The user is told to remove those by hand, and `P2-T01`'s manifest fixes it properly. | `P0-T04`, `P2-T01` |
| 2026-09-22 | DEC-014 | Reviewed paths must be *direct children* of an orphan root, not merely underneath one. | Every candidate the scanner writes is a direct child, so anything deeper did not come from a scan, and accepting it would turn a reviewed list into a general "delete this subtree" facility. Rejecting it costs nothing real and removes a whole class of hand-edited mistakes. | `P0-T04` |
| 2026-09-22 | DEC-015 | An incomplete installed-app index downgrades *every* candidate to `weak` and is reported loudly, rather than being ignored or made fatal. | The scan's only inference is "nothing claimed this name". If the index is partial, that inference is worthless, so presenting any result as high-confidence would be a lie. Refusing to run instead would be worse: the report is still useful as a list of things to look at by hand, and it is the incompleteness itself the user most needs to be told about. Incompleteness is detected three ways: no `mdfind`, `mdfind` returning zero applications, or `mdfind` returning fewer than a plain directory walk finds. | `P0-T06` |
| 2026-09-22 | DEC-016 | Orphan candidate sizes are no longer added to the reclaimable-space estimate. | `TOTAL_BEFORE_KB` backs the line "Estimated reclaimable space … run again with --clean to actually remove these files". `--clean` now frees none of this, so counting it made the headline figure state something false. The total is reported separately, next to the review file that is the actual route to reclaiming it. | `P0-T06`, `P0-T05` |
| 2026-09-22 | DEC-017 | The direct application walk reads real system directories during CLI-level tests, and this is accepted rather than worked around with an environment override. | A `$PATH` mock cannot intercept a directory walk, and the only override that would help is one that *narrows* the set of known-installed apps — which is the dangerous direction, because fewer known apps means more things look unclaimed. Unit tests confine `ORPHAN_APP_WALK_ROOTS` directly after sourcing the library; CLI tests instead use fixture names no real application can match. | `P0-T06`, `P0-T11` |
| 2026-09-22 | DEC-018 | Success is decided by the postcondition (is the target gone?), not by `rm`'s exit status. | `rm -rf` can delete most of a tree and leave the root, and it can fail for reasons it does not print. Trusting its status is what produced "removed X (freed 400M)" for directories that were still entirely there. Checking the postcondition costs one stat and is the only claim the tool can actually stand behind. The exit status is still captured, for the log. | `P0-T05`, `P0-T10` |
| 2026-09-22 | DEC-019 | Partial failure exits `3`, interruption exits `4`, and `2` is left unused. Permission-denied counts as a failure. | `2` is read as "usage" by too many tools, and DEC-004 already put usage on `1`. Counting denied as a failure is the honest reading: the tool did not do what was asked, and on macOS the cause is almost always Full Disk Access, which the user can fix — so it has to be detectable from a script, not buried in the transcript. It is still reported as its own category so the cause is obvious. | `P0-T05`, `P1-T05` |
| 2026-09-22 | DEC-020 | `SIGINT`/`SIGTERM` raise a flag instead of exiting; the action in progress completes and nothing further starts. | Dying inside an `rm -rf` is precisely how a half-removed tree and a total that describes neither state happen. Letting the current action finish bounds the damage to one target, and the flag is checked before every subsequent action, at both the category and the entry level. The run then exits `4`, so an interrupted run is never mistaken for a completed one. | `P0-T05`, `P1-T07` |
| 2026-09-22 | DEC-021 | `P1-T02`/`P1-T03` were pulled forward and partially done while Phase 0 is still open, at the maintainer's explicit request after the concern was raised. | This contradicts DEC-003 and the "do not combine Phase 0 safety changes with large modularization diffs" rule, and the conflict was stated before the work began. The risk was mitigated by doing it as a *pure move* in its own change set: no behaviour was altered, coverage of the split was verified line-by-line (5,012/5,012 lines assigned, no overlaps), and old-vs-new output was diffed across ten invocations. The remaining Phase 0 tasks are unaffected — they touch `lib/core.sh`, which is a contiguous copy of what they would have touched before. | `P1-T02`, `P1-T03`, Phase 0 remainder |
| 2026-09-22 | DEC-022 | `clean.sh` *sources* `bin/cleanmymac` instead of `exec`-ing it. | An exec re-enters through the `#!/usr/bin/env bash` line, which on a developer machine finds Homebrew's bash 5 — silently destroying the test suite's macOS bash 3.2 guarantee, which is the single most load-bearing property of the harness. Sourcing also keeps `$0` pointing at the shim, so the tool still calls itself "clean.sh" in usage errors, preserving DEC-004's contract without any special-casing. | `P1-T02` |
| 2026-09-22 | DEC-023 | The usage-error prefix became `$SCRIPT_NAME: error:` instead of a hardcoded `clean.sh: error:`. | With two entry points a hardcoded name is wrong for one of them. Deriving it from `$0` is the standard Unix convention and means the tool is always truthful about how it was invoked: `clean.sh` through the shim (unchanged for every existing user and every existing test), `cleanmymac` when `bin/` is run directly. It also sidesteps `D-007` (the final command name) entirely. | `P1-T02`, `P0-T08` |
| 2026-09-22 | DEC-024 | An Android system image is deleted only when the AVD evidence parses cleanly; anything else makes the category report-only. | This was the same mistake `P0-T06` fixed for orphans, with worse consequences. An image was removed because no AVD referenced it — but the reference list was empty whenever `ANDROID_AVD_HOME` pointed elsewhere, when no `config.ini` was readable, or when the file had CRLF endings, and "no references found" was read as "nothing uses these". Format-checking each reference and refusing to act on a broken list costs a re-download at worst. | `P0-T10` |
| 2026-09-22 | DEC-025 | `launchctl unload <path>` was replaced by `launchctl bootout gui/<uid>/<label>`, and failing to stop an agent is reported rather than swallowed. | `unload` is the deprecated interface and says nothing useful; the modern subcommands address a job by label, so the label is read from the plist. The old call ended in `\|\| true`, which hid the one fact the user needed: if the agent cannot be stopped, deleting its plist stops it coming back at next login but does not stop it now. | `P0-T10`, `P4-T04` |
| 2026-09-22 | DEC-026 | Every size the tool measures is allocated (on-disk) bytes; logical size is reporting-only and may never reach a reclaimed total. | `du -skx` already reported allocated blocks, which is the figure that answers "how much would I get back", so the accounting was right — what was missing was saying so. A sparse Docker.raw that Finder shows as 64G may occupy 5G, and the report looked like it was under-counting by tens of gigabytes. `path_logical_kb` and `is_sparse_file` annotate the difference without ever feeding it into a total. The APFS clone over-count is documented as a known limitation rather than papered over. | `P0-T10`, `P6-T11` |
| 2026-09-22 | DEC-027 | The product and command are named `mimi`; the GitHub repository is renamed to match. Resolves `D-007`. | The maintainer's choice. It also clears a real problem the old name had: "CleanMyMac" is a registered commercial product from MacPaw, which `P7-T01` would have had to deal with before any public packaging. `--cleaner` is the documented clean flag, with `--clean` still accepted because every script and every version of the README until now used it. | `P7-T01`, `P7-T02`, all user-facing text |
| 2026-09-22 | DEC-028 | State left by the old name is moved, not left behind or duplicated: `~/.config/cleanmymac` → `~/.config/mimi`, same for the log directory. | A whitelist that silently stops being read protects nothing, which makes "just use the new path" a safety regression rather than a cosmetic one. Moving rather than copying means it happens once and leaves nothing to drift out of sync. Migration never overwrites an existing `mimi` config, and it degrades to reading the old location if the move fails. Orphan review files carrying the old marker are still accepted on input. | `P7-T03` |
| 2026-09-22 | DEC-029 | A declined or unobtainable confirmation exits `5`, not `1`. | DEC-004 put *invalid usage* on `1`, and this is not that: the command line was well-formed and the answer was simply "no". A cron job needs to tell "you typed the flags wrong" (`1`), "the work ran and some of it failed" (`3`) and "you never authorized this" (`5`) apart, because the fix for each is different. Declining one category mid-run stays a skip, not a cancellation — the run did finish. | `P0-T07`, `P1-T05` |
| 2026-09-22 | DEC-030 | `--force-risky` takes action ids and has no `all`. | The plan called for "an exact plan ID", but plans are `P2-T01` and do not exist yet; inventing a throwaway identifier now would mean designing it twice (the same reasoning as DEC-012). The action id is the identifier that does exist, it is the vocabulary `--only`/`--skip` already use, and requiring each one to be named is what stops the flag outliving the reason it was added. `all` is rejected explicitly rather than merely unimplemented, because a silently-unsupported spelling would look like it worked. It authorizes but does not select: `--include-<name>` is still required, so neither flag is dangerous alone. | `P0-T07`, `P2-T01` |
| 2026-09-22 | DEC-031 | `--force-risky` is command-line only: never read from the config file, never written by `save_config`. | An authorization that can be saved once and forgotten is indistinguishable from the `--yes` behaviour this task removed. `load_config` reads an explicit key allowlist, so a hand-added `FORCE_RISKY_LIST=` line is ignored rather than honoured, and a test asserts it. | `P0-T07` |
| 2026-09-22 | DEC-032 | A non-interactive run that selected unauthorized risky work fails before the first category instead of skipping that category and continuing. | Skipping would leave the run exiting `0` with the dangerous work quietly undone, which is the same class of untruth `P0-T05` fixed for action accounting. Failing up front also costs nothing: no category has run, so there is no half-finished state to reason about. The cost is that a cron line which relied on `--yes --include-trash` now does nothing until it is updated — which is the intended breaking change, not a side effect. | `P0-T07`, `P0-T05` |
| 2026-09-22 | DEC-033 | At a terminal, an irreversible action is confirmed by typing the action's own id; a risky one keeps `y/N`. The typed answer is given once per id per run. | "y" is muscle memory and an irreversible prompt needs an answer a hand cannot give by accident. Asking per item would be the same keystroke repeated, so the typed answer authorizes the *class* of action once and each individual item still gets its own `y/N` — strictly stronger than the single `y/N` per item that existed before. | `P0-T07` |
| 2026-09-24 | DEC-034 | Category selection precedence is strictly defined: CLI `--only` > CLI `--profile` > `CONFIG_SELECTED_CATEGORIES` > `CONFIG_PROFILE` > default profile (`safe`). | Ensures predictable resolution across flags, saved profile, and legacy selection configurations. `--only` always isolates the exact specified set; profiles specify structured defaults without overriding explicit user intention. `--skip` wins over everything. | `P0-T09`, `bin/mimi`, `lib/validate.sh` |
| 2026-09-24 | DEC-035 | `caches`, `logs`, `timemachine`, `device-support`, and `homebrew-old` are moved out of unqualified defaults (`default=0`), leaving the default `safe` profile strictly narrow and regenerable. | Broad user app caches and logs can have surprising performance or session side-effects; Time Machine thinning has system APFS impact; old Homebrew versions and device support have rebuild costs. These are now opt-in via `--profile aggressive` / `developer` or explicit `--include-*` / `--only` flags. | `P0-T09`, `lib/core.sh`, `lib/validate.sh` |
| 2026-09-24 | DEC-036 | Homebrew cleanup is split into two distinct categories: `homebrew` (download cache only, safe) and `homebrew-old` (installed formula/cask versions and `brew autoremove`, moderate/opt-in). | Purging downloaded tarballs is safe and always regenerable on demand; removing installed formula versions or dependencies can break pinned local setups. Splitting them lets users safely clear downloads without touching installed packages. | `P0-T09`, `lib/core.sh` |
| 2026-09-24 | DEC-037 | A four-facet risk classification model (`category_risk_facets`: recoverability, data loss risk, rebuild/download cost, system impact) is established for all 36 categories and unified with `confirm_class`. | Replaces ad-hoc risk strings with structured facets. `category_info`'s risk column is updated so `irreversible` and `risky` align exactly with `confirm_class` in `lib/confirm.sh`, verified by Bats consistency tests. | `P0-T09`, `lib/core.sh`, `tests/profiles.bats` |
| 2026-09-24 | DEC-038 | CI runs full tests on macOS (Apple Silicon runner, system Bash 3.2), and supplementary static checks (ShellCheck, doc whitespace) on Ubuntu. ShellCheck is wired into `tests/run`. | Enforces macOS Bash 3.2 compatibility natively where the tool actually runs, while keeping fast linting and style validation in GitHub Actions and local test execution. | `P0-T11`, `.github/workflows/ci.yml`, `tests/run` |
| 2026-09-24 | DEC-039 | The canonical tool command and binary name is `mimi` (located at `bin/mimi`), with `clean.sh` preserved as a sourcing wrapper. | Replaces temporary project names and avoids commercial trademark conflicts while keeping full compatibility for existing invocations. | `P1-T01`, `bin/mimi`, `clean.sh` |
| 2026-09-24 | DEC-040 | The execution baseline is macOS 12+ running Apple system Bash 3.2.57(1) at `/bin/bash` with zero required external runtimes. | The tool must execute reliably on fresh, out-of-the-box macOS installations without requiring Homebrew, Homebrew Bash 5, Python, Node, or jq. | `P1-T01`, all shell files |
| 2026-09-24 | DEC-041 | JSON Lines protocol serialization is Bash-owned via `lib/json.sh`. | Pure Bash string formatting and character escaping ensures streaming event emission with zero subprocess overhead and no dependency on python or jq. | `P1-T01`, `P1-T06`, `lib/json.sh` |
| 2026-09-24 | DEC-042 | Strict module rules: files in `lib/*.sh` define functions/constants only, must not mutate filesystem or exit on source, must load idempotently, and declare all shared state in `lib/globals.sh`. | Keeps modularization safe, preventing accidental side-effects during sourcing and keeping modules independently testable. | `P1-T01`, `lib/load.sh` |
| 2026-09-24 | DEC-043 | Compatibility period for legacy flags and artifacts is indefinite. | Preserves `clean.sh`, `--clean` synonym, and automatic migration from `~/.config/cleanmymac` without surprise breakage for established user scripts. | `P1-T01`, `P1-T08` |
| 2026-09-24 | DEC-044 | JSON Lines protocol v1 reserves stdout strictly for JSON Lines events; all human logs and diagnostics are diverted to stderr. | Ensures GUIs and automation clients can stream parse stdout directly without multiplexing errors or escaping ambiguities. Schema is formalized in `schemas/protocol-v1.json`. | `P1-T06`, `lib/json.sh`, `lib/log.sh` |
| 2026-09-24 | DEC-045 | `lib/core.sh` is fully modularized into `categories.sh`, `tui.sh`, `report.sh`, `orphans.sh`, and `registry.sh`, reducing `core.sh` from 3,582 to 169 lines. | Enforces clean separation of concerns, decouples category implementations from runner loops via registry dynamic dispatch, and keeps each component independently verifiable. | `P1-T03`, `P1-T04`, `lib/` |
| 2026-09-24 | DEC-046 | Plan schema v1 (`schemas/plan-v1.json`) formalizes immutable plan structure, host binding, action arrays, SHA-256 digest, and atomic `0600` save. | Replacing ad-hoc mutation with an immutable, cryptographically verifiable plan prevents path tampering, stale execution, and unauthorized modifications. | `P2-T01`, `lib/plan.sh` |
| 2026-09-24 | DEC-047 | Planner API derives deterministic candidate IDs from category and canonical target path; plans are built strictly from discovered candidates, never arbitrary caller-supplied paths. | Guarantees that neither CLI users nor external integrations can craft malicious deletion manifests targeting unauthorized paths. | `P2-T02`, `lib/plan.sh`, `lib/action.sh` |
| 2026-09-24 | DEC-048 | Quarantine executor and restore store quarantined targets by run ID in `~/.config/mimi/quarantine/<run-id>` with `manifest.jsonl`, performing atomic same-volume moves and verified cross-volume copy/move. | Ensures all removals are recoverable by default before explicit purge, replacing immediate irreversible deletions. | `P2-T04`, `P2-T06`, `lib/quarantine.sh` |
| 2026-09-24 | DEC-049 | Plan preflight checks reject tampered digests, expired timestamps, mismatched host/user bindings, and targets whose inode/device identity changed since plan creation. | Prevents execution of stale, replayed, or malicious plans against modified files. | `P2-T03`, `lib/plan.sh` |
| 2026-09-24 | DEC-050 | Purge is strictly separated from clean/apply into an explicit `mimi purge <run-id>` command requiring dedicated confirmation. | Enforces operational separation between safe cleaning/quarantine and permanent data destruction. | `P2-T07`, `bin/mimi`, `lib/core.sh` |
| 2026-09-24 | DEC-051 | Reorganized all 18 library modules into 5 functional subdirectories (`core/`, `safety/`, `transaction/`, `cleaners/`, `ui/`), sourced through single entry point `lib/load.sh`. | Cleanly clusters modules by single responsibility, reduces root clutter, maintains self-describing headers, and preserves 100% backward compatibility across all 370 tests. | `lib/`, `lib/load.sh`, `tests/layout.bats` |
| 2026-09-21 | DEC-007 | The integer validator is named `validate_int` and accepts zero, rather than the planned `validate_positive_int`. | `--keep-logs 0` and `--keep-toolchains 0` are meaningful, so "positive" would have been an inaccurate name for the required behaviour. The task text asks for *bounded non-negative* integers. | `P0-T08` |
| 2026-09-26 | DEC-052 | Remnant evidence has six confidences (authoritative, strong, corroborated, weak, conflicting, shared) mapped to three classes (attributable, review, retained); only `attributable` is selectable, via the single predicate `evidence_is_selectable`. | One rule shared by `app inspect` and every planner means a weak, shared, or sibling-owned item cannot become an action by a second code path drifting. | `P3-T05`, `lib/apps/evidence.sh`, `lib/apps/uninstall.sh` |
| 2026-09-26 | DEC-053 | Bundle-id matching is component-boundary aware (`exact`, `child` = `id.*`, `prefix` = `*.id`) and case-insensitive; substring matching is removed. | `com.foo.application` must never be evidence for `com.foo.app`. | `P3-T04`, `ev_id_match` |
| 2026-09-26 | DEC-054 | Evidence paths are canonicalised with `nofollow` and must lie inside their root; a symlinked remnant is recorded as the link, `weak`, and its target is never followed. | Prevents a link in `~/Library` from pulling user documents elsewhere into a report or a future plan. | `P3-T04`, `record_evidence` |
| 2026-09-26 | DEC-055 | App eligibility is decided at inspection (`APP_INFO_ELIGIBLE`): system/Apple apps, missing `Info.plist`, missing bundle id, and Team-signed identifiers contradicting the bundle id are ineligible; unsigned/ad-hoc bundles only warn. | Ad-hoc and unsigned apps are common and legitimate; a signed identity that disagrees with its own Info.plist is not. | `P3-T02`, `lib/apps/inventory.sh` |
| 2026-09-26 | DEC-056 | Explicit application roots (`--app-root`, `MIMI_APP_SEARCH_ROOTS`) disable Spotlight; host locations (Caskroom, receipts, `/Library` roots) are overridable only through `MIMI_*` environment variables used by tests. | Spotlight results cannot be constrained to a caller's root, and production code must not read test variables such as `FAKE_HOME`. | `P3-T01`, `P3-T03`, `tests/apps.bats` |
| 2026-09-26 | DEC-057 | `apps list --json` and `app inspect --json` emit single JSON documents versioned `mimi.apps-list/1` and `mimi.app-inspect/1` (`schemas/apps-list-v1.json`, `schemas/app-inspect-v1.json`), not JSON Lines events. | They are request/response reports for the GUI, not a streamed run; a versioned document is the stable contract `P3-T06` asks for. | `P3-T01`, `P3-T06`, `schemas/` |
| 2026-09-26 | DEC-058 | In the interactive UI, the category selection is the confirmation: a menu clean answers the whole-run gate and authorizes each selected risky/irreversible category as `--force-risky` would, and nothing unselected. CLI prompts are unchanged. | The user reviews every category and its colour-coded risk before pressing `c`; further prompts duplicated that decision. The CLI keeps its gates because a flag in a script is easy to forget, which is the rationale of DEC-029–DEC-033. | `lib/ui/tui.sh`, `lib/safety/confirm.sh`, `tests/confirmations.bats` |
| 2026-09-26 | DEC-059 | Orphan leftovers can be removed in bulk: `--remove-orphans` (or the orphans category ticked for a menu clean) moves every candidate, strong and weak, to a quarantine run. Naming the flag is the authorization; no review file or `--force-risky`. | The review-file round trip was too inconvenient to use. Bulk removal of a heuristic list is only acceptable because it is undoable: quarantine plus `restore`, with space released only by an explicit `purge`. Obvious non-leftovers (macOS structure, installed CLI tools) are excluded first. | `P0-T06` (amended), `lib/cleaners/categories.sh`, `lib/cleaners/orphans.sh` |
| 2026-09-26 | DEC-060 | Uninstalls are ordinary plans executed from the saved file by the shared executor (`plan_execute_loaded`). App bundles are authorized by a dedicated rule (`uninstall_authorize_bundle`) rather than by adding application folders to `path_authorize`'s roots. Plans gain a no-op `retain` operation recording what must survive. Force-quitting an app is the risky action `app-terminate`. | Widening the global allowed roots to /Applications would let every cleaner reach it; a category-scoped rule keeps the blast radius to one bundle. Recording retained items in the plan makes "shared resources survive" verifiable from the plan alone. Unsaved work is the one thing quarantine cannot restore. | `P4-T01`–`P4-T06`, `lib/apps/uninstall.sh`, `lib/core/core.sh`, `lib/transaction/plan.sh`, `schemas/plan-v1.json` |
| 2026-09-26 | DEC-061 | Privileged scope uses option B: a standalone `libexec/mimi-root-apply` run explicitly with `sudo`. It re-derives candidates itself; mimi only writes a request selecting candidate ids (hash of kind, path, device:inode) and prints the sudo command. Two independent attribution signals, root-owned regular files only, root-only quarantine with restore/purge, typed bundle-id confirmation. | Keeps the code that runs as root to one reviewable file, works with the existing Homebrew formula and no code-signing, and makes a forged request unable to name a path. Option C (SMAppService) is deferred to the GUI, when a Developer ID-signed app exists. | `P5-T03`–`P5-T05`, `libexec/mimi-root-apply`, `lib/apps/uninstall.sh`, `docs/PRIVILEGED_DESIGN.md` |
| 2026-09-27 | DEC-062 | Identifiers for the GUI and its parts use the `io.github.nkwabyte.mimi` family: app `io.github.nkwabyte.mimi`, unit tests `…mimi.tests`, UI tests `…mimi.uitests`, a future SMAppService helper `…mimi.helper` (also its launchd label), app group `group.io.github.nkwabyte.mimi` if one is ever needed. The CLI has no bundle id and keeps `~/.config/mimi`; the GUI reads and writes state only through the engine. | Reverse-DNS on a namespace the owner controls (the GitHub account) without needing a domain; `com.nkwabyte.*` is equally fine if the domain is owned. It must be fixed before the first signed build: macOS keys Full Disk Access grants to the bundle id, so changing it later silently drops the user's permission. | `P7-T01`, `docs/GUI_XCODE_WALKTHROUGH.md` |
| 2026-09-27 | DEC-063 | `EXIT_FAILURE` is 3, the same code as a partial run. It had been used in a dozen failure paths without being defined, so under `set -u` those paths aborted with "unbound variable". A layout test now fails if any `EXIT_*` name is used but not defined. | The documented exit codes are 0/1/3/4/5; "the work ran and did not succeed" is 3. The scratchpad's earlier claim of `EXIT_PERMISSION=6`/`EXIT_STALE=7` was never true and is corrected. | `lib/core/validate.sh`, `tests/layout.bats` |
| 2026-09-27 | DEC-064 | Downgrades warn, formats refuse: `~/.config/mimi/.version` holds the newest version that used the folder; an older mimi warns once. Unsafe cases are refused by the data itself (plan `schema_version`, history `v`, protocol/document versions); quarantine manifests are unchanged and stay restorable in both directions. | A hard refusal on any downgrade would block restore after a user rolls back to fix a regression, which is exactly when restore matters most. | `P7-T03`, `lib/core/config.sh` |
| 2026-09-27 | DEC-065 | Config-file lists stay comma-separated; paths containing a comma or newline are not supported there (use `--whitelist` on the command line). | Every path that reaches a mutation already travels in JSON plans or argv, which carry any byte; changing the config format is not worth a migration. | parking lot |
| 2026-09-27 | DEC-066 | Plan mode is read-only: every category decides "act or describe" with `is_dry_run`, and a category that cleans with its own tool records one `tool_cleanup` action that `apply` runs through the category's own code. | Sixteen categories checked only for `scan`, so `mimi plan` ran `brew cleanup`, `npm cache clean` and others (review R-01). | `lib/core/util.sh`, `lib/core/core.sh`, `tests/review_fixes.bats` |
| 2026-09-27 | DEC-067 | A plan only selects. `apply` re-derives every action (cleaner categories re-scanned in plan mode, uninstall data re-attributed) and refuses the plan if any action is not selected now. The digest covers the header and stays unkeyed; host and uid are checked; schema 3. | Authority comes from re-derivation, as in the root helper, so no signing key has to be managed (review R-02). | `lib/transaction/plan.sh` |
| 2026-09-27 | DEC-068 | `apply` asks the same confirmations `clean` asks, once per category; a `wipe` needs `uninstall`. | `--yes` alone applied irreversible plans (review R-02). | `lib/core/core.sh`, `lib/safety/confirm.sh` |
| 2026-09-27 | DEC-069 | App uninstall deletes permanently (owner decision). It is irreversible-class; quarantine is for cleaner plans and orphans only. | Uninstall should mean removal; docs, schema and tests were brought in line (review R-03). | `lib/apps/uninstall.sh` |
| 2026-09-27 | DEC-070 | Quarantine lives in `~/Library/Application Support/mimi/quarantine`, excluded from Time Machine and Spotlight, released after `QUARANTINE_KEEP_DAYS` (default 7). Cleared folders are applied child by child. Cross-volume moves never discard the complete copy. | The quarantine used to grow forever, be backed up, and move whole folders such as `~/.Trash` (review R-05, R-07, R-08). | `lib/transaction/quarantine.sh` |
| 2026-09-27 | DEC-071 | `--remove-orphans` moves `[strong]` leftovers only; `--include-weak` adds guesses. One mutating run at a time (exit 7); a refused plan exits 6. | Weak guesses were moved by default; concurrent runs could interleave (review R-09, R-13, R-14). | `lib/cleaners/categories.sh`, `lib/ui/log.sh` |
| 2026-09-27 | DEC-072 | `EXIT_FAILURE` is 8, separate from a partial run (3). Supersedes the code chosen in DEC-063; the layout test stays. | A script must tell "some items failed" from "the work could not be done at all" (review O-6, approved by the owner). | `lib/core/validate.sh`, help, man page, README, USAGE |
| 2026-09-27 | DEC-073 | The root helper stops a system-wide LaunchAgent in every GUI session (users found by their `loginwindow` process) and compiles the launcher from a root-owned copy of its source with an empty environment. A signed, notarized prebuilt launcher waits on a Developer ID. | One user's `bootout` left the agent running for everyone else; the compile trusted inherited compiler settings (review O-4, O-5). | `libexec/mimi-root-apply`, `tests/root_apply.bats` |
| 2026-09-27 | DEC-074 | The GUI is built and unit-tested in CI with code signing off; its signing team lives in an untracked `Local.xcconfig`; `#filePath` fallbacks are Debug-only. The engine's exit handler chains any exit trap already installed. Completed phases moved to `docs/archive/`. | Review O-1, O-2, O-3, O-7, O-8. | `.github/workflows/ci.yml`, `gui/Mimi/Config/`, `lib/ui/log.sh` |

## 9. Blocker log

| Date | Task | Blocker | Needed to unblock | Status |
|---|---|---|---|---|
| 2026-09-26 | `P5-T03` → `P5-T04`, `P5-T05` | Privileged architecture needs the owner's choice (A: hand-offs only, B: minimal `sudo` apply tool, C: `SMAppService` helper) — see `docs/PRIVILEGED_DESIGN.md` | A recorded decision (DEC entry) | resolved 2026-09-26: B (DEC-061) |

## 10. Discovery and parking lot

Add newly discovered work here before assigning it to a phase. Do not silently expand an in-progress task.

- [x] ~~Decide whether configuration lists must support commas/newlines in paths.~~ Decided 2026-09-27 (DEC-065): no. Config lists stay comma-separated; a path containing a comma or newline is whitelisted with `--whitelist` on the command line instead. Plans (JSON) already carry any path.
- [x] ~~Measure how Spotlight incompleteness should be surfaced to users.~~ Done in Phase 3: `apps list`/`app inspect` report `inventory.complete` and notes; the orphan scan marks everything weak and warns.
- [x] ~~Research safe last-used signals.~~ `kMDItemLastUsedDate`, then `kMDItemDateAdded`, never mtime (P6-T07). Not yet applied to applications themselves.
- [x] ~~Define allocated versus logical byte reporting.~~ Allocated everywhere (`dir_size_kb`), logical shown for sparse files (`path_logical_kb`, report); APFS clones over-count is documented in `util.sh`.
- [x] ~~Expose Full Disk Access limitations.~~ Permission denials are counted separately, named in the summary, emitted as `permission_required`, and `warn_if_no_full_disk_access` runs before clean/apply. SIP-protected items are separated from FDA denials (2026-09-26).
- [x] ~~Audit the current project name before public packaging.~~ Resolved 2026-09-22: renamed to `mimi`, which also avoids the MacPaw "CleanMyMac" trademark.
- [x] ~~`save_config` is not atomic and does not set restrictive permissions.~~ Resolved 2026-09-22.
- [x] ~~No golden-file snapshot of `--list` yet; the category table is asserted only by spot-check (remaining `P0-T02` item).~~ Resolved 2026-09-24 in `tests/profiles.bats` (test 309).
- [x] ~~`save_config` round-trip is untested.~~ Resolved 2026-09-22 in `tests/defects.bats`.
- [x] ~~ShellCheck and shfmt are documented in `tests/README.md` but not yet installed or wired into `tests/run`; the definition-of-done lint gate is therefore not enforced.~~ Resolved 2026-09-24: ShellCheck wired into `tests/run` and GitHub Actions CI.
- [x] ~~Interactive TUI screens have no automated coverage.~~ Resolved 2026-09-26: the `MIMI_TUI_INPUT` seam feeds keystrokes from a file; `tests/tui.bats` covers the picker (toggle, arrows, all/none, scan, clean), menus, settings, and whitelist. Rendering on a real terminal is still checked by hand.
- [x] ~~The `CLEANMYMAC_LIB_ONLY=1` test hook only exposes helpers defined above the argument-parsing banner.~~ Resolved 2026-09-22: the hook is gone and `lib/load.sh` exposes everything.
- [x] ~~Any `err`/`warn` before `log_init` writes to a log path whose directory does not exist yet.~~ Resolved 2026-09-22: `LOG_FILE` starts as `/dev/null` and `log_init` opens the real transcript.
- [x] ~~`lib/core.sh` is still ~3770 lines. The confirmation helpers left in `P0-T07` (`lib/confirm.sh`); the next extraction pass (Phase 1) should take the category registry, the report and the TUI out of it.~~ Resolved 2026-09-24: reduced to 169 lines across modular files.
- [x] ~~`mail`, `sim-stale` and `android` are gated as risky by `lib/confirm.sh` while `category_info` still carries its own `safe|moderate|risky` column.~~ Resolved 2026-09-24: `category_info` and `category_risk_facets` aligned with `confirm_class` and verified by golden tests.
- [~] `TEST_JOBS=N ./tests/run` runs files in parallel when GNU parallel is installed (2026-09-27; not exercised here, parallel not installed). The suite takes roughly 3–4 minutes per full run (about 510 tests as of 2026-09-26, each with a fresh fixture and several full CLI invocations). Worth measuring under `P6-T11`; `bats --jobs` needs GNU parallel.
- [x] ~~Benchmark `path_canonicalize`.~~ Measured by `tests/bench`: ~1 ms per call (1,000 calls in 1.06 s). `path_canonicalize` walks each component in pure Bash and forks `readlink` only for real symlinks. It has not been benchmarked against a `~/Library/Caches` with tens of thousands of entries; `P6-T11` should measure it.
- [x] ~~`plan_load` does not JSON-unescape.~~ Fixed 2026-09-27 (`json_unescape_to`; regression test in `tests/plan.bats`). `plan_load` read string values back without JSON-unescaping them, so a plan whose path or evidence contains `"` or `\\` fails its own digest check. Uninstall plans avoid such values (`_uninstall_path_ok`, `_uninstall_evid`); a real fix belongs with a plan schema v2 reader. Its `'}'*|'},'*` case also trips ShellCheck SC2221/SC2222.
- [x] ~~Orphan scan speed.~~ Fixed 2026-09-27: tokens folded by one awk per root, fork-free checks, candidates sized once, pure-Bash `human_kb` (identical output over 3,440 values). Benchmark 13.4 s → 5.2 s. Was: Orphan scan costs ~6 ms per Library entry (about 78 s for 13,000): `normalize_token`, `is_apple_identifier`, and `is_installed_cli_tool` each fork `tr` per entry. Batch the case-folding per root with one `awk`, as `collect_app_evidence` does (`_ev_list_root`).
- [x] ~~Name resolution speed.~~ Bundle-id targets resolve through a Spotlight query (2026-09-27), verified against Info.plist, falling back to the inventory. `app inspect` end to end is still ~7.7 s with 107 apps: the sibling index is needed for conflict detection. Was: Name resolution in `app inspect`/`app uninstall` scales with installed apps (~7 s for 100): `inventory_scan_apps resolve` canonicalises and reads each Info.plist. Consider a Spotlight-first lookup by bundle id.
- [x] ~~`mimi history` command.~~ Added 2026-09-27 (`schemas/history-v1.json`). Was: `mimi history` command: `~/.config/mimi/history.jsonl` exists (uninstalls, Homebrew hand-offs) but there is no command to read it.
- [ ] `--report`/top-offenders code reads `~/Desktop`, `~/Documents` and friends without going through `path_authorize`. That is correct today because it never mutates, but the read paths should be routed through the API once plan/apply exists so that "what was inspected" is auditable.

## 11. Next-session handoff template

Copy and fill this section at the end of an implementation session:

```text
Task:
Status:
Changed files:
Tests run:
Test result:
Safety checks:
Decisions made:
New risks/discoveries:
Blocker, if any:
Exact next step:
```
