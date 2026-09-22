# CleanMyMac CLI improvement and uninstaller plan

Status: proposed

Reviewed: 2026-09-14

Baseline: `clean.sh` (2,059 lines), macOS 26.6.2, system Bash 3.2.57

## 1. Objective

Turn the current script into a dependable macOS storage-management CLI with two clearly separated jobs:

1. **Cleaner:** find and remove regenerable caches, logs, build artifacts, and other selected disposable data.
2. **Uninstaller:** remove a selected application and its attributable remnants without deleting user-created documents or resources shared with other installed software.

The tool should remain dry-run-first, explain why every item was selected, support machine-readable output, and make destructive work recoverable whenever macOS permits it.

The uninstaller must not be implemented as a broader version of the current orphan-name heuristic. It needs an evidence model, an immutable removal plan, shared-resource checks, quarantine, verification, and recovery.

## 2. Current-state review

### What is already strong

- Scan mode is the default, and risky categories are visibly separated from normal categories.
- Quoting is generally careful, and deletion goes through two central helpers for most categories.
- The script avoids `sudo` and has an explicit list of paths it refuses to delete.
- Whitelists, per-category selection, interactive operation, logs, and space summaries are useful foundations.
- The orphan scanner distinguishes automatic candidates from review-only candidates.
- Xcode, Simulator, Android, Docker, Homebrew, and package-manager cleanup give the utility a useful developer focus.
- `/bin/bash -n clean.sh` passes under the actual macOS Bash 3.2 runtime.

### Findings to address before adding an uninstaller

| Priority | Finding | Evidence in current script | Required response |
|---|---|---|---|
| P0 | Reviewed orphan paths are authorized using a lexical prefix. A path containing `..` can pass the allowed-location `case` and resolve outside that location before `rm -rf`. | `process_orphans_review_file`, around lines 1284-1347 | Canonicalize first, require containment under canonical allow-roots, reject `..`, symlink traversal, mount changes, and stale identities. Disable reviewed-file deletion until fixed. |
| P0 | The `auto` orphan tier can delete data based mainly on a missing name/bundle-ID match. Rebrands, helper IDs, disabled Spotlight, apps on unavailable volumes, and shared vendor data can produce false positives. | `collect_orphan_candidates`, lines 513-550; `cat_orphans`, lines 1223-1281 | Make all heuristic matches report-only. Only authoritative or multiple independent strong signals may become selectable for removal. |
| P0 | ~~`--yes` makes every `confirm` return success, including Trash, Docker volumes, stale virtual devices, and orphan deletion. This conflicts with the documentation's stronger confirmation language.~~ **Resolved 2026-09-22 (`P0-T07`).** | `confirm`, lines 646-654 | Done: four confirmation classes in `lib/confirm.sh`. `--yes` answers recoverable prompts only; risky/irreversible work needs a terminal confirmation or `--force-risky <action-id>`. The identifier is the action id rather than a plan id, because plans are `P2-T01` and do not exist yet (DEC-030). |
| P0 | Deletion is immediate and normally irreversible. There is no transaction manifest, quarantine, rollback, or stale-plan check. | `clear_dir_contents` and `remove_path`, lines 572-644 | Introduce plan/apply/verify/restore. Move eligible targets to a per-run quarantine before permanent purge. |
| P1 | Safety checks protect only a short exact-path list. They do not enforce that a category stays inside its declared roots, and directory symlinks can redirect content-clearing operations. | `resolve_path`, `is_forbidden`, and `clear_dir_contents`, lines 323-605 | Give each operation explicit canonical roots and use `lstat`/device/inode checks immediately before mutation. Never follow a directory symlink during content cleanup. |
| P1 | Several broad or consequential operations are enabled by default or labelled `safe`: all user app caches/logs, old Homebrew versions, DeviceSupport pruning, and local Time Machine thinning. | `category_info`, lines 703-734 | Adopt `safe`, `rebuild-cost`, `data-loss`, and `system-impact` dimensions. Keep only narrowly regenerable, well-tested actions in the default profile. |
| P1 | Argument values are read from `$2` without checking that a value exists, and numeric/category values are not validated centrally. | argument parser, lines 1684-1744 | Build parser helpers, validate enums and bounded integers, reject unknown category IDs, and return documented exit codes with actionable errors. |
| P1 | Removal failures can still be reported and counted as successful. `.DS_Store` accounting assumes every `rm` succeeded; `remove_path` adds the pre-delete size without checking the result. | lines 640 and 861 | Check every action, record per-item result/error, measure after mutation, and return partial-failure status when appropriate. |
| P1 | Android image ownership parsing assumes slash-separated `image.sysdir.*` values and should not be trusted for deletion across SDK/AVD versions without fixtures. | `cat_android`, lines 1506-1554 | Prefer `sdkmanager`/`avdmanager` metadata where available; otherwise normalize every supported format and downgrade unknown formats to report-only. |
| P2 | QuickLook reset runs the same command twice. | lines 881-882 | Remove the duplicate call and test command invocation counts. |
| P2 | A single 2,059-line script couples parsing, UI, discovery, policy, execution, and reporting. There are no automated tests. | repository structure | Split the implementation into testable modules and introduce fixtures, mocks, static analysis, and macOS integration tests. |
| P2 | Logs/configuration lack an explicit format version, restrictive permissions, retention policy, and redaction rules. | `log_init`, `load_config`, `save_config` | Version persisted formats, use `0700` directories and `0600` files, redact user paths in telemetry, and add retention controls. |

