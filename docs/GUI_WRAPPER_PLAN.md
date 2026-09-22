# Future macOS GUI wrapper plan

Status: proposed

Reviewed: 2026-09-14

Depends on: [CLI improvement and uninstaller plan](IMPROVEMENT_PLAN.md)

## 1. Objective

Build a simple, trustworthy macOS GUI around the cleaner and uninstaller while preserving the CLI as a fully supported product.

The GUI should make scanning, reviewing, cleaning, uninstalling, restoring, and understanding disk usage approachable for people who do not want to operate a terminal. It must not duplicate or weaken the engine's safety rules.

Recommended implementation:

- a native SwiftUI macOS application with focused AppKit integration where needed;
- the CLI/core as the only discovery, policy, plan, and execution engine;
- a versioned JSON/JSON Lines protocol between the app and engine;
- direct Developer ID distribution, signing, hardened runtime, and notarization;
- a separately authorized, narrowly scoped service only for future system-level actions.

The first GUI release should support user-scope scanning, cleaning, application inspection, plan review, quarantine, and restore. Permanent deletion, package receipts, and privileged remnants should arrive only after the CLI safety foundation is complete.

## 2. Non-negotiable design principles

1. **One engine, two interfaces.** Terminal and GUI invoke the same plan/apply policy and produce equivalent results.
2. **The GUI never deletes paths directly.** It submits selections to the engine, receives an immutable plan, and applies that exact plan ID.
3. **Preview before mutation.** Every clean or uninstall begins with a scan and a reviewable plan.
4. **Recovery first.** Eligible items go to quarantine or the macOS Trash before permanent purge.
5. **Explain every candidate.** Show size, location, evidence, risk, sharing status, and expected recovery cost.
6. **No fake certainty.** Weak heuristic matches remain visibly uncertain and unselected.
7. **Least privilege.** The main app runs as the signed-in user. A helper, if later required, accepts only narrow, validated operations.
8. **No shell-string execution.** Launch a fixed executable with an argument array; never build commands for `/bin/sh -c` or `eval`.
9. **No automatic destructive scheduling.** A future scheduler may scan and notify, but must not silently delete or uninstall.
10. **Accessible by default.** Every workflow must support VoiceOver, keyboard navigation, reduced motion, high contrast, and macOS text scaling.

## 3. Prerequisites and dependency gates

The production GUI must not be connected directly to the current `clean.sh`. UI prototyping can start with a mock engine, but real mutations require these CLI milestones:

| GUI capability | Required CLI milestone |
|---|---|
| Read-only dashboard prototype | Stable mock event schema |
| Real scan results | Versioned `--json`/JSON Lines output and stable exit codes |
| Cleaning | Plan/apply foundation, canonical containment, accurate action results |
| App inspection | Exact app identity and evidence-based remnant inventory |
| App uninstall | Quarantine/restore plus user-scope uninstall MVP |
| System remnants | Minimal privileged executor and package/shared-resource checks |
| Public release | Full safety matrix, signed artifacts, migration and recovery testing |

Before GUI implementation begins, Phase 0 of the CLI plan must fix path traversal, symlink handling, risky confirmation bypass, heuristic auto-deletion, argument validation, and inaccurate success accounting.

## 4. Proposed architecture

```text
┌────────────────────────────────────────────────────────────┐
│ SwiftUI macOS app                                         │
│ Views → ViewModels → Application Services                 │
└──────────────────────────────┬─────────────────────────────┘
                               │ typed requests/events
┌──────────────────────────────▼─────────────────────────────┐
│ Engine client                                              │
│ Process runner · protocol decoder · cancellation · logs   │
└──────────────────────────────┬─────────────────────────────┘
                               │ argv + JSON Lines
┌──────────────────────────────▼─────────────────────────────┐
│ CLI/core engine                                            │
│ discover → classify → plan → validate → apply → verify    │
└───────────────┬──────────────────────────────┬─────────────┘
                │ user-scope actions           │ plan-bound IPC
┌───────────────▼──────────────┐  ┌────────────▼─────────────┐
│ Quarantine/history store    │  │ Privileged helper        │
│ manifests · results · undo  │  │ future, narrow API only  │
└──────────────────────────────┘  └──────────────────────────┘
```

### Ownership boundaries

