#!/usr/bin/env bats
#
# purge.bats — Tests for Project Build Artifacts Purge Engine (Phase 11)
#

load 'test_helper'

@test "purge: discovers node_modules, target, .venv, and .build in project roots" {
  local dev="$FAKE_HOME/Dev"
  mkdir -p "$dev/my-node-app/node_modules"
  echo '{"name":"test"}' > "$dev/my-node-app/package.json"
  echo "dummy" > "$dev/my-node-app/node_modules/lib.js"

  mkdir -p "$dev/my-rust-app/target/debug"
  echo '[package]' > "$dev/my-rust-app/Cargo.toml"
  echo "binary" > "$dev/my-rust-app/target/debug/app"

  mkdir -p "$dev/my-python-app/.venv/bin"
  echo 'pytest' > "$dev/my-python-app/requirements.txt"
  echo "python" > "$dev/my-python-app/.venv/bin/python"

  mkdir -p "$dev/my-swift-app/.build"
  echo '// swift-tools-version:5.9' > "$dev/my-swift-app/Package.swift"
  echo "object" > "$dev/my-swift-app/.build/app.o"

  run "$MIMI_BIN" purge --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project Build Artifacts (Purge)"* ]]
  [[ "$output" == *"4 artifact folder(s)"* ]]
  [[ "$output" == *"my-node-app"* ]]
  [[ "$output" == *"[node_modules]"* ]]
  [[ "$output" == *"my-rust-app"* ]]
  [[ "$output" == *"[target]"* ]]
  [[ "$output" == *"my-python-app"* ]]
  [[ "$output" == *"[.venv]"* ]]
  [[ "$output" == *"my-swift-app"* ]]
  [[ "$output" == *"[.build]"* ]]
}

@test "purge: ignores generic build/vendor directory if not in a legitimate project root" {
  local dev="$FAKE_HOME/Dev"
  # Generic folder without package.json, Cargo.toml, composer.json, etc.
  mkdir -p "$dev/RandomFolder/build"
  mkdir -p "$dev/RandomFolder/vendor"
  echo "something" > "$dev/RandomFolder/build/file.txt"
  echo "something" > "$dev/RandomFolder/vendor/file.txt"

  run "$MIMI_BIN" purge --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No project build artifacts found"* ]]
}

@test "purge: respects whitelist protection" {
  local dev="$FAKE_HOME/Dev"
  mkdir -p "$dev/ProtectedApp/node_modules"
  echo '{"name":"protected"}' > "$dev/ProtectedApp/package.json"
  echo "module" > "$dev/ProtectedApp/node_modules/index.js"

  run "$MIMI_BIN" purge --whitelist "$dev/ProtectedApp/node_modules" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No project build artifacts found"* ]]
}

@test "purge: custom target directory scans specified folder" {
  local custom="$TEST_TMPDIR/CustomWorkspace"
  mkdir -p "$custom/SampleProject/node_modules"
  echo '{"name":"sample"}' > "$custom/SampleProject/package.json"
  echo "data" > "$custom/SampleProject/node_modules/data.js"

  run "$MIMI_BIN" purge "$custom" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SampleProject"* ]]
  [[ "$output" == *"[node_modules]"* ]]
}

@test "purge: --dry-run does not delete candidates" {
  local dev="$FAKE_HOME/Dev"
  mkdir -p "$dev/App/node_modules"
  echo '{"name":"app"}' > "$dev/App/package.json"
  echo "mod" > "$dev/App/node_modules/index.js"

  run "$MIMI_BIN" purge --dry-run
  [ "$status" -eq 0 ]
  [ -d "$dev/App/node_modules" ]
  [ -f "$dev/App/node_modules/index.js" ]
}

@test "purge: --yes permanently removes selected build artifacts and records history" {
  local dev="$FAKE_HOME/Dev"
  mkdir -p "$dev/App/node_modules"
  echo '{"name":"app"}' > "$dev/App/package.json"
  echo "mod" > "$dev/App/node_modules/index.js"

  run "$MIMI_BIN" purge --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purged 1 project build artifact(s)"* ]]
  [ ! -d "$dev/App/node_modules" ]
  # Project root and files are preserved
  [ -f "$dev/App/package.json" ]

  run "$MIMI_BIN" history
  [ "$status" -eq 0 ]
  [[ "$output" == *"purge"* ]]
}

@test "purge: --paths displays search paths" {
  run "$MIMI_BIN" purge --paths
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configured project purge search paths"* ]]
  [[ "$output" == *"~/Dev"* ]]
}

@test "purge: --json emits structured telemetry" {
  local dev="$FAKE_HOME/Dev"
  mkdir -p "$dev/App/node_modules"
  echo '{"name":"app"}' > "$dev/App/package.json"
  echo "mod" > "$dev/App/node_modules/index.js"

  run "$MIMI_BIN" purge --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"purge_scan"'* ]]
  [[ "$output" == *'"project":"App"'* ]]
  [[ "$output" == *'"type":"node_modules"'* ]]
  [ -d "$dev/App/node_modules" ]

  run "$MIMI_BIN" purge --yes --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"purge_cleanup"'* ]]
  [[ "$output" == *'"removed":1'* ]]
  [ ! -d "$dev/App/node_modules" ]
}
