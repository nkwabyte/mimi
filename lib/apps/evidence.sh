#!/usr/bin/env bash
#
# lib/apps/evidence.sh — Remnant evidence collectors and confidence/shared-use policy.
# Phase 3: P3-T04, P3-T05.
#
# Collectors emit evidence FACTS — where an item is, which signals tie it to
# the app, and how strong those signals are — never a bare "owned / not
# owned" verdict. The policy layer then classifies every fact:
#
#   confidence     meaning                                        class
#   -------------  ---------------------------------------------  -----------
#   authoritative  macOS names the item after the exact bundle    attributable
#                  id (sandbox container, preference domain).
#   strong         reverse-DNS bundle-id directory, or a startup  attributable
#                  item that launches the app's own binary.
#   corroborated   two independent signals agree (e.g. name +     attributable
#                  contents reference the bundle id).
#   weak           one heuristic signal only (bare name match,    review
#                  symlink, crash log by executable name).
#   conflicting    the item also matches another installed app    retained
#                  (duplicate copy, sibling bundle id, same name).
#   shared         shared by design: App Group containers,        retained
#                  vendor folders, shared updaters.
#
# Items in /Library are system locations: always report-only (retained).
# Only "attributable" items are selectable for any future action; see
# evidence_is_selectable. Everything here is read-only.
#
# Compatible with Bash 3.2+ (no associative arrays).
#
# shellcheck disable=SC2155

# Evidence storage arrays (parallel indexed arrays for Bash 3.2)
EVIDENCE_PATHS=()
EVIDENCE_ROOTS=()
EVIDENCE_CONFIDENCES=()
EVIDENCE_SHARED=()
EVIDENCE_SYSTEM_LOC=()
EVIDENCE_SIZES=()
EVIDENCE_REASONS=()
EVIDENCE_CLASSES=()     # attributable | review | retained
EVIDENCE_KINDS=()       # dir | file | symlink | other
EVIDENCE_COUNT=0

# Summary statistics
EVIDENCE_TOTAL_ATTRIBUTABLE_KB=0
EVIDENCE_TOTAL_REVIEW_KB=0
EVIDENCE_TOTAL_RETAINED_KB=0
EVIDENCE_ATTRIBUTABLE_COUNT=0
EVIDENCE_REVIEW_COUNT=0
EVIDENCE_RETAINED_COUNT=0
EVIDENCE_NOTES=()

# Known shared vendor directories that must NEVER be claimed by a single app
SHARED_VENDOR_NAMES=(
  "google" "microsoft" "adobe" "jetbrains" "apple" "mozilla"
  "dropbox" "1password" "oracle" "vmware" "docker"
)

# Shared updaters and vendor agents serve every app from a vendor. Matched
# against the lowercased item name as substrings.
SHARED_UPDATER_PATTERNS=(
  "com.google.keystone" "com.google.googleupdater" "googlesoftwareupdate"
  "googleupdater" "com.microsoft.autoupdate" "microsoft autoupdate"
  "com.microsoft.update.agent" "com.adobe.acc" "com.adobe.armdc"
  "com.adobe.agsservice" "adobe genuine" "adobegcclient"
)

# Names shorter than this are too generic for name-only matching ("Go", "Qt").
EVIDENCE_MIN_NAME_LEN=3

# ---------------------------------------------------------------------------
# Matching helpers
# ---------------------------------------------------------------------------

_ev_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_shared_vendor_token() {
  local tok="$1" v
  tok="$(normalize_token "$tok")"
  is_shared_vendor_norm "$tok"
}

# Same test for an already-normalised token, without a subshell.
is_shared_vendor_norm() {
  local tok="$1" v
  for v in "${SHARED_VENDOR_NAMES[@]}"; do
    if [ "$tok" = "$v" ]; then
      return 0
    fi
  done
  return 1
}

is_shared_updater_name() {
  local lc p
  lc="$(_ev_lower "$1")"
  for p in "${SHARED_UPDATER_PATTERNS[@]}"; do
    case "$lc" in
      *"$p"*) return 0 ;;
    esac
  done
  return 1
}

# Boundary-aware bundle-id match of an item name against a bundle id, case
# insensitive. Prints the match kind and returns 0, or returns 1:
#   exact   — item == id
#   child   — item == id.<more>   (com.foo.app.helper, com.foo.app.ByHost…)
#   prefix  — item == <x>.id      (TEAMID.com.foo.app, group.com.foo.app)
# "com.foo.application" is NOT a match for "com.foo.app".
ev_id_match() {
  local item id
  item="$(_ev_lower "$1")"
  id="$(_ev_lower "$2")"
  [ -n "$item" ] && [ -n "$id" ] || return 1
  if [ "$item" = "$id" ]; then printf 'exact'; return 0; fi
  case "$item" in
    "$id".*) printf 'child'; return 0 ;;
    *."$id") printf 'prefix'; return 0 ;;
    *."$id".*) printf 'prefix'; return 0 ;;
  esac
  return 1
}

