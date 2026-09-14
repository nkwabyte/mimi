# CleanMyMac (clean.sh)

A bash script that finds and removes common macOS "junk" — caches, logs,
old Xcode build artifacts, package-manager caches, and more — and reports
how much space it freed. Built for Apple Silicon Macs with Xcode/iOS
Simulator workflows in mind.

It never touches anything outside categories you enable, always scans
before it cleans, and lets you protect any directory with `--whitelist`
so it's never touched.

## Why "System Data" is huge in Storage settings

macOS lumps a lot of things into the grey "System Data" bucket: app
caches, logs, Xcode build products, Simulator devices/runtimes, local
Time Machine snapshots, and purgeable space. This script targets the
parts of that bucket that are genuinely safe to remove (they get
regenerated automatically) — it does not and cannot touch actual macOS
system files, and it never runs as root.

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
| `homebrew` | safe | on | `brew cleanup -s --prune=all` |
| `npm` | safe | on | `npm cache clean --force` |
| `yarn` | safe | on | `yarn cache clean` |
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

## Orphaned application leftovers (`orphans`)

This scans everywhere macOS lets an app leave files behind after you drag its
`.app` to the Trash — `~/Library/Application Support`, `Containers`,
`Preferences`, `Preferences/ByHost`, `Saved Application State`, `WebKit`,
`HTTPStorages`, `Cookies`, `Application Scripts`, `LaunchAgents` — and
compares every entry against every app actually installed on your Mac
(found via Spotlight, so it doesn't matter where the app lives). Anything
left over with no matching installed app is a candidate.

This is inherently **heuristic** (name/bundle-id matching, not a real
uninstall log), and a first real-world test run on a loaded dev machine
turned up both genuine orphans (leftover data from long-uninstalled apps,
some in the hundreds of MB) and real Apple/system files that must never be
touched (`loginwindow.plist`, `MobileMeAccounts.plist`, `pbs.plist` — the
macOS pasteboard server). Because of that, results are split into two
tiers and handled very differently:

- **`[auto]`** — high-confidence matches: entries in `Containers`, `WebKit`,
  `HTTPStorages`, `Cookies`, `Application Scripts`, `Saved Application
  State` (macOS itself names these by bundle id, apps don't get to choose),
  plus `Application Support` folders that are themselves named like a
  bundle id (e.g. `com.vendor.app`). These are offered for **immediate
  bulk removal** with one confirmation prompt (still skips anything under
  `com.apple.*`, known bare macOS service names, well-known shared vendor
  folders, and bare-UUID container names, which can't be reliably
  attributed to any single app).
- **`[review]`** — everything noisier: `Preferences`, `Preferences/ByHost`,
  `LaunchAgents`, and plain-English-named `Application Support` folders
  (an app can name this folder anything — "Vivaldi", "Qt", "dotnet" — so a
  miss here is much easier). These are **never auto-removed**, anywhere,
  under any flag. They only get written to a review file.

Every run with `--include-orphans` writes a review file to
`~/Library/Logs/cleanmymac/orphans-review-<timestamp>.txt` listing every
candidate (both tiers) with its size. Open it, delete or comment out (`#`)
any line for something you recognize as still in use, save, then run:

```bash
./clean.sh --clean --remove-orphans-from "~/Library/Logs/cleanmymac/orphans-review-<timestamp>.txt"
```

Paths in that file are re-validated before deletion (must still exist, must
be inside one of the scanned locations, still honors `--whitelist`) — it's
not a blind "rm every line."

**Recommended usage:**

```bash
# 1. Preview only — nothing is touched
./clean.sh --only orphans --include-orphans --scan

# 2. Bulk-remove just the high-confidence [auto] matches
./clean.sh --clean --only orphans --include-orphans

# 3. Review the noisier [review] items in the generated file, then:
./clean.sh --clean --remove-orphans-from "<path from step 1/2 output>"
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
--include-orphans           Opt into scanning for uninstalled-app leftovers
--remove-orphans-from FILE  Remove exactly the paths listed in a reviewed
                            orphans report (see "Orphaned application
                            leftovers" below)
--include-whatsapp          Opt into WhatsApp's expired Status/Stories cache
--include-sim-stale         Opt into removing long-unused Simulator devices
--sim-stale-days N          Staleness threshold for --include-sim-stale (60)
--include-claude-cache      Opt into clearing Claude desktop app's cache
--include-android           Opt into unreferenced Android images/stale AVDs
--android-stale-days N      Staleness threshold for --include-android (60)
-h, --help                  Full usage
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

## Recommended first run

```bash
./clean.sh --scan --whitelist-preset xcode-simulator
```

Look over the output, then when you're happy:

```bash
./clean.sh --clean --whitelist-preset xcode-simulator --yes
```
