#!/usr/bin/env bats
#
# status.bats — Tests for System Health & Resource Diagnostics (Phase 7)
#

load 'test_helper'

@test "status: 'mimi status' outputs system health card" {
  run "$MIMI_BIN" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"System Health & Status"* ]]
  [[ "$output" == *"Memory"* ]]
  [[ "$output" == *"Disk"* ]]
}

@test "status: 'mimi status --json' outputs valid json health document" {
  run "$MIMI_BIN" status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"ok"'* ]]
  [[ "$output" == *'"type":"system_health"'* ]]
  [[ "$output" == *'"memory"'* ]]
  [[ "$output" == *'"disk"'* ]]
  [[ "$output" == *'"cpu"'* ]]
}

@test "status: render_health_bar produces expected bracket width" {
  load_lib
  local bar plain
  bar="$(render_health_bar 50 10)"
  plain="$(printf '%s' "$bar" | sed $'s/\033\\[[0-9;]*m//g')"
  [ "$plain" = "[█████░░░░░]" ]
}
