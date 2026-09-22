#!/usr/bin/env bash
#
# lib/load.sh — loads every library module, in order.
#
# Sourced by bin/mimi, and directly by the test suite when it needs to
# call a helper rather than observe it through a whole run:
#
#     . "$REPO_ROOT/lib/load.sh"
#
# Order matters only for the handful of load-time assignments. globals.sh sets
# HOME_DIR, which several later arrays interpolate; path.sh's FORBIDDEN_EXACT
# does the same. Everything else is function definitions, which bash resolves
# at call time, so the remaining order is for readability.

_mimi_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

for _mimi_module in globals log util validate confirm usage config path action core; do
  # shellcheck source=/dev/null
  . "$_mimi_lib_dir/$_mimi_module.sh"
done

unset _mimi_module _mimi_lib_dir
