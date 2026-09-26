#!/usr/bin/env bash
#
# lib/apps/uninstall.sh — Reversible user-scope application uninstall (Phase 4).
#
# Covers P4-T01 (target resolution & mode selection),
#        P4-T03 (uninstall plan building), and
#        P4-T04 (apply & verification).
#
# Compatible with Bash 3.2+ (no associative arrays).
#
# Public entry points:
#
#   mimi_app_uninstall
#     Top-level CLI command handler for "mimi app uninstall <target>".
#     Reads APP_TARGET, UNINSTALL_DATA_MODE, ASSUME_YES from globals.
#
# Data modes (set via --keep-data or --purge-data):
#   UNINSTALL_DATA_MODE="keep"   — quarantine bundle only; retain user data
#   UNINSTALL_DATA_MODE="purge"  — quarantine bundle + all attributable user data
#   UNINSTALL_DATA_MODE="ask"    — (default) show the plan; ask before each data item
#
# Exit codes follow the existing EXIT_* constants from globals.
#

# shellcheck disable=SC2155

# ---------------------------------------------------------------------------
# Globals set/read by this module
# ---------------------------------------------------------------------------

UNINSTALL_DATA_MODE="ask"       # keep | purge | ask
UNINSTALL_PLAN_ACTIONS=()       # internal: parallel to PLAN_ACTIONS for the uninstall run
UNINSTALL_LAUNCHAGENTS=()       # LaunchAgent plists to unload before quarantine

# ---------------------------------------------------------------------------
# P4-T01 Helper: uninstall target resolution
# ---------------------------------------------------------------------------
# Wraps resolve_app_target (inspect.sh) and adds system/Apple app guard.
# Sets: RESOLVED_APP_PATH (from resolve_app_target)
# Returns 0 on success; 1 on refusal or not-found.

