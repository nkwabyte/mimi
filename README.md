# CleanMyMac (clean.sh)

A bash script that finds and removes common macOS "junk" — caches, logs,
old Xcode build artifacts, package-manager caches, and more — and reports
how much space it freed. Built for Apple Silicon Macs with Xcode/iOS
Simulator workflows in mind.

It never touches anything outside categories you enable, always scans
before it cleans, and lets you protect any directory with `--whitelist`
so it's never touched.

## Grant Full Disk Access first — otherwise browser junk is invisible

**Do this before anything else.** macOS protects a handful of directories
behind TCC:

- `~/Library/Application Support/Google/Chrome`
- `~/Library/Application Support/Firefox`
- `~/Library/Application Support/BraveSoftware`
- `~/Library/Application Support/Microsoft Edge`
- `~/Library/Safari`, `~/Library/Mail`, `~/Library/Messages`
- `~/Library/Application Support/MobileSync` (iPhone backups)

Without Full Disk Access your terminal cannot even *read* them. `du`
reports them as 0 B and `rm` fails silently, so browser caches survive
every clean and keep showing up as unexplained "System Data". Chrome
alone routinely hoards 10+ GB there.

1. System Settings → Privacy & Security → **Full Disk Access**
2. Add and enable your terminal app (Terminal, iTerm, Ghostty, Warp, VS
   Code — whichever one you run the script from)
3. **Fully quit and reopen** the terminal (a reload is not enough)

`clean.sh` prints a loud warning at the top of every run if it is
missing, and marks each directory it could not read.

## Why "System Data" is huge in Storage settings

macOS lumps a lot of things into the grey "System Data" bucket: app
caches, logs, Xcode build products, Simulator devices/runtimes, local
Time Machine snapshots, and purgeable space. This script targets the
parts of that bucket that are genuinely safe to remove (they get
regenerated automatically) — it does not and cannot touch actual macOS
system files, and it never runs as root.

"System Data" is not a folder — it is whatever Finder failed to
categorise. On a developer Mac it is overwhelmingly:

| What | Where | Handled by |
|---|---|---|
| Browser + Electron caches | `~/Library/Application Support/<app>` | `browsers`, `electron` |
| Docker's VM disk | `~/Library/Containers/com.docker.docker` | `docker-cache` |
| Xcode device-support + simulators | `~/Library/Developer` | `device-support`, `sim-*` |
| Android SDK system images / NDK | `~/Library/Android/sdk` | `android` |
| Model weights | `~/.cache/huggingface`, `~/.ollama` | `ml-caches` (opt-in) |
| Toolchain caches | `~/.cache`, `~/.gradle`, `~/.konan` | `dev-caches`, `gradle` |
| `node_modules` you forgot about | anywhere in `~` | reported by `--report` |
| Purgeable space + APFS snapshots | invisible | `timemachine`, reboot |

Run `./clean.sh --report` for the live breakdown on *your* machine. It
deletes nothing — it just tells you where the space went, including the
things no cleaner should ever delete for you.

## Interactive mode

Run it with no arguments from a real terminal and you get a menu instead of
a one-shot scan:

```bash
./clean.sh
# or explicitly, even with other flags pre-set:
./clean.sh -i
```

(Any flag at all — including `--scan` — keeps the script fully scriptable/
non-interactive, exactly as documented below. Only a truly bare invocation
from an actual terminal enters the menu.)

The menu is keyboard-driven — arrow keys to move, enter to select:

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

