# CLI implementation scratchpad

Status: active planning

Created: 2026-09-14

Primary plan: [CLI improvement and uninstaller plan](IMPROVEMENT_PLAN.md)

GUI work: deferred until the CLI safety and protocol gates in [GUI wrapper plan](GUI_WRAPPER_PLAN.md) are complete.

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

Current phase: Phase 0 — Safety stabilization

Current task: `P0-T01` — establish the test harness and isolated fake home directory

Next tasks:

1. `P0-T02` — capture current CLI behavior as characterization tests.
2. `P0-T03` — canonical path and containment API.
3. `P0-T04` — secure reviewed-orphan input handling.
4. `P0-T05` — harden mutation primitives and result accounting.
5. `P0-T06` — make heuristic orphan discovery report-only.

Do not start plan/apply, application uninstalling, privileged helpers, new cleanup categories, or GUI integration until the Phase 0 exit gate passes.

## 4. Baseline snapshot

- Main implementation: `clean.sh`
- Current size at planning time: 2,059 lines
- Runtime target: macOS system Bash 3.2+
- Current tests: 63 Bats tests in `tests/` (`./tests/run`) — as of 2026-09-21
- Current CI: none
- Current static tools in review environment: ShellCheck and shfmt still not installed (documented in `tests/README.md`, not yet enforced)
- Syntax check: `/bin/bash -n clean.sh` passes
- Current persisted config: `~/.config/cleanmymac/config.conf`
- Current logs: `~/Library/Logs/cleanmymac`
- Current execution model: scan or immediate clean
- Current recovery model: none
- Current orphan model: heuristic `auto` and `review` tiers

Known critical risks are tracked in the main plan. Phase 0 treats the current deletion behavior as frozen except for safety fixes.

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

Every implementation task must satisfy all applicable items:

- [ ] Acceptance criteria are demonstrably met.
- [ ] New/changed behavior has tests.
- [ ] `/bin/bash -n` passes for every shell file.
- [ ] ShellCheck passes at the agreed severity.
- [ ] Formatting check passes.
- [ ] Existing tests pass under macOS Bash 3.2.
- [ ] No test touched data outside its disposable fixture.
- [ ] Help text and README match behavior.
- [ ] Error and cancellation paths have been exercised.
- [ ] `git diff --check` passes.
- [ ] Scratchpad status and progress log are updated.

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

Status: `[~]` partially complete — 2026-09-21 (Batch A subset)

- [x] Test `--help` and `--list` exit successfully.
- [~] Snapshot category IDs, risks, and defaults. *(IDs and the risk column are
  asserted; a full golden-file snapshot of all 35 rows is still outstanding.)*
- [x] Test scan is the non-interactive default when a flag is supplied.
- [x] Test `--only`, `--skip`, repeated whitelist, and presets.
- [x] Test configuration load/save precedence. *(load and precedence covered;
  `save_config` round-tripping is not yet tested.)*
- [x] Capture current missing-value, invalid-number, and unknown-category behavior before fixing it.
- [x] Test that a scan does not remove fixture files.

Acceptance:

- Tests describe current public behavior without depending on ANSI codes, timestamps, or real installed tools.
- Known-bad behavior is named clearly and may be marked pending only when a following Phase 0 task owns the fix.

Depends on: `P0-T01`.

### `P0-T03` — Canonical path and containment API

- [ ] Define a small path API for existing, missing, file, directory, and symlink targets.
- [ ] Canonicalize allowed roots once and targets before authorization.
- [ ] Require component-boundary containment, not string-prefix similarity.
- [ ] Reject `..` traversal and unexpected symlinks.
- [ ] Capture device/inode identity when a target is discovered.
- [ ] Recheck identity immediately before mutation.
- [ ] Define behavior for different volumes and unavailable mounts.

Required tests:

- [ ] direct child under an allowed root;
- [ ] sibling with the same textual prefix;
- [ ] `..` escape;
- [ ] symlink at the final component;
- [ ] symlink in an intermediate component;
- [ ] broken symlink;
- [ ] root replaced between discovery and mutation;
- [ ] whitespace, glob, leading dash, `#`, tab, newline, and Unicode filenames;
- [ ] forbidden exact roots and home itself.

