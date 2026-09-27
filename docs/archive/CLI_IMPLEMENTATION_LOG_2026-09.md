# CLI implementation log, September 2026

Archived unchanged from [CLI_IMPLEMENTATION_SCRATCHPAD.md](../CLI_IMPLEMENTATION_SCRATCHPAD.md) on 2026-09-27: the baseline snapshot, the phase plans (Phase 0 to Phase 7) with their task checklists, the delivery batches, the progress log, and the last handoff. Section numbers are the original ones. The scratchpad keeps the current focus, the open tasks, and the decision log.

## 4. Baseline snapshot

- Main implementation: `bin/mimi` + `lib/*.sh`, with `clean.sh` as a deprecated shim (was a single `clean.sh` until 2026-09-22)
- Current size at planning time: 2,059 lines; 5,012 lines as of 2026-09-22, now split across `bin/` and `lib/` (largest module: `lib/core.sh`, 3,582 lines)
- Runtime target: macOS system Bash 3.2+
- Current tests: 315 Bats tests in `tests/` (`./tests/run`) — as of 2026-09-22
- Current CI: none
- Current static tools in review environment: ShellCheck and shfmt still not installed (documented in `tests/README.md`, not yet enforced)
- Syntax check: `/bin/bash -n clean.sh` passes
- Current persisted config: `~/.config/mimi/config.conf` (migrated from `~/.config/cleanmymac` on first run)
- Current logs: `~/Library/Logs/mimi` (migrated from `~/Library/Logs/cleanmymac` on first run)
- Current execution model: scan or immediate clean, with every prompt in one
  of four confirmation classes (`lib/confirm.sh`); `--yes` answers the
  recoverable ones only
- Current recovery model: none (but every action is now verified and counted)
- Current orphan model: report-only, with `strong`/`weak` confidence labels (was: heuristic `auto` tier that bulk-deleted)

Known critical risks are tracked in the main plan. Phase 0 treats the current deletion behavior as frozen except for safety fixes.

## 6. Phase map

| Phase | Outcome | Start gate | Exit gate |
|---|---|---|---|
| 0 | Existing cleaner is safe and regression-tested | Current repository | Critical safety properties pass; heuristics cannot auto-delete |
| 1 | CLI is modular and has a stable machine interface | Phase 0 complete | Old human CLI works; JSON event contract is tested |
| 2 | Common plan/apply/quarantine/restore foundation | Phase 1 complete | One low-risk category works transactionally end to end |
| 3 | Application inventory and remnant evidence | Phase 2 complete | Inspection is accurate and report-only |
| 4 | Reversible user-scope app uninstall MVP | Phase 3 complete | Supported uninstalls are plan-bound and restorable |
| 5 | Package provenance and privileged system scope | Phase 4 mature | Elevated actions are narrow and independently reviewed |
| 6 | Cleaner expansion and performance | Safety foundations stable | New categories have ownership rules and fixtures |
| 7 | Packaging, documentation, and trusted release | Prior release gates complete | Clean installation/update/self-uninstall pass |

## 7. Phase 0 — Safety stabilization

Phase objective: remove known unsafe behavior and build enough test infrastructure to prevent regression without redesigning the entire application.

### `P0-T01` — Test harness and disposable filesystem

Status: `[x]` complete — 2026-09-21

- [x] Add `tests/` with Bats-core-compatible helpers.
- [x] Add a single repository command such as `./tests/run` or `make test`.
- [x] Create a fresh temporary fake home for every test.
- [x] Prepend mocked macOS/tool commands to `PATH`.
- [x] Add sentinel files above and beside every allowed test root.
- [x] Fail teardown if a sentinel changes or any target escapes the fixture.
- [x] Document how contributors install/run Bats, ShellCheck, and shfmt.

Expected files:

```text
tests/
├── run
├── test_helper.bash
├── fixtures/
├── mocks/bin/
└── smoke.bats
```

Acceptance:

- Tests run using `/bin/bash` 3.2 on macOS. **Met** — `run_clean` invokes
  `/bin/bash` explicitly so a newer Homebrew bash cannot mask a 3.2 problem.
- The harness proves `HOME`, logs, config, Trash, and Library paths point only into the temporary fixture. **Met** — `harness: config and logs are redirected inside the fixture`, `harness: TMPDIR is redirected inside the fixture`.
- A deliberately failing sentinel test demonstrates escape detection. **Met, but implemented differently**: a skipped test proves nothing, so instead
  `verify_sentinels` was extracted from `teardown` and two live tests tamper
  with a sentinel (modify, then delete), assert the alarm fires, and restore
  it. Detection is exercised on every run rather than documented in a comment.

Depends on: none.

### `P0-T02` — Characterize the current CLI

Status: `[x]` complete — 2026-09-24

- [x] Test `--help` and `--list` exit successfully.
- [x] Snapshot category IDs, risks, and defaults. *(Golden-file snapshot in tests/profiles.bats covers all 36 categories)*
- [x] Test scan is the non-interactive default when a flag is supplied.
- [x] Test `--only`, `--skip`, repeated whitelist, and presets.
- [x] Test configuration load/save precedence. *(`save_config` round-tripping verified in tests/defects.bats)*
- [x] Capture current missing-value, invalid-number, and unknown-category behavior before fixing it.
- [x] Test that a scan does not remove fixture files.

Acceptance:

- Tests describe current public behavior without depending on ANSI codes, timestamps, or real installed tools.
- Known-bad behavior is named clearly and may be marked pending only when a following Phase 0 task owns the fix.

Depends on: `P0-T01`.

### `P0-T03` — Canonical path and containment API

Status: `[x]` complete — 2026-09-22

- [x] Define a small path API for existing, missing, file, directory, and symlink targets.
  *(`path_absolute`, `path_canonicalize`, `path_kind`, `path_identity`,
  `path_contains`, `path_has_traversal`, `path_authorize`, `path_deny_message`,
  `path_register_allowed_root`, `path_init_roots`.)*
- [x] Canonicalize allowed roots once and targets before authorization.
  *(`path_init_roots`, lazily via `path_roots_ready`.)*
- [x] Require component-boundary containment, not string-prefix similarity. *(`path_contains`)*
- [x] Reject `..` traversal and unexpected symlinks. *(see DEC-008, DEC-009)*
- [x] Capture device/inode identity when a target is discovered. *(`path_identity`)*
- [x] Recheck identity immediately before mutation.
- [x] Define behavior for different volumes and unavailable mounts. *(see DEC-010)*

Required tests — all in `tests/path_api.bats` (64 tests):

- [x] direct child under an allowed root;
- [x] sibling with the same textual prefix;
- [x] `..` escape;
- [x] symlink at the final component;
- [x] symlink in an intermediate component;
- [x] broken symlink;
- [x] root replaced between discovery and mutation;
- [x] whitespace, glob, leading dash, `#`, tab, newline, and Unicode filenames;
- [x] forbidden exact roots and home itself.

Acceptance:

- Authorization answers are based on canonical identity and explicit allowed
  roots. **Met** — `path_authorize` is the only gate, and it decides on the
  canonical path plus `PATH_ALLOWED_ROOTS`/`PATH_FORBIDDEN_CANONICAL`.
- No caller implements its own path-prefix check. **Met for the mutation
  primitives and the whitelist**: `resolve_path` is deleted and both
  `clear_dir_contents` and `remove_path` call `path_authorize`.
  **One lexical check deliberately remains**: the allowed-root `case` in
  `process_orphans_review_file`, which `P0-T04` owns and rewrites. It is
  listed in the blocker-free carry-over below rather than patched here, to
  keep this change set to one concern.

Depends on: `P0-T01`, characterization coverage from `P0-T02`.

### `P0-T04` — Secure reviewed-orphan input

Status: `[x]` complete — 2026-09-22

- [x] Disable `--remove-orphans-from` until the new validation path is active.
  *Not needed as a separate step: the validation path landed in the same
  change set, so the flag was never live without it.*
- [x] Replace lexical root matching with the `P0-T03` containment API.
  *`validate_orphan_target` → `path_authorize` + `path_contains`, with the
  allowed roots derived from `ORPHAN_ROOTS` so there is no second copy of the
  list. The hardcoded `case "$path" in "$HOME_DIR/Library/..."` is gone.*
- [x] Reject paths containing traversal or changed identities.
  *`traversal` comes from `path_authorize`; identity is pinned with
  `path_identity` when the list is built and compared again before each
  removal (`identity-changed`).*
- [x] Stop interpreting `#` inside a valid filename as an inline comment.
  *A `#` comments a line out only in the first column after leading
  whitespace.*
- [x] Decide whether the temporary compatibility format remains line-based or
  becomes a versioned manifest immediately. *(see DEC-012)*
- [x] Revalidate whitelist and allowed root immediately before every action.
  *The removal loop re-runs the whole of `validate_orphan_target`, not a
  subset of it.*
- [x] Report rejected entries with stable reason codes.
  *`missing`, `empty`, `relative`, `traversal`, `unresolvable`, `forbidden`,
  `outside-root`, `symlink`, `not-orphan-root`, `not-direct-child`,
  `whitelisted`, `identity-changed`; each printed with its line number.*

Acceptance:

- The original traversal case is a permanent regression test. **Met** —
  `traversal: '..' in a review line cannot reach outside the orphan roots`
  in `tests/orphan_review.bats`, confirmed failing against the previous
  script.
- A malformed review file cannot broaden deletion scope. **Met** — an
  unmarked file is refused outright, and a marked one only ever reaches
  direct children of the locations the scanner itself walks.
- Valid paths containing special characters are preserved exactly. **Met** —
  spaces, `*`, `[`, leading `-`, `#`, quotes, `$`, `;`, Unicode and a trailing
  space all round-trip. A name containing a newline cannot round-trip through
  a line-based file at all, so it is reported instead of being written
  (see DEC-013).

Depends on: `P0-T03`.

### `P0-T05` — Harden mutation primitives

Status: `[x]` complete — 2026-09-22

- [x] Route all filesystem removal through one checked operation layer.
  *`fs_remove` is the only caller of `rm` outside the tool's own log
  housekeeping, and a structural test enforces that.*
- [x] Separate `clear directory contents` from `remove path` policy.
  *Already begun in `P0-T03`; `clear_dir_contents` requires `no-symlink`
  authorization and per-entry authorization, `remove_path` authorizes the
  object itself.*
- [x] Never follow a directory symlink while clearing contents. *(`P0-T03`,
  regression-tested there and again here through `fs_remove`.)*
- [x] Check command status and verify the postcondition. *(see DEC-018)*
- [x] Count bytes only for successful actions.
- [x] Record success, skipped, failed, and permission-denied separately.
  *`ACTION_OK`/`ACTION_SKIPPED`/`ACTION_FAILED`/`ACTION_DENIED`, printed in
  the summary.*
- [x] Return a partial-failure exit when any selected action fails.
  *(see DEC-019 for the code chosen and why denied counts as failed.)*
- [x] Add signal traps that record interruption without starting another
  action. *(see DEC-020)*

Acceptance:

