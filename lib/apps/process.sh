#!/usr/bin/env bash
#
# lib/apps/process.sh — Running process handling for app uninstall (Phase 4, P4-T02).
#
# Provides:
#   app_process_list_pids BUNDLE_ID APP_PATH APP_NAME
#     Sets PROC_PIDS (array of PID:name strings) and PROC_COUNT.
#
#   app_process_request_quit BUNDLE_ID
#     Sends a normal AppleEvent quit to the app if osascript is available.
#     Returns 0 if sent, 1 if unavailable.
#
#   app_process_wait_gone BUNDLE_ID APP_PATH APP_NAME TIMEOUT_SECS
#     Polls until the process list is empty or the timeout elapses.
#     Returns 0 if gone, 1 if processes remain.
#
#   app_process_confirm_terminate PROC_COUNT APP_NAME
#     Asks the user whether to force-terminate the remaining processes.
#     Returns 0 if approved, non-zero otherwise.
#
#   app_process_force_quit BUNDLE_ID APP_PATH APP_NAME
#     Sends SIGTERM to all matching processes; waits 2 s, then SIGKILL.
#     Returns 0 if all gone, 1 if any remain after SIGKILL.
#
# Compatible with Bash 3.2+ (no associative arrays).
#
# NOTE on Bash 3.2 empty-array expansion:
#   "${arr[@]:-}" on an empty array expands to ONE empty string, not nothing.
#   Every loop over PROC_PIDS is therefore guarded by [ "${#arr[@]}" -gt 0 ]
#   and the :- default is omitted so that a zero-length array is handled
#   correctly by the guard rather than producing a spurious empty iteration.
#

# ---------------------------------------------------------------------------
# State (cleared by each _proc_find_pids call)
# ---------------------------------------------------------------------------

PROC_PIDS=()
PROC_COUNT=0

# ---------------------------------------------------------------------------
# Internal helper: collect PIDs for a given app
# ---------------------------------------------------------------------------

