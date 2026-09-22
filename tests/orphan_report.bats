#!/usr/bin/env bats
#
# orphan_report.bats — P0-T06: heuristic orphan discovery is report-only.
#
# The scan reasons from absence: an entry is listed because no installed
# application claimed its name. Every fixture here is a case where that
# inference is wrong, or where it cannot be made at all.

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

APPSUP() { printf '%s' "$FAKE_HOME/Library/Application Support"; }
CONTAINERS() { printf '%s' "$FAKE_HOME/Library/Containers"; }

# Build an installed-application index the mocked mdfind/mdls/defaults serve.
# Each argument is "<app path>|<bundle id>"; the .app bundle is created too, so
# the direct directory walk sees it as well.
install_apps() {
  local entry app
  export MOCK_APP_INDEX="$TEST_TMPDIR/app-index"
  : > "$MOCK_APP_INDEX"
  mkdir -p "$FAKE_HOME/Applications"
  for entry in "$@"; do
    app="${entry%%|*}"
    mkdir -p "$app/Contents"
    printf '%s\n' "$entry" >> "$MOCK_APP_INDEX"
  done
  # Confine the direct app walk to the fixture. The mocks cannot intercept a
  # directory walk, so without this the developer's real /Applications and
  # /System/Applications are read and the results depend on what they happen
  # to have installed.
  ORPHAN_APP_WALK_ROOTS=("$FAKE_HOME/Applications")
}

# Index position of a candidate path, or "" when it was not listed at all.
candidate_tier() {
  local want="$1" i n="${#ORPHAN_CANDIDATE_PATHS[@]}"
  for ((i = 0; i < n; i++)); do
    if [ "${ORPHAN_CANDIDATE_PATHS[$i]}" = "$want" ]; then
      printf '%s' "${ORPHAN_CANDIDATE_TIERS[$i]}"
      return 0
    fi
  done
  return 1
}

assert_not_a_candidate() {
  if candidate_tier "$1" > /dev/null; then
    echo "expected NOT to be listed as a candidate: $1 (tier=$(candidate_tier "$1"))" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Nothing is ever deleted
# ---------------------------------------------------------------------------

@test "report-only: --clean --include-orphans removes nothing" {
  local strong weak
  strong="$(CONTAINERS)/com.zzqqxx9.vvbbnn7"
  weak="$(APPSUP)/Zzqqxx9BareName"
  mkdir -p "$strong" "$weak"
  printf 'x\n' > "$strong/data"
  printf 'x\n' > "$weak/data"

  run_clean --clean --yes --only orphans --include-orphans
  [ "$status" -eq 0 ]
  [ -f "$strong/data" ]
  [ -f "$weak/data" ]
}

@test "report-only: not even a [strong] candidate is offered for removal" {
  local strong
  strong="$(CONTAINERS)/com.zzqqxx9.vvbbnn7"
  mkdir -p "$strong"

  run_clean --clean --yes --only orphans --include-orphans
  [ -d "$strong" ]
  # The old wording promised bulk removal; it must be gone from the output.
  ! echo "$output" | grep -qi 'Remove the .* item'
  echo "$output" | grep -q 'report only'
}

@test "report-only: the scan does not inflate the reclaimable-space estimate" {
  # TOTAL_BEFORE_KB answers "how much would --clean free". --clean frees none
  # of this, so none of it may be counted.
  mkdir -p "$(CONTAINERS)/com.zzqqxx9.vvbbnn7"
  dd if=/dev/zero of="$(CONTAINERS)/com.zzqqxx9.vvbbnn7/blob" bs=1024 count=600 2>/dev/null

  run_clean --scan --only orphans --include-orphans
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Estimated reclaimable space: 0.0K'
}

@test "report-only: a review file is still written and points the way forward" {
  mkdir -p "$(CONTAINERS)/com.zzqqxx9.vvbbnn7"

  run_clean --scan --only orphans --include-orphans
  echo "$output" | grep -q -- '--remove-orphans-from'

  local generated
  generated="$(grep -rl 'mimi-orphan-review v1' "$FAKE_HOME/Library/Logs/mimi" 2>/dev/null | head -1)"
  [ -n "$generated" ]
  grep -qx "$(CONTAINERS)/com.zzqqxx9.vvbbnn7" "$generated"
}

# ---------------------------------------------------------------------------
# Confidence wording
# ---------------------------------------------------------------------------

@test "wording: the report uses strong/weak, never auto" {
  mkdir -p "$(CONTAINERS)/com.zzqqxx9.vvbbnn7" "$(APPSUP)/Zzqqxx9BareName"

  run_clean --scan --only orphans --include-orphans
  echo "$output" | grep -q '\[strong\]'
  echo "$output" | grep -q '\[weak\]'
  ! echo "$output" | grep -q '\[auto\]'
}

@test "wording: a weak match is never described as belonging to an uninstalled app" {
  mkdir -p "$(APPSUP)/Zzqqxx9BareName"

  run_clean --scan --only orphans --include-orphans
  echo "$output" | grep -q 'NOT evidence'
  # The section heading must not assert uninstallation either.
  ! echo "$output" | grep -q 'uninstalled apps'
}

@test "wording: --help describes the category as report only" {
  run_clean --help
  echo "$output" | grep -q 'REPORT ONLY'
  ! echo "$output" | grep -q 'offered for immediate bulk removal'
}

@test "wording: --list describes the category as never deleting" {
  run_clean --list
  echo "$output" | grep -q 'never deletes'
}

# ---------------------------------------------------------------------------
# Fixtures: cases where "nothing claimed it" is simply wrong
# ---------------------------------------------------------------------------

@test "fixture: a renamed app still claims its bundle id" {
  source_lib
  # The bundle is called Newname.app but its id never changed.
  install_apps "$FAKE_HOME/Applications/Newname.app|com.vendor.oldname"
  mkdir -p "$(CONTAINERS)/com.vendor.oldname"

  build_installed_identifiers
  collect_orphan_candidates
  assert_not_a_candidate "$(CONTAINERS)/com.vendor.oldname"
}

@test "fixture: a beta sibling does not make the stable app's data an orphan" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Vividly.app|com.vendor.vividly"
  mkdir -p "$(CONTAINERS)/com.vendor.vividly.beta"

  build_installed_identifiers
  collect_orphan_candidates
  assert_not_a_candidate "$(CONTAINERS)/com.vendor.vividly.beta"
}