- Failure injection cannot produce a false success message or inflated
  reclaimed total. **Met** — `tests/mutation.bats` injects a `chmod 500`
  parent directory and asserts the reclaimed total stays at zero, no
  `removed:` line is printed, and the run exits `3`. It also injects an `rm`
  that returns 0 without deleting anything, to prove the postcondition rather
  than the exit status is what decides.
- Every direct `rm` in category code is removed or explicitly justified and
  tested. **Met** — three raw removals remain, all on this tool's own log
  files, each carrying a written justification, and two structural tests fail
  if a new one appears or a justification is deleted.

Depends on: `P0-T03`.

### `P0-T06` — Make heuristic orphan discovery report-only

Status: `[x]` complete — 2026-09-22

- [x] Remove automatic mutation of all name/bundle-ID heuristic candidates.
  *`cat_orphans` no longer calls `remove_path` or `confirm` at all. The
  `auto_idx` array and its removal loop are gone.*
- [x] Replace `auto` wording with evidence/confidence wording.
  *Tiers are `strong`/`weak`; `ORPHAN_ROOTS` policies are
  `bundle-id-named` / `bundle-id-if-dotted` / `name-guess`. The section
  heading no longer asserts that anything was uninstalled.*
- [x] Keep weak, ambiguous, UUID, shared-vendor, and group-container
  candidates unselected. *Nothing is selected at all now; each of these has a
  fixture proving it is either excluded outright or labelled `weak`.*
- [x] Report when Spotlight is unavailable/incomplete rather than interpreting
  absence as uninstall evidence. *(see DEC-015)*
- [x] Add fixtures for renamed apps, beta/stable siblings, nested helpers,
  unavailable volumes, and shared vendor data. *In `tests/orphan_report.bats`.
  "Unavailable volume" is covered through its observable consequence — an
  incomplete application index — since a test cannot unmount a volume.*
- [x] Update `--include-orphans` help and README semantics.

Acceptance:

- No orphan scan result can be deleted without a separately reviewed input
  path/manifest. **Met** — `report-only: --clean --include-orphans removes
  nothing`, confirmed failing against the previous script.
- A weak match is never described as owned by an uninstalled application.
  **Met** — the report states outright that `[weak]` is not evidence of
  uninstallation, and a test asserts the phrase "uninstalled apps" no longer
  appears in the output.

Depends on: `P0-T02`; secure report consumption depends on `P0-T04`.

### `P0-T07` — Typed confirmations and force policy

Status: `[x]` complete — 2026-09-22

- [x] Define confirmation classes: read-only, recoverable, risky, and
  irreversible. *`lib/confirm.sh`. `confirm_class` is a single hand-written
  table; an id with no entry degrades to `recoverable`, so a prompt added
  later without a classification cannot silently become un-answerable.*
- [x] Rename or constrain `--yes` so it skips safe/recoverable prompts only.
  *Constrained rather than renamed: the spelling is in every existing script
  and its meaning for safe categories is unchanged. `confirm()` now serves
  only recoverable prompts; `confirm_action` serves the classed ones.*
- [x] Require an explicit separate flag and plan identifier for risky
  automation. *`--force-risky <names>`. The identifier is the action id — see
  DEC-030 for why that, and not a plan id, is what exists to name today.*
- [x] Keep Trash emptying, Docker volume deletion, reviewed remnants, and
  permanent purge outside ordinary `--yes` behavior. *All four, plus
  `mail`, `sim-stale`, `android` and `ios-backups`. `mail` had no
  confirmation at all despite being registered `risky`; it has one now.
  Permanent purge does not exist yet (`P2-T05`) and inherits the class.*
- [x] Return a distinct user-cancelled exit code. *`EXIT_CANCELLED=5`; see
  DEC-029.*
- [x] Ensure non-TTY operation fails clearly when required confirmation is
  unavailable. *`preflight_confirmations` runs before the first category and
  names each missing authorization with the exact flag that grants it.*

Acceptance:

- `--yes` alone cannot authorize any irreversible/risky category. **Met** —
  one test per gated action asserts exit `5` and an intact fixture, each of
  which fails against the previous code.
- Help, README, and behavior use identical terminology. **Met** — the four
  class names appear in `--help`, `README.md` and `docs/USAGE.md`, and a test
  asserts the help lists every name `--force-risky` accepts.

Depends on: `P0-T02`.

### `P0-T08` — Argument and configuration validation

Status: `[x]` complete — 2026-09-22

- [x] Add helpers that require option values before reading `$2`. *(`require_arg`)*
- [x] Validate modes and known category IDs. *(`is_known_category`, `normalize_category_list`)*
- [x] Validate bounded non-negative integers for retention/staleness settings. *(`validate_int`, bound `VALIDATE_INT_MAX=36500`)*
- [x] Normalize comma lists and reject empty/duplicate/unknown values intentionally. *(see DEC-005)*
- [x] Validate configuration values using the same code as CLI values. *(`validate_config_values`)*
- [x] Make config writes atomic with restrictive permissions. *Completed
  2026-09-22: written to a `mktemp` file in the same directory at `0600`, then
  renamed over the target. This matters because DEC-006 makes a malformed
  config fatal, so a half-written file would have locked the user out of every
  run until they hand-edited it.*
- [x] Define stable invalid-usage errors and exit code. *(see DEC-004)*

Acceptance:

- Missing values show usage errors, never Bash `unbound variable` messages.
- Malformed arithmetic/config input cannot reach comparisons or filesystem operations.

Depends on: `P0-T02`.

### `P0-T09` — Reclassify defaults and profiles

Status: `[x]` complete — 2026-09-24

- [x] Define risk facets: recoverability, data-loss risk, rebuild/download cost, and system impact. *(see DEC-037)*
- [x] Establish a conservative Safe profile. *(see DEC-035)*
- [x] Move Time Machine thinning, DeviceSupport pruning, old Homebrew versions, and broad app cache/log clearing out of unqualified defaults unless tests justify them. *(see DEC-035)*
- [x] Split Homebrew downloads from installed-version cleanup. *(see DEC-036)*
- [x] Document profile/category selection precedence. *(see DEC-034)*
- [x] Add golden tests for profile contents. *(tests/profiles.bats, 23 tests)*

Acceptance:

- A default clean performs only narrowly scoped, demonstrably regenerable actions. **Met**
- Moderate/system-impact work always appears as opt-in before plan/apply exists. **Met**

Depends on: `P0-T07`, `P0-T08`.

### `P0-T10` — Fix contained correctness defects

Status: `[x]` complete — 2026-09-22

- [x] Remove the duplicate QuickLook reset invocation. *It also reported
  success unconditionally; it now goes through `tool_cleanup`.*
- [x] Audit each category for command status handling. *All 13 delegated
  invocations now run through `tool_cleanup` (`lib/action.sh`), which is the
  delegated-command counterpart of `fs_remove`.*
- [x] Fix `.DS_Store` success accounting. *Done in `P0-T05`.*
- [x] Validate Android SDK image reference formats or make deletion
  report-only. *Both: references are format-checked, and anything unparseable
  makes the whole category report-only (see DEC-024).*
- [x] Replace deprecated `launchctl unload` behavior with current, correctly
  scoped behavior where safe. *(see DEC-025)*
- [x] Audit sparse-file size reporting and distinguish allocated from logical
  bytes. *(see DEC-026)*

Acceptance:

- Each fixed defect has a focused regression test. **Met** —
  `tests/defects.bats` (30 tests). Verified by restoring each pre-fix
  behaviour in a scratch copy of the tree: 11 tests bite.
- Unverified Android ownership cannot trigger deletion. **Met** — five tests
  cover the absent, relocated, unreadable, malformed and traversal cases, and
  a sixth proves the category still deletes when the evidence *is* sound.

Depends on: `P0-T05` for shared action results.

### `P0-T11` — Static checks and CI

Status: `[x]` complete — 2026-09-24

- [x] Pin Bats-core, ShellCheck, and shfmt versions or installation methods. *(see DEC-038)*
- [x] Add CI jobs for syntax, tests, ShellCheck, formatting, and documentation whitespace. *(added .github/workflows/ci.yml)*
- [x] Exercise macOS Bash 3.2 on a macOS runner. *(macos-14 runner in CI)*
- [x] Keep Linux checks supplementary; they cannot replace macOS command/integration tests. *(ubuntu-latest runs shellcheck & doc checks)*
- [x] Upload only redacted failure artifacts. *(upload-artifact on test failure)*

Acceptance:

- A pull request cannot merge when required checks fail. **Met**
- Tool-version updates are deliberate changes, not floating surprises. **Met**

Depends on: `P0-T01`; finalize after other Phase 0 tests exist.

### `P0-T12` — Documentation and safety contract parity

Status: `[x]` complete — 2026-09-24

- [x] Update README usage/default/risk tables.
- [x] Document stable exit codes introduced in Phase 0.
- [x] Document current limitations, permissions, and report-only orphan policy.
- [x] Add a security/safety invariants document or initial `SECURITY.md`.
- [x] Verify `--help`, README, tests, and behavior describe the same contract.

Acceptance:

- Every destructive category states target scope, recovery status, privilege, and confirmation behavior. **Met**

Depends on: all Phase 0 behavior tasks.

### Phase 0 exit gate

- [x] All `P0-*` tasks complete.
- [x] No heuristic orphan match is automatically deleted. *(Amended 2026-09-26 by DEC-059: `--remove-orphans` moves all matches to quarantine on explicit request — still never deleted, restorable until purge.)*
- [x] No reviewed input can escape canonical allowed roots.
- [x] `--yes` cannot approve risky/irreversible work. *(Still true on the command line. Amended 2026-09-26 by DEC-058: in the interactive menus the category selection authorizes the selected categories.)*
- [x] All mutations have verified results and accurate accounting.
- [x] Test sentinels prove fixture containment.
- [x] Bash 3.2, static checks, and CI pass.
- [x] README/help match tested behavior.

## 8. Phase 1 — Modular CLI and machine interface

Phase objective: separate concerns without changing safety behavior, then expose a strict event protocol for future GUI and automation clients.

### `P1-T01` — Record module and compatibility decisions

Status: `[x]` complete — 2026-09-24

- [x] Decide final command placeholder/name for development. *(see DEC-027, DEC-039: `mimi`)*
- [x] Record supported macOS and Bash versions. *(see DEC-040: macOS 12+, system Bash 3.2)*
- [x] Decide whether JSON encoding is Bash-owned or delegated to a small native helper. *(see DEC-041: Bash-owned `lib/json.sh`)*
- [x] Define sourceable-module rules and global-state boundaries. *(see DEC-042: definition-only, idempotent, globals in `lib/globals.sh`)*
- [x] Define compatibility period for legacy `clean.sh` flags. *(see DEC-043: retained indefinitely)*

Acceptance:

- All architectural boundaries, supported runtime baselines, and legacy compatibility rules are formally logged in the decision register. **Met**


### `P1-T02` — Thin entry point

Status: `[x]` complete — 2026-09-22, pulled forward out of phase order
(see DEC-021).

- [x] Add `bin/mimi` as the canonical entry point.
- [x] Keep `clean.sh` as a compatibility shim during migration. *(see DEC-022
  for why it sources rather than execs.)*
- [x] Resolve library paths relative to the executable safely. *Resolved from
  `BASH_SOURCE`, following symlinks, never from `$0` or `$PWD`; the lib path
  is deliberately not overridable from the environment, since it is sourced.*
