#!/usr/bin/env bash
#
# lib/apps/inventory.sh — Installed application inventory, metadata, signing, and provenance.
# Phase 3: P3-T01, P3-T02, P3-T03.
#
# Everything in this module is read-only. Nothing here creates, moves, or
# deletes a file; the only external commands are metadata readers (plutil,
# defaults, mdls, mdfind, codesign, file, pkgutil).
#
# Compatible with Bash 3.2+ (no associative arrays).
#

# Standard search roots for applications. Overridable in tests through
# MIMI_APP_SEARCH_ROOTS (colon-separated) and on the command line through the
# repeatable --app-root option. Either one makes the roots "explicit": the
# inventory then walks exactly those locations and does not consult Spotlight,
# whose results cannot be constrained to a caller-supplied root.
APP_ROOTS_EXPLICIT=0
if [ -n "${MIMI_APP_SEARCH_ROOTS:-}" ]; then
  IFS=':' read -r -a APP_SEARCH_ROOTS <<< "$MIMI_APP_SEARCH_ROOTS"
  APP_ROOTS_EXPLICIT=1
elif [ -z "${APP_SEARCH_ROOTS+x}" ]; then
  if [ -n "${ORPHAN_APP_WALK_ROOTS+x}" ]; then
    APP_SEARCH_ROOTS=("${ORPHAN_APP_WALK_ROOTS[@]}")
  else
    APP_SEARCH_ROOTS=(
      "/Applications"
      "/Applications/Utilities"
      "$HOME_DIR/Applications"
      "/System/Applications"
      "/System/Applications/Utilities"
    )
  fi
fi

# Add a caller-supplied application root (--app-root). The first explicit root
# replaces the defaults; later ones are appended, so the option is repeatable.
app_add_search_root() {
  local root="$1"
  [ -n "$root" ] || return 1
  if [ "$APP_ROOTS_EXPLICIT" -ne 1 ]; then
    APP_SEARCH_ROOTS=()
    APP_ROOTS_EXPLICIT=1
  fi
  APP_SEARCH_ROOTS+=("$root")
}

# Valid values for `apps list --source`.
APP_SOURCE_VALUES="all app cask mas pkg system"