# True when a file (or any of the first regular files directly inside a
# directory) mentions NEEDLE literally. Bounded so a huge tree is not read.
_ev_content_mentions() {
  local p="$1" needle="$2" f n=0
  [ -n "$needle" ] || return 1
  [ -L "$p" ] && return 1
  if [ -f "$p" ]; then
    grep -F -q -s -- "$needle" "$p" 2>/dev/null && return 0
    if command -v plutil > /dev/null 2>&1; then
      plutil -p "$p" 2>/dev/null | grep -F -q -- "$needle" && return 0
    fi
    return 1
  fi
  [ -d "$p" ] || return 1
  for f in "$p"/* "$p"/.[!.]*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    n=$((n + 1))
    [ "$n" -le 20 ] || break
    grep -F -q -s -- "$needle" "$f" 2>/dev/null && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Sibling index — other installed apps whose data must survive
# ---------------------------------------------------------------------------

EV_SIB_IDS=()        # lowercased bundle ids of other installed apps
EV_SIB_NAMES_NORM=() # normalize_token of their names / bundle basenames
EV_SIB_LABELS=()     # display "Name (path)"
EV_DUP_ID_SIBLING="" # another installed copy with the target's bundle id
EV_DUP_NAME_SIBLING=""

_ev_add_sibling() {
  local path="$1" name="$2" id="$3" base
  base="$(basename "$path" .app)"
  EV_SIB_IDS+=("$(_ev_lower "$id")")
  EV_SIB_NAMES_NORM+=("$(normalize_token "$name")|$(normalize_token "$base")")
  EV_SIB_LABELS+=("$name ($path)")
}

# Index every installed app except TARGET. Reuses a completed inventory when
# one exists; otherwise walks the search roots reading Info.plist only (it
# must not call app_inspect_bundle, which would overwrite APP_INFO_*).
ev_index_siblings() {
  local target="$1"
  EV_SIB_IDS=()
  EV_SIB_NAMES_NORM=()
  EV_SIB_LABELS=()

  local i
  if [ "${APP_INV_SCANNED:-0}" -eq 1 ]; then
    for ((i = 0; i < APP_INV_COUNT; i++)); do
      [ "${APP_INV_PATHS[$i]}" = "$target" ] && continue
      _ev_add_sibling "${APP_INV_PATHS[$i]}" "${APP_INV_NAMES[$i]}" "${APP_INV_IDS[$i]}"
    done
    return 0
  fi

  local root app_dir canon kv name id
  local -a seen=()
  for root in "${APP_SEARCH_ROOTS[@]:-}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for app_dir in "$root"/*.app "$root"/*/*.app; do
      [ -d "$app_dir" ] || continue
      _app_in_bundle_dir "$app_dir" && continue
      canon="$(path_canonicalize "$app_dir" 2>/dev/null || true)"
      [ -n "$canon" ] && [ "$canon" != "$target" ] || continue
      case " ${seen[*]:-} " in *" $canon "*) continue ;; esac
      seen+=("$canon")
      kv="$(plist_read_keys "$canon/Contents/Info.plist" CFBundleDisplayName CFBundleName CFBundleIdentifier 2>/dev/null || true)"
      name="$(_plist_kv CFBundleDisplayName "$kv" || _plist_kv CFBundleName "$kv" || true)"
      [ -n "$name" ] || name="$(basename "$canon" .app)"
      id="$(_plist_kv CFBundleIdentifier "$kv" || true)"
      _ev_add_sibling "$canon" "$name" "$id"
    done
  done
}

# Conflict check for an item matched by bundle id. Prints the sibling label
# and returns 0 when the item belongs at least as much to another app.
_ev_id_conflict() {
  local item_lc target_lc i sid
  item_lc="$(_ev_lower "$1")"
  target_lc="$(_ev_lower "$2")"
  if [ -n "$EV_DUP_ID_SIBLING" ]; then
    printf '%s' "$EV_DUP_ID_SIBLING"
    return 0
  fi
  for ((i = 0; i < ${#EV_SIB_IDS[@]}; i++)); do
    sid="${EV_SIB_IDS[$i]}"
    [ -n "$sid" ] || continue
    # A sibling whose id is more specific than the target's and matches the
    # item (com.foo.app.beta installed next to com.foo.app) owns that item.
    case "$sid" in
      "$target_lc".*)
        if ev_id_match "$item_lc" "$sid" > /dev/null; then
          printf '%s' "${EV_SIB_LABELS[$i]}"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Recording and classification
# ---------------------------------------------------------------------------

evidence_classify() {
  local conf="$1" shared="$2" sys="$3"
  if [ "$shared" -eq 1 ] || [ "$sys" -eq 1 ]; then
    printf 'retained'
    return 0
  fi
  case "$conf" in
    authoritative|strong|corroborated) printf 'attributable' ;;
    weak) printf 'review' ;;
    *) printf 'retained' ;;
  esac
}