| Component | Owns | Must not own |
|---|---|---|
| SwiftUI app | navigation, selections, explanations, progress, accessibility | path authorization, ownership inference, raw deletion |
| Engine client | process lifecycle, protocol validation, cancellation, event routing | cleanup policy or plan editing |
| CLI/core | discovery, confidence/risk policy, manifests, validation, execution, verification | GUI state and presentation |
| Privileged helper | exact approved system-scope actions | scanning, arbitrary command execution, general filesystem access |
| History store | immutable plans/results and quarantine mappings | silent retention/purge decisions |

The app must remain useful when the privileged helper is absent or authorization is declined. User-scope features should not depend on elevated access.

## 5. Engine protocol

### 5.1 Invocation

During the transition, bundle the Bash engine as a signed app resource and start it with Foundation `Process` using fixed executable URLs and separate argument values. A future native engine can replace it without changing the UI protocol.

Requirements:

- use absolute paths to the bundled engine and `/bin/bash` only while the engine is a script;
- never search the user's `PATH` for the main engine;
- use a minimal, explicit environment and a controlled `PATH` for approved macOS tools;
- run non-interactively (`--no-prompt`, `--no-color`, `--jsonl`);
- send human-readable diagnostics to structured events, not mixed terminal output;
- cap individual event size and total buffered output;
- preserve stderr separately for crash diagnostics;
- generate and pass a request ID for correlation.

Do not expose a “custom command” or raw-arguments field in the GUI.

### 5.2 Version handshake

The first event must identify protocol and engine compatibility:

```json
{
  "type": "hello",
  "protocol_version": 1,
  "engine_version": "0.2.0",
  "plan_schema_version": 1,
  "request_id": "UUID",
  "capabilities": ["scan", "plan", "quarantine", "restore"]
}
```

The GUI must reject unsupported protocol/plan versions and show a repair/update action. Do not attempt best-effort parsing of unknown destructive-action schemas.

### 5.3 Event types

Use one JSON object per line with a required `type`, `request_id`, sequence number, and timestamp. Initial event set:

- `hello` — version and capabilities;
- `phase_started` / `phase_finished` — discovery, sizing, planning, applying, verifying;
- `candidate` — one cleaner/remnant candidate with evidence and risk;
- `progress` — completed/total work where total is genuinely known;
- `permission_required` — affected scope and remediation instructions;
- `warning` — recoverable concern or downgrade to report-only;
- `plan_ready` — plan ID, expiry, summary, and manifest location;
- `action_started` / `action_result` — apply progress and exact outcome;
- `run_finished` — totals, exit classification, and history ID;
- `error` — stable error code, safe user message, and optional diagnostic ID.

All byte values must be integers; format them for display in the app. Paths remain full-fidelity data and must not be line-parsed or interpolated into shell commands.

### 5.4 Selection and plan integrity

The GUI may maintain checkboxes by candidate ID, not by path. When a selection changes, it asks the engine to create a new plan from those IDs. It must never edit a plan JSON file or append paths to it.

Before apply, display:

- plan ID and age;
- selected and retained item counts;
- recoverable versus irreversible actions;
- required privileges;
- total allocated and logical bytes;
- conflicts, weak evidence, and shared resources;
- quarantine retention and restore limitations.

The engine revalidates the plan at apply time. A changed/stale target returns a new finding and requires a new plan; the GUI must not offer “continue anyway” unless the engine explicitly supports a narrowly scoped, separately reviewed override.

### 5.5 Cancellation and crashes

- Scans may be cancelled immediately.
- Apply cancellation is cooperative between atomic actions, not during an in-flight move/delete.
- Send an interrupt request first and wait for an acknowledgement; do not immediately kill the engine.
- If the app or engine exits during apply, reopen the run as “interrupted” and offer verify/resume/restore based on the manifest.
- Never display a run as successful until the terminal `run_finished` event and exit status agree.

## 6. Information architecture

Use a standard macOS sidebar with these destinations:

### Dashboard

- storage overview and last successful scan;
- primary “Scan Mac” action;
- current safe-profile estimate;
- recent clean/uninstall runs;
- permission or engine-health notices;
- no exaggerated gauges or health scores without a defensible calculation.

### Cleaner

