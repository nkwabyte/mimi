#!/usr/bin/env bash
#
# lib/apps/uninstall.sh — Reversible user-scope application uninstall (Phase 4).
#
# P4-T01 target resolution and data modes, P4-T03 the uninstall plan,
# P4-T04 apply and verification (through the common plan executor),
# P4-T05 Homebrew cask hand-off. P4-T02 process handling is in process.sh;
# P4-T06 restore is the common `mimi restore` (lib/transaction/quarantine.sh).
#
# Compatible with Bash 3.2+ (no associative arrays).
#
# An uninstall is an ordinary plan:
#
#   resolve target -> collect evidence -> build plan -> save plan (0600)
#     -> preflight the SAVED FILE -> execute through plan_execute_loaded
#
# so it gets the same digest, expiry, host/user, and file-identity checks as
# `mimi apply`, and `--plan-only` lets the plan be reviewed and applied later
# with `mimi apply <file>`. Nothing is deleted: every action is a move into a
# quarantine run that `mimi restore` undoes until `mimi purge`.
#
# Plan categories, in execution order:
#
#   uninstall-launchagent  a user LaunchAgent attributed to the app; stopped
#                          (launchctl bootout gui/<uid>/<Label>) then moved
#   uninstall-app          the application bundle itself
#   uninstall-data         attributable user data (only when data is included)
#   uninstall-retain       operation "retain": evidence the plan must NOT
#                          touch — shared, conflicting, weak, system, or data
#                          kept by the data mode. Verified to survive.
#
# Data modes:
#   --keep-data    bundle and LaunchAgents only; data is retained
#   --purge-data   bundle, LaunchAgents, and all attributable user data
#   (default ask)  asks once at a terminal; without one (or with --yes), data
#                  is kept and the run says how to include it
#
# shellcheck disable=SC2155

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

UNINSTALL_DATA_MODE="${UNINSTALL_DATA_MODE:-ask}"   # keep | purge | ask
UNINSTALL_INCLUDE_DATA=0        # ask-mode decision, made before planning
UNINSTALL_PLAN_ONLY=0           # --plan-only: save the plan, do not apply
UNINSTALL_LAUNCHAGENTS=()       # LaunchAgent plists in the current plan

UNINSTALL_DENY_REASON=""
UNINSTALL_CANONICAL=""

# Set by uninstall_plan_detect from the plan's own actions.
UNINSTALL_PLAN_APP_PATH=""
UNINSTALL_PLAN_APP_NAME=""
UNINSTALL_PLAN_BUNDLE_ID=""
UNINSTALL_LEFTOVER_COUNT=0

