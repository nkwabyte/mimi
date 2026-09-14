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

SIM_STALE_DAYS=60
ANDROID_STALE_DAYS=60

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

log_init() {
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"
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

usage() {
  cat <<'EOF'
clean.sh — macOS junk cleaner (Xcode/simulator aware)

USAGE:
  ./clean.sh [--scan | --clean] [options]

MODES:
  --scan                 Report reclaimable space only. Deletes nothing. (default)
  --clean                Actually remove junk. Prompts for confirmation unless --yes.

COMMON OPTIONS:
  -y, --yes              Do not prompt for confirmation before deleting.
  -v, --verbose           Print extra detail (paths being inspected/removed).
  --only <list>           Comma-separated category ids to run (see --list).
  --skip <list>           Comma-separated category ids to exclude.
  --list                  Print all category ids, descriptions, risk level, then exit.
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

  -h, --help              Show this help.

EXAMPLES:
  ./clean.sh                                   # scan only, see what would be freed
  ./clean.sh --clean                            # clean safe categories, ask to confirm
  ./clean.sh --clean --yes                      # clean safe categories, no prompts
  ./clean.sh --clean --whitelist-preset xcode-simulator
  ./clean.sh --clean --only caches,logs,dsstore --yes
  ./clean.sh --clean --include-trash --include-mail --yes
EOF
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
  du -sk "$p" 2>/dev/null | awk '{print $1}' | tail -1
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
    *) echo "" ;;
  esac
}

ALL_CATEGORY_IDS="caches logs diagnostics dsstore quicklook xcode-derived xcode-archives sim-caches sim-unavailable device-support homebrew npm yarn pnpm cocoapods gradle pip timemachine docker docker-cache mail trash orphans whatsapp sim-stale claude-cache android"

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
  local sub
  for sub in "$base"/*; do
    [ -e "$sub" ] || continue
    clear_dir_contents "$sub"
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
    clear_dir_contents "$sub"
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

  if [ "$MODE" = "scan" ]; then
    info "would run: brew cleanup -s --prune=all  (cache: $(human_kb "$before") at $cache_dir)"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    return
  fi

  if is_whitelisted "$cache_dir"; then
    info "whitelisted, skipped: $cache_dir"
    return
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
  local cache_dir
  cache_dir="$(yarn cache dir 2>/dev/null)"
  [ -d "$cache_dir" ] || { info "no yarn cache dir found"; return; }
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
  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon not running, skipped"
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
  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon not running, skipped"
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
    docker system df 2>/dev/null | while IFS= read -r line; do info "  $line"; done
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
    *) warn "unknown category: $id" ;;
  esac
}

# ---------------------------------------------------------------------------
# Whitelist presets
# ---------------------------------------------------------------------------

apply_whitelist_preset() {
  case "$1" in
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
      err "unknown whitelist preset: $1 (known: xcode-simulator, xcode-derived, node)"
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --scan) MODE="scan"; shift ;;
    --clean) MODE="clean"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --keep-device-support)
      KEEP_DEVICE_SUPPORT="$2"; shift 2 ;;
    --keep-device-support=*)
      KEEP_DEVICE_SUPPORT="${1#*=}"; shift ;;
    --only)
      ONLY_LIST="$2"; shift 2 ;;
    --only=*)
      ONLY_LIST="${1#*=}"; shift ;;
    --skip)
      SKIP_LIST="$2"; shift 2 ;;
    --skip=*)
      SKIP_LIST="${1#*=}"; shift ;;
    --whitelist)
      IFS=',' read -r -a _wl <<< "$2"; WHITELIST+=("${_wl[@]}"); shift 2 ;;
    --whitelist=*)
      IFS=',' read -r -a _wl <<< "${1#*=}"; WHITELIST+=("${_wl[@]}"); shift ;;
    --whitelist-preset)
      apply_whitelist_preset "$2"; shift 2 ;;
    --whitelist-preset=*)
      apply_whitelist_preset "${1#*=}"; shift ;;
    --include-trash) INCLUDE_TRASH=1; shift ;;
    --include-mail) INCLUDE_MAIL=1; shift ;;
    --include-docker) INCLUDE_DOCKER=1; shift ;;
    --include-docker-cache) INCLUDE_DOCKER_CACHE=1; shift ;;
    --include-orphans) INCLUDE_ORPHANS=1; shift ;;
    --include-whatsapp) INCLUDE_WHATSAPP=1; shift ;;
    --include-sim-stale) INCLUDE_SIM_STALE=1; shift ;;
    --sim-stale-days)
      SIM_STALE_DAYS="$2"; shift 2 ;;
    --sim-stale-days=*)
      SIM_STALE_DAYS="${1#*=}"; shift ;;
    --include-claude-cache) INCLUDE_CLAUDE_CACHE=1; shift ;;
    --include-android) INCLUDE_ANDROID=1; shift ;;
    --android-stale-days)
      ANDROID_STALE_DAYS="$2"; shift 2 ;;
    --android-stale-days=*)
      ANDROID_STALE_DAYS="${1#*=}"; shift ;;
    --remove-orphans-from)
      REMOVE_ORPHANS_FILE="$2"; shift 2 ;;
    --remove-orphans-from=*)
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

# Apply default-on/off filtering only when --only wasn't explicitly given.
if [ -z "$ONLY_LIST" ]; then
  default_ids=""
  for _id in $ALL_CATEGORY_IDS; do
    _info_line="$(category_info "$_id")"
    _default="$(echo "$_info_line" | cut -d'|' -f2)"
    [ "$_default" = "1" ] && default_ids="$default_ids,$_id"
  done
  ONLY_LIST="${default_ids#,}"
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log_init

  say "${C_BOLD}clean.sh${C_RESET} — mode: ${C_BOLD}$MODE${C_RESET}  $( [ "$AGGRESSIVE" = 1 ] && echo '(aggressive)' )"
  say "Log: $LOG_FILE"
  if [ "${#WHITELIST[@]}" -gt 0 ]; then
    say "Whitelisted paths:"
    local w
    for w in "${WHITELIST[@]}"; do
      [ -n "$w" ] && say "  - $w"
    done
  fi

  local free_before
  free_before="$(df -H / | awk 'NR==2{print $4}')"

  if [ "$MODE" = "clean" ] && [ "$ASSUME_YES" != 1 ]; then
    if ! confirm "About to clean categories: $ONLY_LIST — proceed?"; then
      warn "aborted by user"
      exit 0
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
  say "Full log: $LOG_FILE"
}

main