- **Choose categories & run** — a live checklist of every category
  (including all the opt-in ones from this doc — WhatsApp, orphans,
  Android, etc.):

  ```
  Choose categories  (19/33 selected)
    ↑/↓ move   space toggle   enter run scan   c clean   a all   x none   r reset   q back

  ❯ [x] browsers         safe     Chrome/Brave/Edge/Arc/Vivaldi/Opera/Firefox caches
    [x] electron         safe     Electron app caches (Notion, Slack, VS Code...)
    [ ] ios-backups      risky    Local iPhone/iPad backups in MobileSync
    — showing 1-18 of 33 —
  ```

  | Key | Does |
  |---|---|
  | `↑` `↓` / `k` `j` | move (wraps around) |
  | `space` / `→` | toggle the highlighted category |
  | `enter` / `s` | run a **scan** with exactly what is checked |
  | `c` | run a **clean** with exactly what is checked |
  | `a` / `x` | select all / clear all |
  | `r` | reset to your saved defaults |
  | `PgUp` `PgDn` `g` `G` | jump around a long list |
  | `q` / `esc` | back to the main menu |

  Risk levels are colour-coded (green safe, yellow moderate, red risky) so
  a destructive category is hard to tick by accident, and the list scrolls
  when it does not fit your terminal. Toggling an opt-in category here
  automatically sets its `--include-*` flag too — no need to remember flag
  names. Number keys still work, and if stdin is not a terminal (a pipe, a
  CI job) the script falls back to the old typed-number menu automatically.
- **Settings** and **Manage whitelist** are arrow-driven too:

  ```
  Settings
    ↑/↓ move   ←/→ adjust   enter edit or toggle   q back

    Xcode DeviceSupport versions to keep        3
    Temp file age threshold (days)              3
  ❯ Aggressive mode (prunes harder)             on
    Verbose output                              off
  ```

  `←`/`→` nudge a number or flip a switch without typing; `enter` opens a
  prompt when you want an exact value. In the whitelist, `space` removes the
  highlighted entry, `a` adds one, `p` opens a preset picker.

- **Manage whitelist** — add/remove entries or apply a preset
  (`xcode-simulator`, `xcode-derived`, `node`, `browsers`, `ml`) without
  re-typing paths on the command line.
- **Settings** — adjust `--keep-device-support`, `--sim-stale-days`,
  `--android-stale-days`, and toggle aggressive/verbose/assume-yes.
- **Save current selection + settings as default** — writes everything to
  `~/.config/cleanmymac/config.conf`. From then on, *every* invocation
  (interactive or not) loads that file first: your saved whitelist entries
  and thresholds apply automatically, and if you saved a category
  selection, that becomes the new default set instead of the built-in
  defaults (CLI flags like `--only`/`--skip` still override it for that
  one run). Delete the file, or use the menu again, to change it.

This is meant to be the extension point going forward — adding a new
category is one `category_info()` line + one function + one
`category_include_var()` line, and it shows up in the interactive menu
automatically.

## Quick start

```bash
chmod +x clean.sh

# 1. See what would be cleaned and how much space you'd get back (safe, deletes nothing)
./clean.sh

# 2. Actually clean it, confirming once
./clean.sh --clean

# 3. Actually clean it without any prompts
./clean.sh --clean --yes
```

`--scan` (the default) **never deletes anything**. You always have to
pass `--clean` to remove files.

## Project layout

`./clean.sh` is the documented entry point and always will be — it is a small
shim over `bin/cleanmymac`, which loads the library in `lib/`.

```text
clean.sh            # compatibility shim; sources bin/cleanmymac
bin/cleanmymac      # entry point: finds lib/, loads it, parses args, dispatches
lib/
  load.sh           # sources the modules below, in order
  globals.sh        # every variable the rest of the tool reads
  log.sh            # the run transcript and the say/info/ok/warn/err family
  util.sh           # size formatting and measurement
  validate.sh       # argument and configuration validation
  usage.sh          # the --help text
  config.sh         # ~/.config/cleanmymac/config.conf
  path.sh           # canonical path resolution and containment checks
  action.sh         # the checked removal layer
  core.sh           # categories, the orphan scan, the report, the TUI, main()
tests/              # bats suite; ./tests/run
docs/               # plans, usage reference
```

`clean.sh` *sources* `bin/cleanmymac` rather than exec'ing it, so `./clean.sh`
keeps running under whichever bash you invoked it with and the tool keeps
calling itself "clean.sh" in its messages. Running `bin/cleanmymac` directly
works identically; it just calls itself "cleanmymac".

