#!/usr/bin/env bash
#
# lib/core/core.sh lib/core.sh — Main execution loop and category dispatcher.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions only.

run_category() {
  local id="$1"
  should_run_category "$id" || return 0
  RAN_ANY=1
  CURRENT_CATEGORY_ID="$id"
  local handler
  handler="$(category_handler "$id")"
  if [ -n "$handler" ] && declare -f "$handler" >/dev/null 2>&1; then
    "$handler"
  else
    warn "unknown category: $id"
  fi
  CURRENT_CATEGORY_ID=""
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

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_hello
    json_emit_phase_started "$MODE"
  fi

  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — mode: ${C_BOLD}$MODE${C_RESET}  $( [ "$AGGRESSIVE" = 1 ] && echo '(aggressive)' )"
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

  # Everything this run could never confirm is reported before anything is
  # removed, so a misconfigured scripted run costs nothing instead of stopping
  # halfway through a category list.
  if ! preflight_confirmations; then
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_phase_finished "$MODE" "cancelled"
      json_emit_run_finished "cancelled" "$EXIT_CANCELLED" "$TOTAL_RECLAIMED_KB" "$TOTAL_BEFORE_KB" "$ACTION_OK" "$ACTION_SKIPPED" "$ACTION_DENIED" "$ACTION_FAILED"
    fi
    return "$EXIT_CANCELLED"
  fi

  if [ "$MODE" = "clean" ] && [ "$ASSUME_YES" != 1 ]; then
    local gate_rc=0
    confirm "About to clean categories: $ONLY_LIST — proceed?" || gate_rc=$?
    if [ "$gate_rc" != 0 ]; then
      if [ "$gate_rc" = 2 ]; then
        err "no terminal to confirm on: pass --yes to approve ordinary prompts"
        err "non-interactively. Nothing was removed."
      else
        warn "aborted by user"
      fi
      if [ "${JSONL_ENABLED:-0}" = 1 ]; then
        json_emit_phase_finished "$MODE" "cancelled"
        json_emit_run_finished "cancelled" "$EXIT_CANCELLED" "$TOTAL_RECLAIMED_KB" "$TOTAL_BEFORE_KB" "$ACTION_OK" "$ACTION_SKIPPED" "$ACTION_DENIED" "$ACTION_FAILED"
      fi
      return "$EXIT_CANCELLED"
    fi
  fi

  local id
  for id in $ALL_CATEGORY_IDS; do
    if interrupted; then
      warn "interrupted — remaining categories were not started"
      break
    fi
    run_category "$id"
  done

  if [ -n "$REMOVE_ORPHANS_FILE" ] && ! interrupted; then
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
    say "Actions: ${ACTION_OK} succeeded, ${ACTION_SKIPPED} skipped, ${ACTION_DENIED} permission-denied, ${ACTION_FAILED} failed"
    if [ "$ACTION_DENIED" -gt 0 ]; then
      warn "$ACTION_DENIED action(s) were refused by the system. Full Disk Access in"
      warn "System Settings > Privacy & Security is the usual reason."
      [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_permission_required "full_disk_access" "Full Disk Access is recommended for unhindered cleaning"
    fi
    if [ "$ACTION_FAILED" -gt 0 ]; then
      warn "$ACTION_FAILED action(s) failed; see the log for the exact errors."
    fi
  fi
  # Anything a cleaner must not delete for you still has to be findable.
  if [ "$REPORT_ONLY" = 1 ] || [ "$MODE" = "scan" ]; then
    local purgeable
    purgeable="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
    say ""
    info "Tip: run ${C_BOLD}mimi --report${C_RESET} for a full breakdown of where the"
    info "rest of your disk went (VM disks, SDKs, model weights, node_modules)."
  fi
  if [ "$NO_LOG" = 1 ]; then
    say "Log: not kept (--no-log)"
  else
    say "Full log: $LOG_FILE  (keeping the last $KEEP_LOGS runs)"
  fi

  # The exit status describes what actually happened, not merely that the
  # script reached the end.
  local term_status="ok" exit_code="$EXIT_OK"
  if interrupted; then
    warn "run was interrupted before it finished"
    term_status="interrupted"
    exit_code="$EXIT_INTERRUPTED"
  elif any_action_failed; then
    term_status="partial"
    exit_code="$EXIT_PARTIAL"
  fi

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_phase_finished "$MODE" "$term_status"
    json_emit_run_finished "$term_status" "$exit_code" "$TOTAL_RECLAIMED_KB" "$TOTAL_BEFORE_KB" "$ACTION_OK" "$ACTION_SKIPPED" "$ACTION_DENIED" "$ACTION_FAILED"
  fi

  return "$exit_code"
}

run_plan() {
  log_init
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_hello
    json_emit_phase_started "plan"
  fi

  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — mode: ${C_BOLD}plan${C_RESET}"
  say "Log: $LOG_FILE"
  warn_if_no_full_disk_access

  PLAN_CANDIDATES=()
  local prev_mode="$MODE"
  MODE="plan"
  local id
  for id in $ALL_CATEGORY_IDS; do
    if interrupted; then
      warn "interrupted — remaining categories were not scanned for plan"
      break
    fi
    run_category "$id"
  done
  MODE="$prev_mode"

  plan_build ""
  local total_actions="${#PLAN_ACTIONS[@]}"

  local out_path="$PLAN_OUT_FILE"
  if [ -z "$out_path" ]; then
    mkdir -p "$PLANS_DIR"
    out_path="$PLANS_DIR/${PLAN_ID}.json"
  fi

  if ! plan_save "$out_path"; then
    err "failed to save execution plan to: $out_path"
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_phase_finished "plan" "failed"
      json_emit_run_finished "failed" "$EXIT_FAILURE" 0 0 0 0 0 1
    fi
    return "$EXIT_FAILURE"
  fi

  section "Plan summary"
  say "Plan ID: ${C_BOLD}$PLAN_ID${C_RESET}"
  say "Target count: $total_actions candidates ($(human_kb "$TOTAL_BEFORE_KB"))"
  say "Plan file: ${C_BOLD}$out_path${C_RESET}"
  say ""
  say "To review and apply this plan:"
  say "  ${C_BOLD}$SCRIPT_NAME apply \"$out_path\"${C_RESET}"

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_phase_finished "plan" "ok"
    json_emit_run_finished "ok" "$EXIT_OK" 0 "$TOTAL_BEFORE_KB" "$total_actions" 0 0 0
  fi
  return "$EXIT_OK"
}

run_apply() {
  log_init
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_hello
    json_emit_phase_started "apply"
  fi

  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — mode: ${C_BOLD}apply${C_RESET}"
  say "Plan: $PLAN_FILE"
  say "Log: $LOG_FILE"
  warn_if_no_full_disk_access

  if ! plan_preflight "$PLAN_FILE"; then
    err "plan preflight failed; refusing to apply"
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_phase_finished "apply" "failed"
      json_emit_run_finished "failed" "$EXIT_USAGE" 0 0 0 0 0 1
    fi
    return "$EXIT_USAGE"
  fi

  local action_count="${#PLAN_ACTIONS[@]}"
  if [ "$ASSUME_YES" != 1 ]; then
    local gate_rc=0
    confirm "About to apply plan $(basename "$PLAN_FILE") ($action_count action(s)) — proceed?" || gate_rc=$?
    if [ "$gate_rc" != 0 ]; then
      warn "apply cancelled by user"
      if [ "${JSONL_ENABLED:-0}" = 1 ]; then
        json_emit_phase_finished "apply" "cancelled"
        json_emit_run_finished "cancelled" "$EXIT_CANCELLED" 0 0 0 0 0 0
      fi
      return "$EXIT_CANCELLED"
    fi
  fi

  quarantine_init_run "$PLAN_ID" || {
    err "failed to initialize quarantine run"
    return "$EXIT_FAILURE"
  }

  TOTAL_BEFORE_KB=0
  TOTAL_RECLAIMED_KB=0
  ACTION_OK=0
  ACTION_SKIPPED=0
  ACTION_DENIED=0
  ACTION_FAILED=0

  local item act_id cat op p ident bytes risk evid
  for item in "${PLAN_ACTIONS[@]}"; do
    if interrupted; then
      warn "interrupted — stopping apply"
      break
    fi
    act_id="${item%%::*}"
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    p="${item#*::*::*::}"; p="${p%%::*}"
    ident="${item#*::*::*::*::}"; ident="${ident%%::*}"
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    evid="${item##*::}"

    case "$op" in
      remove_path|clear_dir_contents|quarantine)
        if quarantine_target "$act_id" "$cat" "$p" "$ident" "$bytes"; then
          record_action ok
          TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + (bytes / 1024)))
          [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "ok" "$p" "$bytes"
          ok "quarantined: $p"
        else
          record_action failed
          [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "failed" "$p" 0
          err "failed to quarantine: $p"
        fi
        ;;
      tool_cleanup)
        record_action ok
        ;;
    esac
  done

  section "Apply summary"
  say "Actions: ${ACTION_OK} succeeded, ${ACTION_SKIPPED} skipped, ${ACTION_DENIED} denied, ${ACTION_FAILED} failed"
  say "Quarantine run ID: ${C_BOLD}$QUARANTINE_CURRENT_RUN_ID${C_RESET}"
  say "Quarantine directory: $QUARANTINE_CURRENT_RUN_DIR"
  say ""
  say "To restore this run if needed:"
  say "  ${C_BOLD}$SCRIPT_NAME restore \"$QUARANTINE_CURRENT_RUN_ID\"${C_RESET}"

  local term_status="ok" exit_code="$EXIT_OK"
  if interrupted; then
    term_status="interrupted"
    exit_code="$EXIT_INTERRUPTED"
  elif any_action_failed; then
    term_status="partial"
    exit_code="$EXIT_PARTIAL"
  fi

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    json_emit_phase_finished "apply" "$term_status"
    json_emit_run_finished "$term_status" "$exit_code" "$TOTAL_RECLAIMED_KB" "$TOTAL_BEFORE_KB" "$ACTION_OK" "$ACTION_SKIPPED" "$ACTION_DENIED" "$ACTION_FAILED"
  fi
  return "$exit_code"
}