Acceptance:

- Authorization answers are based on canonical identity and explicit allowed roots.
- No caller implements its own path-prefix check.

Depends on: `P0-T01`, characterization coverage from `P0-T02`.

### `P0-T04` — Secure reviewed-orphan input

- [ ] Disable `--remove-orphans-from` until the new validation path is active.
- [ ] Replace lexical root matching with the `P0-T03` containment API.
- [ ] Reject paths containing traversal or changed identities.
- [ ] Stop interpreting `#` inside a valid filename as an inline comment.
- [ ] Decide whether the temporary compatibility format remains line-based or becomes a versioned manifest immediately.
- [ ] Revalidate whitelist and allowed root immediately before every action.
- [ ] Report rejected entries with stable reason codes.

Acceptance:

- The original traversal case is a permanent regression test.
- A malformed review file cannot broaden deletion scope.
- Valid paths containing special characters are preserved exactly.

Depends on: `P0-T03`.

### `P0-T05` — Harden mutation primitives

- [ ] Route all filesystem removal through one checked operation layer.
- [ ] Separate `clear directory contents` from `remove path` policy.
- [ ] Never follow a directory symlink while clearing contents.
- [ ] Check command status and verify the postcondition.
- [ ] Count bytes only for successful actions.
- [ ] Record success, skipped, failed, and permission-denied separately.
- [ ] Return a partial-failure exit when any selected action fails.
- [ ] Add signal traps that record interruption without starting another action.

Acceptance:

- Failure injection cannot produce a false success message or inflated reclaimed total.
- Every direct `rm` in category code is removed or explicitly justified and tested.

Depends on: `P0-T03`.

### `P0-T06` — Make heuristic orphan discovery report-only

- [ ] Remove automatic mutation of all name/bundle-ID heuristic candidates.
- [ ] Replace `auto` wording with evidence/confidence wording.
- [ ] Keep weak, ambiguous, UUID, shared-vendor, and group-container candidates unselected.
- [ ] Report when Spotlight is unavailable/incomplete rather than interpreting absence as uninstall evidence.
- [ ] Add fixtures for renamed apps, beta/stable siblings, nested helpers, unavailable volumes, and shared vendor data.
- [ ] Update `--include-orphans` help and README semantics.

Acceptance:

- No orphan scan result can be deleted without a separately reviewed input path/manifest.
- A weak match is never described as owned by an uninstalled application.

Depends on: `P0-T02`; secure report consumption depends on `P0-T04`.

### `P0-T07` — Typed confirmations and force policy

- [ ] Define confirmation classes: read-only, recoverable, risky, and irreversible.
- [ ] Rename or constrain `--yes` so it skips safe/recoverable prompts only.
- [ ] Require an explicit separate flag and plan identifier for risky automation.
- [ ] Keep Trash emptying, Docker volume deletion, reviewed remnants, and permanent purge outside ordinary `--yes` behavior.
- [ ] Return a distinct user-cancelled exit code.
- [ ] Ensure non-TTY operation fails clearly when required confirmation is unavailable.

Acceptance:

- `--yes` alone cannot authorize any irreversible/risky category.
- Help, README, and behavior use identical terminology.

Depends on: `P0-T02`.

### `P0-T08` — Argument and configuration validation

Status: `[~]` partially complete — 2026-09-21 (Batch A subset)

- [x] Add helpers that require option values before reading `$2`. *(`require_arg`)*
- [x] Validate modes and known category IDs. *(`is_known_category`, `normalize_category_list`)*
- [x] Validate bounded non-negative integers for retention/staleness settings. *(`validate_int`, bound `VALIDATE_INT_MAX=36500`)*
- [x] Normalize comma lists and reject empty/duplicate/unknown values intentionally. *(see DEC-005)*
- [x] Validate configuration values using the same code as CLI values. *(`validate_config_values`)*
- [ ] Make config writes atomic with restrictive permissions. **Not started** — deferred, `save_config` still writes in place.
- [x] Define stable invalid-usage errors and exit code. *(see DEC-004)*