`lib/core.sh` is the part that has not been broken up yet, and it is the
largest file by far. Splitting it further is tracked in
[docs/CLI_IMPLEMENTATION_SCRATCHPAD.md](docs/CLI_IMPLEMENTATION_SCRATCHPAD.md).

## Protecting directories (whitelisting)

Use `--whitelist` to pass one or more entries that should never be touched,
no matter what category runs:

- An absolute path (or `~/...`) protects everything under it.
- A plain word or glob (e.g. `com.adobe.*`, `Steam*`) protects any
  `orphans` candidate whose inferred name/bundle-id matches it, regardless
  of where it's found — handy since orphan leftovers for one app can be
  scattered across five different directories.

```bash
./clean.sh --clean --whitelist "$HOME/Library/Developer/CoreSimulator,$HOME/Library/Caches/SomeApp"
./clean.sh --clean --include-orphans --whitelist "com.adobe.*,Vivaldi"
```

You can also repeat the flag:

```bash
./clean.sh --clean --whitelist "$HOME/Library/Developer/CoreSimulator" --whitelist "$HOME/Library/Caches/SomeApp"
```

### Presets

Since Xcode/iOS Simulator files are the most common thing people want to
protect, there's a shortcut:

```bash
./clean.sh --clean --whitelist-preset xcode-simulator
```

| Preset | Protects |
|---|---|
| `xcode-simulator` | `~/Library/Developer/CoreSimulator` and `~/Library/Developer/Xcode/iOS DeviceSupport` — keeps every simulator runtime, device, and device-support symbol set intact |
| `xcode-derived` | `~/Library/Developer/Xcode/DerivedData` |
| `node` | Yarn cache, `~/.npm`, and the pnpm store |

Presets and `--whitelist` can be combined and used multiple times.

## What it cleans

Run `./clean.sh --list` to print the live list with current risk level
and default on/off state. As of writing:

| ID | Risk | Default | What it is |
|---|---|---|---|
| `browsers` | safe | on | Chromium-family browser caches — Chrome, Chrome Beta/Canary, Chromium, Brave, Edge, Vivaldi, Opera, Arc, Yandex, Comet — across **every** profile (`Default`, `Profile 1..N`, Guest, System), plus Firefox's startup/shader caches. See the section below for exactly what is and is not touched |
| `electron` | safe | on | Electron app caches — Notion, Slack, VS Code, Postman, Obsidian, Discord, Claude, pgAdmin, and any other app with the Chromium layout — **including `Partitions/*`**, which is where the multi-GB `Service Worker/CacheStorage` hides |
| `dev-caches` | safe | on | Toolchain caches: `uv cache prune`, `go clean -cache`, Trivy, GitHub Copilot, `gh`, gem, giget, Firebase, Playwright, Deno, Bazel, sccache, cargo registry cache, SwiftPM, JetBrains, `.dartServer` |
| `caches` | safe | on | `~/Library/Caches/*` (per-app caches, e.g. browser/Electron app caches) |
| `logs` | safe | on | `~/Library/Logs/*` |
| `diagnostics` | safe | on | Crash/diagnostic reports |
| `dsstore` | safe | on | Stray `.DS_Store` files under your home directory |
| `quicklook` | safe | on | QuickLook thumbnail cache (`qlmanage -r cache`) |
| `xcode-derived` | safe | on | Xcode `DerivedData` (build products — always safe, Xcode rebuilds them) |
| `xcode-archives` | moderate | **off** | Old `.xcarchive` builds — only runs with `--aggressive` since you may need these for dSYMs/App Store resubmission |
| `sim-caches` | safe | on | iOS Simulator's own cache directory |
| `sim-unavailable` | safe | on | Deletes simulator devices Xcode already marked "unavailable" (orphaned runtimes) via `xcrun simctl delete unavailable` |
| `device-support` | moderate | on | Old Xcode "iOS DeviceSupport" symbol sets — keeps the N most recently used (default 3, see `--keep-device-support`) |
| `homebrew` | safe | on | `brew autoremove` (uninstalls formulae that only existed as a dependency of something you removed) followed by `brew cleanup -s --prune=all` |
| `npm` | safe | on | `npm cache clean --force` |
| `yarn` | safe | on | `yarn cache clean` for Yarn Classic; for Yarn Berry (v2+, which has no `yarn cache dir` and keeps a global store) it clears `~/.yarn/berry/cache` directly |
| `pnpm` | safe | on | `pnpm store prune` |
| `cocoapods` | safe | on | `~/Library/Caches/CocoaPods` |
| `gradle` | safe | on | `~/.gradle/caches` |
| `pip` | safe | on | `pip cache purge` |
| `timemachine` | moderate | on | Thins local Time Machine snapshots (frees local disk only — your actual backups on an external/Time Capsule drive are untouched) |
| `docker` | risky | **off** | `docker system prune -af --volumes` — removes ALL unused images/containers/volumes. Opt in with `--include-docker` |
| `mail` | risky | **off** | Mail.app's local "Mail Downloads" cache. Opt in with `--include-mail` |
| `trash` | risky | **off** | Empties `~/.Trash` — irreversible. Opt in with `--include-trash`, and it always asks to confirm |
| `orphans` | risky | **off** | Leftover config/prefs/caches/containers/LaunchAgents from apps you've uninstalled. Opt in with `--include-orphans`. See its own section below — this one is heuristic and split into two safety tiers |
| `whatsapp` | moderate | **off** | WhatsApp's expired Status/Stories media cache only. Opt in with `--include-whatsapp` |
| `sim-stale` | moderate | **off** | iOS Simulator devices unused for a long time. Opt in with `--include-sim-stale` |
| `claude-cache` | safe | **off** | Claude desktop app's standard Electron cache dirs only. Opt in with `--include-claude-cache` |
| `android` | moderate | **off** | Unreferenced Android system images + long-unused AVDs. Opt in with `--include-android` |
| `ide-stale` | moderate | **off** | Config/plugin/cache folders left behind by superseded JetBrains + Android Studio versions (300-500 MB each, and they stack up every release). The newest of each product is always kept. Opt in with `--include-ide-stale` |
| `ml-caches` | moderate | **off** | Hugging Face + PyTorch model caches. Without the flag it only *reports* the sizes. Ollama and LM Studio models are never deleted, only reported. Opt in with `--include-ml-caches` |
| `tmp` | safe | on | `$TMPDIR` (`/private/var/folders/…/T`) and the matching per-user cache dir, for entries older than `--tmp-stale-days` (default 3). macOS only sweeps these at boot, so abandoned test scratch and build temp pile up for weeks. Anything newer is **reported with its size** but left alone, since a running process may be using it |
| `toolchains` | moderate | **off** | Superseded Kotlin/Native prebuilts, Gradle wrapper distributions, Gradle's auto-provisioned JDKs, and non-active SDKMAN candidates. Keeps the newest `--keep-toolchains` (default 1) of each, and whatever SDKMAN's `current` points at. Opt in with `--include-toolchains` |
| `ios-backups` | risky | **off** | Local iPhone/iPad backups in `~/Library/Application Support/MobileSync/Backup`. Asks per backup with its size and date. Opt in with `--include-ios-backups` |

## Browser and Electron caches (`browsers`, `electron`)

These two are usually the biggest safe win on a machine that has been in use
for a while — Chrome and Notion in particular will happily sit on 10+ GB of
pure cache that nothing in macOS ever reclaims.

**Cleared** (all of it regenerates on demand):

```
Cache/  Code Cache/  GPUCache/  DawnCache/  DawnGraphiteCache/
DawnWebGPUCache/  GraphiteDawnCache/  ShaderCache/  GrShaderCache/
Media Cache/  Application Cache/  PnaclTranslationCache/  blob_storage/
Service Worker/CacheStorage/   Service Worker/ScriptCache/
Shared Dictionary/cache/  component_crx_cache/  extensions_crx_cache/
optimization_guide_model_store/  Crashpad/completed/  Crashpad/pending/
```