# ---------------------------------------------------------------------------
# Bundle authorization
# ---------------------------------------------------------------------------
#
# The general path gate (path_authorize) allows only $HOME and the per-user
# temp folder, which is right for every cleaner. An application bundle lives
# in /Applications, so it needs its own rule — deliberately much narrower
# than adding /Applications as an allowed root:
#
#   * the object itself is a real directory named *.app (not a symlink), with
#     Contents/Info.plist;
#   * its parent is an application root, or a plain vendor folder directly
#     inside one (/Applications/<Vendor>/<App>.app);
#   * it is not on the system volume, not an Apple app, and has a bundle id
#     (app_inspect_bundle's eligibility).
#
# Sets UNINSTALL_CANONICAL on success, UNINSTALL_DENY_REASON on refusal.
uninstall_authorize_bundle() {
  local raw="$1" canon parent grand r cr ok=0
  UNINSTALL_DENY_REASON=""
  UNINSTALL_CANONICAL=""

  case "$raw" in
    /*) ;;
    *) UNINSTALL_DENY_REASON="not an absolute path"; return 1 ;;
  esac
  if path_has_traversal "$raw"; then
    UNINSTALL_DENY_REASON="path traversal"
    return 1
  fi
  canon="$(path_canonicalize "$raw" nofollow 2>/dev/null || true)"
  if [ -z "$canon" ]; then
    UNINSTALL_DENY_REASON="unresolvable"
    return 1
  fi
  if [ -L "$canon" ]; then
    UNINSTALL_DENY_REASON="the bundle is a symbolic link"
    return 1
  fi
  case "$canon" in
    *.app) ;;
    *) UNINSTALL_DENY_REASON="not an .app bundle"; return 1 ;;
  esac
  case "$canon" in
    /System/*) UNINSTALL_DENY_REASON="on the system volume"; return 1 ;;
  esac
  if [ ! -d "$canon" ] || [ ! -f "$canon/Contents/Info.plist" ]; then
    UNINSTALL_DENY_REASON="not an application bundle (no Contents/Info.plist)"
    return 1
  fi

  parent="$(dirname "$canon")"
  grand="$(dirname "$parent")"
  for r in "${APP_SEARCH_ROOTS[@]:-}" "/Applications" "$HOME_DIR/Applications"; do
    [ -n "$r" ] || continue
    cr="$(path_canonicalize "$r" 2>/dev/null || true)"
    [ -n "$cr" ] || continue
    if [ "$parent" = "$cr" ]; then
      ok=1
      break
    fi
    # One vendor folder deep, and that folder must not itself be a bundle.
    if [ "$grand" = "$cr" ] && ! _app_in_bundle_dir "$canon"; then
      ok=1
      break
    fi
  done
  if [ "$ok" != 1 ]; then
    UNINSTALL_DENY_REASON="not inside an application folder"
    return 1
  fi

  # Eligibility, without clobbering a caller's APP_INFO_*: run in a subshell.
  local verdict
  verdict="$(
    app_inspect_bundle "$canon" resolve > /dev/null 2>&1 || { printf 'uninspectable'; exit 0; }
    if [ "$APP_INFO_ELIGIBLE" != 1 ]; then printf '%s' "$APP_INFO_INELIGIBLE_REASON"; fi
  )"
  if [ -n "$verdict" ]; then
    UNINSTALL_DENY_REASON="$verdict"
    return 1
  fi

  UNINSTALL_CANONICAL="$canon"
  return 0
}

# ---------------------------------------------------------------------------
# P4-T01: target resolution
# ---------------------------------------------------------------------------
# Wraps resolve_app_target (inspect.sh) and refuses what must not be removed.
# Sets RESOLVED_APP_PATH and APP_INFO_*.

uninstall_resolve_target() {
  local target="$1"

  resolve_app_target "$target" || return 1

  if [ -z "$RESOLVED_APP_PATH" ]; then
    err "uninstall: failed to resolve target: $target"
    return 1
  fi

  local ident_before
  ident_before="$(path_identity "$RESOLVED_APP_PATH" 2>/dev/null || echo "")"

  app_inspect_bundle "$RESOLVED_APP_PATH" || {
    err "uninstall: cannot inspect bundle: $RESOLVED_APP_PATH"
    return 1
  }

  # Guard: refuse system/Apple apps.
  if [ "${APP_INFO_IS_SYSTEM:-0}" -eq 1 ]; then
    err "uninstall: \"$APP_INFO_NAME\" is a macOS system application protected by"
    err "           System Integrity Protection. mimi will not touch it."
    return 1
  fi

  # Guard: ambiguous identity (no bundle id, missing Info.plist, signature
  # identifier that disagrees with the bundle id). See app_inspect_bundle.
  if [ "${APP_INFO_ELIGIBLE:-1}" -ne 1 ]; then
    err "uninstall: refusing \"$APP_INFO_NAME\": ${APP_INFO_INELIGIBLE_REASON:-identity could not be established}"
    return 1
  fi

  # Guard: the bundle was replaced between resolution and inspection.
  if [ -n "$ident_before" ] && [ -n "$APP_INFO_IDENTITY" ] && [ "$ident_before" != "$APP_INFO_IDENTITY" ]; then
    err "uninstall: application identity changed while it was being inspected."
    err "           Run 'mimi app inspect \"$target\"' again and retry."
    return 1
  fi

  if ! uninstall_authorize_bundle "$APP_INFO_CANONICAL_PATH"; then
    err "uninstall: refusing \"$APP_INFO_NAME\": $UNINSTALL_DENY_REASON"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# P4-T02: running processes, before anything is moved
# ---------------------------------------------------------------------------
# Returns 0 when nothing of the app is running (any more), EXIT_CANCELLED when
# the user (or the lack of a terminal) declines force-quitting, 1 on failure.

uninstall_handle_processes() {
  local bundle_id="$1" app_path="$2" app_name="$3"

  app_process_list_pids "$bundle_id" "$app_path" "$app_name"

  if [ "$PROC_COUNT" -eq 0 ]; then
    return 0
  fi

  say ""
  say "${C_YELLOW}\"$app_name\" is running ($PROC_COUNT process(es)).${C_RESET}"

  # First: a normal quit, which lets the app ask to save documents.
  if app_process_request_quit "$bundle_id"; then
    say "  Asked $app_name to quit normally — waiting up to 10 seconds…"
    if app_process_wait_gone "$bundle_id" "$app_path" "$app_name" 10; then
      ok "  $app_name quit."
      return 0
    fi
  fi

  app_process_list_pids "$bundle_id" "$app_path" "$app_name"
  if [ "$PROC_COUNT" -eq 0 ]; then
    return 0
  fi

  # Force-quitting is risky: --yes cannot approve it.
  if ! app_process_confirm_terminate "$PROC_COUNT" "$app_name"; then
    warn "uninstall cancelled — \"$app_name\" is still running. Quit it and run the uninstall again."
    return "$EXIT_CANCELLED"
  fi

  if ! app_process_force_quit "$bundle_id" "$app_path" "$app_name"; then
    err "uninstall: could not stop every process of \"$app_name\"."
    err "           Quit it manually and retry."
    return 1
  fi

  ok "  Processes stopped."
  return 0
}

# ---------------------------------------------------------------------------
# P4-T03: the uninstall plan
# ---------------------------------------------------------------------------

# Evidence strings are stored in the plan file and read back verbatim, so they
# must not contain the item separator or characters the plan reader keeps
# escaped.
_uninstall_evid() {
  local e="$1"
  e="${e//::/:}"
  e="${e//\"/\'}"
  e="${e//\\//}"
  printf '%s' "$e"
}

# A path the plan file can carry losslessly.
_uninstall_path_ok() {
  case "$1" in
    *::* | *\"* | *\\* | *$'\n'*) return 1 ;;
  esac
  return 0
}

# True when user data goes into this plan.
uninstall_data_included() {
  case "$UNINSTALL_DATA_MODE" in
    purge) return 0 ;;
    keep)  return 1 ;;
    *)     [ "$UNINSTALL_INCLUDE_DATA" = 1 ] ;;
  esac
}

# Fills PLAN_CANDIDATES from the current APP_INFO_* and EVIDENCE_* state.
# Call plan_build afterwards to turn candidates into PLAN_ACTIONS.
uninstall_build_plan() {
  local app_path="$1" app_name="$2" bundle_id="$3"
  UNINSTALL_LAUNCHAGENTS=()
  PLAN_CANDIDATES=()

  local canon_app i ev_path ev_root ev_conf ev_reason ev_ident ev_bytes ev_risk
  canon_app="$(path_canonicalize "$app_path" nofollow 2>/dev/null || printf '%s' "$app_path")"

  # 1. User LaunchAgents first, so nothing relaunches the app mid-way.
  for ((i = 0; i < EVIDENCE_COUNT; i++)); do
    [ "${EVIDENCE_ROOTS[$i]}" = "LaunchAgents" ] || continue
    evidence_is_selectable "$i" || continue
    ev_path="${EVIDENCE_PATHS[$i]}"
    _uninstall_path_ok "$ev_path" || continue
    UNINSTALL_LAUNCHAGENTS+=("$ev_path")
    ev_ident="$(path_identity "$ev_path" 2>/dev/null || echo "unknown")"
    plan_candidate_add "uninstall-launchagent" "quarantine" \
      "$ev_path" "$ev_ident" "$(( ${EVIDENCE_SIZES[$i]:-0} * 1024 ))" "moderate" \
      "$(_uninstall_evid "LaunchAgent: ${EVIDENCE_REASONS[$i]} [${EVIDENCE_CONFIDENCES[$i]}]; stopped before it is moved")"
  done

  # 2. The application bundle.
  local bundle_ident
  bundle_ident="$(path_identity "$canon_app" 2>/dev/null || echo "unknown")"
  plan_candidate_add "uninstall-app" "quarantine" \
    "$canon_app" "$bundle_ident" "$(( ${APP_INFO_SIZE_KB:-0} * 1024 ))" "moderate" \
    "$(_uninstall_evid "app bundle: $app_name ($bundle_id)")"

  # 3. Attributable user data, or 4. retain it.
  for ((i = 0; i < EVIDENCE_COUNT; i++)); do
    ev_path="${EVIDENCE_PATHS[$i]}"
    ev_root="${EVIDENCE_ROOTS[$i]}"
    ev_conf="${EVIDENCE_CONFIDENCES[$i]}"
    ev_reason="${EVIDENCE_REASONS[$i]}"
    [ "$ev_root" = "LaunchAgents" ] && evidence_is_selectable "$i" && continue
    _uninstall_path_ok "$ev_path" || continue
    ev_ident="$(path_identity "$ev_path" 2>/dev/null || echo "unknown")"

    if evidence_is_selectable "$i" && uninstall_data_included; then
      ev_bytes=$(( ${EVIDENCE_SIZES[$i]:-0} * 1024 ))
      case "$ev_conf" in
        authoritative|strong) ev_risk="safe" ;;
        *)                    ev_risk="moderate" ;;
      esac
      plan_candidate_add "uninstall-data" "quarantine" \
        "$ev_path" "$ev_ident" "$ev_bytes" "$ev_risk" \
        "$(_uninstall_evid "${ev_root}: ${ev_reason} [${ev_conf}]")"
    else
      local why
      if evidence_is_selectable "$i"; then
        why="kept: user data is not part of this uninstall (--purge-data includes it)"
      else
        case "${EVIDENCE_CLASSES[$i]}" in
          review) why="kept: weak evidence, never removed automatically" ;;
          *)      why="kept: ${ev_conf} / shared or system resource" ;;
        esac
      fi
      plan_candidate_add "uninstall-retain" "retain" \
        "$ev_path" "$ev_ident" 0 "safe" \
        "$(_uninstall_evid "${why} — ${ev_root}: ${ev_reason}")"
    fi
  done
}

uninstall_print_plan() {
  local app_name="$1"
  printf '\n%s=== Uninstall Plan: %s ===%s\n' "$C_BOLD" "$app_name" "$C_RESET"

  local total_bytes=0 total_actions=0 kept=0
  local item cat op p bytes risk evid tag

  printf '\n%sMoved to quarantine (restorable until purge):%s\n' "$C_BOLD" "$C_RESET"
  for item in "${PLAN_ACTIONS[@]}"; do
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    [ "$op" = "retain" ] && { kept=$((kept + 1)); continue; }
    p="${item#*::*::*::}"; p="${p%%::*}"
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    evid="${item##*::}"
    total_bytes=$((total_bytes + bytes))
    total_actions=$((total_actions + 1))
    case "$risk" in
      safe)     tag="${C_GREEN}[safe]    ${C_RESET}" ;;
      moderate) tag="${C_YELLOW}[moderate]${C_RESET}" ;;
      *)        tag="${C_RED}[$risk]${C_RESET}" ;;
    esac
    printf '  %b %s (%s)\n' "$tag" "$p" "$(human_kb "$((bytes / 1024))")"
    printf '             %s\n' "$evid"
  done

  if [ "$kept" -gt 0 ]; then
    printf '\n%sKept (verified to survive the uninstall):%s\n' "$C_BOLD" "$C_RESET"
    for item in "${PLAN_ACTIONS[@]}"; do
      op="${item#*::*::}"; op="${op%%::*}"
      [ "$op" = "retain" ] || continue
      p="${item#*::*::*::}"; p="${p%%::*}"
      evid="${item##*::}"
      printf '  %s[kept]%s     %s\n' "$C_DIM" "$C_RESET" "$p"
      printf '             %s\n' "$evid"
    done
  fi

  printf '\n  Total: %d item(s) to quarantine, estimated %s; %d item(s) kept.\n' \
    "$total_actions" "$(human_kb "$((total_bytes / 1024))")" "$kept"
  printf '  Nothing is deleted: %s restore <run-id> undoes it until %s purge <run-id>.\n\n' \
    "$SCRIPT_NAME" "$SCRIPT_NAME"
}

# ---------------------------------------------------------------------------
# P4-T04: hooks used by plan_execute_loaded
# ---------------------------------------------------------------------------

# True when the loaded plan is an uninstall. Sets UNINSTALL_PLAN_* from the
# plan's own uninstall-app action — so `mimi apply <uninstall plan>` behaves
# exactly like the uninstall that wrote it.
uninstall_plan_detect() {
  UNINSTALL_PLAN_APP_PATH=""
  UNINSTALL_PLAN_APP_NAME=""
  UNINSTALL_PLAN_BUNDLE_ID=""
  local item cat p evid rest
  for item in "${PLAN_ACTIONS[@]:-}"; do
    [ -n "$item" ] || continue
    cat="${item#*::}"; cat="${cat%%::*}"
    [ "$cat" = "uninstall-app" ] || continue
    p="${item#*::*::*::}"; p="${p%%::*}"
    evid="${item##*::}"
    UNINSTALL_PLAN_APP_PATH="$p"
    # "app bundle: <name> (<bundle id>)"
    rest="${evid#app bundle: }"
    UNINSTALL_PLAN_BUNDLE_ID="${rest##*(}"
    UNINSTALL_PLAN_BUNDLE_ID="${UNINSTALL_PLAN_BUNDLE_ID%)}"
    UNINSTALL_PLAN_APP_NAME="${rest% (*}"
    [ -n "$UNINSTALL_PLAN_APP_NAME" ] || UNINSTALL_PLAN_APP_NAME="$(basename "$p" .app)"
    return 0
  done
  return 1
}

# After the actions ran: the app is gone, every retained item survived, and
# anything attributable that is still present is reported as a leftover.
# Returns non-zero when the uninstall is incomplete.
uninstall_verify_after_apply() {
  local rc=0 item op cat p ident retained=0 missing=0

  section "Uninstall verification"

  if [ -e "$UNINSTALL_PLAN_APP_PATH" ] || [ -L "$UNINSTALL_PLAN_APP_PATH" ]; then
    err "the application bundle is still present: $UNINSTALL_PLAN_APP_PATH"
    rc=1
  else
    ok "application removed: $UNINSTALL_PLAN_APP_PATH"
  fi

  for item in "${PLAN_ACTIONS[@]}"; do
    op="${item#*::*::}"; op="${op%%::*}"
    [ "$op" = "retain" ] || continue
    p="${item#*::*::*::}"; p="${p%%::*}"
    ident="${item#*::*::*::*::}"; ident="${ident%%::*}"
    if [ -e "$p" ] || [ -L "$p" ]; then
      retained=$((retained + 1))
    else
      missing=$((missing + 1))
      warn "a kept item is no longer present (removed by something else?): $p"
    fi
  done
  if [ "$retained" -gt 0 ]; then
    ok "$retained kept item(s) verified intact (shared, weak, system, or kept data)"
  fi

  # Leftovers: attributable evidence that exists now but is neither in the
  # plan's quarantine set nor retained — e.g. recreated by a helper that was
  # still running, or created after the plan was written.
  UNINSTALL_LEFTOVER_COUNT=0
  collect_app_evidence "$UNINSTALL_PLAN_APP_PATH" "$UNINSTALL_PLAN_APP_NAME" "$UNINSTALL_PLAN_BUNDLE_ID" "" "" > /dev/null 2>&1 || true
  local i ep how
  for ((i = 0; i < EVIDENCE_COUNT; i++)); do
    evidence_is_selectable "$i" || continue
    ep="${EVIDENCE_PATHS[$i]}"
    how="new since the plan was made"
    for item in "${PLAN_ACTIONS[@]}"; do
      case "$item" in
        *"::retain::$ep::"*) how="kept"; break ;;
        *"::quarantine::$ep::"*) how="could not be moved"; break ;;
      esac
    done
    [ "$how" = "kept" ] && continue
    UNINSTALL_LEFTOVER_COUNT=$((UNINSTALL_LEFTOVER_COUNT + 1))
    warn "leftover still present ($how): $ep"
  done
  if [ "$UNINSTALL_LEFTOVER_COUNT" -gt 0 ]; then
    warn "$UNINSTALL_LEFTOVER_COUNT leftover(s) remain; run 'mimi app inspect $UNINSTALL_PLAN_BUNDLE_ID' for details"
    rc=1
  fi

  if [ "${#UNINSTALL_LAUNCHAGENTS[@]}" -gt 0 ] || _uninstall_plan_has_category "uninstall-launchagent"; then
    info "LaunchAgents were stopped and moved. If you restore this run, they are not"
    info "restarted until you log out and in again."
  fi

  return "$rc"
}

_uninstall_plan_has_category() {
  local want="$1" item cat
  for item in "${PLAN_ACTIONS[@]:-}"; do
    cat="${item#*::}"; cat="${cat%%::*}"
    [ "$cat" = "$want" ] && return 0
  done
  return 1
}

# Save the in-memory plan, preflight the saved file, and execute it. The
# single apply path for an uninstall; used by mimi_app_uninstall and tests.
uninstall_apply() {
  local plan_file="${PLANS_DIR}/${PLAN_ID}.json"
  mkdir -p "$PLANS_DIR" || return "$EXIT_FAILURE"
  if ! plan_save "$plan_file"; then
    err "uninstall: could not save the plan to $plan_file"
    return "$EXIT_FAILURE"
  fi
  UNINSTALL_PLAN_FILE="$plan_file"
  if ! plan_preflight "$plan_file"; then
    err "uninstall: plan preflight failed; nothing was moved"
    return "$EXIT_USAGE"
  fi
  plan_execute_loaded
}

# ---------------------------------------------------------------------------
# P4-T05: Homebrew cask hand-off
# ---------------------------------------------------------------------------

# Paths listed in the recorded cask definition's `zap` stanza, one per line,
# with ~ expanded. Empty when there is no definition or no zap stanza.
uninstall_cask_zap_paths() {
  local token="$1" cr def
  while IFS= read -r cr; do
    [ -n "$cr" ] && [ -d "$cr/$token" ] || continue
    for def in "$cr/$token"/.metadata/*/*/Casks/"$token".json "$cr/$token"/.metadata/*/*/Casks/"$token".rb; do
      [ -f "$def" ] || continue
      case "$def" in
        *.json)
          # {"zap":[{"trash":["~/Library/...", ...], "rmdir": [...]}]}
          awk 'BEGIN{RS="\"zap\""} NR==2 { n=split($0, a, "\""); for (i=1;i<=n;i++) if (a[i] ~ /^[~\/]/) print a[i] }' "$def"
          ;;
        *.rb)
          awk '/^[[:space:]]*zap[[:space:]]/ {z=1} z { n=split($0, a, "\""); for (i=1;i<=n;i++) if (a[i] ~ /^[~\/]/) print a[i] } z && /^[[:space:]]*end[[:space:]]*$/ {exit}' "$def"
          ;;
      esac
      return 0
    done
  done < <(app_caskroom_dirs) | sed "s|^~|$HOME_DIR|" | awk '!seen[$0]++'
}

