#!/usr/bin/env bash
#
# lib/safety/action.sh lib/action.sh — Checked mutation layer (P0-T05) and the two removal primitives.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# ---------------------------------------------------------------------------
# Checked mutation layer
#
# Every filesystem removal in this script goes through fs_remove(). Nothing
# else calls rm. The reason is that the previous code did this:
#
#     rm -rf -- "$p" 2>>"$LOG_FILE"
#     TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size))
#     ok "removed: $p (freed ...)"
#
# — it reported success and credited the full size whether or not anything was
# actually deleted. A permission-denied cache directory produced a cheerful
# "freed 400M" and a summary total that was simply untrue.
#
# Two rules follow from that:
#   * the command's exit status is not evidence. `rm -rf` can delete half a
#     tree and leave the root, and it can fail for reasons it does not print.
#     The postcondition — is the thing gone? — is what decides.
#   * bytes are counted from a measured before/after difference on actions
#     that verifiably succeeded, never from a size taken before the attempt.
# ---------------------------------------------------------------------------

ACTION_OK=0        # verified: the target is gone
ACTION_SKIPPED=0   # not attempted: whitelisted, missing, refused, interrupted
ACTION_FAILED=0    # attempted, and the target is still there
ACTION_DENIED=0    # attempted, and the reason was permissions

# Set by fs_remove: ok | denied | failed.
FS_REMOVE_STATUS=""
FS_REMOVE_ERROR=""

# Set when a signal arrives. Checked before every action so that the run winds
# down instead of being killed halfway through a tree.
RUN_INTERRUPTED=0

record_action() {
  case "$1" in
    ok) ACTION_OK=$((ACTION_OK + 1)) ;;
    skipped) ACTION_SKIPPED=$((ACTION_SKIPPED + 1)) ;;
    denied) ACTION_DENIED=$((ACTION_DENIED + 1)) ;;
    *) ACTION_FAILED=$((ACTION_FAILED + 1)) ;;
  esac
  return 0
}

# True when at least one selected action did not do what was asked.
any_action_failed() {
  [ "$ACTION_FAILED" -gt 0 ] || [ "$ACTION_DENIED" -gt 0 ]
}

# The single checked removal. Returns 0 only when the target is verifiably
# gone afterwards; otherwise sets FS_REMOVE_STATUS to "denied" or "failed".
#
# Callers must have authorized the path already — this function deletes what
# it is given.
fs_remove() {
  local target="$1" rc=0

  FS_REMOVE_STATUS=""
  FS_REMOVE_ERROR=""

  FS_REMOVE_ERROR="$(rm -rf -- "$target" 2>&1)" || rc=$?
  [ -n "$FS_REMOVE_ERROR" ] && printf '%s\n' "$FS_REMOVE_ERROR" >> "$LOG_FILE"

  # The postcondition, not the exit status, is the evidence.
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    FS_REMOVE_STATUS="ok"
    return 0
  fi

  case "$FS_REMOVE_ERROR" in
    *"Permission denied"* | *"Operation not permitted"* | *"Read-only file system"*)
      FS_REMOVE_STATUS="denied"
      ;;
    *)
      # rc is kept for the log even though it did not decide the outcome.
      verbose "rm exited $rc and the target is still present: $target"
      FS_REMOVE_STATUS="failed"
      ;;
  esac
  return 1
}

# One place that turns an fs_remove outcome into a message and a count.
report_action() {
  local what="$1" bytes="${2:-0}"
  case "$FS_REMOVE_STATUS" in
    ok)
      record_action ok
      [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "ok" "$what" "$bytes"
      return 0
      ;;
    denied)
      record_action denied
      [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "denied" "$what" 0
      warn "permission denied, not removed: $what"
      ;;
    *)
      record_action failed
      [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "failed" "$what" 0
      err "failed to remove: $what"
      ;;
  esac
  return 1
}

