#!/usr/bin/env bash
#
# lib/ui/log.sh lib/log.sh — Logging, the run transcript, and the say/info/ok/warn/err family.
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
  run_unlock
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
    LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/mimi-XXXXXX")" || LOG_FILE="/dev/null"
  else
    # Transcripts list full paths under $HOME: private to the user.
    ( umask 077; mkdir -p "$LOG_DIR" && : > "$LOG_DIR/clean-$TIMESTAMP.log" )
    LOG_FILE="$LOG_DIR/clean-$TIMESTAMP.log"
    prune_old_logs
  fi
  # EXIT is cleanup. INT/TERM must NOT exit here: being killed partway through
  # an rm is exactly how a half-removed tree and a wrong total happen, so the
  # handler raises a flag and every action checks it before starting.
  trap '_cleanup_on_exit' EXIT
  trap '_on_interrupt' INT TERM
}

# One mutating run at a time per user: a GUI scan, a terminal clean, and an
# apply must not interleave their quarantine runs and history records. The
# lock is a directory (mkdir is atomic) holding the owner's pid; a lock whose
# owner is gone is taken over.
RUN_LOCK_DIR=""
run_lock() {
  local dir="$CONFIG_DIR/run.lock" pid
  [ -n "$RUN_LOCK_DIR" ] && return 0
  mkdir -p "$CONFIG_DIR" 2>/dev/null
  if ! mkdir "$dir" 2>/dev/null; then
    pid="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then
      err "another mimi run (pid $pid) is changing files; try again when it has finished"
      return 1
    fi
    # Justified raw rm: the pid file of a lock whose owner is gone.
    rm -f "$dir/pid"
    rmdir "$dir" 2>/dev/null
    mkdir "$dir" 2>/dev/null || { err "could not take the run lock: $dir"; return 1; }
  fi
  printf '%s\n' "$$" > "$dir/pid"
  RUN_LOCK_DIR="$dir"
}

run_unlock() {
  [ -n "$RUN_LOCK_DIR" ] || return 0
  # Justified raw rm: this run's own lock pid file.
  rm -f "$RUN_LOCK_DIR/pid"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null
  RUN_LOCK_DIR=""
}

say() {
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '%s\n' "$*" >&2
    printf '%s\n' "$*" >> "$LOG_FILE"
    return 0
  fi
  printf '%s\n' "$*"
  printf '%s\n' "$*" >> "$LOG_FILE"
}

section() {
  say ""
  say "${C_BOLD}${C_CYAN}== $* ==${C_RESET}"
}

# Diagnostics go to stderr, so `mimi scan > report.txt` keeps them visible.
say_err() {
  printf '%s\n' "$*" >&2
  printf '%s\n' "$*" >> "$LOG_FILE"
}

info() { say "${C_DIM}  $*${C_RESET}"; }
ok()   { say "${C_GREEN}  $*${C_RESET}"; }
warn() {
  say_err "${C_YELLOW}  $*${C_RESET}"
  [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_warning "" "$*"
  return 0
}
err()  { say_err "${C_RED}  $*${C_RESET}"; }
verbose() { [ "$VERBOSE" = 1 ] && say "${C_DIM}    [v] $*${C_RESET}"; return 0; }