uninstall_resolve_target() {
  local target="$1"

  resolve_app_target "$target" || return 1

  if [ -z "$RESOLVED_APP_PATH" ]; then
    err "uninstall: failed to resolve target: $target"
    return 1
  fi

  # Inspect the bundle so APP_INFO_* are populated.
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

  # Guard: changed identity (app was replaced after resolution).
  local canon_ident
  canon_ident="$(path_identity "$RESOLVED_APP_PATH" 2>/dev/null || echo "")"
  if [ -n "$APP_INFO_IDENTITY" ] && [ "$canon_ident" != "$APP_INFO_IDENTITY" ]; then
    err "uninstall: application identity changed since target was resolved."
    err "           Run 'mimi app inspect \"$target\"' again and retry."
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# P4-T02 Integration: handle running processes before quarantine
# ---------------------------------------------------------------------------
# Returns 0 if the app can proceed to be quarantined.
# Returns EXIT_CANCELLED if the user refuses termination.

uninstall_handle_processes() {
  local bundle_id="$1" app_path="$2" app_name="$3"

  app_process_list_pids "$bundle_id" "$app_path" "$app_name"

  if [ "$PROC_COUNT" -eq 0 ]; then
    return 0
  fi

  say ""
  say "${C_YELLOW}\"$app_name\" is currently running ($PROC_COUNT process(es)).${C_RESET}"

  # First: attempt a polite AppleEvent quit.
  if app_process_request_quit "$bundle_id"; then
    say "  Sent quit request to $app_name — waiting up to 10 seconds…"
    if app_process_wait_gone "$bundle_id" "$app_path" "$app_name" 10; then
      ok "  $app_name quit gracefully."
      return 0
    fi
  fi

  # Refresh count after the wait.
  app_process_list_pids "$bundle_id" "$app_path" "$app_name"
  if [ "$PROC_COUNT" -eq 0 ]; then
    return 0
  fi

  # Require explicit approval before force-termination.
  local gate_rc=0
  app_process_confirm_terminate "$PROC_COUNT" "$app_name" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    warn "uninstall cancelled — $app_name is still running"
    return "$EXIT_CANCELLED"
  fi

  if ! app_process_force_quit "$bundle_id" "$app_path" "$app_name"; then
    err "uninstall: could not terminate all processes for \"$app_name\""
    err "           Please quit the application manually and retry."
    return 1
  fi

  ok "  Processes terminated."
  return 0
}

# ---------------------------------------------------------------------------
# P4-T03: Build an uninstall plan
# ---------------------------------------------------------------------------
# Adds plan candidates for:
#   1. The app bundle itself (always included).
#   2. LaunchAgents attributed to the app (if any).
#   3. Attributable user data (controlled by UNINSTALL_DATA_MODE).
#
# After calling this function, PLAN_CANDIDATES is populated; call
# plan_build "" to convert candidates into PLAN_ACTIONS.

uninstall_build_plan() {
  local app_path="$1" app_name="$2" bundle_id="$3" team_id="${4:-}" exe_name="${5:-}"
  UNINSTALL_LAUNCHAGENTS=()

  PLAN_CANDIDATES=()

  # 1. The application bundle.
  local bundle_ident bytes_bundle
  bundle_ident="$(path_identity "$app_path" 2>/dev/null || echo "unknown")"
  bytes_bundle=$(( APP_INFO_SIZE_KB * 1024 ))
  plan_candidate_add "uninstall-app" "quarantine" \
    "$app_path" "$bundle_ident" "$bytes_bundle" "moderate" \
    "app bundle"

  # 2. Collect evidence (remnants), already done by mimi_app_uninstall before calling here.
  #    Walk EVIDENCE_* arrays and add candidates based on data mode.
  local i
  for ((i = 0; i < EVIDENCE_COUNT; i++)); do
    local ev_path="${EVIDENCE_PATHS[$i]}"
    local ev_conf="${EVIDENCE_CONFIDENCES[$i]}"
    local ev_size="${EVIDENCE_SIZES[$i]}"
    local ev_root="${EVIDENCE_ROOTS[$i]}"
    local ev_reason="${EVIDENCE_REASONS[$i]}"

    # Only attributable evidence can become an action. Weak, conflicting,
    # shared, and system-location evidence never can, in any data mode.
    evidence_is_selectable "$i" || continue

    # LaunchAgents: track separately for pre-quarantine unload.
    if [[ "$ev_root" == "LaunchAgents" ]]; then
      UNINSTALL_LAUNCHAGENTS+=("$ev_path")
    fi

    # Data mode gating.
    case "$UNINSTALL_DATA_MODE" in
      keep)
        # Only include LaunchAgents (startup items, not documents).
        if [[ "$ev_root" != "LaunchAgents" ]]; then
          continue
        fi
        ;;
      purge|ask)
        # Include all attributable, non-shared, non-system items.
        ;;
    esac

    local ev_ident ev_bytes ev_risk
    ev_ident="$(path_identity "$ev_path" 2>/dev/null || echo "unknown")"
    ev_bytes=$(( ev_size * 1024 ))
    # Confidence → risk mapping for the plan.
    case "$ev_conf" in
      authoritative) ev_risk="safe" ;;
      strong)        ev_risk="safe" ;;
      corroborated)  ev_risk="moderate" ;;
      *)             ev_risk="moderate" ;;
    esac

    plan_candidate_add "uninstall-data" "quarantine" \
      "$ev_path" "$ev_ident" "$ev_bytes" "$ev_risk" \
      "${ev_root}: ${ev_reason} [${ev_conf}]"
  done
}

# ---------------------------------------------------------------------------
# P4-T03 Helper: Display the uninstall plan to the user
# ---------------------------------------------------------------------------