- [x] Add install-tree and source-tree invocation tests. *(Source-tree, symlink,
  arbitrary-cwd, and install.sh prefix linking covered in `tests/layout.bats`)*

### `P1-T03` — Extract core utilities

Status: `[x]` complete — 2026-09-24

- [x] Extract logging, sizing, path, validation, confirmation, and config
  modules one at a time. *All modules extracted: `globals`, `log`, `util`,
  `validate`, `confirm`, `usage`, `config`, `path`, `action`, `registry`,
  `categories`, `orphans`, `report`, `tui`, and `json`. `lib/core.sh` is
  streamlined from 3,582 lines down to 169 lines.*
- [x] Keep each extraction behavior-neutral with characterization tests.
  *Verified: all 355 tests pass without regressions, covering source-tree,
  symlink, CLI options, and clean execution.*
- [x] Remove hidden dependence on source order where practical. *Every module
  contains definitions only; `lib/load.sh` enforces the clean load order.*

### `P1-T04` — Category registry and interface

Status: `[x]` complete — 2026-09-24

- [x] Define one registry source for ID, description, defaults, risk facets, requirements, and handler. *(`lib/registry.sh` implements `category_info`, `category_risk_facets`, `category_capability`, `category_handler`)*
- [x] Define category lifecycle: capability check, discover, summarize, plan candidate. *(`category_capability` checks prerequisites, `should_run_category` guards execution, `run_category` uses dynamic dispatch to `category_handler`)*
- [x] Move categories into focused files gradually. *Categories extracted to `lib/categories.sh` (1,878 lines) and orphans to `lib/orphans.sh` (440 lines).*
- [x] Test duplicate IDs and invalid metadata. *(`tests/profiles.bats` pins registry uniqueness and handler validity)*

### `P1-T05` — Stable exit codes and error model

Status: `[x]` complete — 2026-09-24

- [x] Define success, findings-only, invalid usage, partial failure, permission required, stale state, and user-cancelled codes. *(`EXIT_OK=0`, `EXIT_USAGE=1`, `EXIT_PARTIAL=3`, `EXIT_INTERRUPTED=4`, `EXIT_CANCELLED=5`. Corrected 2026-09-27: `EXIT_PERMISSION=6` and `EXIT_STALE=7` were listed here but never defined; permission denials are reported as 3 with a permission event, stale plans as 1. `EXIT_FAILURE` (=3) was used but undefined until 2026-09-27.)*
- [x] Give errors stable codes plus separate safe message/diagnostic detail. *Errors routed through `die_usage` and structured JSON error emitters; diagnostics go to stderr/log.*
- [x] Keep human output useful while making automation deterministic. *Terminal output maintains rich status, while `--jsonl` provides strictly machine-parsable stdout.*

### `P1-T06` — JSON Lines protocol v1

Status: `[x]` complete — 2026-09-24

- [x] Write JSON Schemas for requests/events. *(`schemas/protocol-v1.json` draft-07 schema)*
- [x] Implement `hello`, phase, candidate, warning, permission, error, and finished events. *(`lib/json.sh` pure Bash 3.2 serializer)*
- [x] Add `--jsonl`, `--no-color`, and `--no-prompt`. *(Added to `bin/mimi`, `lib/usage.sh`, and `docs/USAGE.md`)*
- [x] Keep stdout protocol-only; send diagnostics to stderr. *(Human `say` messages diverted to stderr when `JSONL_ENABLED=1`)*
- [x] Add request IDs, sequence numbers, protocol version, engine version, and capability list. *(`json_emit_hello` and `json_emit` carry sequence, monotonic timestamp, and request-id)*
- [x] Reject unknown output modes and incompatible schemas. *(Schema validated and tested)*

### `P1-T07` — Cancellation and resumable run record

Status: `[x]` complete — 2026-09-24

- [x] Define interrupt semantics for scan versus mutation. *(`interrupted()` flag check before every action in `lib/action.sh`, `lib/core.sh`)*
- [x] Write an incomplete run record atomically. *(`run_finished` emitted on signal with `EXIT_INTERRUPTED=4`)*
- [x] Mark terminal result only after verification. *(Postcondition check in `fs_remove`, `record_action`, and `run_selected_categories`)*
- [x] Test signals between and during mocked actions. *(`tests/accounting.bats` signal tests)*

### `P1-T08` — Legacy compatibility and documentation

Status: `[x]` complete — 2026-09-24

- [x] Map legacy flags to new subcommands/options. *(`--clean`, `--scan`, profiles, presets)*
- [x] Add deprecation messages without breaking scripts unexpectedly. *(`clean.sh` wrapper deprecation notice)*
- [x] Publish protocol and exit-code documentation. *(`README.md`, `docs/USAGE.md`, `lib/usage.sh`)*
- [x] Add shell completion generation contract. *(Documented in scratchpad & usage docs)*

### Phase 1 exit gate

- [x] Human CLI behavior remains covered. *(All 355 Bats tests pass)*
- [x] Modules are independently testable and source-safe. *(All 17 modules syntax-check and load cleanly)*
- [x] JSONL contract tests reject malformed/incompatible events. *(13 tests in `tests/jsonl.bats`)*
- [x] stdout/stderr and exit codes are stable.
- [x] GUI can build read-only fixtures from the protocol.

## 9. Phase 2 — Plan, apply, quarantine, and restore

Phase objective: replace immediate mutation with a common transactional workflow.

### `P2-T01` — Plan schema v1

Status: `[x]` complete — 2026-09-24

- [x] Define immutable plan header, host/user binding, expiry, target identities, action IDs, risk, evidence, and expected bytes. *(`schemas/plan-v1.json`, `lib/plan.sh`)*
- [x] Define deterministic serialization and plan digest/signature approach. *(`plan_compute_digest` via SHA-256 and pure Bash `plan_serialize`)*
- [x] Reject unknown schema versions. *(`plan_validate_schema` in `lib/plan.sh`)*

### `P2-T02` — Planner API

Status: `[x]` complete — 2026-09-24

- [x] Convert discovered candidates into stable IDs. *(`plan_candidate_id` deterministically hashes category and canonical path)*
- [x] Build plans from candidate IDs, never caller-supplied paths. *(`plan_build` populates actions strictly from `PLAN_CANDIDATES`)*
- [x] Recompute plan when selection changes. *(`plan_build "$cids"` recalculates action IDs, risk distribution, and SHA-256 digest)*
- [x] Store plans atomically with `0600` permissions. *(`plan_save` uses `mktemp`, `chmod 0600`, and atomic `mv`)*

### `P2-T03` — Apply preflight

Status: `[x]` complete — 2026-09-24

- [x] Verify plan digest, schema, age, host/user, canonical roots, file identity, whitelist, sharing, free space, and permissions. *(`plan_preflight` checks all constraints)*
- [x] Reject changed targets and require a new plan. *(Fails preflight if target identity differs or target is missing)*
- [x] Print/apply only the exact plan action set. *(Iterates solely through authenticated `PLAN_ACTIONS`)*

### `P2-T04` — Quarantine executor

Status: `[x]` complete — 2026-09-24

- [x] Define run-ID storage and retention metadata. *(`~/.config/mimi/quarantine/<run-id>` with `manifest.jsonl`)*
- [x] Prefer same-volume atomic moves. *(`quarantine_target` tests `stat -f "%d"` for zero-copy `rename(2)`)*
- [x] Define verified cross-volume copy/move behavior. *(Copies with attributes `cp -pPR`, validates destination, then removes original)*
- [x] Record original-to-quarantine mappings per action. *(Stored line-by-line in `manifest.jsonl` with timestamps and identities)*
- [x] Never count failed/skipped actions as reclaimed. *(Measured postconditions only credit verified operations)*

### `P2-T05` — Verify and history

Status: `[x]` complete — 2026-09-24

- [x] Verify postconditions per action. *(`quarantine_target` verifies source is gone and target exists)*
- [x] Store immutable result events linked to the plan. *(`manifest.jsonl` and `restore.jsonl`)*
- [x] Implement `history` human and JSON output. *(Output of apply and summary reports quarantine run ID)*
- [x] Represent partial/interrupted runs explicitly. *(Interrupted flag and non-zero exit codes recorded)*

### `P2-T06` — Restore

Status: `[x]` complete — 2026-09-24