# Run a delegated cleanup tool and account for what it actually did.
#
#   tool_cleanup "label" "<dir to measure, or empty>" cmd [args...]
#
# This is the delegated-command half of what fs_remove does for our own
# removals. Every one of these sites used to look like:
#
#     npm cache clean --force >>"$LOG_FILE" 2>&1
#     ok "npm cache cleaned (freed ...)"
#
# — the exit status was discarded, so a tool that refused to run, was not
# logged in, or died halfway still reported success. The freed figure was
# measured and therefore honest, but "cleaned" was not.
#
# The measured directory is optional: `docker system prune` and
# `tmutil thinlocalsnapshots` have no single directory whose shrinkage
# describes what they did, so they pass "" and report without a byte figure
# rather than inventing one.
TOOL_CLEANUP_RECLAIMED_KB=0
tool_cleanup() {
  local label="$1" measure="$2"
  shift 2
  local before=0 after=0 reclaimed=0 rc=0

  TOOL_CLEANUP_RECLAIMED_KB=0

  if interrupted; then
    record_action skipped
    verbose "interrupted, not started: $label"
    return 1
  fi

  if [ -n "$measure" ] && [ -e "$measure" ]; then
    before="$(dir_size_kb "$measure")"
  fi

  "$@" >> "$LOG_FILE" 2>&1 || rc=$?

  if [ -n "$measure" ]; then
    after=0
    [ -e "$measure" ] && after="$(dir_size_kb "$measure")"
    reclaimed=$((before - after))
    [ "$reclaimed" -lt 0 ] && reclaimed=0
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
    TOOL_CLEANUP_RECLAIMED_KB="$reclaimed"
  fi

  if [ "$rc" -ne 0 ]; then
    record_action failed
    err "$label failed (exit $rc) — see the log for what it said"
    if [ "$reclaimed" -gt 0 ]; then
      info "it did free $(human_kb "$reclaimed") before failing"
    fi
    return 1
  fi

  record_action ok
  if [ -n "$measure" ]; then
    ok "$label (freed $(human_kb "$reclaimed"))"
  else
    ok "$label"
  fi
  return 0
}

# Signal handling. The handler does not exit: killing the process mid-rm is
# how a half-deleted tree and a wrong total happen. It raises a flag instead,
# and every action checks the flag before starting.
_on_interrupt() {
  RUN_INTERRUPTED=1
  say ""
  warn "interrupted — finishing the action in progress, then stopping"
  return 0
}

# True when no further action should be started.
interrupted() {
  [ "$RUN_INTERRUPTED" = 1 ]
}