Static review note: ShellCheck and shfmt were not installed in the review environment, so they still need to be run as part of Phase 0. There are currently no repository tests.

## 3. Product and command model

Use a stable subcommand interface. Preserve old flags temporarily through a compatibility shim that prints migration guidance.

```text
cleanmymac scan [--profile safe|developer|custom] [--category ID] [--json]
cleanmymac clean plan [selection options] [--output PLAN]
cleanmymac clean apply PLAN [--yes-safe]

cleanmymac apps list [--source app|brew|pkg|all] [--json]
cleanmymac app inspect APP [--json]
cleanmymac app uninstall plan APP [--keep-data|--purge-data] [--output PLAN]
cleanmymac app uninstall apply PLAN [--quarantine-days N]

cleanmymac remnants scan [APP] [--json]
cleanmymac remnants plan [APP] [--output PLAN]
cleanmymac remnants apply PLAN

cleanmymac history [--json]
cleanmymac restore RUN_ID
cleanmymac purge RUN_ID
cleanmymac doctor
cleanmymac config get|set|reset
cleanmymac completion bash|zsh|fish
```

`APP` must resolve to exactly one installed application through an absolute `.app` path, exact bundle ID, installed Homebrew cask token, or an unambiguous app name. Ambiguous names must stop and list choices.

Recommended semantics:

- `scan` never mutates user or system data. It may create only its own private cache/log files.
- `plan` records proposed actions but performs no target mutation.
- `apply` accepts only a valid, unexpired plan produced on the same Mac/user and revalidates every target.
- `--keep-data` removes the application and its launch integration while retaining preferences and user data.
- `--purge-data` adds attributable support data after a second, explicit review.
- `restore` moves quarantined items back when their original paths are unoccupied.
- `purge` permanently deletes a quarantined run after its retention period or explicit confirmation.

Before a public release, choose a distinct product/command name after checking package-name and trademark availability; “CleanMyMac” is already strongly associated with an existing macOS product. The placeholder command above mirrors the current repository only.

## 4. Target architecture

### Near-term Bash layout

```text
bin/cleanmymac                 # thin entry point
lib/core/args.sh               # parsing and validation
lib/core/paths.sh              # canonicalization and containment
lib/core/log.sh                # human + structured events
lib/core/plan.sh               # manifest creation and validation
lib/core/executor.sh           # quarantine/apply/restore/purge
lib/core/policy.sh             # risk and confidence decisions
lib/platform/macos.sh          # macOS version and capability checks
lib/discovery/apps.sh          # app inventory and identity
lib/discovery/receipts.sh      # Homebrew/pkg provenance
lib/discovery/remnants.sh      # candidate evidence collection
lib/categories/*.sh            # one cleaner category per module
tests/unit/*.bats
tests/integration/*.bats
tests/fixtures/
```

All library files must be sourceable without executing the program. Commands should return data rather than printing directly; one presentation layer should render text, JSON, or interactive output.

