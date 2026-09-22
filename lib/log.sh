#!/usr/bin/env bash
#
# lib/log.sh — Logging, the run transcript, and the say/info/ok/warn/err family.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

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
    # Justified raw rm: this is the tool's own transcript housekeeping, not a
    # user-selected action. It runs inside log_init before any action exists,
    # so routing it through fs_remove would count it in the user-facing
    # success/failure totals and describe log rotation as a cleanup result.
    rm -f "$f"
  done < <(ls -t "$LOG_DIR"/clean-*.log 2>/dev/null)
  # Orphan review files are meant to be edited by hand and fed back in, so
  # they are kept much longer than a transcript — but not forever. Justified
  # raw delete for the same reason as the rm above: the tool's own files.
  find "$LOG_DIR" -maxdepth 1 -name 'orphans-review-*.txt' -mtime +30 -delete 2>/dev/null
  return 0
}

# Single exit path: restore the cursor if a TUI screen was up, and drop the
# scratch log if --no-log was used. Installed by both log_init and tui_begin
# so whichever runs first wins and neither clobbers the other.
_cleanup_on_exit() {
  tui_end 2>/dev/null
  if [ "$NO_LOG" = 1 ] && [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    # Justified raw rm: the scratch log this process created for --no-log,
    # removed on the way out. Accounting is already finished by this point.
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
  # EXIT is cleanup. INT/TERM must NOT exit here: being killed partway through
  # an rm is exactly how a half-removed tree and a wrong total happen, so the
  # handler raises a flag and every action checks it before starting.
  trap '_cleanup_on_exit' EXIT
  trap '_on_interrupt' INT TERM
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
