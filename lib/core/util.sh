#!/usr/bin/env bash
#
# lib/core/util.sh lib/util.sh — Size formatting and measurement.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# True in the modes that must not change anything: a scan reports, a plan
# records. Every "act or just describe" decision in a category uses this, so a
# new mode cannot silently fall into the cleaning branch.
is_dry_run() {
  [ "$MODE" = "scan" ] || [ "$MODE" = "plan" ]
}

human_kb() {
  # $1 = size in KB (integer) -> "12.3M". Pure Bash: this runs once per listed
  # item, and forking awk for it dominated large reports. Integer arithmetic
  # reproduces printf "%.1f" exactly: the units are powers of two, so the
  # value is exact and ties round to even, as printf does.
  local kb="${1:-0}" u=K den=1 num q r
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  if [ "$kb" -ge 1073741824 ]; then u=T; den=1073741824
  elif [ "$kb" -ge 1048576 ]; then u=G; den=1048576
  elif [ "$kb" -ge 1024 ]; then u=M; den=1024
  fi
  num=$((kb * 10))
  q=$((num / den))
  r=$((num % den))
  if [ $((r * 2)) -gt "$den" ] || { [ $((r * 2)) -eq "$den" ] && [ $((q % 2)) -eq 1 ]; }; then
    q=$((q + 1))
  fi
  printf '%d.%d%s' $((q / 10)) $((q % 10)) "$u"
}

# ALLOCATED size: blocks actually occupied on the volume. This is the number
# that answers "how much would I get back", so it is what every size in this
# tool is measured with, and the only one that may be added to a reclaimed
# total.
#
# It is not the same as the logical (apparent) size, and for a sparse file the
# two differ enormously: a Docker.raw that Finder shows as 64G may occupy 5G.
# See path_logical_kb below.
#
# Known limitation: on APFS, du counts a cloned file's blocks against every
# clone, so a tree full of clones reports more than deleting it would free.
dir_size_kb() {
  local p="$1"
  [ -e "$p" ] || { printf '0'; return; }
  # -x: never cross a mount point. Without it, anything containing a mounted
  # volume (most visibly /Library, which has the Xcode simulator runtime
  # volumes under Developer/CoreSimulator) reports several times its real
  # on-disk size and every total built from it is wrong.
  # One process: `du -s` prints a single "<kb>\t<path>" line.
  local out
  out="$(du -skx "$p" 2>/dev/null)"
  out="${out##*$'\n'}"
  out="${out%%[[:space:]]*}"
  printf '%s' "${out:-0}"
}

# LOGICAL (apparent) size of a single file, in KB — what the file claims to be
# rather than what it occupies. Reporting only; never added to a reclaimed
# total, because these bytes may not exist on disk at all.
path_logical_kb() {
  local p="$1" bytes
  [ -f "$p" ] || { printf '0'; return; }
  bytes="$(file_size "$p" 2>/dev/null)" || { printf '0'; return; }
  printf '%s' $(((bytes + 1023) / 1024))
}

# True when a file is materially sparse: its logical size exceeds what it
# occupies by more than a quarter. VM disk images are the common case.
is_sparse_file() {
  local p="$1" logical allocated
  [ -f "$p" ] || return 1
  logical="$(path_logical_kb "$p")"
  allocated="$(dir_size_kb "$p")"
  [ "${logical:-0}" -gt 0 ] || return 1
  [ "${allocated:-0}" -gt 0 ] || return 1
  [ "$((logical - allocated))" -gt "$((logical / 4))" ]
}

# macOS ships no timeout(1), so this is the bash-3.2-safe equivalent. Used to
# stop an unresponsive Docker daemon from stalling the whole run: `docker info`
# happily blocks for minutes when Docker Desktop is starting up or wedged.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watch_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -TERM "$watch_pid" 2>/dev/null
  wait "$watch_pid" 2>/dev/null
  return "$rc"
}

# True only if the Docker daemon answers within a few seconds.
docker_daemon_ready() {
  command -v docker >/dev/null 2>&1 || return 1
  run_with_timeout 8 docker info >/dev/null 2>&1
}