### Language decision gate

Bash 3.2 is acceptable for the cleaner's orchestration layer, but safe path identity, structured manifests, Unicode filenames, concurrent filesystem changes, and modern macOS Service Management are increasingly awkward in shell.

After Phase 1, prototype one narrow native helper in Swift for:

- filesystem URL canonicalization and non-following file operations;
- atomic quarantine/restore with file identity checks;
- application bundle/signing metadata;
- modern login-item/service inspection where public APIs allow it;
- JSON plan validation.

Keep the user experience as one CLI regardless of implementation language. Proceed to a full Swift core only if the helper materially reduces risk and can be distributed as a signed/notarized universal binary without adding runtime dependencies. Do not let a rewrite delay the P0 fixes.

## 5. Uninstaller design

### 5.1 Resolve and fingerprint the application

For the selected `.app`, record:

- canonical URL, filesystem device/inode, size, and modification time;
- `CFBundleIdentifier`, display name, executable name, version, and vendor fields from `Info.plist`;
- signing identifier and Team ID from the code signature;
- nested apps, XPC services, app extensions, login items, frameworks, and helper bundle IDs;
- App Store receipt presence;
- matching Homebrew cask and matching Installer package receipts;
- mounted volume and whether the target is writable/removable.

Reject Apple/system applications, anything in `/System`, ambiguous targets, broken bundle metadata, and targets whose identity changes between inspect, plan, and apply. A signing identifier alone is not proof of ownership; Apple notes that secure identity checks also need signer/category constraints.

### 5.2 Prefer authoritative uninstall mechanisms

Use this precedence order:

1. **Vendor-provided uninstaller:** detect and offer it first, displaying its identity and exact command. Do not silently execute an untrusted script from inside an app bundle.
2. **Homebrew cask:** delegate to `brew uninstall --cask`; offer `--zap` separately because Homebrew warns that zap rules can remove shared resources.
3. **Installer package:** use `pkgutil` receipts/BOMs to inventory payload paths and detect shared ownership. `pkgutil --forget` removes only receipt metadata, not installed files, so it is a final bookkeeping action rather than an uninstaller.
4. **Plain app bundle:** use the tool's evidence-backed bundle/remnant plan.

Apple also recommends using an application's own uninstaller when it provides one, since it may know about login items, extensions, and data elsewhere on disk.

### 5.3 Collect remnant evidence

Classify every candidate by evidence, not merely by name.

| Confidence | Example evidence | Default policy |
|---|---|---|
| Authoritative | Homebrew cask uninstall/zap stanza; exact package-receipt payload; vendor manifest/uninstaller | Selectable, still previewed |
| Strong | Exact bundle ID in a known per-app location plus matching signing Team ID/vendor; container metadata that points to the app; helper embedded in the selected bundle | Selectable for `--purge-data` after shared-use check |
| Corroborated | Two independent signals such as exact bundle ID and matching executable/launch-service reference | Selectable with warning |
| Weak | Display-name, substring, normalized-name, or modification-time match only | Report-only; never selected automatically |
| Conflicting/shared | Used by an installed sibling, another receipt, a group container, shared updater, common vendor directory, or unknown owner | Keep by default; require per-item override |

Inspect at least these scopes:

- App bundles: `/Applications`, `~/Applications`, and an explicitly supplied path.
- User data: `~/Library/Application Support`, `Caches`, `Preferences`, `Saved Application State`, `WebKit`, `HTTPStorages`, `Cookies`, `Logs`, `Application Scripts`, and crash reports.
- Sandboxes: `~/Library/Containers` and `~/Library/Group Containers`; group containers are shared until proven otherwise.
- Startup integration: user LaunchAgents, legacy login items, bundled helpers, and modern background-item/service metadata that public macOS interfaces expose.
- System scope, report-only until elevated apply: `/Library/Application Support`, `LaunchAgents`, `LaunchDaemons`, `PrivilegedHelperTools`, relevant plug-in directories, and package receipts.
- Developer/CLI artifacts: authoritative package-manager links, completions, man pages, and command wrappers.

Never auto-select user-created documents, projects, exports, media libraries, browser profiles, cloud-synced data, keychain items, or files outside known application-support scopes. Warn that uninstalling an app does not cancel a subscription and may leave documents that require the app to open.

