#!/usr/bin/env bash
#
# lib/usage.sh — The --help text.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

usage() {
  cat <<'EOF'
mimi — macOS junk cleaner (Xcode/simulator aware)

USAGE:
  mimi [--scan | --cleaner] [options]

MODES:
  --scan                 Report reclaimable space only. Deletes nothing. (default)
  --clean                Actually remove junk. Prompts for confirmation unless --yes.
  -i, --interactive       Menu-driven mode: toggle categories, edit the
                          whitelist, tune thresholds, run scan/clean, save
                          your selection as the new default. Also entered
                          automatically when you run mimi with no
                          arguments at all from a real terminal (any flag —
                          including --scan — keeps it fully scriptable).
                          Settings saved from the menu persist to
                          ~/.config/mimi/config.conf.

COMMON OPTIONS:
  -y, --yes              Do not prompt for confirmation before deleting.
  -v, --verbose           Print extra detail (paths being inspected/removed).
  --only <list>           Comma-separated category ids to run (see --list).
  --skip <list>           Comma-separated category ids to exclude.
  --list                  Print all category ids, descriptions, risk level, then exit.
  --report                Print a breakdown of where your disk space actually
                          went — top directories, folders over 1 GB, stale
                          node_modules, snapshots and volume accounting —
                          then exit. Deletes nothing. Use this to find the
                          things no cleaner should delete for you (VM disks,
                          SDKs, model weights, datasets).
  --aggressive            Also enable stricter pruning (older Xcode device support,
                          more Xcode archive/log trimming). Still respects whitelist.
  --keep-device-support N Number of Xcode iOS DeviceSupport versions to keep (default 3).

OPT-IN (destructive / can remove wanted data — off unless requested):
  --include-trash         Empty ~/.Trash (irreversible).
  --include-mail          Clear Mail app's local "Mail Downloads" cache.
  --include-docker-cache   Run `docker builder prune -f` + `docker image
                          prune -f` — only dangling build cache and untagged
                          images. Never touches running containers, named
                          volumes, or tagged images. This is what actually
                          shrinks Docker Desktop's Docker.raw VM disk, which
                          `docker system prune` alone does not reclaim from.
  --include-docker        Run `docker system prune -af --volumes` (removes ALL
                          unused images/containers/volumes, not just old ones,
                          more aggressive than --include-docker-cache above).
  --include-orphans        REPORT ONLY. Scan for leftover config/prefs/caches/
                          containers/LaunchAgents whose names no installed
                          application claims. This never removes anything,
                          under any flag, in any mode: it writes a review
                          file you edit by hand and pass back with
                          --remove-orphans-from <file>.
                          Matching is a name/bundle-id heuristic, reported
                          at two confidence levels:
                            [strong] the folder is named by bundle id
                                     (Containers, WebKit, HTTPStorages,
                                     Cookies, Saved Application State, or an
                                     Application Support folder itself named
                                     like a bundle id) and no installed app
                                     claims that id.
                            [weak]   the name is a guess: bare-word folders,
                                     Preferences/ByHost/LaunchAgents full of
                                     macOS service names, anonymous UUIDs, or
                                     anything at all when the app index turned
                                     out to be incomplete. A [weak] entry is
                                     NOT evidence that an app was uninstalled.
                          An app that renamed itself, keeps helpers under its
                          own prefix, or lives on a volume that is not mounted
                          will show up here while still being in use.
                          Never touches anything under com.apple.*, known
                          bare macOS service names, or well-known shared
                          vendor folders (Adobe, Google, Microsoft, Dropbox,
                          iCloud, etc). Preview safely first with:
                            mimi --only orphans --include-orphans --scan
  --remove-orphans-from <file>
                          Remove exactly the paths listed in a review file
                          produced by --include-orphans. Edit it first: delete
                          a line, or put a # in its FIRST column, for anything
                          you want to keep. A # anywhere else on the line is
                          part of the filename. Still asks to confirm unless
                          --yes.
                          The file must be one this tool wrote (it is refused
                          without its header line), and only direct children
                          of the locations --include-orphans scans are
                          accepted, so this is not a general
                          delete-these-paths flag. Every refused line is
                          reported with a reason code.
  --include-whatsapp       Remove WhatsApp's expired Status/Stories media
                          cache only (Message/Media/<id>.status folders —
                          these expire after 24h on WhatsApp's own servers
                          anyway). Real conversation media and every
                          database (ChatStorage.sqlite, contacts, etc.) are
                          never touched.
  --include-sim-stale       Delete iOS Simulator devices not booted in
                          --sim-stale-days (default 60). Currently-booted
                          and never-booted (fresh default) devices are
                          always left alone. Lists every device by name
                          before asking to confirm.
  --sim-stale-days N        Staleness threshold for --include-sim-stale.
  --include-claude-cache    Clear only the Claude desktop app's standard
                          Electron cache dirs (Cache, Code Cache, GPUCache,
                          etc). Never touches conversation/session state.
                          Reports (does not remove) vm_bundles, the local
                          agent-mode VM image, since it's not a cache.
  --include-toolchains      Remove superseded SDK/compiler toolchains: Kotlin/
                          Native prebuilts, Gradle wrapper distributions,
                          Gradle's auto-provisioned JDKs, and every SDKMAN
                          candidate except the one `current` points at. Keeps
                          the newest --keep-toolchains of each (default 1).
  --keep-toolchains N       How many versions of each toolchain to keep.
  --no-log                  Do not leave a log file behind at all. Output
                          still goes to the terminal; the transcript lives in
                          a scratch file that is deleted when the run ends.
  --keep-logs N             Number of past run logs to keep in
                          ~/Library/Logs/mimi (default 5, 0 = none).
                          Older ones are pruned at the start of every run,
                          so this tool does not become the junk it removes.
  --tmp-stale-days N        Age threshold for the `tmp` category (default 3).
                          Entries in $TMPDIR newer than this are reported but
                          left alone, since a running process may be using
                          them. --aggressive sets this to 0.
  --include-ide-stale       Remove the config/plugin/cache folders left behind
                          by superseded JetBrains and Android Studio versions.
                          The newest release of each product is always kept.
  --include-ml-caches       Clear the Hugging Face and PyTorch model caches.
                          Without this flag the sizes are reported only.
                          Ollama and LM Studio models are never deleted, only
                          reported — remove those from inside each app.
  --include-ios-backups     Delete local iPhone/iPad backups from MobileSync.
                          Asks per backup, showing size and date. Irreversible
                          unless you also have an iCloud backup.
  --include-android         Remove Android system images no AVD references,
                          and AVDs not used in --android-stale-days (default
                          60). Lists every candidate and asks to confirm
                          per AVD (AVDs hold their own app data/snapshots).
  --android-stale-days N    Staleness threshold for --include-android.

WHITELIST (protect paths from being touched):
  --whitelist <items>     Comma-separated entries to exclude. Repeatable.
                          An absolute path (or ~/...) protects everything
                          under it. A plain word/glob (e.g. "com.adobe.*")
                          instead protects any orphan candidate whose
                          inferred name/bundle-id matches it.
  --whitelist-preset <name>
                          Expand a named preset into the whitelist. Presets:
                            xcode-simulator  -> CoreSimulator + iOS DeviceSupport
                                                (protects simulator runtimes/binaries)
                            xcode-derived    -> Xcode DerivedData
                            node             -> npm/yarn/pnpm caches
                            browsers         -> Chrome/Firefox/Brave/Edge/Arc
                                                profile data (skip all browser
                                                cleaning)
                            ml               -> Hugging Face/torch/Ollama/
                                                LM Studio model caches

  -h, --help              Show this help.

EXAMPLES:
  mimi                                   # scan only, see what would be freed
  mimi --clean                            # clean safe categories, ask to confirm
  mimi --clean --yes                      # clean safe categories, no prompts
  mimi --clean --whitelist-preset xcode-simulator
  mimi --clean --only caches,logs,dsstore --yes
  mimi --clean --include-trash --include-mail --yes
  mimi --report                           # where did my disk space go?
  mimi --clean --only browsers,electron --yes   # the big browser/Electron win

FULL DISK ACCESS:
  macOS protects ~/Library/Application Support/{Google/Chrome,Firefox,
  BraveSoftware,Microsoft Edge}, ~/Library/Safari and ~/Library/Mail behind
  TCC. Without Full Disk Access your terminal cannot even read them: they
  scan as 0 B and cannot be cleaned, which is why browser junk survives every
  run and keeps showing up as "System Data" in Settings > General > Storage.

  Grant it once: System Settings > Privacy & Security > Full Disk Access >
  add your terminal app (Terminal, iTerm, Ghostty, VS Code, Warp...), enable
  it, then fully quit and reopen the terminal. This script warns you at the
  start of every run if it is missing.

INTERACTIVE CONTROLS:
  Every screen is arrow-key driven; nothing needs a number typed at it.
    Main menu   up/down move, enter selects, q quits.
    Categories  up/down move, space toggles, enter scans, c cleans,
                a all, x none, r reset, PgUp/PgDn/g/G jump, q back.
    Settings    up/down move, left/right adjust a number or flip a switch,
                enter types an exact value, q back.
    Whitelist   up/down move, space removes the highlighted entry, a adds,
                p applies a preset, q back.
  Number keys still work, and the old typed menus are used automatically when
  stdin is not a terminal.
EOF
}