Acceptance:

- Missing values show usage errors, never Bash `unbound variable` messages.
- Malformed arithmetic/config input cannot reach comparisons or filesystem operations.

Depends on: `P0-T02`.

### `P0-T09` — Reclassify defaults and profiles

- [ ] Define risk facets: recoverability, data-loss risk, rebuild/download cost, and system impact.
- [ ] Establish a conservative Safe profile.
- [ ] Move Time Machine thinning, DeviceSupport pruning, old Homebrew versions, and broad app cache/log clearing out of unqualified defaults unless tests justify them.
- [ ] Split Homebrew downloads from installed-version cleanup.
- [ ] Document profile/category selection precedence.
- [ ] Add golden tests for profile contents.

Acceptance:

- A default clean performs only narrowly scoped, demonstrably regenerable actions.
- Moderate/system-impact work always appears as opt-in before plan/apply exists.

Depends on: `P0-T07`, `P0-T08`.

### `P0-T10` — Fix contained correctness defects

- [ ] Remove the duplicate QuickLook reset invocation.
- [ ] Audit each category for command status handling.
- [ ] Fix `.DS_Store` success accounting.
- [ ] Validate Android SDK image reference formats or make deletion report-only.
- [ ] Replace deprecated `launchctl unload` behavior with current, correctly scoped behavior where safe.
- [ ] Audit sparse-file size reporting and distinguish allocated from logical bytes.

Acceptance:

- Each fixed defect has a focused regression test.
- Unverified Android ownership cannot trigger deletion.

Depends on: `P0-T05` for shared action results.

### `P0-T11` — Static checks and CI

- [ ] Pin Bats-core, ShellCheck, and shfmt versions or installation methods.
- [ ] Add CI jobs for syntax, tests, ShellCheck, formatting, and documentation whitespace.
- [ ] Exercise macOS Bash 3.2 on a macOS runner.
- [ ] Keep Linux checks supplementary; they cannot replace macOS command/integration tests.
- [ ] Upload only redacted failure artifacts.

Acceptance:

- A pull request cannot merge when required checks fail.
- Tool-version updates are deliberate changes, not floating surprises.

Depends on: `P0-T01`; finalize after other Phase 0 tests exist.

### `P0-T12` — Documentation and safety contract parity

- [ ] Update README usage/default/risk tables.
- [ ] Document stable exit codes introduced in Phase 0.
- [ ] Document current limitations, permissions, and report-only orphan policy.
- [ ] Add a security/safety invariants document or initial `SECURITY.md`.
- [ ] Verify `--help`, README, tests, and behavior describe the same contract.

Acceptance:

- Every destructive category states target scope, recovery status, privilege, and confirmation behavior.

Depends on: all Phase 0 behavior tasks.

### Phase 0 exit gate

- [ ] All `P0-*` tasks complete.
- [ ] No heuristic orphan match is automatically deleted.
- [ ] No reviewed input can escape canonical allowed roots.
- [ ] `--yes` cannot approve risky/irreversible work.
- [ ] All mutations have verified results and accurate accounting.
- [ ] Test sentinels prove fixture containment.
- [ ] Bash 3.2, static checks, and CI pass.
- [ ] README/help match tested behavior.

## 8. Phase 1 — Modular CLI and machine interface

Phase objective: separate concerns without changing safety behavior, then expose a strict event protocol for future GUI and automation clients.

### `P1-T01` — Record module and compatibility decisions

- [ ] Decide final command placeholder/name for development.
- [ ] Record supported macOS and Bash versions.
- [ ] Decide whether JSON encoding is Bash-owned or delegated to a small native helper.
- [ ] Define sourceable-module rules and global-state boundaries.
- [ ] Define compatibility period for legacy `clean.sh` flags.

### `P1-T02` — Thin entry point

- [ ] Add `bin/cleanmymac` as the canonical entry point.
- [ ] Keep `clean.sh` as a compatibility shim during migration.
- [ ] Resolve library paths relative to the executable safely.
- [ ] Add install-tree and source-tree invocation tests.

