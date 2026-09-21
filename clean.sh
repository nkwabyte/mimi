#!/usr/bin/env bash
#
# clean.sh — macOS junk cleaner (Apple Silicon safe, Xcode/simulator aware)
# Usage: see README.md or run ./clean.sh --help
#
# Written for bash 3.2+ compatibility (no associative arrays) since macOS's
# system /bin/bash is still 3.2 even when a newer bash is on PATH.

set -uo pipefail
shopt -s nullglob

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
HOME_DIR="$HOME"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HOME_DIR/Library/Logs/cleanmymac"
LOG_FILE="$LOG_DIR/clean-$TIMESTAMP.log"

MODE="scan"        # scan (dry-run, default) | clean
ASSUME_YES=0
VERBOSE=0
AGGRESSIVE=0
KEEP_DEVICE_SUPPORT=3
KEEP_SIM_LOGS_DAYS=7

INCLUDE_TRASH=0
INCLUDE_MAIL=0
INCLUDE_DOCKER=0
INCLUDE_DOCKER_CACHE=0
INCLUDE_ORPHANS=0
INCLUDE_WHATSAPP=0
INCLUDE_SIM_STALE=0
INCLUDE_CLAUDE_CACHE=0
INCLUDE_ANDROID=0
INCLUDE_IDE_STALE=0
INCLUDE_ML_CACHES=0
INCLUDE_IOS_BACKUPS=0
INCLUDE_TOOLCHAINS=0
REPORT_ONLY=0
NO_LOG=0
KEEP_LOGS=5
TMP_STALE_DAYS=3
KEEP_TOOLCHAINS=1

SIM_STALE_DAYS=60
ANDROID_STALE_DAYS=60

CONFIG_DIR="$HOME_DIR/.config/cleanmymac"
CONFIG_FILE="$CONFIG_DIR/config.conf"
CONFIG_SELECTED_CATEGORIES=""
INTERACTIVE=0

INSTALLED_IDS_NORM=()
INSTALLED_NAMES_NORM=()
_INSTALLED_BUILT=0

# Plain-English shared/vendor folder names that must never be auto-flagged as
# orphans even if no exact app match is found (substring match, e.g. "Adobe"
# also denylists "Adobe Common" if that ever showed up).
ORPHAN_DENYLIST=(adobe google microsoft mozilla dropbox 1password icloud
  clouddocs syncservices mobilesync crashreporter addressbook callhistory
  knowledge identityservices fileprovider cloudkit)

# Bare (non "com.apple.") system daemon/service names macOS itself owns.
# Discovered by scanning ~/Library/Preferences on a real machine: plenty of
# OS-level services (pasteboard server, login window, printing, spotlight
# helpers...) keep prefs here with no reverse-DNS prefix at all, so the
# com.apple.* check alone does not catch them.
ORPHAN_SYSTEM_DENYLIST=(loginwindow pbs mbuseragent scopedbookmarkagent
  sharedfilelistd corespotlightd diagnostics_agent contextstoreagent
  tokenbucketratelimiter askpermissiond locationaccessstored mobilemeaccounts
  org.cups.printingprefs org.sparkle-project.sparkle.autoupdate jbdeviceservice)

# root path :: token-normalization kind :: policy, scanned for orphaned app
# leftovers. Policy decides whether a match is safe to bulk auto-remove:
#   auto         -> macOS itself names these entries by bundle id, so a match
#                   is high-confidence (Containers, WebKit, HTTPStorages, ...)
#   dotted-auto  -> only auto-eligible when the leftover's name itself looks
#                   like a reverse-DNS bundle id (>=2 dots); apps are free to
#                   name their Application Support folder anything, so a bare
#                   word like "Caches" or "Qt" is NOT auto-eligible, only
#                   listed for manual review
#   report       -> never bulk auto-removed; Preferences/ByHost/LaunchAgents
#                   are too full of bare OS-service names to risk it — these
#                   only ever go in the human-reviewed removal file
#
# Group Containers are deliberately excluded entirely: they're shared across
# every app from the same vendor/group, and attribution to a single app
# isn't reliable.
ORPHAN_ROOTS=(
  "$HOME_DIR/Library/Application Support::plain::dotted-auto"
  "$HOME_DIR/Library/Containers::plain::auto"
  "$HOME_DIR/Library/Preferences::plist::report"
  "$HOME_DIR/Library/Preferences/ByHost::plist-byhost::report"
  "$HOME_DIR/Library/Saved Application State::savedstate::auto"
  "$HOME_DIR/Library/WebKit::plain::auto"
  "$HOME_DIR/Library/HTTPStorages::plain::auto"
  "$HOME_DIR/Library/Cookies::binarycookies::auto"
  "$HOME_DIR/Library/Application Scripts::plain::report"
  "$HOME_DIR/Library/LaunchAgents::plist::report"
)

REMOVE_ORPHANS_FILE=""

ONLY_LIST=""
SKIP_LIST=""
WHITELIST=()

TOTAL_BEFORE_KB=0
TOTAL_RECLAIMED_KB=0
RAN_ANY=0

# Colors (disabled if not a tty)
if [ -t 1 ]; then
  C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_CYAN="$(tput setaf 6)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

# A tool whose job is removing junk has no business leaving a growing pile of
# its own behind, so the log directory is capped at KEEP_LOGS runs and pruned
# on every start. --no-log skips the directory entirely and uses a scratch
# file that is deleted when the process exits.
prune_old_logs() {
  [ "${KEEP_LOGS:-0}" -gt 0 ] || return 0
  [ -d "$LOG_DIR" ] || return 0
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -le "$KEEP_LOGS" ] && continue
    rm -f "$f"
  done < <(ls -t "$LOG_DIR"/clean-*.log 2>/dev/null)
  # Orphan review files are meant to be edited by hand and fed back in, so
  # they are kept much longer than a transcript — but not forever.
  find "$LOG_DIR" -maxdepth 1 -name 'orphans-review-*.txt' -mtime +30 -delete 2>/dev/null
  return 0
}

# Single exit path: restore the cursor if a TUI screen was up, and drop the
# scratch log if --no-log was used. Installed by both log_init and tui_begin
# so whichever runs first wins and neither clobbers the other.
_cleanup_on_exit() {
  tui_end 2>/dev/null
  if [ "$NO_LOG" = 1 ] && [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    rm -f "$LOG_FILE"
  fi
  return 0
}

log_init() {
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  if [ "$NO_LOG" = 1 ]; then
    LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/cleanmymac-XXXXXX")" || LOG_FILE="/dev/null"
  else
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/clean-$TIMESTAMP.log"
    : > "$LOG_FILE"
    prune_old_logs
  fi
  trap '_cleanup_on_exit' EXIT INT TERM
}

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE" >/dev/null
}

say() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >> "$LOG_FILE"
}

section() {
  say ""
  say "${C_BOLD}${C_CYAN}== $* ==${C_RESET}"
}

info() { say "${C_DIM}  $*${C_RESET}"; }
ok()   { say "${C_GREEN}  $*${C_RESET}"; }
warn() { say "${C_YELLOW}  $*${C_RESET}"; }
err()  { say "${C_RED}  $*${C_RESET}"; }
verbose() { [ "$VERBOSE" = 1 ] && say "${C_DIM}    [v] $*${C_RESET}"; return 0; }

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Argument and configuration validation  (P0-T08)
#
# Every value that reaches arithmetic, find(1) or a category lookup is checked
# here first. The rules are identical whether the value came from the command
# line or from the saved config file, so a hand-edited config cannot smuggle
# past what the CLI would reject.
#
# Invalid usage always exits 1 with the same `clean.sh: error:` prefix, and
# always writes to stderr — this runs before any log file exists.
# ---------------------------------------------------------------------------

EXIT_USAGE=1

# Upper bound for every count/day setting. Generous enough that no real
# retention policy hits it, small enough that a typo or an overflow attempt
# does not reach arithmetic.
VALIDATE_INT_MAX=36500

die_usage() {
  printf 'clean.sh: error: %s\n' "$*" >&2
  printf "Try './%s --help' for the full list of options.\n" "$SCRIPT_NAME" >&2
  exit "$EXIT_USAGE"
}

# require_arg <flag> <remaining-arg-count> <candidate-value>
#
# Guards `$2` before anything reads it, so `set -u` can never surface a raw
# "unbound variable" to the user. A candidate that is itself a long option is
# treated as missing: `--only --scan` is a typo, not a category named
# "--scan". A leading single dash is allowed through so that a negative
# number reaches the numeric validator and gets its more specific message.
require_arg() {
  local flag="$1" remaining="$2" candidate="${3-}"
  if [ "$remaining" -lt 2 ]; then
    die_usage "$flag requires a value"
  fi
  case "$candidate" in
    --*) die_usage "$flag requires a value (got the option '$candidate')" ;;
  esac
  return 0
}

# validate_int <source-label> <value>
#
# Accepts a bounded non-negative integer and nothing else: no signs, no
# decimals, no whitespace, no empty string. <source-label> is the flag name
# for CLI values and a config-file description for config values, so the
# error always points at what the user actually has to edit.
validate_int() {
  local src="$1" val="${2-}"
  case "$val" in
    ''|*[!0-9]*)
      die_usage "$src expects a whole number between 0 and $VALIDATE_INT_MAX (got: '$val')" ;;
  esac
  if [ "$val" -gt "$VALIDATE_INT_MAX" ]; then
    die_usage "$src expects a whole number between 0 and $VALIDATE_INT_MAX (got: '$val')"
  fi
  return 0
}

is_known_category() {
  local needle="$1" id
  for id in $ALL_CATEGORY_IDS; do
    [ "$id" = "$needle" ] && return 0
  done
  return 1
}

# normalize_category_list <source-label> <comma-separated-list>
#
# Trims whitespace around each id, drops empty fields, removes duplicates and
# rejects anything that is not a real category. Prints the normalized list.
# An empty result is an error: `--only ""` almost certainly means the shell
# ate an argument, and silently running everything would be the worst
# possible interpretation.
normalize_category_list() {
  local src="$1" raw="$2" out="" item
  local oldifs="$IFS"
  IFS=','
  set -- $raw
  IFS="$oldifs"
  for item in "$@"; do
    # Strip surrounding whitespace (bash 3.2: no ${var//pattern} niceties
    # that handle this in one step reliably).
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] && continue
    if ! is_known_category "$item"; then
      die_usage "$src: unknown category '$item' (run './$SCRIPT_NAME --list' to see them all)"
    fi
    case ",$out," in
      *",$item,"*) continue ;;    # already present, drop the duplicate
    esac
    out="${out:+$out,}$item"
  done
  if [ -z "$out" ]; then
    die_usage "$src requires at least one category name"
  fi
  printf '%s' "$out"
}

# Applies the CLI validation rules to whatever the config file supplied, with
# an error that names the file and key rather than a flag the user never
# typed. Called once, after argument parsing.
validate_config_values() {
  local line key val
  local oldifs="$IFS"
  while IFS='	' read -r key val; do
    [ -z "$key" ] && continue
    validate_int "$CONFIG_FILE ($key)" "$val"
  done <<EOF
$CONFIG_NUMERIC_SEEN
EOF
  IFS="$oldifs"

  if [ -n "$CONFIG_SELECTED_CATEGORIES" ]; then
    CONFIG_SELECTED_CATEGORIES="$(normalize_category_list "$CONFIG_FILE (SELECTED_CATEGORIES)" "$CONFIG_SELECTED_CATEGORIES")" \
      || exit "$EXIT_USAGE"
  fi
  return 0
}

usage() {
  cat <<'EOF'
clean.sh — macOS junk cleaner (Xcode/simulator aware)

USAGE:
  ./clean.sh [--scan | --clean] [options]

MODES:
  --scan                 Report reclaimable space only. Deletes nothing. (default)
  --clean                Actually remove junk. Prompts for confirmation unless --yes.
  -i, --interactive       Menu-driven mode: toggle categories, edit the
                          whitelist, tune thresholds, run scan/clean, save
                          your selection as the new default. Also entered
                          automatically when you run ./clean.sh with no
                          arguments at all from a real terminal (any flag —
                          including --scan — keeps it fully scriptable).
                          Settings saved from the menu persist to
                          ~/.config/cleanmymac/config.conf.

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
  --include-orphans        Scan for leftover config/prefs/caches/containers/
                          LaunchAgents belonging to apps that are no longer
                          installed. Heuristic (name/bundle-id matching)
                          and split into two tiers:
                            [auto]   high-confidence matches (Containers,
                                     WebKit, HTTPStorages, Cookies, or an
                                     Application Support folder that's
                                     itself named like a bundle id) —
                                     offered for immediate bulk removal
                                     with one confirmation.
                            [review] everything noisier (Preferences,
                                     ByHost, LaunchAgents, plain-named
                                     Application Support folders) — NEVER
                                     auto-removed. Written to a review file
                                     you edit by hand, then removed with
                                     --remove-orphans-from <file>.
                          Never touches anything under com.apple.*, known
                          bare macOS service names, or well-known shared
                          vendor folders (Adobe, Google, Microsoft, Dropbox,
                          iCloud, etc). Preview safely first with:
                            ./clean.sh --only orphans --include-orphans --scan
  --remove-orphans-from <file>
                          Remove exactly the paths listed in a review file
                          produced by --include-orphans (comment out with #
                          any line you want to keep first). Still asks to
                          confirm unless --yes.
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
                          ~/Library/Logs/cleanmymac (default 5, 0 = none).
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
  ./clean.sh                                   # scan only, see what would be freed
  ./clean.sh --clean                            # clean safe categories, ask to confirm
  ./clean.sh --clean --yes                      # clean safe categories, no prompts
  ./clean.sh --clean --whitelist-preset xcode-simulator
  ./clean.sh --clean --only caches,logs,dsstore --yes
  ./clean.sh --clean --include-trash --include-mail --yes
  ./clean.sh --report                           # where did my disk space go?
  ./clean.sh --clean --only browsers,electron --yes   # the big browser/Electron win

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

# Numeric keys the config file supplied, as "KEY<TAB>value" lines. Validated
# by validate_config_values() after argument parsing, so that an unusable
# config still leaves --help and --list working — otherwise the user has no
# in-tool way to find out how to fix it.
CONFIG_NUMERIC_SEEN=""

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      ''|'#'*) continue ;;
    esac
    case "$key" in
      SIM_STALE_DAYS|ANDROID_STALE_DAYS|KEEP_DEVICE_SUPPORT|TMP_STALE_DAYS|KEEP_TOOLCHAINS|KEEP_LOGS)
        CONFIG_NUMERIC_SEEN="$CONFIG_NUMERIC_SEEN$key	$val
" ;;
    esac
    case "$key" in
      SIM_STALE_DAYS) SIM_STALE_DAYS="$val" ;;
      ANDROID_STALE_DAYS) ANDROID_STALE_DAYS="$val" ;;
      KEEP_DEVICE_SUPPORT) KEEP_DEVICE_SUPPORT="$val" ;;
      TMP_STALE_DAYS) TMP_STALE_DAYS="$val" ;;
      KEEP_TOOLCHAINS) KEEP_TOOLCHAINS="$val" ;;
      KEEP_LOGS) KEEP_LOGS="$val" ;;
      WHITELIST)
        local _wl
        IFS=',' read -r -a _wl <<< "$val"
        WHITELIST+=("${_wl[@]}")
        ;;
      SELECTED_CATEGORIES) CONFIG_SELECTED_CATEGORIES="$val" ;;
    esac
  done < "$CONFIG_FILE"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  local wl_joined="" w
  for w in "${WHITELIST[@]:-}"; do
    [ -z "$w" ] && continue
    wl_joined="${wl_joined:+$wl_joined,}$w"
  done
  local sel_joined="" i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && sel_joined="${sel_joined:+$sel_joined,}${CATEGORY_STATE_IDS[$i]}"
  done
  {
    printf '# clean.sh saved settings — edit by hand or via the interactive menu (-i)\n'
    printf 'SIM_STALE_DAYS=%s\n' "$SIM_STALE_DAYS"
    printf 'ANDROID_STALE_DAYS=%s\n' "$ANDROID_STALE_DAYS"
    printf 'KEEP_DEVICE_SUPPORT=%s\n' "$KEEP_DEVICE_SUPPORT"
    printf 'TMP_STALE_DAYS=%s\n' "$TMP_STALE_DAYS"
    printf 'KEEP_TOOLCHAINS=%s\n' "$KEEP_TOOLCHAINS"
    printf 'KEEP_LOGS=%s\n' "$KEEP_LOGS"
    printf 'WHITELIST=%s\n' "$wl_joined"
    printf 'SELECTED_CATEGORIES=%s\n' "$sel_joined"
  } > "$CONFIG_FILE"
  ok "settings saved to $CONFIG_FILE"
}

human_kb() {
  # $1 = size in KB (integer) -> human string
  local kb="${1:-0}"
  awk -v kb="$kb" 'BEGIN{
    split("K M G T", u, " ")
    v = kb + 0
    i = 1
    while (v >= 1024 && i < 4) { v = v / 1024; i++ }
    printf "%.1f%s", v, u[i]
  }'
}