uninstall_cask_delegate() {
  local target="$1" zap="${UNINSTALL_ZAP:-0}"

  if [ "$APP_INFO_PROVENANCE" != "cask" ] && [ -z "${APP_INFO_CASK_TOKEN:-}" ]; then
    if [ "$zap" = 1 ]; then
      err "uninstall: --zap is only applicable to applications installed via Homebrew Cask."
    else
      err "uninstall: --cask: \"$APP_INFO_NAME\" was not installed by Homebrew Cask."
    fi
    return "$EXIT_USAGE"
  fi
  local token="$APP_INFO_CASK_TOKEN"

  if ! command -v brew > /dev/null 2>&1; then
    err "uninstall: Homebrew (brew) is not available to hand the uninstall to."
    return "$EXIT_FAILURE"
  fi
  # Exact check: brew must itself report the cask as installed.
  if ! brew list --cask --versions "$token" > /dev/null 2>&1; then
    err "uninstall: brew does not list '$token' as an installed cask; refusing to guess."
    return "$EXIT_USAGE"
  fi

  local -a brew_cmd=("brew" "uninstall" "--cask")
  [ "$zap" = 1 ] && brew_cmd+=("--zap")
  brew_cmd+=("$token")

  say ""
  section "Homebrew Cask Delegation"
  say "  Cask token: ${C_BOLD}$token${C_RESET} ($APP_INFO_CASK_METHOD match)"
  say "  Command:    ${C_BOLD}${brew_cmd[*]}${C_RESET}"
  say "  Homebrew removes: $APP_INFO_CANONICAL_PATH"
  if [ "$zap" = 1 ]; then
    say "  Mode:       ${C_RED}--zap${C_RESET} — also removes the files the cask lists in its zap stanza."
    warn "  Homebrew deletes these directly; mimi cannot quarantine or restore them."
    local zp shared=0 listed=0
    while IFS= read -r zp; do
      [ -n "$zp" ] || continue
      listed=$((listed + 1))
      case "$zp" in
        */Group\ Containers/*)
          warn "    [shared] $zp  (App Group container: may be used by other apps)"
          shared=$((shared + 1)) ;;
        *)
          local vend="${zp#"$HOME_DIR/Library/Application Support/"}"
          if [ "$vend" != "$zp" ] && is_shared_vendor_token "${vend%%/*}" && [ "${vend%%/*}" = "$vend" ]; then
            warn "    [shared] $zp  (whole vendor folder)"
            shared=$((shared + 1))
          else
            say "             $zp"
          fi ;;
      esac
    done < <(uninstall_cask_zap_paths "$token")
    if [ "$listed" = 0 ]; then
      warn "  The recorded cask definition lists no zap paths mimi can preview; Homebrew"
      warn "  may still remove files it defines elsewhere."
    elif [ "$shared" -gt 0 ]; then
      warn "  $shared zap path(s) look shared with other apps."
    fi
  else
    say "  Mode:       standard cask uninstall (app bundle and cask artifacts)"
  fi

  local gate_rc=0
  confirm "Hand the uninstall of \"$APP_INFO_NAME\" to Homebrew now?" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    [ "$gate_rc" = 2 ] && err "no terminal to confirm on: pass --yes to approve"
    warn "uninstall cancelled"
    history_record "cask-uninstall" "cancelled" "app=$APP_INFO_NAME" "token=$token" "zap=$zap"
    return "$EXIT_CANCELLED"
  fi

  say "Running: ${brew_cmd[*]}"
  local brew_rc=0
  "${brew_cmd[@]}" >> "$LOG_FILE" 2>&1 || brew_rc=$?

  local present=0
  [ -e "$APP_INFO_CANONICAL_PATH" ] && present=1
  history_record "cask-uninstall" "$([ "$brew_rc" = 0 ] && echo ok || echo failed)" \
    "app=$APP_INFO_NAME" "bundle_id=$APP_INFO_BUNDLE_ID" "token=$token" "zap=$zap" \
    "command=${brew_cmd[*]}" "exit=$brew_rc" "bundle_still_present=$present"

  if [ "$brew_rc" -eq 0 ]; then
    ok "Successfully uninstalled cask: $token"
    [ "$present" = 1 ] && warn "the application bundle is still present: $APP_INFO_CANONICAL_PATH"
    info "Homebrew removals are not in mimi's quarantine and cannot be restored by mimi."
    return "$EXIT_OK"
  fi
  err "Homebrew cask uninstall failed with exit code $brew_rc (see $LOG_FILE)"
  return "$EXIT_FAILURE"
}

# ---------------------------------------------------------------------------
# P5-T01: vendor uninstaller hand-off
# ---------------------------------------------------------------------------
#
# A vendor uninstaller is third-party code that may remove system files with
# administrator rights, outside mimi's quarantine. mimi only ever LAUNCHES
# one, and only when every check holds:
#
#   * it is the uninstaller app_detect_uninstaller found for this app —
#     inside the bundle, or beside it in the app's own vendor folder;
#   * it is an application bundle (Contents/Info.plist). Scripts, command
#     files, bare executables, and .pkg files are never run: they are shown
#     so a person can read them first;
#   * it is code-signed with the SAME developer Team ID as the app, so a
#     dropped-in "Uninstall.app" from someone else is refused.
#
# It is launched with `open -W -n <path>` (its own UI, its own password
# prompt), never through a shell string, and only after an irreversible-class
# confirmation (typed at a terminal, or --force-risky vendor-uninstaller).
#
# Sets VENDOR_UNINSTALLER_OK (1/0), VENDOR_UNINSTALLER_REASON,
# VENDOR_UNINSTALLER_TEAM.
VENDOR_UNINSTALLER_OK=0
VENDOR_UNINSTALLER_REASON=""
VENDOR_UNINSTALLER_TEAM=""

uninstall_vendor_check() {
  local app_path="$1" un="$2" app_team="$3"
  VENDOR_UNINSTALLER_OK=0
  VENDOR_UNINSTALLER_REASON=""
  VENDOR_UNINSTALLER_TEAM=""

  if [ -z "$un" ]; then
    VENDOR_UNINSTALLER_REASON="no vendor uninstaller found"
    return 1
  fi
  local canon app_canon parent
  canon="$(path_canonicalize "$un" nofollow 2>/dev/null || true)"
  app_canon="$(path_canonicalize "$app_path" 2>/dev/null || true)"
  parent="$(dirname "$app_canon")"
  if [ -z "$canon" ] || [ -L "$canon" ]; then
    VENDOR_UNINSTALLER_REASON="the uninstaller path is a symbolic link or unresolvable"
    return 1
  fi
  if ! path_contains "$app_canon" "$canon" && [ "$(dirname "$canon")" != "$parent" ]; then
    VENDOR_UNINSTALLER_REASON="not inside the app or its vendor folder"
    return 1
  fi
  case "$canon" in
    *.app) ;;
    *)
      VENDOR_UNINSTALLER_REASON="not an application bundle; mimi never runs scripts or packages — read it, then run it yourself if you trust it"
      return 1
      ;;
  esac
  if [ ! -d "$canon" ] || [ ! -f "$canon/Contents/Info.plist" ]; then
    VENDOR_UNINSTALLER_REASON="not an application bundle (no Contents/Info.plist)"
    return 1
  fi
  if [ -z "$app_team" ]; then
    VENDOR_UNINSTALLER_REASON="the app has no developer Team ID to match the uninstaller against"
    return 1
  fi
  # Signing of the uninstaller, without disturbing the app's SIGNING_* state.
  local s_id="$SIGNING_IDENTIFIER" s_team="$SIGNING_TEAM_ID" s_auth="$SIGNING_AUTHORITY" s_status="$SIGNING_STATUS"
  app_detect_signing "$canon"
  VENDOR_UNINSTALLER_TEAM="$SIGNING_TEAM_ID"
  local u_status="$SIGNING_STATUS"
  SIGNING_IDENTIFIER="$s_id" SIGNING_TEAM_ID="$s_team" SIGNING_AUTHORITY="$s_auth" SIGNING_STATUS="$s_status"
  if [ "$u_status" != "signed" ] || [ -z "$VENDOR_UNINSTALLER_TEAM" ]; then
    VENDOR_UNINSTALLER_REASON="the uninstaller is not signed with a developer Team ID"
    return 1
  fi
  if [ "$VENDOR_UNINSTALLER_TEAM" != "$app_team" ]; then
    VENDOR_UNINSTALLER_REASON="signed by Team ID $VENDOR_UNINSTALLER_TEAM, but the app is signed by $app_team"
    return 1
  fi
  VENDOR_UNINSTALLER_OK=1
  VENDOR_UNINSTALLER_REASON="signed by the app's own developer (Team ID $app_team)"
  return 0
}

uninstall_vendor_handoff() {
  local un="$APP_INFO_UNINSTALLER"
  section "Vendor uninstaller"
  if ! uninstall_vendor_check "$APP_INFO_CANONICAL_PATH" "$un" "$SIGNING_TEAM_ID"; then
    err "uninstall: will not launch the vendor uninstaller: $VENDOR_UNINSTALLER_REASON"
    [ -n "$un" ] && info "  Found at: $un"
    history_record "vendor-uninstaller" "refused" "app=$APP_INFO_NAME" "bundle_id=$APP_INFO_BUNDLE_ID" \
      "uninstaller=$un" "reason=$VENDOR_UNINSTALLER_REASON"
    return "$EXIT_USAGE"
  fi

  say "  Uninstaller: ${C_BOLD}$un${C_RESET}"
  say "  Verified:    $VENDOR_UNINSTALLER_REASON"
  say "  Command:     ${C_BOLD}open -W -n \"$un\"${C_RESET}"
  warn "  This runs the vendor's own code. It may ask for your administrator password"
  warn "  and remove system files. mimi cannot quarantine or restore what it removes."

  if ! confirm_action_ok vendor-uninstaller "Launch the vendor uninstaller for \"$APP_INFO_NAME\"?"; then
    history_record "vendor-uninstaller" "cancelled" "app=$APP_INFO_NAME" "uninstaller=$un"
    return "$EXIT_CANCELLED"
  fi

  local rc=0
  open -W -n "$un" >> "$LOG_FILE" 2>&1 || rc=$?
  local present=0
  [ -e "$APP_INFO_CANONICAL_PATH" ] && present=1
  history_record "vendor-uninstaller" "$([ "$rc" = 0 ] && echo ok || echo failed)" \
    "app=$APP_INFO_NAME" "bundle_id=$APP_INFO_BUNDLE_ID" "uninstaller=$un" \
    "exit=$rc" "bundle_still_present=$present"
  if [ "$rc" != 0 ]; then
    err "the vendor uninstaller exited with status $rc"
    return "$EXIT_FAILURE"
  fi
  if [ "$present" = 1 ]; then
    warn "the uninstaller finished but the app is still at $APP_INFO_CANONICAL_PATH"
    info "you can remove it with: $SCRIPT_NAME app uninstall \"$APP_INFO_CANONICAL_PATH\""
  else
    ok "the vendor uninstaller removed $APP_INFO_NAME"
  fi
  info "To review anything it left behind: $SCRIPT_NAME scan --only orphans --remove-orphans"
  return "$EXIT_OK"
}

# ---------------------------------------------------------------------------
# P5-T05: system scope — request for the root tool (option B, DEC-061)
# ---------------------------------------------------------------------------
#
# mimi never runs as root and never calls sudo. For system items it asks
# libexec/mimi-root-apply (as the user, read-only) which items are
# attributable to the app, writes a request that SELECTS those candidate ids,
# and prints the sudo command. The root tool re-derives everything itself.

UNINSTALL_SYSTEM="${UNINSTALL_SYSTEM:-0}"
SYSTEM_REQUESTS_DIR="$CONFIG_DIR/system-requests"

# The copy bundled with this installation (owned by whoever installed mimi).
mimi_root_tool_bundled() {
  local here
  here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || return 1
  [ -x "$here/libexec/mimi-root-apply" ] || return 1
  printf '%s/libexec/mimi-root-apply' "$here"
}

# The root-owned copy `sudo mimi-root-apply --install` puts in place.
mimi_root_tool_hardened() {
  local prefix=""
  [ "${MIMI_ROOT_TEST:-0}" = 1 ] && prefix="${MIMI_ROOT_PREFIX:-}"
  printf '%s/usr/local/libexec/mimi/mimi-root-apply' "$prefix"
}

# Expected owner of a trusted copy: root, or the current user when the
# root tool is running against a fixture (MIMI_ROOT_TEST).
_root_tool_expected_owner() {
  if [ "${MIMI_ROOT_TEST:-0}" = 1 ]; then
    id -u
  else
    printf '0'
  fi
}

# True when NODE is a non-symlink owned by the expected owner and not
# group- or world-writable.
_root_tool_node_ok() {
  local node="$1" expected="$2" owner mode
  [ -e "$node" ] && [ ! -L "$node" ] || return 1
  owner="$(stat -f '%u' "$node" 2>/dev/null)" || return 1
  mode="$(stat -f '%Lp' "$node" 2>/dev/null)" || return 1
  [ "$owner" = "$expected" ] || return 1
  [ $((8#$mode & 022)) -eq 0 ] || return 1
}

# True when PATH is a regular executable whose entire parent chain, down to
# / (or the test prefix), is owned by the expected owner and not writable
# by group or other. A symlink anywhere in that chain fails.
_root_tool_trusted() {
  local path="$1" expected dir stop
  expected="$(_root_tool_expected_owner)"
  [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ] || return 1
  _root_tool_node_ok "$path" "$expected" || return 1
  if [ "${MIMI_ROOT_TEST:-0}" = 1 ] && [ -n "${MIMI_ROOT_PREFIX:-}" ]; then
    stop="${MIMI_ROOT_PREFIX%/}"
  else
    stop="/"
  fi
  dir="$(dirname "$path")"
  while [ -n "$dir" ] && [ "$dir" != "$stop" ] && [ "$dir" != "/" ]; do
    _root_tool_node_ok "$dir" "$expected" || return 1
    dir="$(dirname "$dir")"
  done
  if [ "$stop" != "/" ]; then
    _root_tool_node_ok "$stop" "$expected" || return 1
  fi
  return 0
}

# The only path that may be passed to sudo: the hardened copy, and only
# while it is byte-identical to this installation and trusted. Never the
# bundled file. Sets ROOT_TOOL_NOTE when it refuses.
ROOT_TOOL_NOTE=""
mimi_root_tool() {
  local bundled hardened
  ROOT_TOOL_NOTE=""
  bundled="$(mimi_root_tool_bundled)" || return 1
  hardened="$(mimi_root_tool_hardened)"
  if [ -e "$hardened" ] || [ -L "$hardened" ]; then
    if [ -L "$hardened" ] || [ ! -f "$hardened" ] || ! cmp -s "$bundled" "$hardened"; then
      ROOT_TOOL_NOTE="The copy at $hardened is out of date or not the file this mimi ships. Update it with: sudo \"$bundled\" --install"
      return 1
    fi
    if ! _root_tool_trusted "$hardened"; then
      ROOT_TOOL_NOTE="The copy at $hardened is not a trusted root-owned file. Its owner, mode, or a parent directory would let another user change what sudo runs. Reinstall with: sudo \"$bundled\" --install"
      return 1
    fi
    printf '%s' "$hardened"
    return 0
  fi
  ROOT_TOOL_NOTE="No trusted root-owned copy is installed. Once, install one with: sudo \"$bundled\" --install"
  return 1
}

# True for something shaped like a bundle id (com.vendor.app).
_looks_like_bundle_id_target() {
  { [ -e "$1" ] || [ -L "$1" ]; } && return 1
  case "$1" in
    */*|*' '*) return 1 ;;
    *.*.*) return 0 ;;
  esac
  return 1
}