is_valid_app_source() {
  case " $APP_SOURCE_VALUES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Inventory storage arrays (parallel indexed arrays for Bash 3.2)
APP_INV_PATHS=()
APP_INV_NAMES=()
APP_INV_IDS=()
APP_INV_VERSIONS=()
APP_INV_SOURCES=()
APP_INV_SYSTEM=()
APP_INV_SIZES=()
APP_INV_EXECUTABLES=()
APP_INV_IDENTITIES=()
APP_INV_CASK_TOKENS=()
APP_INV_ELIGIBLE=()
APP_INV_COUNT=0
APP_INV_SCANNED=0

# Completeness auditing. An inventory is "complete" only when every root was
# readable and, where Spotlight was consulted, it agreed with the direct walk.
APP_INV_SPOTLIGHT="skipped"      # used | unavailable | skipped
APP_INV_SPOTLIGHT_COUNT=0        # Spotlight hits that fell inside a search root
APP_INV_WALKED_COUNT=0           # bundles seen by the directory walk
APP_INV_WALK_ONLY_COUNT=0        # bundles the walk found that Spotlight missed
APP_INV_UNAVAILABLE_ROOTS=()     # roots that are missing, unmounted, or unreadable
APP_INV_NOTES=()
APP_INV_COMPLETE=1
APP_INV_NOTE=""                  # APP_INV_NOTES joined with "; " (human output)

# ---------------------------------------------------------------------------
# Plist field extraction helper
# ---------------------------------------------------------------------------

plist_get_value() {
  local plist_file="$1" key="$2" val=""
  [ -f "$plist_file" ] || return 1

  # 1. Try plutil (standard on macOS). Reads XML, binary, and JSON plists.
  if command -v plutil > /dev/null 2>&1; then
    val="$(plutil -extract "$key" raw -o - "$plist_file" 2>/dev/null || true)"
    if [ -n "$val" ] && [ "$val" != "(null)" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi

  # 2. Try XML plist fallback with awk
  val="$(awk -v k="$key" '
    $0 ~ "<key>" k "</key>" { found=1; next }
    found && /<string>/ {
      sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit
    }
    found && /<true\/>/ { print "true"; exit }
    found && /<false\/>/ { print "false"; exit }
    found && /<integer>/ {
      sub(/.*<integer>/, ""); sub(/<\/integer>.*/, ""); print; exit
    }
    found && /<\/dict>/ { exit }
  ' "$plist_file" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi

  # 3. Try defaults read (if path has no .plist or defaults can resolve it)
  if command -v defaults > /dev/null 2>&1; then
    local base="${plist_file%.plist}"
    val="$(defaults read "$base" "$key" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi

  return 1
}

# Read several top-level string keys from a plist in one pass. Prints
# "Key=value" lines for the keys that are present. One plutil conversion per
# file instead of one per key keeps a full inventory fast.
plist_read_keys() {
  local plist_file="$1"
  shift
  [ -f "$plist_file" ] || return 1
  {
    if command -v plutil > /dev/null 2>&1; then
      plutil -convert xml1 -o - "$plist_file" 2>/dev/null || cat "$plist_file" 2>/dev/null
    else
      cat "$plist_file" 2>/dev/null
    fi
  } | awk -v keys="$*" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
    {
      line = $0
      if (pending != "") {
        if (line ~ /<string>/) {
          sub(/.*<string>/, "", line); sub(/<\/string>.*/, "", line)
          gsub(/&lt;/, "<", line); gsub(/&gt;/, ">", line); gsub(/&amp;/, "\\&", line)
          print pending "=" line
        }
        pending = ""
      }
      if ($0 ~ /<key>/ && depth == 1) {
        key = $0; sub(/.*<key>/, "", key); sub(/<\/key>.*/, "", key)
        if (key in want) pending = key
      }
      if ($0 ~ /<dict>/) depth++
      if ($0 ~ /<\/dict>/) depth--
    }
  '
}

# Value of KEY from the output of plist_read_keys (passed as $2).
_plist_kv() {
  local key="$1" kv="$2" line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <<< "$kv"
  return 1
}

# ---------------------------------------------------------------------------
# Application provenance detection (P3-T03)
# ---------------------------------------------------------------------------

# Caskroom directories to consult. MIMI_CASKROOM_DIRS (colon-separated)
# replaces the defaults entirely, so a test can never see the host's casks.
app_caskroom_dirs() {
  if [ -n "${MIMI_CASKROOM_DIRS+x}" ]; then
    local -a dirs=()
    IFS=':' read -r -a dirs <<< "$MIMI_CASKROOM_DIRS"
    local d
    for d in "${dirs[@]:-}"; do
      [ -n "$d" ] && printf '%s\n' "$d"
    done
    return 0
  fi
  [ -n "${HOMEBREW_PREFIX:-}" ] && printf '%s\n' "$HOMEBREW_PREFIX/Caskroom"
  printf '%s\n' "/opt/homebrew/Caskroom" "/usr/local/Caskroom"
}

# Detect the installed cask that owns an app bundle.
# Sets APP_CASK_TOKEN and APP_CASK_METHOD:
#   metadata — the cask's recorded definition (.metadata/**/Casks/<token>.json
#              or .rb) declares an `app` artifact with this bundle's file name.
#              This is authoritative.
#   name     — no definition names the bundle, but an installed cask token
#              normalises to the bundle's name. Reported, but weaker.
# Returns 1 when no installed cask matches.
APP_CASK_TOKEN=""
APP_CASK_METHOD=""

# Built once per process: every installed cask token, and every "<Name>.app"
# string its recorded definition mentions. One grep per cask instead of one
# per (app, cask) pair keeps a full inventory fast.
APP_CASK_INDEX_BUILT=0
APP_CASK_TOKENS=()       # installed tokens
APP_CASK_TOKENS_NORM=()  # normalize_token of each token
APP_CASK_ARTIFACTS=()    # "token|Name.app" for each declared app artifact

_app_cask_index_build() {
  [ "$APP_CASK_INDEX_BUILT" -eq 1 ] && return 0
  APP_CASK_INDEX_BUILT=1
  APP_CASK_TOKENS=()
  APP_CASK_TOKENS_NORM=()
  APP_CASK_ARTIFACTS=()

  local cr entry token def art
  while IFS= read -r cr; do
    [ -n "$cr" ] && [ -d "$cr" ] || continue
    for entry in "$cr"/*; do
      [ -d "$entry" ] || continue
      token="$(basename "$entry")"
      APP_CASK_TOKENS+=("$token")
      APP_CASK_TOKENS_NORM+=("$(normalize_token "$token")")
      for def in "$entry"/.metadata/*/*/Casks/*.json "$entry"/.metadata/*/*/Casks/*.rb; do
        [ -f "$def" ] || continue
        while IFS= read -r art; do
          art="${art#\"}"
          art="${art%\"}"
          art="${art##*/}"
          [ -n "$art" ] && APP_CASK_ARTIFACTS+=("$token|$art")
        done < <(grep -o '"[^"]*\.app"' "$def" 2>/dev/null || true)
      done
    done
  done < <(app_caskroom_dirs)
}

app_detect_cask() {
  local app_path="$1"
  APP_CASK_TOKEN=""
  APP_CASK_METHOD=""
  _app_cask_index_build
  [ "${#APP_CASK_TOKENS[@]}" -gt 0 ] || return 1

  local base_file app_norm
  base_file="$(basename "$app_path")"
  app_norm="$(normalize_token "${base_file%.app}")"

  # Pass 1: authoritative — a cask definition declares this .app artifact.
  local a
  for a in "${APP_CASK_ARTIFACTS[@]:-}"; do
    [ -n "$a" ] || continue
    if [ "${a#*|}" = "$base_file" ]; then
      APP_CASK_TOKEN="${a%%|*}"
      APP_CASK_METHOD="metadata"
      return 0
    fi
  done

  # Pass 2: installed token that normalises to the bundle name.
  local i
  for ((i = 0; i < ${#APP_CASK_TOKENS[@]}; i++)); do
    if [ "${APP_CASK_TOKENS_NORM[$i]}" = "$app_norm" ]; then
      APP_CASK_TOKEN="${APP_CASK_TOKENS[$i]}"
      APP_CASK_METHOD="name"
      return 0
    fi
  done
  return 1
}

# Print the cask token for an app bundle (subshell-friendly wrapper).
app_detect_cask_token() {
  app_detect_cask "$1" || return 1
  printf '%s\n' "$APP_CASK_TOKEN"
}

# Installer package receipts that reference an app bundle. Report-only: the
# receipts are never forgotten (`pkgutil --forget`) or modified.
# Sets APP_PKG_IDS.
APP_PKG_IDS=()

app_detect_pkg_receipts() {
  local app_path="$1" bundle_id="${2-}"
  APP_PKG_IDS=()

  local receipts_dir="${MIMI_RECEIPTS_DIR:-/var/db/receipts}"

  _pkg_add() {
    local id="$1" e
    [ -n "$id" ] || return 0
    for e in "${APP_PKG_IDS[@]:-}"; do
      [ "$e" = "$id" ] && return 0
    done
    APP_PKG_IDS+=("$id")
  }

  # 1. Path-based correlation: the receipt database records which package
  #    installed this path.
  if command -v pkgutil > /dev/null 2>&1; then
    local line
    while IFS= read -r line; do
      case "$line" in
        pkgid:*) _pkg_add "$(printf '%s' "${line#pkgid:}" | sed 's/^[[:space:]]*//')" ;;
      esac
    done < <(pkgutil --file-info "$app_path" 2>/dev/null || true)
  fi

  # 2. A receipt named after the bundle identifier.
  if [ -n "$bundle_id" ] && [ -d "$receipts_dir" ]; then
    if [ -f "$receipts_dir/$bundle_id.plist" ] || [ -f "$receipts_dir/$bundle_id.bom" ]; then
      _pkg_add "$bundle_id"
    fi
  fi

  [ "${#APP_PKG_IDS[@]}" -gt 0 ]
}

# Primary provenance, by precedence: system > mas > cask > pkg > app.
# Kept as a subshell-friendly function for callers that only need the label.
app_detect_provenance() {
  local app_path="$1" bundle_id="${2-}" is_system="${3:-0}"

  if [ "$is_system" -eq 1 ]; then
    printf 'system\n'
    return 0
  fi
  if [ -f "$app_path/Contents/_MASReceipt/receipt" ]; then
    printf 'mas\n'
    return 0
  fi
  if app_detect_cask "$app_path"; then
    printf 'cask\n'
    return 0
  fi
  if app_detect_pkg_receipts "$app_path" "$bundle_id"; then
    printf 'pkg\n'
    return 0
  fi
  printf 'app\n'
}

# ---------------------------------------------------------------------------
# Code signing and Team ID fingerprint (P3-T02)
# ---------------------------------------------------------------------------

SIGNING_IDENTIFIER=""
SIGNING_TEAM_ID=""
SIGNING_AUTHORITY=""
SIGNING_STATUS="unsigned"   # unsigned | adhoc | signed

app_detect_signing() {
  local app_path="$1"
  SIGNING_IDENTIFIER=""
  SIGNING_TEAM_ID=""
  SIGNING_AUTHORITY=""
  SIGNING_STATUS="unsigned"

  command -v codesign > /dev/null 2>&1 || return 0

  local cs_out line
  cs_out="$(codesign -d --verbose=2 "$app_path" 2>&1 || true)"
  while IFS= read -r line; do
    case "$line" in
      Identifier=*)
        SIGNING_IDENTIFIER="${line#Identifier=}"
        ;;
      TeamIdentifier=*)
        SIGNING_TEAM_ID="${line#TeamIdentifier=}"
        [ "$SIGNING_TEAM_ID" = "not set" ] && SIGNING_TEAM_ID=""
        ;;
      Authority=*)
        if [ -z "$SIGNING_AUTHORITY" ]; then
          SIGNING_AUTHORITY="${line#Authority=}"
        fi
        ;;
      Signature=adhoc)
        SIGNING_STATUS="adhoc"
        ;;
    esac
  done <<< "$cs_out"

  if [ "$SIGNING_STATUS" != "adhoc" ] && [ -n "$SIGNING_IDENTIFIER" ]; then
    SIGNING_STATUS="signed"
  fi
}

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------