# Real, resolved path (no trailing slash). Empty output if path does not exist
# and cannot be resolved as a plain string either.
resolve_path() {
  local p="$1"
  p="${p/#\~/$HOME_DIR}"
  if [ -e "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

dir_size_kb() {
  local p="$1"
  [ -e "$p" ] || { printf '0'; return; }
  # -x: never cross a mount point. Without it, anything containing a mounted
  # volume (most visibly /Library, which has the Xcode simulator runtime
  # volumes under Developer/CoreSimulator) reports several times its real
  # on-disk size and every total built from it is wrong.
  du -skx "$p" 2>/dev/null | awk '{print $1}' | tail -1
}

# Hard safety net: never operate on these regardless of whitelist/category bugs.
FORBIDDEN_EXACT=(
  "/" "/System" "/Library" "/Applications" "/usr" "/bin" "/sbin" "/etc" "/var"
  "/private" "/Users" "$HOME_DIR"
)

is_forbidden() {
  local target="$1" f
  for f in "${FORBIDDEN_EXACT[@]}"; do
    [ "$target" = "$f" ] && return 0
  done
  return 1
}

is_whitelisted() {
  local target
  target="$(resolve_path "$1")"
  local w wn
  for w in "${WHITELIST[@]:-}"; do
    [ -z "$w" ] && continue
    case "$w" in /*|\~*) ;; *) continue ;; esac   # skip identifier-style entries here
    wn="$(resolve_path "$w")"
    case "$target" in
      "$wn"|"$wn"/*) return 0 ;;
    esac
  done
  return 1
}

# Non-path whitelist entries (no leading / or ~) are treated as glob patterns
# matched against an orphan's inferred identifier/name, e.g. --whitelist "com.adobe.*"
is_identifier_whitelisted() {
  local token="$1" w matched=1
  shopt -s nocasematch
  for w in "${WHITELIST[@]:-}"; do
    [ -z "$w" ] && continue
    case "$w" in /*|\~*) continue ;; esac
    if [[ "$token" == $w ]]; then
      matched=0
      break
    fi
  done
  shopt -u nocasematch
  return "$matched"
}

normalize_token() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' _-'
}

is_apple_identifier() {
  local t
  t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    # matches com.apple.* directly, and also group.com.apple.* / <TEAMID>.com.apple.*
    # (macOS's own App Group / team-prefixed container naming conventions)
    *com.apple.*|apple) return 0 ;;
    *) return 1 ;;
  esac
}

# Anonymous sandbox container/script folder names (a bare UUID) can't be
# attributed to any app by name at all — they're just as likely to belong to
# a still-active extension of a currently-installed app as to an orphan, so
# never auto-remove them regardless of which root they were found under.
looks_like_uuid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

is_denylisted_identifier() {
  local t="$1" d
  for d in "${ORPHAN_DENYLIST[@]}"; do
    case "$t" in
      *"$d"*) return 0 ;;
    esac
  done
  for d in "${ORPHAN_SYSTEM_DENYLIST[@]}"; do
    [ "$t" = "$d" ] && return 0
  done
  return 1
}

# >=2 dots => looks like a reverse-DNS bundle id (com.foo.bar), which is the
# signal used to promote an Application Support entry to the "auto" tier.
looks_like_bundle_id() {
  local dots
  dots="$(printf '%s' "$1" | tr -cd '.' | wc -c | tr -d ' ')"
  [ "${dots:-0}" -ge 2 ]
}

_index_app() {
  local app="$1" id name
  [ -e "$app" ] || return
  id=""
  if command -v mdls >/dev/null 2>&1; then
    id="$(mdls -name kMDItemCFBundleIdentifier -raw "$app" 2>/dev/null)"
    [ "$id" = "(null)" ] && id=""
  fi
  if [ -z "$id" ] && command -v defaults >/dev/null 2>&1; then
    id="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)"
  fi
  name="$(basename "$app" .app)"
  [ -n "$id" ] && INSTALLED_IDS_NORM+=("$(normalize_token "$id")")
  INSTALLED_NAMES_NORM+=("$(normalize_token "$name")")
}

build_installed_identifiers() {
  [ "$_INSTALLED_BUILT" = 1 ] && return
  _INSTALLED_BUILT=1

  # Primary: ask Spotlight for every app bundle on the machine, wherever it
  # lives (catches apps outside the standard folders, e.g. dragged into
  # Downloads or a custom location) rather than trusting a fixed path list.
  if command -v mdfind >/dev/null 2>&1; then
    local app
    while IFS= read -r app; do
      _index_app "$app"
    done < <(mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null)
  fi

  # Supplement with a direct directory walk in case Spotlight is disabled,
  # not finished indexing, or excludes a volume.
  local roots=("/Applications" "/Applications/Utilities" "$HOME_DIR/Applications" "/System/Applications" "/System/Applications/Utilities")
  local root app
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    for app in "$root"/*.app; do
      _index_app "$app"
    done
  done

  verbose "indexed ${#INSTALLED_IDS_NORM[@]} bundle id(s) and ${#INSTALLED_NAMES_NORM[@]} app name(s) from installed applications"
}

is_installed_identifier() {
  local tok="$1" x
  [ -z "$tok" ] && return 0   # couldn't derive a token; treat as installed (skip) to be safe
  for x in "${INSTALLED_IDS_NORM[@]:-}"; do
    [ -n "$x" ] && [ "$tok" = "$x" ] && return 0
  done
  for x in "${INSTALLED_NAMES_NORM[@]:-}"; do
    [ -n "$x" ] && [ "$tok" = "$x" ] && return 0
  done
  # conservative containment match, catches helper/plugin folders named after the app
  for x in "${INSTALLED_NAMES_NORM[@]:-}" "${INSTALLED_IDS_NORM[@]:-}"; do
    [ -z "$x" ] && continue
    [ "${#x}" -lt 4 ] && continue
    case "$tok" in *"$x"*) return 0 ;; esac
    case "$x" in *"$tok"*) return 0 ;; esac
  done
  return 1
}

get_token_for_entry() {
  local kind="$1" name="$2"
  case "$kind" in
    plist) name="${name%.plist}" ;;
    plist-byhost)
      name="${name%.plist}"
      name="$(printf '%s' "$name" | sed -E 's/\.[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$//')"
      ;;
    savedstate) name="${name%.savedState}" ;;
    binarycookies) name="${name%.binarycookies}" ;;
    plain) ;;
  esac
  printf '%s' "$name"
}

# Parallel arrays, one entry per detected orphan candidate.
ORPHAN_CANDIDATE_PATHS=()
ORPHAN_CANDIDATE_TOKENS=()
ORPHAN_CANDIDATE_KINDS=()
ORPHAN_CANDIDATE_TIERS=()   # "auto" or "report"

collect_orphan_candidates() {
  ORPHAN_CANDIDATE_PATHS=()
  ORPHAN_CANDIDATE_TOKENS=()
  ORPHAN_CANDIDATE_KINDS=()
  ORPHAN_CANDIDATE_TIERS=()
  local spec root kind policy entry base token norm_token tier
  for spec in "${ORPHAN_ROOTS[@]}"; do
    root="$(printf '%s' "$spec" | awk -F'::' '{print $1}')"
    kind="$(printf '%s' "$spec" | awk -F'::' '{print $2}')"
    policy="$(printf '%s' "$spec" | awk -F'::' '{print $3}')"
    [ -d "$root" ] || continue
    for entry in "$root"/*; do
      [ -e "$entry" ] || continue
      base="$(basename "$entry")"
      token="$(get_token_for_entry "$kind" "$base")"
      norm_token="$(normalize_token "$token")"

      is_whitelisted "$entry" && continue
      is_identifier_whitelisted "$token" && continue
      is_apple_identifier "$token" && continue
      is_denylisted_identifier "$norm_token" && continue
      is_installed_identifier "$norm_token" && continue

      case "$policy" in
        auto) tier="auto" ;;
        report) tier="report" ;;
        dotted-auto) looks_like_bundle_id "$token" && tier="auto" || tier="report" ;;
        *) tier="report" ;;
      esac
      looks_like_uuid "$token" && tier="report"

      ORPHAN_CANDIDATE_PATHS+=("$entry")
      ORPHAN_CANDIDATE_TOKENS+=("$token")
      ORPHAN_CANDIDATE_KINDS+=("$kind")
      ORPHAN_CANDIDATE_TIERS+=("$tier")
    done
  done
}

write_orphans_review_file() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  {
    printf '# Orphan candidates found by clean.sh on %s\n' "$(date)"
    printf '# One path per line. Delete/comment-out (#) any line for anything you want to KEEP.\n'
    printf '# Then run:  ./clean.sh --clean --remove-orphans-from "%s"\n' "$out"
    printf '#\n'
    printf '# [auto]   already offered for immediate bulk removal by clean.sh --clean --include-orphans\n'
    printf '# [review] not auto-removed anywhere else — this file is the only way to remove these\n'
    printf '#\n'
    local i n="${#ORPHAN_CANDIDATE_PATHS[@]}"
    for ((i = 0; i < n; i++)); do
      printf '# [%s] token=%s size=%s\n' "${ORPHAN_CANDIDATE_TIERS[$i]}" "${ORPHAN_CANDIDATE_TOKENS[$i]}" "$(human_kb "$(dir_size_kb "${ORPHAN_CANDIDATE_PATHS[$i]}")")"
      printf '%s\n' "${ORPHAN_CANDIDATE_PATHS[$i]}"
    done
  } > "$out"
}

# Safety-checked recursive delete of a path's *contents* (keeps the dir itself).
# Usage: clear_dir_contents "/path/to/dir" "label"
clear_dir_contents() {
  local dir="$1"
  local resolved
  resolved="$(resolve_path "$dir")"

  [ -d "$dir" ] || { verbose "skip (missing): $dir"; return 0; }
  if is_forbidden "$resolved"; then
    warn "refusing to touch protected path: $dir"
    return 1
  fi
  if is_whitelisted "$dir"; then
    info "whitelisted, skipped: $dir"
    return 0
  fi

  local before after entry
  before="$(dir_size_kb "$dir")"

  if [ "$MODE" = "scan" ]; then
    info "would clear contents of: $dir ($(human_kb "$before"))"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return 0
  fi

  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || continue
    if is_whitelisted "$entry"; then
      verbose "whitelisted entry, kept: $entry"
      continue
    fi
    verbose "removing: $entry"
    rm -rf -- "$entry" 2>>"$LOG_FILE"
  done

  after="$(dir_size_kb "$dir")"
  local reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "cleared: $dir  (freed $(human_kb "$reclaimed"))"
}

# Remove a single path outright (file or directory), with the same safety checks.
remove_path() {
  local p="$1"
  local resolved
  resolved="$(resolve_path "$p")"

  [ -e "$p" ] || return 0
  if is_forbidden "$resolved"; then
    warn "refusing to touch protected path: $p"
    return 1
  fi
  if is_whitelisted "$p"; then
    info "whitelisted, skipped: $p"
    return 0
  fi

  local size
  size="$(dir_size_kb "$p")"

  if [ "$MODE" = "scan" ]; then
    info "would remove: $p ($(human_kb "$size"))"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + size))
    return 0
  fi

  verbose "removing: $p"
  rm -rf -- "$p" 2>>"$LOG_FILE"
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + size))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size))
  ok "removed: $p  (freed $(human_kb "$size"))"
}

# macOS ships no timeout(1), so this is the bash-3.2-safe equivalent. Used to
# stop an unresponsive Docker daemon from stalling the whole run: `docker info`
# happily blocks for minutes when Docker Desktop is starting up or wedged.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watch_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -TERM "$watch_pid" 2>/dev/null
  wait "$watch_pid" 2>/dev/null
  return "$rc"
}

# True only if the Docker daemon answers within a few seconds.
docker_daemon_ready() {
  command -v docker >/dev/null 2>&1 || return 1
  run_with_timeout 8 docker info >/dev/null 2>&1
}

confirm() {
  local prompt="$1"
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply
  read -r -p "${C_YELLOW}${prompt} [y/N] ${C_RESET}" reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

in_list() {
  # in_list "needle" "comma,separated,list"
  local needle="$1" list="$2" item
  [ -z "$list" ] && return 1
  IFS=',' read -r -a arr <<< "$list"
  for item in "${arr[@]}"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Maps an opt-in category id to the global flag variable that gates it, so
# that passing --include-X is by itself enough to run it (see the ONLY_LIST
# fixup below) — add one line here for any new opt-in category.
category_include_var() {
  case "$1" in
    docker) printf '%s' "INCLUDE_DOCKER" ;;
    docker-cache) printf '%s' "INCLUDE_DOCKER_CACHE" ;;
    mail) printf '%s' "INCLUDE_MAIL" ;;
    trash) printf '%s' "INCLUDE_TRASH" ;;
    orphans) printf '%s' "INCLUDE_ORPHANS" ;;
    whatsapp) printf '%s' "INCLUDE_WHATSAPP" ;;
    sim-stale) printf '%s' "INCLUDE_SIM_STALE" ;;
    claude-cache) printf '%s' "INCLUDE_CLAUDE_CACHE" ;;
    android) printf '%s' "INCLUDE_ANDROID" ;;
    ide-stale) printf '%s' "INCLUDE_IDE_STALE" ;;
    ml-caches) printf '%s' "INCLUDE_ML_CACHES" ;;
    ios-backups) printf '%s' "INCLUDE_IOS_BACKUPS" ;;
    toolchains) printf '%s' "INCLUDE_TOOLCHAINS" ;;
    *) printf '%s' "" ;;
  esac
}

should_run_category() {
  local id="$1"
  # --skip always wins, even over an explicit --only or the default set.
  if [ -n "$SKIP_LIST" ] && in_list "$id" "$SKIP_LIST"; then
    return 1
  fi
  if [ -n "$ONLY_LIST" ]; then
    in_list "$id" "$ONLY_LIST" && return 0 || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Category registry: id | risk | default-on | description
#   default-on only matters when --only is not used; --skip always wins.
# ---------------------------------------------------------------------------

category_info() {
  case "$1" in
    caches)            echo "safe|1|User app caches (~/Library/Caches/*)" ;;
    logs)              echo "safe|1|User log files (~/Library/Logs/*)" ;;
    diagnostics)       echo "safe|1|Old crash/diagnostic reports" ;;
    dsstore)           echo "safe|1|.DS_Store files under home directory" ;;
    quicklook)         echo "safe|1|QuickLook thumbnail cache" ;;
    xcode-derived)     echo "safe|1|Xcode DerivedData (build artifacts, safe to delete)" ;;
    xcode-archives)    echo "moderate|0|Old Xcode .xcarchive builds (kept unless --aggressive)" ;;
    sim-caches)        echo "safe|1|iOS Simulator cache files" ;;
    sim-unavailable)   echo "safe|1|Deleted/unavailable iOS Simulator devices" ;;
    device-support)    echo "moderate|1|Old Xcode iOS DeviceSupport symbol sets (keeps latest N)" ;;
    homebrew)          echo "safe|1|Homebrew download cache + old formula/cask versions" ;;
    npm)               echo "safe|1|npm cache" ;;
    yarn)              echo "safe|1|Yarn cache" ;;
    pnpm)              echo "safe|1|pnpm store (prune unreferenced packages)" ;;
    cocoapods)         echo "safe|1|CocoaPods cache" ;;
    gradle)            echo "safe|1|Gradle caches (Android/Kotlin builds)" ;;
    pip)               echo "safe|1|pip download cache" ;;
    timemachine)       echo "moderate|1|Local Time Machine snapshots (thinned, not your backups)" ;;
    docker)            echo "risky|0|Docker ALL unused images/containers/volumes -af --volumes (opt-in)" ;;
    docker-cache)      echo "safe|0|Docker dangling build cache + untagged images only, shrinks Docker.raw (opt-in)" ;;
    mail)              echo "risky|0|Mail.app local download cache (opt-in)" ;;
    trash)             echo "risky|0|Empty ~/.Trash (irreversible, opt-in)" ;;
    orphans)           echo "risky|0|Leftover config/support/cache files from uninstalled apps (opt-in, heuristic)" ;;
    whatsapp)          echo "moderate|0|WhatsApp expired Status/Stories media cache, real chat media untouched (opt-in)" ;;
    sim-stale)         echo "moderate|0|iOS Simulator devices unused for a long time (opt-in, keeps recently-booted ones)" ;;
    claude-cache)      echo "safe|0|Claude desktop app's browser-style cache dirs only (opt-in)" ;;
    android)           echo "moderate|0|Unreferenced Android system images + long-unused AVDs (opt-in)" ;;
    browsers)          echo "safe|1|Chrome/Brave/Edge/Arc/Vivaldi/Opera/Firefox caches, every profile" ;;
    electron)          echo "safe|1|Electron app caches (Notion, Slack, VS Code, Postman...) incl. Partitions" ;;
    dev-caches)        echo "safe|1|Language/tool caches (uv, go, cargo, trivy, gh, JetBrains, SwiftPM...)" ;;
    ide-stale)         echo "moderate|0|Config/plugin folders of superseded JetBrains + Android Studio versions (opt-in)" ;;
    ml-caches)         echo "moderate|0|Hugging Face / torch model caches; reports Ollama + LM Studio (opt-in)" ;;
    ios-backups)       echo "risky|0|Local iPhone/iPad backups in MobileSync (opt-in, irreversible)" ;;
    tmp)               echo "safe|1|\$TMPDIR + per-user cache, entries older than --tmp-stale-days" ;;
    toolchains)        echo "moderate|0|Superseded Kotlin/Native, Gradle dists, Gradle JDKs, SDKMAN versions (opt-in)" ;;
    *) echo "" ;;
  esac
}

ALL_CATEGORY_IDS="browsers electron dev-caches caches tmp logs diagnostics dsstore quicklook xcode-derived xcode-archives sim-caches sim-unavailable device-support homebrew npm yarn pnpm cocoapods gradle pip timemachine docker docker-cache mail trash orphans whatsapp sim-stale claude-cache android ide-stale ml-caches ios-backups toolchains"

# Live on/off state for the interactive menu, parallel arrays keyed by index
# (bash 3.2 has no associative arrays). Seeded from category_info() defaults,
# then CONFIG_SELECTED_CATEGORIES (from the config file) if present.
CATEGORY_STATE_IDS=()
CATEGORY_STATE_ON=()

sync_include_var() {
  local id="$1" val="$2" varname
  varname="$(category_include_var "$id")"
  [ -n "$varname" ] && printf -v "$varname" '%s' "$val"
}

build_category_state() {
  CATEGORY_STATE_IDS=()
  CATEGORY_STATE_ON=()
  local id info default
  for id in $ALL_CATEGORY_IDS; do
    info="$(category_info "$id")"
    default="$(printf '%s' "$info" | cut -d'|' -f2)"
    CATEGORY_STATE_IDS+=("$id")
    CATEGORY_STATE_ON+=("$default")
  done
  if [ -n "$CONFIG_SELECTED_CATEGORIES" ]; then
    local i
    for i in "${!CATEGORY_STATE_IDS[@]}"; do
      case ",$CONFIG_SELECTED_CATEGORIES," in
        *",${CATEGORY_STATE_IDS[$i]},"*) CATEGORY_STATE_ON[$i]=1 ;;
        *) CATEGORY_STATE_ON[$i]=0 ;;
      esac
    done
  fi
  local i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    sync_include_var "${CATEGORY_STATE_IDS[$i]}" "${CATEGORY_STATE_ON[$i]}"
  done
}

category_state_index() {
  local i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    if [ "${CATEGORY_STATE_IDS[$i]}" = "$1" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

toggle_category_state() {
  local idx
  idx="$(category_state_index "$1")" || return 1
  if [ "${CATEGORY_STATE_ON[$idx]}" = "1" ]; then
    CATEGORY_STATE_ON[$idx]=0
  else
    CATEGORY_STATE_ON[$idx]=1
  fi
  sync_include_var "$1" "${CATEGORY_STATE_ON[$idx]}"
}

only_list_from_category_state() {
  local joined="" i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && joined="${joined:+$joined,}${CATEGORY_STATE_IDS[$i]}"
  done
  printf '%s' "$joined"
}

print_category_list() {
  printf '%-16s %-9s %-8s %s\n' "ID" "RISK" "DEFAULT" "DESCRIPTION"
  local id info_line risk default desc
  for id in $ALL_CATEGORY_IDS; do
    info_line="$(category_info "$id")"
    risk="$(echo "$info_line" | cut -d'|' -f1)"
    default="$(echo "$info_line" | cut -d'|' -f2)"
    desc="$(echo "$info_line" | cut -d'|' -f3)"
    [ "$default" = "1" ] && default="on" || default="off"
    printf '%-16s %-9s %-8s %s\n' "$id" "$risk" "$default" "$desc"
  done
}

# ---------------------------------------------------------------------------
# Category implementations
# ---------------------------------------------------------------------------

cat_caches() {
  section "User caches"
  local base="$HOME_DIR/Library/Caches"
  [ -d "$base" ] || { info "no caches dir found"; return; }
  # Entries here are usually per-app directories, but loose files turn up too
  # (stray plists, single-file caches). clear_dir_contents only handles
  # directories, so a bare file would otherwise be skipped silently and never
  # counted in the estimate either.
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    if [ -d "$sub" ]; then
      clear_dir_contents "$sub"
    else
      remove_path "$sub"
    fi
  done
}

cat_logs() {
  section "User logs"
  local base="$HOME_DIR/Library/Logs"
  [ -d "$base" ] || { info "no logs dir found"; return; }
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    # DiagnosticReports handled by its own category so it can be toggled separately
    [ "$(basename "$sub")" = "DiagnosticReports" ] && continue
    # Never our own log directory: this runs mid-run, so clearing it would
    # delete the transcript currently being written and any orphan review
    # file the user has not acted on yet. It is size-capped by KEEP_LOGS.
    [ "$sub" = "$LOG_DIR" ] && { verbose "skipping own log dir: $sub"; continue; }
    # Same as caches: ~/Library/Logs holds loose .log files as well as
    # per-app directories, and clear_dir_contents ignores non-directories.
    if [ -d "$sub" ]; then
      clear_dir_contents "$sub"
    else
      remove_path "$sub"
    fi
  done
}

cat_diagnostics() {
  section "Diagnostic / crash reports"
  clear_dir_contents "$HOME_DIR/Library/Logs/DiagnosticReports"
}

cat_dsstore() {
  section ".DS_Store files"
  local count=0 total_kb=0 f size
  while IFS= read -r -d '' f; do
    is_whitelisted "$f" && continue
    size="$(dir_size_kb "$f")"
    total_kb=$((total_kb + size))
    count=$((count + 1))
    if [ "$MODE" = "clean" ]; then
      verbose "removing: $f"
      rm -f -- "$f" 2>>"$LOG_FILE"
    fi
  done < <(find "$HOME_DIR" -xdev -name '.DS_Store' -not -path '*/.Trash/*' -print0 2>/dev/null)

  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + total_kb))
  if [ "$MODE" = "scan" ]; then
    info "found $count .DS_Store files ($(human_kb "$total_kb"))"
  else
    TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + total_kb))
    ok "removed $count .DS_Store files (freed $(human_kb "$total_kb"))"
  fi
}

cat_quicklook() {
  section "QuickLook thumbnail cache"
  if [ "$MODE" = "scan" ]; then
    info "would reset QuickLook thumbnail cache (qlmanage -r cache)"
    return
  fi
  if command -v qlmanage >/dev/null 2>&1; then
    qlmanage -r cache >/dev/null 2>>"$LOG_FILE"
    qlmanage -r cache >/dev/null 2>>"$LOG_FILE"
    ok "QuickLook thumbnail cache reset"
  else
    warn "qlmanage not found, skipped"
  fi
}

cat_xcode_derived() {
  section "Xcode DerivedData"
  clear_dir_contents "$HOME_DIR/Library/Developer/Xcode/DerivedData"
}

cat_xcode_archives() {
  section "Xcode Archives (old builds)"
  local base="$HOME_DIR/Library/Developer/Xcode/Archives"
  [ -d "$base" ] || { info "no archives dir found"; return; }
  if [ "$AGGRESSIVE" != 1 ]; then
    warn "skipped (enable with --aggressive; archives may be needed for dSYM/App Store re-submission)"
    return
  fi
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    remove_path "$sub"
  done
}

cat_sim_caches() {
  section "iOS Simulator caches"
  clear_dir_contents "$HOME_DIR/Library/Developer/CoreSimulator/Caches"
}

cat_sim_unavailable() {
  section "Unavailable iOS Simulator devices"
  if ! command -v xcrun >/dev/null 2>&1; then
    warn "xcrun not found, skipped"
    return
  fi
  local sim_root="$HOME_DIR/Library/Developer/CoreSimulator/Devices"
  if is_whitelisted "$sim_root"; then
    info "whitelisted, skipped: $sim_root"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$sim_root")"
  if [ "$MODE" = "scan" ]; then
    info "would run: xcrun simctl delete unavailable (devices dir currently: $(human_kb "$before"))"
    return
  fi
  xcrun simctl delete unavailable >/dev/null 2>>"$LOG_FILE"
  after="$(dir_size_kb "$sim_root")"
  reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "deleted unavailable simulator devices (freed $(human_kb "$reclaimed"))"
}

cat_device_support() {
  section "Xcode iOS DeviceSupport (old OS symbol sets)"
  local base="$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport"
  [ -d "$base" ] || { info "no DeviceSupport dir found"; return; }
  if is_whitelisted "$base"; then
    info "whitelisted, skipped: $base"
    return
  fi

  local keep="$KEEP_DEVICE_SUPPORT"
  [ "$AGGRESSIVE" = 1 ] && keep=1

  # Sort by modification time, newest first; keep the newest $keep, remove the rest.
  local -a dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null \
            | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | cut -d' ' -f2-)

  local total="${#dirs[@]}"
  if [ "$total" -le "$keep" ]; then
    info "only $total version(s) present, nothing to prune (keeping $keep)"
    return
  fi

  info "found $total version(s), keeping the $keep most recently used"
  local i=0 d
  for d in "${dirs[@]}"; do
    i=$((i + 1))
    [ "$i" -le "$keep" ] && { verbose "keeping: $d"; continue; }
    remove_path "$d"
  done
}

cat_homebrew() {
  section "Homebrew cache"
  if ! command -v brew >/dev/null 2>&1; then
    info "Homebrew not installed, skipped"
    return
  fi
  local cache_dir
  cache_dir="$(brew --cache 2>/dev/null)"
  local before=0
  [ -n "$cache_dir" ] && before="$(dir_size_kb "$cache_dir")"

  # Cellar is measured too: `brew autoremove` deletes installed formulae that
  # only exist as a dependency of something you have since uninstalled, so the
  # space it frees is in the Cellar, not in the download cache.
  local cellar_dir cellar_before=0
  cellar_dir="$(brew --cellar 2>/dev/null)"
  [ -n "$cellar_dir" ] && [ -d "$cellar_dir" ] && cellar_before="$(dir_size_kb "$cellar_dir")"

  if [ "$MODE" = "scan" ]; then
    info "would run: brew autoremove   (unused dependencies, listed below)"
    local line orphan_count=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        ==\>*|Warning:*|"Would remove"*) continue ;;
      esac
      orphan_count=$((orphan_count + 1))
      info "    unused dependency: $line"
    done < <(brew autoremove --dry-run 2>/dev/null | tr ' ' '\n')
    [ "$orphan_count" = 0 ] && info "    (none — no unused dependencies)"
    info "would run: brew cleanup -s --prune=all  (cache: $(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi

  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi

  # autoremove first: it uninstalls formulae, which then leaves more for
  # cleanup to sweep out of the cache.
  brew autoremove >>"$LOG_FILE" 2>&1
  local cellar_after=0
  [ -n "$cellar_dir" ] && [ -d "$cellar_dir" ] && cellar_after="$(dir_size_kb "$cellar_dir")"
  local cellar_freed=$((cellar_before - cellar_after))
  [ "$cellar_freed" -lt 0 ] && cellar_freed=0
  if [ "$cellar_freed" -gt 0 ]; then
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + cellar_freed))
    TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + cellar_freed))
    ok "brew autoremove removed unused dependencies (freed $(human_kb "$cellar_freed"))"
  else
    info "brew autoremove: no unused dependencies"
  fi

  brew cleanup -s --prune=all >>"$LOG_FILE" 2>&1
  local after=0
  [ -n "$cache_dir" ] && after="$(dir_size_kb "$cache_dir")"
  local reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "brew cleanup done (freed $(human_kb "$reclaimed"))"
}

cat_npm() {
  section "npm cache"
  command -v npm >/dev/null 2>&1 || { info "npm not installed, skipped"; return; }
  local cache_dir
  cache_dir="$(npm config get cache 2>/dev/null)"
  [ -d "$cache_dir" ] || { info "no npm cache dir found"; return; }
  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$cache_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: npm cache clean --force ($(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  npm cache clean --force >>"$LOG_FILE" 2>&1
  after="$(dir_size_kb "$cache_dir")"
  reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "npm cache cleaned (freed $(human_kb "$reclaimed"))"
}

cat_yarn() {
  section "Yarn cache"
  command -v yarn >/dev/null 2>&1 || { info "yarn not installed, skipped"; return; }
  # Yarn Classic (1.x) answers `yarn cache dir`. Yarn Berry (2/3/4) does not
  # have that command at all — it keeps a global cache at ~/.yarn/berry/cache
  # and `yarn cache clean` only works from inside a project, so Berry's cache
  # is cleared directly. Everything in it is re-fetched from the registry.
  local cache_dir
  cache_dir="$(yarn cache dir 2>/dev/null)"
  case "$cache_dir" in
    /*) ;;
    *) cache_dir="" ;;     # Berry prints usage/error text, not a path
  esac
  if [ -z "$cache_dir" ] || [ ! -d "$cache_dir" ]; then
    if [ -d "$HOME_DIR/.yarn/berry/cache" ]; then
      info "Yarn Berry detected (v$(yarn --version 2>/dev/null)) — clearing its global cache"
      clear_dir_contents "$HOME_DIR/.yarn/berry/cache"
      return
    fi
    info "no yarn cache dir found"
    return
  fi
  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$cache_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: yarn cache clean ($(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  yarn cache clean >>"$LOG_FILE" 2>&1
  after="$(dir_size_kb "$cache_dir")"
  reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "yarn cache cleaned (freed $(human_kb "$reclaimed"))"
  [ -d "$HOME_DIR/.yarn/berry/cache" ] && clear_dir_contents "$HOME_DIR/.yarn/berry/cache"
  return 0
}

cat_pnpm() {
  section "pnpm store"
  command -v pnpm >/dev/null 2>&1 || { info "pnpm not installed, skipped"; return; }
  local store_dir
  store_dir="$(pnpm store path 2>/dev/null)"
  [ -d "$store_dir" ] || { info "no pnpm store found"; return; }
  if is_whitelisted "$store_dir"; then
    info "whitelisted, skipped: $store_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$store_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: pnpm store prune ($(human_kb "$before") at $store_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  pnpm store prune >>"$LOG_FILE" 2>&1
  after="$(dir_size_kb "$store_dir")"
  reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "pnpm store pruned (freed $(human_kb "$reclaimed"))"
}

cat_cocoapods() {
  section "CocoaPods cache"
  local cache_dir="$HOME_DIR/Library/Caches/CocoaPods"
  [ -d "$cache_dir" ] || { info "no CocoaPods cache found"; return; }
  clear_dir_contents "$cache_dir"
}

cat_gradle() {
  section "Gradle caches"
  clear_dir_contents "$HOME_DIR/.gradle/caches"
}

cat_pip() {
  section "pip cache"
  command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1 || { info "pip not installed, skipped"; return; }
  local pipbin="pip3"
  command -v pip3 >/dev/null 2>&1 || pipbin="pip"
  local cache_dir
  cache_dir="$("$pipbin" cache dir 2>/dev/null)"
  [ -d "$cache_dir" ] || { info "no pip cache found"; return; }
  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
  fi
  local before after reclaimed
  before="$(dir_size_kb "$cache_dir")"
  if [ "$MODE" = "scan" ]; then
    info "would run: $pipbin cache purge ($(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi
  "$pipbin" cache purge >>"$LOG_FILE" 2>&1
  after="$(dir_size_kb "$cache_dir")"
  reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "pip cache purged (freed $(human_kb "$reclaimed"))"
}

cat_timemachine() {
  section "Local Time Machine snapshots"
  if ! command -v tmutil >/dev/null 2>&1; then
    info "tmutil not found, skipped"
    return
  fi
  local snapshots
  snapshots="$(tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine' || true)"
  if [ -z "$snapshots" ]; then
    info "no local snapshots found"
    return
  fi
  local count
  count="$(printf '%s\n' "$snapshots" | wc -l | tr -d ' ')"
  if [ "$MODE" = "scan" ]; then
    info "found $count local snapshot(s) (thinning reclaims purgeable space, not shown in du totals)"
    return
  fi
  info "thinning local snapshots (this only affects local disk space, not your Time Machine backup drive)"
  # 4 = urgency level "as much as possible while keeping at least one recent snapshot"
  tmutil thinlocalsnapshots / 999999999999 4 >>"$LOG_FILE" 2>&1
  ok "requested thinning of $count local snapshot(s)"
}

cat_docker() {
  section "Docker (unused images/containers/volumes)"
  if [ "$INCLUDE_DOCKER" != 1 ]; then
    warn "skipped (opt-in only, pass --include-docker)"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "docker not installed, skipped"
    return
  fi
  if ! docker_daemon_ready; then
    warn "Docker daemon not responding (not running, or still starting) — skipped"
    return
  fi
  if [ "$MODE" = "scan" ]; then
    info "would run: docker system prune -af --volumes"
    return
  fi
  if ! confirm "This removes ALL unused Docker images, containers, and volumes. Continue?"; then
    warn "skipped by user"
    return
  fi
  docker system prune -af --volumes >>"$LOG_FILE" 2>&1
  ok "docker system prune complete (see log for reclaimed space)"
}

cat_docker_cache() {
  section "Docker build cache & unused images (safe prune)"
  if [ "$INCLUDE_DOCKER_CACHE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-docker-cache)"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "docker not installed, skipped"
    return
  fi
  if ! docker_daemon_ready; then
    warn "Docker daemon not responding (not running, or still starting) — skipped"
    return
  fi

  # Unlike the `docker` category (-af --volumes, wipes everything unused),
  # this only removes dangling build cache and untagged images — nothing
  # currently tagged, running, or in a named volume is ever touched.
  local raw_disk="$HOME_DIR/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  local before=0
  [ -e "$raw_disk" ] && before="$(dir_size_kb "$raw_disk")"

  if [ "$MODE" = "scan" ]; then
    info "would run: docker builder prune -f && docker image prune -f (dangling only)"
    local line
    run_with_timeout 15 docker system df 2>/dev/null | while IFS= read -r line; do info "  $line"; done
    return
  fi

  docker builder prune -f >>"$LOG_FILE" 2>&1
  docker image prune -f >>"$LOG_FILE" 2>&1

  local after=0
  [ -e "$raw_disk" ] && after="$(dir_size_kb "$raw_disk")"
  local reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  ok "docker build cache + unused images pruned (Docker.raw shrank by $(human_kb "$reclaimed"))"
}

cat_mail() {
  section "Mail.app download cache"
  if [ "$INCLUDE_MAIL" != 1 ]; then
    warn "skipped (opt-in only, pass --include-mail)"
    return
  fi
  clear_dir_contents "$HOME_DIR/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
}

cat_orphans() {
  section "Orphaned application leftovers (uninstalled apps)"
  if [ "$INCLUDE_ORPHANS" != 1 ]; then
    warn "skipped (opt-in only, pass --include-orphans; try --only orphans --include-orphans --scan first to preview)"
    return
  fi

  info "indexing installed applications (Spotlight + standard app folders)..."
  build_installed_identifiers
  collect_orphan_candidates

  local n="${#ORPHAN_CANDIDATE_PATHS[@]}"
  if [ "$n" -eq 0 ]; then
    info "no orphaned leftovers found"
    return
  fi

  local i size total_kb=0 auto_count=0 review_count=0
  local -a auto_idx=()
  for ((i = 0; i < n; i++)); do
    size="$(dir_size_kb "${ORPHAN_CANDIDATE_PATHS[$i]}")"
    total_kb=$((total_kb + size))
    if [ "${ORPHAN_CANDIDATE_TIERS[$i]}" = "auto" ]; then
      auto_count=$((auto_count + 1))
      auto_idx+=("$i")
      info "  [auto]   [${ORPHAN_CANDIDATE_TOKENS[$i]}] ${ORPHAN_CANDIDATE_PATHS[$i]}  ($(human_kb "$size"))"
    else
      review_count=$((review_count + 1))
      info "  [review] [${ORPHAN_CANDIDATE_TOKENS[$i]}] ${ORPHAN_CANDIDATE_PATHS[$i]}  ($(human_kb "$size"))"
    fi
  done
  warn "matching is heuristic (name/bundle-id based) — double-check anything you don't recognize"

  local review_file="$LOG_DIR/orphans-review-$TIMESTAMP.txt"
  write_orphans_review_file "$review_file"
  info "full candidate list (both [auto] and [review]) written to: $review_file"
  if [ "$review_count" -gt 0 ]; then
    info "$review_count item(s) marked [review] are NEVER auto-removed — edit that file, then run:"
    info "  ./clean.sh --clean --remove-orphans-from \"$review_file\""
  fi

  if [ "$MODE" = "scan" ]; then
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + total_kb))
    return
  fi

  [ "$auto_count" -eq 0 ] && return

  if ! confirm "Remove the $auto_count item(s) marked [auto] above? ([review] items are untouched, see the file above)"; then
    warn "skipped by user"
    return
  fi

  for i in "${auto_idx[@]}"; do
    if [ "${ORPHAN_CANDIDATE_KINDS[$i]}" = "plist" ] && [[ "${ORPHAN_CANDIDATE_PATHS[$i]}" == *"/LaunchAgents/"* ]]; then
      launchctl unload "${ORPHAN_CANDIDATE_PATHS[$i]}" >/dev/null 2>&1 || true
    fi
    remove_path "${ORPHAN_CANDIDATE_PATHS[$i]}"
  done
}

process_orphans_review_file() {
  local file="$REMOVE_ORPHANS_FILE"
  if [ ! -f "$file" ]; then
    err "orphans review file not found: $file"
    return 1
  fi

  section "Removing items from reviewed file: $file"

  local -a to_remove=()
  local raw line path
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    path="$line"

    if [ ! -e "$path" ]; then
      warn "no longer exists, skipping: $path"
      continue
    fi
    case "$path" in
      "$HOME_DIR/Library/Application Support/"*|"$HOME_DIR/Library/Containers/"*|"$HOME_DIR/Library/Preferences/"*|"$HOME_DIR/Library/Saved Application State/"*|"$HOME_DIR/Library/WebKit/"*|"$HOME_DIR/Library/HTTPStorages/"*|"$HOME_DIR/Library/Cookies/"*|"$HOME_DIR/Library/Application Scripts/"*|"$HOME_DIR/Library/LaunchAgents/"*)
        ;;
      *)
        warn "not a recognized orphan location, skipping: $path"
        continue
        ;;
    esac
    if is_whitelisted "$path"; then
      info "whitelisted, skipped: $path"
      continue
    fi
    to_remove+=("$path")
  done < "$file"

  local n="${#to_remove[@]}"
  if [ "$n" -eq 0 ]; then
    info "nothing to remove from review file"
    return
  fi

  info "$n item(s) from the review file are queued for removal:"
  local p
  for p in "${to_remove[@]}"; do
    info "  $p  ($(human_kb "$(dir_size_kb "$p")"))"
  done

  if [ "$MODE" != "clean" ]; then
    info "(scan mode — nothing deleted; re-run with --clean to actually remove these)"
    return
  fi

  if ! confirm "Remove these $n reviewed item(s)? This is not heuristic — you already reviewed the file."; then
    warn "skipped by user"
    return
  fi

  for p in "${to_remove[@]}"; do
    if [[ "$p" == *"/LaunchAgents/"* ]]; then
      launchctl unload "$p" >/dev/null 2>&1 || true
    fi
    remove_path "$p"
  done
}

cat_whatsapp() {
  section "WhatsApp expired Status/Stories media cache"
  if [ "$INCLUDE_WHATSAPP" != 1 ]; then
    warn "skipped (opt-in only, pass --include-whatsapp)"
    return
  fi

  local base="$HOME_DIR/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
  if [ ! -d "$base" ]; then
    info "WhatsApp data not found, skipped"
    return
  fi

  # Only ever targets Message/Media/<id>.status folders (WhatsApp's own naming
  # for cached Status/Stories views, which expire after 24h on WhatsApp's
  # servers anyway) plus generic Cache/Logs. Actual conversation media
  # (Message/Media/<id> without .status) and every database (ChatStorage.sqlite,
  # Axolotl.sqlite, etc.) at the container root are never touched.
  local media_dir="$base/Message/Media"
  if [ -d "$media_dir" ]; then
    local d
    for d in "$media_dir"/*.status; do
      [ -e "$d" ] || continue
      remove_path "$d"
    done
  else
    info "no Message/Media directory found"
  fi

  clear_dir_contents "$base/Library/Caches"
  clear_dir_contents "$base/Logs"
}

cat_sim_stale() {
  section "Long-unused iOS Simulator devices"
  if [ "$INCLUDE_SIM_STALE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-sim-stale; tune with --sim-stale-days N, default $SIM_STALE_DAYS)"
    return
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    info "xcrun not found, skipped"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found (needed to read simulator metadata), skipped"
    return
  fi
  local devices_root="$HOME_DIR/Library/Developer/CoreSimulator/Devices"
  if is_whitelisted "$devices_root"; then
    info "whitelisted, skipped: $devices_root"
    return
  fi

  local list
  list="$(xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
for runtime, devs in d["devices"].items():
    for dev in devs:
        udid = dev["udid"]; name = dev["name"]; state = dev["state"]
        size_kb = int(dev.get("dataPathSize", 0)) // 1024
        lb = dev.get("lastBootedAt")
        days = -1
        if lb:
            try:
                dt = datetime.datetime.strptime(lb, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
                days = (now - dt).days
            except Exception:
                days = -1
        print(f"{udid}\t{name}\t{state}\t{size_kb}\t{days}")
' 2>/dev/null)"

  if [ -z "$list" ]; then
    info "no simulator devices found"
    return
  fi

  local udid name state size_kb days
  local -a del_udids=() del_labels=() del_sizes=()
  local total_kb=0
  while IFS=$'\t' read -r udid name state size_kb days; do
    [ -z "$udid" ] && continue
    [ "$state" = "Booted" ] && continue
    [ "$days" = "-1" ] && continue   # never booted -> a fresh default device, leave it
    [ "$days" -lt "$SIM_STALE_DAYS" ] && continue
    del_udids+=("$udid")
    del_labels+=("$name — last booted $days days ago ($(human_kb "$size_kb"))")
    del_sizes+=("$size_kb")
    total_kb=$((total_kb + size_kb))
  done <<< "$list"

  local n="${#del_udids[@]}"
  if [ "$n" -eq 0 ]; then
    info "no devices unused for $SIM_STALE_DAYS+ days (currently-booted and never-booted devices are always left alone)"
    return
  fi

  info "found $n device(s) unused for $SIM_STALE_DAYS+ days:"
  local i
  for ((i = 0; i < n; i++)); do
    info "  ${del_labels[$i]}"
  done

  if [ "$MODE" = "scan" ]; then
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + total_kb))
    return
  fi

  if ! confirm "Delete these $n unused simulator device(s)? (Xcode recreates default devices on demand; custom ones are gone for good)"; then
    warn "skipped by user"
    return
  fi

  for ((i = 0; i < n; i++)); do
    udid="${del_udids[$i]}"
    if xcrun simctl delete "$udid" >>"$LOG_FILE" 2>&1; then
      TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + del_sizes[i]))
      ok "deleted: ${del_labels[$i]}"
    else
      err "failed to delete device $udid (see log)"
    fi
  done
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + total_kb))
}

cat_claude_cache() {
  section "Claude desktop app cache"
  if [ "$INCLUDE_CLAUDE_CACHE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-claude-cache)"
    return
  fi

  local base="$HOME_DIR/Library/Application Support/Claude"
  if [ ! -d "$base" ]; then
    info "Claude app data not found, skipped"
    return
  fi

  # Only standard Electron/Chromium browser-cache directories — never touches
  # conversation/session state (Local Storage, IndexedDB, Session Storage,
  # Preferences, Partitions) or vm_bundles (the local agent-mode VM image,
  # reported separately below since it's not a cache and re-downloading it
  # is expensive).
  local sub
  for sub in Cache "Code Cache" GPUCache DawnGraphiteCache DawnWebGPUCache Crashpad "Shared Dictionary"; do
    [ -e "$base/$sub" ] && clear_dir_contents "$base/$sub"
  done

  if [ -d "$base/vm_bundles" ]; then
    local vm_size
    vm_size="$(dir_size_kb "$base/vm_bundles")"
    warn "not touched: $base/vm_bundles ($(human_kb "$vm_size")) — this is the local agent-mode VM image, not a cache; review manually if you don't use Claude's local/agent code execution features"
  fi
}

cat_android() {
  section "Android SDK: unreferenced system images + long-unused AVDs"
  if [ "$INCLUDE_ANDROID" != 1 ]; then
    warn "skipped (opt-in only, pass --include-android; tune with --android-stale-days N, default $ANDROID_STALE_DAYS)"
    return
  fi

  local sdk_images="$HOME_DIR/Library/Android/sdk/system-images"
  local avd_root="$HOME_DIR/.android/avd"

  if [ -d "$sdk_images" ] && ! is_whitelisted "$sdk_images"; then
    # Each leaf 3-level dir under system-images (api/tag/abi) is one image.
    # An AVD references one via its config.ini's image.sysdir.N value, e.g.
    # "system-images/android-34/google_apis/arm64-v8a/". Any leaf with no
    # AVD referencing it is safe to remove (re-installable via SDK Manager).
    local -a referenced=()
    if [ -d "$avd_root" ]; then
      local ini
      for ini in "$avd_root"/*.avd/config.ini; do
        [ -e "$ini" ] || continue
        while IFS='=' read -r key val; do
          case "$key" in
            image.sysdir.*)
              val="${val%/}"
              referenced+=("$val")
              ;;
          esac
        done < "$ini"
      done
    fi

    local api_dir tag_dir abi_dir leaf rel found
    for api_dir in "$sdk_images"/*/; do
      [ -d "$api_dir" ] || continue
      for tag_dir in "$api_dir"*/; do
        [ -d "$tag_dir" ] || continue
        for abi_dir in "$tag_dir"*/; do
          [ -d "$abi_dir" ] || continue
          leaf="${abi_dir%/}"
          rel="system-images/${leaf#"$sdk_images"/}"
          found=0
          local r
          for r in "${referenced[@]:-}"; do
            [ "$r" = "$rel" ] && { found=1; break; }
          done
          if [ "$found" -eq 0 ]; then
            info "unreferenced by any AVD:"
            remove_path "$leaf"
          fi
        done
      done
    done
  else
    info "no Android system-images directory found"
  fi

  if [ -d "$avd_root" ] && ! is_whitelisted "$avd_root"; then
    local ini name avd_dir mtime_src last_epoch now_epoch days size_kb
    now_epoch="$(date +%s)"
    for ini in "$avd_root"/*.ini; do
      [ -e "$ini" ] || continue
      name="$(basename "$ini" .ini)"
      avd_dir="$avd_root/$name.avd"
      [ -d "$avd_dir" ] || continue

      mtime_src="$avd_dir/userdata-qemu.img"
      [ -e "$mtime_src" ] || mtime_src="$avd_dir"
      last_epoch="$(stat -f '%m' "$mtime_src" 2>/dev/null || echo 0)"
      days=$(( (now_epoch - last_epoch) / 86400 ))
      size_kb="$(dir_size_kb "$avd_dir")"

      if [ "$days" -lt "$ANDROID_STALE_DAYS" ]; then
        verbose "keeping AVD (used $days days ago): $name"
        continue
      fi

      info "unused for $days days: $name ($(human_kb "$size_kb"))"
      if [ "$MODE" = "scan" ]; then
        TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + size_kb))
        continue
      fi
      if ! confirm "Delete AVD '$name' (unused $days days, $(human_kb "$size_kb"))? Recreatable, but any app data inside it is lost."; then
        warn "skipped by user: $name"
        continue
      fi
      if command -v avdmanager >/dev/null 2>&1; then
        avdmanager delete avd -n "$name" >>"$LOG_FILE" 2>&1
      fi
      remove_path "$avd_dir"
      remove_path "$ini"
    done
  else
    info "no Android AVDs directory found"
  fi
}

# ---------------------------------------------------------------------------
# Full Disk Access (TCC) preflight
#
# Since macOS Mojave, ~/Library/Application Support/{Google/Chrome,Firefox,
# BraveSoftware,Microsoft Edge}, ~/Library/Safari, ~/Library/Mail and friends
# are TCC-protected: a terminal without Full Disk Access gets "Operation not
# permitted" and — crucially — `du`/`rm` silently report those trees as 0 B.
# That is why browser junk survives every clean and keeps showing up as
# "System Data" in Settings > General > Storage.
# ---------------------------------------------------------------------------

FDA_OK=-1   # -1 unknown, 1 granted, 0 denied

# Probe a handful of TCC-protected paths that exist on essentially every Mac.
# If at least one is readable we have Full Disk Access.
check_full_disk_access() {
  [ "$FDA_OK" != -1 ] && return 0
  local probe found=0 blocked=0
  for probe in \
    "$HOME_DIR/Library/Safari" \
    "$HOME_DIR/Library/Application Support/Google/Chrome" \
    "$HOME_DIR/Library/Application Support/Firefox" \
    "$HOME_DIR/Library/Messages" \
    "$HOME_DIR/Library/Cookies"
  do
    [ -d "$probe" ] || continue
    if ls "$probe" >/dev/null 2>&1; then found=1; else blocked=1; fi
  done
  if [ "$found" = 1 ] || [ "$blocked" = 0 ]; then FDA_OK=1; else FDA_OK=0; fi
  return 0
}

# Print a loud, actionable warning once if we are running without FDA.
warn_if_no_full_disk_access() {
  check_full_disk_access
  [ "$FDA_OK" = 1 ] && return 0
  local term="your terminal app"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) term="Terminal" ;;
    iTerm.app) term="iTerm" ;;
    vscode) term="Visual Studio Code" ;;
    WarpTerminal) term="Warp" ;;
    ghostty) term="Ghostty" ;;
    WezTerm) term="WezTerm" ;;
  esac
  say ""
  say "${C_BOLD}${C_YELLOW}!! Full Disk Access is NOT granted to $term${C_RESET}"
  warn "macOS is blocking reads of Chrome/Brave/Edge/Firefox/Safari/Mail data."
  warn "Those folders will scan as 0 B and cannot be cleaned — this is usually"
  warn "the single biggest chunk of unexplained \"System Data\" on a dev Mac."
  warn ""
  warn "Fix: System Settings > Privacy & Security > Full Disk Access >"
  warn "     add and enable $term, then quit and reopen it and re-run this script."
  say ""
}

# True if a path is unreadable because of TCC rather than because it is absent.
path_blocked_by_tcc() {
  local p="$1"
  [ -d "$p" ] || return 1
  ls "$p" >/dev/null 2>&1 && return 1
  return 0
}

# Warn (once per path) that a directory exists but cannot be read.
note_tcc_block() {
  local p="$1"
  warn "no permission to read: $p  (grant Full Disk Access — see top of this run)"
}

# ---------------------------------------------------------------------------
# Running-app guard
#
# Chromium wipes are pointless (and occasionally confusing) while the browser
# is live: it holds the cache files open, immediately re-creates them, and the
# freed space does not show up until it quits. We never kill anything — we
# just tell the truth about it.
# ---------------------------------------------------------------------------

app_is_running() {
  # $1 = .app bundle name without extension, e.g. "Google Chrome"
  pgrep -f "/${1}.app/Contents/MacOS/" >/dev/null 2>&1
}

RUNNING_APPS_SEEN=""
note_if_running() {
  local app="$1"
  app_is_running "$app" || return 1
  case ",$RUNNING_APPS_SEEN," in
    *",$app,"*) ;;
    *)
      RUNNING_APPS_SEEN="${RUNNING_APPS_SEEN:+$RUNNING_APPS_SEEN,}$app"
      warn "$app is running — quit it first or it will just rewrite these caches"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Chromium engine cleaner (shared by browsers + Electron apps)
#
# Only ever touches directories Chromium itself treats as a disposable cache.
# Explicitly NEVER touched: Login Data, Cookies, History, Bookmarks, Web Data,
# Preferences, Secure Preferences, Local Storage, Session Storage, IndexedDB,
# Sessions, Extensions, Local Extension Settings, Sync Data.
# ---------------------------------------------------------------------------

# Disposable caches that live inside a single profile directory.
CHROMIUM_PROFILE_CACHES=(
  "Cache"
  "Code Cache"
  "GPUCache"
  "DawnCache"
  "DawnGraphiteCache"
  "DawnWebGPUCache"
  "GraphiteDawnCache"
  "ShaderCache"
  "GrShaderCache"
  "Media Cache"
  "Application Cache"
  "PnaclTranslationCache"
  "blob_storage"
  "Service Worker/CacheStorage"
  "Service Worker/ScriptCache"
  "Shared Dictionary/cache"
  "Storage/ext/.cache"
  "optimization_guide_prediction_model_downloads"
  "extensions_crx_cache"
  "component_crx_cache"
)

# Disposable caches that live at the browser's user-data root (shared by all
# profiles), not inside a profile.
CHROMIUM_ROOT_CACHES=(
  "GrShaderCache"
  "ShaderCache"
  "GraphiteDawnCache"
  "component_crx_cache"
  "extensions_crx_cache"
  "optimization_guide_model_store"
  "Crashpad/completed"
  "Crashpad/pending"
  "SwReporter"
  "Webstore Downloads"
)

# Extra root-level dirs only cleared with --aggressive: they are still pure
# cache, but they cost a fresh multi-hundred-MB download to rebuild.
CHROMIUM_ROOT_CACHES_AGGRESSIVE=(
  "Safe Browsing"
  "Snapshots"
  "OnDeviceHeadSuggestModel"
  "SafetyTips"
  "Subresource Filter"
  "FileTypePolicies"
  "MEIPreload"
)

# clean_chromium_profile <profile-dir>
clean_chromium_profile() {
  local prof="$1" sub
  [ -d "$prof" ] || return 0
  for sub in "${CHROMIUM_PROFILE_CACHES[@]}"; do
    [ -d "$prof/$sub" ] && clear_dir_contents "$prof/$sub"
  done
  # Note: "Network Action Predictor" and "Visited Links" are deliberately left
  # alone. They are small, and wiping them degrades omnibox suggestions.
  return 0
}

# clean_chromium_root <user-data-dir> — clears shared caches, then every profile.
clean_chromium_root() {
  local root="$1" sub prof
  [ -d "$root" ] || return 0

  if path_blocked_by_tcc "$root"; then
    note_tcc_block "$root"
    return 0
  fi

  for sub in "${CHROMIUM_ROOT_CACHES[@]}"; do
    [ -d "$root/$sub" ] && clear_dir_contents "$root/$sub"
  done
  if [ "$AGGRESSIVE" = 1 ]; then
    for sub in "${CHROMIUM_ROOT_CACHES_AGGRESSIVE[@]}"; do
      [ -d "$root/$sub" ] && clear_dir_contents "$root/$sub"
    done
  fi

  # Every profile: Default, Profile 1..N, Guest Profile, System Profile, and
  # any other directory that carries a profile's tell-tale Preferences file.
  for prof in "$root"/*/; do
    prof="${prof%/}"
    [ -d "$prof" ] || continue
    case "$(basename "$prof")" in
      Default|Profile*|"Guest Profile"|"System Profile") ;;
      *) [ -f "$prof/Preferences" ] || continue ;;
    esac
    clean_chromium_profile "$prof"
  done

  # Opera and a few others keep the profile at the root itself.
  [ -f "$root/Preferences" ] && clean_chromium_profile "$root"
  return 0
}

