#!/usr/bin/env bats
#
# history.bats — `mimi history` (records, runs, logs) and `mimi history clear`.

load 'test_helper'
bats_require_minimum_version 1.5.0

HIST() { printf '%s' "$FAKE_HOME/.config/mimi/history.jsonl"; }
LOGS() { printf '%s' "$FAKE_HOME/Library/Logs/mimi"; }

seed_history() {
  mkdir -p "$FAKE_HOME/.config/mimi" "$(LOGS)"
  cat > "$(HIST)" <<'JSONL'
{"v":1,"at":"2026-09-27T10:00:00Z","type":"clean","status":"ok","freed_kb":2048,"removed":3,"log":"clean-20260927-100000.log"}
{"v":1,"at":"2026-09-27T11:00:00Z","type":"uninstall","status":"ok","app":"Slack","bundle_id":"com.example.slack"}
{"v":1,"at":"2026-09-27T12:00:00Z","type":"clean","status":"partial","freed_kb":10,"removed":1}
JSONL
  chmod 600 "$(HIST)"
  printf 'log\n' > "$(LOGS)/clean-20260927-100000.log"
  printf 'review\n' > "$(LOGS)/orphans-review-20260927.txt"
  printf 'not ours\n' > "$(LOGS)/notes.txt"
}

history_json() {
  run --separate-stderr /bin/bash "$MIMI_BIN" history --json --limit 50
  [ "$status" -eq 0 ]
}

@test "history --json: records carry ids, and mimi's own log files are listed" {
  seed_history
  history_json
  echo "$output" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema"] == "mimi.history/2", d
ids = [r["id"] for r in d["records"]]
assert ids == ["r1@2026-09-27T10:00:00Z", "r2@2026-09-27T11:00:00Z", "r3@2026-09-27T12:00:00Z"], ids
assert d["records"][0]["freed_kb"] == 2048
names = sorted(l["name"] for l in d["logs"])
assert names == ["clean-20260927-100000.log", "orphans-review-20260927.txt"], names
assert all(l["modified"].endswith("Z") for l in d["logs"])
'
}

@test "history clear: removes exactly the records and logs asked for" {
  seed_history
  run --separate-stderr /bin/bash "$MIMI_BIN" history clear --json --yes \
    --records "r2@2026-09-27T11:00:00Z" --logs "orphans-review-20260927.txt"
  [ "$status" -eq 0 ]
  echo "$output" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d == {"schema": "mimi.history-clear/1", "records_removed": 1, "logs_removed": 1, "not_found": 0}, d
'
  ! grep -q Slack "$(HIST)"
  [ "$(grep -c . "$(HIST)")" = 2 ]
  [ "$(file_mode "$(HIST)")" = 600 ]
  [ ! -e "$(LOGS)/orphans-review-20260927.txt" ]
  [ -f "$(LOGS)/clean-20260927-100000.log" ]
}

@test "history clear: an id whose line changed, or a file that is not mimi's, is left alone" {
  seed_history
  run --separate-stderr /bin/bash "$MIMI_BIN" history clear --json --yes \
    --records "r2@2026-01-01T00:00:00Z,r9@2026-09-27T11:00:00Z" \
    --logs "notes.txt,../history.jsonl,clean-missing.log"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q '"not_found": 5'
  [ "$(grep -c . "$(HIST)")" = 3 ]
  [ -f "$(LOGS)/notes.txt" ]
}

@test "history clear --all: every record and log goes, quarantine runs and other files stay" {
  seed_history
  mkdir -p "$FAKE_HOME/Library/Application Support/mimi/quarantine/run-keep"
  run /bin/bash "$MIMI_BIN" history clear --all --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Deleted 3 history record(s) and 2 log file(s)"
  [ ! -s "$(HIST)" ]
  [ -f "$(LOGS)/notes.txt" ]
  [ ! -e "$(LOGS)/clean-20260927-100000.log" ]
  [ -d "$FAKE_HOME/Library/Application Support/mimi/quarantine/run-keep" ]
  [ ! -e "$FAKE_HOME/.config/mimi/run.lock" ]
}

@test "history clear: nothing is deleted without a confirmation, and it needs a selection" {
  seed_history
  run /bin/bash "$MIMI_BIN" history clear --all --no-prompt < /dev/null
  [ "$status" -eq 5 ]
  [ "$(grep -c . "$(HIST)")" = 3 ]
  [ -f "$(LOGS)/clean-20260927-100000.log" ]
  run /bin/bash "$MIMI_BIN" history clear --yes
  [ "$status" -eq 1 ]
  run /bin/bash "$MIMI_BIN" history clear --all --logs x --yes
  [ "$status" -eq 1 ]
}

@test "history: a clean run is recorded with what it freed and its log" {
  mkdir -p "$FAKE_HOME/Library/Caches/com.example.junk"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/com.example.junk/data"
  run_clean --clean --yes --only caches
  [ "$status" -eq 0 ]
  local rec
  rec="$(tail -1 "$(HIST)")"
  echo "$rec" | grep -q '"type":"clean","status":"ok"'
  echo "$rec" | grep -q '"log":"clean-'
  local log
  log="$(echo "$rec" | sed -n 's/.*"log":"\([^"]*\)".*/\1/p')"
  [ -f "$(LOGS)/$log" ]
}

@test "history: a scan records nothing" {
  run_clean --scan --only caches
  [ "$status" -eq 0 ]
  [ ! -s "$(HIST)" ]
}