### `P1-T03` — Extract core utilities

- [ ] Extract logging, sizing, path, validation, confirmation, and config modules one at a time.
- [ ] Keep each extraction behavior-neutral with characterization tests.
- [ ] Remove hidden dependence on source order where practical.

### `P1-T04` — Category registry and interface

- [ ] Define one registry source for ID, description, defaults, risk facets, requirements, and handler.
- [ ] Define category lifecycle: capability check, discover, summarize, plan candidate.
- [ ] Move categories into focused files gradually.
- [ ] Test duplicate IDs and invalid metadata.

### `P1-T05` — Stable exit codes and error model

- [ ] Define success, findings-only, invalid usage, partial failure, permission required, stale state, and user-cancelled codes.
- [ ] Give errors stable codes plus separate safe message/diagnostic detail.
- [ ] Keep human output useful while making automation deterministic.

### `P1-T06` — JSON Lines protocol v1

- [ ] Write JSON Schemas for requests/events.
- [ ] Implement `hello`, phase, candidate, warning, permission, error, and finished events.
- [ ] Add `--jsonl`, `--no-color`, and `--no-prompt`.
- [ ] Keep stdout protocol-only; send diagnostics to stderr.
- [ ] Add request IDs, sequence numbers, protocol version, engine version, and capability list.
- [ ] Reject unknown output modes and incompatible schemas.

### `P1-T07` — Cancellation and resumable run record

- [ ] Define interrupt semantics for scan versus mutation.
- [ ] Write an incomplete run record atomically.
- [ ] Mark terminal result only after verification.
- [ ] Test signals between and during mocked actions.

### `P1-T08` — Legacy compatibility and documentation

- [ ] Map legacy flags to new subcommands/options.
- [ ] Add deprecation messages without breaking scripts unexpectedly.
- [ ] Publish protocol and exit-code documentation.
- [ ] Add shell completion generation contract.

### Phase 1 exit gate

- [ ] Human CLI behavior remains covered.
- [ ] Modules are independently testable and source-safe.
- [ ] JSONL contract tests reject malformed/incompatible events.
- [ ] stdout/stderr and exit codes are stable.
- [ ] GUI can build read-only fixtures from the protocol.

## 9. Phase 2 — Plan, apply, quarantine, and restore

Phase objective: replace immediate mutation with a common transactional workflow.

### `P2-T01` — Plan schema v1

- [ ] Define immutable plan header, host/user binding, expiry, target identities, action IDs, risk, evidence, and expected bytes.
- [ ] Define deterministic serialization and plan digest/signature approach.
- [ ] Reject unknown schema versions.

### `P2-T02` — Planner API

- [ ] Convert discovered candidates into stable IDs.
- [ ] Build plans from candidate IDs, never caller-supplied paths.
- [ ] Recompute plan when selection changes.
- [ ] Store plans atomically with `0600` permissions.

### `P2-T03` — Apply preflight

- [ ] Verify plan digest, schema, age, host/user, canonical roots, file identity, whitelist, sharing, free space, and permissions.
- [ ] Reject changed targets and require a new plan.
- [ ] Print/apply only the exact plan action set.

### `P2-T04` — Quarantine executor

- [ ] Define run-ID storage and retention metadata.
- [ ] Prefer same-volume atomic moves.
- [ ] Define verified cross-volume copy/move behavior.
- [ ] Record original-to-quarantine mappings per action.
- [ ] Never count failed/skipped actions as reclaimed.

### `P2-T05` — Verify and history

- [ ] Verify postconditions per action.
- [ ] Store immutable result events linked to the plan.
- [ ] Implement `history` human and JSON output.
- [ ] Represent partial/interrupted runs explicitly.

### `P2-T06` — Restore

- [ ] Generate a restore plan.
- [ ] Detect occupied/changed original paths.
- [ ] Restore only verified quarantine identities.
- [ ] Append restore results without rewriting original history.

### `P2-T07` — Explicit purge