# ---------------------------------------------------------------------------
# Category: browsers
# ---------------------------------------------------------------------------

# label :: app-bundle-name :: path relative to ~/Library/Application Support
CHROMIUM_BROWSERS=(
  "Google Chrome::Google Chrome::Google/Chrome"
  "Google Chrome Beta::Google Chrome Beta::Google/Chrome Beta"
  "Google Chrome Canary::Google Chrome Canary::Google/Chrome Canary"
  "Chrome for Testing::Google Chrome for Testing::Google/Chrome for Testing"
  "Chromium::Chromium::Chromium"
  "Brave::Brave Browser::BraveSoftware/Brave-Browser"
  "Brave Beta::Brave Browser Beta::BraveSoftware/Brave-Browser-Beta"
  "Microsoft Edge::Microsoft Edge::Microsoft Edge"
  "Vivaldi::Vivaldi::Vivaldi"
  "Opera::Opera::com.operasoftware.Opera"
  "Opera GX::Opera GX::com.operasoftware.OperaGX"
  "Arc::Arc::Arc/User Data"
  "Dia::Dia::Dia/User Data"
  "Yandex::Yandex::Yandex/YandexBrowser"
  "Comet::Comet::Perplexity/Comet"
)

cat_browsers() {
  section "Browser caches (Chromium family + Firefox)"
  check_full_disk_access
  local base="$HOME_DIR/Library/Application Support"
  local entry label app rel root found=0

  for entry in "${CHROMIUM_BROWSERS[@]}"; do
    label="${entry%%::*}"
    app="${entry#*::}"; app="${app%%::*}"
    rel="${entry##*::}"
    root="$base/$rel"
    [ -d "$root" ] || continue
    found=1
    info "-- $label"
    note_if_running "$app"
    clean_chromium_root "$root"
  done

  # Chromium's on-disk HTTP cache actually lives under ~/Library/Caches on
  # macOS, keyed by bundle id. The generic `caches` category covers these too,
  # but browsers is also useful standalone (--only browsers).
  local c
  if ! should_run_category caches; then
  for c in "$HOME_DIR/Library/Caches/Google/Chrome" \
           "$HOME_DIR/Library/Caches/com.google.Chrome" \
           "$HOME_DIR/Library/Caches/com.google.Chrome.canary" \
           "$HOME_DIR/Library/Caches/BraveSoftware" \
           "$HOME_DIR/Library/Caches/com.brave.Browser" \
           "$HOME_DIR/Library/Caches/Microsoft Edge" \
           "$HOME_DIR/Library/Caches/com.microsoft.edgemac" \
           "$HOME_DIR/Library/Caches/Chromium" \
           "$HOME_DIR/Library/Caches/company.thebrowser.Browser" \
           "$HOME_DIR/Library/Caches/com.operasoftware.Opera" \
           "$HOME_DIR/Library/Caches/Vivaldi"
  do
    [ -d "$c" ] && { found=1; clear_dir_contents "$c"; }
  done
  fi

  # Firefox: different engine, different layout.
  local ff="$base/Firefox/Profiles"
  if [ -d "$ff" ]; then
    found=1
    info "-- Firefox"
    note_if_running "Firefox"
    if path_blocked_by_tcc "$base/Firefox"; then
      note_tcc_block "$base/Firefox"
    else
      local p s
      for p in "$ff"/*/; do
        p="${p%/}"
        [ -d "$p" ] || continue
        for s in startupCache shader-cache "storage/default/http+++.cache"; do
          [ -d "$p/$s" ] && clear_dir_contents "$p/$s"
        done
      done
    fi
  fi
  if ! should_run_category caches; then
    [ -d "$HOME_DIR/Library/Caches/Firefox" ] && { found=1; clear_dir_contents "$HOME_DIR/Library/Caches/Firefox"; }
  fi

  # Safari is fully TCC-protected and its cache is managed by the OS; we only
  # report it so the number is not silently missing from the total.
  if [ -d "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches" ]; then
    local sk
    sk="$(dir_size_kb "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches")"
    [ "${sk:-0}" -gt 0 ] && info "Safari cache: $(human_kb "$sk") — clear via Safari > Settings > Advanced > Develop > Empty Caches"
  fi

  [ "$found" = 0 ] && info "no Chromium/Firefox browser data found"
  return 0
}

# ---------------------------------------------------------------------------
# Category: electron
#
# Every Electron app ships the same Chromium cache layout, usually at
# ~/Library/Application Support/<App>/ and ~/Library/Application Support/<App>/
# Partitions/<partition>/. On a working dev Mac this is routinely several GB
# (Notion, Slack, Postman, Obsidian, Discord, VS Code forks, ...) and nothing
# in macOS ever reclaims it.
# ---------------------------------------------------------------------------

# App-root caches, on top of the per-profile list above. These are the dirs
# Electron/VS Code-family apps put directly in the app support folder.
ELECTRON_APP_CACHES=(
  "Cache"
  "Code Cache"
  "GPUCache"
  "DawnCache"
  "DawnGraphiteCache"
  "DawnWebGPUCache"
  "GraphiteDawnCache"
  "ShaderCache"
  "GrShaderCache"
  "blob_storage"
  "Crashpad/completed"
  "Crashpad/pending"
  "Shared Dictionary/cache"
  "Service Worker/CacheStorage"
  "Service Worker/ScriptCache"
  "component_crx_cache"
  "CachedData"
  "CachedExtensionVSIXs"
  "CachedProfilesData"
  "Cache Storage"
  "logs"
)

# Apps whose data we deliberately leave to their own dedicated category or
# leave alone entirely.
ELECTRON_SKIP=(
  "Google"          # handled by browsers/ide-stale
  "Firefox"
  "Chromium"
  "BraveSoftware"
  "Microsoft Edge"
  "Vivaldi"
  "Arc"
  "MobileSync"
)

electron_is_skipped() {
  local name="$1" s
  for s in "${ELECTRON_SKIP[@]}"; do
    [ "$name" = "$s" ] && return 0
  done
  return 1
}

cat_electron() {
  section "Electron app caches (Notion, Slack, VS Code, Postman, ...)"
  local base="$HOME_DIR/Library/Application Support"
  [ -d "$base" ] || { info "no Application Support dir"; return; }

  local app name sub part found=0
  for app in "$base"/*/; do
    app="${app%/}"
    name="$(basename "$app")"
    electron_is_skipped "$name" && continue

    # Electron fingerprint: at least one of these must exist, otherwise it is
    # just an ordinary app support folder and we do not go near it.
    if [ ! -d "$app/Cache" ] && [ ! -d "$app/Code Cache" ] && \
       [ ! -d "$app/GPUCache" ] && [ ! -d "$app/Partitions" ] && \
       [ ! -d "$app/Service Worker" ]; then
      continue
    fi

    found=1
    info "-- $name"
    note_if_running "$name"

    for sub in "${ELECTRON_APP_CACHES[@]}"; do
      [ -d "$app/$sub" ] && clear_dir_contents "$app/$sub"
    done

    # Partitions/<name>/ are full Chromium profiles — this is where Notion and
    # friends hide the multi-GB Service Worker CacheStorage.
    if [ -d "$app/Partitions" ]; then
      for part in "$app/Partitions"/*/; do
        part="${part%/}"
        [ -d "$part" ] || continue
        clean_chromium_profile "$part"
      done
    fi
  done

  [ "$found" = 0 ] && info "no Electron app caches found"
  return 0
}

# ---------------------------------------------------------------------------
# Category: dev-caches
#
# Language/toolchain caches that are pure download or build cache: every one
# of these is re-fetched or re-built on demand. Package *stores* that hold the
# only copy of a dependency (pub-cache, .m2, cargo registry/src) are left
# alone on purpose.
# ---------------------------------------------------------------------------

cat_dev_caches() {
  section "Developer tool caches"

  # Tools that own their own cache-clearing command get to use it.
  # `uv cache prune` only drops entries no installed environment references,
  # so its yield is a fraction of the directory size — we do NOT count the
  # whole directory as reclaimable. `--aggressive` switches to `uv cache
  # clean`, which does wipe the lot (everything is re-downloadable).
  if command -v uv >/dev/null 2>&1 && [ -d "$HOME_DIR/.cache/uv" ]; then
    local uv_before uv_cmd
    uv_before="$(dir_size_kb "$HOME_DIR/.cache/uv")"
    if [ "$AGGRESSIVE" = 1 ]; then uv_cmd="clean"; else uv_cmd="prune"; fi
    if [ "$MODE" = "scan" ]; then
      info "would run: uv cache $uv_cmd  (~/.cache/uv is $(human_kb "$uv_before"))"
      if [ "$uv_cmd" = "clean" ]; then
        TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + uv_before))
      else
        info "  (prune only drops unreferenced entries — pass --aggressive to wipe all $(human_kb "$uv_before"))"
      fi
    elif is_whitelisted "$HOME_DIR/.cache/uv"; then
      info "whitelisted, skipped: ~/.cache/uv"
    else
      uv cache "$uv_cmd" >>"$LOG_FILE" 2>&1
      local uv_after reclaimed
      uv_after="$(dir_size_kb "$HOME_DIR/.cache/uv")"
      reclaimed=$((uv_before - uv_after)); [ "$reclaimed" -lt 0 ] && reclaimed=0
      TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + reclaimed))
      TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
      ok "uv cache $uv_cmd done (freed $(human_kb "$reclaimed"))"
    fi
  fi

  if command -v go >/dev/null 2>&1; then
    local go_cache
    go_cache="$(go env GOCACHE 2>/dev/null)"
    if [ -n "$go_cache" ] && [ -d "$go_cache" ]; then
      if [ "$MODE" = "scan" ]; then
        info "would run: go clean -cache  ($(human_kb "$(dir_size_kb "$go_cache")") at $go_cache)"
        TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + $(dir_size_kb "$go_cache")))
      else
        clear_dir_contents "$go_cache"
      fi
    fi
  fi

  # Plain directory caches. Each one is regenerated automatically.
  local d
  for d in \
    "$HOME_DIR/.cache/trivy" \
    "$HOME_DIR/.cache/github-copilot" \
    "$HOME_DIR/.cache/giget" \
    "$HOME_DIR/.cache/gh" \
    "$HOME_DIR/.cache/gem" \
    "$HOME_DIR/.cache/firebase" \
    "$HOME_DIR/.cache/vscode-ripgrep" \
    "$HOME_DIR/.cache/mesa_shader_cache" \
    "$HOME_DIR/.cache/node-gyp" \
    "$HOME_DIR/.cache/puppeteer/.cache" \
    "$HOME_DIR/.cache/ms-playwright" \
    "$HOME_DIR/.cache/deno" \
    "$HOME_DIR/.cache/bazel" \
    "$HOME_DIR/.cache/sccache" \
    "$HOME_DIR/.cargo/registry/cache" \
    "$HOME_DIR/.dotnet/optimizationdata" \
    "$HOME_DIR/.nuget/packages/.tools" \
    "$HOME_DIR/.m2/repository/.cache" \
    "$HOME_DIR/.cache/go-build" \
    "$HOME_DIR/.cache/codex-runtimes" \
    "$HOME_DIR/.cache/pkg" \
    "$HOME_DIR/.cache/wine" \
    "$HOME_DIR/.gradle/.tmp" \
    "$HOME_DIR/.gradle/daemon" \
    "$HOME_DIR/.gradle/native" \
    "$HOME_DIR/.npm/_cacache" \
    "$HOME_DIR/.nuget/v3-cache" \
    "$HOME_DIR/.local/share/NuGet/v3-cache" \
    "$HOME_DIR/.local/share/NuGet/plugins-cache"
  do
    [ -d "$d" ] && clear_dir_contents "$d"
  done

  # These live under ~/Library/Caches, which the `caches` category already
  # wipes wholesale. Doing them here too would double-count them in the scan
  # estimate, so only run them when `caches` is not part of this run (i.e.
  # someone asked for --only dev-caches).
  if ! should_run_category caches; then
    for d in \
      "$HOME_DIR/Library/Caches/deno" \
      "$HOME_DIR/Library/Caches/ms-playwright" \
      "$HOME_DIR/Library/Caches/typescript" \
      "$HOME_DIR/Library/Caches/electron" \
      "$HOME_DIR/Library/Caches/electron-builder" \
      "$HOME_DIR/Library/Caches/Yarn" \
      "$HOME_DIR/Library/Caches/org.swift.swiftpm" \
      "$HOME_DIR/Library/Caches/com.apple.dt.Xcode" \
      "$HOME_DIR/Library/Caches/JetBrains" \
      "$HOME_DIR/Library/Caches/Homebrew"
    do
      [ -d "$d" ] && clear_dir_contents "$d"
    done
  fi

  # Flutter/Dart build leftovers that are not the package store itself.
  [ -d "$HOME_DIR/.pub-cache/.tmp" ] && clear_dir_contents "$HOME_DIR/.pub-cache/.tmp"
  [ -d "$HOME_DIR/.dartServer" ] && clear_dir_contents "$HOME_DIR/.dartServer"
  return 0
}

# ---------------------------------------------------------------------------
# Category: ide-stale (opt-in)
#
# JetBrains and Android Studio never delete the config/plugin/cache folders of
# the version you upgraded away from — each one is 300-500 MB and they stack up
# release after release. We keep the newest of each product family.
# ---------------------------------------------------------------------------

cat_ide_stale() {
  section "Superseded JetBrains / Android Studio version folders"
  if [ "$INCLUDE_IDE_STALE" != 1 ]; then
    warn "skipped (opt-in only, pass --include-ide-stale)"
    return
  fi

  local roots=(
    "$HOME_DIR/Library/Application Support/JetBrains"
    "$HOME_DIR/Library/Application Support/Google"
    "$HOME_DIR/Library/Caches/JetBrains"
    "$HOME_DIR/Library/Caches/Google"
    "$HOME_DIR/Library/Logs/JetBrains"
  )

  local root dir name family newest
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue

    # Group "<Product><Year>.<n>.<n>" dirs by product, keep the newest.
    local families=""
    for dir in "$root"/*/; do
      dir="${dir%/}"
      name="$(basename "$dir")"
      # Must look like ProductName + version, e.g. AndroidStudio2026.1.3
      case "$name" in
        *[0-9][0-9][0-9][0-9].[0-9]*) ;;
        *) continue ;;
      esac
      family="$(printf '%s' "$name" | sed -E 's/[0-9]{4}\.[0-9].*$//')"
      [ -z "$family" ] && continue
      case " $families " in
        *" $family "*) ;;
        *) families="$families $family" ;;
      esac
    done

    for family in $families; do
      # Version sort; the last entry is the newest and is always kept.
      newest="$(ls -1d "$root/$family"*/ 2>/dev/null | sed 's:/$::' | sort -V | tail -1)"
      [ -n "$newest" ] || continue
      for dir in "$root/$family"*/; do
        dir="${dir%/}"
        [ -d "$dir" ] || continue
        [ "$dir" = "$newest" ] && { verbose "keeping newest: $dir"; continue; }
        remove_path "$dir"
      done
      info "kept newest $family: $(basename "$newest")"
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# Category: ml-caches (opt-in)
#
# Hugging Face / PyTorch / Ollama / LM Studio model blobs. Trivially the
# largest thing in a lot of home directories, but re-downloading a model is
# expensive (and sometimes gated), so this is opt-in and never silent.
# ---------------------------------------------------------------------------