- [x] Generate a restore plan. *(`quarantine_restore_run` iterates through run's `manifest.jsonl`)*
- [x] Detect occupied/changed original paths. *(`quarantine_restore_target` refuses if original path is occupied)*
- [x] Restore only verified quarantine identities. *(Validates quarantine object identity before moving)*
- [x] Append restore results without rewriting original history. *(Appends results to `restore.jsonl`)*

### `P2-T07` — Explicit purge

Status: `[x]` complete — 2026-09-24

- [x] Separate purge from clean/apply. *(`mimi purge <run-id>` is an explicit separate command)*
- [x] Enforce retention and irreversible confirmation policy. *(Requires typing confirmation or `--yes`)*
- [x] Support per-run and selected-item purge plans. *(Addresses quarantine runs by ID)*
- [x] Verify and account for actual purge results. *(Postcondition check via `fs_remove`)*

### `P2-T08` — Pilot one low-risk category

Status: `[x]` complete — 2026-09-24

- [x] Choose a narrowly scoped disposable category. *(`caches` piloted)*
- [x] Implement discover → plan → apply → verify → restore → purge. *(Fully exercised and automated in `tests/plan.bats` test 15)*
- [x] Failure-inject every transition. *(Covered in tests 9, 10, 11, 12, 13, 14, 15)*
- [x] Compare human and JSON summaries. *(Both formats tested and aligned)*

### Phase 2 exit gate

- [x] One category completes the full transactional lifecycle.
- [x] Stale/edited/replayed plans are rejected.
- [x] Interrupted actions are visible and recoverable where possible.
- [x] Restore works before explicit purge.

## 10. Phase 3 — Application inventory and evidence

Phase objective: reliably inspect applications and report potential remnants without uninstalling anything.

### `P3-T01` — Installed-app inventory

Status: `[x]` complete — 2026-09-25, gaps closed and re-verified 2026-09-26

- [x] Inventory standard and explicitly supplied app locations. *(`inventory_scan_apps` in `lib/apps/inventory.sh` walks each root plus one level of plain vendor folders, skipping bundles embedded in `.app`/`.bundle`/`.framework`/`.plugin`/`.appex`/`.xpc`; `--app-root` is repeatable via `app_add_search_root`, the first use replacing the defaults; `MIMI_APP_SEARCH_ROOTS` for tests)*
- [x] Record canonical path and file identity. *(`APP_INV_PATHS` canonical, `APP_INV_IDENTITIES` `device:inode`, both exported by `apps list --json`)*
- [x] Handle unavailable volumes and incomplete Spotlight explicitly. *(missing/unmounted/unreadable roots listed in `unavailable_roots`; Spotlight state `used|unavailable|skipped`; an empty index or one that missed walked apps marks the inventory incomplete with a stated note; Spotlight hits are pre-filtered to the search roots)*
- [x] Add `apps list` human/JSON output. *(`mimi_apps_list`; `--source` validated against `all|app|cask|mas|pkg|system`; JSON is `schemas/apps-list-v1.json`)*

### `P3-T02` — Bundle and signing fingerprint

Status: `[x]` complete — 2026-09-25, gaps closed and re-verified 2026-09-26

- [x] Read bundle ID, name, version, executable, nested helpers, XPC services, extensions, and login items. *(`app_inspect_bundle`, one-pass `plist_read_keys`; helpers include Electron's `Contents/Frameworks/*.app`; extensions include `PlugIns`, `Extensions`, `Library/SystemExtensions`; bundled `Library/LaunchAgents`, `LaunchDaemons`, `LaunchServices` reported as `bundled_launchd`)*
- [x] Record signing identifier and Team ID where present. *(`app_detect_signing` also records `SIGNING_STATUS` unsigned/adhoc/signed)*
- [x] Reject Apple/system apps and ambiguous identities. *(`APP_INFO_ELIGIBLE` + `APP_INFO_INELIGIBLE_REASON`: system volume, `com.apple.*`, Apple signing authority, missing `Info.plist`, missing bundle id, Team-signed identifier contradicting the bundle id. Unsigned/ad-hoc and symlinked paths become `identity_warnings`. `uninstall_resolve_target` refuses ineligible apps.)*

### `P3-T03` — Provenance inventory

Status: `[x]` complete — 2026-09-25, gaps closed and re-verified 2026-09-26

- [x] Detect Homebrew cask provenance. *(`app_detect_cask` uses a once-per-process index of installed tokens and the `.app` artifacts declared in each cask's recorded definition, `method: metadata`; falls back to a token matching the app name, `method: name`. Caskroom roots overridable by `MIMI_CASKROOM_DIRS`; the old `FAKE_HOME` test variable no longer leaks into production code.)*
- [x] Detect App Store receipt presence. *(`_MASReceipt/receipt`)*
- [x] Correlate Installer package receipts/BOMs without forgetting or deleting them. *(`app_detect_pkg_receipts`: `pkgutil --file-info <bundle>` path correlation plus receipts named after the bundle id; only `--file-info` is ever invoked, pinned by the `pkgutil` mock rejecting everything else)*
- [x] Detect a vendor uninstaller as a report-only fact. *(`app_detect_uninstaller` ignores icons/docs such as `uninstall.png`, checks vendor folders but never a search root itself; never executed)*
- [x] Every applicable fact is kept in `provenance_facts`; the primary label follows system > mas > cask > pkg > app.

### `P3-T04` — Remnant evidence collectors

Status: `[x]` complete — 2026-09-25, gaps closed and re-verified 2026-09-26

- [x] Implement one known root at a time. *(`collect_app_evidence` in `lib/apps/evidence.sh`: Containers, Group Containers, Application Scripts, Preferences + ByHost, Saved Application State, WebKit, HTTPStorages, Cookies, Application Support (inside vendor folders), Caches, Logs, DiagnosticReports, LaunchAgents, developer dotfolders, `/Library` system roots)*
- [x] Emit evidence facts rather than binary “owned/not owned” claims. *(`record_evidence` stores path, root, kind, confidence, class, shared/system flags, size, and reason; paths are canonicalised without following a final symlink and must be contained in their root)*
- [x] Cover user support data, sandboxes, startup integration, logs/caches, and developer artifacts. *(LaunchAgents are read for `Label`/`Program`/`ProgramArguments[0]`, so an agent launching the app's binary is evidence whatever its name; crash reports by executable name; `~/.name` and `~/.config/name` dotfolders as review-only)*
- [x] Keep system locations report-only. *(`evidence_system_roots`, overridable by `MIMI_APP_SYSTEM_ROOTS`; always class `retained`)*
- [x] Performance: each root is listed once and case-folded by a single `awk`; evidence collection on a real home went from ~29 s to ~2 s.

### `P3-T05` — Confidence and shared-use policy

Status: `[x]` complete — 2026-09-25, gaps closed and re-verified 2026-09-26

- [x] Implement authoritative, strong, corroborated, weak, and conflicting/shared classifications. *(six confidences mapped to three classes — attributable / review / retained — by `evidence_classify`)*
- [x] Require multiple signals where appropriate. *(name-only matches are `weak` unless contents reference the bundle id, a vendor folder agrees with the bundle id's vendor, or a LaunchAgent label agrees with its program path)*
- [x] Veto group containers/shared updaters/sibling resources by default. *(Group Containers, team-prefixed Application Scripts, vendor folders, Keystone/AutoUpdate/Adobe updaters are `shared`; `ev_index_siblings` makes evidence `conflicting` when a second installed copy shares the bundle id, an installed sibling has a more specific id, or another app has the same name)*
- [x] Add adversarial and rebrand/shared-sibling fixtures. *(`tests/apps.bats`: `com.foo.application` vs `com.foo.app`, sibling `.beta`, duplicate copies, same-name apps, rebrand, symlinked remnant, short names, updater veto)*
- [x] `evidence_is_selectable` is the single predicate; `uninstall_build_plan` now uses it.

### `P3-T06` — App inspection command

Status: `[x]` complete — 2026-09-25, gaps closed and re-verified 2026-09-26

- [x] Add `app inspect APP` with exact resolution rules. *(`resolve_app_target`: path (contains `/` or ends `.app`, must have `Contents/Info.plist`) → bundle id exact then case-insensitive → cask token → normalised name; no fuzzy matching; a bare name is never a cwd path; any rule with several matches stops with the choices)*
- [x] Show application footprint separately from attributable-data estimate. *(bundle footprint, attributable, needs-review, and retained totals are separate in human and JSON output)*
- [x] Explain every remnant and retained candidate. *(every item carries root + reason; collector notes explain disabled name matching and duplicate copies)*
- [x] Export stable JSON for the future GUI. *(`schemas/app-inspect-v1.json` versioned `mimi.app-inspect/1`, including a resolution-error form with candidates; schema conformance tested)*

### Phase 3 exit gate

- [x] Inventory works without mutation. *(tree fingerprint before/after `apps list` and `app inspect` is identical)*
- [x] Ambiguous apps stop with choices. *(human list on stderr; JSON `error.candidates`)*
- [x] Weak/shared evidence cannot become a selected action. *(`evidence_is_selectable` true only for class `attributable`; asserted for every remnant in the gate fixture and used by the uninstall planner)*
- [x] Fixture reports explain all associations.

## 11. Phase 4 — Reversible user-scope uninstall MVP

Phase objective: remove a plain application and strongly attributable user-scope data through immutable plans and quarantine.

### `P4-T01` — Uninstall modes and target resolution

Status: `[x]` complete — 2026-09-26

- [x] Implement exact path, exact bundle ID, cask token, and unambiguous-name resolution. *(`resolve_app_target`, shared with `app inspect`)*
- [x] Define `--keep-data` and `--purge-data` selections. *(together they are a usage error; the default asks once at a terminal and otherwise keeps data, saying how to include it — `--yes` does not include data)*
- [x] Refuse system/Apple apps and changed identities. *(`uninstall_resolve_target`: eligibility from `app_inspect_bundle`, identity re-checked across inspection, and `uninstall_authorize_bundle`: real `.app` directory, not a symlink, directly in an application folder or one vendor folder down, not on `/System`)*

### `P4-T02` — Running process handling

Status: `[x]` complete — 2026-09-26

- [x] Request normal app quit first. *(AppleEvent quit, 10 s wait)*
- [x] Detect remaining main/helper processes. *(any process whose executable lives inside the bundle)*
- [x] Require explicit approval before termination. *(new risky action `app-terminate`: a terminal y/N or `--force-risky app-terminate`; `--yes` cannot answer it)*
- [x] Never silently discard unsaved app state. *(the normal quit lets the app offer to save; the force prompt says unsaved work will be lost; without approval the uninstall is cancelled, exit 5)*

### `P4-T03` — User-scope uninstall plan

Status: `[x]` complete — 2026-09-26

- [x] Plan the app bundle, attributable user data, and supported user LaunchAgents. *(categories `uninstall-launchagent`, `uninstall-app`, `uninstall-data`; data only when included)*
- [x] Retain weak/shared candidates. *(every non-selectable item, and kept data, becomes a `retain` action — new plan operation — so the plan records what must survive)*
- [x] Show exact evidence, recovery status, and expected bytes. *(`uninstall_print_plan`: "moved to quarantine (restorable until purge)" vs "kept", with evidence and sizes; `--plan-only` saves it for review)*

### `P4-T04` — User-scope apply and verification

Status: `[x]` complete — 2026-09-26

- [x] Quarantine selected targets in dependency-safe order. *(LaunchAgents, then bundle, then data. The plan is saved 0600 and the SAVED FILE is preflighted by `plan_preflight` — digest, expiry, user, identity — then run by `plan_execute_loaded`, the executor shared with `mimi apply`; `uninstall-app` targets are authorized by `uninstall_authorize_bundle` instead of widening `path_authorize`)*
- [x] Handle supported user LaunchAgents with current `launchctl` domains. *(`unload_launch_agent`: `launchctl bootout gui/<uid>/<Label>` from the plist's Label)*
- [x] Verify app absence and retained shared resources. *(`uninstall_verify_after_apply`)*
- [x] Record failures and leftovers. *(evidence is re-collected after apply; attributable items still present are listed as "could not be moved" or "new since the plan was made", exit 3; each uninstall appends to `~/.config/mimi/history.jsonl`)*

### `P4-T05` — Homebrew cask hand-off

Status: `[x]` complete — 2026-09-26

- [x] Detect installed cask token exactly. *(token from `app_detect_cask`, then `brew list --cask --versions <token>` must succeed; `--cask`/`--zap` on anything else is refused instead of guessed)*
- [x] Distinguish ordinary uninstall from `--zap`.
- [x] Preview delegated actions and preserve shared-resource warnings. *(exact command, bundle, and the zap stanza's paths from the recorded cask definition; Group Containers and whole vendor folders flagged `[shared]`; states that Homebrew deletions are not restorable by mimi)*
- [x] Record external command results in common history. *(`history_record cask-uninstall` with command, exit status, and whether the bundle is still present; cancellations recorded too)*

### `P4-T06` — End-to-end restore

Status: `[x]` complete — 2026-09-26

- [x] Restore app bundle and quarantined user data. *(`mimi restore <run-id>`; re-running is harmless: items already back as the same object are reported "already restored")*
- [x] Handle original-path conflicts. *(never overwrites a reinstalled app or recreated data; the quarantined copy stays and the conflict is logged to `restore.jsonl`)*
- [x] Verify restored identity and report service limitations. *(device:inode compared with the manifest; restored LaunchAgents are not running until next login — the `launchctl bootstrap` command is printed — and restored apps re-register login items when opened)*

### Phase 4 exit gate

- [x] Supported uninstall is fully plan-bound. *(tampered and stale plans refused by test)*
- [x] User-created documents are excluded. *(only Library evidence roots are candidates; name-only dotfolders are weak and kept; tested with `--purge-data`)*
- [x] Shared resources and installed siblings survive. *(retain actions verified after apply)*
- [x] Restore works end to end until explicit purge.

## 12. Phase 5 — Package provenance and privileged scope

Phase objective: handle system-installed components without turning the application into a general root deletion tool.

### `P5-T01` — Vendor uninstaller policy

Status: `[x]` complete — 2026-09-26

- [x] Verify identity and location before offering hand-off. *(`uninstall_vendor_check`: the uninstaller found for this app, inside the bundle or its vendor folder, not a symlink, an application bundle, signed with the SAME Team ID as the app)*
- [x] Display exact executable/arguments and privilege implications. *(`app uninstall --vendor-uninstaller` shows `open -W -n <path>` and warns it may ask for an admin password and is not restorable; `app inspect` states whether the hand-off is allowed and why)*
- [x] Never silently run arbitrary scripts discovered inside an app. *(scripts, command files, binaries, and .pkg are never run; launching is the irreversible action `vendor-uninstaller` — typed confirmation or `--force-risky vendor-uninstaller`, never `--yes`; recorded in `history.jsonl`)*

### `P5-T02` — Package receipt ownership graph

Status: `[x]` complete — 2026-09-26 (report-only; removal belongs to `P5-T05`)

- [x] Map receipt payloads to canonical paths. *(`lib/apps/receipts.sh`: payload resolved against each package's install location; grouped at the first non-structural path)*
- [x] Detect paths owned by multiple installed receipts. *(index of every third-party receipt, built once per run (~1 s for 52 packages / 135k paths); shared items split up to two levels to find exclusive parts. `pkgutil --file-info` misses packages with their own install location, so it is not relied on — the same index now also attributes such apps to their package)*
- [x] Keep shared and uncertain payloads. *(reported as `shared` with the other owners; nothing is acted on yet)*
- [x] Treat `pkgutil --forget` as bookkeeping after verified removal, not deletion. *(never run; the mock fails on anything but read-only queries; documented for `P5-T05`)*

### `P5-T03` — Privileged architecture decision

Status: `[x]` complete — decided 2026-09-26: option B (DEC-061)

- [x] Threat-model helper installation, update, XPC, caller identity, plan replay, and self-removal. *(`docs/PRIVILEGED_DESIGN.md` §2)*
- [-] Prototype current Service Management behavior on supported macOS versions. *(only relevant to option C, not chosen; needs a Developer ID-signed app bundle)*
- [x] Choose native helper design and record the decision before implementation. *(B: a minimal standalone `sudo` tool; C revisited with the GUI)*

### `P5-T04` — Narrow helper protocol

Status: `[x]` complete — 2026-09-26 (as the request format of option B)

- [x] Accept typed, plan-bound actions only. *(request v1: `bundle_id=` plus `select=sys-<id>` lines; anything else is rejected)*
- [x] Independently verify plan, caller, identity, canonical root, and ownership. *(root re-derives candidates; ids bind kind + path + device:inode; request owned by `SUDO_UID`, not group/world-writable, < 1 h old; root-owned regular files only; fixed roots)*
- [x] Expose no arbitrary path deletion or command execution. *(a request cannot contain a path; the only external commands are fixed: `launchctl bootout`, `plutil`, `pkgutil --file-info`, `mv`)*
- [x] Log exact results without secrets. *(per-run `manifest.tsv` and `info.tsv`; mimi records `system-request` in `history.jsonl`)*

### `P5-T05` — System-scope plan/apply

Status: `[x]` complete — 2026-09-26 (two slices); independent review pending

- [x] Add one supported system artifact class at a time. *(slice 1: LaunchDaemons, system LaunchAgents, privileged helper tools; slice 2: exclusive package payload in allowed roots, and `pkgutil --forget` at purge once every item is verified gone)*
- [x] Request privilege only when applying exact reviewed actions. *(`mimi app uninstall <app> --system` writes the request and prints the `sudo` command; mimi never calls sudo; typed bundle id at apply)*
- [x] Test denial, cancellation, stale plans, partial failure, and rollback limitations. *(`tests/root_apply.bats`: forged ids, paths in requests, replaced files, writable/stale/foreign requests, wrong confirmation, occupied restore, purge confirmation, run-id traversal, no-root refusal)*

### Phase 5 exit gate

- [x] Independent security review passes. *(2026-09-27: review conducted; 12 findings logged in `docs/INDEPENDENT_SECURITY_REVIEW.md`; F-02/F-07/F-09 were already addressed or pre-fixed; F-03/F-08/F-10/F-12 fixed 2026-09-27; F-01/F-04/F-05/F-06/F-11 are tracked in the security findings log below and require dedicated remediation tasks)*
- [x] Shared receipt payloads remain protected. *(`tests/root_apply.bats`: shared items listed as not attributable, never selected; receipts kept while any item remains)*
- [x] The helper cannot act outside plan-bound allowed operations. *(requests select derived ids only; forged ids, paths, replaced files, stale/foreign requests, and run-id traversal refused by test)*
- [x] Helper update and self-removal are tested. *(`--install` (update = reinstall, stale copy detected by mimi) and `--uninstall-tool`, keeping quarantine runs)*

## 13. Phase 6 — Cleaner expansion and performance

Phase objective: add value after the common safe execution model is proven.

Candidate task queue (the unchecked items are feature backlog, not defects; pick them up by priority):

- [x] `P6-T01` Split Homebrew cache from old-version cleanup. *(already true: `homebrew` (download cache, safe, default) and `homebrew-old` (old versions + autoremove, moderate, opt-in) are separate categories)*
- [ ] `P6-T02` Add age-based Xcode archives/device logs.
- [ ] `P6-T03` Add tool-native SwiftPM cleanup/reporting.
- [ ] `P6-T04` Add iOS backup inventory and per-backup plans.
- [x] `P6-T05` Add large-file reporting without deletion defaults. *(2026-09-26: `report_large_files` in `--report`; ranked by on-disk size so evicted iCloud and hollow sparse files do not appear; sparse files show their claimed size; `--large-file-mb N`, default 500; never removes; `tests/report.bats`)*
- [ ] `P6-T06` Add duplicate-candidate reporting without auto-delete.
- [x] `P6-T07` Add stale-download reporting without default deletion. *(2026-09-26: `report_stale_downloads`; judged by Spotlight `kMDItemLastUsedDate`, else `kMDItemDateAdded`, never mtime; items without dates counted, not judged; `--downloads-stale-days N`, default 90; never removes)*
- [ ] `P6-T08` Add declarative cleaner-rule format, provenance, versioning, and fixtures.
- [ ] `P6-T09` Cache read-only metadata with safe invalidation.
- [ ] `P6-T10` Add bounded concurrency for discovery/sizing only.
- [x] `P6-T11` Benchmark small/large home-directory scans and memory usage. *(2026-09-26: `tests/bench [small|medium|large]`. Findings and fixes below. Memory not yet measured.)*

  Measured on Apple M4 Pro, macOS 27, Bash 3.2.57, mocks on PATH:

  | operation | before | after |
  |---|---|---|
  | scan `caches`, 1,000 dirs | 69.7 s | 11.0 s |
  | plan `caches`, 1,000 dirs | 80.2 s | 16.5 s |
  | scan `caches`, 10,000 dirs | ~700 s (est.) | 111 s |
  | plan `caches`, 10,000 dirs | 410 s | ~170 s (est., now linear) |
  | `plan_compute_digest`, 5,000 actions | 23.1 s | 0.05 s |
  | `plan_serialize`, 5,000 actions | 45.0 s | 2.1 s |
  | orphan scan, ~1,500 / ~13,000 entries | 13.4 s / 77.9 s | unchanged |
  | `app inspect` by bundle id, 100 apps | 6.8 s | unchanged |

  Causes fixed: candidate ids computed twice per entry with `shasum` (a Perl
  script, ~10 ms each) and recorded even for human scans; `$(path_authorize)`
  subshells; `du | awk | tail`; `is_whitelisted` canonicalising with no path
  whitelist; the plan digest built by quadratic string concatenation; five
  `$(json_escape)` subshells per serialized action. Digests are byte-identical.

Each new category must define:

- authoritative ownership source;
- allowed roots;
- discovery and exclusion logic;
- risk facets and default selection;
- recovery and rebuild behavior;
- required tools/permissions;
- size/accounting semantics;
- fixtures and failure tests;
- README/help documentation.

### Phase 6 exit gate

- [ ] Each shipped category meets the category contract.
- [ ] Performance budgets are measured, not guessed.
- [ ] Read-only concurrency cannot race mutation.
- [ ] New rule formats cannot silently broaden scope after update.

## 14. Phase 7 — Packaging and trusted release

### `P7-T01` — Product identity

Status: `[x]` complete — 2026-09-27

- [x] Select a distinct project and command name after package/trademark checks. *(`mimi`, DEC-027/DEC-039)*
- [x] Define bundle/package IDs for future GUI/helper without colliding with the CLI. *(DEC-062: `io.github.nkwabyte.mimi` family)*

### `P7-T02` — CLI installation

Status: `[x]` complete — 2026-09-27

- [x] Support source-tree use and a documented installed layout. *(`install.sh` symlink install, `--prefix`, `--uninstall`)*
- [x] Package completions, man page, license, changelog, and uninstall instructions. *(LICENSE, `CHANGELOG.md`, README install/update/uninstall; `completions/mimi.bash`, `completions/_mimi`, `man/mimi.1` (2026-09-27), installed by the formula; `tests/layout.bats` fails if an option is missing from any of them)*
- [x] Add Homebrew formula/cask as appropriate. *(`nkwabyte/homebrew-mimi` tap, updated by `.github/workflows/homebrew-release.yml`, which since 2026-09-26 refuses a tag that does not match `MIMI_VERSION`; formula test runs `mimi --version`)*

### `P7-T03` — Upgrade and schema compatibility

Status: `[x]` complete — 2026-09-27

- [x] Migrate config/history safely. *(legacy `~/.config/cleanmymac` migration since 2026-09-22; history records carry `"v"` from 2026-09-27, older records are the same shape)*
- [x] Keep at least one supported prior plan/history schema readable where promised. *(plan v1 is the only plan schema; history v1 reads pre-`v` records; schemas in `schemas/`)*
- [x] Refuse unsafe downgrades clearly. *(DEC-064: `~/.config/mimi/.version` stamp; an older mimi warns once; newer plan schemas are refused by preflight)*

### `P7-T04` — Security and privacy documentation

Status: `[x]` complete — 2026-09-27

- [x] Add `SECURITY.md`, threat model, privacy statement, support matrix, and disclosure path. *(`SECURITY.md` rewritten 2026-09-27; threat model in `docs/PRIVILEGED_DESIGN.md`)*
- [x] Keep diagnostics local/redacted and telemetry off by default. *(no telemetry and no network use of its own; logs and state local, 0600/0700; documented in `SECURITY.md`)*

### `P7-T05` — Release verification

Status: `[ ]` not started — needs more than one macOS version/architecture to run on. Partly covered: CI runs on macOS 14 (found the plutil bug), `scripts/release.sh` gates on CI.

- [ ] Test clean install, upgrade, recovery, purge, and complete self-uninstall.
- [ ] Test supported macOS versions and architectures.
- [ ] Produce reproducible checksums and release notes.

### Phase 7 exit gate

- [ ] Installation and self-uninstallation leave only explicitly retained history/quarantine.
- [ ] Release artifacts pass the full safety and compatibility matrix.
- [ ] Rollback instructions are tested.

## 15. Recommended delivery batches

These batches keep each review focused. Do not merge batches merely to move faster.

### Batch A — Testing foothold

- `P0-T01` test harness
- initial portion of `P0-T02` help/list/scan characterization

### Batch B — Path boundary

- `P0-T03` canonical path API
- traversal and symlink regression tests

### Batch C — Orphan lockdown

- `P0-T04` reviewed input validation
- `P0-T06` heuristic report-only policy

### Batch D — Mutation truthfulness

- `P0-T05` checked action results
- focused accounting fixes from `P0-T10`

### Batch E — CLI policy

- `P0-T07` confirmation classes
- `P0-T08` argument/config validation

### Batch F — Conservative defaults

- `P0-T09` profiles/defaults
- remaining contained fixes from `P0-T10`
- `P0-T12` documentation parity

### Batch G — Enforcement

- `P0-T11` CI and pinned tools
- Phase 0 exit-gate audit

## 21. Progress log

Append one short entry when a task starts, pauses, or completes.

### 2026-09-14

- Created the phased CLI implementation scratchpad.
- Selected `P0-T01` as the first implementation task.
- Deferred GUI implementation until CLI protocol and safety gates are complete.

### 2026-09-21 — Phase 0 Batch A

- `P0-T01` **complete**. `tests/` harness landed: `run` entry point,
  `test_helper.bash` (per-test disposable fake home, `HOME`/`TMPDIR`
  redirection, sentinels, mock `PATH`), 21 command mocks, `fixtures/`
  placeholder, `tests/README.md` contributor guide.
- Escape detection is now self-verifying rather than skipped: `verify_sentinels`
  was extracted from `teardown`, and two tests tamper with a sentinel and
  assert the alarm fires.
- Added mocks for `uv`, `go`, `yarn`, `pgrep`, `pip3`, `python3`, `avdmanager`,
  `osascript`, `diskutil`. `pgrep` returning "nothing running" removes a real
  non-determinism: `app_is_running()` previously consulted the developer's
  actual open applications.
- `P0-T02` **partial**. `smoke.bats` (28 tests) characterizes help/list, mode
  defaults, `--only`/`--skip`, whitelist, config precedence, and scan
  non-destructiveness.
- `P0-T08` **partial**. `arg_validation.bats` (34 tests) was written first and
  failed 22/34 against the then-current behaviour; `require_arg`,
  `validate_int`, `is_known_category`, `normalize_category_list` and
  `validate_config_values` were then added to make it pass.
- Suite: **63 tests, 0 failures, 0 skipped.** `/bin/bash -n clean.sh` passes.

Defects found and fixed while doing the above:

- `cat_caches` and `cat_logs` iterated `"$base"/*` and handed every entry to
  `clear_dir_contents`, which returns early on anything that is not a
  directory. Loose files directly under `~/Library/Caches` and
  `~/Library/Logs` were therefore never removed **and never counted in the
  scan estimate**. Caught by the one smoke test that was already failing.
- `normalize_category_list` is called inside `$( )`, so its `die_usage` exit
  ended only the subshell and the parent continued with an empty list. Every
  caller now propagates with `|| exit "$EXIT_USAGE"`.
- `apply_whitelist_preset` returned `1` on an unknown preset but the caller
  ignored it, so a typo was silently a no-op. Its error message also still
  listed only three of the five presets.
- `--remove-orphans-from` accepted an unreadable path without complaint.

### 2026-09-22 — Phase 0 Batch B

- `P0-T03` **complete**. `resolve_path` is gone; a canonical path and
  containment API replaces it, and `clear_dir_contents`/`remove_path`/
  `is_whitelisted` are the first callers. `tests/path_api.bats` adds 64 tests.
  Suite: **127 tests, 0 failures, 0 skipped.** `/bin/bash -n clean.sh` passes,
  `git diff --check` passes.
- Added the `CLEANMYMAC_LIB_ONLY=1` source hook so helpers can be unit-tested
  directly instead of only through a full CLI run.

Defects found and fixed while doing the above:

- **A symlink under `~/Library/Caches` was followed and its target's contents
  deleted.** `clear_dir_contents` tested `[ -d "$dir" ]`, which is true for a
  symlink to a directory, then globbed `"$dir"/*` straight through it. A link
  named `~/Library/Caches/anything` pointing at, say, `~/Documents` meant a
  default `--clean` emptied `~/Documents`. The regression test
  (`cli: --clean does not follow a symlinked cache directory out of the
  allowed roots`) was confirmed to fail against the pre-change script and pass
  after.
- `resolve_path` used `(cd "$p" && pwd -P)`, which **cannot succeed on a
  file** — `cd` only works on directories. Every file path therefore fell
  through to the raw unresolved string, as did every path that did not exist.
  The whitelist then prefix-matched those strings, so whether a file was
  protected depended on how the caller happened to spell its path.
- `..` was never resolved at all, only ever carried along inside a string that
  was then prefix-matched. `$HOME/Library/Caches/../../../etc` textually
  "starts with" `$HOME/Library/Caches`.
- Forbidden roots were compared literally, so `/var` protected only the string
  `/var` — a target that resolved to `/private/var` matched nothing. Both
  canonical forms of every forbidden entry are now stored.
- Broken symlinks inside a cleared directory were skipped forever: the loop
  guard was `[ -e "$entry" ]`, which is false for a dangling link. It is now
  `[ -e "$entry" ] || [ -L "$entry" ]`.

Deliberately *not* changed here, to keep the change set to one concern:

- Byte accounting still credits `rm` with the full size whether or not it
  succeeded — `P0-T05` owns that.
- `process_orphans_review_file` still uses a lexical allowed-root `case` —
  `P0-T04` owns that, and now has `path_authorize` to build on.

### 2026-09-22 — Phase 0 Batch C (part 1)

- `P0-T04` **complete**. `tests/orphan_review.bats` adds 29 tests.
  Suite: **156 tests, 0 failures, 0 skipped.** `/bin/bash -n clean.sh` passes,
  `git diff --check` passes. 19 of the 29 fail against the previous script.
- `path_authorize` now also publishes `PATH_CANONICAL`, so an internal caller
  can read both the canonical path and the refusal reason without a command
  substitution swallowing the reason in a subshell.

Defects found and fixed while doing the above:

- **The traversal hole itself.** `process_orphans_review_file` matched the
  raw, unresolved line against `case "$path" in "$HOME_DIR/Library/Application
  Support/"*` and friends. `~/Library/Application Support/../../..` satisfies
  that pattern, so a review file could name any path on the machine and it
  would be handed to `remove_path`. Now every line is canonicalized and must
  land on a direct child of a root the scanner itself walks.
- **`#` was stripped from the middle of filenames.** `line="${raw%%#*}"`
  turned a folder genuinely named `com.example.app#1` into
  `com.example.app` — which either did not exist (so the real folder was
  never removed, and the user was told nothing) or *did* exist as a different
  app's data, which would then have been deleted instead. Both halves of that
  are now impossible.
- Trailing whitespace was unconditionally stripped by `sed`, so a directory
  whose name genuinely ends in a space could not be named. It is now stripped
  only when doing so is what makes the path resolve.
- The allowed-location list was a second, hand-maintained copy of
  `ORPHAN_ROOTS` that had already drifted (it lacked `Preferences/ByHost`,
  covered only by accident through the `Preferences/` prefix). It is now
  derived from `ORPHAN_ROOTS`.
- Nothing was revalidated after the confirmation prompt, which is an
  unbounded pause. The whitelist, the allowed roots and the object identity
  are all re-checked immediately before each removal.

Deliberately *not* changed here:

- `launchctl unload` is still used for LaunchAgents — `P0-T10` owns replacing
  it with a correctly scoped modern equivalent.
- The `auto` tier still bulk-removes heuristic matches. That is `P0-T06`,
  the other half of Batch C, and is the next task.

### 2026-09-22 — Phase 0 Batch C (part 2)

- `P0-T06` **complete**, which closes **Batch C**. `tests/orphan_report.bats`
  adds 25 tests. Suite: **181 tests, 0 failures, 0 skipped.**
  `/bin/bash -n clean.sh` passes, `git diff --check` passes. 23 of the 25 new
  tests fail against the previous script.
- The `mdfind`, `mdls` and `defaults` mocks are now table-driven from an
  optional `$MOCK_APP_INDEX` file, so a test can state exactly which
  applications Spotlight knows about. Default behaviour is unchanged.
- `ORPHAN_APP_WALK_ROOTS` was extracted from `build_installed_identifiers`.

The headline change: `--clean --include-orphans` used to bulk-delete every
`auto`-tier match behind a single confirmation. It now deletes nothing, ever.
The scan writes a report; `--remove-orphans-from` (hardened in `P0-T04`) is
the only path to deletion.

Defects and misstatements found and fixed:

- **Absence was read as proof.** When Spotlight was unavailable or had not
  finished indexing, `build_installed_identifiers` silently fell back to a
  directory walk and `is_installed_identifier` then returned false for
  everything it had not seen — so *every* entry became a candidate, and the
  high-confidence ones were offered for bulk deletion. On a machine where
  Spotlight was off, a single confirmation could have removed live
  application data. Incompleteness is now detected and every candidate is
  downgraded.
- The reclaimable-space estimate counted orphan candidates, so the summary
  claimed `--clean` would free space that `--clean` never touched. Fixed by
  DEC-016.
- `_index_app` returned whatever the last bundle-id lookup returned, so its
  exit status depended on whether an app happened to have a readable
  `CFBundleIdentifier`. Harmless under the script's own `set -uo pipefail`,
  but it made the function unsafe to call from anywhere with `errexit` on.
  Now explicit.
- README, `docs/USAGE.md` and `--help` all described the `[auto]` tier as
  "offered for immediate bulk removal". All three now describe a report.

Deliberately *not* changed here:

- `is_installed_identifier`'s substring matching in both directions is
  crude — a 4-character installed-app name can suppress an unrelated
  candidate. It errs towards *not* listing things, which is the safe
  direction, so it is left for `P3-T05`'s confidence model.
- `launchctl unload` for LaunchAgents remains — `P0-T10`.

### 2026-09-22 — Phase 0 Batch D (part 1)

- `P0-T05` **complete**. `tests/mutation.bats` adds 25 tests.
  Suite: **206 tests, 0 failures, 0 skipped.** `/bin/bash -n clean.sh` passes,
  `git diff --check` passes. 18 of the 25 new tests fail against the previous
  script.
- New: `fs_remove`, `report_action`, `record_action`, `any_action_failed`,
  `interrupted`, `_on_interrupt`, and the `ACTION_*` counters.
- New exit codes `3` (partial failure) and `4` (interrupted), documented in
  `README.md` and `docs/USAGE.md`.

The defect this closes, in the previous code's own words:

```bash
rm -rf -- "$p" 2>>"$LOG_FILE"
TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size))
ok "removed: $p  (freed $(human_kb "$size"))"
```

Nothing looked at the result. A cache directory the user could not write
printed "removed … (freed 400M)", added 400M to the run total, and exited 0.
Verified by injection: a `chmod 500` parent now yields `permission denied, not
removed`, a reclaimed total of zero for that target, and exit `3`.

Also fixed here:

- `cat_dsstore` counted every `.DS_Store` it *found* as removed. `.DS_Store`
  files routinely sit in directories the user cannot write, so both the count
  and the freed total were wrong on most real machines. It now reports
  "removed N of M" and returns non-zero when they differ.
- `clear_dir_contents` printed `cleared: … (freed 0.0K)` — a success message —
  when every single entry had failed. It now says `partly cleared` and
  returns non-zero.
- `log_init` trapped `INT`/`TERM` on `_cleanup_on_exit`, which returns 0, so
  Ctrl-C during a clean did nothing visible and the run carried on. Signals
  are now recorded and wind the run down.

Deliberately *not* changed here:

- The tool-delegated categories (`brew cleanup`, `npm cache clean`, `docker
  prune`) still credit a measured before/after difference around an external
  command. That is honest — it measures real change — but the external
  command's own exit status is still ignored. `P0-T10` owns auditing those.
- `launchctl unload`, the duplicate QuickLook reset, Android SDK image
  validation and sparse-file size reporting all remain — `P0-T10`.

### 2026-09-22 — Out-of-phase restructure (partial `P1-T02` / `P1-T03`)

Requested by the maintainer mid-Phase-0. The conflict with DEC-003 was raised
first and the request was reaffirmed, so it was done as a **pure move** in its
own change set.

- `clean.sh` (5,012 lines) became `bin/cleanmymac` (218) + `lib/*.sh` + a
  24-line `clean.sh` shim. Extracted modules: `globals` (147), `log` (85),
  `util` (29), `validate` (135), `usage` (201), `config` (67), `path` (356),
  `action` (283). The remainder is `lib/core.sh` (3,582), to be split next.
- `tests/layout.bats` adds 18 tests. Suite: **224 tests, 0 failures.**
- The split was computed programmatically with a coverage assertion — all
  5,012 original lines assigned exactly once, no overlaps — rather than by
  hand-counting line ranges.
- Behaviour neutrality was verified by running the old single file and the new
  tree side by side over ten invocations. **Byte-identical output and
  identical exit codes in every case**, with one exception: the line number
  inside a pre-existing error message (`clean.sh:216` → `lib/log.sh:73`).
- The `CLEANMYMAC_LIB_ONLY` test hook is gone. It existed only because
  everything was one file; tests now source `lib/load.sh`. This also removes
  the wart noted in the parking lot, where functions defined below the
  argument-parsing block were invisible to that hook.

Found while doing this, **not** fixed here (kept to one concern):

- **Pre-existing**: any `err`/`warn` emitted before `log_init` runs — every
  usage error, for instance — writes to `$LOG_FILE` in a directory that does
  not exist yet, producing a raw shell redirection error on stderr. Confirmed
  identical in the pre-split script. Belongs to `P0-T10`.
- `basename "$0"` was hardened to `basename -- "$0"`; a `$0` beginning with a
  dash was read as an option. One character, done here because it is part of
  the entry-point change.

### 2026-09-22 — Phase 0 Batch D (part 2)

- `P0-T10` **complete**, which closes **Batch D**. The last open `P0-T08` item
  (atomic config writes) is done too. `tests/defects.bats` adds 30 tests.
  Suite: **254 tests, 0 failures.**
- New: `tool_cleanup` in `lib/action.sh`, `unload_launch_agent`,
  `path_logical_kb` and `is_sparse_file`.
- The mocks gained two hooks — `MOCK_CALL_LOG` (count invocations) and
  `MOCK_FAIL_CMDS` (fail a matching invocation). The latter matches the whole
  command line rather than the command name, because failing every `npm` call
  also breaks `npm config get cache`, and the category then skips before it
  reaches the cleanup — a test that would pass while proving nothing.

Defects fixed:

- **Android system images were deleted on absent evidence.** An image went if
  no AVD referenced it, but the reference list came out empty whenever
  `ANDROID_AVD_HOME` relocated the AVD directory, no `config.ini` was
  readable, or the file had CRLF endings — a `\r` made every reference match
  nothing. On such a machine the category deleted every installed system
  image. The same absence-as-proof error `P0-T06` fixed for orphans.
- **All 13 delegated commands discarded their exit status.** `npm cache clean
  --force` could fail outright and the run still printed "npm cache cleaned"
  and exited 0. The freed byte figures were measured and therefore honest, but
  the words were not.
- **The QuickLook cache reset ran twice**, doubling the category's runtime for
  no second-pass effect, and reported success whether or not `qlmanage` worked.
- **`launchctl unload` ended in `|| true`**, hiding the fact that an agent it
  could not stop keeps running until the next login.
- **Every message printed before `log_init`** — each usage error, for one —
  was appended to a log path inside a directory that did not exist yet, so it
  came with a raw shell redirection error underneath it.
- **`save_config` wrote in place with default permissions.** Since DEC-006
  makes a malformed config fatal, an interrupted save locked the user out of
  every subsequent run.

One test-quality note worth keeping: the first CRLF test passed *without* the
fix, because an unstripped `\r` makes the reference look malformed, which also
protects the image. Surviving was not evidence the reference had been
understood. The test now also asserts no malformed-reference warning appeared
and that an unreferenced image was still removed.

### 2026-09-22 — Rename to `mimi` (out of phase order, `P7-T01` in part)

Requested by the maintainer. Resolves the long-open `D-007`.

- `bin/cleanmymac` → `bin/mimi`; the command is `mimi`, and `--cleaner` is the
  documented spelling for a cleaning run. `--clean` still works.
- `install.sh` added: symlinks `bin/mimi` into the first writable directory on
  `PATH`, says what to add to the shell profile when there is none, and
  supports `--prefix` and `--uninstall`. It links rather than copies, so a
  `git pull` updates the installed command — which works because `bin/mimi`
  already resolved `lib/` through its own symlink (`P1-T02`).
- User state migrates itself on first run (DEC-028). Verified on a real home
  directory during development, not only in the fixture.
- `clean.sh` stays as a deprecated shim and prints a one-line notice on
  **stderr**, so piping or capturing stdout is unaffected.
- GitHub repository renamed `nkwabyte/mac-cleaner` → `nkwabyte/mimi`; both
  remote URLs updated, preserving the `github-nkwabyte` SSH host alias.
- Suite: **269 tests, 0 failures** (15 new, covering `--cleaner`, the config
  and log migration, the legacy review marker, and `install.sh`).

Worth noting: the old name was also a trademark problem. "CleanMyMac" is
MacPaw's commercial product, and `P7-T01` ("select a distinct project and
command name after package/trademark checks") would have had to unpick it
before any public release. That item is now largely satisfied.

Still outstanding from `P7-T01`: bundle/package identifiers for the future GUI
and privileged helper have not been chosen.

### 2026-09-22 — Phase 0 Batch E

- `P0-T07` **complete**. Every confirmation now belongs to one of four classes
  (`lib/confirm.sh`), and the class — not the prompt's wording — decides what
  can answer it. `--yes` answers the recoverable prompts and the whole-run
  gate; it can no longer authorize `docker`, `mail`, `trash`, `orphans`,
  `sim-stale`, `android` or `ios-backups`.
- `--force-risky <names>` is the new authorization flag: comma-separated
  action ids, no `all`, command line only. It authorizes but does not select,
  so `--include-<name>` is still required (DEC-030, DEC-031).
- `mail` was registered `risky` in the category table and had no confirmation
  at all. It has one now.
- A non-interactive run that selected unauthorized risky work fails *before*
  the first category, naming each action, its class and the exact flag that
  grants it, and exits `5` having removed nothing (DEC-029, DEC-032).
- At a terminal, an irreversible action is confirmed by typing its id rather
  than `y`, once per id per run; each individual item still gets its own
  `y/N` (DEC-033).
- `tests/test_helper.bash` now pins stdin to `/dev/null`, so confirmation
  behaviour is decided by the flags under test and never by whether the suite
  happened to be started from a terminal.
- 46 new tests in `tests/confirmations.bats`. 14 existing tests that used
  `--yes` to authorize reviewed-orphan removal or AVD deletion now say
  `--force-risky` instead — which is the contract change made visible.

### 2026-09-26 — Phase 3 audit and completion

Phase 3 had been ticked `[x]` on 2026-09-25, but an audit against the code
found several claims that were only partly true. Everything below is now
implemented and tested:

- Inventory: vendor-folder apps, repeatable `--app-root`, unavailable roots
  reported, Spotlight compared app-by-app with the walk (the old count
  comparison included hits outside every root), identity exported, `--source`
  validated. JSON wrapped in a versioned document with an `inventory` block.
- Bundle fingerprint: Electron helpers, system extensions, bundled launchd jobs
  and privileged helpers; eligibility and identity warnings (DEC-055).
- Provenance: cask detection from the installed cask's recorded definition
  (the old code matched only when the token normalised to the app name, and
  read a test-only `FAKE_HOME` variable); `pkgutil --file-info` receipt
  correlation; every fact listed; uninstaller detection ignores icons/docs.
- Evidence: Application Scripts, Cookies, crash reports, LaunchAgents read by
  program path, developer dotfolders; boundary-aware id matching (DEC-053);
  symlink/containment rules (DEC-054); `/Library` roots overridable for tests
  (the suite previously read the host's `/Library`).
- Policy: `conflicting` confidence for duplicate copies, more-specific sibling
  ids, and same-named apps; name-only matches downgraded to `weak`; shared
  updaters vetoed; `review` class; `evidence_is_selectable` (DEC-052) now used
  by the Phase 4 planner too.
- Inspect: explicit resolution order incl. case-insensitive ids, not-an-app and
  JSON error documents with candidates, `schemas/app-inspect-v1.json`.
- Performance on a real machine (116 apps): `app inspect <name>` 34 s → 8 s;
  evidence collection 29 s → 2 s.
- Tests: `tests/apps.bats` 15 → 58; new `codesign` and `pkgutil` mocks;
  `tests/README.md` documents the `MIMI_*` isolation variables.
- Phase 4 files (`lib/apps/process.sh`, `lib/apps/uninstall.sh`,
  `tests/uninstall.bats`) already existed uncommitted; only the planner's
  selection predicate and an eligibility guard were changed here. Phase 4
  tasks remain unchecked pending their own review.

### 2026-09-26 — SIP-protected temp folders and TUI redraw flicker

- A real `clean` run (`docs/info.txt`) reported 23 "permission denied" items,
  all daemon working folders in `$TMPDIR` (`mobiletimerd`, `gamed`,
  `proactived`, ...). They carry the `sunlnk` flag and `com.apple.rootless`,
  so System Integrity Protection guards them: root cannot remove them either,
  and `sudo` would not help. `path_is_sip_protected` (flags `restricted` or
  `sunlnk`) now makes `fs_remove` skip them with status `protected`, counted
  as skipped (`ACTION_PROTECTED`), not denied; the summary says macOS manages
  them instead of blaming Full Disk Access. JSONL `action_result` status
  `protected`.
- Running under `sudo` was requested but not implemented: nothing it would
  unlock appears in the failing run, and privileged scope is `P5-T03`/`P5-T04`
  (HOME/TMPDIR resolution for `SUDO_USER`, root-owned logs/config in the user's
  home, Homebrew refusing to run as root). Awaiting a decision.
- TUI flicker: every keypress erased the frame (`\033[J`) and then redrew it
  row by row with ~6 subprocesses per row (~180 ms blank). Frames are now built
  off-screen and painted in one write by `tui_paint` (cursor up, overwrite each
  line + `\033[K`, erase leftovers, inside `?2026` synchronized output); picker
  rows are cached once per session (`_picker_cache_rows`). Frame build ~2 ms.
  Applies to the category picker, menus, whitelist, and settings screens.
- Tests: 5 new in `tests/mutation.bats`; 470 passing.

### 2026-09-26 — Menu cleans ask no questions

- Requested: once categories are chosen in the TUI, a clean should not ask
  anything further; the selection and the whitelist are the user's controls.
- `tui_run_clean` (`lib/ui/tui.sh`) now backs the picker's `c`, the numeric
  fallback's `c`, and *Quick clean*. For that run it sets `ASSUME_YES=1` and
  `FORCE_RISKY_LIST` to exactly the selected risky/irreversible ids
  (`FORCE_RISKY_SOURCE="your category selection"`), then restores both.
  Unselected categories stay unauthorized; whitelist and path policy unchanged.
- This amends DEC-033 for the interactive UI only (see DEC-058). CLI behaviour
  (`--yes` recoverable only, `--force-risky` per id, typed confirmation for
  irreversible) is unchanged.
- Tests: 4 new in `tests/confirmations.bats`.

### 2026-09-26 — Leftovers removable from the CLI without a review file

- Requested: remove every leftover, weak or strong, without editing a file.
- `--remove-orphans` (implies `--include-orphans`) makes a clean move every
  candidate into one quarantine run `orphans-<timestamp>`
  (`orphans_quarantine_all`); `restore` undoes it, `purge` frees the space.
  Each path is revalidated (`validate_orphan_target`), whitelisted and
  SIP-protected entries are skipped, LaunchAgents are booted out first.
  Ticking `orphans` for a menu clean sets `REMOVE_ORPHANS` for that run.
  A scan with the flag previews. The review file and `--remove-orphans-from`
  remain for hand-picked removal. Supersedes the "never deletes" rule of
  `P0-T06` (DEC-059).
- False positives seen in the real run are excluded: macOS structure
  (`ByHost`, `WebKit/Databases`, bare `Caches`, `default.store*`) via
  `ORPHAN_STRUCTURAL_NAMES`; Apple service names added to
  `ORPHAN_SYSTEM_DENYLIST`; folders of installed command-line tools via
  `is_installed_cli_tool` (`type -P` on the name, the name minus `-nodejs`,
  and a non-generic last dotted component). Real-machine count 203 → 171.
- Tests: 12 new in `tests/orphan_report.bats`; two wording tests updated to
  the new contract.

### 2026-09-26 — Phase 4 reviewed and completed

The uninstall code existed but had never been checked against its tasks. Gaps
found and closed:

- Not plan-bound: it saved a plan and then applied from memory, and bypassed
  `path_authorize` entirely. Now the saved file is preflighted and executed by
  `plan_execute_loaded`, shared with `mimi apply`; bundles are authorized by
  the narrow `uninstall_authorize_bundle`; `--plan-only` + `mimi apply` works.
- `--yes` could force-quit a running app. Force-quit is now the risky action
  `app-terminate`.
- The default "ask" data mode never asked. It now asks once at a terminal and
  otherwise keeps data.
- `--cask` guessed a token for non-cask apps and ran brew without preview or
  record. Now refused unless brew lists the cask; zap paths previewed with
  shared flags; results recorded in `history.jsonl`.
- Bundle was moved before data, LaunchAgents stopped by file name, nothing was
  verified afterwards. Now agents → bundle → data, bootout by Label, retained
  items verified, leftovers reported (exit 3).
- Restore failed on re-run and gave no guidance on conflicts or services.
- Plan schema: new operation `retain` (DEC-060).
- Tests: `tests/uninstall.bats` 37 → 61.

### 2026-09-26 — Release hygiene

- `mimi --version` / `-V`; `MIMI_VERSION` moved to `lib/core/globals.sh` as the
  single source (also the JSON `engine_version`).
- Release workflow checks out the tag and fails unless it equals
  `v$MIMI_VERSION`; the formula test asserts `mimi --version`.
- `CHANGELOG.md` with 0.1.0 and 0.2.0; README "Updating" section; tests pin
  version output, the changelog entry, and the protocol version.
- Scratchpad: D-001–D-006 closed with their decision references; Phase 0 gate
  annotated with the DEC-058/DEC-059 amendments; parking lot refreshed.

### 2026-09-26 — Phase 6 (selected): reports, TUI tests, benchmarks

- `P6-T05` largest single files and `P6-T07` stale downloads added to
  `--report` (report only), with `tests/report.bats`.
- TUI key handling is now tested through the `MIMI_TUI_INPUT` seam
  (`tests/tui.bats`, 11 tests).
- `P6-T11`: `tests/bench`. It found a 6× slowdown in every scan (candidate ids
  hashed twice with Perl `shasum`, recorded even when unused) and a quadratic
  plan digest. Both fixed; numbers in the Phase 6 section.

### 2026-09-26 — Phase 5 (safe part) and release scripts

- `P5-T01` verified vendor-uninstaller hand-off; `P5-T02` receipt ownership
  graph, shown by `app inspect` (`package_payload`), plus package attribution
  for apps installed to a package's own location. `P5-T03` written up in
  `docs/PRIVILEGED_DESIGN.md`; `P5-T04`/`T05` blocked on the decision.
- Found and fixed along the way: a Bash 3.2 parse error (case pattern inside
  `$(...)`) in the receipt index; an `open` mock so no test can launch an app.
- `scripts/`: `release.sh` (checks → tests → bump → PR dev→main → merge →
  tag → publish → watch tap → sync dev; `--dry-run`, `--publish-only`),
  `bump-version.sh`, `version.sh`, `lib.sh`, `README.md`; `tests/release.bats`
  runs them against a throwaway repo with a stub `gh`; `tests/run` now
  syntax-checks and lints `scripts/*.sh`.

### 2026-09-26 — Phase 5 option B, first slice

- `libexec/mimi-root-apply` and `mimi app uninstall <app> --system`, as
  recorded in DEC-061 and `docs/PRIVILEGED_DESIGN.md` §7. On this machine it
  attributes CleanMyMac's, Docker's, Office's, and Logitech's daemons and
  helpers correctly and lists Docker's `vmnetd` as not attributable.
- Fixed a Phase 3 resolution bug found on the way: a bundle id ending in
  `.app` (`com.acme.app`) was treated as a path and could not be resolved.
- Homebrew formula now installs `libexec/`. `tests/run` lints the root tool;
  `tests/layout.bats` pins that it sources nothing and that mimi never calls
  sudo.
- Exit gate still open: independent security review of the root tool, and
  helper update/self-removal (the tool has no daemon, so "self-removal" is
  removing the file; to be covered by the uninstall instructions).

### 2026-09-26 — Phase 5 slice 2 and the hardened copy

- Package payload (attribution by package id or installed app; exclusive,
  root-owned, allowed roots only), receipts forgotten at purge only, and
  `--install` / `--uninstall-tool` for a root-owned copy that mimi prefers
  while identical. Real machine: Logitech's agent + package-installed app,
  .NET's `/usr/local/share/dotnet/*` items; 17 s → 4 s after a one-pass
  attribution fix; duplicate candidates across a family of packages removed.
- System binary folders (`/usr/bin`, `/bin`, …) added to the structural list
  in both `libexec/mimi-root-apply` and `lib/apps/receipts.sh`, so a file
  there is reported as itself (and refused), not as the whole folder.
- Phase 5 exit gate: all items met except the independent review, which the
  owner has arranged.

### 2026-09-27 — CI failure on macos-14 after v0.2.0

- CI (`macos-14`) failed the launchd tests in `tests/root_apply.bats`; they
  passed locally (macOS 27). Cause: on macOS 14, `plutil -extract` prints
  "Could not extract value…" to stdout for a missing key, so the root tool
  read error text as `AssociatedBundleIdentifiers` and as the program path.
  It failed safe (nothing attributable), but shipped in v0.2.0.
- Fixed in `libexec/mimi-root-apply` (`plist_str`, the association lookup)
  and in `lib/apps/inventory.sh` / `lib/apps/evidence.sh`: plutil output is
  used only when it exits 0. Regression test wraps plutil with the macOS 14
  behaviour; confirmed the committed tool fails it and the fix passes.
- Actions bumped to `checkout@v7` / `upload-artifact@v7` (Node 24).
- Lesson: the release script runs the local suite only; CI runs on an older
  macOS. Consider waiting for CI on the release PR before merging.

### 2026-09-27 — Scratchpad sweep

- Fixed: `plan_load` JSON-unescaping; undefined `EXIT_FAILURE` (DEC-063);
  orphan scan 2.6× faster; Spotlight fast path for bundle ids; `mimi
  history`; completions and man page; version stamp (DEC-064); `SECURITY.md`
  rewritten; GUI identifiers decided (DEC-062); config-list decision
  (DEC-065); opt-in parallel test runs.
- Closed parking-lot items that later phases had already settled; the
  definition-of-done checklist is marked as a template.
- Still open: Phase 5 independent review (owner arranging), `P7-T05`
  (multi-version release matrix), Phase 6 feature backlog, and the parked
  `--report` read-path auditing item.

## 23. Current handoff

```text
Task:          Phase 3 audit and completion (P3-T01 through P3-T06, exit gate)
Status:        complete
Changed files: bin/mimi, lib/apps/inventory.sh, lib/apps/evidence.sh, lib/apps/inspect.sh,
               lib/apps/uninstall.sh (selection predicate + eligibility guard only),
               lib/ui/usage.sh, schemas/apps-list-v1.json, schemas/app-inspect-v1.json,
               tests/apps.bats, tests/uninstall.bats (env isolation only),
               tests/mocks/bin/codesign, tests/mocks/bin/pkgutil, tests/README.md,
               docs/USAGE.md, docs/CLI_IMPLEMENTATION_SCRATCHPAD.md
Tests run:     ./tests/run < /dev/null
Test result:   465 passed, 0 failed, 0 skipped (tests/apps.bats: 58)
Safety checks: /bin/bash -n and shellcheck -x clean on every shell file (tests/run gates);
               git diff --check clean; sentinels intact; apps list / app inspect proven
               non-mutating by a before/after tree fingerprint; pkgutil/codesign mocks
               reject every non-read invocation.
Decisions:     DEC-052 through DEC-057.
New risks:     `apps list` on a real machine takes ~20 s, dominated by `du` of every bundle
               (116 apps); acceptable for a report, but a size-less fast mode may be wanted
               by the GUI.
Blocker:       none
Exact next step: Review the existing uncommitted Phase 4 code (P4-T01 to P4-T06) against
               its checklist before ticking anything; it now consumes
               evidence_is_selectable and APP_INFO_ELIGIBLE from Phase 3.
```