@test "fixture: a nested helper under an installed app's prefix is not an orphan" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Vividly.app|com.vendor.vividly"
  mkdir -p "$(CONTAINERS)/com.vendor.vividly.helper" \
           "$(APPSUP)/com.vendor.vividly.updater"

  build_installed_identifiers
  collect_orphan_candidates
  assert_not_a_candidate "$(CONTAINERS)/com.vendor.vividly.helper"
  assert_not_a_candidate "$(APPSUP)/com.vendor.vividly.updater"
}

@test "fixture: shared vendor data is never listed" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Something.app|com.example.something"
  local d
  for d in Adobe Google Microsoft Dropbox 1Password; do
    mkdir -p "$(APPSUP)/$d"
  done

  build_installed_identifiers
  collect_orphan_candidates
  for d in Adobe Google Microsoft Dropbox 1Password; do
    assert_not_a_candidate "$(APPSUP)/$d"
  done
}

@test "fixture: group containers are not scanned at all" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Group Containers/group.com.vendor.shared"

  build_installed_identifiers
  collect_orphan_candidates
  assert_not_a_candidate "$FAKE_HOME/Library/Group Containers/group.com.vendor.shared"

  # And the location is not in the scanned set in the first place.
  local spec
  for spec in "${ORPHAN_ROOTS[@]}"; do
    case "${spec%%::*}" in
      *"Group Containers"*) return 1 ;;
    esac
  done
}

@test "fixture: an anonymous UUID container is only ever weak" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Something.app|com.example.something"
  local uuid
  uuid="$(CONTAINERS)/A1B2C3D4-1234-5678-9ABC-DEF012345678"
  mkdir -p "$uuid"

  build_installed_identifiers
  collect_orphan_candidates
  [ "$(candidate_tier "$uuid")" = "weak" ]
}

@test "fixture: an Apple identifier is never listed" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Something.app|com.example.something"
  mkdir -p "$(CONTAINERS)/com.apple.Safari" \
           "$FAKE_HOME/Library/Preferences/group.com.apple.notes.plist"

  build_installed_identifiers
  collect_orphan_candidates
  assert_not_a_candidate "$(CONTAINERS)/com.apple.Safari"
}

@test "fixture: a bare-word Application Support folder is weak, a dotted one is strong" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Something.app|com.example.something"
  mkdir -p "$(APPSUP)/Qt" "$(APPSUP)/com.vendor.dotted"

  build_installed_identifiers
  collect_orphan_candidates
  [ "$(candidate_tier "$(APPSUP)/Qt")" = "weak" ]
  [ "$(candidate_tier "$(APPSUP)/com.vendor.dotted")" = "strong" ]
}

