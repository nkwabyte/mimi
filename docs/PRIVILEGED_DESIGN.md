# Privileged scope: design decision (P5-T03)

Status: **decided 2026-09-26 — option B** (DEC-061). First slice implemented:
`libexec/mimi-root-apply` and `mimi app uninstall <app> --system` (§5).
Slice 2 (package payload, receipts at purge, hardened copy) added the same
day. Independent review of `libexec/mimi-root-apply` is in progress (external
reviewer, plus `/security-review`) and is required before the Phase 5 exit
gate can close.

## 1. What needs privilege

Today everything mimi changes is owned by the user: `$HOME`, the per-user
temp folder, and app bundles in application folders the user can write to.
What it can only **report** is system scope, owned by root:

| Artifact | Example | Reported by |
|---|---|---|
| LaunchDaemons | `/Library/LaunchDaemons/com.vendor.helper.plist` | `app inspect` (system locations, package payload) |
| Privileged helpers | `/Library/PrivilegedHelperTools/com.vendor.helper` | same |
| System support data | `/Library/Application Support/<Vendor>` | same |
| Package payload outside `$HOME` | `/usr/local/share/dotnet/host` | `app inspect` package payload (P5-T02) |
| Stale package receipts | `pkgutil --forget <id>` after removal | P5-T02 finds them |
| App bundles owned by root | `/Applications/<App>.app` installed by a `.pkg` | `app uninstall` refuses (not writable) |

Two ways to act on these already exist and stay the preferred route: the
vendor's own uninstaller (P5-T01, launched only when signed by the app's
developer) and Homebrew (`--cask` / `--zap`).

## 2. Threat model

| # | Threat | Why it matters here |
|---|---|---|
| T1 | **Plan forgery → root deletion.** Anything running as the user can write a plan file and wait for the user to apply it with privilege. | A privileged apply that trusts a user-writable plan turns any user-level malware into root deletion of chosen system paths. The plan digest does not help: the attacker computes it. |
| T2 | **Path games.** Symlinks, `..`, firmlinks, and replacing a directory between check and act (TOCTOU). | Root follows a symlink the user planted from `/Library/…/Vendor` to `/System` or `/usr`. |
| T3 | **Environment injection.** `PATH`, `BASH_ENV`, `IFS`, `TMPDIR`, `HOME` under `sudo`. | Bash sources and runs whatever the environment points at; running all of mimi's ~11,500 lines as root makes every line part of the trusted base. |
| T4 | **Ownership mistakes.** Removing a payload shared by another package or app. | Breaks an unrelated product; not reversible by mimi if not quarantined. |
| T5 | **Helper persistence and misuse.** An installed privileged daemon stays running and callable. | Any process that can talk to it can ask it to act; it must verify the caller and accept only narrow, typed operations. |
| T6 | **Replay.** Applying an old approved plan again later. | The system changed since; items are no longer what was approved. |
| T7 | **Self-removal and upgrade.** A helper left behind after uninstall, or an old helper after upgrade. | Stale privileged code on the machine. |

Invariants any design must keep:

1. Root never trusts a path from a user-writable file. Root **re-derives**
   the candidate set itself (from receipts and fixed system roots) and a plan
   may only **select** among candidates root computed, by id.
2. A fixed allow-list of system roots: `/Library/LaunchDaemons`,
   `/Library/LaunchAgents`, `/Library/PrivilegedHelperTools`,
   `/Library/Application Support/<Vendor>`, receipt payload paths outside
   `/System`, `/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`. Never `/System`, never
   an Apple-owned path, never a path any other receipt owns (T4).
3. No symlink following: act on `lstat` identity; refuse symlinks and
   anything whose owner/identity changed since listing (T2).
4. Quarantine, not delete: a root-owned quarantine
   (`/Library/Application Support/mimi/quarantine`, `root:wheel 0700`), with
   restore and a separate purge — the same model as user scope.
5. Every privileged action is shown in full and confirmed in the same session
   that authorizes it; nothing is remembered between sessions (T6).
6. The privileged code is small, separate, and reviewed on its own.

## 3. Options

### A. No privileged code — hand-offs and instructions only

mimi keeps reporting system scope, and for each item prints the exact command
a person can run (`sudo launchctl bootout system/<label>`, `sudo mv …`), or
hands off to the vendor uninstaller or Homebrew.

- **For:** zero new attack surface; nothing to sign or install; honest.
- **Against:** the user does the root work by hand; no quarantine or restore
  for it.

### B. A minimal `sudo` apply tool — `libexec/mimi-root-apply`

A separate, small script (target: under 400 lines, no `lib/` sourcing) run
explicitly with `sudo`. mimi (as the user) writes a *request*: an app bundle
id and the candidate ids the user selected. The root tool:

1. starts with a fixed environment (`env -i`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
   refuses if `BASH_ENV`/`SHELLOPTS` are set), checks it is root via `sudo`
   and that `SUDO_UID` owns the request file;
2. re-derives the candidates itself from `pkgutil` receipts and the fixed
   system roots for that bundle id (invariant 1) — the request only selects;
3. shows every action and asks for a typed confirmation on the terminal;
4. moves each item into the root quarantine after `lstat`/owner/identity
   checks, stops LaunchDaemons with `launchctl bootout system/<label>` first,
   and runs `pkgutil --forget` only after every payload item of that package
   is verified gone;
5. writes a root-owned manifest; `sudo mimi-root-apply --restore <run>` and
   `--purge <run>` mirror user scope.

- **For:** matches the earlier "run with sudo" request without running all of
  mimi as root; uses the standard `sudo` password prompt; ships in the
  existing Homebrew formula; no signing or notarization; auditable in one
  file.
- **Against:** still Bash as root, so it must be written and reviewed
  defensively; `sudo` from a terminal only (no GUI prompt); Full Disk Access
  still applies to the terminal.