_proc_find_pids() {
  # Strategy: get a broad candidate list from pgrep, then accept only processes
  # whose executable path is contained inside the app bundle.  This prevents
  # pgrep -f from matching the calling process (which may have the app name in
  # its own command-line arguments) or any unrelated process.

  local bundle_id="$1" app_path="$2" app_name="$3"
  PROC_PIDS=()
  PROC_COUNT=0

  # Short-circuit: if the app bundle doesn't exist on disk there can be no
  # running process for it.
  [ -d "$app_path" ] || return 0

  # Canonicalize once for reliable prefix matching.
  local canon_app
  canon_app="$(cd -P "$app_path" 2>/dev/null && pwd -P)" || return 0
  [ -n "$canon_app" ] || return 0

  local pid
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue

    # Get only the executable path (comm), not the full argument list.
    local cmd
    cmd="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    [ -z "$cmd" ] && continue

    # Resolve symlinks in the executable path.
    local canon_cmd cmd_dir cmd_base
    cmd_dir="$(dirname "$cmd")"
    cmd_base="$(basename "$cmd")"
    canon_cmd="$(cd -P "$cmd_dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$cmd_base")" \
      || canon_cmd="$cmd"

    # Accept only if the executable lives inside the app bundle.
    case "$canon_cmd" in
      "$canon_app"/*) ;;
      *) continue ;;
    esac

    PROC_PIDS+=("${pid}:${cmd_base}")
  done < <(pgrep -f "$(basename "$app_path")" 2>/dev/null || true)

  # De-duplicate (Bash 3.2 compatible, no associative arrays).
  # Guard the loop: in Bash 3.2, "${empty[@]:-}" expands to one empty string.
  if [ "${#PROC_PIDS[@]}" -gt 0 ]; then
    local seen="" dedupe_pids=()
    local entry p
    for entry in "${PROC_PIDS[@]}"; do
      p="${entry%%:*}"
      case " $seen " in
        *" $p "*) ;;
        *) seen="$seen $p"; dedupe_pids+=("$entry") ;;
      esac
    done
    if [ "${#dedupe_pids[@]}" -gt 0 ]; then
      PROC_PIDS=("${dedupe_pids[@]}")
    else
      PROC_PIDS=()
    fi
  fi

  PROC_COUNT="${#PROC_PIDS[@]}"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

app_process_list_pids() {
  local bundle_id="$1" app_path="$2" app_name="$3"
  _proc_find_pids "$bundle_id" "$app_path" "$app_name"
}

app_process_request_quit() {
  local bundle_id="$1"
  [ -z "$bundle_id" ] && return 1

  if ! command -v osascript >/dev/null 2>&1; then
    verbose "process: osascript unavailable, cannot send AppleEvent quit"
    return 1
  fi

  # AppleScript quit is best-effort; we do not treat a refusal as fatal.
  osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
  return 0
}

app_process_wait_gone() {
  local bundle_id="$1" app_path="$2" app_name="$3" timeout_secs="${4:-10}"

  local elapsed=0 interval=1
  while [ "$elapsed" -lt "$timeout_secs" ]; do
    _proc_find_pids "$bundle_id" "$app_path" "$app_name"
    if [ "$PROC_COUNT" -eq 0 ]; then
      return 0
    fi
    sleep "$interval" 2>/dev/null || true
    elapsed=$((elapsed + interval))
  done

  # Final check
  _proc_find_pids "$bundle_id" "$app_path" "$app_name"
  [ "$PROC_COUNT" -eq 0 ]
}

app_process_confirm_terminate() {
  # $1 = number of remaining processes
  # $2 = human-readable app name
  # Delegates to confirm() from lib/safety/confirm.sh.
  local proc_count="$1" app_name="$2"

  local pid_list=""
  # Guard: length check before iterating (Bash 3.2 empty-array safety).
  if [ "${#PROC_PIDS[@]}" -gt 0 ]; then
    local entry
    for entry in "${PROC_PIDS[@]}"; do
      local p="${entry%%:*}"
      local n="${entry#*:}"
      pid_list="${pid_list:+$pid_list, }${n} (PID $p)"
    done
  fi

  warn "\"$app_name\" still has $proc_count running process(es):${pid_list:+ $pid_list}"
  warn "It may be showing a save dialog. Forcing it to quit discards any unsaved work."

  # Risky class: --yes cannot answer this. Only a person at the terminal, or
  # an explicit --force-risky app-terminate, can decide to throw away
  # unsaved work. Quarantine cannot bring unsaved documents back.
  confirm_action_ok app-terminate \
    "Force-quit \"$app_name\" and continue the uninstall? Unsaved work will be lost." || return $?
  return 0
}

app_process_force_quit() {
  local bundle_id="$1" app_path="$2" app_name="$3"

  _proc_find_pids "$bundle_id" "$app_path" "$app_name"
  if [ "$PROC_COUNT" -eq 0 ]; then
    return 0
  fi

  # Send SIGTERM to all matching PIDs.
  # Guard: length check before iterating (Bash 3.2 empty-array safety).
  if [ "${#PROC_PIDS[@]}" -gt 0 ]; then
    local entry pid
    for entry in "${PROC_PIDS[@]}"; do
      pid="${entry%%:*}"
      [ -n "$pid" ] || continue
      verbose "process: SIGTERM PID $pid"
      kill -TERM "$pid" 2>/dev/null || true
    done
  fi

  # Wait up to 2 seconds for graceful exit.
  local waited=0
  while [ "$waited" -lt 2 ]; do
    _proc_find_pids "$bundle_id" "$app_path" "$app_name"
    [ "$PROC_COUNT" -eq 0 ] && return 0
    sleep 1 2>/dev/null || true
    waited=$((waited + 1))
  done

  # SIGKILL survivors.
  if [ "${#PROC_PIDS[@]}" -gt 0 ]; then
    local entry pid
    for entry in "${PROC_PIDS[@]}"; do
      pid="${entry%%:*}"
      [ -n "$pid" ] || continue
      verbose "process: SIGKILL PID $pid"
      kill -KILL "$pid" 2>/dev/null || true
    done
  fi

  sleep 1 2>/dev/null || true
  _proc_find_pids "$bundle_id" "$app_path" "$app_name"
  [ "$PROC_COUNT" -eq 0 ]
}
