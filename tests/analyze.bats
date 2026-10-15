#!/usr/bin/env bats
#
# analyze.bats — Tests for Interactive Storage Analyzer (Phase 8)
#

load 'test_helper'

@test "analyze: displays storage analysis card for a directory" {
  local fixture="$TEST_TMPDIR/fixture_analyze"
  mkdir -p "$fixture/sub_a" "$fixture/sub_b"
  dd if=/dev/zero of="$fixture/sub_a/large.dat" bs=1024 count=100 2>/dev/null
  dd if=/dev/zero of="$fixture/sub_b/small.dat" bs=1024 count=20 2>/dev/null

  ANALYZE_NO_PROMPT=1 run "$MIMI_BIN" analyze "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Storage Analysis:"* ]]
  [[ "$output" == *"Top Direct Folders:"* ]]
  [[ "$output" == *"sub_a/"* ]]
  [[ "$output" == *"sub_b/"* ]]
}

@test "analyze: --json outputs valid structured analysis document" {
  local fixture="$TEST_TMPDIR/fixture_analyze_json"
  mkdir -p "$fixture/dir1"
  dd if=/dev/zero of="$fixture/dir1/test.dat" bs=1024 count=50 2>/dev/null

  run "$MIMI_BIN" analyze "$fixture" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"storage_analysis"'* ]]
  [[ "$output" == *'"target":'* ]]
  [[ "$output" == *'"children":'* ]]
  [[ "$output" == *'"largest_files":'* ]]
}

@test "analyze: reports error on non-existent directory" {
  run "$MIMI_BIN" analyze "/nonexistent/path/for/mimi/analyze"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a directory"* ]]
}

@test "analyze: analyze_format_pct calculates correct proportions" {
  load_lib
  local p1 p2 p3
  p1="$(analyze_format_pct 50 100)"
  p2="$(analyze_format_pct 0 100)"
  p3="$(analyze_format_pct 25 0)"
  [ "$p1" = "50" ]
  [ "$p2" = "0" ]
  [ "$p3" = "0" ]
}