### C. A native privileged helper — `SMAppService` LaunchDaemon + XPC (Swift)

The Apple-recommended design: a signed Swift daemon registered through
`SMAppService.daemon(plistName:)`, embedded in an app bundle's
`Contents/Library/LaunchDaemons`, approved by the user in System Settings →
Login Items. mimi talks to it over XPC; the daemon verifies the caller's code
signature (Team ID + designated requirement) and accepts only typed,
plan-bound operations.

- **For:** strongest caller verification; GUI-friendly authorization; the
  natural base for the planned GUI (see `GUI_WRAPPER_PLAN.md`).
- **Against:** requires a **Developer ID** certificate and notarization (this
  machine has an *Apple Development* identity only, which is not enough to
  distribute); must ship as an app bundle, so Homebrew distribution moves from
  a formula to a cask; a Swift codebase to maintain; user approval step in
  System Settings; the most work by far.

## 4. Recommendation

**B now, C later with the GUI.**

- B gives real, reversible system-scope uninstall for the cases people hit
  (vendor LaunchDaemons, privileged helpers, package payload), keeps the
  distribution you already have, and its trusted code is one small file that
  can be reviewed independently — which the Phase 5 exit gate requires anyway.
- A is the fallback if you would rather mimi never hold root at all; it is
  also what B degrades to for anything B's allow-list refuses.
- C only pays off once there is a signed GUI app to host the daemon and a
  Developer ID to sign it. Revisit then; B's request format and invariants
  carry over unchanged.

## 5. If B is chosen: first slice

1. `libexec/mimi-root-apply` handling one artifact class: LaunchDaemons and
   PrivilegedHelperTools attributed to one bundle id by receipt and label.
2. `mimi app uninstall <app> --system` writes the request and prints the
   `sudo` command; it never calls `sudo` itself.
3. Tests with a fake root (`MIMI_ROOT_PREFIX` pointing into the fixture), the
   `pkgutil`/`launchctl` mocks, and adversarial requests: forged ids,
   symlinks, shared payload, replaced targets, stale requests.
4. An independent review of that one file before it ships.

## 6. Decision

- [ ] A — hand-offs and instructions only
- [x] B — minimal `sudo` apply tool (chosen 2026-09-26, DEC-061)
- [ ] C — native `SMAppService` helper (revisit with the GUI)

## 7. What was built (first slice)

- `libexec/mimi-root-launch` is the program `sudo` runs. It execs `mimi-root-apply` in the same directory with `bash --noprofile --norc` and a fixed environment, so `BASH_ENV` and `SHELLOPTS` from the caller are not applied. `sudo mimi-root-apply --install` compiles that launcher next to the root-owned script.
- `libexec/mimi-root-apply` (standalone; sources nothing): `--candidates`
  (no root needed), apply a request, `--restore`, `--purge`, `--runs`.
  Scope: `/Library/LaunchDaemons`, `/Library/LaunchAgents`,
  `/Library/PrivilegedHelperTools` for one bundle id.
- Attribution needs two signals per plist: an owner signal (file name is the
  bundle id or nested under it, or `AssociatedBundleIdentifiers` names it)
  and a corroborating one (the program is a matching helper tool or inside a
  matching app, or both owner signals agree); `Label` must equal the file
  name; helper tools only when a selected job runs them. Items associated
  with other apps, owned by several packages, symlinked, or not root-owned
  are listed as "not attributable" and never selected.
- Candidate ids hash kind, path, and device:inode, so a request cannot name
  a path and a replaced file matches nothing; an unknown id fails the whole
  request. Requests must be owned by the sudo user, not group/world-writable,
  and under an hour old.
- Apply: typed bundle id on the terminal (no `--yes`), `launchctl bootout`
  (`system/` for daemons, `gui/<uid>/` for agents), identity re-checked just
  before each move into `/Library/Application Support/mimi/quarantine/<run>`
  (0700), manifest per run. Restore never overwrites and is safe to repeat;
  purge needs the typed word `purge`.
- Real mode fixes its own `PATH`, unsets `BASH_ENV`/`ENV`/`CDPATH`, and warns
  when its own file is writable by a non-root user (a Homebrew install is
  user-owned; the warning prints the `sudo install` command for a root-owned
  copy).
- Test mode (`MIMI_ROOT_TEST=1`, refused when running as root) drives
  `tests/root_apply.bats` against a fake root.

### Slice 2 (2026-09-26)

- **Package payload.** Packages are attributed to the bundle id when the
  package id is the bundle id (or nested under it) or when the package
  installed an app whose `Info.plist` names it. Their payload is grouped
  below structural folders; an item is selectable only if no other
  third-party package owns it or anything inside it (shared items are split
  up to two levels to find exclusive parts), it is root-owned, not a
  symlink, and inside `/Applications`, `/Library` (not `/Library/Apple`),
  `/usr/local`, or `/opt`. Plists in the launchd folders are never taken
  through this route: they always need the two-signal rule. Payload moves
  after the jobs and helpers.
- **Receipts.** `pkgutil --forget` runs at `--purge`, never at apply: while
  files are restorable from quarantine the receipt must stay. At purge it
  runs only for packages whose payload was moved in that run and whose every
  item is verified absent; otherwise the receipt is kept and the count of
  items still installed is shown.
- **Hardened copy.** `sudo mimi-root-apply --install` installs a
  `root:wheel 0755` copy at `/usr/local/libexec/mimi/mimi-root-apply`
  (atomically, verified byte-identical); `--uninstall-tool` removes it and
  lists the quarantine runs it leaves in place. mimi prints the hardened
  copy in its `sudo` command while it is identical to the bundled one, and
  says when an upgrade made it stale or when none is installed.
