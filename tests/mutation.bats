#!/usr/bin/env bats
#
# mutation.bats — P0-T05: every removal is checked, and the numbers are true.
#
# The defect these guard: the previous code ran `rm -rf` without looking at the
# result, then printed "removed X (freed 400M)" and added 400M to the run
# total. A cache directory the user could not write produced a cheerful,
# entirely fictional success.

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
  MODE="clean"
}

# Make a directory whose contents cannot be unlinked, by removing write
# permission from the directory itself. Returns the path of a victim file.
make_unremovable() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'payload\n' > "$dir/locked"
  chmod 500 "$dir"
  printf '%s' "$dir/locked"
}

# Undo make_unremovable so teardown can clean up.
unlock() {
  chmod 700 "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# fs_remove: the postcondition decides, not the exit status
# ---------------------------------------------------------------------------

@test "fs_remove: reports ok when the target is verifiably gone" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/gone"
  fs_remove "$FAKE_HOME/Library/Caches/gone"
  [ "$FS_REMOVE_STATUS" = "ok" ]
  [ ! -e "$FAKE_HOME/Library/Caches/gone" ]
}

@test "fs_remove: reports denied when permissions are the reason" {
  source_lib
  local dir victim
  dir="$FAKE_HOME/Library/Caches/locked"
  victim="$(make_unremovable "$dir")"

  run fs_remove "$victim"
  [ "$status" -ne 0 ]
  unlock "$dir"
  [ -f "$victim" ]
}

@test "fs_remove: sets the denied status for a permission failure" {
  source_lib
  local dir victim
  dir="$FAKE_HOME/Library/Caches/locked"
  victim="$(make_unremovable "$dir")"

  fs_remove "$victim" || true
  unlock "$dir"
  [ "$FS_REMOVE_STATUS" = "denied" ]
}

@test "fs_remove: a target that survives a zero-exit rm is still a failure" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/liar"
  # An rm that claims success and does nothing. The whole point of checking the
  # postcondition is that the command's word is not evidence.
  rm() { return 0; }

  run fs_remove "$FAKE_HOME/Library/Caches/liar"
  [ "$status" -ne 0 ]
  [ -d "$FAKE_HOME/Library/Caches/liar" ]
}

@test "fs_remove: a missing target is ok, not a failure" {
  source_lib
  fs_remove "$FAKE_HOME/Library/Caches/never-existed"
  [ "$FS_REMOVE_STATUS" = "ok" ]
}

@test "fs_remove: unlinks a symlink without following it" {
  source_lib
  mkdir -p "$FAKE_HOME/real"
  printf 'precious\n' > "$FAKE_HOME/real/data"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"

  fs_remove "$FAKE_HOME/Library/Caches/link"
  [ "$FS_REMOVE_STATUS" = "ok" ]
  [ -f "$FAKE_HOME/real/data" ]
}

# ---------------------------------------------------------------------------
# Byte accounting
# ---------------------------------------------------------------------------

@test "accounting: a failed removal does not inflate the reclaimed total" {
  source_lib
  local dir
  dir="$FAKE_HOME/Library/Caches/locked"
  mkdir -p "$dir"
  dd if=/dev/zero of="$dir/blob" bs=1024 count=500 2>/dev/null
  chmod 500 "$dir"

  TOTAL_RECLAIMED_KB=0
  remove_path "$dir/blob" || true
  unlock "$dir"

  [ "$TOTAL_RECLAIMED_KB" -eq 0 ]
  [ -f "$dir/blob" ]
}

@test "accounting: a failed removal does not print a success message" {
  source_lib
  local dir
  dir="$FAKE_HOME/Library/Caches/locked"
  mkdir -p "$dir"
  printf 'payload\n' > "$dir/blob"
  chmod 500 "$dir"

  run remove_path "$dir/blob"
  unlock "$dir"
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q 'removed:'
  echo "$output" | grep -qi 'permission denied'
}

@test "accounting: a successful removal credits its size exactly once" {
  source_lib
  local dir size
  dir="$FAKE_HOME/Library/Caches/big"
  mkdir -p "$dir"
  dd if=/dev/zero of="$dir/blob" bs=1024 count=500 2>/dev/null
  size="$(dir_size_kb "$dir")"

  TOTAL_RECLAIMED_KB=0
  remove_path "$dir"
  [ "$TOTAL_RECLAIMED_KB" -eq "$size" ]
  [ ! -e "$dir" ]
}