- categories grouped by System, Applications, Developer, Package Managers, Virtualization, and Other;
- profile picker (`Safe`, `Developer`, `Custom`);
- category size, item count, risk facets, and rebuild/download cost;
- expandable candidate rows with full paths and reasons;
- filters for size, age, confidence, and recoverability;
- “Reveal in Finder” and copy-path actions;
- plan summary before any Apply button becomes available.

### Applications

- searchable installed-app grid/list with icon, name, version, source, last-used signal when reliably available, app size, and attributable-data estimate;
- sorting by total footprint, app size, name, and source;
- exact app detail page showing bundle identity, provenance, helpers, and candidate remnants;
- drag-and-drop of an `.app` bundle into the window as an inspection shortcut;
- separate `Keep app data` and `Remove attributable app data` choices;
- shared/uncertain remnants retained and explained by default.

### Remnants

- orphan/remnant scan results grouped by confidence;
- authoritative/strong, weak, and shared/conflicting sections;
- weak items are unselected and cannot be bulk-selected;
- evidence inspector showing which identifiers, receipts, metadata, or rules produced the association;
- ability to whitelist or suppress a candidate without deleting it.

### History and Recovery

- every plan/apply/restore/purge run with time, status, bytes, and engine version;
- quarantined items with expiration date and original location;
- Restore, Reveal, Export Report, and eligible Purge actions;
- partial/interrupted runs clearly separated from successful runs;
- path conflicts shown before restore.

### Settings

- default cleanup profile and thresholds;
- quarantine retention and optional reminders;
- whitelist management;
- scan-only notification schedule, if later enabled;
- appearance, accessibility, log retention, and privacy controls;
- engine version, protocol version, and diagnostic tools;
- never place irreversible “purge now” beside ordinary preference toggles.

### Help and Diagnostics

- permission status and guided remediation;
- engine health/capabilities from `doctor`;
- open logs, export a redacted support bundle, and verify installation;
- links to safety model, recovery instructions, limitations, and changelog.

## 7. Primary workflows

### 7.1 First launch

1. Explain that the app scans locally and does not delete during scanning.
2. Show privacy policy and default no-telemetry position.
3. Run a non-mutating engine/version/permission check.
4. Explain missing permissions in context; do not demand broad access before the user chooses a feature needing it.
5. Offer a Safe Profile scan.

Do not use a single “Grant all permissions” onboarding step. Apple requires users to grant Full Disk Access themselves in System Settings, and the app must remain defensive when access is absent.

### 7.2 Scan and clean

1. User chooses a profile or categories.
2. App starts a read-only scan and streams structured findings.
3. Results are grouped by risk and recoverability.
4. User adjusts candidate selections.
5. Engine produces a plan; GUI displays the exact summary.
6. User confirms recoverable actions.
7. Engine applies and verifies; GUI shows per-action results.
8. History offers recovery or report export.

### 7.3 Uninstall an application

1. User selects/searches/drops one app.
2. GUI requests exact app inspection and displays identity/provenance.
3. Engine inventories app bundle, helpers, services, receipts, and remnants.
4. GUI offers `Keep app data` or `Remove attributable app data`.
5. Weak/shared candidates remain retained and are visibly explained.
6. User reviews running-process and privilege implications.
7. Engine creates a new immutable uninstall plan.
8. User confirms using the app name for higher-risk purge-data operations.
9. Engine quits the app normally, quarantines eligible paths, verifies services/results, and records history.
10. GUI shows reclaimed space, retained items, failures, and restore duration.

If an authoritative vendor uninstaller or Homebrew cask operation is preferred, the UI must explain the hand-off and distinguish ordinary uninstall from Homebrew `--zap`.

### 7.4 Restore

1. User opens a completed or interrupted history record.
2. Engine verifies quarantine identity and original-path availability.
3. GUI lists conflicts and items that cannot be restored automatically.
4. User confirms a restore plan.
5. Engine restores, verifies, and appends a new immutable history event.

### 7.5 Permanent purge

Purge must be visually and operationally separate from cleaning. Show that it is irreversible, enumerate affected runs/items, and require fresh authentication/confirmation appropriate to risk. Never couple “Empty Trash” or “Purge quarantine” to a normal Clean button.

## 8. Permissions, sandbox, and privileged operations

### Distribution model spike

Prototype and document both:

1. a sandboxed build using user-selected access/security-scoped bookmarks; and
2. a directly distributed, hardened, non-sandboxed Developer ID build.