### 5.4 Handle running software and services

Before mutation:

1. Ask the application to quit normally and allow it to present save dialogs.
2. Recheck for the main executable and attributable helpers.
3. Offer termination only after an explicit warning if processes remain.
4. Use current `launchctl bootout` domain targets for legacy LaunchAgents/Daemons instead of deprecated `unload` behavior.
5. Treat modern Service Management login items separately. macOS 13+ apps can register helpers through `SMAppService`; deleting a plist is not a complete model for them.
6. Never unload a shared service merely because its label contains the app's display name.

### 5.5 Plan manifest

Write a versioned JSON plan with restrictive permissions. Each action should contain at least:

```json
{
  "schema_version": 1,
  "plan_id": "UUID",
  "created_at": "RFC3339 timestamp",
  "host_id_hash": "non-reversible host binding",
  "uid": 501,
  "mode": "app-uninstall",
  "target": {
    "path": "/Applications/Example.app",
    "bundle_id": "com.example.app",
    "team_id": "TEAMID"
  },
  "actions": [
    {
      "action": "quarantine",
      "path": "/Users/me/Library/Caches/com.example.app",
      "canonical_path": "/Users/me/Library/Caches/com.example.app",
      "device": 1,
      "inode": 123,
      "size_bytes": 456,
      "evidence": ["exact-bundle-id", "team-id-match"],
      "confidence": "strong",
      "shared": false,
      "requires_admin": false
    }
  ]
}
```

The plan must be deterministic, human-readable, and hashable. `apply` must reject expired plans, unknown schema versions, changed targets, replaced symlinks, changed device/inode pairs, newly shared resources, and actions outside declared canonical roots.

Paths in machine-readable manifests must not use line-oriented parsing. macOS filenames can contain spaces, tabs, newlines, `#`, and shell metacharacters.

### 5.6 Quarantine, verify, and restore

- Default to quarantine rather than `rm -rf` for app uninstall and remnant removal.
- Prefer an atomic move on the same APFS volume. If crossing volumes, copy, verify metadata/content, then remove the source only after success.
- Store quarantined content by run ID with a manifest mapping original to stored locations.
- Keep it for a configurable period, for example 7 or 14 days.
- Verify that services are no longer loaded, the app bundle is absent, selected remnants moved successfully, and expected shared items remain.
- Report exact reclaimed space from successful actions only.
- Restore only if the original path is free and the stored identity matches; otherwise stop and explain the conflict.
- Permanent purge is a separate irreversible command and never part of a default uninstall.

For system-owned files, build a minimal privileged action list and request authorization only during `apply`. Never run the entire CLI as root, never interpolate shell command strings, and never broaden permissions recursively.

## 6. Cleaner improvements beyond uninstalling

### Safety and accuracy

- Replace “safe/risky” with risk facets: recoverability, rebuild/download cost, personal-data risk, and system impact.
- Make the default `safe` profile conservative; move Time Machine thinning, DeviceSupport pruning, global cache clearing, and old Homebrew version deletion into opt-in profiles.
- Add age and size thresholds (`--older-than`, `--larger-than`) where meaningful.
- Detect active applications before clearing their cache/log directories.
- Base reclaim estimates on allocated bytes and report logical size separately for sparse files such as Docker disks.
- Record skipped, failed, quarantined, purged, and restored bytes separately.
- Add disk-space preflight and APFS/local-snapshot explanations without promising instantly visible Storage UI changes.

### Useful new categories

Add only with fixtures and documented ownership rules:

- Xcode archives by age, old device logs, documentation caches, and unavailable runtimes.
- Homebrew download cache separately from old installed versions.
- Derived build caches for SwiftPM, Gradle, CocoaPods, npm/Yarn/pnpm, and supported IDEs, with tool-native cleanup preferred.
- iOS device backups: inventory and size reporting first; deletion only by explicit backup ID.
- Large-file and duplicate-candidate reporting. Do not auto-delete duplicates because identical content can have different ownership/value.
- Stale downloads reporting by age/size, never default deletion.
- Trash inventory with per-volume awareness and quarantine retention integration.
- Plugin-style app cleaners stored as declarative, versioned rules with tests and provenance.

