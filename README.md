# mimi

A bash tool that finds and removes common macOS "junk" — caches, logs,
old Xcode build artifacts, package-manager caches, and more — and reports
how much space it freed. Built for Apple Silicon Macs with Xcode/iOS
Simulator workflows in mind.

```bash
mimi              # scan: show what would go, delete nothing
mimi --cleaner    # actually clean
```

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

`mimi` prints a loud warning at the top of every run if it is
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

Run `mimi --report` for the live breakdown on *your* machine. It
deletes nothing — it just tells you where the space went, including the
things no cleaner should ever delete for you.

## Interactive mode

Run it with no arguments from a real terminal and you get a menu instead of
a one-shot scan:

```bash
mimi
# or explicitly, even with other flags pre-set:
mimi -i
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
  `~/.config/mimi/config.conf`. From then on, *every* invocation
  (interactive or not) loads that file first: your saved whitelist entries
  and thresholds apply automatically, and if you saved a category
  selection, that becomes the new default set instead of the built-in
  defaults (CLI flags like `--only`/`--skip` still override it for that
  one run). Delete the file, or use the menu again, to change it.

This is meant to be the extension point going forward — adding a new
category is one `category_info()` line + one function + one
`category_include_var()` line, and it shows up in the interactive menu
automatically.

## Install

### Via Homebrew (Recommended)

```bash
brew install nkwabyte/mimi
```

### From source

```bash
git clone https://github.com/nkwabyte/mimi.git
cd mimi
./install.sh
```

That symlinks `bin/mimi` into the first writable directory it finds on your
`PATH` (`/usr/local/bin`, then Homebrew's `bin`, then `~/.local/bin`), and
tells you what to add to your shell profile if that directory is not on
`PATH` yet. Pick the location yourself with `./install.sh --prefix DIR`, and
undo it with `./install.sh --uninstall`.

It links rather than copies, so `git pull` here updates the installed command
too.

No install needed to try it — `./bin/mimi` works straight out of the checkout.

## Quick start

```bash
# 1. See what would be cleaned and how much space you'd get back (deletes nothing)
mimi
# or explicitly:
mimi scan

# 2. Actually clean it, confirming once
mimi --cleaner
# or:
mimi clean

# 3. Clean with safe developer profile (includes Xcode DerivedData, build artifacts)
mimi --cleaner --profile developer

# 4. Generate an immutable, reviewable plan before touching any file
mimi plan
# Validate and execute the plan with automatic quarantine:
mimi apply ~/.config/mimi/plans/plan-*.json

# 5. Restore or purge a quarantined run
mimi restore <run-id>
mimi purge <run-id>
```

`--scan` (or `mimi scan`, the default) **never deletes anything**. You always have to pass
`--cleaner` (or `mimi clean`) to remove files. `--clean` is accepted as well.

## Project layout

`bin/mimi` is the entry point; it loads the library in `lib/`.

```text
bin/mimi            # entry point: finds lib/, loads it, parses args, dispatches
install.sh          # symlinks bin/mimi onto your PATH
clean.sh            # deprecated shim for the tool's previous name
lib/
  load.sh           # single entry point: sources modules in order
  core/             # globals, util, validate, config, orchestrator (core.sh)
  safety/           # canonical path resolution, confirmation gates, checked mutation
  transaction/      # execution plans (plan.sh), quarantine & rollback (quarantine.sh)
  cleaners/         # category registry, clean handlers, orphan analysis
  ui/               # log, JSON Lines protocol v1, usage/help, report, interactive TUI