Plus, with `--aggressive` only (still pure cache, but each costs a fresh
several-hundred-MB download to rebuild): `Safe Browsing/`, `Snapshots/`,
`OnDeviceHeadSuggestModel/`, `SafetyTips/`, `Subresource Filter/`,
`FileTypePolicies/`, `MEIPreload/`.

**Never touched** — your logins, history and site data are safe:

```
Login Data   Cookies   History   Bookmarks   Web Data   Preferences
Secure Preferences   Local Storage   Session Storage   IndexedDB
Sessions   Extensions   Local Extension Settings   Sync Data
```

Two things worth knowing:

- **Quit the browser first.** A running Chrome holds its cache files open and
  re-creates them immediately, so the space does not come back until it
  exits. The script detects this and warns you rather than killing anything.
- **Full Disk Access is mandatory for Chrome, Brave, Edge and Firefox.** See
  the section at the top. Without it these show as `no permission to read`
  and are skipped.

Both categories are on by default. To skip browser cleaning entirely:

```bash
./clean.sh --clean --skip browsers,electron
# or protect specific browsers only:
./clean.sh --clean --whitelist-preset browsers
```

## Finding the rest: `--report`

The categories above only remove things that are safe to remove
automatically. The other half of a bloated dev Mac is stuff no cleaner
should ever delete for you — SDKs, VM images, model weights, datasets,
`node_modules`. `--report` finds them and deletes nothing:

```bash
./clean.sh --report
```

It opens with a **"what is in that System Data number"** table that maps the
grey blob in Settings onto real paths, split three ways:

```
REDUCIBLE — a category targets these
    31.2G  Docker VM disk (Docker.raw)   --only docker-cache --include-docker-cache
    17.9G  Android SDK images/NDK        --only android --include-android
    13.1G  Hugging Face model cache      --only ml-caches --include-ml-caches
YOUR CALL — real data, never removed automatically
    15.4G  Claude local-agent VM image   delete by hand if you do not use it
LEAVE ALONE — the OS and your installed software
    14.3G  macOS system files            leave alone
```

Sizes there are whole-tree totals, not what you would actually free — each
category keeps whatever is still in use. Then it prints:

- the top directories by size across `~`, `/Applications`, `/opt/homebrew`
  and `/Library`
- every folder over 1 GB under your home directory
- stale **project** `node_modules` (untouched 90+ days, parent has a
  `package.json`) — extension-bundled `node_modules` are filtered out
  because deleting those breaks the extension
- volume accounting and the local APFS snapshot count

It walks your whole home directory, so give it a few minutes.

## Orphaned application leftovers (`orphans`)