cat_ml_caches() {
  section "ML model caches (Hugging Face, torch, Ollama, LM Studio)"
  if [ "$INCLUDE_ML_CACHES" != 1 ]; then
    # Still report the sizes: knowing it is there is the whole point.
    local d sz any=0
    for d in "$HOME_DIR/.cache/huggingface" "$HOME_DIR/.cache/torch" \
             "$HOME_DIR/.ollama/models" "$HOME_DIR/.lmstudio/models"; do
      [ -d "$d" ] || continue
      sz="$(dir_size_kb "$d")"
      [ "${sz:-0}" -gt 0 ] || continue
      any=1
      info "$d — $(human_kb "$sz")"
    done
    [ "$any" = 1 ] && warn "not removed (opt-in: pass --include-ml-caches)" \
                   || info "no ML model caches found"
    return
  fi

  # Hugging Face: prefer its own GC so refs/symlinks stay consistent.
  if [ -d "$HOME_DIR/.cache/huggingface" ]; then
    if [ "$MODE" = "clean" ] && ! confirm "Delete the Hugging Face model cache? Models will be re-downloaded on next use."; then
      warn "skipped by user"
    else
      clear_dir_contents "$HOME_DIR/.cache/huggingface/hub"
      clear_dir_contents "$HOME_DIR/.cache/huggingface/datasets"
      clear_dir_contents "$HOME_DIR/.cache/huggingface/xet"
    fi
  fi
  [ -d "$HOME_DIR/.cache/torch" ] && clear_dir_contents "$HOME_DIR/.cache/torch"

  # Ollama / LM Studio are reported only: these are usually deliberately
  # downloaded models, and both apps have their own uninstall UI.
  local d sz
  for d in "$HOME_DIR/.ollama/models" "$HOME_DIR/.lmstudio/models"; do
    [ -d "$d" ] || continue
    sz="$(dir_size_kb "$d")"
    [ "${sz:-0}" -gt 0 ] && warn "not touched: $d ($(human_kb "$sz")) — remove individual models from the app instead"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Category: ios-backups (opt-in)
# ---------------------------------------------------------------------------

cat_ios_backups() {
  section "iPhone/iPad backups (MobileSync)"
  local base="$HOME_DIR/Library/Application Support/MobileSync/Backup"
  if [ ! -d "$base" ]; then
    info "no local device backups found"
    return
  fi
  if path_blocked_by_tcc "$base"; then
    note_tcc_block "$base"
    return
  fi

  local b sz
  if [ "$INCLUDE_IOS_BACKUPS" != 1 ]; then
    for b in "$base"/*/; do
      b="${b%/}"; [ -d "$b" ] || continue
      sz="$(dir_size_kb "$b")"
      info "$(basename "$b") — $(human_kb "$sz")  (last modified $(date -r "$b" '+%Y-%m-%d' 2>/dev/null))"
    done
    warn "not removed (opt-in: pass --include-ios-backups). These are full device"
    warn "backups — deleting one is irreversible if you have no iCloud backup."
    return
  fi

  for b in "$base"/*/; do
    b="${b%/}"; [ -d "$b" ] || continue
    sz="$(dir_size_kb "$b")"
    if [ "$MODE" = "clean" ]; then
      confirm "Delete backup $(basename "$b") ($(human_kb "$sz"), $(date -r "$b" '+%Y-%m-%d' 2>/dev/null))?" || { warn "kept"; continue; }
    fi
    remove_path "$b"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Disk report: where the space actually went
#
# Everything above only removes things that are safe to remove automatically.
# A dev Mac's "System Data" is mostly stuff no cleaner should delete for you
# (SDKs, VM disks, model weights, node_modules). This prints it so you can
# make the call yourself.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# "System Data" accounting
#
# Settings > General > Storage shows one grey number and no way to drill into
# it. It is not a folder — it is whatever Finder could not file under
# Applications/Documents/Photos/Music/Mail/Developer. On a dev Mac that is
# overwhelmingly ~/Library, the dot-directories in $HOME, and the OS trees
# outside $HOME.
#
# This maps that number back onto real paths and says, for each one, whether
# this script can clean it, whether it is your call, or whether it should be
# left alone.
# ---------------------------------------------------------------------------

# path :: tier :: label :: how to deal with it
#   tier 1 = a category cleans it
#   tier 2 = real data, your call, never removed automatically
#   tier 3 = OS or installed software, leave alone
SYSTEM_DATA_MAP=(
  "$HOME_DIR/Library/Containers/com.docker.docker::1::Docker VM disk (Docker.raw)::--only docker-cache --include-docker-cache (start Docker first)"
  "$HOME_DIR/.cache/huggingface::1::Hugging Face model cache::--only ml-caches --include-ml-caches"
  "$HOME_DIR/Library/Android::1::Android SDK images/NDK::--only android --include-android"
  "$HOME_DIR/.konan::1::Kotlin/Native toolchains::--only toolchains --include-toolchains"
  "$HOME_DIR/.gradle::1::Gradle wrapper dists + JDKs::--only toolchains --include-toolchains"
  "$HOME_DIR/.yarn::1::Yarn Berry global cache::--only yarn"
  "$HOME_DIR/.cache::1::Tool caches (uv, trivy, copilot...)::--only dev-caches"
  "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport::1::Xcode device symbol sets::--only device-support --keep-device-support 1"
  "$HOME_DIR/Library/Developer/CoreSimulator::1::iOS Simulator devices::--only sim-stale --include-sim-stale"
  "$HOME_DIR/Library/Application Support/MobileSync::1::iPhone/iPad backups::--only ios-backups --include-ios-backups"
  "$HOME_DIR/Library/Application Support/Claude/vm_bundles::2::Claude local-agent VM image::delete by hand if you do not use local agent mode"
  "$HOME_DIR/.lmstudio::2::LM Studio models::remove individual models inside LM Studio"
  "$HOME_DIR/.ollama::2::Ollama models::ollama rm <model>"
  "$HOME_DIR/.android/avd::2::Android emulator AVDs::delete unused AVDs in Android Studio's Device Manager"
  "$HOME_DIR/.vscode::2::VS Code extensions::uninstall extensions you no longer use"
  "$HOME_DIR/.pub-cache::2::Dart/Flutter package store::dart pub cache clean (re-downloads everything)"
  "$HOME_DIR/.local::2::pipx/uv managed installs::uv python list / pipx list, then uninstall"
  "/Applications::3::Installed apps (shown as Applications, not System Data)::uninstall what you do not use"
  "/opt/homebrew::3::Homebrew prefix::brew autoremove (the homebrew category runs this)"
  "/System/Volumes/Data/System::3::macOS system files::leave alone"
  "/Library::3::System-wide app support::leave alone"
  "/usr::3::Unix tooling::leave alone"
  "/private/var/db::3::OS databases (Spotlight, TCC, receipts)::leave alone"
  "/private/var/vm::3::Swap file::leave alone, macOS sizes it"
)

report_system_data() {
  section "What is in that \"System Data\" number"

  local entry path tier label advice kb
  local sum1=0 sum2=0 sum3=0

  local t
  for t in 1 2 3; do
    case "$t" in
      1) say ""; info "${C_BOLD}REDUCIBLE${C_RESET} — a category targets these (the size shown is the whole tree, not what you would free):" ;;
      2) say ""; info "${C_BOLD}YOUR CALL${C_RESET} — real data, never removed automatically:" ;;
      3) say ""; info "${C_BOLD}LEAVE ALONE${C_RESET} — the OS and your installed software:" ;;
    esac
    for entry in "${SYSTEM_DATA_MAP[@]}"; do
      path="${entry%%::*}"
      tier="${entry#*::}"; tier="${tier%%::*}"
      [ "$tier" = "$t" ] || continue
      [ -e "$path" ] || continue
      label="${entry#*::*::}"; label="${label%%::*}"
      advice="${entry##*::}"
      kb="$(dir_size_kb "$path")"
      # Subtract any other mapped path that lives inside this one, so a parent
      # row does not also count its child's bytes (~/.cache vs
      # ~/.cache/huggingface). Each byte lands in exactly one row.
      local other opath okb
      for other in "${SYSTEM_DATA_MAP[@]}"; do
        opath="${other%%::*}"
        [ "$opath" = "$path" ] && continue
        case "$opath" in
          "$path"/*) ;;
          *) continue ;;
        esac
        [ -e "$opath" ] || continue
        okb="$(dir_size_kb "$opath")"
        kb=$((kb - ${okb:-0}))
      done
      [ "$kb" -lt 0 ] && kb=0
      [ "${kb:-0}" -gt 51200 ] || continue     # skip anything under 50 MB
      case "$t" in
        1) sum1=$((sum1 + kb)) ;;
        2) sum2=$((sum2 + kb)) ;;
        3) sum3=$((sum3 + kb)) ;;
      esac
      printf '  %9s  %-40s %s\n' "$(human_kb "$kb")" "$label" "${C_DIM}$advice${C_RESET}" | tee -a "$LOG_FILE"
    done
  done

  say ""
  info "Reducible with a flag:  $(human_kb "$sum1")   (upper bound — each category keeps what is still in use)"
  info "Your call:              $(human_kb "$sum2")"
  info "Leave alone:            $(human_kb "$sum3")"

  check_full_disk_access
  if [ "$FDA_OK" = 0 ]; then
    say ""
    warn "Browser data is NOT in the numbers above — Full Disk Access is still"
    warn "not granted, so Chrome/Brave/Edge/Firefox read as 0 B. Granting it and"
    warn "re-running is likely worth another 10+ GB on this machine."
  fi
  return 0
}

report_top_offenders() {
  section "Where your disk space actually is"
  check_full_disk_access
  [ "$FDA_OK" = 0 ] && warn "running without Full Disk Access — browser/mail sizes below will read as 0"

  local targets=(
    "$HOME_DIR/Library/Application Support"
    "$HOME_DIR/Library/Containers"
    "$HOME_DIR/Library/Caches"
    "$HOME_DIR/Library/Developer"
    "$HOME_DIR/Library/Android"
    "$HOME_DIR/Library/Group Containers"
    "$HOME_DIR/.cache"
    "$HOME_DIR/.gradle"
    "$HOME_DIR/.npm"
    "$HOME_DIR/.yarn"
    "$HOME_DIR/.pub-cache"
    "$HOME_DIR/.konan"
    "$HOME_DIR/.android"
    "$HOME_DIR/.docker"
    "$HOME_DIR/.lmstudio"
    "$HOME_DIR/.ollama"
    "$HOME_DIR/Downloads"
    "$HOME_DIR/Documents"
    "$HOME_DIR/Desktop"
    "$HOME_DIR/Movies"
    "$HOME_DIR/Music"
    "$HOME_DIR/Pictures"
    "$HOME_DIR/.Trash"
    "/Applications"
    "/opt/homebrew"
    "/usr/local"
    "/Library/Developer"
    "/private/var/folders"
  )

  info "Top directories by size — a full home-directory walk, expect a few minutes..."
  local t
  {
    for t in "${targets[@]}"; do
      [ -e "$t" ] || continue
      du -sxk "$t" 2>/dev/null | tail -1
    done
  } | sort -rn | head -20 | while IFS=$'\t' read -r kb path; do
    printf '  %10s  %s\n' "$(human_kb "$kb")" "$path" | tee -a "$LOG_FILE"
  done

  # Big single directories anywhere under home, which is how you find the
  # 12 GB node_modules / dataset / VM image you forgot about.
  say ""
  info "Largest individual folders under \$HOME (depth 4, >1 GB):"
  du -xk -d4 "$HOME_DIR" 2>/dev/null \
    | awk '$1 > 1048576' | sort -rn | head -25 \
    | while IFS=$'\t' read -r kb path; do
        printf '  %10s  %s\n' "$(human_kb "$kb")" "$path" | tee -a "$LOG_FILE"
      done

  # Stale node_modules — nothing deletes these for you and they are pure build
  # artefact that `npm install` regenerates.
  #
  # Only *project* node_modules count. A node_modules shipped inside an
  # installed VS Code / Claude / Copilot extension is part of that extension
  # and deleting it breaks the extension, so anything under a dot-directory,
  # ~/Library, or an extensions/ folder is filtered out. The parent must also
  # have a package.json, which is what makes `npm install` able to rebuild it.
  say ""
  info "Stale project node_modules (untouched 90+ days, rebuilt by \`npm install\`):"
  local nm_total=0 nm_kb nm parent
  while IFS= read -r nm; do
    [ -d "$nm" ] || continue
    case "$nm" in
      */.*/*|"$HOME_DIR/Library/"*|*/extensions/*|*/node_modules/*/node_modules) continue ;;
    esac
    parent="$(dirname "$nm")"
    [ -f "$parent/package.json" ] || continue
    nm_kb="$(du -sxk "$nm" 2>/dev/null | awk '{print $1}')"
    nm_total=$((nm_total + ${nm_kb:-0}))
    printf '%s\t%s\n' "${nm_kb:-0}" "$nm"
  done < <(find "$HOME_DIR" -maxdepth 7 -type d -name node_modules -mtime +90 -prune 2>/dev/null) \
    | sort -rn | head -25 \
    | while IFS=$'\t' read -r nm_kb nm; do
        printf '  %10s  %s\n' "$(human_kb "$nm_kb")" "$nm" | tee -a "$LOG_FILE"
      done
  info "Delete one with: rm -rf <path>   (then \`npm install\` when you next need it)"

  # Purgeable space / snapshots: the other half of the "System Data" mystery.
  say ""
  info "Volume accounting:"
  df -h / /System/Volumes/Data 2>/dev/null | while IFS= read -r l; do printf '  %s\n' "$l" | tee -a "$LOG_FILE"; done
  local snaps
  snaps="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)"
  info "Local Time Machine snapshots: ${snaps:-0} (these count as 'System Data' and are purgeable)"
  say ""
  info "Note: 'System Data' in Settings > Storage is a leftover bucket, not a real folder."
  info "It is mostly the items above that Finder cannot categorise — VM disks, SDKs,"
  info "caches, snapshots and purgeable space. Clearing the categories in this script"
  info "and then rebooting is what makes the number move."
  return 0
}

# ---------------------------------------------------------------------------
# Category: tmp
#
# $TMPDIR (/private/var/folders/<x>/<y>/T) and the matching per-user cache
# directory (.../C). macOS only sweeps these on boot, and only for files past
# a few days old, so a machine that stays awake for weeks accumulates
# gigabytes of abandoned test scratch, build temp and installer payloads here.
#
# Age-gated by default because $TMPDIR is live: a running process may well be
# using a file created minutes ago. Anything newer than --tmp-stale-days is
# reported but left alone.
# ---------------------------------------------------------------------------

cat_tmp() {
  section "Temporary files (\$TMPDIR + per-user cache)"

  local tdir cdir
  tdir="${TMPDIR:-}"
  tdir="${tdir%/}"
  if [ -z "$tdir" ] || [ ! -d "$tdir" ]; then
    info "no \$TMPDIR found, skipped"
    return
  fi
  # .../T and .../C are siblings under the same per-user folder.
  cdir="$(dirname "$tdir")/C"

  local days="$TMP_STALE_DAYS"
  [ "$AGGRESSIVE" = 1 ] && days=0

  local root entry kept_kb=0 kept_n=0 sz
  for root in "$tdir" "$cdir"; do
    [ -d "$root" ] || continue
    info "-- $root ($(human_kb "$(dir_size_kb "$root")"))"

    # -mindepth/-maxdepth 1: only whole top-level entries, never a file from
    # inside a directory some process is mid-write on.
    while IFS= read -r entry; do
      [ -e "$entry" ] || continue
      case "$(basename "$entry")" in
        # Apple's own live IPC/staging dirs — removing these while the OS is
        # running causes visible breakage rather than reclaiming anything.
        com.apple.*|TemporaryItems|.keystone_install*|Cleanup\ At\ Startup) continue ;;
      esac
      remove_path "$entry"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime +"$days" 2>/dev/null)

    # Report what the age gate spared, so a multi-GB fresh scratch dir is
    # still visible rather than silently skipped.
    while IFS= read -r entry; do
      [ -e "$entry" ] || continue
      sz="$(dir_size_kb "$entry")"
      [ "${sz:-0}" -gt 102400 ] || continue    # only flag entries over 100 MB
      kept_n=$((kept_n + 1))
      kept_kb=$((kept_kb + sz))
      warn "left alone (modified in the last $days day(s)): $entry ($(human_kb "$sz"))"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime -"$((days + 1))" 2>/dev/null)
  done

  if [ "$kept_n" -gt 0 ]; then
    info "$kept_n recent item(s) totalling $(human_kb "$kept_kb") were skipped as too new."
    info "Quit the app that owns them and re-run, or use --aggressive to take them anyway."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Category: toolchains (opt-in)
#
# SDK/compiler toolchains that each pin their own version and never clean up
# after an upgrade: Kotlin/Native prebuilts, Gradle wrapper distributions,
# Gradle's auto-provisioned JDKs, SDKMAN candidates. All are re-downloaded on
# demand, but a project pinned to an old version will re-fetch it, so this is
# opt-in and always keeps the newest.
# ---------------------------------------------------------------------------

# Keep the newest N entries matching a glob, remove the rest. Version-sorted.
# $1 = human label, $2 = keep count, $3.. = candidate dirs
_keep_newest_versions() {
  local label="$1" keep="$2"; shift 2
  local total=$# dir i=0 sorted
  [ "$total" -gt 0 ] || return 0
  if [ "$total" -le "$keep" ]; then
    info "$label: $total installed, keeping all (limit $keep)"
    return 0
  fi
  sorted="$(printf '%s\n' "$@" | sort -V)"
  local drop=$((total - keep))
  while IFS= read -r dir; do
    i=$((i + 1))
    [ "$i" -gt "$drop" ] && break
    remove_path "$dir"
  done <<EOF
$sorted
EOF
  info "$label: kept the newest $keep of $total"
  return 0
}

cat_toolchains() {
  section "Superseded SDK/compiler toolchains"
  if [ "$INCLUDE_TOOLCHAINS" != 1 ]; then
    local d sz any=0
    for d in "$HOME_DIR/.konan" "$HOME_DIR/.gradle/wrapper/dists" \
             "$HOME_DIR/.gradle/jdks" "$HOME_DIR/.sdkman/candidates"; do
      [ -d "$d" ] || continue
      sz="$(dir_size_kb "$d")"
      [ "${sz:-0}" -gt 0 ] || continue
      any=1
      info "$d — $(human_kb "$sz")"
    done
    [ "$any" = 1 ] && warn "not removed (opt-in: pass --include-toolchains)" \
                   || info "no versioned toolchains found"
    return
  fi

  # Kotlin/Native prebuilt compilers — ~1.7 GB each.
  if [ -d "$HOME_DIR/.konan" ]; then
    local konan=()
    local d
    for d in "$HOME_DIR"/.konan/kotlin-native-prebuilt-*/; do
      d="${d%/}"; [ -d "$d" ] && konan+=("$d")
    done
    [ "${#konan[@]}" -gt 0 ] && _keep_newest_versions "Kotlin/Native prebuilts" "$KEEP_TOOLCHAINS" "${konan[@]}"
  fi

  # Gradle wrapper distributions — one per Gradle version any project used.
  if [ -d "$HOME_DIR/.gradle/wrapper/dists" ]; then
    local dists=()
    for d in "$HOME_DIR"/.gradle/wrapper/dists/gradle-*/; do
      d="${d%/}"; [ -d "$d" ] && dists+=("$d")
    done
    [ "${#dists[@]}" -gt 0 ] && _keep_newest_versions "Gradle distributions" "$KEEP_TOOLCHAINS" "${dists[@]}"
  fi

  # JDKs Gradle auto-provisioned for toolchain resolution — always re-fetched.
  if [ -d "$HOME_DIR/.gradle/jdks" ]; then
    info "Gradle auto-provisioned JDKs (re-downloaded on next build):"
    clear_dir_contents "$HOME_DIR/.gradle/jdks"
  fi

  # SDKMAN: every candidate except the one `current` points at.
  if [ -d "$HOME_DIR/.sdkman/candidates" ]; then
    local cand ver current_target
    for cand in "$HOME_DIR"/.sdkman/candidates/*/; do
      cand="${cand%/}"
      [ -d "$cand" ] || continue
      current_target=""
      [ -L "$cand/current" ] && current_target="$(basename "$(readlink "$cand/current")" 2>/dev/null)"
      for ver in "$cand"/*/; do
        ver="${ver%/}"
        case "$(basename "$ver")" in
          current) continue ;;
          "$current_target") verbose "keeping active: $ver"; continue ;;
        esac
        remove_path "$ver"
      done
    done
  fi
  return 0
}

