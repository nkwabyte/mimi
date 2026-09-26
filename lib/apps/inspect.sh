#!/usr/bin/env bash
#
# lib/apps/inspect.sh — Application target resolution and inspection command.
# Phase 3: P3-T06.
#
# Read-only. `app inspect` never creates, moves, or deletes anything.
#
# Compatible with Bash 3.2+ (no associative arrays).
#

# ---------------------------------------------------------------------------
# Target Resolution
# ---------------------------------------------------------------------------
#
# Exact resolution rules, applied in order; the first rule that matches
# anything decides the outcome, and a rule that matches more than one app
# stops with the list of choices instead of guessing:
#
#   1. path       — TARGET contains "/" or ends in ".app". It must exist and
#                   be an application bundle (a directory with
#                   Contents/Info.plist). Symlinks are resolved.
#   2. bundle_id  — exact CFBundleIdentifier match, then case-insensitive.
#   3. cask       — exact installed Homebrew cask token.
#   4. name       — normalised display name or bundle file name (case, space,
#                   "-" and "_" insensitive; a trailing ".app" is ignored).
#
# There is no fuzzy or substring matching.
#
# Sets RESOLVED_APP_PATH and RESOLVED_APP_METHOD on success. On failure sets
# RESOLVE_ERROR_CODE (not_found | ambiguous | not_an_app) and the parallel
# RESOLVE_CANDIDATE_* arrays, prints a human error to stderr, and returns 1.

RESOLVED_APP_PATH=""
RESOLVED_APP_METHOD=""
RESOLVE_ERROR_CODE=""
RESOLVE_ERROR_MESSAGE=""
RESOLVE_CANDIDATE_PATHS=()
RESOLVE_CANDIDATE_IDS=()
RESOLVE_CANDIDATE_NAMES=()

_resolve_fail() {
  RESOLVE_ERROR_CODE="$1"
  RESOLVE_ERROR_MESSAGE="$2"
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$RESOLVE_ERROR_MESSAGE" >&2
  local i
  for ((i = 0; i < ${#RESOLVE_CANDIDATE_PATHS[@]}; i++)); do
    printf '  - %s (Bundle ID: %s)\n' "${RESOLVE_CANDIDATE_PATHS[$i]}" "${RESOLVE_CANDIDATE_IDS[$i]:-none}" >&2
  done
  if [ "$RESOLVE_ERROR_CODE" = "ambiguous" ]; then
    printf 'Specify the exact bundle ID or full path to the application.\n' >&2
  fi
  return 1
}

# Collect inventory indexes whose FIELD equals VALUE into RESOLVE_CANDIDATE_*.
_resolve_collect() {
  local field="$1" value="$2" i v
  RESOLVE_CANDIDATE_PATHS=()
  RESOLVE_CANDIDATE_IDS=()
  RESOLVE_CANDIDATE_NAMES=()
  for ((i = 0; i < APP_INV_COUNT; i++)); do
    case "$field" in
      id)    v="${APP_INV_IDS[$i]}" ;;
      id_ci) v="$(_ev_lower "${APP_INV_IDS[$i]}")" ;;
      cask)  v="${APP_INV_CASK_TOKENS[$i]}" ;;
      name)
        if [ "$(normalize_token "${APP_INV_NAMES[$i]}")" = "$value" ] \
           || [ "$(normalize_token "$(basename "${APP_INV_PATHS[$i]}" .app)")" = "$value" ]; then
          v="$value"
        else
          v=""
        fi
        ;;
    esac
    if [ -n "$v" ] && [ "$v" = "$value" ]; then
      RESOLVE_CANDIDATE_PATHS+=("${APP_INV_PATHS[$i]}")
      RESOLVE_CANDIDATE_IDS+=("${APP_INV_IDS[$i]}")
      RESOLVE_CANDIDATE_NAMES+=("${APP_INV_NAMES[$i]}")
    fi
  done
}

