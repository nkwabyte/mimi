#!/usr/bin/env bash
#
# lib/cleaners/orphans.sh lib/orphans.sh — orphaned application leftover detection and review.
#

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
  [ -e "$app" ] || return 0
  # An app bundle without a readable bundle id is ordinary, not an error: the
  # `|| true` says so explicitly rather than leaving the function's exit status
  # to depend on whether the last lookup happened to succeed.
  id=""
  if command -v mdls > /dev/null 2>&1; then
    id="$(mdls -name kMDItemCFBundleIdentifier -raw "$app" 2>/dev/null || true)"
    [ "$id" = "(null)" ] && id=""
  fi
  if [ -z "$id" ] && command -v defaults > /dev/null 2>&1; then
    id="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  fi
  name="$(basename "$app" .app)"
  [ -n "$id" ] && INSTALLED_IDS_NORM+=("$(normalize_token "$id")")
  INSTALLED_NAMES_NORM+=("$(normalize_token "$name")")
  return 0
}

build_installed_identifiers() {
  [ "$_INSTALLED_BUILT" = 1 ] && return
  _INSTALLED_BUILT=1

  ORPHAN_SPOTLIGHT_APPS=0
  ORPHAN_WALKED_APPS=0
  ORPHAN_INDEX_COMPLETE=1
  ORPHAN_INDEX_NOTE=""

  # Primary: ask Spotlight for every app bundle on the machine, wherever it
  # lives (catches apps outside the standard folders, e.g. dragged into
  # Downloads or a custom location) rather than trusting a fixed path list.
  local have_mdfind=0
  if command -v mdfind > /dev/null 2>&1; then
    have_mdfind=1
    local app
    while IFS= read -r app; do
      [ -n "$app" ] || continue
      ORPHAN_SPOTLIGHT_APPS=$((ORPHAN_SPOTLIGHT_APPS + 1))
      _index_app "$app"
    done < <(mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null)
  fi

  # Supplement with a direct directory walk in case Spotlight is disabled,
  # not finished indexing, or excludes a volume.
  local root app
  for root in "${ORPHAN_APP_WALK_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    for app in "$root"/*.app; do
      ORPHAN_WALKED_APPS=$((ORPHAN_WALKED_APPS + 1))
      _index_app "$app"
    done
  done

  # This whole scan reasons from absence: an entry is a candidate because no
  # installed application claimed it. That inference is only as good as the
  # index, so the cases where the index is known to be partial are recorded
  # here and reported rather than being silently read as "uninstalled".
  if [ "$have_mdfind" != 1 ]; then
    ORPHAN_INDEX_COMPLETE=0
    ORPHAN_INDEX_NOTE="Spotlight (mdfind) is unavailable"
  elif [ "$ORPHAN_SPOTLIGHT_APPS" -eq 0 ]; then
    ORPHAN_INDEX_COMPLETE=0
    ORPHAN_INDEX_NOTE="Spotlight returned no applications at all (indexing disabled, still running, or this volume is excluded)"
  elif [ "$ORPHAN_SPOTLIGHT_APPS" -lt "$ORPHAN_WALKED_APPS" ]; then
    ORPHAN_INDEX_COMPLETE=0
    ORPHAN_INDEX_NOTE="Spotlight returned fewer applications ($ORPHAN_SPOTLIGHT_APPS) than a plain directory walk found ($ORPHAN_WALKED_APPS), so its index is incomplete"
  fi

  verbose "indexed ${#INSTALLED_IDS_NORM[@]} bundle id(s) and ${#INSTALLED_NAMES_NORM[@]} app name(s) from installed applications"
  verbose "spotlight apps=$ORPHAN_SPOTLIGHT_APPS walked apps=$ORPHAN_WALKED_APPS complete=$ORPHAN_INDEX_COMPLETE"
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
# "strong" = the location names entries by bundle id AND the name really is
# one AND nothing installed claimed it. "weak" = everything else. Neither is
# ever deleted by this scan; the label only orders the report.
ORPHAN_CANDIDATE_TIERS=()

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
        bundle-id-named) tier="strong" ;;
        bundle-id-if-dotted) looks_like_bundle_id "$token" && tier="strong" || tier="weak" ;;
        name-guess) tier="weak" ;;
        *) tier="weak" ;;
      esac
      # A bare UUID names nothing: it is as likely to belong to a live
      # extension of an installed app as to anything uninstalled.
      looks_like_uuid "$token" && tier="weak"
      # If the installed-app index is incomplete, "nothing claimed this" is
      # not evidence of anything, so no candidate can be called strong.
      [ "$ORPHAN_INDEX_COMPLETE" = 1 ] || tier="weak"

      ORPHAN_CANDIDATE_PATHS+=("$entry")
      ORPHAN_CANDIDATE_TOKENS+=("$token")
      ORPHAN_CANDIDATE_KINDS+=("$kind")
      ORPHAN_CANDIDATE_TIERS+=("$tier")
    done
  done
}