uninstall_system_request() {
  local target="$1" bid="" bundled tool listing req n=0
  # Candidate listing is read-only and runs as the user. The bundled script
  # is fine for that. It is never the program named after sudo.
  bundled="$(mimi_root_tool_bundled)" || { err "libexec/mimi-root-apply is missing from this installation"; return "$EXIT_FAILURE"; }

  # The app may already be gone: a bundle id is enough for system cleanup.
  if _looks_like_bundle_id_target "$target"; then
    bid="$target"
  else
    uninstall_resolve_target "$target" || return "$EXIT_USAGE"
    bid="$APP_INFO_BUNDLE_ID"
  fi

  section "System items for $bid"
  "$bundled" --candidates "$bid" || return "$EXIT_USAGE"
  listing="$("$bundled" --candidates "$bid" --tsv)" || return "$EXIT_USAGE"

  local -a ids=()
  local id kind path label reason
  while IFS=$'\t' read -r id kind path label reason; do
    case "$id" in sys-*) ids+=("$id"); n=$((n + 1)) ;; esac
  done <<< "$listing"
  if [ "$n" -eq 0 ]; then
    info "Nothing in system scope is attributable to $bid; no request written."
    return "$EXIT_OK"
  fi

  mkdir -p "$SYSTEM_REQUESTS_DIR" && chmod 0700 "$SYSTEM_REQUESTS_DIR" 2>/dev/null
  req="$SYSTEM_REQUESTS_DIR/$(date +%Y%m%d-%H%M%S)-$$.request"
  (
    umask 077
    {
      printf 'mimi-root-request v1\n'
      printf 'bundle_id=%s\n' "$bid"
      printf 'created=%s\n' "$(json_now_iso)"
      for id in "${ids[@]}"; do printf 'select=%s\n' "$id"; done
    } > "$req"
  ) || { err "could not write $req"; return "$EXIT_FAILURE"; }

  history_record "system-request" "written" "bundle_id=$bid" "items=$n" "request=$req"

  say ""
  say "Request written: $req (valid for 1 hour)"
  if tool="$(mimi_root_tool)"; then
    say "To stop these jobs and move the $n item(s) to a root-only quarantine, run:"
    say ""
    say "  ${C_BOLD}sudo \"$tool\" \"$req\"${C_RESET}"
    say ""
    say "It lists the items again and asks you to type ${C_BOLD}$bid${C_RESET} before it acts."
    say "Undo later with: sudo \"$tool\" --restore <run-id>"
  else
    say "No sudo command was printed. The request selects candidate ids only;"
    say "it is not safe to run the copy of the tool that lives in this installation as root."
    warn "$ROOT_TOOL_NOTE"
  fi
  return "$EXIT_OK"
}