app_detect_arch() {
  local app_path="$1" executable="$2"
  local bin_path="$app_path/Contents/MacOS/$executable"
  [ -f "$bin_path" ] || { printf 'unknown\n'; return 0; }

  if command -v file > /dev/null 2>&1; then
    local f_out
    f_out="$(file "$bin_path" 2>/dev/null || true)"
    if echo "$f_out" | grep -q "arm64" && echo "$f_out" | grep -q "x86_64"; then
      printf 'universal (arm64, x86_64)\n'
    elif echo "$f_out" | grep -q "arm64"; then
      printf 'arm64 (Apple Silicon)\n'
    elif echo "$f_out" | grep -q "x86_64"; then
      printf 'x86_64 (Intel 64-bit)\n'
    elif echo "$f_out" | grep -q "Mach-O"; then
      printf 'Mach-O binary\n'
    else
      printf 'script/executable\n'
    fi
  else
    printf 'unknown\n'
  fi
}

# ---------------------------------------------------------------------------
# Vendor uninstaller detection (report-only fact; never executed)
# ---------------------------------------------------------------------------

# True for names that look like an uninstaller program rather than, say, an
# "uninstall.png" icon or an "UninstallHelp.html" page.
_is_uninstaller_name() {
  local base="$1"
  case "$base" in
    *.png|*.icns|*.tiff|*.jpg|*.pdf|*.html|*.htm|*.rtf|*.txt|*.strings|*.nib|*.plist|*.lproj)
      return 1 ;;
    *[Uu]ninstall*) return 0 ;;
  esac
  return 1
}