# ---------------------------------------------------------------------------
# Reviewed-orphan input
#
# The review file is the only way a scanned leftover can ever be deleted,
# which makes it the one place where a *user-supplied list of paths* reaches
# the removal code. It is therefore treated as untrusted input:
#
#   * the file must carry the marker this tool writes, so an arbitrary list of
#     paths someone was talked into passing is not accepted;
#   * "#" starts a comment only as the first character of a line, so a folder
#     genuinely named "Foo#1" is no longer truncated to "Foo";
#   * every path is canonicalized and must resolve to a *direct child* of a
#     known orphan root — the previous code compared the raw, unresolved
#     string against "$HOME/Library/Application Support/"* and friends, which
#     any "../.." walked straight out of;
#   * everything is revalidated immediately before the removal itself, because
#     the confirmation prompt in between is an unbounded pause.
# ---------------------------------------------------------------------------

# First line of a review file. A file without it is refused.
ORPHAN_REVIEW_FORMAT="mimi-orphan-review v1"
# The marker written before the tool was renamed. Still accepted on input, so a
# review file someone generated and is halfway through editing keeps working.
ORPHAN_REVIEW_FORMAT_LEGACY="cleanmymac-orphan-review v1"

# Results of the most recent validate_orphan_target call (see path_authorize
# for why these are globals rather than stdout).
ORPHAN_DENY_REASON=""
ORPHAN_CANONICAL=""

# Count of candidates write_orphans_review_file could not represent.
ORPHAN_REVIEW_SKIPPED=0

_ORPHAN_ROOTS_CANONICAL=()
_ORPHAN_ROOTS_CANONICAL_READY=0

# ORPHAN_ROOTS is the single source of truth for which locations may hold an
# orphan candidate, so the reviewed-input check derives its allowed roots from
# the same list the scanner walks instead of keeping a second copy.
orphan_roots_canonical_ready() {
  [ "$_ORPHAN_ROOTS_CANONICAL_READY" = 1 ] && return 0
  local spec root c
  _ORPHAN_ROOTS_CANONICAL=()
  for spec in "${ORPHAN_ROOTS[@]}"; do
    root="${spec%%::*}"
    c="$(path_canonicalize "$root")" || continue
    [ -n "$c" ] || continue
    _ORPHAN_ROOTS_CANONICAL+=("$c")
  done
  _ORPHAN_ROOTS_CANONICAL_READY=1
  return 0
}

# Decide whether one reviewed path may be removed.
#
# On success sets ORPHAN_CANONICAL and returns 0. On refusal returns non-zero
# with ORPHAN_DENY_REASON set to a stable code:
#
#   missing           gone since the review file was written
#   empty relative traversal unresolvable forbidden outside-root symlink
#                     passed straight through from path_authorize
#   not-orphan-root   does not resolve underneath any known orphan location
#   not-direct-child  resolves deeper than a direct child of one
#   whitelisted       protected by --whitelist
#
# "Direct child" is deliberate: every candidate this tool writes is a direct
# child of an orphan root, so anything deeper did not come from a scan.
validate_orphan_target() {
  local raw="$1" canon root parent in_root=1 direct=1

  ORPHAN_DENY_REASON=""
  ORPHAN_CANONICAL=""

  if [ ! -e "$raw" ] && [ ! -L "$raw" ]; then
    ORPHAN_DENY_REASON="missing"
    return 1
  fi

  if ! path_authorize "$raw" > /dev/null; then
    ORPHAN_DENY_REASON="$PATH_DENY_REASON"
    return 1
  fi
  canon="$PATH_CANONICAL"

  orphan_roots_canonical_ready
  parent="${canon%/*}"
  for root in ${_ORPHAN_ROOTS_CANONICAL[@]+"${_ORPHAN_ROOTS_CANONICAL[@]}"}; do
    # The root directory itself is never a candidate, only things inside it.
    [ "$canon" = "$root" ] && continue
    path_contains "$root" "$canon" || continue
    in_root=0
    [ "$parent" = "$root" ] && direct=0
  done

  if [ "$in_root" != 0 ]; then
    ORPHAN_DENY_REASON="not-orphan-root"
    return 1
  fi
  if [ "$direct" != 0 ]; then
    ORPHAN_DENY_REASON="not-direct-child"
    return 1
  fi
  if is_whitelisted "$canon"; then
    ORPHAN_DENY_REASON="whitelisted"
    return 1
  fi

  ORPHAN_CANONICAL="$canon"
  return 0
}