cat_trash() {
  section "Trash"
  if [ "$INCLUDE_TRASH" != 1 ]; then
    warn "skipped (opt-in only, pass --include-trash)"
    return
  fi
  if [ "$MODE" = "clean" ] && ! confirm "Permanently empty ~/.Trash? This cannot be undone."; then
    warn "skipped by user"
    return
  fi
  clear_dir_contents "$HOME_DIR/.Trash"
}

run_category() {
  local id="$1"
  should_run_category "$id" || return 0
  RAN_ANY=1
  case "$id" in
    caches) cat_caches ;;
    logs) cat_logs ;;
    diagnostics) cat_diagnostics ;;
    dsstore) cat_dsstore ;;
    quicklook) cat_quicklook ;;
    xcode-derived) cat_xcode_derived ;;
    xcode-archives) cat_xcode_archives ;;
    sim-caches) cat_sim_caches ;;
    sim-unavailable) cat_sim_unavailable ;;
    device-support) cat_device_support ;;
    homebrew) cat_homebrew ;;
    npm) cat_npm ;;
    yarn) cat_yarn ;;
    pnpm) cat_pnpm ;;
    cocoapods) cat_cocoapods ;;
    gradle) cat_gradle ;;
    pip) cat_pip ;;
    timemachine) cat_timemachine ;;
    docker) cat_docker ;;
    docker-cache) cat_docker_cache ;;
    mail) cat_mail ;;
    trash) cat_trash ;;
    orphans) cat_orphans ;;
    whatsapp) cat_whatsapp ;;
    sim-stale) cat_sim_stale ;;
    claude-cache) cat_claude_cache ;;
    android) cat_android ;;
    browsers) cat_browsers ;;
    electron) cat_electron ;;
    dev-caches) cat_dev_caches ;;
    ide-stale) cat_ide_stale ;;
    ml-caches) cat_ml_caches ;;
    ios-backups) cat_ios_backups ;;
    tmp) cat_tmp ;;
    toolchains) cat_toolchains ;;
    *) warn "unknown category: $id" ;;
  esac
}