# The single predicate every planner must use: only attributable evidence can
# ever become a selected action. Weak, conflicting, shared, and system-location
# evidence cannot.
evidence_is_selectable() {
  local i="$1"
  [ "$i" -ge 0 ] && [ "$i" -lt "$EVIDENCE_COUNT" ] || return 1
  [ "${EVIDENCE_CLASSES[$i]}" = "attributable" ]
}

# record_evidence PATH ROOT_LABEL ROOT_DIR CONFIDENCE SHARED SYSTEM REASON [MATCH]
#   MATCH is how the item was tied to the app — "id", "name", or "other" — and
#   decides which sibling-conflict test applies.
record_evidence() {
  local path="$1" root="$2" root_dir="$3" conf="$4" is_shared="$5" is_sys="$6" reason="$7"
  local match="${8:-other}"

  # Canonicalise the item itself without following a final symlink, so a
  # link is recorded as the link and its target is never claimed.
  local canon canon_root
  canon="$(path_canonicalize "$path" nofollow 2>/dev/null || true)"
  [ -n "$canon" ] || return 0
  canon_root="$(path_canonicalize "$root_dir" 2>/dev/null || true)"
  if [ -z "$canon_root" ] || ! path_contains "$canon_root" "$canon" || [ "$canon" = "$canon_root" ]; then
    verbose "evidence: skipping $path — not contained in $root_dir"
    return 0
  fi

  local i
  for ((i = 0; i < EVIDENCE_COUNT; i++)); do
    if [ "${EVIDENCE_PATHS[$i]}" = "$canon" ]; then
      return 0
    fi
  done

  local kind
  kind="$(path_kind "$canon")"

  # Policy vetoes, strongest first.
  if [ "$is_shared" -eq 0 ] && [ "$is_sys" -eq 0 ]; then
    local base sib=""
    base="$(basename "$canon")"
    if is_shared_updater_name "$base"; then
      conf="shared"
      is_shared=1
      reason="$reason; shared vendor updater (vetoed by policy)"
    elif [ "$match" = "id" ] && sib="$(_ev_id_conflict "${base%.plist}" "${EV_TARGET_ID:-}")"; then
      conf="conflicting"
      is_shared=1
      reason="$reason; also matches installed app $sib (vetoed)"
    elif [ "$match" = "name" ] && [ -n "$EV_DUP_NAME_SIBLING" ]; then
      conf="conflicting"
      is_shared=1
      reason="$reason; another installed app has the same name: $EV_DUP_NAME_SIBLING (vetoed)"
    elif [ "$kind" = "symlink" ]; then
      local tgt
      tgt="$(readlink "$canon" 2>/dev/null || true)"
      conf="weak"
      reason="$reason; symbolic link to ${tgt:-?} (link only; target never followed)"
    fi
  fi

  local size_kb
  size_kb="$(dir_size_kb "$canon")"
  [ -n "$size_kb" ] || size_kb=0

  local class
  class="$(evidence_classify "$conf" "$is_shared" "$is_sys")"

  EVIDENCE_PATHS+=("$canon")
  EVIDENCE_ROOTS+=("$root")
  EVIDENCE_CONFIDENCES+=("$conf")
  EVIDENCE_SHARED+=("$is_shared")
  EVIDENCE_SYSTEM_LOC+=("$is_sys")
  EVIDENCE_SIZES+=("$size_kb")
  EVIDENCE_REASONS+=("$reason")
  EVIDENCE_CLASSES+=("$class")
  EVIDENCE_KINDS+=("$kind")
  EVIDENCE_COUNT=$((EVIDENCE_COUNT + 1))

  case "$class" in
    attributable)
      EVIDENCE_TOTAL_ATTRIBUTABLE_KB=$((EVIDENCE_TOTAL_ATTRIBUTABLE_KB + size_kb))
      EVIDENCE_ATTRIBUTABLE_COUNT=$((EVIDENCE_ATTRIBUTABLE_COUNT + 1))
      ;;
    review)
      EVIDENCE_TOTAL_REVIEW_KB=$((EVIDENCE_TOTAL_REVIEW_KB + size_kb))
      EVIDENCE_REVIEW_COUNT=$((EVIDENCE_REVIEW_COUNT + 1))
      ;;
    *)
      EVIDENCE_TOTAL_RETAINED_KB=$((EVIDENCE_TOTAL_RETAINED_KB + size_kb))
      EVIDENCE_RETAINED_COUNT=$((EVIDENCE_RETAINED_COUNT + 1))
      ;;
  esac
}

# System locations consulted report-only. MIMI_APP_SYSTEM_ROOTS
# (colon-separated) replaces the list, so tests never read the host's /Library.
evidence_system_roots() {
  if [ -n "${MIMI_APP_SYSTEM_ROOTS+x}" ]; then
    local -a roots=()
    IFS=':' read -r -a roots <<< "$MIMI_APP_SYSTEM_ROOTS"
    local r
    for r in "${roots[@]:-}"; do
      [ -n "$r" ] && printf '%s\n' "$r"
    done
    return 0
  fi
  printf '%s\n' \
    "/Library/Application Support" \
    "/Library/LaunchAgents" \
    "/Library/LaunchDaemons" \
    "/Library/PrivilegedHelperTools" \
    "/Library/Preferences" \
    "/Library/Caches" \
    "/Library/Logs"
}