# Stop a user LaunchAgent before its plist is deleted.
#
# `launchctl unload <path>` is the legacy interface; it still works but is
# deprecated and reports nothing useful. The current form is domain-scoped:
# gui/<uid> for a per-user agent. The label, not the path, is what the modern
# subcommands address, so it is read out of the plist first.
#
# This is deliberately not fatal. If the agent cannot be stopped, deleting its
# plist still prevents it coming back at next login — but the user is told,
# because the job keeps running until then, and the old `|| true` hid that
# completely.
unload_launch_agent() {
  local plist="$1" label="" uid

  uid="$(id -u)"

  if command -v plutil > /dev/null 2>&1; then
    label="$(plutil -extract Label raw -o - "$plist" 2>/dev/null || true)"
  fi
  if [ -z "$label" ] && command -v defaults > /dev/null 2>&1; then
    label="$(defaults read "${plist%.plist}" Label 2>/dev/null || true)"
  fi

  command -v launchctl > /dev/null 2>&1 || {
    warn "launchctl not available; $(basename "$plist") is removed but may still be running"
    return 1
  }

  if [ -n "$label" ]; then
    if launchctl bootout "gui/$uid/$label" > /dev/null 2>&1; then
      verbose "booted out gui/$uid/$label"
      return 0
    fi
    # bootout fails with ESRCH when the job simply is not loaded, which is the
    # normal case for a leftover from an uninstalled app.
    if ! launchctl print "gui/$uid/$label" > /dev/null 2>&1; then
      verbose "not loaded, nothing to stop: $label"
      return 0
    fi
    warn "could not stop $label; it will not return after you log out"
    return 1
  fi

  warn "no Label in $(basename "$plist"); cannot stop it by name"
  warn "if something from it is running, it will stop at your next login"
  return 1
}

# Human wording for the current ORPHAN_DENY_REASON.
orphan_deny_message() {
  case "${ORPHAN_DENY_REASON:-}" in
    missing) printf 'no longer exists' ;;
    not-orphan-root) printf 'not inside any known orphan location' ;;
    not-direct-child) printf 'not a direct child of an orphan location' ;;
    whitelisted) printf 'protected by the whitelist' ;;
    *) path_deny_message ;;
  esac
}

write_orphans_review_file() {
  local out="$1" nl
  nl='
'
  ORPHAN_REVIEW_SKIPPED=0
  mkdir -p "$(dirname "$out")"
  {
    printf '# %s\n' "$ORPHAN_REVIEW_FORMAT"
    printf '# Keep the line above: %s refuses a review file without it.\n' "$SCRIPT_NAME"
    printf '# Orphan candidates found on %s\n' "$(date)"
    printf '#\n'
    printf '# One path per line. Delete a line, or put a # at the start of it, for\n'
    printf '# anything you want to KEEP. A # anywhere else on the line is part of the\n'
    printf '# filename, not a comment.\n'
    printf '# Then run:  ./%s --clean --remove-orphans-from "%s"\n' "$SCRIPT_NAME" "$out"
    printf '#\n'
    printf '# [strong] named by bundle id, and no installed app claims that id\n'
    printf '# [weak]   the name is a guess (bare word, macOS service name, UUID, or the\n'
    printf '#          installed-app index was incomplete). NOT evidence that anything\n'
    printf '#          was uninstalled.\n'
    printf '#\n'
    printf '# Neither tier was removed by the scan that wrote this file. This file is the\n'
    printf '# only way any of it can be deleted, and every line is revalidated first.\n'
    printf '#\n'
    printf '# Only direct children of the locations this tool scans are accepted back,\n'
    printf '# so adding arbitrary paths here will not remove them.\n'
    printf '#\n'
    local i n="${#ORPHAN_CANDIDATE_PATHS[@]}"
    for ((i = 0; i < n; i++)); do
      # A line-based file cannot represent a path containing a newline: writing
      # it would produce two lines that each resolve to something else. Report
      # it instead of silently mangling it.
      case "${ORPHAN_CANDIDATE_PATHS[$i]}" in
        *"$nl"*)
          printf '# NOT LISTED (path contains a newline): token=%s\n' "${ORPHAN_CANDIDATE_TOKENS[$i]}"
          ORPHAN_REVIEW_SKIPPED=$((ORPHAN_REVIEW_SKIPPED + 1))
          continue
          ;;
      esac
      printf '# [%s] token=%s size=%s\n' "${ORPHAN_CANDIDATE_TIERS[$i]}" "${ORPHAN_CANDIDATE_TOKENS[$i]}" "$(human_kb "$(dir_size_kb "${ORPHAN_CANDIDATE_PATHS[$i]}")")"
      printf '%s\n' "${ORPHAN_CANDIDATE_PATHS[$i]}"
    done
  } > "$out"
}