# ---------------------------------------------------------------------------
# Whitelist presets
# ---------------------------------------------------------------------------

apply_whitelist_preset() {
  case "$1" in
    browsers)
      WHITELIST+=("$HOME_DIR/Library/Application Support/Google/Chrome")
      WHITELIST+=("$HOME_DIR/Library/Application Support/Firefox")
      WHITELIST+=("$HOME_DIR/Library/Application Support/BraveSoftware")
      WHITELIST+=("$HOME_DIR/Library/Application Support/Microsoft Edge")
      WHITELIST+=("$HOME_DIR/Library/Application Support/Arc")
      ;;
    ml)
      WHITELIST+=("$HOME_DIR/.cache/huggingface")
      WHITELIST+=("$HOME_DIR/.cache/torch")
      WHITELIST+=("$HOME_DIR/.ollama")
      WHITELIST+=("$HOME_DIR/.lmstudio")
      ;;
    xcode-simulator)
      WHITELIST+=("$HOME_DIR/Library/Developer/CoreSimulator")
      WHITELIST+=("$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport")
      ;;
    xcode-derived)
      WHITELIST+=("$HOME_DIR/Library/Developer/Xcode/DerivedData")
      ;;
    node)
      WHITELIST+=("$HOME_DIR/Library/Caches/Yarn")
      WHITELIST+=("$HOME_DIR/.npm")
      WHITELIST+=("$HOME_DIR/Library/pnpm")
      ;;
    *)
      printf 'clean.sh: error: unknown whitelist preset: %s\n' "$1" >&2
      printf '  known presets: xcode-simulator, xcode-derived, node, browsers, ml\n' >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

load_config

# Bare invocation from an actual terminal drops into the interactive menu;
# any flag at all keeps the script fully scriptable/non-interactive as before.
if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  INTERACTIVE=1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--interactive) INTERACTIVE=1; shift ;;
    --scan) MODE="scan"; shift ;;
    --clean) MODE="clean"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --keep-device-support)
      require_arg "--keep-device-support" "$#" "${2-}"
      validate_int "--keep-device-support" "$2"
      KEEP_DEVICE_SUPPORT="$2"; shift 2 ;;
    --keep-device-support=*)
      validate_int "--keep-device-support" "${1#*=}"
      KEEP_DEVICE_SUPPORT="${1#*=}"; shift ;;
    --only)
      require_arg "--only" "$#" "${2-}"
      ONLY_LIST="$(normalize_category_list "--only" "$2")" || exit "$EXIT_USAGE"; shift 2 ;;
    --only=*)
      ONLY_LIST="$(normalize_category_list "--only" "${1#*=}")" || exit "$EXIT_USAGE"; shift ;;
    --skip)
      require_arg "--skip" "$#" "${2-}"
      SKIP_LIST="$(normalize_category_list "--skip" "$2")" || exit "$EXIT_USAGE"; shift 2 ;;
    --skip=*)
      SKIP_LIST="$(normalize_category_list "--skip" "${1#*=}")" || exit "$EXIT_USAGE"; shift ;;
    --whitelist)
      require_arg "--whitelist" "$#" "${2-}"
      IFS=',' read -r -a _wl <<< "$2"; WHITELIST+=("${_wl[@]}"); shift 2 ;;
    --whitelist=*)
      IFS=',' read -r -a _wl <<< "${1#*=}"; WHITELIST+=("${_wl[@]}"); shift ;;
    --whitelist-preset)
      require_arg "--whitelist-preset" "$#" "${2-}"
      apply_whitelist_preset "$2" || exit "$EXIT_USAGE"; shift 2 ;;
    --whitelist-preset=*)
      apply_whitelist_preset "${1#*=}" || exit "$EXIT_USAGE"; shift ;;
    --include-trash) INCLUDE_TRASH=1; shift ;;
    --include-mail) INCLUDE_MAIL=1; shift ;;
    --include-docker) INCLUDE_DOCKER=1; shift ;;
    --include-docker-cache) INCLUDE_DOCKER_CACHE=1; shift ;;
    --include-orphans) INCLUDE_ORPHANS=1; shift ;;
    --include-whatsapp) INCLUDE_WHATSAPP=1; shift ;;
    --include-sim-stale) INCLUDE_SIM_STALE=1; shift ;;
    --sim-stale-days)
      require_arg "--sim-stale-days" "$#" "${2-}"
      validate_int "--sim-stale-days" "$2"
      SIM_STALE_DAYS="$2"; shift 2 ;;
    --sim-stale-days=*)
      validate_int "--sim-stale-days" "${1#*=}"
      SIM_STALE_DAYS="${1#*=}"; shift ;;
    --include-claude-cache) INCLUDE_CLAUDE_CACHE=1; shift ;;
    --include-android) INCLUDE_ANDROID=1; shift ;;
    --include-ide-stale) INCLUDE_IDE_STALE=1; shift ;;
    --include-ml-caches) INCLUDE_ML_CACHES=1; shift ;;
    --include-ios-backups) INCLUDE_IOS_BACKUPS=1; shift ;;
    --include-toolchains) INCLUDE_TOOLCHAINS=1; shift ;;
    --tmp-stale-days)
      require_arg "--tmp-stale-days" "$#" "${2-}"
      validate_int "--tmp-stale-days" "$2"
      TMP_STALE_DAYS="$2"; shift 2 ;;
    --tmp-stale-days=*)
      validate_int "--tmp-stale-days" "${1#*=}"
      TMP_STALE_DAYS="${1#*=}"; shift ;;
    --keep-toolchains)
      require_arg "--keep-toolchains" "$#" "${2-}"
      validate_int "--keep-toolchains" "$2"
      KEEP_TOOLCHAINS="$2"; shift 2 ;;
    --keep-toolchains=*)
      validate_int "--keep-toolchains" "${1#*=}"
      KEEP_TOOLCHAINS="${1#*=}"; shift ;;
    --report) REPORT_ONLY=1; shift ;;
    --no-log) NO_LOG=1; shift ;;
    --keep-logs)
      require_arg "--keep-logs" "$#" "${2-}"
      validate_int "--keep-logs" "$2"
      KEEP_LOGS="$2"; shift 2 ;;
    --keep-logs=*)
      validate_int "--keep-logs" "${1#*=}"
      KEEP_LOGS="${1#*=}"; shift ;;
    --android-stale-days)
      require_arg "--android-stale-days" "$#" "${2-}"
      validate_int "--android-stale-days" "$2"
      ANDROID_STALE_DAYS="$2"; shift 2 ;;
    --android-stale-days=*)
      validate_int "--android-stale-days" "${1#*=}"
      ANDROID_STALE_DAYS="${1#*=}"; shift ;;
    --remove-orphans-from)
      require_arg "--remove-orphans-from" "$#" "${2-}"
      [ -r "$2" ] || die_usage "--remove-orphans-from: cannot read review file '$2'"
      REMOVE_ORPHANS_FILE="$2"; shift 2 ;;
    --remove-orphans-from=*)
      [ -r "${1#*=}" ] || die_usage "--remove-orphans-from: cannot read review file '${1#*=}'"
      REMOVE_ORPHANS_FILE="${1#*=}"; shift ;;
    --list) print_category_list; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *)
      err "unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# The config file gets the same treatment the CLI just got. Deliberately after
