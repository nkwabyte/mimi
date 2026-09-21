#!/usr/bin/env bats
#
# smoke.bats — P0-T01 harness isolation + P0-T02 CLI characterization
#
# Tests here document the *current* public behavior of clean.sh.
# They must pass without touching the real home directory.
#
# Depends on: test_helper.bash, tests/mocks/bin/*

load 'test_helper'

# ---------------------------------------------------------------------------
# P0-T01: Harness isolation
# ---------------------------------------------------------------------------

@test "harness: fake HOME is isolated from real HOME" {
  # The real home must not equal the fake home set up by setup().
  [ "$HOME" != "$OLDPWD" ] || true   # OLDPWD is not HOME; just a guard
  # The key invariant: HOME points into the tmp fixture, not the user's dir.
  [[ "$HOME" == */cleanmymac-test-* ]]
}

@test "harness: mocks/bin is on PATH before real tools" {
  # mdfind mock returns empty — if the real mdfind ran it could return results.
  result="$(mdfind 'kMDItemContentType == com.apple.application-bundle' 2>/dev/null)"
  [ -z "$result" ]
}

@test "harness: sentinel inside fixture survives a dry scan" {
  run_clean --scan --only caches --no-log
  assert_fixture_sentinel_intact
}

@test "harness: escape detection fires when a sentinel is modified" {
  # Simulate a write that escaped the fixture, then assert the guard notices.
  printf 'tampered\n' > "$SENTINEL_SIBLING"
  run verify_sentinels
  [ "$status" -ne 0 ]
  [[ "$output" == *"ESCAPE DETECTED"* ]]
  [[ "$output" == *"modified"* ]]
  restore_sentinels
}

@test "harness: escape detection fires when a sentinel is deleted" {
  rm -f "$SENTINEL_PARENT"
  run verify_sentinels
  [ "$status" -ne 0 ]
  [[ "$output" == *"ESCAPE DETECTED"* ]]
  [[ "$output" == *"deleted"* ]]
  restore_sentinels
}

@test "harness: verify_sentinels passes when nothing escaped" {
  run verify_sentinels
  [ "$status" -eq 0 ]
}

@test "harness: config and logs are redirected inside the fixture" {
  run_clean --scan --only caches
  [ "$status" -eq 0 ]
  # A log was written, and it landed under the fake HOME, not the real one.
  [ -d "$FAKE_HOME/Library/Logs/cleanmymac" ]
  [[ "$output" == *"$FAKE_HOME"* ]]
}

@test "harness: TMPDIR is redirected inside the fixture" {
  [[ "$TMPDIR" == */cleanmymac-test-* ]]
}

# ---------------------------------------------------------------------------
# P0-T02: Basic CLI characterization
# ---------------------------------------------------------------------------

@test "cli: --help exits 0" {
  run_clean --help
  [ "$status" -eq 0 ]
}

@test "cli: --help output contains USAGE" {
  run_clean --help
  [[ "$output" == *"USAGE"* ]]
}

@test "cli: --help output contains MODES" {
  run_clean --help
  [[ "$output" == *"MODES"* ]]
}

@test "cli: --list exits 0" {
  run_clean --list
  [ "$status" -eq 0 ]
}

@test "cli: --list prints known category IDs" {
  run_clean --list
  [[ "$output" == *"caches"* ]]
  [[ "$output" == *"logs"* ]]
  [[ "$output" == *"npm"* ]]
  [[ "$output" == *"yarn"* ]]
  [[ "$output" == *"homebrew"* ]]
}

@test "cli: --list prints risk column" {
  run_clean --list
  [[ "$output" == *"safe"* ]]
  [[ "$output" == *"moderate"* ]]
  [[ "$output" == *"risky"* ]]
}

@test "cli: scan mode is default when a flag is supplied" {
  # --no-log is a safe flag that forces non-interactive mode.
  run_clean --no-log --only caches
  [ "$status" -eq 0 ]
  # Scan output uses "would" language, not "cleared" (which means clean ran).
  [[ "$output" == *"would"* ]] || [[ "$output" == *"scan"* ]] || [[ "$output" == *"Estimated"* ]]
}