- [ ] Separate purge from clean/apply.
- [ ] Enforce retention and irreversible confirmation policy.
- [ ] Support per-run and selected-item purge plans.
- [ ] Verify and account for actual purge results.

### `P2-T08` — Pilot one low-risk category

- [ ] Choose a narrowly scoped disposable category.
- [ ] Implement discover → plan → apply → verify → restore → purge.
- [ ] Failure-inject every transition.
- [ ] Compare human and JSON summaries.

### Phase 2 exit gate

- [ ] One category completes the full transactional lifecycle.
- [ ] Stale/edited/replayed plans are rejected.
- [ ] Interrupted actions are visible and recoverable where possible.
- [ ] Restore works before explicit purge.

## 10. Phase 3 — Application inventory and evidence

Phase objective: reliably inspect applications and report potential remnants without uninstalling anything.

### `P3-T01` — Installed-app inventory

- [ ] Inventory standard and explicitly supplied app locations.
- [ ] Record canonical path and file identity.
- [ ] Handle unavailable volumes and incomplete Spotlight explicitly.
- [ ] Add `apps list` human/JSON output.

### `P3-T02` — Bundle and signing fingerprint

- [ ] Read bundle ID, name, version, executable, nested helpers, XPC services, extensions, and login items.
- [ ] Record signing identifier and Team ID where present.
- [ ] Reject Apple/system apps and ambiguous identities.

### `P3-T03` — Provenance inventory

- [ ] Detect Homebrew cask provenance.
- [ ] Detect App Store receipt presence.
- [ ] Correlate Installer package receipts/BOMs without forgetting or deleting them.
- [ ] Detect a vendor uninstaller as a report-only fact.

### `P3-T04` — Remnant evidence collectors

- [ ] Implement one known root at a time.
- [ ] Emit evidence facts rather than binary “owned/not owned” claims.
- [ ] Cover user support data, sandboxes, startup integration, logs/caches, and developer artifacts.
- [ ] Keep system locations report-only.

### `P3-T05` — Confidence and shared-use policy

- [ ] Implement authoritative, strong, corroborated, weak, and conflicting/shared classifications.
- [ ] Require multiple signals where appropriate.
- [ ] Veto group containers/shared updaters/sibling resources by default.
- [ ] Add adversarial and rebrand/shared-sibling fixtures.

### `P3-T06` — App inspection command

- [ ] Add `app inspect APP` with exact resolution rules.
- [ ] Show application footprint separately from attributable-data estimate.
- [ ] Explain every remnant and retained candidate.
- [ ] Export stable JSON for the future GUI.

### Phase 3 exit gate

- [ ] Inventory works without mutation.
- [ ] Ambiguous apps stop with choices.
- [ ] Weak/shared evidence cannot become a selected action.
- [ ] Fixture reports explain all associations.

## 11. Phase 4 — Reversible user-scope uninstall MVP

Phase objective: remove a plain application and strongly attributable user-scope data through immutable plans and quarantine.

### `P4-T01` — Uninstall modes and target resolution

- [ ] Implement exact path, exact bundle ID, cask token, and unambiguous-name resolution.
- [ ] Define `--keep-data` and `--purge-data` selections.
- [ ] Refuse system/Apple apps and changed identities.

### `P4-T02` — Running process handling

- [ ] Request normal app quit first.
- [ ] Detect remaining main/helper processes.
- [ ] Require explicit approval before termination.
- [ ] Never silently discard unsaved app state.

### `P4-T03` — User-scope uninstall plan

- [ ] Plan the app bundle, attributable user data, and supported user LaunchAgents.
- [ ] Retain weak/shared candidates.
- [ ] Show exact evidence, recovery status, and expected bytes.

### `P4-T04` — User-scope apply and verification

- [ ] Quarantine selected targets in dependency-safe order.
- [ ] Handle supported user LaunchAgents with current `launchctl` domains.
- [ ] Verify app absence and retained shared resources.
- [ ] Record failures and leftovers.

### `P4-T05` — Homebrew cask hand-off

- [ ] Detect installed cask token exactly.
- [ ] Distinguish ordinary uninstall from `--zap`.
- [ ] Preview delegated actions and preserve shared-resource warnings.
- [ ] Record external command results in common history.