This scans everywhere macOS lets an app leave files behind after you drag its
`.app` to the Trash — `~/Library/Application Support`, `Containers`,
`Preferences`, `Preferences/ByHost`, `Saved Application State`, `WebKit`,
`HTTPStorages`, `Cookies`, `Application Scripts`, `LaunchAgents` — and
compares every entry against every app actually installed on your Mac
(found via Spotlight, so it doesn't matter where the app lives). Anything
left over with no matching installed app is a candidate.

> **This category never deletes anything.** Not with `--clean`, not with
> `--yes`, not with `--aggressive`. It writes a report. The only way any of
> it can be removed is to read that report, decide for yourself, and pass it
> back with `--remove-orphans-from`.

The reason is what the scan actually knows. It works by **absence**: an entry
is listed because no installed application claimed its name. That is not
ownership, and there are ordinary situations where the inference is simply
wrong — an app that renamed itself but kept its bundle id, a beta installed
next to a stable release, helpers and updaters filed under a vendor's prefix,
an app on a volume that is not mounted right now, or Spotlight not having
finished indexing. A first real-world run on a loaded dev machine turned up
both genuine leftovers (hundreds of MB from long-gone apps) and real
Apple/system files that must never be touched — `loginwindow.plist`,
`MobileMeAccounts.plist`, `pbs.plist`, the macOS pasteboard server.

Results are reported at two confidence levels, and the difference is how much
the *location* tells you, not whether anything gets deleted:

- **`[strong]`** — entries in `Containers`, `WebKit`, `HTTPStorages`,
  `Cookies`, `Saved Application State` (macOS itself names these by bundle
  id; apps don't get to choose), plus `Application Support` folders that are
  themselves named like a bundle id (e.g. `com.vendor.app`) — where no
  installed app claims that id. The name is real evidence here.
- **`[weak]`** — everything else: `Preferences`, `Preferences/ByHost`,
  `LaunchAgents` and `Application Scripts` (full of bare macOS service
  names), plain-English `Application Support` folders (an app can name that
  folder anything — "Vivaldi", "Qt", "dotnet"), anonymous UUID containers,
  and **every** candidate when the installed-app index turned out to be
  incomplete. A `[weak]` entry is not evidence that anything was
  uninstalled.

Anything under `com.apple.*`, known bare macOS service names, well-known
shared vendor folders (Adobe, Google, Microsoft, Dropbox, 1Password, …) and
`Group Containers` is excluded from the scan entirely.

If the installed-app index is incomplete — Spotlight unavailable, returning
nothing, or returning fewer apps than a plain directory walk finds — the run
says so prominently and marks every candidate `[weak]`, rather than reading
the missing apps as evidence that they were uninstalled.

Every run with `--include-orphans` writes a review file to
`~/Library/Logs/cleanmymac/orphans-review-<timestamp>.txt` listing every
candidate (both tiers) with its size. Open it, delete the line — or put a `#`
in its **first column** — for anything you recognize as still in use, save,
then run:

```bash
./clean.sh --clean --remove-orphans-from "~/Library/Logs/cleanmymac/orphans-review-<timestamp>.txt"
```

A `#` anywhere other than the first column is part of the filename, so a
folder genuinely named `Foo#1` survives the round trip intact.

That file is treated as untrusted input, not as a list of paths to delete.
Before anything is removed, and again immediately before each individual
removal:

- the file must still carry the `# cleanmymac-orphan-review v1` header this
  tool wrote — keep that first line, or the file is refused outright;
- every path is resolved to its real location, with symlinks followed and
  `..` rejected outright, so no line can point somewhere other than where it
  appears to;
- the result must be a **direct child** of one of the locations
  `--include-orphans` actually scans;
- `--whitelist` is re-checked;
- the target must still be the same object (device + inode) it was when the
  list was built.

Each refused line is reported with a stable reason code (`traversal`,
`not-orphan-root`, `not-direct-child`, `whitelisted`, `missing`,
`identity-changed`, …). Adding arbitrary paths to the file will not remove
them: this is not a general "delete these paths" flag.

**Recommended usage:**

```bash
# 1. Preview only — nothing is touched
./clean.sh --only orphans --include-orphans --scan

# 2. Open the generated review file. Delete the line — or put a # in its
#    first column — for everything you want to KEEP.

# 3. Remove exactly what is left:
./clean.sh --clean --remove-orphans-from "<path from step 1 output>"
```

A known limitation: matching is by the app's *technical* bundle id, not its
display name. Occasionally an app's actual bundle id doesn't match what its
leftover data uses (rebrands, beta channels, embedded helper processes) —
`--whitelist` (including glob patterns like `--whitelist "com.vendor.*"`)
is there for exactly this — protect anything you're not sure about before
running `--clean`.

## App-specific categories

These four exist because their apps stash large amounts of data outside
every location the categories above scan, and each needed its own
carefully-scoped logic to stay safe — a generic "delete this folder" rule
would have been wrong for all four.

### `whatsapp` — expired Status/Stories cache

WhatsApp Desktop caches every Status/Story you've viewed under
`Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/`, in
folders named `<id>.status`. Since Status updates expire after 24h on
WhatsApp's own servers regardless, this cache is pure disposable view
history — on one real machine it was **38GB** of a 38.3GB total in that
folder, while actual chat media (folders without the `.status` suffix) was
under 700MB. `--include-whatsapp` removes only the `.status`-suffixed
folders, plus WhatsApp's own `Library/Caches` and `Logs`. It never touches
`ChatStorage.sqlite`, `Axolotl.sqlite`, contacts, stickers, or any
non-`.status` media folder — those hold your actual conversation history.

```bash
./clean.sh --clean --include-whatsapp --yes
```

### `sim-stale` — long-unused Simulator devices

Beyond `sim-unavailable` (devices Xcode itself already marked orphaned),
this looks at every Simulator device's actual `lastBootedAt` timestamp (via
`xcrun simctl list devices -j`) and offers to delete ones untouched for
`--sim-stale-days` (default 60). A currently-booted device is never a
candidate, and a device that's *never* been booted (Xcode's fresh default
device set, a few MB each) is left alone too — there's nothing to gain from
removing those and Xcode just recreates them. Requires `python3` to parse
Simulator metadata (ships with Xcode's Command Line Tools).

```bash
./clean.sh --clean --include-sim-stale --sim-stale-days 45
```

### `claude-cache` — Claude desktop app cache

Clears only the standard Electron/Chromium cache directories (`Cache`,
`Code Cache`, `GPUCache`, the Dawn shader caches, `Crashpad`, `Shared
Dictionary`). Never touches `Local Storage`, `IndexedDB`, `Session
Storage`, `Partitions`, or `Preferences` — that's where session/app state
lives. If a `vm_bundles` folder is found (the local agent-mode VM image
used for Claude's local code execution features, tens of GB on a machine
that uses it), it's only **reported**, never removed automatically —
re-acquiring it isn't a simple redownload-on-next-launch in every case, so
that decision is left to you.

```bash
./clean.sh --clean --include-claude-cache --yes
```

### `android` — unreferenced system images + stale AVDs

Two independent checks:
- **System images** (`~/Library/Android/sdk/system-images/<api>/<tag>/<abi>`):
  removed only if zero AVDs reference it via their `config.ini`'s
  `image.sysdir.N` — reinstallable anytime through Android Studio's SDK
  Manager.
- **AVDs** (`~/.android/avd/*.avd`): flagged if unused for
  `--android-stale-days` (default 60), based on the emulator's own
  `userdata-qemu.img` modification time (a real "last ran" signal, not just
  the directory's). Each stale AVD asks to confirm individually, since
  deleting one removes any app data/snapshots inside it — recreating the
  AVD itself is quick, but its contents are not recoverable.

```bash
./clean.sh --clean --include-android --android-stale-days 45
```

"Safe" categories only ever remove files that the owning app/tool
regenerates on its own. "Moderate" categories remove things that could
theoretically cost you a re-download or a few seconds of re-indexing.
"Risky" categories are opt-in only and off by default.

## Choosing exactly what runs

```bash
# Only run these categories, ignore everything else
./clean.sh --clean --only caches,logs,dsstore,homebrew

# Run the normal default set, but skip Homebrew and Gradle
./clean.sh --clean --skip homebrew,gradle

# List every category id, its risk level, and whether it's on by default
./clean.sh --list
```

`--skip` always wins, even over `--only` or the defaults.

## Other options

| Flag | What it does |
|---|---|
| `--report` | Print where your disk space actually went, then exit. Deletes nothing. |
| `--no-log` | Leave no log file behind at all |
| `--keep-logs N` | Past run logs to keep (default 5, 0 = none). Older ones are pruned every run, so the cleaner does not become the junk it removes |
| `--include-ide-stale` | Remove superseded JetBrains / Android Studio version folders |
| `--include-ml-caches` | Clear the Hugging Face + PyTorch model caches |
| `--include-ios-backups` | Delete local iPhone/iPad backups (asks per backup) |


```
--scan                    Report only, delete nothing (default)
--clean                   Actually remove junk
-y, --yes                 Skip the confirmation prompt
-v, --verbose              Print every file/dir as it's inspected or removed
--aggressive               Also prune Xcode archives and DeviceSupport down to 1 version
--keep-device-support N    How many DeviceSupport versions to keep (default 3)
--include-trash            Opt into emptying ~/.Trash
--include-mail             Opt into clearing Mail's download cache
--include-docker            Opt into `docker system prune -af --volumes`
--include-orphans           Opt into REPORTING possible app leftovers (never
                            deletes; see --remove-orphans-from)
--remove-orphans-from FILE  Remove exactly the paths listed in a reviewed
                            orphans report this tool wrote (see "Orphaned
                            application leftovers" below)
--include-whatsapp          Opt into WhatsApp's expired Status/Stories cache
--include-sim-stale         Opt into removing long-unused Simulator devices
--sim-stale-days N          Staleness threshold for --include-sim-stale (60)
--include-claude-cache      Opt into clearing Claude desktop app's cache
--include-android           Opt into unreferenced Android images/stale AVDs
--android-stale-days N      Staleness threshold for --include-android (60)
-h, --help                  Full usage
```

## Recommended order for a big cleanout

```bash
# 0. Grant Full Disk Access (see top) and quit your browsers.
# 1. See where everything actually is — deletes nothing.
./clean.sh --report

# 2. Scan the safe default set.
./clean.sh --scan

# 3. Clean it.
./clean.sh --clean

# 4. The opt-in wins, one at a time so you can see each result.
./clean.sh --clean --only docker-cache --include-docker-cache
./clean.sh --clean --only ide-stale --include-ide-stale
./clean.sh --clean --only android --include-android
./clean.sh --clean --only ml-caches --include-ml-caches      # re-downloads models
./clean.sh --clean --only ios-backups --include-ios-backups  # irreversible

# 5. Reboot. Purgeable space and APFS snapshots are only actually released
#    on restart, which is when the Storage graph finally moves.
```

## Safety notes

- **Dry-run by default.** Nothing is deleted unless you pass `--clean`.
- **Hard-coded guard rails.** The script refuses to operate on `/`,
  `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/etc`, `/var`,
  `/Users`, or your home directory itself, regardless of category logic
  or whitelist bugs.
- **Never runs as root / never asks for sudo.** Everything it touches is
  writable by your own user account.
- **Every run is logged** to `~/Library/Logs/cleanmymac/clean-<timestamp>.log`,
  including which files were removed and any errors encountered.
- Cache/log directories have their *contents* removed, not the directory
  itself — apps that expect the folder to exist keep working.
- **Paths are resolved before they are trusted.** Symlinks are followed and
  `..` is rejected, so nothing can be reached by spelling a path a different
  way, and a symlinked cache directory is never followed out of the places
  the tool is allowed to touch.
- **The numbers are measured, not assumed.** A removal counts as successful
  only if the target is verifiably gone afterwards — `rm` returning 0 is not
  taken as evidence. Only successful actions contribute to "Space freed this
  run", so a permission-denied directory can never produce a cheerful,
  fictional total.
- **Ctrl-C does not kill it mid-delete.** The signal is recorded, the action
  in progress finishes, and nothing further starts.

Every run ends with a breakdown, and the exit status matches it:

```
Actions: 412 succeeded, 7 skipped, 3 permission-denied, 0 failed
```

| Exit | Meaning |
|---|---|
| `0` | Everything asked for was done |
| `1` | Invalid usage, or you declined a confirmation |
| `3` | Finished, but at least one action failed or was refused by the system |
| `4` | A signal stopped the run before it finished |

A `3` usually means Full Disk Access is not granted. It is reported rather
than hidden, because "the tool did not do what you asked" is something a
script needs to be able to detect.

## Recommended first run

```bash
./clean.sh --scan --whitelist-preset xcode-simulator
```

Look over the output, then when you're happy:

```bash
./clean.sh --clean --whitelist-preset xcode-simulator --yes
```
