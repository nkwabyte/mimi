# clean.sh — complete usage reference

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

Make it executable once:

```bash
chmod +x clean.sh
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

`clean.sh` prints a warning at the top of every run if this is missing, and
marks each directory it could not read with `no permission to read:`.

### Quit the apps you are about to clean

A running Chrome, Notion or VS Code holds its cache files open and re-creates
them immediately, so the space does not come back until it exits. The script
detects running apps and warns you — it never kills anything.

---

## Quick start

```bash
./clean.sh                 # bare invocation from a terminal → interactive menu
./clean.sh --scan          # report what would be freed, delete nothing
./clean.sh --clean         # actually clean, asks once to confirm
./clean.sh --clean --yes   # no prompts at all
./clean.sh --report        # where did my disk space go? deletes nothing
./clean.sh --list          # every category id, risk level, default state
./clean.sh --help          # full flag list
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

### `--clean`

Does the work. Prompts once before starting unless `--yes` is given, and
prompts again per item for the genuinely destructive categories
(`docker`, `ios-backups`, `ml-caches`, `sim-stale`, `android`).

```
  cleared: ~/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage  (freed 8.4G)

== Summary ==
Space freed this run: 18.6G
Free space before: 48G  ->  after: 67G
```

---

## Interactive mode

Entered by running `./clean.sh` with **no arguments at all** from a real
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

### Modes

| Flag | Effect |
|---|---|
| `--scan` | Report only, delete nothing. **Default.** |
| `--clean` | Actually delete. Confirms once unless `--yes`. |
| `--report` | Print a full disk breakdown, then exit. Deletes nothing. |
| `--list` | Print every category id, risk and default state, then exit. |
| `-i`, `--interactive` | Force the menu even when other flags are present. |
| `-h`, `--help` | Print the built-in help, then exit. |

### Common options

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Never prompt. Use with care on opt-in categories. |
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
| `--remove-orphans-from <file>` | Remove exactly the paths listed in a review file produced by `--include-orphans`. The file must still carry its `# cleanmymac-orphan-review v1` header, `#` comments a line out only in the first column, and each path must resolve to a direct child of a scanned orphan location. Refused lines are reported with a reason code. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Everything asked for was done, including `--help`, `--list` and `--report` |
| `1` | Invalid usage, or you declined the confirmation prompt |
| `3` | The run finished, but at least one selected action failed or was refused by the system |
| `4` | A signal (Ctrl-C, `SIGTERM`) stopped the run before it finished |

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
otherwise.

Every invalid-usage message is written to **stderr** with the same prefix, so
it is easy to grep for in a wrapper script:

```
clean.sh: error: --only: unknown category 'cahces' (run './clean.sh --list' to see them all)
Try './clean.sh --help' for the full list of options.
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

`./clean.sh --list` prints the live list. Risk levels mean:

- **safe** — regenerated automatically, nothing is lost but time
- **moderate** — regenerated, but re-downloading or rebuilding costs real time
- **risky** — can remove data you actually wanted; always opt-in and confirmed

### On by default

| ID | Risk | What it removes |
|---|---|---|
| `browsers` | safe | Chromium-family caches across **every** profile (`Default`, `Profile 1..N`, Guest, System) for Chrome, Chrome Beta/Canary, Chrome for Testing, Chromium, Brave, Brave Beta, Edge, Vivaldi, Opera, Opera GX, Arc, Dia, Yandex, Comet — plus Firefox's startup and shader caches. Details [below](#what-browsers-and-electron-touch). |
| `electron` | safe | The same Chromium cache layout inside Electron apps — Notion, Slack, VS Code, Postman, Obsidian, Discord, Claude, pgAdmin and anything else with the layout — **including `Partitions/*`**, where the multi-GB `Service Worker/CacheStorage` hides. |
| `dev-caches` | safe | `uv cache prune`, `go clean -cache`, Trivy, GitHub Copilot, `gh`, gem, giget, Firebase, Playwright, Deno, Bazel, sccache, node-gyp, cargo registry cache, NuGet http caches, SwiftPM, JetBrains, `.dartServer`, `.gradle/.tmp`. |
| `caches` | safe | Everything under `~/Library/Caches/*`. |
| `tmp` | safe | `$TMPDIR` (`/private/var/folders/…/T`) and the matching per-user cache dir, for entries older than `--tmp-stale-days`. Anything newer is **reported with its size** but left alone — a running process may be using it. Apple's live IPC dirs are always skipped. |
| `logs` | safe | `~/Library/Logs/*`. |
| `diagnostics` | safe | Old crash and diagnostic reports. |
| `dsstore` | safe | Stray `.DS_Store` files under your home directory. |
| `quicklook` | safe | QuickLook thumbnail cache (`qlmanage -r cache`). |
| `xcode-derived` | safe | Xcode `DerivedData`. Xcode rebuilds it. |
| `sim-caches` | safe | The iOS Simulator's own cache directory. |
| `sim-unavailable` | safe | Simulator devices Xcode already marked unavailable (`xcrun simctl delete unavailable`). |
| `device-support` | moderate | Old Xcode iOS DeviceSupport symbol sets, keeping the newest `--keep-device-support`. |
| `homebrew` | safe | `brew autoremove` (uninstalls formulae that only existed as a dependency of something you removed), then `brew cleanup -s --prune=all`. |
| `npm` | safe | `npm cache clean --force`. |
| `yarn` | safe | `yarn cache clean` for Yarn Classic; for Yarn Berry (v2+, which has no `yarn cache dir`) it clears `~/.yarn/berry/cache` directly. |
| `pnpm` | safe | `pnpm store prune`. |
| `cocoapods` | safe | `~/Library/Caches/CocoaPods`. |
| `gradle` | safe | `~/.gradle/caches`. |
| `pip` | safe | `pip cache purge`. |
| `timemachine` | moderate | Thins **local** Time Machine snapshots. Your real backups on an external drive are untouched. |

### Off by default (opt-in)

| ID | Risk | What it removes | Flag |
|---|---|---|---|
| `xcode-archives` | moderate | Old `.xcarchive` builds. You may need these for dSYMs or App Store resubmission. Only with `--aggressive`. | — |
| `docker-cache` | safe | Dangling Docker build cache and untagged images. Never touches running containers, named volumes or tagged images. | `--include-docker-cache` |
| `docker` | risky | **All** unused images, containers and volumes. | `--include-docker` |
| `mail` | risky | Mail.app's local download cache. | `--include-mail` |
| `trash` | risky | Empties `~/.Trash`. Irreversible. | `--include-trash` |
| `orphans` | risky | Reports leftovers no installed app claims. Heuristic, never deletes — see [its section](#possible-app-leftovers). | `--include-orphans` |
| `whatsapp` | moderate | WhatsApp's expired Status/Stories media only. Chat media and every database are untouched. | `--include-whatsapp` |
| `sim-stale` | moderate | Simulator devices unused for `--sim-stale-days`. Booted and never-booted devices are always kept. | `--include-sim-stale` |
| `claude-cache` | safe | The Claude desktop app's Electron cache dirs. Reports but never removes `vm_bundles`. | `--include-claude-cache` |
| `android` | moderate | Android system images no AVD references, plus AVDs unused for `--android-stale-days`. Confirms per AVD. | `--include-android` |
| `ide-stale` | moderate | Config/plugin/cache folders of superseded JetBrains and Android Studio versions. Keeps the newest of each product. | `--include-ide-stale` |
| `ml-caches` | moderate | Hugging Face and PyTorch model caches. Without the flag it only *reports* sizes. Ollama and LM Studio models are never deleted, only reported. | `--include-ml-caches` |
| `ios-backups` | risky | Local iPhone/iPad backups in MobileSync. Confirms per backup with size and date. | `--include-ios-backups` |
| `toolchains` | moderate | Superseded Kotlin/Native prebuilts, Gradle wrapper distributions, Gradle's auto-provisioned JDKs, and every SDKMAN candidate except the one `current` points at. Keeps the newest `--keep-toolchains`. | `--include-toolchains` |

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
./clean.sh --scan --only caches,logs,dsstore      # only these three
./clean.sh --clean --skip homebrew,gradle         # defaults minus two
./clean.sh --clean --include-trash                # defaults plus trash
./clean.sh --clean --only browsers --include-docker-cache   # browsers + docker-cache
```

---

## Protecting paths: whitelist and presets

A whitelist entry is either:

- **An absolute path** (or `~/...`) — protects everything under it
- **A word or glob** (e.g. `com.adobe.*`) — protects any orphan candidate
  whose inferred name or bundle id matches

```bash
./clean.sh --clean --whitelist ~/Library/Caches/JetBrains
./clean.sh --clean --whitelist 'com.adobe.*,com.figma.*'
./clean.sh --clean --whitelist ~/Dev --whitelist ~/Documents   # repeatable
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
./clean.sh --clean --whitelist-preset xcode-simulator
./clean.sh --clean --whitelist-preset browsers --whitelist-preset ml
```

---

## Possible app leftovers

`orphans` looks for config, preferences, caches, containers and LaunchAgents
whose names no installed application claims.

**It never deletes anything** — not with `--clean`, `--yes` or `--aggressive`.
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
./clean.sh --only orphans --include-orphans --scan

# 2. Edit the generated review file — delete a line, or put a # in its FIRST
#    column, for anything to keep. Keep the header line: the file is refused
#    without it.

# 3. Remove exactly what remains
./clean.sh --clean --remove-orphans-from ~/Library/Logs/cleanmymac/orphans-review-<timestamp>.txt
```

---

## The disk report

```bash
./clean.sh --report
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

`~/.config/cleanmymac/config.conf`, written by **Save current selection +
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
~/Library/Logs/cleanmymac/clean-YYYYMMDD-HHMMSS.log
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
./clean.sh --clean --no-log     # transcript goes to a scratch file, deleted on exit
./clean.sh --clean --keep-logs 0  # write this run's log, keep nothing older
```

The `logs` category clears `~/Library/Logs/*` but explicitly skips
`cleanmymac` — otherwise it would delete the transcript it is writing
mid-run, along with any orphan review file you had not acted on yet.

---

## Recipes

### A full cleanout, in order

```bash
# 0. Grant Full Disk Access, quit your browsers and Electron apps.
# 1. See where everything actually is — deletes nothing.
./clean.sh --report

# 2. Scan, then clean the safe default set.
./clean.sh --scan
./clean.sh --clean

# 3. The opt-in wins, one at a time so you can see each result.
./clean.sh --clean --only docker-cache --include-docker-cache   # start Docker first
./clean.sh --clean --only toolchains --include-toolchains
./clean.sh --clean --only ide-stale --include-ide-stale
./clean.sh --clean --only android --include-android
./clean.sh --clean --only ml-caches --include-ml-caches         # re-downloads models
./clean.sh --clean --only ios-backups --include-ios-backups     # irreversible

# 4. Reboot — purgeable space and snapshots are only released on restart.
```

### Just the browser and Electron win

```bash
./clean.sh --clean --only browsers,electron --yes
```

### A conservative weekly run

```bash
./clean.sh --clean --yes \
  --skip timemachine,device-support \
  --whitelist-preset xcode-simulator
```

### Free space fast without touching anything downloadable

```bash
./clean.sh --clean --only caches,tmp,logs,diagnostics,xcode-derived --yes
```

### Scriptable / cron

```bash
./clean.sh --clean --yes --only caches,logs,tmp,dsstore >> ~/clean-cron.log 2>&1
```

`--yes` suppresses all prompts, and non-terminal stdin disables the
interactive menu and all colour, so output stays log-friendly.

---

## Safety model

- **Never runs as root**, never uses `sudo`.
- **Hard-coded refusal list.** `/`, `/System`, `/Library`, `/Applications`,
  `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/private`, `/Users` and `$HOME`
  itself can never be the target of a removal, regardless of category or
  whitelist bugs.
- **Scan is the default.** You have to ask for `--clean` explicitly.
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
that `trash` and `ios-backups` in particular are genuinely irreversible.
