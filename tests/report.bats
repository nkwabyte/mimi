#!/usr/bin/env bats
#
# report.bats — P6-T05 largest files and P6-T07 stale downloads in --report.
# Both are report-only; the full --report walk is too slow for the suite, so
# the two sections are exercised directly against the fixture home.

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

# mdls date line for the mock, relative to now.
days_ago() {
  date -u -r "$(( $(date +%s) - $1 * 86400 ))" '+%Y-%m-%d %H:%M:%S +0000'
}

@test "large files: lists single files over the threshold, largest first, and removes nothing" {
  mkdir -p "$FAKE_HOME/VMs" "$FAKE_HOME/Projects"
  dd if=/dev/zero of="$FAKE_HOME/VMs/big.img" bs=1024k count=3 2>/dev/null
  dd if=/dev/zero of="$FAKE_HOME/Projects/medium.bin" bs=1024k count=2 2>/dev/null
  dd if=/dev/zero of="$FAKE_HOME/Projects/small.bin" bs=1024 count=100 2>/dev/null

  source_lib
  run report_large_files 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "big.img"
  echo "$output" | grep -q "medium.bin"
  ! echo "$output" | grep -q "small.bin"
  # Largest first.
  [ "$(echo "$output" | grep -n 'big.img' | cut -d: -f1)" -lt "$(echo "$output" | grep -n 'medium.bin' | cut -d: -f1)" ]
  echo "$output" | grep -q "mimi never removes these"
  [ -f "$FAKE_HOME/VMs/big.img" ]
}

@test "large files: a sparse file shows what it claims next to what it occupies" {
  mkdir -p "$FAKE_HOME/VMs"
  dd if=/dev/zero of="$FAKE_HOME/VMs/disk.raw" bs=1024k count=2 2>/dev/null
  # Extend logically to ~50 MB without allocating it.
  dd if=/dev/zero of="$FAKE_HOME/VMs/disk.raw" bs=1 count=1 seek=52428800 conv=notrunc 2>/dev/null
  source_lib
  run report_large_files 1
  echo "$output" | grep -q "disk.raw.*sparse file; claims"
}

@test "large files: a file that occupies less than the threshold on disk is not listed" {
  mkdir -p "$FAKE_HOME/VMs"
  # ~50 MB logical, almost nothing allocated (like an evicted iCloud file).
  dd if=/dev/zero of="$FAKE_HOME/VMs/hollow.raw" bs=1 count=1 seek=52428800 2>/dev/null
  source_lib
  run report_large_files 10
  ! echo "$output" | grep -q "hollow.raw"
}

@test "large files: nothing over the threshold says so" {
  source_lib
  run report_large_files 100000
  echo "$output" | grep -q "(none)"
}

@test "stale downloads: judged by last opened, then date added — never by modification time" {
  local D="$FAKE_HOME/Downloads"
  mkdir -p "$D/old-folder"
  printf 'x\n' > "$D/opened-long-ago.dmg"
  printf 'x\n' > "$D/opened-recently.zip"
  printf 'x\n' > "$D/never-opened-old.pdf"
  printf 'x\n' > "$D/never-opened-new.pdf"
  printf 'x\n' > "$D/no-metadata.txt"
  # Modification times say the opposite of the Spotlight dates: must be ignored.
  touch -t 201001010000 "$D/opened-recently.zip" "$D/never-opened-new.pdf" "$D/no-metadata.txt"
  export MOCK_MDLS_DATES="$TEST_TMPDIR/dates"
  {
    printf '%s|kMDItemLastUsedDate|%s\n' "$D/opened-long-ago.dmg" "$(days_ago 200)"
    printf '%s|kMDItemDateAdded|%s\n'    "$D/opened-long-ago.dmg" "$(days_ago 300)"
    printf '%s|kMDItemLastUsedDate|%s\n' "$D/opened-recently.zip" "$(days_ago 3)"
    printf '%s|kMDItemDateAdded|%s\n'    "$D/never-opened-old.pdf" "$(days_ago 120)"
    printf '%s|kMDItemDateAdded|%s\n'    "$D/never-opened-new.pdf" "$(days_ago 5)"
    printf '%s|kMDItemDateAdded|%s\n'    "$D/old-folder" "$(days_ago 400)"
  } > "$MOCK_MDLS_DATES"

  source_lib
  run report_stale_downloads 90
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "opened-long-ago.dmg  (last opened"
  echo "$output" | grep -q "never-opened-old.pdf  (added, never opened"
  echo "$output" | grep -q "old-folder"
  ! echo "$output" | grep -q "opened-recently.zip"
  ! echo "$output" | grep -q "never-opened-new.pdf"
  ! echo "$output" | grep -q "no-metadata.txt  ("
  echo "$output" | grep -q "1 item(s) have no Spotlight dates and were not judged"
  [ -f "$D/opened-long-ago.dmg" ]
}

@test "stale downloads: the threshold is configurable and validated" {
  run_mimi --report --downloads-stale-days abc
  [ "$status" -eq 1 ]
  run_mimi --report --large-file-mb -5
  [ "$status" -eq 1 ]
}

@test "stale downloads: no Downloads folder is not an error" {
  source_lib
  run report_stale_downloads 90
  [ "$status" -eq 0 ]
}
