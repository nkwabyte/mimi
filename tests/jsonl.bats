#!/usr/bin/env bats
#
# jsonl.bats — JSON Lines Protocol v1 and machine interface tests (P1-T06).

load 'test_helper'

run_jsonl() {
  local stdout_file="$TEST_TMPDIR/stdout.jsonl"
  local stderr_file="$TEST_TMPDIR/stderr.log"
  run /bin/bash -c '"$1" "${@:2}" > "'"$stdout_file"'" 2> "'"$stderr_file"'" < /dev/null' _ "$MIMI_BIN" "$@"
  output="$(cat "$stdout_file" 2>/dev/null || true)"
  stderr_output="$(cat "$stderr_file" 2>/dev/null || true)"
}

@test "jsonl: emitted lines on stdout are strictly valid JSON" {
  mkdir -p "$FAKE_HOME/Library/Caches/testapp"
  printf 'data\n' > "$FAKE_HOME/Library/Caches/testapp/cache.bin"

  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  # Every single line of stdout must parse as valid JSON
  /usr/bin/python3 -c '
import sys, json
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
assert len(lines) >= 3, f"too few lines: {len(lines)}"
for line in lines:
    data = json.loads(line)
    assert "type" in data
    assert "seq" in data
    assert "request_id" in data
    assert "timestamp" in data
' <<< "$output"
}

@test "jsonl: first event is hello with protocol_version 1 and capabilities" {
  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
lines = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
first = lines[0]
assert first["type"] == "hello"
assert first["seq"] == 1
assert first["protocol_version"] == 1
assert "engine_version" in first
assert first["plan_schema_version"] == 1
assert "scan" in first["capabilities"]
assert "clean" in first["capabilities"]
' <<< "$output"
}

@test "jsonl: emits phase_started and phase_finished for scan" {
  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
types = [e["type"] for e in events]
assert "phase_started" in types
assert "phase_finished" in types

started = next(e for e in events if e["type"] == "phase_started")
assert started["phase"] == "scan"

finished = next(e for e in events if e["type"] == "phase_finished")
assert finished["phase"] == "scan"
assert finished["status"] == "ok"
' <<< "$output"
}

@test "jsonl: candidate events contain category, path, size_kb, and risk" {
  mkdir -p "$FAKE_HOME/Library/Caches/sampleapp"
  printf 'sampledata123\n' > "$FAKE_HOME/Library/Caches/sampleapp/file.dat"

  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
candidates = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip() and json.loads(l).get("type") == "candidate"]
assert len(candidates) >= 1
c = candidates[0]
assert c["category"] == "caches"
assert "sampleapp" in c["path"]
assert isinstance(c["size_kb"], int)
assert "risk" in c
' <<< "$output"
}

@test "jsonl: final event is run_finished with status and exit_code" {
  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
last = events[-1]
assert last["type"] == "run_finished"
assert last["status"] == "ok"
assert last["exit_code"] == 0
assert isinstance(last["scanned_kb"], int)
assert isinstance(last["reclaimed_kb"], int)
assert isinstance(last["actions_ok"], int)
assert isinstance(last["actions_skipped"], int)
assert isinstance(last["actions_denied"], int)
assert isinstance(last["actions_failed"], int)
' <<< "$output"
}

@test "jsonl: seq numbers are strictly monotonically increasing" {
  mkdir -p "$FAKE_HOME/Library/Caches/app1"
  mkdir -p "$FAKE_HOME/Library/Caches/app2"
  printf '1' > "$FAKE_HOME/Library/Caches/app1/f"
  printf '2' > "$FAKE_HOME/Library/Caches/app2/f"

  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
seqs = [e["seq"] for e in events]
assert seqs == list(range(1, len(seqs) + 1)), f"seq mismatch: {seqs}"
' <<< "$output"
}

@test "jsonl: request-id is propagated into all events" {
  local my_req="custom-uuid-12345"
  run_jsonl --jsonl --request-id "$my_req" --scan --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
for e in events:
    assert e["request_id"] == "custom-uuid-12345", f"bad req_id in {e}"
' <<< "$output"
}

@test "jsonl: clean mode emits action_result events for removed items" {
  mkdir -p "$FAKE_HOME/Library/Caches/todelete"
  printf 'junk\n' > "$FAKE_HOME/Library/Caches/todelete/item"

  run_jsonl --jsonl --clean --yes --only caches --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
actions = [e for e in events if e.get("type") == "action_result"]
assert len(actions) >= 1
assert actions[0]["status"] == "ok"
assert "todelete" in actions[0]["path"]
' <<< "$output"
}

@test "jsonl: cancelled confirmation emits cancelled event and exits 5" {
  run_jsonl --jsonl --clean --only caches --no-log
  [ "$status" -eq 5 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
last = events[-1]
assert last["type"] == "run_finished"
assert last["status"] == "cancelled"
assert last["exit_code"] == 5
' <<< "$output"
}

@test "jsonl: report mode emits hello, phase report, and run_finished" {
  run_jsonl --jsonl --report --no-log
  [ "$status" -eq 0 ]

  /usr/bin/python3 -c '
import sys, json
events = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
types = [e["type"] for e in events]
assert "hello" in types
assert "phase_started" in types
assert "run_finished" in types
phase = next(e for e in events if e["type"] == "phase_started")
assert phase["phase"] == "report"
' <<< "$output"
}

@test "jsonl: human messages go to stderr, stdout has 0 non-json lines" {
  mkdir -p "$FAKE_HOME/Library/Caches/app1"
  printf 'test\n' > "$FAKE_HOME/Library/Caches/app1/data"

  run_jsonl --jsonl --scan --only caches --no-log
  [ "$status" -eq 0 ]

  # stderr should have the human output
  [[ "$stderr_output" == *"User caches"* ]]

  # stdout should have only JSON Lines
  /usr/bin/python3 -c '
import sys, json
for line in sys.stdin.read().splitlines():
    if line.strip():
        json.loads(line)
' <<< "$output"
}

@test "jsonl: --no-color suppresses all ANSI escape sequences" {
  run_mimi --no-color --scan --only caches --no-log
  [ "$status" -eq 0 ]
  # ANSI escape code \033[ or \x1b[
  ! printf '%s' "$output" | grep -q $'\033\['
}

@test "jsonl: --no-prompt flag disables interactive prompts" {
  # When --no-prompt is used without --yes, clean mode exits 5 immediately
  run_mimi --no-prompt --clean --only caches --no-log
  [ "$status" -eq 5 ]
}