### `P4-T06` — End-to-end restore

- [ ] Restore app bundle and quarantined user data.
- [ ] Handle original-path conflicts.
- [ ] Verify restored identity and report service limitations.

### Phase 4 exit gate

- [ ] Supported uninstall is fully plan-bound.
- [ ] User-created documents are excluded.
- [ ] Shared resources and installed siblings survive.
- [ ] Restore works end to end until explicit purge.

## 12. Phase 5 — Package provenance and privileged scope

Phase objective: handle system-installed components without turning the application into a general root deletion tool.

### `P5-T01` — Vendor uninstaller policy

- [ ] Verify identity and location before offering hand-off.
- [ ] Display exact executable/arguments and privilege implications.
- [ ] Never silently run arbitrary scripts discovered inside an app.

### `P5-T02` — Package receipt ownership graph

- [ ] Map receipt payloads to canonical paths.
- [ ] Detect paths owned by multiple installed receipts.
- [ ] Keep shared and uncertain payloads.
- [ ] Treat `pkgutil --forget` as bookkeeping after verified removal, not deletion.

### `P5-T03` — Privileged architecture decision

- [ ] Threat-model helper installation, update, XPC, caller identity, plan replay, and self-removal.
- [ ] Prototype current Service Management behavior on supported macOS versions.
- [ ] Choose native helper design and record the decision before implementation.

### `P5-T04` — Narrow helper protocol

- [ ] Accept typed, plan-bound actions only.
- [ ] Independently verify plan, caller, identity, canonical root, and ownership.
- [ ] Expose no arbitrary path deletion or command execution.
- [ ] Log exact results without secrets.

### `P5-T05` — System-scope plan/apply

- [ ] Add one supported system artifact class at a time.
- [ ] Request privilege only when applying exact reviewed actions.
- [ ] Test denial, cancellation, stale plans, partial failure, and rollback limitations.

### Phase 5 exit gate

- [ ] Independent security review passes.
- [ ] Shared receipt payloads remain protected.
- [ ] The helper cannot act outside plan-bound allowed operations.
- [ ] Helper update and self-removal are tested.

## 13. Phase 6 — Cleaner expansion and performance

Phase objective: add value after the common safe execution model is proven.

Candidate task queue:

- [ ] `P6-T01` Split Homebrew cache from old-version cleanup.
- [ ] `P6-T02` Add age-based Xcode archives/device logs.
- [ ] `P6-T03` Add tool-native SwiftPM cleanup/reporting.
- [ ] `P6-T04` Add iOS backup inventory and per-backup plans.
- [ ] `P6-T05` Add large-file reporting without deletion defaults.
- [ ] `P6-T06` Add duplicate-candidate reporting without auto-delete.
- [ ] `P6-T07` Add stale-download reporting without default deletion.
- [ ] `P6-T08` Add declarative cleaner-rule format, provenance, versioning, and fixtures.
- [ ] `P6-T09` Cache read-only metadata with safe invalidation.
- [ ] `P6-T10` Add bounded concurrency for discovery/sizing only.
- [ ] `P6-T11` Benchmark small/large home-directory scans and memory usage.

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

- [ ] Select a distinct project and command name after package/trademark checks.
- [ ] Define bundle/package IDs for future GUI/helper without colliding with the CLI.

### `P7-T02` — CLI installation

- [ ] Support source-tree use and a documented installed layout.
- [ ] Package completions, man page, license, changelog, and uninstall instructions.
- [ ] Add Homebrew formula/cask as appropriate.

### `P7-T03` — Upgrade and schema compatibility

- [ ] Migrate config/history safely.
- [ ] Keep at least one supported prior plan/history schema readable where promised.
- [ ] Refuse unsafe downgrades clearly.

### `P7-T04` — Security and privacy documentation

- [ ] Add `SECURITY.md`, threat model, privacy statement, support matrix, and disclosure path.
- [ ] Keep diagnostics local/redacted and telemetry off by default.

### `P7-T05` — Release verification

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