app_detect_uninstaller() {
  local app_path="$1"
  local parent_dir cand base
  parent_dir="$(dirname "$app_path")"

  # Inside the bundle: Resources, MacOS, SharedSupport
  for cand in "$app_path/Contents/Resources/"*[Uu]ninstall* \
              "$app_path/Contents/MacOS/"*[Uu]ninstall* \
              "$app_path/Contents/SharedSupport/"*[Uu]ninstall*; do
    [ -e "$cand" ] || continue
    base="$(basename "$cand")"
    if _is_uninstaller_name "$base"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done

  # A sibling in a vendor folder (e.g. /Applications/<Vendor>/Uninstall <App>.app).
  # Never at the top of a search root: /Applications is shared by everything.
  local r canon_r at_root=0
  for r in "${APP_SEARCH_ROOTS[@]}"; do
    canon_r="$(path_canonicalize "$r" 2>/dev/null || printf '%s' "$r")"
    if [ "$parent_dir" = "$canon_r" ] || [ "$parent_dir" = "$r" ]; then
      at_root=1
      break
    fi
  done
  if [ "$at_root" -eq 0 ] && [ "$parent_dir" != "/Applications" ] && [ "$parent_dir" != "$HOME_DIR/Applications" ]; then
    for cand in "$parent_dir/"*[Uu]ninstall*.app "$parent_dir/"*[Uu]ninstall*.pkg "$parent_dir/"*[Uu]ninstall*.command; do
      if [ -e "$cand" ] && [ "$cand" != "$app_path" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
    done
  fi

  printf '\n'
  return 0
}

# ---------------------------------------------------------------------------
# Bundle Inspection (P3-T02)
# ---------------------------------------------------------------------------
#
# Depth controls how much work app_inspect_bundle does, because the inventory
# runs it for every installed app:
#   resolve — identity only (Info.plist, provenance by receipt/cask). No du,
#             codesign, pkgutil, or nested-component walk. Used for target
#             resolution and sibling indexing.
#   list    — adds size, signing, and receipts (what `apps list` shows).
#   full    — everything, including architecture, nested components, and the
#             vendor uninstaller (what `app inspect` shows).

APP_INFO_NAME=""
APP_INFO_BUNDLE_ID=""
APP_INFO_VERSION=""
APP_INFO_EXECUTABLE=""
APP_INFO_IS_SYSTEM=0
APP_INFO_SYSTEM_REASON=""
APP_INFO_PROVENANCE="app"
APP_INFO_PROVENANCE_FACTS=()
APP_INFO_SIZE_KB=0
APP_INFO_INPUT_PATH=""
APP_INFO_CANONICAL_PATH=""
APP_INFO_IDENTITY=""
APP_INFO_HELPERS=()
APP_INFO_XPC=()
APP_INFO_EXTENSIONS=()
APP_INFO_LOGIN_ITEMS=()
APP_INFO_LAUNCHD=()
APP_INFO_UNINSTALLER=""
APP_INFO_CASK_TOKEN=""
APP_INFO_CASK_METHOD=""
APP_INFO_PKG_IDS=()
APP_INFO_ARCH="unknown"
APP_INFO_ELIGIBLE=1
APP_INFO_INELIGIBLE_REASON=""
APP_INFO_WARNINGS=()

_app_info_reset() {
  APP_INFO_NAME=""
  APP_INFO_BUNDLE_ID=""
  APP_INFO_VERSION=""
  APP_INFO_EXECUTABLE=""
  APP_INFO_IS_SYSTEM=0
  APP_INFO_SYSTEM_REASON=""
  APP_INFO_PROVENANCE="app"
  APP_INFO_PROVENANCE_FACTS=()
  APP_INFO_SIZE_KB=0
  APP_INFO_INPUT_PATH=""
  APP_INFO_CANONICAL_PATH=""
  APP_INFO_IDENTITY=""
  APP_INFO_HELPERS=()
  APP_INFO_XPC=()
  APP_INFO_EXTENSIONS=()
  APP_INFO_LOGIN_ITEMS=()
  APP_INFO_LAUNCHD=()
  APP_INFO_UNINSTALLER=""
  APP_INFO_CASK_TOKEN=""
  APP_INFO_CASK_METHOD=""
  APP_INFO_PKG_IDS=()
  APP_INFO_ARCH="unknown"
  APP_INFO_ELIGIBLE=1
  APP_INFO_INELIGIBLE_REASON=""
  APP_INFO_WARNINGS=()
  SIGNING_IDENTIFIER=""
  SIGNING_TEAM_ID=""
  SIGNING_AUTHORITY=""
  SIGNING_STATUS="unsigned"
}

# Record why a bundle may not be selected for any future mutation. The first
# reason wins; later ones are kept as warnings so nothing is lost.
_app_mark_ineligible() {
  if [ "$APP_INFO_ELIGIBLE" -eq 1 ]; then
    APP_INFO_ELIGIBLE=0
    APP_INFO_INELIGIBLE_REASON="$1"
  else
    APP_INFO_WARNINGS+=("$1")
  fi
}

app_inspect_bundle() {
  local app_path="$1" depth="${2:-full}"
  _app_info_reset

  [ -e "$app_path" ] || return 1

  APP_INFO_INPUT_PATH="$app_path"
  APP_INFO_CANONICAL_PATH="$(path_canonicalize "$app_path")"
  APP_INFO_IDENTITY="$(path_identity "$APP_INFO_CANONICAL_PATH" 2>/dev/null || true)"

  if [ ! -d "$APP_INFO_CANONICAL_PATH" ]; then
    _app_mark_ineligible "not a bundle directory"
  fi

  local info_plist="$APP_INFO_CANONICAL_PATH/Contents/Info.plist"
  local have_plist=1
  [ -f "$info_plist" ] || have_plist=0

  local kv=""
  kv="$(plist_read_keys "$info_plist" CFBundleDisplayName CFBundleName CFBundleIdentifier \
    CFBundleShortVersionString CFBundleVersion CFBundleExecutable 2>/dev/null || true)"

  # Name resolution: CFBundleDisplayName -> CFBundleName -> filename
  local name=""
  name="$(_plist_kv CFBundleDisplayName "$kv" || true)"
  [ -z "$name" ] && name="$(_plist_kv CFBundleName "$kv" || true)"
  [ -z "$name" ] && name="$(basename "$APP_INFO_CANONICAL_PATH" .app)"
  APP_INFO_NAME="$name"

  # Bundle Identifier
  local bid=""
  bid="$(_plist_kv CFBundleIdentifier "$kv" || true)"
  if [ -z "$bid" ] && command -v mdls > /dev/null 2>&1; then
    bid="$(mdls -name kMDItemCFBundleIdentifier -raw "$APP_INFO_CANONICAL_PATH" 2>/dev/null || true)"
    [ "$bid" = "(null)" ] && bid=""
  fi
  # Fallback to test mock index if present
  if [ -z "$bid" ] && [ -n "${MOCK_APP_INDEX:-}" ] && [ -f "${MOCK_APP_INDEX}" ]; then
    bid="$(awk -F'|' -v a="$APP_INFO_CANONICAL_PATH" '$1 == a { print $2; exit }' "$MOCK_APP_INDEX")"
  fi
  APP_INFO_BUNDLE_ID="$bid"

  # Version
  local ver=""
  ver="$(_plist_kv CFBundleShortVersionString "$kv" || true)"
  [ -z "$ver" ] && ver="$(_plist_kv CFBundleVersion "$kv" || true)"
  [ -z "$ver" ] && ver="unknown"
  APP_INFO_VERSION="$ver"

  # Executable
  local exe=""
  exe="$(_plist_kv CFBundleExecutable "$kv" || true)"
  [ -z "$exe" ] && exe="$name"
  APP_INFO_EXECUTABLE="$exe"

  # System check: path under /System/ or bundle ID com.apple.*
  case "$APP_INFO_CANONICAL_PATH" in
    /System/*)
      APP_INFO_IS_SYSTEM=1
      APP_INFO_SYSTEM_REASON="installed on the sealed system volume"
      ;;
    *)
      if is_apple_identifier "$APP_INFO_BUNDLE_ID"; then
        APP_INFO_IS_SYSTEM=1
        APP_INFO_SYSTEM_REASON="Apple bundle identifier"
      fi
      ;;
  esac

  if [ "$depth" != "resolve" ]; then
    # Signing
    app_detect_signing "$APP_INFO_CANONICAL_PATH"

    # If Authority is Apple's own software signing, it is an Apple app.
    case "$SIGNING_AUTHORITY" in
      *Apple\ System*|*Apple\ Mac\ OS\ Application\ Signing*|Software\ Signing)
        if [ "$APP_INFO_IS_SYSTEM" -eq 0 ]; then
          APP_INFO_IS_SYSTEM=1
          APP_INFO_SYSTEM_REASON="signed by Apple ($SIGNING_AUTHORITY)"
        fi
        ;;
    esac

    # Size
    APP_INFO_SIZE_KB="$(dir_size_kb "$APP_INFO_CANONICAL_PATH")"
    [ -n "$APP_INFO_SIZE_KB" ] || APP_INFO_SIZE_KB=0
  fi

  # Provenance facts. Every applicable fact is recorded; the primary label
  # follows the precedence system > mas > cask > pkg > app.
  local primary="app"
  if [ "$APP_INFO_IS_SYSTEM" -eq 1 ]; then
    primary="system"
    APP_INFO_PROVENANCE_FACTS+=("system: $APP_INFO_SYSTEM_REASON")
  fi
  if [ -f "$APP_INFO_CANONICAL_PATH/Contents/_MASReceipt/receipt" ]; then
    [ "$primary" = "app" ] && primary="mas"
    APP_INFO_PROVENANCE_FACTS+=("mas: Mac App Store receipt present")
  fi
  if app_detect_cask "$APP_INFO_CANONICAL_PATH"; then
    APP_INFO_CASK_TOKEN="$APP_CASK_TOKEN"
    APP_INFO_CASK_METHOD="$APP_CASK_METHOD"
    [ "$primary" = "app" ] && primary="cask"
    if [ "$APP_CASK_METHOD" = "metadata" ]; then
      APP_INFO_PROVENANCE_FACTS+=("cask: $APP_CASK_TOKEN (cask definition declares this app)")
    else
      APP_INFO_PROVENANCE_FACTS+=("cask: $APP_CASK_TOKEN (installed token matches app name)")
    fi
  fi
  local pkg_rc=1
  if [ "$depth" = "resolve" ]; then
    # Receipt-name check only; pkgutil is too slow to run per app here.
    local receipts_dir="${MIMI_RECEIPTS_DIR:-/var/db/receipts}"
    if [ -n "$APP_INFO_BUNDLE_ID" ] && { [ -f "$receipts_dir/$APP_INFO_BUNDLE_ID.plist" ] || [ -f "$receipts_dir/$APP_INFO_BUNDLE_ID.bom" ]; }; then
      APP_PKG_IDS=("$APP_INFO_BUNDLE_ID")
      pkg_rc=0
    fi
  else
    app_detect_pkg_receipts "$APP_INFO_CANONICAL_PATH" "$APP_INFO_BUNDLE_ID" && pkg_rc=0
  fi
  if [ "$pkg_rc" -eq 0 ]; then
    APP_INFO_PKG_IDS=("${APP_PKG_IDS[@]}")
    [ "$primary" = "app" ] && primary="pkg"
    local pid
    for pid in "${APP_INFO_PKG_IDS[@]}"; do
      APP_INFO_PROVENANCE_FACTS+=("pkg: installer receipt $pid (report-only; never forgotten)")
    done
  fi
  APP_INFO_PROVENANCE="$primary"

  # Eligibility: which bundles a later phase could ever select for removal.
  if [ "$APP_INFO_IS_SYSTEM" -eq 1 ]; then
    _app_mark_ineligible "macOS system or Apple application ($APP_INFO_SYSTEM_REASON)"
  fi
  if [ "$have_plist" -eq 0 ]; then
    _app_mark_ineligible "Contents/Info.plist is missing; bundle identity cannot be established"
  fi
  if [ -z "$APP_INFO_BUNDLE_ID" ]; then
    _app_mark_ineligible "no bundle identifier; identity is ambiguous"
  fi
  if [ "$SIGNING_STATUS" = "signed" ] && [ -n "$SIGNING_TEAM_ID" ] && [ -n "$APP_INFO_BUNDLE_ID" ] \
     && [ "$SIGNING_IDENTIFIER" != "$APP_INFO_BUNDLE_ID" ]; then
    _app_mark_ineligible "code signature identifier ($SIGNING_IDENTIFIER) does not match bundle identifier ($APP_INFO_BUNDLE_ID)"
  fi
  if [ "$depth" != "resolve" ]; then
    case "$SIGNING_STATUS" in
      unsigned) APP_INFO_WARNINGS+=("bundle is not code signed; identity rests on Info.plist alone") ;;
      adhoc)    APP_INFO_WARNINGS+=("bundle is ad-hoc signed; no Team ID to corroborate identity") ;;
    esac
  fi
  if [ "$APP_INFO_INPUT_PATH" != "$APP_INFO_CANONICAL_PATH" ] && [ -L "${APP_INFO_INPUT_PATH%/}" ]; then
    APP_INFO_WARNINGS+=("requested path is a symbolic link to $APP_INFO_CANONICAL_PATH")
  fi

  [ "$depth" = "full" ] || return 0

  # Architecture
  APP_INFO_ARCH="$(app_detect_arch "$APP_INFO_CANONICAL_PATH" "$APP_INFO_EXECUTABLE")"

  # Nested helpers (Electron and Chromium helpers live in Frameworks/),
  # XPC services, extensions, login items, and bundled launchd jobs.
  local item c="$APP_INFO_CANONICAL_PATH/Contents"
  for item in "$c/MacOS"/*.app "$c/Helpers"/*.app "$c/Frameworks"/*.app; do
    [ -d "$item" ] && APP_INFO_HELPERS+=("$(basename "$item")")
  done

  for item in "$c/XPCServices"/*.xpc; do
    [ -d "$item" ] && APP_INFO_XPC+=("$(basename "$item")")
  done

  for item in "$c/PlugIns"/* "$c/Extensions"/* "$c/Library/SystemExtensions"/*; do
    [ -d "$item" ] && APP_INFO_EXTENSIONS+=("$(basename "$item")")
  done

  for item in "$c/Library/LoginItems"/*.app; do
    [ -d "$item" ] && APP_INFO_LOGIN_ITEMS+=("$(basename "$item")")
  done

  # SMAppService agents/daemons and SMJobBless privileged helpers.
  for item in "$c/Library/LaunchAgents"/*.plist "$c/Library/LaunchDaemons"/*.plist "$c/Library/LaunchServices"/*; do
    [ -e "$item" ] && APP_INFO_LAUNCHD+=("${item#"$c"/}")
  done

  # Uninstaller
  APP_INFO_UNINSTALLER="$(app_detect_uninstaller "$APP_INFO_CANONICAL_PATH")"
  if [ -n "$APP_INFO_UNINSTALLER" ]; then
    APP_INFO_PROVENANCE_FACTS+=("uninstaller: vendor uninstaller present at $APP_INFO_UNINSTALLER (report-only; never run)")
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Inventory Scanner (P3-T01)
# ---------------------------------------------------------------------------

# True when a directory is a place an app bundle can be read from. A root on
# an unmounted volume simply does not exist; one without search permission
# exists but cannot be listed. Both make the inventory incomplete.
_app_root_readable() {
  [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ]
}

# True when an app bundle's parent directory is itself a bundle (an app,
# framework, plug-in, or installer .bundle) — an embedded helper, not an
# installed application.
_app_in_bundle_dir() {
  local parent
  parent="$(basename "$(dirname "$1")")"
  case "$parent" in
    *.app|*.bundle|*.framework|*.plugin|*.appex|*.xpc) return 0 ;;
  esac
  case "$1" in
    *.app/*) return 0 ;;
  esac
  return 1
}

inventory_scan_apps() {
  local depth="${1:-list}"

  APP_INV_PATHS=()
  APP_INV_NAMES=()
  APP_INV_IDS=()
  APP_INV_VERSIONS=()
  APP_INV_SOURCES=()
  APP_INV_SYSTEM=()
  APP_INV_SIZES=()
  APP_INV_EXECUTABLES=()
  APP_INV_IDENTITIES=()
  APP_INV_CASK_TOKENS=()
  APP_INV_ELIGIBLE=()
  APP_INV_COUNT=0

  APP_INV_SPOTLIGHT="skipped"
  APP_INV_SPOTLIGHT_COUNT=0
  APP_INV_WALKED_COUNT=0
  APP_INV_WALK_ONLY_COUNT=0
  APP_INV_UNAVAILABLE_ROOTS=()
  APP_INV_NOTES=()
  APP_INV_COMPLETE=1
  APP_INV_NOTE=""

  local -a visited_paths=()
  local -a canon_roots=()
  local r c
  for r in "${APP_SEARCH_ROOTS[@]}"; do
    [ -n "$r" ] || continue
    if _app_root_readable "$r"; then
      c="$(path_canonicalize "$r" 2>/dev/null || true)"
      [ -n "$c" ] && canon_roots+=("$c")
    else
      APP_INV_UNAVAILABLE_ROOTS+=("$r")
    fi
  done

  _app_is_visited() {
    local target="$1" v
    for v in "${visited_paths[@]:-}"; do
      [ "$v" = "$target" ] && return 0
    done
    return 1
  }

  # Returns 0 when the bundle was newly recorded, 1 when skipped/duplicate.
  _record_app() {
    local p="$1"
    [ -d "$p" ] || return 1
    local canon
    canon="$(path_canonicalize "$p" 2>/dev/null || true)"
    [ -n "$canon" ] || return 1

    # The bundle must be contained within one of the readable search roots.
    local in_roots=0 cr
    for cr in "${canon_roots[@]:-}"; do
      [ -n "$cr" ] || continue
      if path_contains "$cr" "$canon"; then
        in_roots=1
        break
      fi
    done
    [ "$in_roots" -eq 1 ] || return 1

    _app_is_visited "$canon" && return 1
    visited_paths+=("$canon")

    app_inspect_bundle "$canon" "$depth" || return 1
    APP_INV_PATHS+=("$APP_INFO_CANONICAL_PATH")
    APP_INV_NAMES+=("$APP_INFO_NAME")
    APP_INV_IDS+=("$APP_INFO_BUNDLE_ID")
    APP_INV_VERSIONS+=("$APP_INFO_VERSION")
    APP_INV_SOURCES+=("$APP_INFO_PROVENANCE")
    APP_INV_SYSTEM+=("$APP_INFO_IS_SYSTEM")
    APP_INV_SIZES+=("${APP_INFO_SIZE_KB:-0}")
    APP_INV_EXECUTABLES+=("$APP_INFO_EXECUTABLE")
    APP_INV_IDENTITIES+=("$APP_INFO_IDENTITY")
    APP_INV_CASK_TOKENS+=("$APP_INFO_CASK_TOKEN")
    APP_INV_ELIGIBLE+=("$APP_INFO_ELIGIBLE")
    APP_INV_COUNT=$((APP_INV_COUNT + 1))
    return 0
  }

  # 1. Spotlight — only for the default roots. Hits outside every search root
  #    (apps inside other apps, disk images, Downloads) are ignored.
  if [ "$APP_ROOTS_EXPLICIT" -eq 1 ]; then
    APP_INV_SPOTLIGHT="skipped"
  elif command -v mdfind > /dev/null 2>&1; then
    APP_INV_SPOTLIGHT="used"
    local sp_app sp_hit sp_r
    while IFS= read -r sp_app; do
      [ -n "$sp_app" ] || continue
      # Cheap textual filter first: Spotlight paths are already real paths,
      # and most hits (helpers inside bundles, apps in Downloads or inside
      # Xcode) fall outside every root.
      _app_in_bundle_dir "$sp_app" && continue
      sp_hit=0
      for sp_r in "${canon_roots[@]:-}" "${APP_SEARCH_ROOTS[@]}"; do
        [ -n "$sp_r" ] || continue
        case "$sp_app" in "$sp_r"/*) sp_hit=1; break ;; esac
      done
      [ "$sp_hit" -eq 1 ] || continue
      if _record_app "$sp_app"; then
        APP_INV_SPOTLIGHT_COUNT=$((APP_INV_SPOTLIGHT_COUNT + 1))
      fi
    done < <(mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null)
  else
    APP_INV_SPOTLIGHT="unavailable"
  fi

  # 2. Direct walk: <root>/*.app plus one level of vendor folders
  #    (<root>/<Vendor>/*.app). Bundles are never descended into.
  local root app_dir
  for root in "${APP_SEARCH_ROOTS[@]}"; do
    _app_root_readable "$root" || continue
    for app_dir in "$root"/*.app "$root"/*/*.app; do
      [ -d "$app_dir" ] || continue
      # Skip bundles nested inside another bundle (<root>/X.app/Y.app,
      # <root>/Installer.bundle/Y.app); only plain vendor folders count.
      _app_in_bundle_dir "$app_dir" && continue
      APP_INV_WALKED_COUNT=$((APP_INV_WALKED_COUNT + 1))
      if _record_app "$app_dir"; then
        APP_INV_WALK_ONLY_COUNT=$((APP_INV_WALK_ONLY_COUNT + 1))
      fi
    done
  done

  # 3. Completeness. Each gap is stated, never silently absorbed.
  if [ "${#APP_INV_UNAVAILABLE_ROOTS[@]}" -gt 0 ]; then
    APP_INV_COMPLETE=0
    APP_INV_NOTES+=("${#APP_INV_UNAVAILABLE_ROOTS[@]} application root(s) unavailable or unreadable: ${APP_INV_UNAVAILABLE_ROOTS[*]}")
  fi
  case "$APP_INV_SPOTLIGHT" in
    unavailable)
      APP_INV_COMPLETE=0
      APP_INV_NOTES+=("Spotlight is unavailable; only the direct walk of the search roots was used")
      ;;
    used)
      if [ "$APP_INV_SPOTLIGHT_COUNT" -eq 0 ] && [ "$APP_INV_WALKED_COUNT" -gt 0 ]; then
        APP_INV_COMPLETE=0
        APP_INV_NOTES+=("Spotlight index is empty or indexing is disabled")
      elif [ "$APP_INV_WALK_ONLY_COUNT" -gt 0 ]; then
        APP_INV_COMPLETE=0
        APP_INV_NOTES+=("Spotlight missed $APP_INV_WALK_ONLY_COUNT application(s) found by the directory walk; the index may be incomplete")
      fi
      ;;
  esac

  local n
  for n in "${APP_INV_NOTES[@]:-}"; do
    [ -n "$n" ] || continue
    APP_INV_NOTE="${APP_INV_NOTE:+$APP_INV_NOTE; }$n"
  done

  APP_INV_SCANNED=1
  unset -f _app_is_visited _record_app
  return 0
}

