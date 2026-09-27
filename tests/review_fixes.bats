#!/usr/bin/env bats
#
# review_fixes.bats — regression tests for docs/SYSTEM_REVIEW_2026-09-27.md.
# Each test is named after the finding it guards.

load 'test_helper'
bats_require_minimum_version 1.5.0

# The plan file a `mimi plan` run wrote.
plan_path_from() {
  printf '%s\n' "$1" | sed -n 's/^Plan file: //p' | head -1
}

# Commands that only read: a plan may run these and nothing else.
read_only_call() {
  case "$1" in
    "brew --cache" | "brew --cellar" | "brew autoremove --dry-run" | "docker info" | \
    "go env GOCACHE" | "npm config get cache" | "pip3 cache dir" | "pip cache dir" | \
    "pnpm store path" | "tmutil listlocalsnapshots /" | "xcrun simctl list"* | \
    "yarn cache dir" | "yarn --version" | "uv cache dir" | "docker system df") return 0 ;;
  esac
  return 1
}

@test "R-01: plan runs no cleanup command in any profile" {
  mkdir -p "$FAKE_HOME/.npm/_cacache" "$FAKE_HOME/Library/Caches/Homebrew"
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"
  local p line
  for p in safe developer aggressive; do
    run_mimi plan --profile "$p" --include-docker --include-sim-stale --include-android --no-color
    [ "$status" -eq 0 ]
  done
  while IFS= read -r line; do
    read_only_call "$line" || { echo "plan ran: $line" >&2; return 1; }
  done < "$MOCK_CALL_LOG"
}

@test "R-01: a planned tool cleanup runs at apply, once" {
  mkdir -p "$FAKE_HOME/.npm/_cacache"
  run_mimi plan --only npm --no-color
  local plan
  plan="$(plan_path_from "$output")"
  [ -f "$plan" ]
  grep -q '"operation": "tool_cleanup"' "$plan"

  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"
  run_mimi apply "$plan" --yes --no-color
  [ "$status" -eq 0 ]
  [ "$(grep -c '^npm cache clean' "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "R-02: --yes alone cannot apply a plan with an irreversible category" {
  mkdir -p "$FAKE_HOME/.Trash/old"
  run_mimi plan --only trash --include-trash --no-color
  local plan
  plan="$(plan_path_from "$output")"

  run_mimi apply "$plan" --yes --no-color
  [ "$status" -eq 5 ]
  [ -d "$FAKE_HOME/.Trash/old" ]
}

@test "R-02: an edited expiry is refused as an edit" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  run_mimi plan --only caches --no-color
  local plan
  plan="$(plan_path_from "$output")"
  sed_i 's/"expires_at": ".*"/"expires_at": "2099-01-01T00:00:00Z"/' "$plan"

  run_mimi apply "$plan" --yes --no-color
  [ "$status" -eq 6 ]
  echo "$output" | grep -q "digest mismatch"
}

@test "R-02: a hand-made plan cannot widen what is removed" {
  mkdir -p "$FAKE_HOME/Documents/thesis"
  printf 'precious\n' > "$FAKE_HOME/Documents/thesis/ch1.txt"
  load_lib
  plan_init "plan-crafted-1"
  plan_add_action act-0001 caches remove_path "$FAKE_HOME/Documents" \
    "$(path_identity "$FAKE_HOME/Documents")" 0 safe "x"
  plan_save "$TEST_TMPDIR/crafted.json"

  run_mimi apply "$TEST_TMPDIR/crafted.json" --yes --no-color
  [ "$status" -eq 6 ]
  echo "$output" | grep -q "would not select this now"
  [ -f "$FAKE_HOME/Documents/thesis/ch1.txt" ]
}

@test "R-06: a whitelisted path nested inside a cleared folder survives" {
  local base="$FAKE_HOME/Library/Caches/com.junk"
  mkdir -p "$base/sub/keep" "$base/other"
  printf 'k\n' > "$base/sub/keep/k"
  printf 'o\n' > "$base/other/o"

  run_clean --clean --yes --only caches --whitelist "$base/sub/keep"
  [ "$status" -eq 0 ]
  [ -f "$base/sub/keep/k" ]
  [ ! -e "$base/other" ]
}

@test "R-07: applying a cleared folder keeps the folder and quarantines its contents" {
  mkdir -p "$FAKE_HOME/.Trash/sub"
  printf 't\n' > "$FAKE_HOME/.Trash/sub/f"
  run_mimi plan --only trash --include-trash --no-color
  local plan
  plan="$(plan_path_from "$output")"

  run_mimi apply "$plan" --yes --force-risky trash --no-color
  [ "$status" -eq 0 ]
  [ -d "$FAKE_HOME/.Trash" ]
  [ ! -e "$FAKE_HOME/.Trash/sub" ]
  echo "$output" | grep -q "Moved to quarantine"
}

@test "R-05: a cross-volume move keeps the copy when the original cannot be removed" {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  QUARANTINE_DIR="$TEST_TMPDIR/q"
  local target="$FAKE_HOME/Library/Caches/app"
  mkdir -p "$target"
  printf 'x\n' > "$target/data"
  # Pretend the quarantine is on another volume, and the removal fails.
  file_device() {
    case "$1" in "$QUARANTINE_DIR"*) printf '2\n' ;; *) printf '1\n' ;; esac
  }
  fs_remove() { FS_REMOVE_STATUS="denied"; return 1; }

  run quarantine_target "act-1" "caches" "$target"
  [ "$status" -ne 0 ]
  [ -f "$target/data" ]
  ls "$QUARANTINE_DIR"/*/app__act-1/data
  grep -q '"status":"partial"' "$QUARANTINE_DIR"/*/manifest.jsonl
}