## 16. Verification commands

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

## 17. Open decisions

- [ ] `D-001` Keep Bash 3.2 for the entire engine or introduce a small Swift safety/JSON helper after Phase 1?
- [ ] `D-002` Use product-managed quarantine, macOS Trash, or both based on action type?
- [ ] `D-003` Sign plans cryptographically or rely on private storage, digest, host/user binding, and file identity?
- [ ] `D-004` What is the initial minimum supported macOS version?
- [ ] `D-005` How long should legacy `clean.sh` flags remain supported?
- [ ] `D-006` Which one low-risk category should pilot plan/apply/restore?
- [ ] `D-007` What is the final project/command name?

Resolve decisions only when their owning phase needs them. Do not let later-phase choices block Phase 0 safety work.

## 18. Decision log

| Date | ID | Decision | Reason | Affected tasks |
|---|---|---|---|---|
| 2026-09-14 | DEC-001 | CLI safety work takes priority over the GUI wrapper. | The GUI must not wrap unsafe or unstable mutation behavior. | All Phase 0-2 tasks |
| 2026-09-14 | DEC-002 | New uninstall behavior will use evidence-based plan/apply and recovery. | A broader name heuristic is not safe enough for app removal. | Phase 2-5 |
| 2026-09-14 | DEC-003 | Phase 0 avoids large modularization changes. | Small safety patches are easier to review and regression-test. | Phase 0-1 |
| 2026-09-21 | DEC-004 | All invalid usage exits `1`, not a new dedicated code. | `1` is already the documented exit for an unknown option and is asserted by an existing test. Introducing `2` would break a published contract for no safety gain. The stability the task asked for is delivered by a single `clean.sh: error: <msg>` prefix on stderr via `die_usage`. | `P0-T08` |
| 2026-09-21 | DEC-005 | Comma lists reject empty and unknown ids, but silently de-duplicate. | `--only caches,caches` is unambiguous and harmless, so erroring would be hostile. `--only ""` is almost always a shell-expansion accident, and running the full default set would be the worst possible reading of it. | `P0-T08` |
| 2026-09-21 | DEC-006 | An invalid config file fails the run even when the CLI overrides that same key. | Validating only the final effective value would let a broken config sit unnoticed until the day the flag is omitted. `--help` and `--list` still work, so the user can always reach the documentation that explains the fix. | `P0-T08` |
| 2026-09-21 | DEC-007 | The integer validator is named `validate_int` and accepts zero, rather than the planned `validate_positive_int`. | `--keep-logs 0` and `--keep-toolchains 0` are meaningful, so "positive" would have been an inaccurate name for the required behaviour. The task text asks for *bounded non-negative* integers. | `P0-T08` |

## 19. Blocker log

| Date | Task | Blocker | Needed to unblock | Status |
|---|---|---|---|---|
| — | — | No blockers recorded | — | — |

## 20. Discovery and parking lot

Add newly discovered work here before assigning it to a phase. Do not silently expand an in-progress task.

- [ ] Decide whether configuration lists must support commas/newlines in paths before the plan schema replaces them.
- [ ] Measure how Spotlight incompleteness should be surfaced to users.
- [ ] Research safe last-used application signals; do not infer from arbitrary file modification times.
- [ ] Define allocated versus logical byte reporting across APFS clones and sparse files.
- [ ] Determine how to expose Full Disk Access limitations without treating denial as an empty result.
- [ ] Audit the current project name before public packaging.
- [ ] `save_config` is not atomic and does not set restrictive permissions (remaining `P0-T08` item).
- [ ] No golden-file snapshot of `--list` yet; the category table is asserted only by spot-check (remaining `P0-T02` item).
- [ ] `save_config` round-trip is untested — only `load_config` and precedence are covered.
- [ ] ShellCheck and shfmt are documented in `tests/README.md` but not yet installed or wired into `tests/run`; the definition-of-done lint gate is therefore not enforced.
- [ ] Interactive TUI screens (category picker, settings, whitelist) have no automated coverage; they were verified manually through a pseudo-terminal.

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

## 22. Next-session handoff template

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