@test "accounting: clear_dir_contents credits only what measurably went" {
  source_lib
  local base locked
  base="$FAKE_HOME/Library/Caches/mixed"
  mkdir -p "$base/removable"
  dd if=/dev/zero of="$base/removable/blob" bs=1024 count=400 2>/dev/null
  locked="$base/locked"
  mkdir -p "$locked"
  dd if=/dev/zero of="$locked/blob" bs=1024 count=400 2>/dev/null
  chmod 500 "$locked"

  TOTAL_RECLAIMED_KB=0
  clear_dir_contents "$base" || true
  unlock "$locked"

  # The removable half went; the locked half did not and was not credited.
  [ ! -e "$base/removable" ]
  [ -f "$locked/blob" ]
  [ "$TOTAL_RECLAIMED_KB" -gt 300 ]
  [ "$TOTAL_RECLAIMED_KB" -lt 600 ]
}

@test "accounting: a partly-cleared directory says so instead of claiming success" {
  source_lib
  local base locked
  base="$FAKE_HOME/Library/Caches/mixed"
  mkdir -p "$base/removable"
  locked="$base/locked"
  mkdir -p "$locked"
  printf 'x\n' > "$locked/blob"
  chmod 500 "$locked"

  run clear_dir_contents "$base"
  unlock "$locked"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'partly cleared'
}

# ---------------------------------------------------------------------------
# Outcome counters
# ---------------------------------------------------------------------------

@test "counters: success, skipped, denied and failed are recorded separately" {
  source_lib
  ACTION_OK=0; ACTION_SKIPPED=0; ACTION_DENIED=0; ACTION_FAILED=0

  mkdir -p "$FAKE_HOME/Library/Caches/gone"
  remove_path "$FAKE_HOME/Library/Caches/gone"
  [ "$ACTION_OK" -eq 1 ]

  mkdir -p "$FAKE_HOME/Library/Caches/kept"
  WHITELIST=("$FAKE_HOME/Library/Caches/kept")
  remove_path "$FAKE_HOME/Library/Caches/kept"
  [ "$ACTION_SKIPPED" -eq 1 ]
  WHITELIST=()

  local dir
  dir="$FAKE_HOME/Library/Caches/locked"
  mkdir -p "$dir"
  printf 'x\n' > "$dir/blob"
  chmod 500 "$dir"
  remove_path "$dir/blob" || true
  unlock "$dir"
  [ "$ACTION_DENIED" -eq 1 ]
  [ "$ACTION_FAILED" -eq 0 ]
}

@test "counters: any_action_failed covers both failed and denied" {
  source_lib
  ACTION_FAILED=0; ACTION_DENIED=0
  ! any_action_failed
  ACTION_DENIED=1
  any_action_failed
  ACTION_DENIED=0; ACTION_FAILED=1
  any_action_failed
}

@test "counters: a refused path is skipped, not failed" {
  source_lib
  ACTION_SKIPPED=0; ACTION_FAILED=0
  printf 'x\n' > "$SENTINEL_PARENT.extra"
  remove_path "$SENTINEL_PARENT.extra" || true
  rm -f "$SENTINEL_PARENT.extra"
  [ "$ACTION_SKIPPED" -eq 1 ]
  [ "$ACTION_FAILED" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Interruption
# ---------------------------------------------------------------------------

@test "interrupt: no further action is started once the flag is raised" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/survivor"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/survivor/data"

  RUN_INTERRUPTED=1
  ACTION_SKIPPED=0
  remove_path "$FAKE_HOME/Library/Caches/survivor" || true
  [ -f "$FAKE_HOME/Library/Caches/survivor/data" ]
  [ "$ACTION_SKIPPED" -eq 1 ]
}

@test "interrupt: clear_dir_contents does not start either" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/survivor/inner"
  RUN_INTERRUPTED=1
  clear_dir_contents "$FAKE_HOME/Library/Caches/survivor" || true
  [ -d "$FAKE_HOME/Library/Caches/survivor/inner" ]
}

@test "interrupt: the handler raises the flag rather than exiting" {
  source_lib
  RUN_INTERRUPTED=0
  run _on_interrupt
  [ "$status" -eq 0 ]
  _on_interrupt > /dev/null
  [ "$RUN_INTERRUPTED" = 1 ]
  interrupted
}