resolve_app_target() {
  local target="$1"
  RESOLVED_APP_PATH=""
  RESOLVED_APP_METHOD=""
  RESOLVE_ERROR_CODE=""
  RESOLVE_ERROR_MESSAGE=""
  RESOLVE_CANDIDATE_PATHS=()
  RESOLVE_CANDIDATE_IDS=()
  RESOLVE_CANDIDATE_NAMES=()

  if [ -z "$target" ]; then
    _resolve_fail "not_found" "empty application target"
    return 1
  fi

  # 1. Exact path
  local is_path=0
  case "$target" in
    */*|*.app) is_path=1 ;;
  esac
  if [ "$is_path" -eq 1 ]; then
    if [ ! -e "$target" ]; then
      _resolve_fail "not_found" "no such application path: $target"
      return 1
    fi
    local canon
    canon="$(path_canonicalize "$target" 2>/dev/null || true)"
    if [ -z "$canon" ] || [ ! -d "$canon" ] || [ ! -f "$canon/Contents/Info.plist" ]; then
      _resolve_fail "not_an_app" "not an application bundle (no Contents/Info.plist): $target"
      return 1
    fi
    RESOLVED_APP_PATH="$canon"
    RESOLVED_APP_METHOD="path"
    return 0
  fi

  # 2–4 need the inventory; identity-only depth keeps this fast.
  inventory_scan_apps resolve

  local rule value
  for rule in id id_ci cask name; do
    case "$rule" in
      id)    value="$target" ;;
      id_ci) value="$(_ev_lower "$target")" ;;
      cask)  value="$target" ;;
      name)
        value="$(normalize_token "${target%.app}")"
        ;;
    esac
    [ -n "$value" ] || continue
    _resolve_collect "$rule" "$value"
    case "${#RESOLVE_CANDIDATE_PATHS[@]}" in
      0) continue ;;
      1)
        RESOLVED_APP_PATH="${RESOLVE_CANDIDATE_PATHS[0]}"
        case "$rule" in
          id|id_ci) RESOLVED_APP_METHOD="bundle_id" ;;
          *)        RESOLVED_APP_METHOD="$rule" ;;
        esac
        RESOLVE_CANDIDATE_PATHS=()
        RESOLVE_CANDIDATE_IDS=()
        RESOLVE_CANDIDATE_NAMES=()
        return 0
        ;;
      *)
        local how
        case "$rule" in
          id|id_ci) how="bundle ID" ;;
          cask)     how="Homebrew cask token" ;;
          name)     how="name" ;;
        esac
        _resolve_fail "ambiguous" "ambiguous application target \"$target\" matches ${#RESOLVE_CANDIDATE_PATHS[@]} installed apps by $how:"
        return 1
        ;;
    esac
  done

  local where="standard application locations"
  [ "$APP_ROOTS_EXPLICIT" -eq 1 ] && where="the given application roots"
  _resolve_fail "not_found" "application \"$target\" not found in $where"
  if [ "$APP_INV_COMPLETE" -eq 0 ]; then
    printf '  note: the inventory is incomplete (%s)\n' "$APP_INV_NOTE" >&2
  fi
  return 1
}

# JSON document for a failed resolution (app inspect --json).
_inspect_json_error() {
  local target="$1" i
  printf '{\n'
  printf '  "schema": "mimi.app-inspect/1",\n'
  printf '  "target": "%s",\n' "$(json_escape "$target")"
  printf '  "error": {\n'
  printf '    "code": "%s",\n' "$RESOLVE_ERROR_CODE"
  printf '    "message": "%s",\n' "$(json_escape "$RESOLVE_ERROR_MESSAGE")"
  printf '    "candidates": ['
  for ((i = 0; i < ${#RESOLVE_CANDIDATE_PATHS[@]}; i++)); do
    [ "$i" -gt 0 ] && printf ','
    printf '\n      {"name": "%s", "bundle_id": "%s", "path": "%s"}' \
      "$(json_escape "${RESOLVE_CANDIDATE_NAMES[$i]}")" \
      "$(json_escape "${RESOLVE_CANDIDATE_IDS[$i]}")" \
      "$(json_escape "${RESOLVE_CANDIDATE_PATHS[$i]}")"
  done
  [ "${#RESOLVE_CANDIDATE_PATHS[@]}" -gt 0 ] && printf '\n    '
  printf ']\n'
  printf '  }\n'
  printf '}\n'
}

# ---------------------------------------------------------------------------
# CLI Command: app inspect <target>
# ---------------------------------------------------------------------------

_inspect_print_items() {
  # $1 = class to print
  local want="$1" i tag printed=0
  for ((i = 0; i < EVIDENCE_COUNT; i++)); do
    [ "${EVIDENCE_CLASSES[$i]}" = "$want" ] || continue
    printed=1
    case "${EVIDENCE_CONFIDENCES[$i]}" in
      authoritative) tag="${C_GREEN}[authoritative]${C_RESET}" ;;
      strong)        tag="${C_CYAN}[strong]       ${C_RESET}" ;;
      corroborated)  tag="${C_BLUE}[corroborated] ${C_RESET}" ;;
      weak)          tag="${C_YELLOW}[weak]         ${C_RESET}" ;;
      conflicting)   tag="${C_RED}[conflicting]  ${C_RESET}" ;;
      shared)        tag="${C_RED}[shared/veto]  ${C_RESET}" ;;
      *)             tag="[unknown]      " ;;
    esac
    [ "${EVIDENCE_SYSTEM_LOC[$i]}" -eq 1 ] && tag="${C_YELLOW}[system-loc]   ${C_RESET}"
    printf '  %b %s (%s)\n' "$tag" "${EVIDENCE_PATHS[$i]}" "$(human_kb "${EVIDENCE_SIZES[$i]}")"
    printf '                  %s: %s\n' "${EVIDENCE_ROOTS[$i]}" "${EVIDENCE_REASONS[$i]}"
  done
  return $((1 - printed))
}

mimi_app_inspect() {
  local target="${APP_TARGET:-}"
  if [ -z "$target" ]; then
    die_usage "app inspect requires an application name, bundle ID, cask token, or path"
  fi

  if ! resolve_app_target "$target"; then
    [ "${JSONL_ENABLED:-0}" -eq 1 ] && _inspect_json_error "$target"
    exit "$EXIT_USAGE"
  fi

  # For a path target, inspect the path as given so a symlinked bundle is
  # reported (app_inspect_bundle canonicalises it either way).
  local inspect_path="$RESOLVED_APP_PATH"
  [ "$RESOLVED_APP_METHOD" = "path" ] && inspect_path="${target%/}"

  app_inspect_bundle "$inspect_path" full || {
    printf '%s: error: failed to inspect application bundle at %s\n' "$SCRIPT_NAME" "$RESOLVED_APP_PATH" >&2
    exit "$EXIT_USAGE"
  }

  collect_app_evidence "$APP_INFO_CANONICAL_PATH" "$APP_INFO_NAME" "$APP_INFO_BUNDLE_ID" "$SIGNING_TEAM_ID" "$APP_INFO_EXECUTABLE"

  if [ "${JSONL_ENABLED:-0}" -eq 1 ]; then
    printf '{\n'
    printf '  "schema": "mimi.app-inspect/1",\n'
    printf '  "target": "%s",\n' "$(json_escape "$target")"
    printf '  "resolution": {"method": "%s", "path": "%s"},\n' \
      "$RESOLVED_APP_METHOD" "$(json_escape "$RESOLVED_APP_PATH")"
    if [ "${APP_INV_SCANNED:-0}" -eq 1 ]; then
      printf '  "inventory": '
      inventory_json_object "  "
      printf ',\n'
    else
      printf '  "inventory": null,\n'
    fi
    printf '  "app": {\n'
    printf '    "name": "%s",\n' "$(json_escape "$APP_INFO_NAME")"
    printf '    "bundle_id": "%s",\n' "$(json_escape "$APP_INFO_BUNDLE_ID")"
    printf '    "version": "%s",\n' "$(json_escape "$APP_INFO_VERSION")"
    printf '    "executable": "%s",\n' "$(json_escape "$APP_INFO_EXECUTABLE")"
    printf '    "path": "%s",\n' "$(json_escape "$APP_INFO_CANONICAL_PATH")"
    printf '    "identity": "%s",\n' "$(json_escape "$APP_INFO_IDENTITY")"
    printf '    "source": "%s",\n' "$(json_escape "$APP_INFO_PROVENANCE")"
    printf '    "provenance_facts": %s,\n' "$(_json_string_array "${APP_INFO_PROVENANCE_FACTS[@]:-}")"
    if [ -n "$APP_INFO_CASK_TOKEN" ]; then
      printf '    "cask": {"token": "%s", "method": "%s"},\n' \
        "$(json_escape "$APP_INFO_CASK_TOKEN")" "$APP_INFO_CASK_METHOD"
    else
      printf '    "cask": null,\n'
    fi
    printf '    "pkg_receipts": %s,\n' "$(_json_string_array "${APP_INFO_PKG_IDS[@]:-}")"
    printf '    "is_system": %s,\n' "$(_json_bool "$APP_INFO_IS_SYSTEM")"
    printf '    "eligible": %s,\n' "$(_json_bool "$APP_INFO_ELIGIBLE")"
    if [ -n "$APP_INFO_INELIGIBLE_REASON" ]; then
      printf '    "ineligible_reason": "%s",\n' "$(json_escape "$APP_INFO_INELIGIBLE_REASON")"
    else
      printf '    "ineligible_reason": null,\n'
    fi
    printf '    "identity_warnings": %s,\n' "$(_json_string_array "${APP_INFO_WARNINGS[@]:-}")"
    printf '    "size_kb": %d,\n' "$APP_INFO_SIZE_KB"
    printf '    "architecture": "%s",\n' "$(json_escape "$APP_INFO_ARCH")"
    printf '    "signing": {\n'
    printf '      "status": "%s",\n' "$SIGNING_STATUS"
    printf '      "identifier": "%s",\n' "$(json_escape "$SIGNING_IDENTIFIER")"
    printf '      "team_id": "%s",\n' "$(json_escape "$SIGNING_TEAM_ID")"
    printf '      "authority": "%s"\n' "$(json_escape "$SIGNING_AUTHORITY")"
    printf '    },\n'
    printf '    "nested_helpers": %s,\n' "$(_json_string_array "${APP_INFO_HELPERS[@]:-}")"
    printf '    "xpc_services": %s,\n' "$(_json_string_array "${APP_INFO_XPC[@]:-}")"
    printf '    "extensions": %s,\n' "$(_json_string_array "${APP_INFO_EXTENSIONS[@]:-}")"
    printf '    "login_items": %s,\n' "$(_json_string_array "${APP_INFO_LOGIN_ITEMS[@]:-}")"
    printf '    "bundled_launchd": %s,\n' "$(_json_string_array "${APP_INFO_LAUNCHD[@]:-}")"
    if [ -n "$APP_INFO_UNINSTALLER" ]; then
      printf '    "vendor_uninstaller": "%s"\n' "$(json_escape "$APP_INFO_UNINSTALLER")"
    else
      printf '    "vendor_uninstaller": null\n'
    fi
    printf '  },\n'

    printf '  "remnants": ['
    local i
    for ((i = 0; i < EVIDENCE_COUNT; i++)); do
      [ "$i" -gt 0 ] && printf ','
      printf '\n    {\n'
      printf '      "path": "%s",\n' "$(json_escape "${EVIDENCE_PATHS[$i]}")"
      printf '      "root": "%s",\n' "$(json_escape "${EVIDENCE_ROOTS[$i]}")"
      printf '      "kind": "%s",\n' "${EVIDENCE_KINDS[$i]}"
      printf '      "confidence": "%s",\n' "${EVIDENCE_CONFIDENCES[$i]}"
      printf '      "class": "%s",\n' "${EVIDENCE_CLASSES[$i]}"
      printf '      "selectable": %s,\n' "$(evidence_is_selectable "$i" && printf true || printf false)"
      printf '      "is_shared": %s,\n' "$(_json_bool "${EVIDENCE_SHARED[$i]}")"
      printf '      "is_system_location": %s,\n' "$(_json_bool "${EVIDENCE_SYSTEM_LOC[$i]}")"
      printf '      "size_kb": %d,\n' "${EVIDENCE_SIZES[$i]}"
      printf '      "reason": "%s"\n' "$(json_escape "${EVIDENCE_REASONS[$i]}")"
      printf '    }'
    done
    [ "$EVIDENCE_COUNT" -gt 0 ] && printf '\n  '
    printf '],\n'

    printf '  "notes": %s,\n' "$(_json_string_array "${EVIDENCE_NOTES[@]:-}")"
    printf '  "summary": {\n'
    printf '    "bundle_size_kb": %d,\n' "$APP_INFO_SIZE_KB"
    printf '    "attributable_size_kb": %d,\n' "$EVIDENCE_TOTAL_ATTRIBUTABLE_KB"
    printf '    "review_size_kb": %d,\n' "$EVIDENCE_TOTAL_REVIEW_KB"
    printf '    "retained_size_kb": %d,\n' "$EVIDENCE_TOTAL_RETAINED_KB"
    printf '    "attributable_count": %d,\n' "$EVIDENCE_ATTRIBUTABLE_COUNT"
    printf '    "review_count": %d,\n' "$EVIDENCE_REVIEW_COUNT"
    printf '    "retained_count": %d\n' "$EVIDENCE_RETAINED_COUNT"
    printf '  }\n'
    printf '}\n'
    return 0
  fi

  # Human Output
  printf '%s=== Application Inspection: %s ===%s\n\n' "$C_BOLD" "$APP_INFO_NAME" "$C_RESET"

  printf '  %-20s %s\n' "Bundle Path:" "$APP_INFO_CANONICAL_PATH"
  printf '  %-20s %s (by %s)\n' "Resolved:" "$target" "$RESOLVED_APP_METHOD"
  printf '  %-20s %s\n' "Bundle ID:" "${APP_INFO_BUNDLE_ID:-none}"
  printf '  %-20s %s\n' "Version:" "$APP_INFO_VERSION"
  printf '  %-20s %s\n' "Executable:" "$APP_INFO_EXECUTABLE"
  printf '  %-20s %s\n' "Architecture:" "$APP_INFO_ARCH"
  printf '  %-20s %s\n' "Provenance:" "$APP_INFO_PROVENANCE"
  local fact
  for fact in "${APP_INFO_PROVENANCE_FACTS[@]:-}"; do
    [ -n "$fact" ] && printf '  %-20s - %s\n' "" "$fact"
  done
  if [ "$APP_INFO_IS_SYSTEM" -eq 1 ]; then
    printf '  %-20s %sYes (%s)%s\n' "System Protected:" "$C_RED" "$APP_INFO_SYSTEM_REASON" "$C_RESET"
  else
    printf '  %-20s %sNo%s\n' "System Protected:" "$C_GREEN" "$C_RESET"
  fi
  if [ "$APP_INFO_ELIGIBLE" -eq 1 ]; then
    printf '  %-20s %sYes%s\n' "Eligible:" "$C_GREEN" "$C_RESET"
  else
    printf '  %-20s %sNo — %s%s\n' "Eligible:" "$C_RED" "$APP_INFO_INELIGIBLE_REASON" "$C_RESET"
  fi

  if [ -n "$SIGNING_IDENTIFIER" ] || [ -n "$SIGNING_TEAM_ID" ]; then
    printf '  %-20s %s | ID: %s | Team: %s\n' "Code Signing:" "$SIGNING_STATUS" "${SIGNING_IDENTIFIER:-none}" "${SIGNING_TEAM_ID:-none}"
    [ -n "$SIGNING_AUTHORITY" ] && printf '  %-20s %s\n' "Authority:" "$SIGNING_AUTHORITY"
  else
    printf '  %-20s %s\n' "Code Signing:" "unsigned or unavailable"
  fi
  local w
  for w in "${APP_INFO_WARNINGS[@]:-}"; do
    [ -n "$w" ] && printf '  %-20s %s%s%s\n' "Identity Warning:" "$C_YELLOW" "$w" "$C_RESET"
  done

  printf '  %-20s %s\n' "Bundle Footprint:" "$(human_kb "$APP_INFO_SIZE_KB")"

  if [ -n "$APP_INFO_UNINSTALLER" ]; then
    printf '  %-20s %s%s%s (report-only)\n' "Vendor Uninstaller:" "$C_YELLOW" "$APP_INFO_UNINSTALLER" "$C_RESET"
  fi

  # Nested components
  if [ "${#APP_INFO_HELPERS[@]}" -gt 0 ] || [ "${#APP_INFO_XPC[@]}" -gt 0 ] || [ "${#APP_INFO_LOGIN_ITEMS[@]}" -gt 0 ] \
     || [ "${#APP_INFO_EXTENSIONS[@]}" -gt 0 ] || [ "${#APP_INFO_LAUNCHD[@]}" -gt 0 ]; then
    printf '\n%sNested Components:%s\n' "$C_BOLD" "$C_RESET"
    [ "${#APP_INFO_HELPERS[@]}" -gt 0 ] && printf '  Helpers: %s\n' "${APP_INFO_HELPERS[*]}"
    [ "${#APP_INFO_XPC[@]}" -gt 0 ] && printf '  XPC Services: %s\n' "${APP_INFO_XPC[*]}"
    [ "${#APP_INFO_EXTENSIONS[@]}" -gt 0 ] && printf '  Extensions: %s\n' "${APP_INFO_EXTENSIONS[*]}"
    [ "${#APP_INFO_LOGIN_ITEMS[@]}" -gt 0 ] && printf '  Login Items: %s\n' "${APP_INFO_LOGIN_ITEMS[*]}"
    [ "${#APP_INFO_LAUNCHD[@]}" -gt 0 ] && printf '  Bundled launchd jobs: %s\n' "${APP_INFO_LAUNCHD[*]}"
  fi

  # Attributable remnants — the only selectable class.
  printf '\n%sAttributable User Data (Estimated: %s, %d items):%s\n' \
    "$C_BOLD" "$(human_kb "$EVIDENCE_TOTAL_ATTRIBUTABLE_KB")" "$EVIDENCE_ATTRIBUTABLE_COUNT" "$C_RESET"
  _inspect_print_items attributable || printf '  (no attributable user data found)\n'

  # Weak evidence — shown, explained, never selectable.
  if [ "$EVIDENCE_REVIEW_COUNT" -gt 0 ]; then
    printf '\n%sNeeds Review (weak evidence, never selected automatically: %s, %d items):%s\n' \
      "$C_BOLD" "$(human_kb "$EVIDENCE_TOTAL_REVIEW_KB")" "$EVIDENCE_REVIEW_COUNT" "$C_RESET"
    _inspect_print_items review
  fi

  # Retained & Shared Resources
  if [ "$EVIDENCE_RETAINED_COUNT" -gt 0 ]; then
    printf '\n%sRetained / Shared Resources (Vetoed from Removal: %s, %d items):%s\n' \
      "$C_BOLD" "$(human_kb "$EVIDENCE_TOTAL_RETAINED_KB")" "$EVIDENCE_RETAINED_COUNT" "$C_RESET"
    _inspect_print_items retained
  fi

  local note
  if [ "${#EVIDENCE_NOTES[@]}" -gt 0 ]; then
    printf '\n%sNotes:%s\n' "$C_BOLD" "$C_RESET"
    for note in "${EVIDENCE_NOTES[@]}"; do
      printf '  - %s\n' "$note"
    done
  fi
  if [ "${APP_INV_SCANNED:-0}" -eq 1 ] && [ "$APP_INV_COMPLETE" -eq 0 ]; then
    printf '\n%s[inventory incomplete: %s]%s\n' "$C_YELLOW" "$APP_INV_NOTE" "$C_RESET"
  fi

  printf '\n'
  return 0
}