The utility needs broad inspection of application-support locations, so the directly distributed build is the likely primary product. Treat that as a hypothesis to verify with a permission matrix, not as a shortcut around macOS protections. Apple requires App Sandbox for Mac App Store distribution, while it is optional for Developer ID distribution; notarized direct distribution still requires hardened runtime.

### Full Disk Access

- Detect permission failures by operation and show the exact capability affected.
- Explain how to grant access in System Settings; the app cannot grant Full Disk Access to itself in code.
- Continue with accessible scopes when possible.
- Recheck after the app becomes active rather than polling continuously.
- Do not mislabel a permission denial as “nothing to clean.”

### Privileged helper

System-scope removal is a later feature. If adopted, use current Service Management mechanisms available for the minimum supported macOS version and communicate over XPC.

The helper must:

- verify the connecting app's code identity/audit token;
- accept typed operations or a validated plan/action ID, never arbitrary shell text;
- independently verify schema, signature, expiry, canonical path, allowed root, file identity, and expected owner;
- reject user-home operations that the normal engine can perform;
- expose no generic `delete(path)` or `run(command)` method;
- emit an auditable result for every action;
- remove/unregister itself cleanly when the app is uninstalled;
- be code-signed, hardened, and notarized with the rest of the product.

XPC is useful for privilege isolation and process separation, but it is not a substitute for authorization or plan validation.

### Trash and quarantine

For Finder-like trash behavior, prefer `NSWorkspace.recycle(_:completionHandler:)`, which returns mappings from original to Trash URLs and reports partial failures. Product-managed quarantine remains useful when deterministic retention/restore is required. The engine owns the policy choice and manifest; the GUI displays it.

## 9. Suggested Xcode project layout

```text
gui/
├── CleanMyMacGUI.xcodeproj
├── App/
│   ├── CleanMyMacApp.swift
│   ├── AppState.swift
│   └── NavigationDestination.swift
├── Features/
│   ├── Dashboard/
│   ├── Cleaner/
│   ├── Applications/
│   ├── Remnants/
│   ├── History/
│   ├── Settings/
│   └── Diagnostics/
├── Engine/
│   ├── EngineClient.swift
│   ├── EngineProcess.swift
│   ├── EngineEvent.swift
│   ├── EngineError.swift
│   └── ProtocolVersion.swift
├── Models/
│   ├── Candidate.swift
│   ├── Risk.swift
│   ├── Evidence.swift
│   ├── PlanSummary.swift
│   └── RunRecord.swift
├── Services/
│   ├── PermissionService.swift
│   ├── RecoveryService.swift
│   ├── SupportBundleService.swift
│   └── UpdateService.swift
├── DesignSystem/
├── Resources/
│   ├── Engine/
│   ├── Assets.xcassets
│   └── Localizable.xcstrings
├── PrivilegedHelper/          # not included before privileged phase
└── Tests/
    ├── Unit/
    ├── Contract/
    ├── UI/
    └── Fixtures/
```

Use feature folders and protocol-based service interfaces so previews/tests can inject the mock engine. Do not let SwiftUI views own `Process`, filesystem, authorization, or manifest logic.

## 10. Visual and interaction direction

- Use native macOS controls, spacing, sidebar/navigation, sheets, tables, context menus, and keyboard shortcuts.
- Make the primary visual hierarchy about action safety and recoverability, not decorative “system health” scores.
- Use text plus symbols for risk; never rely on red/amber/green alone.
- Present allocated space and logical size clearly when they differ.
- Use indeterminate progress during discovery when total work is unknown.
- Preserve selection while filters change, and display hidden-selected counts.
- Require deliberate confirmation for risky actions, but avoid confirmation fatigue for read-only work.
- Disable Apply while a plan is missing, stale, incompatible, or contains unresolved permission requirements.
- Provide Undo/Restore prominently after quarantine.
- Support window resizing, table column customization, copy/reveal actions, and state restoration.
- Localize user-facing text from the start; never expose raw engine messages as final UI copy.

Suggested keyboard commands:

- `⌘R` scan/refresh;
- `⌘F` focus search;
- `⌘I` inspect selected item;
- `⌘L` open logs/history;
- `Space` toggle a selectable candidate;
- `⌘.` request safe cancellation;
- no global shortcut for Apply, Purge, or force operations.