### CLI quality

- Stable exit codes: success, findings-only, invalid usage, partial failure, permission required, stale plan, and user cancellation.
- `--json`/JSON Lines output on stdout; human progress and diagnostics on stderr.
- `--no-color`, `--quiet`, `--verbose`, and `--debug` with consistent behavior.
- Zsh/Bash/Fish completions, a man page, examples, and `cleanmymac doctor` capability output.
- `--version` including plan schema and build information.
- Configuration migration and `config validate`.
- Signal traps that leave a valid interrupted-run record and never strand a half-written manifest.

## 7. Testing and verification strategy

Use Bats-core because it supports Bash 3.2 and provides isolated TAP-compatible shell tests. Run ShellCheck with a pinned version and shfmt in CI.

### Unit tests

- argument presence, numeric bounds, category validation, and exit codes;
- canonical containment and exact forbidden-root behavior;
- symlinks at every path component, `..`, mount boundaries, and target replacement between plan/apply;
- filenames containing whitespace, glob characters, leading dashes, `#`, tabs, newlines, and non-ASCII text;
- bundle ID/name normalization without unsafe substring promotion;
- confidence-policy decisions and shared-resource vetoes;
- plan schema, hashing, expiry, host/user binding, and stale identity rejection;
- accurate accounting for successful, skipped, and failed mutations.

### Fixture and mocked-command tests

- Override `HOME` with a disposable fixture and prepend mocked `brew`, `pkgutil`, `mdfind`, `mdls`, `codesign`, `launchctl`, `xcrun`, `docker`, and package-manager commands to `PATH`.
- Cover ordinary apps, renamed apps, beta/stable siblings, suites, shared vendor updaters, group containers, nested helpers, Homebrew casks, Installer receipts, and malicious manifests.
- Make every destructive test assert that sentinel files outside allowed fixture roots survive.
- Inject failures at each executor step and verify that the run is resumable or restorable.

### macOS integration tests

- Run on supported macOS versions in disposable VMs/snapshots and on both Intel and Apple Silicon where supported.
- Install controlled signed test apps through drag-copy, Homebrew cask, and `.pkg` paths.
- Verify normal quit, stubborn process, LaunchAgent, LaunchDaemon, login item, helper, receipt, shared resource, quarantine, restore, and purge flows.
- Test Full Disk Access/permission-denied behavior without weakening protections.
- Require a manual release checklist for destructive flows until the test matrix is mature.

### Core safety properties

Every release must prove:

1. Scan and plan do not mutate target data.
2. No action can escape its canonical allowed roots.
3. System and Apple apps are refused.
4. Weak heuristic matches are never automatically selected.
5. Shared resources are preserved by default.
6. An app-uninstall apply is restorable until explicit purge.
7. A stale or edited plan cannot silently broaden its scope.
8. Failures are visible in output, exit status, history, and byte accounting.

## 8. Delivery roadmap

### Phase 0 — Safety stabilization

Deliverables:

- Fix canonical containment, symlink handling, reviewed-file parsing, and per-action error accounting.
- Change current orphan auto-removal to report-only.
- Separate safe confirmation bypass from risky-force authorization.
- Validate every CLI/config value and fix the duplicate QuickLook call.
- Add Bats, ShellCheck, shfmt, and CI; write regression tests for every P0/P1 finding.
- Reclassify default categories conservatively and reconcile README promises with behavior.

Exit criteria: all core safety properties applicable to the current cleaner pass; no heuristic orphan path is automatically deleted.

### Phase 1 — Plan/apply foundation

Deliverables:

- Modularize the core without changing intended behavior.
- Implement versioned JSON plans, canonical target identities, structured event logs, stable exit codes, and `--json`.
- Add quarantine, history, restore, and purge primitives.
- Add crash/signal recovery and restrictive storage permissions.

Exit criteria: existing cleaner categories operate through the common planner/executor and can be safely failure-injected in tests.

### Phase 2 — Application inventory and inspection

Deliverables:

- `apps list` and `app inspect` with exact app resolution.
- Bundle, signing, nested-helper, Homebrew, App Store receipt, and package-receipt inventory.
- Evidence scoring, shared-resource detection, and human/JSON reports.
- Remnant discovery that is report-only in this phase.