@test "cli: --scan flag explicitly sets scan mode" {
  run_clean --scan --no-log --only caches
  [ "$status" -eq 0 ]
  [[ "$output" == *"Estimated reclaimable"* ]] || [[ "$output" == *"would"* ]] || [[ "$output" == *"scan"* ]]
}

@test "cli: --clean --yes --only caches runs without prompting" {
  run_clean --clean --yes --no-log --only caches
  [ "$status" -eq 0 ]
}

@test "cli: --only limits to only listed categories" {
  # Run with only=npm. The npm mock is a no-op so the run succeeds.
  run_clean --scan --no-log --only npm
  [ "$status" -eq 0 ]
  # The output must mention npm (section header or report line).
  [[ "$output" == *"npm"* ]]
}

@test "cli: --only with multiple comma-separated IDs runs those categories" {
  run_clean --scan --no-log --only caches,npm
  [ "$status" -eq 0 ]
  # Both section headers should appear.
  [[ "$output" == *"caches"* ]] || [[ "$output" == *"cache"* ]]
  [[ "$output" == *"npm"* ]]
}

@test "cli: --skip excludes a category from default scan" {
  # Run default scan but skip npm. Output should NOT mention an npm section
  # running (it may still appear in --list output but not in a skipped run).
  run_clean --scan --no-log --only npm --skip npm
  [ "$status" -eq 0 ]
  # npm was skipped so no npm section output.
  [[ "$output" != *"== npm"* ]]
}

@test "cli: --skip wins over --only" {
  run_clean --scan --no-log --only npm,caches --skip npm
  [ "$status" -eq 0 ]
  # npm must not appear as a run section.
  [[ "$output" != *"== npm"* ]]
}

@test "cli: unknown option exits 1" {
  run_clean --this-flag-does-not-exist
  [ "$status" -eq 1 ]
}

@test "cli: unknown option prints usage hint" {
  run_clean --this-flag-does-not-exist
  [[ "$output" == *"unknown option"* ]] || [[ "$output" == *"USAGE"* ]]
}

@test "cli: --scan does not remove fixture files" {
  # Create a file in the fake caches dir.
  local testfile="$FAKE_HOME/Library/Caches/test-cache-entry.txt"
  echo "keep me" > "$testfile"

  run_clean --scan --no-log --only caches
  [ "$status" -eq 0 ]

  # The file must still be there (scan never deletes).
  [ -f "$testfile" ]
}

@test "cli: --clean --yes removes fixture cache contents" {
  local testfile="$FAKE_HOME/Library/Caches/test-cache-entry.txt"
  echo "remove me" > "$testfile"

  run_clean --clean --yes --no-log --only caches
  [ "$status" -eq 0 ]

  # The file should be gone after a real clean.
  [ ! -f "$testfile" ]
}

@test "cli: --whitelist protects a path from being cleaned" {
  local testfile="$FAKE_HOME/Library/Caches/protected-app/data.txt"
  mkdir -p "$(dirname "$testfile")"
  echo "protect me" > "$testfile"

  run_clean --clean --yes --no-log --only caches \
    --whitelist "$FAKE_HOME/Library/Caches/protected-app"
  [ "$status" -eq 0 ]

  # Whitelisted file must survive even a --clean run.
  [ -f "$testfile" ]
}

# ---------------------------------------------------------------------------
# P0-T02: Configuration load/save characterization
# ---------------------------------------------------------------------------

@test "config: run without config file succeeds" {
  # No config file written — should use built-in defaults.
  run_clean --scan --no-log --only npm
  [ "$status" -eq 0 ]
}

@test "config: SELECTED_CATEGORIES in config is respected when no --only given" {
  # Write a config that selects only 'npm'.
  write_config "SELECTED_CATEGORIES=npm"

  run_clean --scan --no-log
  [ "$status" -eq 0 ]
  # npm section should appear in output.
  [[ "$output" == *"npm"* ]]
}

@test "config: --only overrides SELECTED_CATEGORIES from config" {
  write_config "SELECTED_CATEGORIES=npm"

  # Explicit --only pip should ignore config and run pip only.
  run_clean --scan --no-log --only pip
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip"* ]]
}