run_restore() {
  log_init
  if [ -z "$RUN_ID" ]; then
    err "restore requires a run ID or quarantine directory"
    return "$EXIT_USAGE"
  fi
  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — restoring quarantine run: ${C_BOLD}$RUN_ID${C_RESET}"
  if quarantine_restore_run "$RUN_ID"; then
    ok "restore completed successfully"
    return "$EXIT_OK"
  else
    err "restore encountered errors"
    return "$EXIT_PARTIAL"
  fi
}

run_purge() {
  log_init
  if [ -z "$RUN_ID" ]; then
    err "purge requires a run ID or quarantine directory"
    return "$EXIT_USAGE"
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    local gate_rc=0
    confirm "Permanently purge quarantine run '$RUN_ID'? This is irreversible — proceed?" || gate_rc=$?
    if [ "$gate_rc" != 0 ]; then
      warn "purge cancelled"
      return "$EXIT_CANCELLED"
    fi
  fi
  if quarantine_purge_run "$RUN_ID"; then
    ok "purged quarantine run: $RUN_ID"
    return "$EXIT_OK"
  else
    err "failed to purge quarantine run: $RUN_ID"
    return "$EXIT_FAILURE"
  fi
}

main() {
  if [ "$REPORT_ONLY" = 1 ]; then
    log_init
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      json_emit_hello
      json_emit_phase_started "report"
      {
        say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — disk report"
        say "Log: $LOG_FILE"
        report_system_data
        report_top_offenders
        say ""
        say "Full log: $LOG_FILE"
      } >&2
      json_emit_phase_finished "report" "ok"
      json_emit_run_finished "ok" 0 0 0 0 0 0 0
      return 0
    fi
    say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — disk report"
    say "Log: $LOG_FILE"
    report_system_data
    report_top_offenders
    say ""
    say "Full log: $LOG_FILE"
    return 0
  fi

  case "$MODE" in
    plan) run_plan ;;
    apply) run_apply ;;
    restore) run_restore ;;
    purge) run_purge ;;
    *) run_selected_categories ;;
  esac
}