@test "R-10: history counts an empty run and a conflicts-only restore" {
  local q="$FAKE_HOME/Library/Application Support/mimi/quarantine"
  mkdir -p "$q/run-empty" "$q/run-conflict"
  : > "$q/run-empty/manifest.jsonl"
  printf '{"action_id":"a"}\n' > "$q/run-conflict/manifest.jsonl"
  printf '{"status":"conflict"}\n' > "$q/run-conflict/restore.jsonl"

  run --separate-stderr /bin/bash "$MIMI_BIN" history --json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | /usr/bin/python3 -c '
import json, sys
runs = {r["run_id"]: r for r in json.load(sys.stdin)["quarantine_runs"]}
assert runs["run-empty"]["items"] == 0, runs
assert runs["run-conflict"]["items"] == 1 and runs["run-conflict"]["restored"] == 0, runs
'
}

@test "R-11: file names with control characters stay valid JSON" {
  local odd="$FAKE_HOME/Library/Caches/app"$'\x01'"name"$'\x1b'
  mkdir -p "$odd"
  printf 'x\n' > "$odd/data"
  run --separate-stderr /bin/bash "$MIMI_BIN" --jsonl scan --only caches --include-caches --no-color
  [ "$status" -eq 0 ]
  echo "$output" | /usr/bin/python3 -c '
import json, sys
paths = [json.loads(l).get("path", "") for l in sys.stdin if l.strip()]
assert any("\x01" in p and "\x1b" in p for p in paths), paths
'
}

@test "R-13: a second mutating run is refused while one holds the lock" {
  mkdir -p "$FAKE_HOME/.config/mimi/run.lock"
  sleep 30 &
  local holder=$!
  printf '%s\n' "$holder" > "$FAKE_HOME/.config/mimi/run.lock/pid"

  run_clean --clean --yes --only caches
  kill "$holder" 2>/dev/null
  [ "$status" -eq 7 ]
  echo "$output" | grep -q "another mimi run"
}

@test "R-13: a lock left by a finished run is taken over" {
  mkdir -p "$FAKE_HOME/.config/mimi/run.lock"
  printf '999999\n' > "$FAKE_HOME/.config/mimi/run.lock/pid"
  run_clean --clean --yes --only caches
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.config/mimi/run.lock" ]
}

@test "R-15: warnings go to stderr, and logs are private" {
  run --separate-stderr /bin/bash "$MIMI_BIN" scan --only trash --no-color
  [ "$status" -eq 0 ]
  echo "$stderr" | grep -q "opt-in only"
  ! echo "$output" | grep -q "opt-in only"
  local log
  log="$(ls "$FAKE_HOME/Library/Logs/mimi"/clean-*.log | head -1)"
  [ "$(file_mode "$FAKE_HOME/Library/Logs/mimi")" = "700" ]
  [ "$(file_mode "$log")" = "600" ]
}

@test "O-7: the engine's exit handler keeps an exit trap that was already set" {
  run /bin/bash -c '
    trap "echo prior-ran rc=\$?" EXIT
    . "$1/load.sh"
    LOG_DIR="$2/logs"
    log_init
    tui_begin
    exit 4
  ' _ "$MIMI_LIB" "$TEST_TMPDIR"
  [ "$status" -eq 4 ]
  [ "$(echo "$output" | grep -c 'prior-ran rc=4')" -eq 1 ]
}

@test "O-7: a subshell never runs the parent's exit trap" {
  run /bin/bash -c '
    trap "echo parent-trap-ran" EXIT
    . "$1/load.sh"
    LOG_DIR="$2/logs"
    ( log_init; tui_begin; exit 3 )
    echo "subshell=$?"
    trap - EXIT
  ' _ "$MIMI_LIB" "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "subshell=3" ]
}