uninstall_print_plan() {
  local app_name="$1"
  printf '\n%s=== Uninstall Plan: %s ===%s\n\n' "$C_BOLD" "$app_name" "$C_RESET"

  local total_bytes=0 total_actions=0
  local item act_id cat op p ident bytes risk evid

  for item in "${PLAN_ACTIONS[@]}"; do
    act_id="${item%%::*}"
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    p="${item#*::*::*::}"; p="${p%%::*}"
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    evid="${item##*::}"

    total_bytes=$((total_bytes + bytes))
    total_actions=$((total_actions + 1))

    local risk_tag
    case "$risk" in
      safe)        risk_tag="${C_GREEN}[safe]      ${C_RESET}" ;;
      moderate)    risk_tag="${C_YELLOW}[moderate]  ${C_RESET}" ;;
      risky)       risk_tag="${C_RED}[risky]     ${C_RESET}" ;;
      *)           risk_tag="[unknown]   " ;;
    esac

    printf '  %b %-40s (%s)\n' "$risk_tag" "$p" "$(human_kb "$bytes")"
    printf '        → %s\n' "$evid"
  done

  printf '\n  Total: %d item(s), estimated %s\n' "$total_actions" "$(human_kb "$((total_bytes / 1024))")"
  printf '  All items will be %squarantined%s (restorable until purge).\n\n' "$C_BOLD" "$C_RESET"
}

# ---------------------------------------------------------------------------
# P4-T04: Apply the uninstall plan
# ---------------------------------------------------------------------------
# 1. Unload any LaunchAgents first.
# 2. Quarantine each planned target in dependency-safe order
#    (data before bundle, or bundle first for cleanliness — we do data last
#    so the bundle disappears before user data, which is the natural order).
# 3. Verify app absence.
# 4. Report leftovers.

uninstall_apply() {
  local app_path="$1" bundle_id="$2" app_name="$3"

  quarantine_init_run "uninstall-${PLAN_ID}" || {
    err "uninstall: failed to initialize quarantine run"
    return "$EXIT_FAILURE"
  }

  # --- Pre-quarantine: unload LaunchAgents ---
  local la
  for la in "${UNINSTALL_LAUNCHAGENTS[@]:-}"; do
    [ -f "$la" ] || continue
    local la_label
    la_label="$(basename "$la" .plist)"
    verbose "uninstall: unloading LaunchAgent: $la_label"
    # launchctl bootout is the current (macOS 10.10+) spelling.
    local bootout_target="gui/$(id -u)"
    launchctl bootout "$bootout_target/$la_label" 2>/dev/null || \
      launchctl unload "$la" 2>/dev/null || true
  done

  # --- Apply plan ---
  local item act_id cat op p ident bytes risk evid
  local reclaimed_kb=0 ok_count=0 failed_count=0 skipped_count=0

  for item in "${PLAN_ACTIONS[@]}"; do
    act_id="${item%%::*}"
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    p="${item#*::*::*::}"; p="${p%%::*}"
    ident="${item#*::*::*::*::}"; ident="${ident%%::*}"
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    evid="${item##*::}"

    [ -z "$p" ] && continue

    if interrupted; then
      warn "uninstall: interrupted — stopping apply"
      break
    fi

    if quarantine_target "$act_id" "$cat" "$p" "$ident" "$bytes"; then
      ok_count=$((ok_count + 1))
      reclaimed_kb=$((reclaimed_kb + (bytes / 1024)))
      ok "quarantined: $p"
    else
      failed_count=$((failed_count + 1))
      err "failed to quarantine: $p"
    fi
  done

  # --- Verify app absence ---
  local verify_ok=1
  if [ -e "$app_path" ] || [ -L "$app_path" ]; then
    err "uninstall: application bundle still present after quarantine: $app_path"
    verify_ok=0
  else
    ok "Application bundle removed: $app_path"
  fi

  # --- Summary ---
  say ""
  section "Uninstall summary"
  say "  Application:      $app_name"
  say "  Quarantine run:   ${C_BOLD}$QUARANTINE_CURRENT_RUN_ID${C_RESET}"
  say "  Items quarantined: $ok_count"
  [ "$failed_count" -gt 0 ] && warn "  Items failed:      $failed_count"
  say "  Estimated freed:  $(human_kb "$reclaimed_kb")"
  say ""
  say "  To restore (undo) this uninstall:"
  say "    ${C_BOLD}$SCRIPT_NAME restore \"$QUARANTINE_CURRENT_RUN_ID\"${C_RESET}"
  say ""
  say "  To permanently purge (irreversible):"
  say "    ${C_BOLD}$SCRIPT_NAME purge \"$QUARANTINE_CURRENT_RUN_ID\"${C_RESET}"

  # Leftovers check
  if [ "$failed_count" -gt 0 ] || [ "$verify_ok" -eq 0 ]; then
    warn "  Some items could not be quarantined. See the log for details."
    warn "  The application may not be fully removed."
  fi

  if [ "$failed_count" -gt 0 ]; then
    return "$EXIT_PARTIAL"
  fi
  return "$EXIT_OK"
}

