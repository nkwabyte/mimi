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

for _mimi_module in \
  core/globals.sh \
  ui/theme.sh \
  core/platform.sh \
  ui/log.sh \
  ui/spinner.sh \
  core/util.sh \
  ui/json.sh \
  transaction/plan.sh \
  transaction/quarantine.sh \
  core/validate.sh \
  safety/confirm.sh \
  ui/usage.sh \
  core/config.sh \
  safety/path.sh \
  safety/action.sh \
  cleaners/registry.sh \
  cleaners/categories.sh \
  cleaners/orphans.sh \
  cleaners/hints.sh \
  cleaners/optimize.sh \
  apps/inventory.sh \
  apps/receipts.sh \
  apps/evidence.sh \
  apps/inspect.sh \
  apps/process.sh \
  apps/uninstall.sh \
  ui/report.sh \
  ui/health.sh \
  ui/analyze.sh \
  ui/touchid.sh \
  ui/menu_paginated.sh \
  ui/tui.sh \
  core/core.sh; do
  # shellcheck source=/dev/null
  . "$_mimi_lib_dir/$_mimi_module"
done

unset _mimi_module _mimi_lib_dir