# ---------------------------------------------------------------------------
# .DS_Store — the other place that counted finds as removals
# ---------------------------------------------------------------------------

@test "dsstore: an unremovable file is not counted as removed" {
  source_lib
  local dir
  dir="$FAKE_HOME/Library/Caches/locked"
  mkdir -p "$dir"
  printf 'x\n' > "$dir/.DS_Store"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/.DS_Store"
  chmod 500 "$dir"

  run cat_dsstore
  unlock "$dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'removed 1 of 2'
  [ -f "$dir/.DS_Store" ]
  [ ! -e "$FAKE_HOME/Library/Caches/.DS_Store" ]
}

@test "dsstore: all-removable reports plain success" {
  source_lib
  printf 'x\n' > "$FAKE_HOME/Library/Caches/.DS_Store"
  run cat_dsstore
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'removed 1 .DS_Store'
}

# ---------------------------------------------------------------------------
# Exit codes, end to end
# ---------------------------------------------------------------------------

@test "exit: a clean run with nothing failing exits 0" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/data"
  run_clean --clean --yes --only caches
  [ "$status" -eq 0 ]
}

@test "exit: a run with a failed action exits 3, not 0" {
  local dir
  dir="$FAKE_HOME/Library/Caches/locked"
  mkdir -p "$dir/inner"
  printf 'x\n' > "$dir/inner/data"
  chmod 500 "$dir"

  run_clean --clean --yes --only caches
  unlock "$dir"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'permission-denied'
}

@test "exit: the summary reports the outcome counts" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/data"
  run_clean --clean --yes --only caches
  echo "$output" | grep -qE 'Actions: [0-9]+ succeeded, [0-9]+ skipped, [0-9]+ permission-denied, [0-9]+ failed'
}

@test "exit: a scan never reports failures it did not attempt" {
  local dir
  dir="$FAKE_HOME/Library/Caches/locked"
  mkdir -p "$dir/inner"
  chmod 500 "$dir"

  run_clean --scan --only caches
  unlock "$dir"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structural: nothing outside the checked layer may delete
# ---------------------------------------------------------------------------
@test "structure: the only raw removals left are the tool's own log housekeeping" {
  local found expected
  # Every shell file in the tree, so moving code between modules cannot lose
  # the guard. Non-comment lines that delete something, sorted so the answer
  # does not depend on which module they ended up in.
  found="$(grep -hE '(^|[^_[:alnum:]])rm[[:space:]]+-|find .*-delete' \
      "$CLEAN_SH" "$CLEANMYMAC_BIN" "$CLEANMYMAC_LIB"/*.sh \
    | grep -vE '^[[:space:]]*#' \
    | grep -vE 'FS_REMOVE_ERROR=' \
    | grep -vE 'info "Delete one with' \
    | sed -E 's/^[[:space:]]+//' | sort)"

  # Exactly these three, all operating on this tool's own log directory.
  # save_config writes to a temporary file and renames it into place; the two
  # rm's below clean up that temporary file when the write or the rename fails.
  expected="$(printf '%s\n' \
    'find "$LOG_DIR" -maxdepth 1 -name '"'"'orphans-review-*.txt'"'"' -mtime +30 -delete 2>/dev/null' \
    'rm -f "$LOG_FILE"' \
    'rm -f "$f"' \
    'rm -f "$tmp"' \
    'rm -f "$tmp"' | sort)"

  if [ "$found" != "$expected" ]; then
    echo "A raw removal appeared outside fs_remove. Route it through fs_remove," >&2
    echo "or justify it here and add it to the expected list." >&2
    echo "--- found ---" >&2
    echo "$found" >&2
    echo "--- expected ---" >&2
    echo "$expected" >&2
    return 1
  fi
}

@test "structure: every justified raw removal carries its justification" {
  grep -qr "Justified raw rm: this is the tool's own transcript housekeeping" "$CLEANMYMAC_LIB"
  grep -qr 'Justified raw rm: the scratch log this process created' "$CLEANMYMAC_LIB"
  grep -qr 'raw delete for the same reason as the rm above' "$CLEANMYMAC_LIB"
  grep -qr 'Justified raw rm: our own half-written temporary file' "$CLEANMYMAC_LIB"
}