Exit criteria: fixture and real-machine samples explain every association and never claim weak evidence is ownership.

### Phase 3 — User-scope uninstall MVP

Deliverables:

- Plan/apply for plain `.app` bundles and strongly attributable user-library remnants.
- Normal quit and user LaunchAgent handling.
- `--keep-data` and `--purge-data` modes.
- Quarantine, post-apply verification, restore, and delayed purge.
- Homebrew cask delegation with a separate, clearly warned zap choice.

Exit criteria: app removal is reversible, user documents are excluded, shared siblings remain functional, and adversarial path tests pass.

### Phase 4 — Package and privileged remnants

Deliverables:

- Vendor-uninstaller discovery/hand-off.
- Package receipt/BOM inventory with shared-payload checks.
- Minimal privileged executor for explicitly reviewed system-scope actions.
- LaunchDaemon, privileged helper, and supported service-management handling.

Exit criteria: privilege is requested only for exact manifest actions; shared package files and unrelated services survive all tests.

### Phase 5 — Cleaner expansion and UX

Deliverables:

- Conservative profiles, thresholds, new developer cleanup categories, and large-file/reporting tools.
- Completions, man page, `doctor`, config migration, clearer summaries, and machine-readable output documentation.
- Performance work: one inventory pass, bounded concurrency for read-only sizing, and cached metadata invalidated safely.

Exit criteria: scan performance and estimates are measured on small and large home directories; each category has ownership documentation and fixtures.

### Phase 6 — Distribution and trust

Deliverables:

- Final product name and command.
- Homebrew distribution; if a native binary is adopted, universal signing/notarization and reproducible release checks.
- `SECURITY.md`, threat model, privacy statement, support matrix, changelog, and release rollback procedure.
- Opt-in, path-redacted diagnostics only; no telemetry by default.

Exit criteria: a clean install/uninstall of this CLI leaves no undocumented files and release artifacts pass the full safety matrix.

## 9. Recommended first implementation slice

Do not begin with app deletion. The first pull request should be narrowly scoped to:

1. add the test harness and mock filesystem;
2. reproduce the reviewed-path traversal and symlink escape cases as failing tests;
3. implement canonical root containment and pre-mutation identity checks;
4. make orphan discovery report-only;
5. introduce typed confirmations so `--yes` cannot authorize risky operations;
6. validate CLI arguments and correct error accounting;
7. update README safety claims.

The second slice should introduce the common plan/quarantine/restore executor for one low-risk category. Only after that path is proven should application inspection and uninstall planning be added.

## 10. Definition of done for the uninstaller

The uninstall feature is ready for general use only when:

- a user can identify an app unambiguously and preview every proposed action and reason;
- authoritative, strong, weak, and shared evidence are visibly distinguished;
- the app bundle and selected user-scope remnants are quarantined, not immediately erased;
- user documents and uncertain/shared resources are retained;
- running processes and supported launch integrations are handled without silent data loss;
- changed filesystem targets invalidate the plan instead of being followed;
- partial failures produce a nonzero exit and a precise resumable/restorable history record;
- restore and explicit permanent purge are tested end to end;
- Homebrew/vendor/package uninstall paths are delegated or handled according to their provenance;
- documentation covers permissions, Full Disk Access limitations, subscriptions, backups, and recovery.

## 11. References

- [Apple Support: Delete or uninstall apps on Mac](https://support.apple.com/en-gb/102610) — vendor uninstallers, quitting apps, Trash behavior, documents, subscriptions, and protected system apps.
- [Apple Developer: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) — current macOS registration/control model for login items, LaunchAgents, and LaunchDaemons.
- [Apple Developer: SigningIdentifier](https://developer.apple.com/documentation/lightweightcoderequirements/signingidentifier) — why an identifier alone is not sufficient secure identity evidence.
- [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) — uninstall/zap semantics, package receipts, services, login items, and shared-resource warnings.
- [Homebrew man page](https://docs.brew.sh/Manpage) — supported cask uninstall and `--zap` behavior.
- [Bats-core](https://github.com/bats-core/bats-core) — Bash 3.2-compatible test framework.
- [ShellCheck](https://github.com/koalaman/shellcheck) — static analysis for shell correctness and portability.
