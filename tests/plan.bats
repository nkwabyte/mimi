#!/usr/bin/env bats
#
# plan.bats — Unit tests for Transactional Execution Plan v1 (P2-T01).

load 'test_helper'

@test "plan: initializes plan with unique ID and host binding" {
  load_lib
  plan_init
  [ -n "$PLAN_ID" ]
  [ -n "$PLAN_CREATED_AT" ]
  [ -n "$PLAN_EXPIRES_AT" ]
  [ -n "$PLAN_HOSTNAME" ]
  [ -n "$PLAN_USER" ]
}

@test "plan: serialize produces valid JSON conforming to schemas/plan-v1.json" {
  load_lib
  plan_init "test-plan-001"
  plan_add_action "act-1" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "ident-1" 1024 "safe" "standard cache"
  plan_add_action "act-2" "trash" "clear_dir_contents" "$FAKE_HOME/.Trash" "ident-2" 2048 "irreversible" "empty trash"

  local plan_json
  plan_json="$(plan_serialize)"

  /usr/bin/python3 -c '
import sys, json
data = json.loads(sys.stdin.read())
assert data["schema_version"] == 1
assert data["plan_id"] == "test-plan-001"
assert data["summary"]["total_candidates"] == 2
assert data["summary"]["total_bytes"] == 3072
assert data["summary"]["risk_distribution"]["safe"] == 1
assert data["summary"]["risk_distribution"]["irreversible"] == 1
assert len(data["actions"]) == 2
assert data["actions"][0]["action_id"] == "act-1"
assert data["actions"][1]["action_id"] == "act-2"
' <<< "$plan_json"
}

@test "plan: compute_digest is deterministic and changes when actions change" {
  load_lib
  plan_init "test-plan-digest"
  plan_add_action "act-1" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "ident-1" 1024 "safe" "evidence"

  local d1 d2 d3
  d1="$(plan_compute_digest)"
  d2="$(plan_compute_digest)"
  [ "$d1" = "$d2" ]

  plan_add_action "act-2" "npm" "tool_cleanup" "" "" 500 "safe" "npm cache"
  d3="$(plan_compute_digest)"
  [ "$d1" != "$d3" ]
}

@test "plan: plan_save writes atomically with 0600 permissions" {
  load_lib
  plan_init "test-plan-save"
  plan_add_action "act-1" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "ident-1" 1024 "safe" "evidence"

  local target="$TEST_TMPDIR/saved-plan.json"
  plan_save "$target"
  [ -f "$target" ]

  # Check permissions: 0600 (-rw-------)
  local mode
  mode="$(stat -f "%Lp" "$target" 2>/dev/null || stat -c "%a" "$target" 2>/dev/null)"
  [ "$mode" = "600" ]

  /usr/bin/python3 -c '
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data["plan_id"] == "test-plan-save"
' "$target"
}

@test "planner: candidate IDs are deterministic and derived from category and target path" {
  load_lib
  local id1 id2 id3
  id1="$(plan_candidate_id "caches" "$FAKE_HOME/Library/Caches/app1")"
  id2="$(plan_candidate_id "caches" "$FAKE_HOME/Library/Caches/app1")"
  id3="$(plan_candidate_id "caches" "$FAKE_HOME/Library/Caches/app2")"
  [ "$id1" = "$id2" ]
  [ "$id1" != "$id3" ]
}

@test "planner: plan_build constructs actions from candidate IDs, never caller paths" {
  load_lib
  plan_candidate_add "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "ident-1" 1024 "safe" "evidence 1"
  plan_candidate_add "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app2" "ident-2" 2048 "safe" "evidence 2"
  [ "$(plan_candidate_count)" -eq 2 ]

  local cid1 cid2
  cid1="$(plan_candidate_id "caches" "$FAKE_HOME/Library/Caches/app1")"
  cid2="$(plan_candidate_id "caches" "$FAKE_HOME/Library/Caches/app2")"

  # Build with all candidates
  plan_build "" "plan-all"
  [ "${#PLAN_ACTIONS[@]}" -eq 2 ]

  # Build filtered by single candidate ID
  plan_build "$cid1" "plan-filtered"
  [ "${#PLAN_ACTIONS[@]}" -eq 1 ]
  [[ "${PLAN_ACTIONS[0]}" =~ "app1" ]]
}