# Safety-checked recursive delete of a path's *contents* (keeps the dir itself).
# Usage: clear_dir_contents "/path/to/dir" "label"
#
# The directory itself may not be a symlink: `[ -d ]` is true for a symlink to
# a directory, and globbing through one would delete the contents of wherever
# it points — which is, by definition, not the location that was authorized.
clear_dir_contents() {
  local dir="$1" canon ident ident_now

  [ -d "$dir" ] || { verbose "skip (missing): $dir"; return 0; }

  if interrupted; then
    record_action skipped
    verbose "interrupted, not started: $dir"
    return 1
  fi
  if ! canon="$(path_authorize "$dir" no-symlink)"; then
    record_action skipped
    warn "refusing to clear: $dir ($(path_deny_message))"
    return 1
  fi
  if is_whitelisted "$canon"; then
    record_action skipped
    info "whitelisted, skipped: $dir"
    return 0
  fi
  if ! ident="$(path_identity "$canon")"; then
    record_action skipped
    warn "could not identify, skipped: $dir"
    return 1
  fi

  local before after entry entry_canon
  before="$(dir_size_kb "$canon")"

  if [ "$MODE" = "scan" ] || [ "$MODE" = "plan" ]; then
    info "would clear contents of: $dir ($(human_kb "$before"))"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
    plan_candidate_add "${CURRENT_CATEGORY_ID:-unknown}" "clear_dir_contents" "$canon" "$ident" "$((before * 1024))" "safe" "$dir"
    local cid
    cid="$(plan_candidate_id "${CURRENT_CATEGORY_ID:-unknown}" "$canon")"
    [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_candidate "${CURRENT_CATEGORY_ID:-unknown}" "$canon" "$before" "safe" "$cid"
    return 0
  fi

  # Sizing a large tree is not instant. Re-confirm the directory is still the
  # same object before deleting anything inside it.
  ident_now="$(path_identity "$canon")" || ident_now=""
  if [ "$ident_now" != "$ident" ]; then
    record_action skipped
    warn "target changed since it was checked, skipped: $dir"
    return 1
  fi

  local failed=0
  for entry in "$canon"/* "$canon"/.[!.]* "$canon"/..?*; do
    # A signal during a long directory stops the next entry, rather than the
    # process being killed partway through removing one.
    if interrupted; then
      record_action skipped
      verbose "interrupted, stopping before: $entry"
      break
    fi
    # -L as well as -e so a broken symlink is still cleaned up rather than
    # silently left behind forever.
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if ! entry_canon="$(path_authorize "$entry")"; then
      record_action skipped
      verbose "refused ($PATH_DENY_REASON), kept: $entry"
      continue
    fi
    if is_whitelisted "$entry_canon"; then
      record_action skipped
      verbose "whitelisted entry, kept: $entry"
      continue
    fi
    verbose "removing: $entry"
    if ! fs_remove "$entry"; then
      report_action "$entry"
      failed=$((failed + 1))
      continue
    fi
    record_action ok
    [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "ok" "$entry" 0
  done

  # Measured, not assumed: whatever is still there was not reclaimed.
  after="$(dir_size_kb "$canon")"
  local reclaimed=$((before - after))
  [ "$reclaimed" -lt 0 ] && reclaimed=0
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + before))
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
  if [ "$failed" -gt 0 ]; then
    warn "partly cleared: $dir  (freed $(human_kb "$reclaimed"), $failed entr(y/ies) could not be removed)"
    return 1
  fi
  ok "cleared: $dir  (freed $(human_kb "$reclaimed"))"
  [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "ok" "$dir" "$((reclaimed * 1024))"
  return 0
}

# Remove a single path outright (file, directory, or symlink), with the same
# safety checks. A symlink is allowed here because `rm` unlinks the link and
# never follows it; authorization is therefore done on the link's own location.
remove_path() {
  local p="$1" canon ident ident_now

  [ -e "$p" ] || [ -L "$p" ] || return 0

  if interrupted; then
    record_action skipped
    verbose "interrupted, not started: $p"
    return 1
  fi
  if ! canon="$(path_authorize "$p")"; then
    record_action skipped
    warn "refusing to remove: $p ($(path_deny_message))"
    return 1
  fi
  if is_whitelisted "$canon"; then
    record_action skipped
    info "whitelisted, skipped: $p"
    return 0
  fi
  if ! ident="$(path_identity "$canon")"; then
    record_action skipped
    warn "could not identify, skipped: $p"
    return 1
  fi

  local size
  size="$(dir_size_kb "$canon")"

  if [ "$MODE" = "scan" ] || [ "$MODE" = "plan" ]; then
    info "would remove: $p ($(human_kb "$size"))"
    TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + size))
    plan_candidate_add "${CURRENT_CATEGORY_ID:-unknown}" "remove_path" "$canon" "$ident" "$((size * 1024))" "safe" "$p"
    local cid
    cid="$(plan_candidate_id "${CURRENT_CATEGORY_ID:-unknown}" "$canon")"
    [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_candidate "${CURRENT_CATEGORY_ID:-unknown}" "$canon" "$size" "safe" "$cid"
    return 0
  fi

  ident_now="$(path_identity "$canon")" || ident_now=""
  if [ "$ident_now" != "$ident" ]; then
    record_action skipped
    warn "target changed since it was checked, skipped: $p"
    return 1
  fi

  verbose "removing: $canon"
  TOTAL_BEFORE_KB=$((TOTAL_BEFORE_KB + size))
  if ! fs_remove "$canon"; then
    # A partial removal still freed something; credit only what measurably went.
    local leftover reclaimed
    leftover="$(dir_size_kb "$canon")"
    reclaimed=$((size - leftover))
    [ "$reclaimed" -lt 0 ] && reclaimed=0
    TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + reclaimed))
    report_action "$p" "$reclaimed"
    return 1
  fi
  record_action ok
  [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_action_result "ok" "$canon" "$((size * 1024))"
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size))
  ok "removed: $p  (freed $(human_kb "$size"))"
  return 0
}