# the parse loop: --help and --list exit inside it, so documentation stays
# reachable even when the saved config is broken.
validate_config_values

# Apply default-on/off filtering only when --only wasn't explicitly given.
#
# A category selection saved from the interactive menu takes precedence over
# the built-in defaults, for scripted runs as much as interactive ones — that
# is the whole point of saving it. An explicit --only still beats both.
if [ -z "$ONLY_LIST" ]; then
  if [ -n "$CONFIG_SELECTED_CATEGORIES" ]; then
    ONLY_LIST="$CONFIG_SELECTED_CATEGORIES"
    # An opt-in category named in the saved selection also needs its
    # --include-* gate opened, or it would appear in the run list and then
    # refuse to do anything ("skipped (opt-in only)").
    for _id in $ALL_CATEGORY_IDS; do
      case ",$ONLY_LIST," in
        *",$_id,"*)
          _var="$(category_include_var "$_id")"
          [ -n "$_var" ] && printf -v "$_var" '1'
          ;;
      esac
    done
  else
    default_ids=""
    for _id in $ALL_CATEGORY_IDS; do
      _info_line="$(category_info "$_id")"
      _default="$(echo "$_info_line" | cut -d'|' -f2)"
      [ "$_default" = "1" ] && default_ids="$default_ids,$_id"
    done
    ONLY_LIST="${default_ids#,}"
  fi
fi

# Any --include-X flag is itself an explicit request to run that category,
# whether or not --only named it (or code defaults would have included it).
# --skip still wins (checked first in should_run_category).
for _id in $ALL_CATEGORY_IDS; do
  _var="$(category_include_var "$_id")"
  if [ -n "$_var" ] && [ "${!_var}" = "1" ]; then
    case ",$ONLY_LIST," in
      *",$_id,"*) ;;
      *) ONLY_LIST="${ONLY_LIST:+$ONLY_LIST,}$_id" ;;
    esac
  fi
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------

compute_code_default_ids() {
  local ids="" id info default
  for id in $ALL_CATEGORY_IDS; do
    info="$(category_info "$id")"
    default="$(printf '%s' "$info" | cut -d'|' -f2)"
    [ "$default" = "1" ] && ids="${ids:+$ids,}$id"
  done
  printf '%s' "$ids"
}

reset_all_include_vars() {
  local id var
  for id in $ALL_CATEGORY_IDS; do
    var="$(category_include_var "$id")"
    [ -n "$var" ] && printf -v "$var" '0'
  done
}

interactive_pause() {
  read -r -p "Press Enter to continue..." _ </dev/tty
}

print_live_category_state() {
  printf '%-16s %-9s %-6s %s\n' "ID" "RISK" "STATE" "DESCRIPTION"
  local i id info risk desc state
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    id="${CATEGORY_STATE_IDS[$i]}"
    info="$(category_info "$id")"
    risk="$(printf '%s' "$info" | cut -d'|' -f1)"
    desc="$(printf '%s' "$info" | cut -d'|' -f3)"
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && state="on" || state="off"
    printf '%-16s %-9s %-6s %s\n' "$id" "$risk" "$state" "$desc"
  done
}

view_last_log() {
  local f
  f="$(ls -t "$LOG_DIR"/clean-*.log 2>/dev/null | head -1)"
  if [ -z "$f" ]; then
    info "no log files yet"
    return
  fi
  say "Showing last 60 lines of: $f"
  say "---"
  tail -60 "$f"
  say "---"
}

# ---------------------------------------------------------------------------
# Keyboard-driven menus
#
# Arrow keys to move, space to toggle, enter to accept. Written against bash
# 3.2 (macOS /bin/bash): no fractional `read -t`, no associative arrays, so
# escape sequences are read as a fixed 2-char follow-up, and the whole picker
# state lives in the parallel CATEGORY_STATE_* arrays.
#
# Everything degrades to the old typed-number menus when stdin is not a real
# terminal, so piping the script or running it under CI still works.
# ---------------------------------------------------------------------------

# bash 4+ accepts `read -t 0.05`; bash 3.2 rejects it with an error on stderr.
# Detected once so a lone Esc keypress can be distinguished from an arrow key
# where the shell supports it.
_READ_FRAC_T=-1
supports_frac_timeout() {
  if [ "$_READ_FRAC_T" = -1 ]; then
    if [ -z "$( { read -t 0.01 _ </dev/null; } 2>&1 )" ]; then
      _READ_FRAC_T=1
    else
      _READ_FRAC_T=0
    fi
  fi
  [ "$_READ_FRAC_T" = 1 ]
}

tui_available() {
  [ -t 0 ] && [ -t 1 ]
}

_CURSOR_HIDDEN=0
tui_begin() {
  tui_available || return 0
  printf '\033[?25l'   # hide cursor
  _CURSOR_HIDDEN=1
  trap '_cleanup_on_exit' EXIT INT TERM
}
tui_end() {
  [ "$_CURSOR_HIDDEN" = 1 ] || return 0
  printf '\033[?25h'   # show cursor
  _CURSOR_HIDDEN=0
}

# Read one keypress and echo a symbolic name for it.
read_key() {
  local k rest
  IFS= read -rsn1 k </dev/tty 2>/dev/null || { printf 'quit'; return; }
  case "$k" in
    '')   printf 'enter'; return ;;
    ' ')  printf 'space'; return ;;
    $'\t') printf 'tab'; return ;;
    $'\177'|$'\b') printf 'backspace'; return ;;
  esac
  if [ "$k" = $'\033' ]; then
    if supports_frac_timeout; then
      IFS= read -rsn2 -t 0.05 rest </dev/tty 2>/dev/null
    else
      # bash 3.2: an arrow key always delivers its two remaining bytes
      # immediately, so a blocking read is safe. A bare Esc needs a second
      # keypress to come back — which is why every menu also accepts `q`.
      IFS= read -rsn2 rest </dev/tty 2>/dev/null
    fi
    case "$rest" in
      '[A'|'OA') printf 'up' ;;
      '[B'|'OB') printf 'down' ;;
      '[C'|'OC') printf 'right' ;;
      '[D'|'OD') printf 'left' ;;
      '[H'|'OH') printf 'home' ;;
      '[F'|'OF') printf 'end' ;;
      '[5') IFS= read -rsn1 _ </dev/tty 2>/dev/null; printf 'pgup' ;;
      '[6') IFS= read -rsn1 _ </dev/tty 2>/dev/null; printf 'pgdn' ;;
      '')   printf 'esc' ;;
      *)    printf 'other' ;;
    esac
    return
  fi
  printf '%s' "$k"
}

# Terminal size. `tput lines` is read via a command substitution here, which
# makes its stdout a pipe — ncurses then cannot run TIOCGWINSZ and silently
# falls back to terminfo's default 24, which would make the viewport taller
# than the window and corrupt the redraw. `stty size </dev/tty` asks the
# terminal directly and is correct regardless of where stdout points.
term_rows() {
  local r
  r="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  case "$r" in ''|*[!0-9]*) r="$(tput lines 2>/dev/null)" ;; esac
  case "$r" in ''|*[!0-9]*) r=24 ;; esac
  [ "$r" -lt 10 ] && r=10
  printf '%s' "$r"
}

term_cols() {
  local c
  c="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  case "$c" in ''|*[!0-9]*) c="$(tput cols 2>/dev/null)" ;; esac
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 40 ] && c=40
  printf '%s' "$c"
}

# Erase the previous frame: move the cursor back up N lines, then clear
# everything below it.
tui_clear_frame() {
  local n="$1"
  [ "${n:-0}" -gt 0 ] || return 0
  printf '\033[%dA\033[J' "$n"
}

# ---------------------------------------------------------------------------
# Multi-select category picker
# ---------------------------------------------------------------------------

# Colour a risk word so "risky" is impossible to tick by accident.
_risk_colored() {
  case "$1" in
    safe)     printf '%s%-8s%s' "$C_GREEN" "safe" "$C_RESET" ;;
    moderate) printf '%s%-8s%s' "$C_YELLOW" "moderate" "$C_RESET" ;;
    risky)    printf '%s%-8s%s' "$C_RED" "risky" "$C_RESET" ;;
    *)        printf '%-8s' "$1" ;;
  esac
}

_picker_draw() {
  # $1 = cursor index, $2 = viewport top index, $3 = viewport height
  local cur="$1" top="$2" vh="$3"
  local i id info risk desc mark line count on=0 dw
  count="${#CATEGORY_STATE_IDS[@]}"
  # "❯ [x] " + 16 id + 8 risk + spacing = 34 columns before the description.
  # A row that wraps would desync the cursor arithmetic in tui_clear_frame,
  # so descriptions are hard-truncated to what is left.
  dw=$(( $(term_cols) - 34 ))
  [ "$dw" -lt 10 ] && dw=10

  for i in "${!CATEGORY_STATE_ON[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && on=$((on + 1))
  done

  printf '%s\n' "${C_BOLD}Choose categories${C_RESET}  ${C_DIM}(${on}/${count} selected)${C_RESET}"
  # The hint line must not wrap either — a wrapped header would shift every
  # subsequent frame up by one line. Narrow terminals get the short form.
  if [ "$(term_cols)" -ge 92 ]; then
    printf '%s\n' "${C_DIM}  ↑/↓ move   space toggle   enter run scan   c clean   a all   x none   r reset   q back${C_RESET}"
  elif [ "$(term_cols)" -ge 66 ]; then
    printf '%s\n' "${C_DIM}  ↑↓ move  space toggle  ⏎ scan  c clean  q back${C_RESET}"
  else
    printf '%s\n' "${C_DIM}  ↑↓ space ⏎scan c q${C_RESET}"
  fi
  printf '%s\n' ""

  local end=$((top + vh))
  [ "$end" -gt "$count" ] && end="$count"
  i="$top"
  while [ "$i" -lt "$end" ]; do
    id="${CATEGORY_STATE_IDS[$i]}"
    info="$(category_info "$id")"
    risk="$(printf '%s' "$info" | cut -d'|' -f1)"
    desc="$(printf '%s' "$info" | cut -d'|' -f3)"
    if [ "${CATEGORY_STATE_ON[$i]}" = "1" ]; then mark="${C_GREEN}[x]${C_RESET}"; else mark="[ ]"; fi
    # Keep rows inside the window so a wrapped line never breaks the redraw.
    desc="$(printf "%.${dw}s" "$desc")"
    line="$(printf '%s %-16s %s %s' "$mark" "$id" "$(_risk_colored "$risk")" "$desc")"
    if [ "$i" = "$cur" ]; then
      printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${C_RESET}${C_BOLD}${line}${C_RESET}"
    else
      printf '  %s\n' "$line"
    fi
    i=$((i + 1))
  done

  # Scroll hint, so a long list never looks truncated.
  if [ "$count" -gt "$vh" ]; then
    printf '%s\n' "${C_DIM}  — showing $((top + 1))-$end of $count —${C_RESET}"
  else
    printf '\n'
  fi
  return 0
}

interactive_choose_categories() {
  tui_available || { interactive_choose_categories_numeric; return; }

  local count cur=0 top=0 vh rows drawn key i
  count="${#CATEGORY_STATE_IDS[@]}"

  tui_begin
  drawn=0
  while true; do
    rows="$(term_rows)"
    vh=$((rows - 6))
    [ "$vh" -lt 5 ] && vh=5
    [ "$vh" -gt "$count" ] && vh="$count"

    # Keep the cursor inside the viewport.
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    tui_clear_frame "$drawn"
    _picker_draw "$cur" "$top" "$vh"
    drawn=$((vh + 4))

    key="$(read_key)"
    case "$key" in
      up|k)    cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)) ;;
      down|j)  cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0 ;;
      pgup)    cur=$((cur - vh)); [ "$cur" -lt 0 ] && cur=0 ;;
      pgdn)    cur=$((cur + vh)); [ "$cur" -ge "$count" ] && cur=$((count - 1)) ;;
      home|g)  cur=0 ;;
      end|G)   cur=$((count - 1)) ;;
      space|right)
        toggle_category_state "${CATEGORY_STATE_IDS[$cur]}" ;;
      a|A)
        for i in "${!CATEGORY_STATE_IDS[@]}"; do
          CATEGORY_STATE_ON[$i]=1
          sync_include_var "${CATEGORY_STATE_IDS[$i]}" 1
        done ;;
      x|X|n|N)
        for i in "${!CATEGORY_STATE_IDS[@]}"; do
          CATEGORY_STATE_ON[$i]=0
          sync_include_var "${CATEGORY_STATE_IDS[$i]}" 0
        done ;;
      r|R) build_category_state ;;
      s|S|enter)
        tui_end
        say ""
        MODE=scan
        ONLY_LIST="$(only_list_from_category_state)"
        SKIP_LIST=""
        if [ -z "$ONLY_LIST" ]; then
          warn "nothing selected"
        else
          run_selected_categories
        fi
        interactive_pause
        tui_begin
        drawn=0
        ;;
      c|C)
        tui_end
        say ""
        MODE=clean
        ONLY_LIST="$(only_list_from_category_state)"
        SKIP_LIST=""
        if [ -z "$ONLY_LIST" ]; then
          warn "nothing selected"
        else
          run_selected_categories
        fi
        interactive_pause
        tui_begin
        drawn=0
        ;;
      q|Q|b|B|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        return 0 ;;
      *) ;;
    esac
  done
}

# Fallback used when stdin/stdout is not a terminal (pipes, CI, `script`).
interactive_choose_categories_numeric() {
  local i id state marker info risk desc sel idx
  while true; do
    say ""
    say "${C_BOLD}Choose categories${C_RESET} (number=toggle, s=all, n=none, r=reset, w=scan, c=clean, b=back)"
    for i in "${!CATEGORY_STATE_IDS[@]}"; do
      id="${CATEGORY_STATE_IDS[$i]}"
      info="$(category_info "$id")"
      risk="$(printf '%s' "$info" | cut -d'|' -f1)"
      desc="$(printf '%s' "$info" | cut -d'|' -f3)"
      if [ "${CATEGORY_STATE_ON[$i]}" = "1" ]; then marker="[x]"; else marker="[ ]"; fi
      printf '  %2d) %s %-16s %-9s %s\n' "$((i + 1))" "$marker" "$id" "$risk" "$desc"
    done
    read -r -p "> " sel </dev/tty
    case "$sel" in
      s|S) for i in "${!CATEGORY_STATE_IDS[@]}"; do CATEGORY_STATE_ON[$i]=1; sync_include_var "${CATEGORY_STATE_IDS[$i]}" 1; done ;;
      n|N) for i in "${!CATEGORY_STATE_IDS[@]}"; do CATEGORY_STATE_ON[$i]=0; sync_include_var "${CATEGORY_STATE_IDS[$i]}" 0; done ;;
      r|R) build_category_state ;;
      w|W) MODE=scan;  ONLY_LIST="$(only_list_from_category_state)"; SKIP_LIST=""; run_selected_categories; interactive_pause ;;
      c|C) MODE=clean; ONLY_LIST="$(only_list_from_category_state)"; SKIP_LIST=""; run_selected_categories; interactive_pause ;;
      b|B) return ;;
      [0-9]*)
        idx=$((sel - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#CATEGORY_STATE_IDS[@]}" ]; then
          toggle_category_state "${CATEGORY_STATE_IDS[$idx]}"
        else
          warn "no such category number: $sel"
        fi ;;
      *) warn "unrecognized option: $sel" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Single-select menu (used for the main menu)
#
# MENU_LABELS is filled by the caller; the chosen index lands in MENU_CHOICE.
# ---------------------------------------------------------------------------

MENU_LABELS=()
MENU_CHOICE=-1

menu_select() {
  # $1 = title, $2 = starting index
  local title="$1" cur="${2:-0}" count drawn=0 key i rows vh top=0
  count="${#MENU_LABELS[@]}"
  [ "$count" -gt 0 ] || { MENU_CHOICE=-1; return 1; }
  [ "$cur" -ge "$count" ] && cur=0

  if ! tui_available; then
    for i in "${!MENU_LABELS[@]}"; do
      printf '  %2d) %s\n' "$((i + 1))" "${MENU_LABELS[$i]}"
    done
    local sel
    read -r -p "> " sel </dev/tty
    case "$sel" in
      ''|*[!0-9]*) MENU_CHOICE=-1; return 1 ;;
    esac
    MENU_CHOICE=$((sel - 1))
    [ "$MENU_CHOICE" -ge 0 ] && [ "$MENU_CHOICE" -lt "$count" ] && return 0
    MENU_CHOICE=-1
    return 1
  fi

  tui_begin
  while true; do
    rows="$(term_rows)"
    vh=$((rows - 5))
    [ "$vh" -lt 4 ] && vh=4
    [ "$vh" -gt "$count" ] && vh="$count"
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    tui_clear_frame "$drawn"
    printf '%s\n' "${C_BOLD}${title}${C_RESET}"
    printf '%s\n' "${C_DIM}  ↑/↓ move   enter select   q quit${C_RESET}"
    local end=$((top + vh))
    [ "$end" -gt "$count" ] && end="$count"
    i="$top"
    while [ "$i" -lt "$end" ]; do
      local label mw
      mw=$(( $(term_cols) - 3 ))
      [ "$mw" -lt 10 ] && mw=10
      label="$(printf "%.${mw}s" "${MENU_LABELS[$i]}")"
      if [ "$i" = "$cur" ]; then
        printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${label}${C_RESET}"
      else
        printf '  %s\n' "$label"
      fi
      i=$((i + 1))
    done
    drawn=$((vh + 2))

    key="$(read_key)"
    case "$key" in
      up|k)   cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)) ;;
      down|j) cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0 ;;
      home|g) cur=0 ;;
      end|G)  cur=$((count - 1)) ;;
      enter|space|right)
        tui_clear_frame "$drawn"
        tui_end
        MENU_CHOICE="$cur"
        return 0 ;;
      q|Q|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        MENU_CHOICE=-1
        return 1 ;;
      [0-9])
        i=$((key - 1))
        if [ "$i" -ge 0 ] && [ "$i" -lt "$count" ]; then
          tui_clear_frame "$drawn"
          tui_end
          MENU_CHOICE="$i"
          return 0
        fi ;;
      *) ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Whitelist manager (arrow keys)