# ---------------------------------------------------------------------------
# Fast root listing
# ---------------------------------------------------------------------------
#
# A Library root can hold thousands of entries, and a per-entry `tr` for case
# folding (Bash 3.2 has no ${x,,}) made collection take tens of seconds. Each
# root is therefore listed once, with every name lowercased and normalised by
# a single awk process; the per-entry comparisons below are then pure Bash.
#
# _ev_list_root DIR [SUFFIX]
#   Lists DIR/* (or DIR/*SUFFIX), including dangling symlinks. Sets:
#     EV_E   full paths
#     EV_B   basenames with SUFFIX removed
#     EV_LC  lowercased EV_B
#     EV_N   normalize_token(EV_B): lowercased, without spaces, "_" and "-"

EV_E=()
EV_B=()
EV_LC=()
EV_N=()

_ev_list_root() {
  local dir="$1" suffix="${2-}" e b
  EV_E=()
  EV_B=()
  EV_LC=()
  EV_N=()
  [ -d "$dir" ] || return 0
  local -a names=()
  for e in "$dir"/*"$suffix"; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    b="${e##*/}"
    case "$b" in *$'\n'*) continue ;; esac
    b="${b%"$suffix"}"
    EV_E+=("$e")
    EV_B+=("$b")
    names+=("$b")
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  local lc n
  while IFS=$'\t' read -r lc n; do
    EV_LC+=("$lc")
    EV_N+=("$n")
  done < <(printf '%s\n' "${names[@]}" | awk '{ lc = tolower($0); n = lc; gsub(/[ _-]/, "", n); print lc "\t" n }')
}

# ev_id_match for an already-lowercased item against EV_ID_LC, without a
# subshell. Sets EV_M to exact | child | prefix, or "" when there is no match.
EV_M=""
_ev_idm() {
  local item="$1" id="$EV_ID_LC"
  EV_M=""
  [ -n "$item" ] && [ -n "$id" ] || return 1
  if [ "$item" = "$id" ]; then EV_M="exact"; return 0; fi
  case "$item" in
    "$id".*) EV_M="child"; return 0 ;;
    *."$id") EV_M="prefix"; return 0 ;;
    *."$id".*) EV_M="prefix"; return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Evidence collector for a target application — one known root at a time
# ---------------------------------------------------------------------------