# JSON array of strings from the positional arguments; empty strings skipped.
_json_string_array() {
  local s first=1
  printf '['
  for s in "$@"; do
    [ -n "$s" ] || continue
    [ "$first" -eq 0 ] && printf ', '
    first=0
    printf '"%s"' "$(json_escape "$s")"
  done
  printf ']'
}

_json_bool() {
  if [ "${1:-0}" = "1" ]; then printf 'true'; else printf 'false'; fi
}

# The inventory completeness object shared by `apps list` and `app inspect`.
inventory_json_object() {
  local indent="${1:-  }"
  printf '{\n'
  printf '%s  "complete": %s,\n' "$indent" "$(_json_bool "$APP_INV_COMPLETE")"
  printf '%s  "spotlight": "%s",\n' "$indent" "$APP_INV_SPOTLIGHT"
  printf '%s  "roots": %s,\n' "$indent" "$(_json_string_array "${APP_SEARCH_ROOTS[@]:-}")"
  printf '%s  "unavailable_roots": %s,\n' "$indent" "$(_json_string_array "${APP_INV_UNAVAILABLE_ROOTS[@]:-}")"
  printf '%s  "notes": %s\n' "$indent" "$(_json_string_array "${APP_INV_NOTES[@]:-}")"
  printf '%s}' "$indent"
}