#
# The list itself is the cursor target: highlight an entry and press space or
# d to drop it. Adding and applying presets need text, so they briefly hand
# the terminal back (cursor visible, normal line editing) and then resume.
# ---------------------------------------------------------------------------

# Prompt for a line of text from inside a TUI screen without wrecking the
# frame: stop owning the cursor, read normally, then take it back.
tui_prompt() {
  # $1 = prompt, $2 = variable name to store into
  local __p="$1" __var="$2" __val
  tui_end
  printf '\n'
  read -r -p "$__p" __val </dev/tty
  printf -v "$__var" '%s' "$__val"
  tui_begin
}

WHITELIST_PRESET_NAMES="xcode-simulator xcode-derived node browsers ml"

_whitelist_draw() {
  local cur="$1" top="$2" vh="$3" count="$4"
  local i end w
  printf '%s\n' "${C_BOLD}Whitelist${C_RESET}  ${C_DIM}(${count} entr$( [ "$count" = 1 ] && echo y || echo ies))${C_RESET}"
  if [ "$(term_cols)" -ge 80 ]; then
    printf '%s\n' "${C_DIM}  ↑/↓ move   space/d remove   a add   p preset   q back${C_RESET}"
  else
    printf '%s\n' "${C_DIM}  ↑↓ move  space del  a add  p preset  q back${C_RESET}"
  fi
  printf '\n'
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "  ${C_DIM}(empty — nothing is being protected)${C_RESET}"
    return 0
  fi
  end=$((top + vh)); [ "$end" -gt "$count" ] && end="$count"
  i="$top"
  while [ "$i" -lt "$end" ]; do
    w="$(printf "%.$(( $(term_cols) - 4 ))s" "${WHITELIST[$i]}")"
    if [ "$i" = "$cur" ]; then
      printf '%s\n' "${C_BOLD}${C_CYAN}❯ ${w}${C_RESET}"
    else
      printf '  %s\n' "$w"
    fi
    i=$((i + 1))
  done
  return 0
}

interactive_whitelist() {
  tui_available || { interactive_whitelist_numeric; return; }

  local cur=0 top=0 vh rows drawn=0 key count newval i pname
  tui_begin
  while true; do
    # Drop any holes left by earlier removals so indices stay contiguous.
    WHITELIST=("${WHITELIST[@]:-}")
    local compact=()
    for i in "${!WHITELIST[@]}"; do
      [ -n "${WHITELIST[$i]}" ] && compact+=("${WHITELIST[$i]}")
    done
    WHITELIST=("${compact[@]:-}")
    count="${#WHITELIST[@]}"
    [ "${WHITELIST[0]:-}" = "" ] && [ "$count" = 1 ] && count=0

    rows="$(term_rows)"
    vh=$((rows - 5)); [ "$vh" -lt 3 ] && vh=3
    [ "$vh" -gt "$count" ] && vh="$count"
    [ "$cur" -ge "$count" ] && cur=$((count - 1))
    [ "$cur" -lt 0 ] && cur=0
    [ "$cur" -lt "$top" ] && top="$cur"
    [ "$vh" -gt 0 ] && [ "$cur" -ge $((top + vh)) ] && top=$((cur - vh + 1))
    [ "$top" -lt 0 ] && top=0

    tui_clear_frame "$drawn"
    _whitelist_draw "$cur" "$top" "$vh" "$count"
    if [ "$count" -eq 0 ]; then drawn=4; else drawn=$((vh + 3)); fi

    key="$(read_key)"
    case "$key" in
      up|k)   [ "$count" -gt 0 ] && { cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)); } ;;
      down|j) [ "$count" -gt 0 ] && { cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0; } ;;
      space|d|D|backspace)
        if [ "$count" -gt 0 ]; then
          unset "WHITELIST[$cur]"
          WHITELIST=("${WHITELIST[@]}")
          drawn=0
        fi ;;
      a|A)
        tui_prompt "Entry to whitelist (path, ~/path, or glob like com.vendor.*): " newval
        [ -n "$newval" ] && WHITELIST+=("$newval")
        drawn=0 ;;
      p|P)
        tui_end
        MENU_LABELS=()
        for pname in $WHITELIST_PRESET_NAMES; do MENU_LABELS+=("$pname"); done
        if menu_select "Apply which preset?" 0; then
          i=0
          for pname in $WHITELIST_PRESET_NAMES; do
            [ "$i" = "$MENU_CHOICE" ] && apply_whitelist_preset "$pname"
            i=$((i + 1))
          done
        fi
        tui_begin
        drawn=0 ;;
      q|Q|b|B|esc|quit|enter)
        tui_clear_frame "$drawn"
        tui_end
        return 0 ;;
      *) ;;
    esac
  done
}

interactive_whitelist_numeric() {
  local sel i w num newval pname
  while true; do
    say ""
    say "${C_BOLD}Whitelist${C_RESET}"
    i=0
    for w in "${WHITELIST[@]:-}"; do
      [ -z "$w" ] && continue
      i=$((i + 1))
      say "  $i) $w"
    done
    [ "$i" -eq 0 ] && say "  (empty)"
    say "  a) Add entry (path, ~/path, or glob like com.vendor.*)"
    say "  d) Remove entry by number"
    say "  p) Apply preset ($WHITELIST_PRESET_NAMES)"
    say "  b) Back"
    read -r -p "> " sel </dev/tty
    case "$sel" in
      a|A) read -r -p "Entry to whitelist: " newval </dev/tty; [ -n "$newval" ] && WHITELIST+=("$newval") ;;
      d|D)
        read -r -p "Number to remove: " num </dev/tty
        if [ -n "$num" ] && [ -z "${num//[0-9]/}" ] && [ "$num" -ge 1 ] && [ "$num" -le "${#WHITELIST[@]}" ]; then
          unset "WHITELIST[$((num - 1))]"
          WHITELIST=("${WHITELIST[@]}")
        else
          warn "invalid number"
        fi ;;
      p|P) read -r -p "Preset name: " pname </dev/tty; apply_whitelist_preset "$pname" ;;
      b|B) return ;;
      *) warn "unrecognized option: $sel" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Settings (arrow keys)
#
# Numeric settings adjust in place with ←/→ so the common case (nudge a
# threshold) needs no typing at all; enter still opens a prompt for an exact
# value. Booleans toggle with space or enter.
# ---------------------------------------------------------------------------

# id :: kind (num|bool) :: variable :: minimum :: label
SETTINGS_ROWS=(
  "keep-device-support::num::KEEP_DEVICE_SUPPORT::1::Xcode DeviceSupport versions to keep"
  "sim-stale-days::num::SIM_STALE_DAYS::1::Simulator staleness threshold (days)"
  "android-stale-days::num::ANDROID_STALE_DAYS::1::Android AVD staleness threshold (days)"
  "tmp-stale-days::num::TMP_STALE_DAYS::0::Temp file age threshold (days)"
  "keep-toolchains::num::KEEP_TOOLCHAINS::1::Toolchain versions to keep (Kotlin, Gradle)"
  "keep-logs::num::KEEP_LOGS::0::Run logs to keep (0 = keep none)"
  "aggressive::bool::AGGRESSIVE::0::Aggressive mode (prunes harder)"
  "verbose::bool::VERBOSE::0::Verbose output"
  "assume-yes::bool::ASSUME_YES::0::Assume yes (skip confirmation prompts)"
)

_settings_draw() {
  local cur="$1"
  local i row kind var label val shown lw
  printf '%s\n' "${C_BOLD}Settings${C_RESET}"
  if [ "$(term_cols)" -ge 84 ]; then
    printf '%s\n' "${C_DIM}  ↑/↓ move   ←/→ adjust   enter edit or toggle   q back${C_RESET}"
  else
    printf '%s\n' "${C_DIM}  ↑↓ move  ←→ adjust  ⏎ edit  q back${C_RESET}"
  fi
  printf '\n'
  lw=$(( $(term_cols) - 12 ))
  [ "$lw" -lt 20 ] && lw=20
  [ "$lw" -gt 52 ] && lw=52
  for i in "${!SETTINGS_ROWS[@]}"; do
    row="${SETTINGS_ROWS[$i]}"
    kind="${row#*::}"; kind="${kind%%::*}"
    var="${row#*::*::}"; var="${var%%::*}"
    label="${row##*::}"
    val="$(eval printf '%s' "\"\${$var}\"")"
    if [ "$kind" = bool ]; then
      [ "$val" = 1 ] && shown="${C_GREEN}on${C_RESET}" || shown="${C_DIM}off${C_RESET}"
    else
      shown="${C_BOLD}$val${C_RESET}"
    fi
    label="$(printf "%.${lw}s" "$label")"
    if [ "$i" = "$cur" ]; then
      printf "${C_BOLD}${C_CYAN}❯ ${C_RESET}${C_BOLD}%-${lw}s${C_RESET}  %s\n" "$label" "$shown"
    else
      printf "  %-${lw}s  %s\n" "$label" "$shown"
    fi
  done
  return 0
}

interactive_settings() {
  tui_available || { interactive_settings_numeric; return; }

  local cur=0 drawn=0 key count row kind var min val newval
  count="${#SETTINGS_ROWS[@]}"
  tui_begin
  while true; do
    tui_clear_frame "$drawn"
    _settings_draw "$cur"
    drawn=$((count + 3))

    row="${SETTINGS_ROWS[$cur]}"
    kind="${row#*::}"; kind="${kind%%::*}"
    var="${row#*::*::}"; var="${var%%::*}"
    min="${row#*::*::*::}"; min="${min%%::*}"

    key="$(read_key)"
    case "$key" in
      up|k)   cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((count - 1)) ;;
      down|j) cur=$((cur + 1)); [ "$cur" -ge "$count" ] && cur=0 ;;
      left|h)
        if [ "$kind" = bool ]; then
          printf -v "$var" '0'
        else
          val="$(eval printf '%s' "\"\${$var}\"")"
          val=$((val - 1)); [ "$val" -lt "$min" ] && val="$min"
          printf -v "$var" '%s' "$val"
        fi ;;
      right|l)
        if [ "$kind" = bool ]; then
          printf -v "$var" '1'
        else
          val="$(eval printf '%s' "\"\${$var}\"")"
          printf -v "$var" '%s' "$((val + 1))"
        fi ;;
      space|enter)
        if [ "$kind" = bool ]; then
          val="$(eval printf '%s' "\"\${$var}\"")"
          [ "$val" = 1 ] && printf -v "$var" '0' || printf -v "$var" '1'
        else
          val="$(eval printf '%s' "\"\${$var}\"")"
          tui_prompt "New value [$val]: " newval
          case "$newval" in
            ''|*[!0-9]*) [ -n "$newval" ] && warn "not a number, keeping $val" ;;
            *) [ "$newval" -lt "$min" ] && newval="$min"; printf -v "$var" '%s' "$newval" ;;
          esac
          drawn=0
        fi ;;
      q|Q|b|B|esc|quit)
        tui_clear_frame "$drawn"
        tui_end
        return 0 ;;
      *) ;;
    esac
  done
}

interactive_settings_numeric() {
  local sel v
  while true; do
    say ""
    say "${C_BOLD}Settings${C_RESET}"
    say "  1) Xcode DeviceSupport versions to keep   = $KEEP_DEVICE_SUPPORT"
    say "  2) Simulator staleness threshold (days)    = $SIM_STALE_DAYS"
    say "  3) Android AVD staleness threshold (days)  = $ANDROID_STALE_DAYS"
    say "  4) Temp file age threshold (days)          = $TMP_STALE_DAYS"
    say "  5) Toolchain versions to keep              = $KEEP_TOOLCHAINS"
    say "  9) Run logs to keep                        = $KEEP_LOGS"
    say "  6) Aggressive mode                         = $( [ "$AGGRESSIVE" = 1 ] && echo on || echo off )"
    say "  7) Verbose output                          = $( [ "$VERBOSE" = 1 ] && echo on || echo off )"
    say "  8) Assume yes (skip confirmation prompts)  = $( [ "$ASSUME_YES" = 1 ] && echo on || echo off )"
    say "  b) Back"
    read -r -p "> " sel </dev/tty
    case "$sel" in
      1) read -r -p "New value [$KEEP_DEVICE_SUPPORT]: " v </dev/tty; [ -n "$v" ] && KEEP_DEVICE_SUPPORT="$v" ;;
      2) read -r -p "New value [$SIM_STALE_DAYS]: " v </dev/tty; [ -n "$v" ] && SIM_STALE_DAYS="$v" ;;
      3) read -r -p "New value [$ANDROID_STALE_DAYS]: " v </dev/tty; [ -n "$v" ] && ANDROID_STALE_DAYS="$v" ;;
      4) read -r -p "New value [$TMP_STALE_DAYS]: " v </dev/tty; [ -n "$v" ] && TMP_STALE_DAYS="$v" ;;
      5) read -r -p "New value [$KEEP_TOOLCHAINS]: " v </dev/tty; [ -n "$v" ] && KEEP_TOOLCHAINS="$v" ;;
      9) read -r -p "New value [$KEEP_LOGS]: " v </dev/tty; [ -n "$v" ] && KEEP_LOGS="$v" ;;
      6) [ "$AGGRESSIVE" = 1 ] && AGGRESSIVE=0 || AGGRESSIVE=1 ;;
      7) [ "$VERBOSE" = 1 ] && VERBOSE=0 || VERBOSE=1 ;;
      8) [ "$ASSUME_YES" = 1 ] && ASSUME_YES=0 || ASSUME_YES=1 ;;
      b|B) return ;;
      *) warn "unrecognized option: $sel" ;;
    esac
  done
}

interactive_main() {
  log_init
  build_category_state
  local last=0
  say "${C_BOLD}CleanMyMac — interactive mode${C_RESET}  (config: $CONFIG_FILE)"
  if tui_available; then
    say "${C_DIM}Arrow keys to move, enter to select. Number keys still work.${C_RESET}"
  fi
  while true; do
    MENU_LABELS=(
      "Quick scan    — code-default safe categories, changes nothing"
      "Quick clean   — code-default safe categories"
      "Choose categories & run"
      "Disk report   — where your space actually went"
      "Manage whitelist"
      "Settings"
      "View category list (current selection)"
      "View most recent log"
      "Save current selection + settings as default"
      "Quit"
    )
    if ! menu_select "Main menu" "$last"; then
      exit 0
    fi
    last="$MENU_CHOICE"
    case "$MENU_CHOICE" in
      0)
        MODE=scan
        reset_all_include_vars
        ONLY_LIST="$(compute_code_default_ids)"
        SKIP_LIST=""
        run_selected_categories
        interactive_pause
        ;;
      1)
        MODE=clean
        reset_all_include_vars
        ONLY_LIST="$(compute_code_default_ids)"
        SKIP_LIST=""
        run_selected_categories
        interactive_pause
        ;;
      2) interactive_choose_categories ;;
      3) log_init; report_system_data; report_top_offenders; interactive_pause ;;
      4) interactive_whitelist ;;
      5) interactive_settings ;;
      6) print_live_category_state; interactive_pause ;;
      7) view_last_log; interactive_pause ;;
      8) save_config; interactive_pause ;;
      9) exit 0 ;;
    esac
  done
}

# Runs exactly the categories currently selected via ONLY_LIST/SKIP_LIST.
# Safe to call more than once in a process (interactive mode does) — resets
# its own run-scoped accumulators and log file each time. Returns 1 if the
# user aborted at the confirmation prompt, so a caller can return to a menu
# instead of exiting the whole process.
run_selected_categories() {
  log_init
  TOTAL_BEFORE_KB=0
  TOTAL_RECLAIMED_KB=0
  RAN_ANY=0

  say "${C_BOLD}clean.sh${C_RESET} — mode: ${C_BOLD}$MODE${C_RESET}  $( [ "$AGGRESSIVE" = 1 ] && echo '(aggressive)' )"
  say "Log: $LOG_FILE"
  if [ "${#WHITELIST[@]}" -gt 0 ]; then
    say "Whitelisted paths:"
    local w
    for w in "${WHITELIST[@]}"; do
      [ -n "$w" ] && say "  - $w"
    done
  fi

  warn_if_no_full_disk_access

  local free_before
  free_before="$(df -H / | awk 'NR==2{print $4}')"

  if [ "$MODE" = "clean" ] && [ "$ASSUME_YES" != 1 ]; then
    if ! confirm "About to clean categories: $ONLY_LIST — proceed?"; then
      warn "aborted by user"
      return 1
    fi
  fi

  local id
  for id in $ALL_CATEGORY_IDS; do
    run_category "$id"
  done

  if [ -n "$REMOVE_ORPHANS_FILE" ]; then
    process_orphans_review_file
  fi

  section "Summary"
  if [ "$MODE" = "scan" ]; then
    say "Estimated reclaimable space: ${C_BOLD}$(human_kb "$TOTAL_BEFORE_KB")${C_RESET}"
    say "Run again with ${C_BOLD}--clean${C_RESET} to actually remove these files."
  else
    say "Space freed this run: ${C_BOLD}$(human_kb "$TOTAL_RECLAIMED_KB")${C_RESET}"
    local free_after
    free_after="$(df -H / | awk 'NR==2{print $4}')"
    say "Free space before: $free_before  ->  after: $free_after"
  fi
  # Anything a cleaner must not delete for you still has to be findable.
  if [ "$REPORT_ONLY" = 1 ] || [ "$MODE" = "scan" ]; then
    local purgeable
    purgeable="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
    say ""
    info "Tip: run ${C_BOLD}./clean.sh --report${C_RESET} for a full breakdown of where the"
    info "rest of your disk went (VM disks, SDKs, model weights, node_modules)."
  fi
  if [ "$NO_LOG" = 1 ]; then
    say "Log: not kept (--no-log)"
  else
    say "Full log: $LOG_FILE  (keeping the last $KEEP_LOGS runs)"
  fi
  return 0
}

main() {
  if [ "$REPORT_ONLY" = 1 ]; then
    log_init
    say "${C_BOLD}clean.sh${C_RESET} — disk report"
    say "Log: $LOG_FILE"
    report_system_data
    report_top_offenders
    say ""
    say "Full log: $LOG_FILE"
    return 0
  fi
  run_selected_categories
}

if [ "$INTERACTIVE" = 1 ]; then
  interactive_main
else
  main
fi