@test "planner: recomputing plan updates digest and actions" {
  load_lib
  plan_candidate_add "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "ident-1" 1024 "safe" "evidence 1"
  plan_candidate_add "trash" "clear_dir_contents" "$FAKE_HOME/.Trash" "ident-2" 4096 "irreversible" "empty trash"

  local cid1
  cid1="$(plan_candidate_id "caches" "$FAKE_HOME/Library/Caches/app1")"

  plan_build "" "plan-full"
  local d1
  d1="$(plan_compute_digest)"

  # Selection changes
  plan_build "$cid1" "plan-partial"
  local d2
  d2="$(plan_compute_digest)"

  [ "$d1" != "$d2" ]
  [ "${#PLAN_ACTIONS[@]}" -eq 1 ]
}

@test "planner: plan_load parses plan file correctly in pure Bash" {
  load_lib
  plan_init "plan-roundtrip"
  plan_add_action "act-0001" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "ident-1" 1024 "safe" "evid"
  local plan_file="$TEST_TMPDIR/roundtrip.json"
  plan_save "$plan_file"

  # Clear memory
  plan_init "blank"
  [ "$PLAN_ID" = "blank" ]
  [ "${#PLAN_ACTIONS[@]}" -eq 0 ]

  plan_load "$plan_file"
  [ "$PLAN_ID" = "plan-roundtrip" ]
  [ "$PLAN_SCHEMA_VERSION" = "1" ]
  [ "${#PLAN_ACTIONS[@]}" -eq 1 ]
  [ -n "$PLAN_DIGEST" ]
}

@test "preflight: rejects tampered plan files with digest mismatch" {
  load_lib
  mkdir -p "$FAKE_HOME/Library/Caches/app1"
  local ident
  ident="$(path_identity "$FAKE_HOME/Library/Caches/app1")"
  plan_init "plan-tamper"
  plan_add_action "act-0001" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "$ident" 1024 "safe" "evid"
  local plan_file="$TEST_TMPDIR/tampered.json"
  plan_save "$plan_file"

  # Tamper with expected_bytes inside the file
  sed -e 's/"expected_bytes": 1024/"expected_bytes": 9999/' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

  run plan_preflight "$plan_file"
  [ "$status" -ne 0 ]
}

@test "preflight: rejects expired plan files" {
  load_lib
  mkdir -p "$FAKE_HOME/Library/Caches/app1"
  local ident
  ident="$(path_identity "$FAKE_HOME/Library/Caches/app1")"
  plan_init "plan-expired"
  plan_add_action "act-0001" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "$ident" 1024 "safe" "evid"
  local plan_file="$TEST_TMPDIR/expired.json"
  plan_save "$plan_file"

  # Set expires_at to 2020
  sed -e 's/"expires_at": "[^"]*"/"expires_at": "2020-01-01T00:00:00Z"/' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

  run plan_preflight "$plan_file"
  [ "$status" -ne 0 ]
}

@test "preflight: rejects plan when target identity has changed" {
  load_lib
  mkdir -p "$FAKE_HOME/Library/Caches/app1"
  plan_init "plan-ident"
  plan_add_action "act-0001" "caches" "clear_dir_contents" "$FAKE_HOME/Library/Caches/app1" "99999:99999" 1024 "safe" "evid"
  local plan_file="$TEST_TMPDIR/ident-changed.json"
  plan_save "$plan_file"

  run plan_preflight "$plan_file"
  [ "$status" -ne 0 ]
}