@test "fixture: Preferences and LaunchAgents are always weak, never strong" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Something.app|com.example.something"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  printf 'x\n' > "$FAKE_HOME/Library/Preferences/com.vendor.gone.plist"
  printf 'x\n' > "$FAKE_HOME/Library/LaunchAgents/com.vendor.gone.plist"

  build_installed_identifiers
  collect_orphan_candidates
  [ "$(candidate_tier "$FAKE_HOME/Library/Preferences/com.vendor.gone.plist")" = "weak" ]
  [ "$(candidate_tier "$FAKE_HOME/Library/LaunchAgents/com.vendor.gone.plist")" = "weak" ]
}

# ---------------------------------------------------------------------------
# An incomplete index is reported, not read as proof of uninstallation
# ---------------------------------------------------------------------------

@test "index: no Spotlight results at all is reported as incomplete" {
  source_lib
  # The default mdfind mock returns nothing, which is what a machine with
  # Spotlight disabled looks like.
  build_installed_identifiers
  [ "$ORPHAN_INDEX_COMPLETE" = 0 ]
  echo "$ORPHAN_INDEX_NOTE" | grep -q 'no applications'
}

@test "index: fewer Spotlight results than the directory walk is reported as incomplete" {
  source_lib
  # Spotlight knows about one app; the walk finds two.
  install_apps "$FAKE_HOME/Applications/Indexed.app|com.example.indexed"
  mkdir -p "$FAKE_HOME/Applications/Unindexed.app/Contents"

  build_installed_identifiers
  [ "$ORPHAN_INDEX_COMPLETE" = 0 ]
  echo "$ORPHAN_INDEX_NOTE" | grep -q 'fewer applications'
}

@test "index: a complete index is not flagged" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Indexed.app|com.example.indexed"
  build_installed_identifiers
  [ "$ORPHAN_INDEX_COMPLETE" = 1 ]
  [ -z "$ORPHAN_INDEX_NOTE" ]
}

@test "index: an incomplete index downgrades every candidate to weak" {
  source_lib
  # No Spotlight at all, so absence proves nothing about anything.
  mkdir -p "$(CONTAINERS)/com.vendor.wouldbestrong"

  build_installed_identifiers
  collect_orphan_candidates
  [ "$ORPHAN_INDEX_COMPLETE" = 0 ]
  [ "$(candidate_tier "$(CONTAINERS)/com.vendor.wouldbestrong")" = "weak" ]
}

@test "index: the same candidate is strong once the index is complete" {
  source_lib
  install_apps "$FAKE_HOME/Applications/Other.app|com.example.other"
  mkdir -p "$(CONTAINERS)/com.vendor.wouldbestrong"

  build_installed_identifiers
  collect_orphan_candidates
  [ "$ORPHAN_INDEX_COMPLETE" = 1 ]
  [ "$(candidate_tier "$(CONTAINERS)/com.vendor.wouldbestrong")" = "strong" ]
}

@test "index: incompleteness is reported loudly in the run output" {
  mkdir -p "$(CONTAINERS)/com.vendor.gone"

  run_clean --scan --only orphans --include-orphans
  echo "$output" | grep -q 'INCOMPLETE'
  echo "$output" | grep -q 'makes every result unreliable'
}

# ---------------------------------------------------------------------------
# The only deletion path still works, and still revalidates
# ---------------------------------------------------------------------------

@test "handoff: the generated file is the only way to delete, and it works" {
  local target
  target="$(CONTAINERS)/com.zzqqxx9.rrgg42"
  mkdir -p "$target"
  printf 'x\n' > "$target/data"

  run_clean --scan --only orphans --include-orphans
  local generated
  generated="$(grep -rl 'mimi-orphan-review v1' "$FAKE_HOME/Library/Logs/mimi" 2>/dev/null | head -1)"
  [ -n "$generated" ]
  [ -f "$target/data" ]

  run_clean --clean --yes --force-risky orphans --only orphans --remove-orphans-from "$generated"
  [ "$status" -eq 0 ]
  [ ! -e "$target" ]
}

@test "handoff: commenting a line out in the generated file keeps it" {
  local keep drop
  keep="$(CONTAINERS)/com.zzqqxx9.kkpp31"
  drop="$(CONTAINERS)/com.zzqqxx9.ddpp52"
  mkdir -p "$keep" "$drop"
  printf 'x\n' > "$keep/data"
  printf 'x\n' > "$drop/data"

  run_clean --scan --only orphans --include-orphans
  local generated
  generated="$(grep -rl 'mimi-orphan-review v1' "$FAKE_HOME/Library/Logs/mimi" 2>/dev/null | head -1)"
  [ -n "$generated" ]

  # Comment out the keeper, exactly as the file instructs.
  /usr/bin/sed -i '' "s|^${keep}$|#${keep}|" "$generated"

  run_clean --clean --yes --force-risky orphans --only orphans --remove-orphans-from "$generated"
  [ -f "$keep/data" ]
  [ ! -e "$drop" ]
}