# ---------------------------------------------------------------------------
# CLI: mimi app uninstall <target>
# ---------------------------------------------------------------------------

mimi_app_uninstall() {
  local target="${APP_TARGET:-}"
  if [ -z "$target" ]; then
    die_usage "app uninstall requires an application name, bundle ID, cask token, or path"
  fi

  log_init
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_hello
    json_emit_phase_started "uninstall"
  fi

  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — uninstall: ${C_BOLD}$target${C_RESET}"
  say "Log: $LOG_FILE"

  # --- P5-T05: system scope (writes a request for the root tool) ---
  if [ "$UNINSTALL_SYSTEM" = 1 ]; then
    local sys_rc=0
    uninstall_system_request "$target" || sys_rc=$?
    exit "$sys_rc"
  fi

  # --- P4-T01: target resolution ---
  if ! uninstall_resolve_target "$target"; then
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_error "uninstall_refused" "target could not be uninstalled" "$target"
      json_emit_run_finished "failed" "$EXIT_USAGE" 0 0 0 0 0 0
    fi
    exit "$EXIT_USAGE"
  fi

  say ""
  say "  Resolved: ${C_BOLD}$RESOLVED_APP_PATH${C_RESET}"
  say "  App:      $APP_INFO_NAME  ($APP_INFO_BUNDLE_ID)"
  say "  Version:  $APP_INFO_VERSION"
  say "  Source:   $APP_INFO_PROVENANCE"
  [ -n "${APP_INFO_CASK_TOKEN:-}" ] && say "  Cask:     $APP_INFO_CASK_TOKEN"

  # --- P5-T01: vendor uninstaller hand-off ---
  if [ "${UNINSTALL_VENDOR:-0}" -eq 1 ]; then
    local v_rc=0
    uninstall_vendor_handoff || v_rc=$?
    exit "$v_rc"
  fi

  # --- P4-T05: Homebrew cask hand-off ---
  if [ "${UNINSTALL_DELEGATE_CASK:-0}" -eq 1 ] || [ "${UNINSTALL_ZAP:-0}" -eq 1 ]; then
    local cask_rc=0
    uninstall_cask_delegate "$target" || cask_rc=$?
    exit "$cask_rc"
  fi
  if [ "$APP_INFO_PROVENANCE" = "cask" ] && [ -n "${APP_INFO_CASK_TOKEN:-}" ]; then
    info "Note: This application was installed via Homebrew Cask ($APP_INFO_CASK_TOKEN)."
    info "      To uninstall via Homebrew instead, use: mimi app uninstall \"$target\" --cask"
    info "      or pass --zap to remove associated preferences and caches via Homebrew."
  fi

  # --- Evidence ---
  collect_app_evidence "$APP_INFO_CANONICAL_PATH" "$APP_INFO_NAME" "$APP_INFO_BUNDLE_ID" \
    "$SIGNING_TEAM_ID" "$APP_INFO_EXECUTABLE"

  # --- Data mode decision (ask mode asks once, before the plan is fixed) ---
  UNINSTALL_INCLUDE_DATA=0
  if [ "$UNINSTALL_DATA_MODE" = "ask" ]; then
    local n_data=0 kb_data=0 i
    for ((i = 0; i < EVIDENCE_COUNT; i++)); do
      evidence_is_selectable "$i" || continue
      [ "${EVIDENCE_ROOTS[$i]}" = "LaunchAgents" ] && continue
      n_data=$((n_data + 1))
      kb_data=$((kb_data + ${EVIDENCE_SIZES[$i]:-0}))
    done
    if [ "$n_data" -gt 0 ]; then
      if [ "$ASSUME_YES" != 1 ] && [ "${JSONL_ENABLED:-0}" != 1 ] && confirm_can_prompt; then
        say ""
        say "$APP_INFO_NAME has $n_data item(s) of its own user data ($(human_kb "$kb_data")):"
        for ((i = 0; i < EVIDENCE_COUNT; i++)); do
          evidence_is_selectable "$i" || continue
          [ "${EVIDENCE_ROOTS[$i]}" = "LaunchAgents" ] && continue
          say "    ${EVIDENCE_PATHS[$i]}"
        done
        local data_rc=0
        confirm_prompt_yesno "Also move this data to quarantine?" || data_rc=$?
        [ "$data_rc" = 0 ] && UNINSTALL_INCLUDE_DATA=1
      else
        info "User data ($n_data item(s), $(human_kb "$kb_data")) is kept. Pass --purge-data to include it."
      fi
    fi
  fi

  # --- P4-T03: build and show the plan ---
  plan_init
  uninstall_build_plan "$APP_INFO_CANONICAL_PATH" "$APP_INFO_NAME" "$APP_INFO_BUNDLE_ID"
  plan_build "" "uninstall-$(date +%Y%m%d-%H%M%S)-$$"
  uninstall_print_plan "$APP_INFO_NAME" >&2

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    local item cat op p bytes risk
    for item in "${PLAN_ACTIONS[@]}"; do
      cat="${item#*::}"; cat="${cat%%::*}"
      op="${item#*::*::}"; op="${op%%::*}"
      p="${item#*::*::*::}"; p="${p%%::*}"
      bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
      risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
      [ "$op" = "retain" ] && continue
      json_emit_candidate "$cat" "$p" "$((bytes / 1024))" "$risk" "${item%%::*}"
    done
  fi

  local plan_file="${PLANS_DIR}/${PLAN_ID}.json"
  if [ "$UNINSTALL_PLAN_ONLY" = 1 ]; then
    mkdir -p "$PLANS_DIR"
    if ! plan_save "$plan_file"; then
      err "could not save the plan to $plan_file"
      exit "$EXIT_FAILURE"
    fi
    say "Plan saved (valid for 24 hours): ${C_BOLD}$plan_file${C_RESET}"
    say "Review it, then apply it with:"
    say "  ${C_BOLD}$SCRIPT_NAME apply \"$plan_file\"${C_RESET}"
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_phase_finished "uninstall" "planned"
      json_emit_run_finished "ok" "$EXIT_OK" 0 0 0 0 0 0
    fi
    exit "$EXIT_OK"
  fi

  # --- Confirmation (recoverable: everything goes to quarantine) ---
  local gate_rc=0
  confirm "Move \"$APP_INFO_NAME\" and the items above to quarantine?" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    [ "$gate_rc" = 2 ] && err "no terminal to confirm on: pass --yes to approve (nothing is deleted; it can be restored)"
    warn "uninstall cancelled"
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_phase_finished "uninstall" "cancelled"
      json_emit_run_finished "cancelled" "$EXIT_CANCELLED" 0 0 0 0 0 0
    fi
    exit "$EXIT_CANCELLED"
  fi

  # --- P4-T04: save, preflight the saved file, execute ---
  local apply_rc=0
  uninstall_apply || apply_rc=$?
  say "Plan: $plan_file"
  exit "$apply_rc"
}
