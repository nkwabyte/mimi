#!/usr/bin/env bash
#
# lib/util.sh — Size formatting and measurement.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

human_kb() {
  # $1 = size in KB (integer) -> human string
  local kb="${1:-0}"
  awk -v kb="$kb" 'BEGIN{
    split("K M G T", u, " ")
    v = kb + 0
    i = 1
    while (v >= 1024 && i < 4) { v = v / 1024; i++ }
    printf "%.1f%s", v, u[i]
  }'
}

dir_size_kb() {
  local p="$1"
  [ -e "$p" ] || { printf '0'; return; }
  # -x: never cross a mount point. Without it, anything containing a mounted
  # volume (most visibly /Library, which has the Xcode simulator runtime
  # volumes under Developer/CoreSimulator) reports several times its real
  # on-disk size and every total built from it is wrong.
  du -skx "$p" 2>/dev/null | awk '{print $1}' | tail -1
}