collect_app_evidence() {
  local app_path="$1" app_name="$2" bundle_id="$3" team_id="${4-}" exe_name="${5-}"

  EVIDENCE_PATHS=()
  EVIDENCE_ROOTS=()
  EVIDENCE_CONFIDENCES=()
  EVIDENCE_SHARED=()
  EVIDENCE_SYSTEM_LOC=()
  EVIDENCE_SIZES=()
  EVIDENCE_REASONS=()
  EVIDENCE_CLASSES=()
  EVIDENCE_KINDS=()
  EVIDENCE_COUNT=0
  EVIDENCE_TOTAL_ATTRIBUTABLE_KB=0
  EVIDENCE_TOTAL_REVIEW_KB=0
  EVIDENCE_TOTAL_RETAINED_KB=0
  EVIDENCE_ATTRIBUTABLE_COUNT=0
  EVIDENCE_REVIEW_COUNT=0
  EVIDENCE_RETAINED_COUNT=0
  EVIDENCE_NOTES=()

  local canon_app
  canon_app="$(path_canonicalize "$app_path" 2>/dev/null || printf '%s' "$app_path")"
  EV_TARGET_ID="$bundle_id"
  EV_ID_LC="$(_ev_lower "$bundle_id")"

  local name_norm exe_norm team_lc
  name_norm="$(normalize_token "$app_name")"
  exe_norm="$(normalize_token "$exe_name")"
  team_lc="$(_ev_lower "$team_id")"

  # Name-based matching is disabled for very short names.
  local use_name=1
  if [ -z "$app_name" ] || [ "${#name_norm}" -lt "$EVIDENCE_MIN_NAME_LEN" ]; then
    use_name=0
    EVIDENCE_NOTES+=("app name '$app_name' is too short for name-based matching; only bundle-id evidence was collected")
  fi
  local use_exe=0
  [ -n "$exe_norm" ] && [ "${#exe_norm}" -ge "$EVIDENCE_MIN_NAME_LEN" ] && use_exe=1
  if [ -z "$bundle_id" ]; then
    EVIDENCE_NOTES+=("no bundle identifier; only name-based (weak) evidence could be collected")
  fi

  # Siblings: other installed apps whose data must survive.
  ev_index_siblings "$canon_app"
  EV_DUP_ID_SIBLING=""
  EV_DUP_NAME_SIBLING=""
  local i
  for ((i = 0; i < ${#EV_SIB_IDS[@]}; i++)); do
    if [ -n "$EV_ID_LC" ] && [ "${EV_SIB_IDS[$i]}" = "$EV_ID_LC" ] && [ -z "$EV_DUP_ID_SIBLING" ]; then
      EV_DUP_ID_SIBLING="${EV_SIB_LABELS[$i]}"
    fi
    case "|${EV_SIB_NAMES_NORM[$i]}|" in
      *"|$name_norm|"*)
        [ -z "$EV_DUP_NAME_SIBLING" ] && [ -n "$name_norm" ] && EV_DUP_NAME_SIBLING="${EV_SIB_LABELS[$i]}"
        ;;
    esac
  done
  if [ -n "$EV_DUP_ID_SIBLING" ]; then
    EVIDENCE_NOTES+=("another installed copy shares this bundle id: $EV_DUP_ID_SIBLING — all bundle-id evidence is retained")
  fi

  local L="$HOME_DIR/Library"
  local j e b lc nt

  # -------------------------------------------------------------------------
  # 1. Containers (~/Library/Containers) — sandbox data
  # -------------------------------------------------------------------------
  local cont_root="$L/Containers"
  _ev_list_root "$cont_root"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"; b="${EV_B[$j]}"; lc="${EV_LC[$j]}"; nt="${EV_N[$j]}"
    _ev_idm "$lc" || true
    if [ "$EV_M" = "exact" ]; then
      record_evidence "$e" "Containers" "$cont_root" "authoritative" 0 0 "exact bundle id sandbox container" id
    elif [ "$EV_M" = "child" ]; then
      record_evidence "$e" "Containers" "$cont_root" "strong" 0 0 "sandbox container of an embedded extension/helper ($b)" id
    elif looks_like_uuid "$b"; then
      # Anonymous container: attributable only through its metadata.
      [ -n "$bundle_id" ] || continue
      local meta mid=""
      meta="$e/.com.apple.containermanager.metadata.plist"
      [ -f "$meta" ] && mid="$(plist_get_value "$meta" MCMMetadataIdentifier 2>/dev/null || true)"
      if [ -n "$mid" ] && ev_id_match "$mid" "$bundle_id" > /dev/null; then
        record_evidence "$e" "Containers" "$cont_root" "corroborated" 0 0 "anonymous container whose metadata identifier is $mid" id
      elif [ -d "$e/Data/Library/Application Support/$bundle_id" ]; then
        record_evidence "$e" "Containers" "$cont_root" "weak" 0 0 "anonymous UUID container holding a folder named after the bundle id" id
      fi
    elif [ "$use_name" -eq 1 ] && [ "$nt" = "$name_norm" ]; then
      record_evidence "$e" "Containers" "$cont_root" "weak" 0 0 "container named after the app (name match only)" name
    fi
  done

  # -------------------------------------------------------------------------
  # 2. Group Containers (~/Library/Group Containers) — ALWAYS SHARED / VETOED
  # -------------------------------------------------------------------------
  local gc_root="$L/Group Containers"
  _ev_list_root "$gc_root"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"; b="${EV_B[$j]}"; lc="${EV_LC[$j]}"
    local why=""
    if _ev_idm "$lc"; then
      why="App Group named after the bundle id"
    elif [ -n "$team_lc" ] && [[ "$lc" == "$team_lc".* ]]; then
      why="App Group of the same developer Team ID ($team_id)"
    elif [ "$use_name" -eq 1 ] && [ "$(normalize_token "${b##*.}")" = "$name_norm" ]; then
      why="App Group whose last component matches the app name"
    fi
    if [ -n "$why" ]; then
      record_evidence "$e" "Group Containers" "$gc_root" "shared" 1 0 "$why; shared by design with sibling apps and extensions (vetoed by policy)"
    fi
  done

  # -------------------------------------------------------------------------
  # 3. Application Scripts (~/Library/Application Scripts) — sandbox scripts
  # -------------------------------------------------------------------------
  local ascr_root="$L/Application Scripts"
  if [ -n "$bundle_id" ]; then
    _ev_list_root "$ascr_root"
    for ((j = 0; j < ${#EV_E[@]}; j++)); do
      e="${EV_E[$j]}"; b="${EV_B[$j]}"
      _ev_idm "${EV_LC[$j]}" || continue
      case "$EV_M" in
        exact) record_evidence "$e" "Application Scripts" "$ascr_root" "authoritative" 0 0 "exact bundle id sandbox scripts folder" id ;;
        child) record_evidence "$e" "Application Scripts" "$ascr_root" "strong" 0 0 "scripts folder of an embedded extension ($b)" id ;;
        prefix)
          # TEAMID.com.foo.app style folders are shared across a team's apps.
          record_evidence "$e" "Application Scripts" "$ascr_root" "shared" 1 0 "team-prefixed scripts folder shared across the developer's apps (vetoed)" id ;;
      esac
    done
  fi

  # -------------------------------------------------------------------------
  # 4. Preferences (~/Library/Preferences) and ByHost
  # -------------------------------------------------------------------------
  local pref_root="$L/Preferences"
  _ev_list_root "$pref_root" ".plist"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"; b="${EV_B[$j]}"; nt="${EV_N[$j]}"
    _ev_idm "${EV_LC[$j]}" || true
    if [ "$EV_M" = "exact" ]; then
      record_evidence "$e" "Preferences" "$pref_root" "authoritative" 0 0 "exact bundle id preference domain" id
    elif [ "$EV_M" = "child" ]; then
      record_evidence "$e" "Preferences" "$pref_root" "strong" 0 0 "preference domain nested under the bundle id ($b)" id
    elif [ "$use_name" -eq 1 ] && [ "$nt" = "$name_norm" ]; then
      if _ev_content_mentions "$e" "$bundle_id"; then
        record_evidence "$e" "Preferences" "$pref_root" "corroborated" 0 0 "preference plist named after the app whose contents reference the bundle id" name
      else
        record_evidence "$e" "Preferences" "$pref_root" "weak" 0 0 "preference plist named after the app (name match only)" name
      fi
    fi
  done

  if [ -n "$bundle_id" ]; then
    _ev_list_root "$pref_root/ByHost" ".plist"
    for ((j = 0; j < ${#EV_E[@]}; j++)); do
      # <bundle id>.<host UUID>.plist
      _ev_idm "${EV_LC[$j]}" || continue
      if [ "$EV_M" = "child" ]; then
        record_evidence "${EV_E[$j]}" "Preferences (ByHost)" "$pref_root/ByHost" "authoritative" 0 0 "ByHost preference domain for the bundle id" id
      fi
    done
  fi

  # -------------------------------------------------------------------------
  # 5. Saved Application State (~/Library/Saved Application State)
  # -------------------------------------------------------------------------
  local sas_root="$L/Saved Application State"
  _ev_list_root "$sas_root" ".savedState"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"
    _ev_idm "${EV_LC[$j]}" || true
    if [ "$EV_M" = "exact" ]; then
      record_evidence "$e" "Saved Application State" "$sas_root" "authoritative" 0 0 "exact bundle id saved window state" id
    elif [ "$use_name" -eq 1 ] && [ "${EV_N[$j]}" = "$name_norm" ]; then
      record_evidence "$e" "Saved Application State" "$sas_root" "weak" 0 0 "saved state named after the app (name match only)" name
    fi
  done

  # -------------------------------------------------------------------------
  # 6. WebKit, HTTPStorages, Cookies — keyed by exact bundle id
  # -------------------------------------------------------------------------
  if [ -n "$bundle_id" ]; then
    local wroot wlabel wsuffix
    for wroot in "$L/WebKit::WebKit::" "$L/HTTPStorages::HTTPStorages::" "$L/Cookies::Cookies::.binarycookies"; do
      wsuffix="${wroot##*::}"
      wroot="${wroot%::*}"
      wlabel="${wroot#*::}"
      wroot="${wroot%%::*}"
      _ev_list_root "$wroot" "$wsuffix"
      for ((j = 0; j < ${#EV_E[@]}; j++)); do
        # HTTPStorages also holds <id>.binarycookies next to the <id> folder.
        lc="${EV_LC[$j]}"
        lc="${lc%.binarycookies}"
        _ev_idm "$lc" || continue
        [ "$EV_M" = "exact" ] || continue
        record_evidence "${EV_E[$j]}" "$wlabel" "$wroot" "authoritative" 0 0 "exact bundle id $wlabel storage" id
      done
    done
  fi

  # -------------------------------------------------------------------------
  # 7. Application Support (~/Library/Application Support)
  # -------------------------------------------------------------------------
  local as_root="$L/Application Support"
  local id_vendor=""
  # Second component of a reverse-DNS id: com.google.Chrome -> google
  if [ -n "$bundle_id" ]; then
    id_vendor="${EV_ID_LC#*.}"
    id_vendor="${id_vendor%%.*}"
  fi
  _ev_list_root "$as_root"
  local -a as_e=("${EV_E[@]:-}") as_b=("${EV_B[@]:-}") as_lc=("${EV_LC[@]:-}") as_n=("${EV_N[@]:-}")
  local as_count="${#EV_E[@]}"
  for ((j = 0; j < as_count; j++)); do
    e="${as_e[$j]}"; b="${as_b[$j]}"; lc="${as_lc[$j]}"; nt="${as_n[$j]}"

    # Shared vendor folder: never claimed itself; look one level inside.
    if is_shared_vendor_norm "$nt"; then
      local k vendor_corr=0
      [ -n "$id_vendor" ] && [ "$nt" = "$(normalize_token "$id_vendor")" ] && vendor_corr=1
      _ev_list_root "$e"
      for ((k = 0; k < ${#EV_E[@]}; k++)); do
        _ev_idm "${EV_LC[$k]}" || true
        if [ "$EV_M" = "exact" ]; then
          record_evidence "${EV_E[$k]}" "Application Support" "$e" "strong" 0 0 "bundle id folder inside the shared $b vendor folder" id
        elif [ "$use_name" -eq 1 ] && [ "${EV_N[$k]}" = "$name_norm" ]; then
          if [ "$vendor_corr" -eq 1 ]; then
            record_evidence "${EV_E[$k]}" "Application Support" "$e" "corroborated" 0 0 "app-name folder inside the $b vendor folder, and the bundle id names the same vendor" name
          else
            record_evidence "${EV_E[$k]}" "Application Support" "$e" "weak" 0 0 "app-name folder inside the shared $b vendor folder (name match only)" name
          fi
        fi
      done
      continue
    fi

    _ev_idm "$lc" || true
    if [ "$EV_M" = "exact" ]; then
      if looks_like_bundle_id "$b"; then
        record_evidence "$e" "Application Support" "$as_root" "strong" 0 0 "reverse-DNS bundle id directory" id
      else
        record_evidence "$e" "Application Support" "$as_root" "corroborated" 0 0 "directory named exactly after the bundle id" id
      fi
    elif [ "$EV_M" = "child" ]; then
      record_evidence "$e" "Application Support" "$as_root" "corroborated" 0 0 "directory nested under the bundle id ($b)" id
    elif [ "$use_name" -eq 1 ] && [ "$nt" = "$name_norm" ]; then
      if _ev_content_mentions "$e" "$bundle_id"; then
        record_evidence "$e" "Application Support" "$as_root" "corroborated" 0 0 "directory named after the app whose contents reference the bundle id" name
      else
        record_evidence "$e" "Application Support" "$as_root" "weak" 0 0 "bare-word directory named after the app, no internal corroboration" name
      fi
    fi
  done

  # -------------------------------------------------------------------------
  # 8. Caches (~/Library/Caches)
  # -------------------------------------------------------------------------
  local c_root="$L/Caches"
  _ev_list_root "$c_root"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"; b="${EV_B[$j]}"; nt="${EV_N[$j]}"
    _ev_idm "${EV_LC[$j]}" || true
    if [ "$EV_M" = "exact" ] || [ "$EV_M" = "child" ]; then
      if looks_like_bundle_id "$b"; then
        record_evidence "$e" "Caches" "$c_root" "strong" 0 0 "reverse-DNS bundle id cache directory" id
      else
        record_evidence "$e" "Caches" "$c_root" "corroborated" 0 0 "cache directory named after the bundle id" id
      fi
    elif [ "$use_name" -eq 1 ] && [ "$nt" = "$name_norm" ] && ! is_shared_vendor_norm "$nt"; then
      record_evidence "$e" "Caches" "$c_root" "weak" 0 0 "cache directory named after the app (name match only)" name
    fi
  done

  # -------------------------------------------------------------------------
  # 9. Logs (~/Library/Logs) and crash reports
  # -------------------------------------------------------------------------
  local log_root="$L/Logs"
  _ev_list_root "$log_root"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"; b="${EV_B[$j]}"
    [ "$b" = "DiagnosticReports" ] && continue
    _ev_idm "${EV_LC[$j]}" || true
    if [ "$EV_M" = "exact" ]; then
      record_evidence "$e" "Logs" "$log_root" "corroborated" 0 0 "log directory named after the bundle id" id
    elif [ "$use_name" -eq 1 ] && [ "${EV_N[$j]}" = "$name_norm" ]; then
      record_evidence "$e" "Logs" "$log_root" "weak" 0 0 "log directory named after the app (name match only)" name
    fi
  done

  local dr_root="$log_root/DiagnosticReports"
  if [ "$use_exe" -eq 1 ]; then
    _ev_list_root "$dr_root"
    for ((j = 0; j < ${#EV_E[@]}; j++)); do
      e="${EV_E[$j]}"; b="${EV_B[$j]}"
      [ -f "$e" ] || continue
      # <Executable>-YYYY-MM-DD-HHMMSS.ips / <Executable>_YYYY-..._host.crash
      local stem="${b%%-[0-9][0-9][0-9][0-9]-*}"
      stem="${stem%%_[0-9][0-9][0-9][0-9]-*}"
      [ "$stem" != "$b" ] || continue
      [ "$(normalize_token "$stem")" = "$exe_norm" ] || continue
      if _ev_content_mentions "$e" "$bundle_id"; then
        record_evidence "$e" "Crash Reports" "$dr_root" "corroborated" 0 0 "crash report for the app's executable that names the bundle id" name
      else
        record_evidence "$e" "Crash Reports" "$dr_root" "weak" 0 0 "crash report named after the executable (name match only)" name
      fi
    done
  fi

  # -------------------------------------------------------------------------
  # 10. LaunchAgents (~/Library/LaunchAgents) — startup integration
  # -------------------------------------------------------------------------
  # Every agent is read (Label, Program/BundleProgram/ProgramArguments[0]):
  # one that launches the app's own binary is evidence whatever its name.
  local la_root="$L/LaunchAgents"
  _ev_list_root "$la_root" ".plist"
  for ((j = 0; j < ${#EV_E[@]}; j++)); do
    e="${EV_E[$j]}"
    local kv label prog label_match=0 name_match=0 prog_match=0
    kv="$(plist_read_keys "$e" Label Program BundleProgram 2>/dev/null || true)"
    label="$(_plist_kv Label "$kv" || true)"
    prog="$(_plist_kv Program "$kv" || _plist_kv BundleProgram "$kv" || true)"
    if [ -z "$prog" ] && command -v plutil > /dev/null 2>&1; then
      prog="$(plutil -extract ProgramArguments.0 raw -o - "$e" 2>/dev/null || true)"
    fi

    if _ev_idm "${EV_LC[$j]}"; then
      label_match=1
    elif [ -n "$label" ] && [ -n "$bundle_id" ] && ev_id_match "$label" "$bundle_id" > /dev/null; then
      label_match=1
    fi
    if [ "$label_match" -eq 0 ] && [ "$use_name" -eq 1 ]; then
      case "${EV_N[$j]}" in
        *"$name_norm"*) name_match=1 ;;
      esac
    fi
    case "$prog" in
      "$canon_app"/*|"$app_path"/*) prog_match=1 ;;
    esac

    if [ "$label_match" -eq 1 ] && [ "$prog_match" -eq 1 ]; then
      record_evidence "$e" "LaunchAgents" "$la_root" "strong" 0 0 "LaunchAgent label matches the bundle id and it launches the app's own binary" id
    elif [ "$prog_match" -eq 1 ]; then
      record_evidence "$e" "LaunchAgents" "$la_root" "strong" 0 0 "LaunchAgent launches a program inside the app bundle ($prog)" other
    elif [ "$label_match" -eq 1 ]; then
      record_evidence "$e" "LaunchAgents" "$la_root" "corroborated" 0 0 "LaunchAgent label matches the bundle id" id
    elif [ "$name_match" -eq 1 ]; then
      record_evidence "$e" "LaunchAgents" "$la_root" "weak" 0 0 "LaunchAgent file name contains the app name (name match only)" name
    fi
  done

  # -------------------------------------------------------------------------
  # 11. Developer / CLI artifacts — dotfolders in HOME and ~/.config
  # -------------------------------------------------------------------------
  if [ "$use_name" -eq 1 ] || [ "$use_exe" -eq 1 ]; then
    local dd
    for dd in "$HOME_DIR::." "$HOME_DIR/.config::"; do
      local droot="${dd%%::*}" dprefix="${dd#*::}"
      [ -d "$droot" ] || continue
      local -a dnames=()
      for e in "$droot/$dprefix"*; do
        [ -d "$e" ] || [ -L "$e" ] || continue
        b="${e##*/}"
        [ -n "$dprefix" ] && { [ "${b:0:1}" = "." ] || continue; }
        case "$b" in .|..|.config|.Trash|.local|.cache|.ssh|.gnupg) continue ;; esac
        dnames+=("$e")
      done
      [ "${#dnames[@]}" -gt 0 ] || continue
      local dpath dn
      while IFS=$'\t' read -r dn dpath; do
        if { [ "$use_name" -eq 1 ] && [ "$dn" = "$name_norm" ]; } || { [ "$use_exe" -eq 1 ] && [ "$dn" = "$exe_norm" ]; }; then
          record_evidence "$dpath" "Developer Artifacts" "$droot" "weak" 0 0 "dotfolder named after the app or its executable (name match only; may hold user configuration)" name
        fi
      done < <(printf '%s\n' "${dnames[@]}" | awk '{ p = $0; b = p; sub(/.*\//, "", b); sub(/^\./, "", b); b = tolower(b); gsub(/[ _-]/, "", b); print b "\t" p }')
    done
  fi

  # -------------------------------------------------------------------------
  # 12. System locations — report-only, never selectable
  # -------------------------------------------------------------------------
  local s_root
  while IFS= read -r s_root; do
    [ -n "$s_root" ] && [ -d "$s_root" ] || continue
    _ev_list_root "$s_root"
    for ((j = 0; j < ${#EV_E[@]}; j++)); do
      lc="${EV_LC[$j]}"
      lc="${lc%.plist}"
      nt="${EV_N[$j]}"
      nt="${nt%.plist}"
      local sys_why=""
      if _ev_idm "$lc"; then
        sys_why="named after the bundle id"
      elif [ "$use_name" -eq 1 ] && [ "$nt" = "$name_norm" ]; then
        sys_why="named after the app"
      fi
      if [ -n "$sys_why" ]; then
        record_evidence "${EV_E[$j]}" "System: $s_root" "$s_root" "corroborated" 0 1 "system location $sys_why (report-only; requires administrator scope)"
      fi
    done
  done < <(evidence_system_roots)

  return 0
}