## 11. Testing strategy

### Swift unit tests

- strict decoding and rejection of unknown/incompatible protocol events;
- state-machine transitions for idle, scanning, planning, applying, interrupted, failed, and complete;
- byte formatting, grouping, sorting, filtering, and selection by candidate ID;
- plan expiry and capability gating;
- cancellation and partial-result handling;
- redaction of support exports;
- permission-state mapping and user-facing errors.

### Engine contract tests

- run the real CLI against disposable fixtures and compare JSON events to schemas;
- verify event sequence numbers, request IDs, terminal event/exit status agreement, and no ANSI/plain text on the event stream;
- test malformed, oversized, truncated, duplicate, and out-of-order events;
- run compatibility fixtures for the current and previous supported protocol versions;
- assert GUI and CLI produce the same plan summary for identical selections.

### UI tests

- first launch with full, partial, and denied permissions;
- safe scan, custom category scan, no findings, partial findings, and engine crash;
- app search, drag/drop inspection, ambiguous identity, shared remnants, and vendor hand-off;
- plan review, stale plan, apply, partial failure, interruption, restore conflict, restore success, and purge;
- keyboard-only navigation, VoiceOver labels/order, increased contrast, reduced motion, and large text;
- very large result sets without freezing or losing selection.

### Security tests

- attempt executable substitution, hostile environment/PATH injection, malicious filenames, and protocol injection;
- ensure no UI field becomes a shell string;
- verify the bundled engine and helper signatures before sensitive work;
- attempt stale/modified plans, symlink swaps, inode replacement, canonical-root escape, and replay on another user/Mac;
- verify helper caller authentication and refusal of arbitrary paths/commands;
- confirm logs and support bundles redact sensitive paths by default.

### Release tests

- Apple Silicon and Intel where supported;
- minimum and newest supported macOS versions;
- clean install, upgrade, downgrade refusal, and complete self-uninstall;
- code-signature verification, hardened runtime, notarization ticket, Gatekeeper launch, and offline stapled-ticket launch;
- damage-free removal of the GUI/CLI itself, including helper and support files;
- recovery compatibility across one supported app/engine upgrade.

## 12. Delivery roadmap

### GUI Phase 0 — Protocol and feasibility spike

Deliverables:

- freeze protocol v1 draft and JSON Schemas;
- build a command-line fixture emitter and recorded transcripts;
- prototype `Process` streaming, cancellation, crash recovery, and backpressure;
- test sandboxed versus direct-distribution permission behavior;
- choose minimum macOS version, suggested initially as macOS 13+ because of modern Service Management support;
- create wireframes for Dashboard, Cleaner results, App detail, Plan review, and History.

Exit criteria: the UI can run entirely against fixtures, the permission/distribution decision is recorded, and no production deletion path exists.

### GUI Phase 1 — Read-only shell

Deliverables:

- signed SwiftUI app skeleton, navigation, design tokens, localization setup, and accessibility baseline;
- engine handshake, doctor output, permission status, logs, and error states;
- Dashboard and Cleaner scan result views against the real read-only engine;
- application inventory and inspection views when the CLI milestone is ready.

Exit criteria: scans can be cancelled safely, large results stay responsive, and UI/CLI reports agree.

### GUI Phase 2 — Cleaner plan/apply

Deliverables:

- candidate selection, risk/evidence details, plan review, and apply progress;
- quarantine history and exact per-action outcomes;
- partial failure, interruption, and stale-plan UX;
- Safe and Developer profiles with the same defaults as the CLI.

Exit criteria: every mutation uses an immutable engine plan, and GUI tests cover success and every terminal failure state.

### GUI Phase 3 — User-scope app uninstall

Deliverables:

- Applications browser, search, sorting, detail, and drag/drop inspection;
- Keep Data/Purge Data plan workflows;
- shared/weak evidence review and vendor/Homebrew hand-off;
- normal app quit, user-scope quarantine, verification, and results.

Exit criteria: user documents and shared resources remain protected, and every supported uninstall is restorable.

### GUI Phase 4 — Recovery and retention

Deliverables:

- History/Recovery center, interrupted-run repair, restore plan review, and conflicts;
- retention reminders and explicit permanent purge;
- redacted support-bundle export.

