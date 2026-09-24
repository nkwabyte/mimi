# mimi — complete usage reference

Every flag, category, key binding and config option, with what each one
actually touches.

- **New here?** Read [Before your first run](#before-your-first-run), then
  [Quick start](#quick-start).
- **Looking for one flag?** Jump to the [Flag reference](#flag-reference).
- **Wondering what a category deletes?** See the
  [Category reference](#category-reference).
- **"Why is my disk still full?"** See [The disk report](#the-disk-report).

---

## Contents

1. [Requirements](#requirements)
2. [Before your first run](#before-your-first-run)
3. [Quick start](#quick-start)
4. [The two modes](#the-two-modes)
5. [Interactive mode](#interactive-mode)
6. [Flag reference](#flag-reference)
7. [Category reference](#category-reference)
8. [Choosing what runs](#choosing-what-runs)
9. [Protecting paths: whitelist and presets](#protecting-paths-whitelist-and-presets)
10. [Possible app leftovers](#possible-app-leftovers)
11. [The disk report](#the-disk-report)
12. [Config file](#config-file)
13. [Logs](#logs)
14. [Recipes](#recipes)
15. [Safety model](#safety-model)
16. [Troubleshooting](#troubleshooting)

---

## Requirements

| | |
|---|---|
| OS | macOS (built and tested on Apple Silicon) |
| Shell | bash 3.2+ — the system `/bin/bash` is enough, no Homebrew bash needed |
| Root | never. The script does not use `sudo` and refuses to touch system paths |
| Optional | `brew`, `npm`, `yarn`, `pnpm`, `pip`, `docker`, `xcrun`, `uv`, `go`, `adb` — each category skips itself cleanly if its tool is missing |

Install it once:

```bash
./install.sh          # symlinks `mimi` onto your PATH
```

---

## Before your first run

### Grant Full Disk Access

macOS puts several directories behind TCC. A terminal without Full Disk
Access cannot even *read* them — `du` reports 0 B and `rm` fails silently, so
browser caches survive every clean and keep showing up as "System Data".

Affected: `~/Library/Application Support/Google/Chrome`, `.../Firefox`,
`.../BraveSoftware`, `.../Microsoft Edge`, `.../MobileSync` (device backups),
`~/Library/Safari`, `~/Library/Mail`, `~/Library/Messages`.

1. System Settings → Privacy & Security → **Full Disk Access**
2. Add and enable the terminal you run the script from (Terminal, iTerm,
   Ghostty, Warp, VS Code…)
3. **Fully quit and reopen it** — a window reload is not enough

`mimi` prints a warning at the top of every run if this is missing, and
marks each directory it could not read with `no permission to read:`.

### Quit the apps you are about to clean

A running Chrome, Notion or VS Code holds its cache files open and re-creates
them immediately, so the space does not come back until it exits. The script
detects running apps and warns you — it never kills anything.

---

## Quick start

```bash
mimi                 # bare invocation from a terminal → interactive menu
mimi --scan          # report what would be freed, delete nothing
mimi --cleaner         # actually clean, asks once to confirm
mimi --cleaner --yes   # answer the ordinary prompts (not the risky ones)
mimi --report        # where did my disk space go? deletes nothing
mimi --list          # every category id, risk level, default state
mimi --help          # full flag list
```

---

## The two modes

### `--scan` (the default)

Deletes nothing. Prints every path it *would* touch with its size, then an
estimated total. Run this first, always.

```
  would clear contents of: ~/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage (8.4G)
  would remove: ~/.konan/kotlin-native-prebuilt-macos-aarch64-2.2.10 (1.7G)

== Summary ==
Estimated reclaimable space: 18.6G
```

The estimate is an upper bound. Categories that delegate to another tool
(`brew cleanup`, `pnpm store prune`, `uv cache prune`) can only report the
size of the directory, not how much that tool will decide to drop.

### `--cleaner`

Does the work. Prompts once before starting unless `--yes` is given, and
prompts again for the genuinely destructive categories (`docker`, `mail`,
`trash`, `orphans`, `sim-stale`, `android`, `ios-backups`, `ml-caches`).
`--yes` answers only the first kind; see
[Confirmation classes](#confirmation-classes).

```
  cleared: ~/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage  (freed 8.4G)

== Summary ==
Space freed this run: 18.6G
Free space before: 48G  ->  after: 67G
```

---

## Transactional workflow: plan, apply, restore, and purge

For maximum safety and reproducibility, `mimi` provides an immutable plan/apply workflow with automatic quarantine and rollback.

### `mimi plan`
Discovers cleanup candidates according to your selected categories and writes an immutable, SHA-256 digested execution plan (`schemas/plan-v1.json`) with restricted `0600` permissions. Nothing is deleted or modified.
```bash
mimi plan --only caches
# or specify an exact output file:
mimi plan --only caches --plan-out ~/Desktop/mimi-plan.json
```

### `mimi apply <plan-file>`
Preflights the execution plan (verifying the cryptographic digest, schema version, host/user binding, expiration, and ensuring target file identities have not changed), prompts for approval (or `--yes`), and moves targets into an isolated quarantine store (`~/.config/mimi/quarantine/<run-id>`) with verified postconditions.
```bash
mimi apply ~/.config/mimi/plans/plan-20260924-120000-1234.json
```

### `mimi restore <run-id>`
Restores a previously quarantined run back to the original filesystem locations, verifying destination availability and file identities.
```bash
mimi restore run-20260924-120000-1234
```

### `mimi purge <run-id>`
Permanently deletes the quarantine directory for a specified run after explicit confirmation.
```bash
mimi purge run-20260924-120000-1234
```

---

## Interactive mode

Entered by running `mimi` with **no arguments at all** from a real
terminal, or explicitly with `-i` / `--interactive`. Any other flag keeps the
script fully scriptable.

Every screen is arrow-key driven. Number keys still work on the main menu,
and if stdin is not a terminal (a pipe, CI) the script silently falls back to
the old typed-number menus.

### Main menu

```
Main menu
  ↑/↓ move   enter select   q quit
❯ Quick scan    — code-default safe categories, changes nothing
  Quick clean   — code-default safe categories
  Choose categories & run
  Disk report   — where your space actually went
  Manage whitelist
  Settings
  View category list (current selection)
  View most recent log
  Save current selection + settings as default
  Quit
```

| Key | Action |
|---|---|
| `↑` `↓` / `k` `j` | move (wraps) |
| `enter` / `space` / `→` | select |
| `g` / `G` / `Home` / `End` | first / last item |
| `1`–`9` | jump straight to that item |
| `q` / `Esc` | quit |

### Choose categories

```
Choose categories  (20/35 selected)
  ↑/↓ move   space toggle   enter run scan   c clean   a all   x none   r reset   q back

❯ [x] browsers         safe     Chrome/Brave/Edge/Arc/Vivaldi/Opera/Firefox caches
  [x] electron         safe     Electron app caches (Notion, Slack, VS Code…)
  [ ] ios-backups      risky    Local iPhone/iPad backups in MobileSync
  — showing 1-18 of 35 —
```

| Key | Action |
|---|---|
| `↑` `↓` / `k` `j` | move (wraps) |
| `space` / `→` | toggle the highlighted category |
| `enter` / `s` | run a **scan** with exactly what is checked |
| `c` | run a **clean** with exactly what is checked |
| `a` | select all |
| `x` / `n` | clear all |
| `r` | reset to your saved selection, or the built-in defaults |
| `PgUp` `PgDn` `g` `G` | jump around a long list |
| `q` / `b` / `Esc` | back to the main menu |

Risk is colour-coded — green `safe`, yellow `moderate`, red `risky` — so a
destructive category is hard to tick by accident. Ticking an opt-in category
here sets its `--include-*` flag automatically; you never need to remember
flag names.

### Settings

```
Settings
  ↑/↓ move   ←/→ adjust   enter edit or toggle   q back

  Xcode DeviceSupport versions to keep        3
  Simulator staleness threshold (days)        60
  Android AVD staleness threshold (days)      60
  Temp file age threshold (days)              3
  Toolchain versions to keep (Kotlin, Gradle) 1
❯ Aggressive mode (prunes harder)             on
  Verbose output                              off
  Assume yes (skip confirmation prompts)      off
```

| Key | Action |
|---|---|
| `↑` `↓` | move |
| `←` `→` | decrement/increment a number, or turn a switch off/on |
| `enter` / `space` | toggle a switch, or open a prompt to type an exact number |
| `q` / `b` / `Esc` | back |

### Whitelist

```
Whitelist  (2 entries)
  ↑/↓ move   space/d remove   a add   p preset   q back

❯ /Users/you/Library/Developer/CoreSimulator
  com.adobe.*
```

| Key | Action |
|---|---|
| `↑` `↓` | move |
| `space` / `d` / `Backspace` | remove the highlighted entry |
| `a` | add an entry (prompts for text) |
| `p` | open a picker of the built-in presets |
| `q` / `b` / `Esc` / `enter` | back |

---

## Flag reference

### Subcommands and modes

| Subcommand / Mode | Effect |
|---|---|
| `scan`, `--scan` | Report reclaimable space only, delete nothing. **Default.** |
| `clean`, `--cleaner` | Actually delete. Confirms once unless `--yes`. `--clean` is accepted too. |
| `plan`, `--plan` | Discovers candidates and generates an immutable execution plan (`schemas/plan-v1.json`). |
| `apply <plan-file>`, `--apply <file>` | Validates plan integrity and moves targets into an isolated quarantine run. |
| `restore <run-id>`, `--restore <id>` | Restores a previously quarantined run back to original paths. |
| `purge <run-id>`, `--purge <id>` | Permanently deletes a quarantined run after explicit confirmation. |
| `--report` | Print a full disk breakdown, then exit. Deletes nothing. |
| `--list` | Print every category id, risk and default state, then exit. |
| `-i`, `--interactive` | Force the menu even when other flags are present. |
| `-h`, `--help` | Print the built-in help, then exit. |

### Common options

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Answer the *recoverable* prompts: the whole-run gate and anything that comes back by itself. It cannot answer a risky or irreversible one. |
| `--profile <name>` | Select category profile (`safe`, `developer`, `aggressive`, or `list` to print profiles). Precedence: `--only` > `--profile` > `CONFIG_SELECTED_CATEGORIES` > `CONFIG_PROFILE` > `safe`. |
| `--force-risky <names>` | Authorize risky/irreversible actions by name, for this invocation only: `docker`, `mail`, `trash`, `orphans`, `sim-stale`, `android`, `ios-backups`. No `all`. Never read from or written to the config file. Authorizes but does not select — the matching `--include-<name>` is still required. |
| `-v`, `--verbose` | Print every path as it is inspected and removed. |
| `--aggressive` | Prune harder where a category supports it: older Xcode device support, `.xcarchive` builds, extra browser cache dirs, `uv cache clean` instead of `prune`, and `--tmp-stale-days 0`. Still fully whitelist-respecting. |
| `--only <ids>` | Comma-separated category ids to run — nothing else runs. |
| `--skip <ids>` | Comma-separated ids to exclude. Always wins. |
| `--no-log` | Leave no log file behind at all. |
| `--keep-logs N` | Past run logs to keep (default `5`, `0` = keep none). |

Every option that takes a value accepts both `--flag value` and
`--flag=value`.

### Thresholds

| Flag | Default | Effect |
|---|---|---|
| `--keep-device-support N` | `3` | Xcode iOS DeviceSupport symbol sets to keep |
| `--sim-stale-days N` | `60` | A Simulator device unused this long counts as stale |
| `--android-stale-days N` | `60` | An AVD unused this long counts as stale |
| `--tmp-stale-days N` | `3` | `$TMPDIR` entries newer than this are reported, not removed |
| `--keep-toolchains N` | `1` | Versions of each toolchain to keep (Kotlin/Native, Gradle) |
| `--keep-logs N` | `5` | Past run logs to keep. `0` keeps none |

### Opt-in categories

None of these run unless you ask for them. Passing the flag is by itself
enough to run that category — you do not also need `--only`.

| Flag | Runs |
|---|---|
| `--include-timemachine` | Local Time Machine APFS snapshots (thinning). |
| `--include-device-support` | Xcode iOS DeviceSupport old OS symbol sets. |
| `--include-homebrew-old` | Old installed Homebrew formula/cask versions and unused dependencies (`brew autoremove`). |
| `--include-caches` | Broad user application caches (`~/Library/Caches/*`). |
| `--include-logs` | Broad user log files (`~/Library/Logs/*`). |
| `--include-docker-cache` | `docker builder prune -f` + `docker image prune -f` — dangling build cache and untagged images only. This is what actually shrinks `Docker.raw`. |
| `--include-docker` | `docker system prune -af --volumes` — **all** unused images, containers and volumes. Much more aggressive than the above. |
| `--include-trash` | Empty `~/.Trash`. Irreversible. |
| `--include-mail` | Clear Mail.app's local "Mail Downloads" cache. |
| `--include-orphans` | **Report only.** Scan for leftovers no installed app claims; never deletes. See [Possible app leftovers](#possible-app-leftovers). |
| `--include-whatsapp` | Remove WhatsApp's expired Status/Stories media only. |
| `--include-sim-stale` | Delete Simulator devices unused for `--sim-stale-days`. |
| `--include-claude-cache` | Clear the Claude desktop app's Electron cache dirs. |
| `--include-android` | Remove unreferenced Android system images and stale AVDs. |
| `--include-ide-stale` | Remove config/plugin folders of superseded JetBrains and Android Studio versions. |
| `--include-ml-caches` | Clear the Hugging Face and PyTorch model caches. |
| `--include-ios-backups` | Delete local iPhone/iPad backups. Asks per backup. |
| `--include-toolchains` | Remove superseded Kotlin/Native, Gradle distributions, Gradle JDKs and non-active SDKMAN candidates. |

### Whitelisting

| Flag | Effect |
|---|---|
| `--whitelist <items>` | Comma-separated paths or globs to protect. Repeatable. |
| `--whitelist-preset <name>` | Expand a named preset. See [presets](#presets). |

### Orphans

| Flag | Effect |
|---|---|
| `--remove-orphans-from <file>` | Remove exactly the paths listed in a review file produced by `--include-orphans`. The file must still carry its `# mimi-orphan-review v1` header, `#` comments a line out only in the first column, and each path must resolve to a direct child of a scanned orphan location. Refused lines are reported with a reason code. |

### Automation and protocol

| Flag | Effect |
|---|---|
| `--jsonl`, `--json` | Emit structured JSON Lines events to stdout for machine integration (protocol v1). Diagnostics go to stderr. |
| `--request-id <id>` | Correlation ID for protocol v1 events. |
| `--no-color` | Suppress ANSI color escape codes in terminal output. |
| `--no-prompt` | Do not prompt interactively; exit `5` immediately if confirmation or authorization is missing. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Everything asked for was done, including `--help`, `--list` and `--report` |
| `1` | Invalid usage |
| `3` | The run finished, but at least one selected action failed or was refused by the system |
| `4` | A signal (Ctrl-C, `SIGTERM`) stopped the run before it finished |
| `5` | A required confirmation was declined, or could not be obtained at all |

`2` is deliberately unused — too many tools read it as "usage", and invalid
usage here is already `1`.

**`3` is not an error in the script; it is the truth about the run.** A
permission-denied cache directory means the tool did not do what you asked,
so it says so in the exit status rather than reporting success. The summary
line breaks the run down:

```
Actions: 412 succeeded, 7 skipped, 3 permission-denied, 0 failed
```

- *succeeded* — verified gone afterwards, not merely "`rm` returned 0"
- *skipped* — never attempted: whitelisted, already missing, refused by the
  path checks, or not started because the run was interrupted
- *permission-denied* — attempted and refused by the system; Full Disk Access
  is the usual cause
- *failed* — attempted, and the target is still there

Only bytes from *succeeded* actions are counted towards "Space freed this
run", and directory clears credit a measured before/after difference rather
than the size taken before the attempt.

On Ctrl-C the tool does **not** die mid-delete. The signal handler records the
interruption, the action in progress is allowed to finish, and nothing further
is started — so a tree is never left half-removed with a total that claims
neither state. The run exits 4.

Every invalid-usage message is written to **stderr** with the same prefix, so
it is easy to grep for in a wrapper script:

```
mimi: error: --only: unknown category 'cahces' (run 'mimi --list' to see them all)
Try 'mimi --help' for the full list of options.
```

### What gets rejected

| Input | Result |
|---|---|
| `--only` with no value | `--only requires a value` |
| `--only --scan` | `--only requires a value (got the option '--scan')` |
| `--only nosuchcategory` | `unknown category 'nosuchcategory'` |
| `--only ""` or `--only ",,,"` | `--only requires at least one category name` |
| `--keep-device-support abc` | `expects a whole number between 0 and 36500` |
| `--tmp-stale-days -5` | same — negatives, floats and whitespace are all rejected |
| `--whitelist-preset nosuch` | `unknown whitelist preset`, and the message lists all five |
| `--remove-orphans-from missing.txt` | `cannot read review file` |

Lists tolerate surrounding whitespace (`--only " caches , logs "`) and silently
drop duplicates (`--only caches,caches`). Values from the config file go
through exactly the same checks, and the error names the file and key rather
than a flag you never typed — but `--help` and `--list` keep working even when
the config is unusable, so you can always reach the documentation that
explains the fix.

---

## Category reference

`mimi --list` prints the live list. Risk levels mean:

- **safe** — regenerated automatically, nothing is lost but time
- **moderate** — regenerated, but re-downloading or rebuilding costs real time
- **risky** — can remove data you actually wanted; always opt-in and confirmed

### On by default (safe profile)

| ID | Risk | What it removes |
|---|---|---|
| `browsers` | safe | Chromium-family caches across **every** profile (`Default`, `Profile 1..N`, Guest, System) for Chrome, Chrome Beta/Canary, Chrome for Testing, Chromium, Brave, Brave Beta, Edge, Vivaldi, Opera, Opera GX, Arc, Dia, Yandex, Comet — plus Firefox's startup and shader caches. Details [below](#what-browsers-and-electron-touch). |
| `electron` | safe | The same Chromium cache layout inside Electron apps — Notion, Slack, VS Code, Postman, Obsidian, Discord, Claude, pgAdmin and anything else with the layout — **including `Partitions/*`**, where the multi-GB `Service Worker/CacheStorage` hides. |
| `dev-caches` | safe | `uv cache prune`, `go clean -cache`, Trivy, GitHub Copilot, `gh`, gem, giget, Firebase, Playwright, Deno, Bazel, sccache, node-gyp, cargo registry cache, NuGet http caches, SwiftPM, JetBrains, `.dartServer`, `.gradle/.tmp`. |
| `tmp` | safe | `$TMPDIR` (`/private/var/folders/…/T`) and the matching per-user cache dir, for entries older than `--tmp-stale-days`. Anything newer is **reported with its size** but left alone — a running process may be using it. Apple's live IPC dirs are always skipped. |
| `diagnostics` | safe | Old crash and diagnostic reports. |
| `dsstore` | safe | Stray `.DS_Store` files under your home directory. |
| `quicklook` | safe | QuickLook thumbnail cache (`qlmanage -r cache`). |
| `xcode-derived` | safe | Xcode `DerivedData`. Xcode rebuilds it. |
| `sim-caches` | safe | The iOS Simulator's own cache directory. |
| `sim-unavailable` | safe | Simulator devices Xcode already marked unavailable (`xcrun simctl delete unavailable`). |
| `homebrew` | safe | Homebrew package download cache only (`brew cleanup -s --prune=all`). |
| `npm` | safe | `npm cache clean --force`. |
| `yarn` | safe | `yarn cache clean` for Yarn Classic; for Yarn Berry (v2+, which has no `yarn cache dir`) it clears `~/.yarn/berry/cache` directly. |
| `pnpm` | safe | `pnpm store prune` (prunes unreferenced packages). |
| `cocoapods` | safe | `~/Library/Caches/CocoaPods`. |
| `gradle` | safe | `~/.gradle/caches`. |
| `pip` | safe | `pip cache purge`. |

### Off by default (opt-in)

| ID | Risk | What it removes | Flag |
|---|---|---|---|
| `caches` | safe | Broad user application caches in `~/Library/Caches/*`. | `--include-caches` |
| `logs` | safe | Broad user log files in `~/Library/Logs/*`. | `--include-logs` |
| `docker-cache` | safe | Dangling Docker build cache and untagged images. Never touches running containers, named volumes or tagged images. | `--include-docker-cache` |
| `claude-cache` | safe | The Claude desktop app's Electron cache dirs. Reports but never removes `vm_bundles`. | `--include-claude-cache` |
| `xcode-archives` | moderate | Old `.xcarchive` builds. You may need these for dSYMs or App Store resubmission. Only with `--aggressive`. | — |
| `device-support` | moderate | Old Xcode iOS DeviceSupport symbol sets, keeping the newest `--keep-device-support`. | `--include-device-support` |
| `homebrew-old` | moderate | Old installed formula/cask versions and unused dependencies (`brew autoremove`). | `--include-homebrew-old` |
| `timemachine` | moderate | Thins **local** Time Machine snapshots. Your real backups on an external drive are untouched. | `--include-timemachine` |
| `whatsapp` | moderate | WhatsApp's expired Status/Stories media only. Chat media and every database are untouched. | `--include-whatsapp` |
| `ide-stale` | moderate | Config/plugin folders of superseded JetBrains and Android Studio versions. Keeps the newest of each product. | `--include-ide-stale` |
| `ml-caches` | moderate | Hugging Face and PyTorch model caches. Without the flag it only *reports* sizes. Ollama and LM Studio models are never deleted, only reported. | `--include-ml-caches` |
| `toolchains` | moderate | Superseded Kotlin/Native prebuilts, Gradle wrapper distributions, Gradle's auto-provisioned JDKs, and every SDKMAN candidate except the one `current` points at. Keeps the newest `--keep-toolchains`. | `--include-toolchains` |
| `docker` | risky | **All** unused images, containers and volumes (`docker system prune -af --volumes`). | `--include-docker` |
| `mail` | risky | Mail.app's local download cache. | `--include-mail` |
| `sim-stale` | risky | Simulator devices unused for `--sim-stale-days`. Booted and never-booted devices are always kept. | `--include-sim-stale` |
| `android` | risky | Android system images no AVD references, plus AVDs unused for `--android-stale-days`. Confirms per AVD. | `--include-android` |
| `trash` | irreversible | Empties `~/.Trash`. Irreversible. | `--include-trash` |
| `orphans` | irreversible | Reports leftovers no installed app claims. Heuristic, never deletes — see [its section](#possible-app-leftovers). | `--include-orphans` |
| `ios-backups` | irreversible | Local iPhone/iPad backups in MobileSync. Confirms per backup with size and date. | `--include-ios-backups` |

### What `browsers` and `electron` touch

**Cleared** — all of it regenerates on demand:

```
Cache/  Code Cache/  GPUCache/  DawnCache/  DawnGraphiteCache/
DawnWebGPUCache/  GraphiteDawnCache/  ShaderCache/  GrShaderCache/
Media Cache/  Application Cache/  PnaclTranslationCache/  blob_storage/
Service Worker/CacheStorage/   Service Worker/ScriptCache/
Shared Dictionary/cache/  component_crx_cache/  extensions_crx_cache/
optimization_guide_model_store/  Crashpad/completed/  Crashpad/pending/
```

With `--aggressive` only — still pure cache, but each costs a fresh
several-hundred-MB download to rebuild: `Safe Browsing/`, `Snapshots/`,
`OnDeviceHeadSuggestModel/`, `SafetyTips/`, `Subresource Filter/`,
`FileTypePolicies/`, `MEIPreload/`.

**Never touched** — your logins, history and site data are safe:

```
Login Data   Cookies   History   Bookmarks   Web Data   Preferences
Secure Preferences   Local Storage   Session Storage   IndexedDB
Sessions   Extensions   Local Extension Settings   Sync Data
Network Action Predictor   Visited Links
```

---

## Choosing what runs

Three inputs decide the run list. In precedence order:

1. **`--skip <ids>`** — always wins, over everything below.
2. **`--only <ids>`** — if present, exactly these run and nothing else.
3. **A saved selection** — if you saved one from the interactive menu, it
   replaces the built-in defaults for *every* invocation, scripted or not.
   Opt-in categories named in it get their `--include-*` gate opened
   automatically.
4. **Built-in defaults** — the `on` column of `--list`.

On top of that, **any `--include-X` flag adds X to the run list**, whether or
not `--only` named it. `--skip` still removes it.

```bash
mimi --scan --only caches,logs,dsstore      # only these three
mimi --cleaner --skip homebrew,gradle         # defaults minus two
mimi --cleaner --include-trash                # defaults plus trash
mimi --cleaner --only browsers --include-docker-cache   # browsers + docker-cache
```

---

## Protecting paths: whitelist and presets

A whitelist entry is either:

- **An absolute path** (or `~/...`) — protects everything under it
- **A word or glob** (e.g. `com.adobe.*`) — protects any orphan candidate
  whose inferred name or bundle id matches

```bash
mimi --cleaner --whitelist ~/Library/Caches/JetBrains
mimi --cleaner --whitelist 'com.adobe.*,com.figma.*'
mimi --cleaner --whitelist ~/Dev --whitelist ~/Documents   # repeatable
```

Whitelisted paths are reported as `whitelisted, skipped:` so you can see the
protection working.

### Presets

| Name | Protects |
|---|---|
| `xcode-simulator` | `~/Library/Developer/CoreSimulator` + iOS DeviceSupport |
| `xcode-derived` | Xcode `DerivedData` |
| `node` | npm / yarn / pnpm caches |
| `browsers` | Chrome, Firefox, Brave, Edge and Arc profile data |
| `ml` | Hugging Face, torch, Ollama and LM Studio model caches |

```bash
mimi --cleaner --whitelist-preset xcode-simulator
mimi --cleaner --whitelist-preset browsers --whitelist-preset ml
```

---

## Possible app leftovers

`orphans` looks for config, preferences, caches, containers and LaunchAgents
whose names no installed application claims.

**It never deletes anything** — not with `--cleaner`, `--yes`, `--aggressive`
or `--force-risky`.
It writes a report. Removing any of it is a separate, deliberate step
(`--remove-orphans-from`).

That is because the scan reasons from **absence**: an entry is listed because
no installed app claimed its name, which is a guess rather than ownership. It
guesses wrong for apps that renamed themselves but kept their bundle id, beta
builds installed beside stable ones, helpers and updaters under a vendor
prefix, apps on an unmounted volume, and anything Spotlight has not indexed.

Results carry a confidence level:

- **`[strong]`** — Containers, WebKit, HTTPStorages, Cookies, Saved
  Application State, or an Application Support folder itself named like a
  bundle id, with no installed app claiming that id. macOS names these by
  bundle id, so the name is real evidence.
- **`[weak]`** — Preferences, ByHost, LaunchAgents, Application Scripts,
  plainly-named Application Support folders, anonymous UUID containers, and
  **everything** when the installed-app index is incomplete. Not evidence
  that anything was uninstalled.

Anything under `com.apple.*`, known bare macOS service names, well-known
shared vendor folders (Adobe, Google, Microsoft, Dropbox, iCloud…) and
`Group Containers` is excluded from the scan entirely.

If Spotlight is unavailable, returns nothing, or returns fewer apps than a
plain directory walk finds, the run says so and marks every candidate
`[weak]`.

```bash
# 1. Report only — nothing is touched, under any flag
mimi --only orphans --include-orphans --scan

# 2. Edit the generated review file — delete a line, or put a # in its FIRST
#    column, for anything to keep. Keep the header line: the file is refused
#    without it.

# 3. Remove exactly what remains
mimi --cleaner --remove-orphans-from ~/Library/Logs/mimi/orphans-review-<timestamp>.txt
```

---

## The disk report

```bash
mimi --report
```

Deletes nothing. It exists because the categories above only remove what is
safe to remove *automatically* — the rest of a full disk is usually things no
cleaner should decide about for you.

It prints, in order:

1. **What is in that "System Data" number** — the grey blob in Settings
   mapped onto real paths, split three ways:
   - `REDUCIBLE` — a category targets it, with the exact flag to use
   - `YOUR CALL` — real data, never removed automatically, with what to do
   - `LEAVE ALONE` — the OS and your installed software

   Sizes are whole-tree totals, not what you would actually free — each
   category keeps whatever is still in use.
2. **Top directories by size** across `~`, `/Applications`, `/opt/homebrew`
   and `/Library`
3. **Every folder over 1 GB** under your home directory
4. **Stale project `node_modules`** — untouched 90+ days, parent has a
   `package.json`. Extension-bundled `node_modules` are filtered out, since
   deleting those breaks the extension
5. **Volume accounting** and the local APFS snapshot count

It walks your whole home directory, so give it a few minutes.

> **"System Data" is not a folder.** It is whatever Finder could not file
> under Applications, Documents, Photos, Music, Mail or Developer. On a
> developer Mac it is mostly `~/Library`, the dot-directories in `$HOME`, and
> the OS trees outside `$HOME`. Purgeable space and APFS snapshots are only
> actually released on restart, which is when the Storage graph finally moves.

---

## Config file

`~/.config/mimi/config.conf`, written by **Save current selection +
settings as default** in the interactive menu. Loaded at the start of *every*
invocation, interactive or not. Plain `KEY=value`; edit it by hand if you
prefer.

| Key | Meaning |
|---|---|
| `KEEP_DEVICE_SUPPORT` | Same as `--keep-device-support` |
| `SIM_STALE_DAYS` | Same as `--sim-stale-days` |
| `ANDROID_STALE_DAYS` | Same as `--android-stale-days` |
| `TMP_STALE_DAYS` | Same as `--tmp-stale-days` |
| `KEEP_TOOLCHAINS` | Same as `--keep-toolchains` |
| `KEEP_LOGS` | Same as `--keep-logs` |
| `WHITELIST` | Comma-separated whitelist entries, merged with any `--whitelist` |
| `SELECTED_CATEGORIES` | Comma-separated ids. Replaces the built-in defaults; `--only` still overrides it |

Delete the file to go back to built-in defaults.

---

## Logs

Every run writes a full transcript to:

```
~/Library/Logs/mimi/clean-YYYYMMDD-HHMMSS.log
```

It includes the stderr of every delegated command (`brew`, `docker`, `npm`…),
which is where to look when a category reports less than you expected. **View
most recent log** in the interactive menu tails the newest one.

**The log directory is self-limiting.** A tool for removing junk should not
quietly become a source of it, so at the start of every run everything past
the newest `--keep-logs` transcripts (default 5) is pruned. Orphan review
files are kept for 30 days instead, since they are meant to be edited by hand
and fed back in.

Want none of it at all:

```bash
mimi --cleaner --no-log     # transcript goes to a scratch file, deleted on exit
mimi --cleaner --keep-logs 0  # write this run's log, keep nothing older
```

The `logs` category clears `~/Library/Logs/*` but explicitly skips
`mimi` — otherwise it would delete the transcript it is writing
mid-run, along with any orphan review file you had not acted on yet.

---

## Recipes

### A full cleanout, in order

```bash
# 0. Grant Full Disk Access, quit your browsers and Electron apps.
# 1. See where everything actually is — deletes nothing.
mimi --report

# 2. Scan, then clean the safe default set.
mimi --scan
mimi --cleaner

# 3. The opt-in wins, one at a time so you can see each result.
mimi --cleaner --only docker-cache --include-docker-cache   # start Docker first
mimi --cleaner --only toolchains --include-toolchains
mimi --cleaner --only ide-stale --include-ide-stale
mimi --cleaner --only android --include-android
mimi --cleaner --only ml-caches --include-ml-caches         # re-downloads models
mimi --cleaner --only ios-backups --include-ios-backups     # irreversible

# 4. Reboot — purgeable space and snapshots are only released on restart.
```

### Just the browser and Electron win

```bash
mimi --cleaner --only browsers,electron --yes
```

### A conservative weekly run

```bash
mimi --cleaner --yes \
  --skip timemachine,device-support \
  --whitelist-preset xcode-simulator
```

### Free space fast without touching anything downloadable

```bash
mimi --cleaner --only caches,tmp,logs,diagnostics,xcode-derived --yes
```

### Scriptable / cron

```bash
mimi --cleaner --yes --only caches,logs,tmp,dsstore >> ~/clean-cron.log 2>&1
```

`--yes` answers the ordinary prompts, and non-terminal stdin disables the
interactive menu and all colour, so output stays log-friendly.

A cron line that selects a risky or irreversible category needs `--force-risky`
as well, because there is no terminal to ask on:

```bash
mimi --cleaner --yes --only trash --include-trash --force-risky trash
```

Without it the run exits `5`, removes nothing at all, and names the flag it
needed.

### Confirmation classes

| Class | What it covers | What answers it |
|---|---|---|
| read-only | `--scan`, `--report`, the `orphans` report | nothing is asked |
| recoverable | caches, re-downloadable models, the whole-run gate | `--yes` |
| risky | `docker`, `mail`, `sim-stale`, `android` | `y/N` at a terminal, or `--force-risky <name>` |
| irreversible | `trash`, `ios-backups`, `orphans` | typing the action's own name at a terminal, or `--force-risky <name>` |

The check happens **before any category runs**, so an unauthorized scripted
run costs nothing rather than stopping part-way through.

---

## Safety model

- **Never runs as root**, never uses `sudo`.
- **Hard-coded refusal list.** `/`, `/System`, `/Library`, `/Applications`,
  `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/private`, `/Users` and `$HOME`
  itself can never be the target of a removal, regardless of category or
  whitelist bugs.
- **Scan is the default.** You have to ask for `--cleaner` explicitly.
- **Destructive categories are opt-in and confirmed**, per item where the
  items are individually meaningful (backups, AVDs, Simulator devices).
- **The whitelist is checked on every single path**, including each entry
  inside a directory being cleared.
- **Nothing is silently skipped.** Unreadable paths, whitelisted paths,
  running apps and items spared by an age threshold are all reported with a
  reason.

---

## Troubleshooting

**"Full Disk Access is NOT granted"** — see
[Before your first run](#before-your-first-run). Until you fix it, Chrome,
Brave, Edge, Firefox, Safari, Mail and device backups scan as 0 B.

**A category freed less than the scan estimated** — usually one of:
the app was still running and re-created its cache; a delegated tool
(`brew`, `pnpm`, `uv`) decided some entries were still referenced; or the
estimate counted a directory a tool only partially prunes. Check the log.

**"Docker daemon not responding"** — `docker info` is capped at 8 seconds.
Start Docker Desktop, wait for it to settle, then re-run.

**The `tmp` category skipped a huge directory** — it was modified within
`--tmp-stale-days`. Quit whatever owns it and re-run, lower the threshold, or
use `--aggressive` (which sets it to 0).

**The menu draws over itself** — resize your terminal and the next redraw
corrects itself. Below roughly 10 rows the viewport has no room; use the
flags directly instead.

**Storage in Settings has not moved** — reboot. Purgeable space and APFS
snapshots are only actually released on restart.

**Where are the old logs?** Only the newest `--keep-logs` (default 5) are
kept; the rest are pruned at the start of each run. Raise the number, or use
`--no-log` to keep none.

**Undo** — there is none. `--scan` first, whitelist what matters, and note
that `trash` and `ios-backups` in particular are genuinely irreversible —
which is why `--yes` cannot authorize either of them.