schemas/            # JSON Schema specifications (protocol-v1.json, plan-v1.json)
tests/              # bats suite; ./tests/run
docs/               # architectural scratchpad, usage reference
```

### The old name

This tool used to be `clean.sh`. That entry point still works and prints a
one-line notice on stderr pointing at `mimi`; nothing anyone scripted against
it breaks. It *sources* `bin/mimi` rather than exec'ing it, so it keeps running
under whichever bash invoked it and the tool keeps calling itself "clean.sh" in
its own messages.

Saved settings and logs move themselves on first run:
`~/.config/cleanmymac` → `~/.config/mimi`, and
`~/Library/Logs/cleanmymac` → `~/Library/Logs/mimi`. Your whitelist comes with
them — a whitelist that silently stopped being read would protect nothing.
Orphan review files written under the old name are still accepted.

## Protecting directories (whitelisting)

Use `--whitelist` to pass one or more entries that should never be touched,
no matter what category runs:

- An absolute path (or `~/...`) protects everything under it.
- A plain word or glob (e.g. `com.adobe.*`, `Steam*`) protects any
  `orphans` candidate whose inferred name/bundle-id matches it, regardless
  of where it's found — handy since orphan leftovers for one app can be
  scattered across five different directories.

```bash
mimi --cleaner --whitelist "$HOME/Library/Developer/CoreSimulator,$HOME/Library/Caches/SomeApp"
mimi --cleaner --include-orphans --whitelist "com.adobe.*,Vivaldi"
```

You can also repeat the flag:

```bash
mimi --cleaner --whitelist "$HOME/Library/Developer/CoreSimulator" --whitelist "$HOME/Library/Caches/SomeApp"
```

### Presets

Since Xcode/iOS Simulator files are the most common thing people want to
protect, there's a shortcut:

```bash
mimi --cleaner --whitelist-preset xcode-simulator
```

| Preset | Protects |
|---|---|
| `xcode-simulator` | `~/Library/Developer/CoreSimulator` and `~/Library/Developer/Xcode/iOS DeviceSupport` — keeps every simulator runtime, device, and device-support symbol set intact |
| `xcode-derived` | `~/Library/Developer/Xcode/DerivedData` |
| `node` | Yarn cache, `~/.npm`, and the pnpm store |

Presets and `--whitelist` can be combined and used multiple times.

## What it cleans

Run `mimi --list` to print the live list with current risk level
and default on/off state. As of writing:

| ID | Risk | Default | What it is |
|---|---|---|---|
| `browsers` | safe | on | Chromium-family browser caches (Chrome, Brave, Edge, Vivaldi, Opera, Arc, etc.) and Firefox startup/shader caches across all profiles |
| `electron` | safe | on | Electron app caches (Notion, Slack, VS Code, Postman, Claude, Discord...) including `Partitions/*` |
| `dev-caches` | safe | on | Toolchain caches: `uv cache prune`, `go clean -cache`, Trivy, GitHub Copilot, `gh`, gem, giget, Firebase, Playwright, Deno, Bazel, sccache, cargo registry cache, SwiftPM, JetBrains, `.dartServer` |
| `diagnostics` | safe | on | Old crash and diagnostic reports |
| `dsstore` | safe | on | Stray `.DS_Store` files under your home directory |
| `quicklook` | safe | on | QuickLook thumbnail cache (`qlmanage -r cache`) |
| `xcode-derived` | safe | on | Xcode `DerivedData` (build artifacts — safe to delete, Xcode rebuilds them) |
| `sim-caches` | safe | on | iOS Simulator's own cache files |
| `sim-unavailable` | safe | on | Deleted/unavailable iOS Simulator devices via `xcrun simctl delete unavailable` |
| `homebrew` | safe | on | Homebrew package download cache only (`brew cleanup -s --prune=all`) |
| `npm` | safe | on | `npm cache clean --force` |
| `yarn` | safe | on | `yarn cache clean` for Classic; `~/.yarn/berry/cache` for Berry |
| `pnpm` | safe | on | `pnpm store prune` (prunes unreferenced packages) |
| `cocoapods` | safe | on | `~/Library/Caches/CocoaPods` |
| `gradle` | safe | on | `~/.gradle/caches` |
| `pip` | safe | on | `pip cache purge` |
| `tmp` | safe | on | `$TMPDIR` (`/private/var/folders/.../T`) and per-user cache entries older than `--tmp-stale-days` (default 3) |
| `caches` | safe | **off** | Broad user app caches (`~/Library/Caches/*`, opt-in via `--include-caches` or aggressive profile) |
| `logs` | safe | **off** | Broad user log files (`~/Library/Logs/*`, opt-in via `--include-logs` or aggressive profile) |
| `docker-cache` | safe | **off** | Docker dangling build cache + untagged images (`docker builder prune -f`), shrinks `Docker.raw` |
| `claude-cache` | safe | **off** | Claude desktop app's standard Electron cache dirs only |
| `xcode-archives` | moderate | **off** | Old `.xcarchive` builds — only runs with `--aggressive` |
| `device-support` | moderate | **off** | Old Xcode iOS DeviceSupport symbol sets — keeps newest N (default 3, opt-in via `--include-device-support`) |
| `homebrew-old` | moderate | **off** | Old installed formula/cask versions and unused dependencies (`brew autoremove`, opt-in via `--include-homebrew-old`) |
| `timemachine` | moderate | **off** | Thins local Time Machine APFS snapshots (frees local disk, not your backups, opt-in via `--include-timemachine`) |
| `whatsapp` | moderate | **off** | WhatsApp's expired Status/Stories media cache only (real chat media untouched) |
| `ide-stale` | moderate | **off** | Config/plugin folders of superseded JetBrains and Android Studio versions |
| `ml-caches` | moderate | **off** | Hugging Face and PyTorch model caches. Ollama and LM Studio models are reported, never deleted |
| `toolchains` | moderate | **off** | Superseded Kotlin/Native prebuilts, Gradle wrapper dists, Gradle JDKs, SDKMAN candidates |
| `docker` | risky | **off** | `docker system prune -af --volumes` — ALL unused images, containers, and volumes |
| `mail` | risky | **off** | Mail.app local "Mail Downloads" cache |
| `sim-stale` | risky | **off** | iOS Simulator devices unused for `--sim-stale-days` (keeps recently-booted ones) |
| `android` | risky | **off** | Unreferenced Android system images and stale AVDs |
| `trash` | irreversible | **off** | Empties `~/.Trash` (requires confirmation or `--force-risky trash`) |
| `orphans` | irreversible | **off** | Leftover app config/prefs/support from uninstalled apps (report-only, writes review file) |
| `ios-backups` | irreversible | **off** | Local iPhone/iPad backups in MobileSync (requires confirmation or `--force-risky ios-backups`) |

## Preset profiles

`mimi` organizes categories into three preset profiles using `--profile <name>`:

| Profile | Target Audience | Categories Included |
|---|---|---|
| `safe` (default) | Daily cleanups | Regenerable app, browser, toolchain, and simulator caches |
| `developer` | Active developers | `safe` + Xcode DerivedData, build artifacts, and simulator caches |
| `aggressive` | Maximum reclamation | `developer` + broad caches/logs, Time Machine snapshot thinning, old Homebrew packages |

```bash
mimi --profile list               # list available profiles and descriptions
mimi --cleaner --profile developer # run developer profile
mimi --cleaner --profile safe --include-timemachine # customize with add-on flags
```

Precedence: `--only` > `--profile` > config `SELECTED_CATEGORIES` > config `PROFILE` > default (`safe`). `--skip` always wins over everything.

## Transactional plans and quarantine rollback

To guarantee safety, predictability, and undo capability, `mimi` supports an immutable plan and quarantine workflow:

1. **Plan** (`mimi plan`): Discovers cleanup targets and generates a cryptographically signed execution plan (`schemas/plan-v1.json`) with an action manifest, preflight checks, and candidate hashes. Deletes nothing.
   ```bash
   mimi plan --profile developer
   ```
2. **Apply** (`mimi apply <plan-file>`): Validates plan integrity (host binding, expiration, inode identity) and moves targets into an isolated quarantine store (`~/.config/mimi/quarantine/<run-id>`) instead of immediate permanent deletion.
   ```bash
   mimi apply ~/.config/mimi/plans/plan-20260924-120000-1234.json
   ```
3. **Restore** (`mimi restore <run-id>`): Restores any quarantined run back to its original filesystem paths if needed.
   ```bash
   mimi restore run-20260924-120000-1234
   ```
4. **Purge** (`mimi purge <run-id>`): Permanently deletes quarantined files after explicit verification.
   ```bash
   mimi purge run-20260924-120000-1234
   ```

## Automation and machine protocol (JSON Lines)

`mimi` provides a pure Bash JSON Lines protocol (`schemas/protocol-v1.json`) on stdout for GUI wrappers, agents, and CI pipelines:

```bash
mimi --jsonl --scan --only caches
```

* **Stdout**: Strictly formatted, newline-delimited JSON events (`hello`, `phase_started`, `candidate`, `action_result`, `phase_finished`, `run_finished`).
* **Stderr**: Human-readable logs and diagnostics.
* Zero external runtimes needed (no `jq` or `python` required at runtime).

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
mimi --cleaner --skip browsers,electron
# or protect specific browsers only:
mimi --cleaner --whitelist-preset browsers
```

## Finding the rest: `--report`

The categories above only remove things that are safe to remove
automatically. The other half of a bloated dev Mac is stuff no cleaner
should ever delete for you — SDKs, VM images, model weights, datasets,
`node_modules`. `--report` finds them and deletes nothing:

```bash
mimi --report
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

> **This category never deletes anything.** Not with `--cleaner`, not with
> `--yes`, not with `--aggressive`, not with `--force-risky`. It writes a
> report. The only way any of it can be removed is to read that report, decide
> for yourself, and pass it back with `--remove-orphans-from` — which is
> itself an irreversible-class action needing a terminal or
> `--force-risky orphans`.

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
`~/Library/Logs/mimi/orphans-review-<timestamp>.txt` listing every
candidate (both tiers) with its size. Open it, delete the line — or put a `#`
in its **first column** — for anything you recognize as still in use, save,
then run:

```bash
mimi --cleaner --remove-orphans-from "~/Library/Logs/mimi/orphans-review-<timestamp>.txt"
```

A `#` anywhere other than the first column is part of the filename, so a
folder genuinely named `Foo#1` survives the round trip intact.

That file is treated as untrusted input, not as a list of paths to delete.
Before anything is removed, and again immediately before each individual
removal:

- the file must still carry the `# mimi-orphan-review v1` header this
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
mimi --only orphans --include-orphans --scan

# 2. Open the generated review file. Delete the line — or put a # in its
#    first column — for everything you want to KEEP.

# 3. Remove exactly what is left:
mimi --cleaner --remove-orphans-from "<path from step 1 output>"
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
mimi --cleaner --include-whatsapp --yes
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
mimi --cleaner --include-sim-stale --sim-stale-days 45
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
mimi --cleaner --include-claude-cache --yes
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
mimi --cleaner --include-android --android-stale-days 45
```

"Safe" categories only ever remove files that the owning app/tool
regenerates on its own. "Moderate" categories remove things that could
theoretically cost you a re-download or a few seconds of re-indexing.
"Risky" categories are opt-in only and off by default.

## Choosing exactly what runs

```bash
# Only run these categories, ignore everything else
mimi --cleaner --only caches,logs,dsstore,homebrew

# Run the normal default set, but skip Homebrew and Gradle
mimi --cleaner --skip homebrew,gradle

# List every category id, its risk level, and whether it's on by default
mimi --list
```

`--skip` always wins, even over `--only` or the defaults.

## Other options

| Flag | What it does |
|---|---|
| `--profile <name>` | Select a category profile (`safe`, `developer`, `aggressive`, or `list` to view) |
| `--report` | Print where your disk space actually went, then exit. Deletes nothing. |
| `--no-log` | Leave no log file behind at all |
| `--keep-logs N` | Past run logs to keep (default 5, 0 = none). Older ones are pruned every run |
| `--include-timemachine` | Thin local Time Machine APFS snapshots (opt-in) |
| `--include-device-support` | Prune old Xcode iOS DeviceSupport symbols (opt-in) |
| `--include-homebrew-old` | Prune old installed Homebrew formulae/casks and unused deps (opt-in) |
| `--include-caches` | Clean broad user app caches `~/Library/Caches/*` (opt-in) |
| `--include-logs` | Clean user logs `~/Library/Logs/*` (opt-in) |
| `--include-ide-stale` | Remove superseded JetBrains / Android Studio version folders |
| `--include-ml-caches` | Clear the Hugging Face + PyTorch model caches |
| `--include-ios-backups` | Delete local iPhone/iPad backups (asks per backup) |
| `--force-risky <names>` | Authorize risky/irreversible actions by name for this run — see below |

```
--scan                    Report only, delete nothing (default)
--cleaner                 Actually remove junk (--clean also accepted)
-y, --yes                 Answer the ordinary prompts. Cannot answer a risky
                          or irreversible one — see "What --yes can answer"
--profile NAME            Select profile: safe (default), developer, aggressive
--force-risky NAMES       Authorize risky/irreversible actions by name, for
                          this run only: docker, mail, trash, orphans,
                          sim-stale, android, ios-backups
-v, --verbose              Print every file/dir as it's inspected or removed
--aggressive               Also prune Xcode archives and DeviceSupport down to 1 version
--keep-device-support N    How many DeviceSupport versions to keep (default 3)
--include-timemachine      Thin local Time Machine snapshots
--include-device-support   Prune old Xcode iOS DeviceSupport symbols
--include-homebrew-old     Clean old installed Homebrew versions and autoremove
--include-caches           Clean broad user app caches (~/Library/Caches/*)
--include-logs             Clean user log files (~/Library/Logs/*)
--include-trash            Opt into emptying ~/.Trash
--include-mail             Opt into clearing Mail's download cache
--include-docker           Opt into `docker system prune -af --volumes`
--include-orphans          Opt into REPORTING possible app leftovers (never
                           deletes; see --remove-orphans-from)
--remove-orphans-from FILE Remove exactly the paths listed in a reviewed
                           orphans report this tool wrote
--include-whatsapp         Opt into WhatsApp's expired Status/Stories cache
--include-sim-stale        Opt into removing long-unused Simulator devices
--sim-stale-days N         Staleness threshold for --include-sim-stale (60)
--include-claude-cache     Opt into clearing Claude desktop app's cache
--include-android          Opt into unreferenced Android images/stale AVDs
--android-stale-days N     Staleness threshold for --include-android (60)
-h, --help                 Full usage
```

## Exit codes

`mimi` uses distinct, deterministic exit codes so scripts can tell why a run stopped:

| Exit code | Meaning | Description |
|---|---|---|
| `0` | Success | Every selected action completed successfully. |
| `1` | Usage error | A flag was unknown, a numeric/name argument was invalid, or config was corrupt. |
| `3` | Partial failure | The run completed, but at least one command or deletion step encountered an error. |
| `4` | Interrupted | A signal (SIGINT / `Ctrl-C` or SIGTERM) stopped the run before completion. |
| `5` | Cancelled / Refused | A required interactive confirmation or `--force-risky` authorization was not given. |


## Recommended order for a big cleanout

```bash
# 0. Grant Full Disk Access (see top) and quit your browsers.
# 1. See where everything actually is — deletes nothing.
mimi --report

# 2. Scan the safe default set.
mimi --scan

# 3. Clean it.
mimi --cleaner

# 4. The opt-in wins, one at a time so you can see each result.
mimi --cleaner --only docker-cache --include-docker-cache
mimi --cleaner --only ide-stale --include-ide-stale
mimi --cleaner --only android --include-android
mimi --cleaner --only ml-caches --include-ml-caches      # re-downloads models
mimi --cleaner --only ios-backups --include-ios-backups  # irreversible

# 5. Reboot. Purgeable space and APFS snapshots are only actually released
#    on restart, which is when the Storage graph finally moves.
```

## What `--yes` can answer

`--yes` is the flag that ends up in a cron line and is never looked at again.
So it answers the prompts you would always have said yes to, and nothing else.

Every prompt belongs to one of four classes:

| Class | What it means | What answers it |
|---|---|---|
| **read-only** | Nothing is removed | Nothing is asked: `--scan`, `--report`, the `orphans` report |
| **recoverable** | It comes back by itself — a cache that refills, a model that re-downloads — plus the whole-run "proceed?" gate | `--yes` |
| **risky** | Real loss, but bounded: `docker`, `mail`, `sim-stale`, `android` | A `y/N` at a terminal, **or** `--force-risky <name>` |
| **irreversible** | No other copy exists: `trash`, `ios-backups`, `orphans` | Typing the action's own name at a terminal, **or** `--force-risky <name>` |

So this does **not** empty your Trash:

```bash
mimi --cleaner --yes --include-trash        # exits 5, removes nothing
```

It tells you exactly what it needs instead:

```
This run has no terminal to ask for confirmation on, and these actions
cannot be authorized by --yes:
  trash  (irreversible) — authorize with: --force-risky trash
Nothing was removed. Re-run from a terminal, or add the flags above.
```

And this does:

```bash
mimi --cleaner --yes --include-trash --force-risky trash
```

Three things about `--force-risky` are deliberate:

- **It has no `all`.** You name each action, so the flag cannot outlive the
  reason you added it.
- **It authorizes; it does not select.** `--include-trash` is still required.
  Neither flag is dangerous on its own.
- **It is never saved.** It cannot be set in `~/.config/mimi/config.conf`, and
  saving your settings never writes it there.

At a terminal you are still asked, `--force-risky` or not — and for an
irreversible action, "y" is not accepted:

```
Permanently empty ~/.Trash.
This cannot be undone. Type trash to confirm, anything else to skip.
>
```

The check runs **before any category does**, so a scripted run that is missing
an authorization removes nothing at all rather than stopping half way.

## Safety notes

- **Dry-run by default.** Nothing is deleted unless you pass `--clean`.
- **Hard-coded guard rails.** The script refuses to operate on `/`,
  `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/etc`, `/var`,
  `/Users`, or your home directory itself, regardless of category logic
  or whitelist bugs.
- **Never runs as root / never asks for sudo.** Everything it touches is
  writable by your own user account.
- **Every run is logged** to `~/Library/Logs/mimi/clean-<timestamp>.log`,
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
- **`--yes` cannot authorize irreversible work.** Emptying the Trash, deleting
  device backups and removing reviewed remnants each need either a terminal
  confirmation or `--force-risky <name>`; see
  [What `--yes` can answer](#what---yes-can-answer).

Every run ends with a breakdown, and the exit status matches it:

```
Actions: 412 succeeded, 7 skipped, 3 permission-denied, 0 failed
```

| Exit | Meaning |
|---|---|
| `0` | Everything asked for was done |
| `1` | Invalid usage |
| `3` | Finished, but at least one action failed or was refused by the system |
| `4` | A signal stopped the run before it finished |
| `5` | A confirmation was declined, or could not be obtained at all |

A `3` usually means Full Disk Access is not granted. It is reported rather
than hidden, because "the tool did not do what you asked" is something a
script needs to be able to detect.

## Recommended first run

```bash
mimi --scan --whitelist-preset xcode-simulator
```

Look over the output, then when you're happy:

```bash
mimi --cleaner --whitelist-preset xcode-simulator --yes
```