Exit criteria: end-to-end restore works across app restart and supported app upgrade; purge is never accidental or coupled to normal cleaning.

### GUI Phase 5 — Privileged system scope

Deliverables:

- signed helper and plan-bound XPC protocol;
- macOS authorization/status UX;
- system-remnant review and exact elevated-action results;
- helper install, update, failure recovery, and self-removal.

Exit criteria: an independent security review and adversarial test suite confirm there is no arbitrary delete/command interface.

### GUI Phase 6 — Distribution

Deliverables:

- final product name and icon, after name/trademark/package checks;
- Developer ID signing, hardened runtime, notarization, stapling, and a reviewed signed-update strategy if automatic updates are desired;
- DMG or signed package, release CI, privacy policy, help, support matrix, and rollback process;
- optional Homebrew cask for the GUI plus continued CLI-only distribution.

Exit criteria: release verification passes on clean machines, the app works without network access after installation, and self-uninstall is documented/tested.

### GUI Phase 7 — Optional future features

- scan-only scheduled notifications;
- Storage trend/history without collecting file names unnecessarily;
- signed declarative cleaner-rule updates with rollback;
- menu-bar status limited to scan results and recovery reminders;
- duplicate and large-file review tools;
- exportable reports for support/managed-device environments.

Each optional feature needs its own privacy, safety, performance, and recovery review. None may introduce unattended destructive actions.

## 13. MVP scope and exclusions

### Include in first usable beta

- engine health and permissions;
- Safe Profile scan;
- cleaner results with risk/recovery explanations;
- immutable plan review and user-scope apply;
- application inventory/inspection;
- quarantine history and restore;
- human-readable and redacted diagnostic export.

### Explicitly exclude from the first beta

- system-level/privileged deletion;
- permanent purge from the primary cleanup flow;
- automatic or scheduled cleanup;
- remote rule downloads;
- package-receipt deletion without shared-payload proof;
- bulk uninstall;
- duplicate-file auto-deletion;
- Mac App Store distribution until sandbox feasibility is proven;
- analytics or telemetry.

## 14. Definition of done

The GUI wrapper is production-ready only when:

- it can perform every supported workflow without parsing terminal-formatted output;
- GUI and CLI produce the same plans and action results;
- the GUI cannot bypass engine confidence, shared-resource, path, or privilege policy;
- no user-controlled string becomes a shell command;
- scan, plan, apply, cancellation, interruption, restore, and purge have complete UI states;
- missing permissions are distinguished from empty results;
- all mutations are attributable to a plan and visible in history;
- eligible uninstall/clean actions remain recoverable until explicit purge;
- accessibility and keyboard workflows pass manual and automated checks;
- the bundled engine/helper and the app are signed, hardened, notarized, and version-compatible;
- clean install, upgrade, recovery, and complete self-uninstall pass the release matrix.

## 15. Recommended first implementation slice

After the CLI protocol draft exists, the first GUI pull request should contain only:

1. a SwiftUI window with sidebar navigation;
2. typed protocol models and strict version handshake;
3. an injectable engine-client interface;
4. a fixture-backed mock engine for scan/progress/error events;
5. Dashboard and read-only Cleaner results;
6. cancellation and engine-crash states;
7. unit, contract-fixture, basic UI, and accessibility tests.

Do not include Apply, uninstall, helper installation, or filesystem mutation in that slice. The next slice can connect read-only scans to the real engine, followed by plan review only, and then plan apply after the corresponding CLI safety gate passes.

## 16. References

- [Apple: SwiftUI apps](https://developer.apple.com/documentation/technologyoverviews/swiftui) — Apple's current recommended framework for new app interfaces.
- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) — sandbox scope, user-selected files, Full Disk Access, and permission-failure handling.
- [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution) — App Sandbox requirements and hardened-runtime distribution guidance.
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Developer ID, hardened runtime, timestamps, notarization, and Gatekeeper trust.
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) — modern management of login items, LaunchAgents, and LaunchDaemons.
- [Apple: XPC](https://developer.apple.com/documentation/xpc) — process separation and privilege-isolation architecture.
- [Apple: NSWorkspace recycle](https://developer.apple.com/documentation/appkit/nsworkspace/recycle(_:completionhandler:)) — Finder-like movement to Trash with original/destination mappings and partial errors.