# ---------------------------------------------------------------------------
# CLI Command: apps list
# ---------------------------------------------------------------------------

mimi_apps_list() {
  local source_filter="${APP_SOURCE_FILTER:-all}"
  if ! is_valid_app_source "$source_filter"; then
    die_usage "--source must be one of: $APP_SOURCE_VALUES (got '$source_filter')"
  fi

  inventory_scan_apps list

  if [ "${JSONL_ENABLED:-0}" -eq 1 ]; then
    printf '{\n'
    printf '  "schema": "mimi.apps-list/1",\n'
    printf '  "source_filter": "%s",\n' "$(json_escape "$source_filter")"
    printf '  "inventory": '
    inventory_json_object "  "
    printf ',\n'
    printf '  "apps": ['
    local i n="$APP_INV_COUNT" first=1
    for ((i = 0; i < n; i++)); do
      local src="${APP_INV_SOURCES[$i]}"
      if [ "$source_filter" != "all" ] && [ "$src" != "$source_filter" ]; then
        continue
      fi

      [ "$first" -eq 0 ] && printf ','
      first=0

      printf '\n    {\n'
      printf '      "name": "%s",\n' "$(json_escape "${APP_INV_NAMES[$i]}")"
      printf '      "bundle_id": "%s",\n' "$(json_escape "${APP_INV_IDS[$i]}")"
      printf '      "version": "%s",\n' "$(json_escape "${APP_INV_VERSIONS[$i]}")"
      printf '      "source": "%s",\n' "$(json_escape "$src")"
      if [ -n "${APP_INV_CASK_TOKENS[$i]}" ]; then
        printf '      "cask_token": "%s",\n' "$(json_escape "${APP_INV_CASK_TOKENS[$i]}")"
      else
        printf '      "cask_token": null,\n'
      fi
      printf '      "path": "%s",\n' "$(json_escape "${APP_INV_PATHS[$i]}")"
      printf '      "identity": "%s",\n' "$(json_escape "${APP_INV_IDENTITIES[$i]}")"
      printf '      "is_system": %s,\n' "$(_json_bool "${APP_INV_SYSTEM[$i]}")"
      printf '      "eligible": %s,\n' "$(_json_bool "${APP_INV_ELIGIBLE[$i]}")"
      printf '      "size_kb": %d\n' "${APP_INV_SIZES[$i]:-0}"
      printf '    }'
    done
    [ "$first" -eq 0 ] && printf '\n  '
    printf ']\n'
    printf '}\n'
    return 0
  fi

  # Human tabular output
  printf '%s=== Installed Applications (%d found) ===%s\n\n' "$C_BOLD" "$APP_INV_COUNT" "$C_RESET"
  if [ "$APP_INV_COMPLETE" -eq 0 ]; then
    local note
    for note in "${APP_INV_NOTES[@]:-}"; do
      [ -n "$note" ] && printf '%s[incomplete: %s]%s\n' "$C_YELLOW" "$note" "$C_RESET"
    done
    printf '\n'
  fi

  printf '%-30s %-12s %-8s %-32s %s\n' "APPLICATION" "VERSION" "SOURCE" "BUNDLE ID" "PATH"
  printf '%-30s %-12s %-8s %-32s %s\n' "-----------" "-------" "------" "---------" "----"

  local i n="$APP_INV_COUNT" shown=0
  for ((i = 0; i < n; i++)); do
    local src="${APP_INV_SOURCES[$i]}"
    if [ "$source_filter" != "all" ] && [ "$src" != "$source_filter" ]; then
      continue
    fi
    shown=$((shown + 1))
    local p="${APP_INV_PATHS[$i]}"
    local name="${APP_INV_NAMES[$i]}"
    local ver="${APP_INV_VERSIONS[$i]}"
    local bid="${APP_INV_IDS[$i]}"

    [ ${#name} -gt 28 ] && name="${name:0:25}..."
    [ ${#ver} -gt 11 ] && ver="${ver:0:9}..."
    [ ${#bid} -gt 30 ] && bid="${bid:0:28}..."

    printf '%-30s %-12s %-8s %-32s %s\n' "$name" "$ver" "$src" "${bid:--}" "$p"
  done

  printf '\nListed %d of %d application(s).\n' "$shown" "$APP_INV_COUNT"
  return 0
}
