#!/usr/bin/env bash
#
# lib/ui/usage.sh lib/usage.sh — The --help text.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

usage() {
  cat <<'EOF'
mimi — macOS junk cleaner (Xcode/simulator aware)

USAGE:
  mimi [scan | clean | plan | apply | restore | purge | apps | app] [options]
  mimi [--scan | --cleaner | --plan] [options]

SUBCOMMANDS:
  scan [options]          Report reclaimable space only. Deletes nothing.
  clean [options]         Actually remove junk with confirmation.
  plan [options]          Generate an immutable execution plan without mutating.
  apply <plan-file>       Validate and execute a plan using atomic quarantine.
  restore <run-id>        Restore a previously quarantined run to original paths.
  purge <run-id>          Permanently remove a quarantined run.
  apps [list] [options]   Inventory installed applications (read-only).
                          --source all|app|cask|mas|pkg|system   Filter by provenance.
                          --app-root DIR  Inventory DIR instead (repeatable).
                          --json          Emit schemas/apps-list-v1.json.
  app inspect <target>    Inspect an app's footprint, provenance, signing, and remnants
                          (read-only). Target resolves by exact path, bundle ID,
                          cask token, then name; ambiguity stops with the choices.
                          --json emits schemas/app-inspect-v1.json.
  app uninstall <target>  Uninstall an app (bundle + optional user data) via plan/quarantine.
                          Target: app name, bundle ID, cask token, or exact path.
                          Everything goes to a quarantine run (mimi restore undoes it).
                          --keep-data   Bundle and LaunchAgents only; user data is kept.
                          --purge-data  Also quarantine all attributable user data.
                          (default)     Asks once whether to include user data;
                                        without a terminal, or with --yes, keeps it.
                          --plan-only   Save the plan; apply later with `mimi apply`.
                          --cask        Hand the uninstall to Homebrew (cask apps only).
                          --zap         Homebrew --zap: also its listed prefs/caches;
                                        deleted by Homebrew, not restorable by mimi.
                          A running app is asked to quit; force-quitting needs a
                          terminal or --force-risky app-terminate (never --yes).

MODES:
  --scan                  Report reclaimable space only. Deletes nothing. (default)
  --cleaner               Actually remove junk. Prompts for confirmation; see
                          CONFIRMATIONS below for what --yes can and cannot
                          answer. --clean is still accepted as a synonym.
  --plan                  Generate an immutable plan file (synonym for 'plan').
  --apply <file>          Apply an execution plan (synonym for 'apply').
  --restore <run-id>      Restore a quarantined run (synonym for 'restore').
  --purge <run-id>        Permanently purge a quarantine run (synonym for 'purge').
  -i, --interactive       Menu-driven mode: toggle categories, edit the
                          whitelist, tune thresholds, run scan/clean, save
                          your selection as the new default. Also entered
                          automatically when you run mimi with no
                          arguments at all from a real terminal (any flag —
                          including --scan — keeps it fully scriptable).
                          Settings saved from the menu persist to
                          ~/.config/mimi/config.conf.

COMMON OPTIONS:
  -y, --yes               Answer the ordinary prompts: the whole-run "proceed?"
                          gate and anything that comes back on its own (a cache
                          that refills, a model that re-downloads). It cannot
                          answer a risky or irreversible prompt — see
                          CONFIRMATIONS below.
  --force-risky <list>    Explicitly authorize risky/irreversible actions by
                          name, for this invocation only, so they need no
                          terminal. Comma-separated, no "all", never read from
                          or saved to the config file. Valid names:
                            docker, mail, trash, orphans, sim-stale, android,
                            ios-backups
                          It authorizes; it does not select. The matching
                          --include-<name> is still required.
  -v, --verbose           Print extra detail (paths being inspected/removed).
  --only <list>           Comma-separated category ids to run (see --list).
  --skip <list>           Comma-separated category ids to exclude.
  --profile <name>        Select preset profile: safe (default, regenerable caches),
                          developer (safe + dev tools & build artifacts),
                          aggressive (safe + dev + broad caches/logs/Time Machine),
                          or 'list' to display profiles.
  --list                  Print all category ids, descriptions, risk level, then exit.
  --report                Print a breakdown of where your disk space actually
                          went — top directories, folders over 1 GB, the
                          largest single files, downloads not opened in a
                          while, stale node_modules, snapshots and volume
                          accounting — then exit. Deletes nothing.
  --large-file-mb N       --report: list files of at least N MB (default 500).
  --downloads-stale-days N
                          --report: list downloads not opened for N days
                          (default 90; judged by Spotlight's last-opened
                          date, never by modification time). Use this to find the
                          things no cleaner should delete for you (VM disks,
                          SDKs, model weights, datasets).
  --aggressive            Also enable stricter pruning (older Xcode device support,
                          more Xcode archive/log trimming). Still respects whitelist.
  --keep-device-support N Number of Xcode iOS DeviceSupport versions to keep (default 3).

OPT-IN (destructive / can remove wanted data — off unless requested):
  --include-trash         Empty ~/.Trash (irreversible; also needs a terminal
                          confirmation or --force-risky trash).
  --include-mail          Clear Mail app's local "Mail Downloads" cache (risky;
                          also needs a terminal confirmation or
                          --force-risky mail).
  --include-docker-cache   Run `docker builder prune -f` + `docker image
                          prune -f` — only dangling build cache and untagged
                          images. Never touches running containers, named
                          volumes, or tagged images. This is what actually
                          shrinks Docker Desktop's Docker.raw VM disk, which
                          `docker system prune` alone does not reclaim from.
  --include-docker        Run `docker system prune -af --volumes` (removes ALL
                          unused images/containers/volumes, not just old ones,
                          more aggressive than --include-docker-cache above).
  --include-orphans       Scan for leftover config/prefs/caches/containers/
                          LaunchAgents whose names no installed application
                          or installed command-line tool claims. On its own
                          it only reports (and writes a review file).
  --remove-orphans        Move EVERY leftover the scan finds, strong and weak,
                          to a quarantine run — no file to edit. Implies
                          --include-orphans; use with clean:
                            mimi clean --only orphans --remove-orphans
                          Undo with `mimi restore orphans-<timestamp>`; free
                          the space with `mimi purge orphans-<timestamp>`.
                          Whitelisted paths are never moved.
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
                          Remove a hand-picked subset instead: exactly the
                          paths listed in a review file
                          produced by --include-orphans. Edit it first: delete
                          a line, or put a # in its FIRST column, for anything
                          you want to keep. A # anywhere else on the line is
                          part of the filename. Removing reviewed items is
                          irreversible, so it always asks — --yes does not
                          answer it; --force-risky orphans does.
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
                          Irreversible unless you also have an iCloud backup,
                          so it asks you to type "ios-backups" once, then
                          confirms each backup by size and date. Scriptable
                          only via --force-risky ios-backups.
  --include-android         Remove Android system images no AVD references,
                          and AVDs not used in --android-stale-days (default
                          60). Lists every candidate and asks to confirm
                          per AVD (AVDs hold their own app data/snapshots).
  --android-stale-days N    Staleness threshold for --include-android.
  --include-timemachine     Thin local Time Machine snapshots (moderate risk,
                          thins local disk purgeable snapshots, not backups).
  --include-device-support  Prune older iOS DeviceSupport symbol sets (keeps
                          newest N versions, default 3).
  --include-homebrew-old    Prune old installed Homebrew formula/cask versions
                          and remove unused dependencies (`brew autoremove`).
  --include-caches          Clear all user application caches in ~/Library/Caches/*
                          (broad sweep, opt-in).
  --include-logs            Clear all user log files in ~/Library/Logs/*
                          (broad sweep, opt-in).

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

AUTOMATION & PROTOCOL:
  --jsonl, --json         Emit structured JSON Lines events to stdout for machine
                          integration (protocol v1). Diagnostics go to stderr.
  --request-id <id>       Correlation ID for protocol v1 events.
  --no-color              Suppress ANSI color escape codes in terminal output.
  --no-prompt             Do not prompt interactively; fail with exit 5 if
                          authorization is missing.

  -h, --help              Show this help.
  -V, --version           Print the version (mimi X.Y.Z) and exit.

CONFIRMATIONS:
  Every prompt belongs to a class, and the class decides what can answer it.

    read-only     Nothing is removed, so nothing is asked: --scan, --report,
                  and the --include-orphans report.
    recoverable   It comes back by itself (caches, re-downloadable models) and
                  the whole-run "proceed?" gate. --yes answers these.
    risky         Bounded but real loss: docker, mail, sim-stale, android.
                  A y/N at a terminal, or --force-risky <name>.
    irreversible  No other copy exists: trash, ios-backups, orphans. At a
                  terminal you type the action's own name, not "y"; otherwise
                  --force-risky <name>.

  --yes never authorizes a risky or irreversible action. If a run has no
  terminal to ask on and no --force-risky for what it selected, it says so and
  removes nothing, exiting 5.

EXIT CODES:
  0 success   1 usage error   3 partial failure   4 interrupted
  5 a required confirmation was declined or could not be obtained

EXAMPLES:
  mimi                                   # scan only, see what would be freed
  mimi --cleaner                          # clean safe categories, ask to confirm
  mimi --cleaner --yes                    # clean safe categories, ordinary prompts answered
  mimi --cleaner --whitelist-preset xcode-simulator
  mimi --cleaner --only caches,logs,dsstore --yes
  mimi --cleaner --yes --include-trash --force-risky trash    # both are needed
  mimi --report                           # where did my disk space go?
  mimi --cleaner --only browsers,electron --yes # the big browser/Electron win

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
