#!/usr/bin/env bats
#
# optimize.bats — Tests for macOS System & Cache Optimizations (Phase 7)
#

load 'test_helper'

@test "optimize: --dry-run prints preview actions and does not mutate" {
  run "$MIMI_BIN" optimize --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[preview]"* ]]
  [[ "$output" == *"Optimization pass complete"* ]]
}

@test "optimize: lints preferences and removes corrupted plist while preserving valid ones" {
  require_tool plutil
  local prefs="$FAKE_HOME/Library/Preferences"
  mkdir -p "$prefs"
  printf "INVALID NOT A PLIST" > "$prefs/com.broken.app.plist"
  printf '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>ok</key><true/></dict></plist>' > "$prefs/com.valid.app.plist"

  run "$MIMI_BIN" optimize
  [ "$status" -eq 0 ]
  [ ! -f "$prefs/com.broken.app.plist" ]
  [ -f "$prefs/com.valid.app.plist" ]
}

@test "optimize: whitelisted plist survives preference linting" {
  require_tool plutil
  local prefs="$FAKE_HOME/Library/Preferences"
  mkdir -p "$prefs"
  printf "INVALID NOT A PLIST" > "$prefs/com.protected.app.plist"

  run "$MIMI_BIN" optimize --whitelist "$prefs/com.protected.app.plist"
  [ "$status" -eq 0 ]
  [ -f "$prefs/com.protected.app.plist" ]
}

@test "optimize: refreshes QuickLook cache directory" {
  local ql_cache="$FAKE_HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
  mkdir -p "$ql_cache"
  touch "$ql_cache/thumbnail.db"

  run "$MIMI_BIN" optimize
  [ "$status" -eq 0 ]
  [ ! -f "$ql_cache/thumbnail.db" ]
}