# ---------------------------------------------------------------------------
# P4-T01 / P4-T03 / P4-T04: Top-level CLI command
# ---------------------------------------------------------------------------

mimi_app_uninstall() {
  local target="${APP_TARGET:-}"
  if [ -z "$target" ]; then
    die_usage "app uninstall requires an application name, bundle ID, or path"
  fi

  log_init

  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — uninstall: ${C_BOLD}$target${C_RESET}"
  say "Log: $LOG_FILE"

  # --- P4-T01: Target resolution ---
  local RESOLVED_APP_PATH=""
  uninstall_resolve_target "$target" || exit "$EXIT_USAGE"

  say ""
  say "  Resolved: ${C_BOLD}$RESOLVED_APP_PATH${C_RESET}"
  say "  App:      $APP_INFO_NAME  ($APP_INFO_BUNDLE_ID)"
  say "  Version:  $APP_INFO_VERSION"
  say "  Source:   $APP_INFO_PROVENANCE"
  [ -n "${APP_INFO_CASK_TOKEN:-}" ] && say "  Cask:     $APP_INFO_CASK_TOKEN"

  # --- P4-T05: Homebrew Cask Delegation ---
  # Guard: --zap without cask provenance
  if [ "${UNINSTALL_ZAP:-0}" -eq 1 ] && [ "$APP_INFO_PROVENANCE" != "cask" ]; then
    err "uninstall: --zap is only applicable to applications installed via Homebrew Cask."
    exit "$EXIT_USAGE"
  fi

  if [ "${UNINSTALL_DELEGATE_CASK:-0}" -eq 1 ] || [ "${UNINSTALL_ZAP:-0}" -eq 1 ]; then
    local cask_token="${APP_INFO_CASK_TOKEN:-}"
    if [ -z "$cask_token" ]; then
      cask_token="$(normalize_token "$APP_INFO_NAME")"
    fi

    say ""
    section "Homebrew Cask Delegation"
    say "  Cask token: ${C_BOLD}$cask_token${C_RESET}"
    if [ "${UNINSTALL_ZAP:-0}" -eq 1 ]; then
      say "  Mode:       ${C_RED}--zap (removes preferences, caches, and shared data)${C_RESET}"
      warn "  Notice: Homebrew warns that --zap may remove shared vendor files"
      warn "  and configurations that cannot be restored via mimi quarantine."
    else
      say "  Mode:       standard cask uninstall"
    fi

    if [ "$ASSUME_YES" != 1 ]; then
      local gate_rc=0
      confirm "Proceed with 'brew uninstall --cask $([ "${UNINSTALL_ZAP:-0}" -eq 1 ] && echo "--zap ")$cask_token'?" || gate_rc=$?
      if [ "$gate_rc" -ne 0 ]; then
        warn "uninstall cancelled by user"
        exit "$EXIT_CANCELLED"
      fi
    fi

    local -a brew_cmd=("brew" "uninstall" "--cask")
    if [ "${UNINSTALL_ZAP:-0}" -eq 1 ]; then
      brew_cmd+=("--zap")
    fi
    brew_cmd+=("$cask_token")

    say "Running: ${brew_cmd[*]}"
    local brew_rc=0
    "${brew_cmd[@]}" 2>>"$LOG_FILE" || brew_rc=$?

    if [ "$brew_rc" -eq 0 ]; then
      ok "Successfully uninstalled cask: $cask_token"
      exit "$EXIT_OK"
    else
      err "Homebrew cask uninstall failed with exit code $brew_rc"
      exit "$EXIT_FAILURE"
    fi
  fi

  if [ "$APP_INFO_PROVENANCE" = "cask" ] && [ -n "${APP_INFO_CASK_TOKEN:-}" ]; then
    info "Note: This application was installed via Homebrew Cask ($APP_INFO_CASK_TOKEN)."
    info "      To uninstall via Homebrew instead, use: mimi app uninstall \"$target\" --cask"
    info "      or pass --zap to remove associated preferences and caches via Homebrew."
  fi

  # --- P4-T02: Running process check ---
  local proc_rc=0
  uninstall_handle_processes "$APP_INFO_BUNDLE_ID" "$RESOLVED_APP_PATH" "$APP_INFO_NAME" || proc_rc=$?
  if [ "$proc_rc" -ne 0 ]; then
    exit "$proc_rc"
  fi

  # --- Collect evidence for plan building ---
  collect_app_evidence \
    "$APP_INFO_CANONICAL_PATH" \
    "$APP_INFO_NAME" \
    "$APP_INFO_BUNDLE_ID" \
    "$SIGNING_TEAM_ID" \
    "$APP_INFO_EXECUTABLE"

  # --- P4-T03: Build the uninstall plan ---
  plan_init
  uninstall_build_plan \
    "$RESOLVED_APP_PATH" \
    "$APP_INFO_NAME" \
    "$APP_INFO_BUNDLE_ID" \
    "$SIGNING_TEAM_ID" \
    "$APP_INFO_EXECUTABLE"
  plan_build ""

  local total_actions="${#PLAN_ACTIONS[@]}"
  if [ "$total_actions" -eq 0 ]; then
    say ""
    warn "Nothing to uninstall — no plan candidates were generated."
    warn "The app bundle may already be missing, or you lack write access."
    exit "$EXIT_OK"
  fi

  # Print the plan.
  uninstall_print_plan "$APP_INFO_NAME"

  # Data mode notice.
  case "$UNINSTALL_DATA_MODE" in
    keep)
      say "  ${C_YELLOW}Data mode: --keep-data${C_RESET}  User data will NOT be quarantined."
      say "  Only the application bundle and any LaunchAgents are planned."
      ;;
    purge)
      say "  ${C_YELLOW}Data mode: --purge-data${C_RESET}  All attributable user data WILL be quarantined."
      ;;
    ask|*)
      say "  Data mode: ask (default)  User data items shown above are included."
      ;;
  esac
  say ""

  # --- Confirmation gate ---
  if [ "$ASSUME_YES" != 1 ]; then
    local gate_rc=0
    confirm "Proceed with uninstall of \"$APP_INFO_NAME\" ($total_actions item(s))?" || gate_rc=$?
    if [ "$gate_rc" -ne 0 ]; then
      warn "uninstall cancelled by user"
      exit "$EXIT_CANCELLED"
    fi
  fi

  # Save the plan for auditability.
  local plan_file="${PLANS_DIR}/uninstall-${PLAN_ID}.json"
  mkdir -p "$PLANS_DIR"
  plan_save "$plan_file" || warn "could not save uninstall plan to $plan_file"

  # --- P4-T04: Apply ---
  local apply_rc=0
  uninstall_apply "$RESOLVED_APP_PATH" "$APP_INFO_BUNDLE_ID" "$APP_INFO_NAME" || apply_rc=$?
  exit "$apply_rc"
}