@test "quarantine: moves target and writes run manifest" {
  load_lib
  QUARANTINE_DIR="$TEST_TMPDIR/quarantine"
  quarantine_init_run "test-run-1"

  mkdir -p "$FAKE_HOME/Library/Caches/testcache"
  printf 'cachedata\n' > "$FAKE_HOME/Library/Caches/testcache/file.dat"
  local ident
  ident="$(path_identity "$FAKE_HOME/Library/Caches/testcache")"

  quarantine_target "act-0001" "caches" "$FAKE_HOME/Library/Caches/testcache" "$ident" 1024
  [ ! -e "$FAKE_HOME/Library/Caches/testcache" ]
  [ -d "$QUARANTINE_DIR/test-run-1" ]
  [ -f "$QUARANTINE_DIR/test-run-1/manifest.jsonl" ]

  # Quarantined target exists under quarantine run dir
  local quarantined
  quarantined="$(find "$QUARANTINE_DIR/test-run-1" -name "testcache__act-0001")"
  [ -n "$quarantined" ]
  [ -f "$quarantined/file.dat" ]
}

@test "quarantine: restores quarantined items to original location" {
  load_lib
  QUARANTINE_DIR="$TEST_TMPDIR/quarantine"
  quarantine_init_run "test-run-restore"

  mkdir -p "$FAKE_HOME/Library/Caches/restoreme"
  printf 'savedcontent\n' > "$FAKE_HOME/Library/Caches/restoreme/hello.txt"
  local ident
  ident="$(path_identity "$FAKE_HOME/Library/Caches/restoreme")"

  quarantine_target "act-0001" "caches" "$FAKE_HOME/Library/Caches/restoreme" "$ident" 1024
  [ ! -e "$FAKE_HOME/Library/Caches/restoreme" ]

  quarantine_restore_run "test-run-restore"
  [ -d "$FAKE_HOME/Library/Caches/restoreme" ]
  [ -f "$FAKE_HOME/Library/Caches/restoreme/hello.txt" ]
}

@test "quarantine: purge removes the quarantine run" {
  load_lib
  QUARANTINE_DIR="$TEST_TMPDIR/quarantine"
  quarantine_init_run "test-run-purge"
  [ -d "$QUARANTINE_DIR/test-run-purge" ]

  quarantine_purge_run "test-run-purge"
  [ ! -d "$QUARANTINE_DIR/test-run-purge" ]
}

@test "lifecycle: discover -> plan -> apply -> verify -> restore -> purge" {
  mkdir -p "$FAKE_HOME/Library/Caches/myapp"
  printf 'hello-lifecycle\n' > "$FAKE_HOME/Library/Caches/myapp/cache.db"

  # 1. Plan
  local plan_file="$TEST_TMPDIR/lifecycle-plan.json"
  run_clean --plan --only caches --plan-out "$plan_file"
  [ "$status" -eq 0 ]
  [ -f "$plan_file" ]
  [ -f "$FAKE_HOME/Library/Caches/myapp/cache.db" ]

  # 2. Apply
  run_clean --apply "$plan_file" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Caches/myapp/cache.db" ]

  # Extract plan_id
  local plan_id
  plan_id="$(sed -n 's/.*"plan_id": "\([^"]*\)".*/\1/p' "$plan_file" | head -1)"
  [ -n "$plan_id" ]

  # 3. Restore
  run_clean --restore "$plan_id"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/Library/Caches/myapp/cache.db" ]
  [ "$(cat "$FAKE_HOME/Library/Caches/myapp/cache.db")" = "hello-lifecycle" ]

  # 4. Re-apply and Purge
  local plan2="$TEST_TMPDIR/plan2.json"
  run_clean --plan --only caches --plan-out "$plan2"
  run_clean --apply "$plan2" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Caches/myapp/cache.db" ]

  local plan2_id
  plan2_id="$(sed -n 's/.*"plan_id": "\([^"]*\)".*/\1/p' "$plan2" | head -1)"
  run_clean --purge "$plan2_id" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$FAKE_HOME/.config/mimi/quarantine/$plan2_id" ]
}
