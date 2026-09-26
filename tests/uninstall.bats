#!/usr/bin/env bats
#
# tests/uninstall.bats — Phase 4: Reversible user-scope app uninstall MVP.
# Covers P4-T01 through P4-T04 and the Phase 4 exit gate.
#

load 'test_helper'

# `run --separate-stderr` is used for JSON output.
bats_require_minimum_version 1.5.0

setup() {
  TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mimi-test-XXXXXX")"
  # Canonicalize to resolve /var -> /private/var (and /tmp -> /private/tmp)
  # symlinks on macOS so that path_canonicalize() comparisons are consistent.
  TEST_TMPDIR="$(cd -P "$TEST_TMPDIR" && pwd -P)"
  SENTINEL_PARENT="${TEST_TMPDIR%/*}/.sentinel-parent-$$"
  SENTINEL_SIBLING="${TEST_TMPDIR%/*}/.sentinel-sibling-$$"
  printf 'sentinel-parent\n'  > "$SENTINEL_PARENT"
  printf 'sentinel-sibling\n' > "$SENTINEL_SIBLING"
  SENTINEL_PARENT_HASH="$(cksum "$SENTINEL_PARENT" | awk '{print $1}')"
  SENTINEL_SIBLING_HASH="$(cksum "$SENTINEL_SIBLING" | awk '{print $1}')"

  FAKE_HOME="$TEST_TMPDIR/home"
  mkdir -p \
    "$FAKE_HOME/Applications" \
    "$FAKE_HOME/Library/Caches" \
    "$FAKE_HOME/Library/Logs" \
    "$FAKE_HOME/Library/Preferences" \
    "$FAKE_HOME/Library/Application Support" \
    "$FAKE_HOME/Library/Containers" \
    "$FAKE_HOME/Library/Group Containers" \
    "$FAKE_HOME/Library/Saved Application State" \
    "$FAKE_HOME/Library/LaunchAgents" \
    "$FAKE_HOME/.config/mimi/plans" \
    "$FAKE_HOME/.config/mimi/quarantine"

  export HOME="$FAKE_HOME"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications"
  export MIMI_CASKROOM_DIRS="$FAKE_HOME/Caskroom"
  export MIMI_APP_SYSTEM_ROOTS=""
  export MIMI_RECEIPTS_DIR="$FAKE_HOME/receipts"
  export PATH="$MOCKS_BIN:$PATH"
}

teardown() {
  verify_sentinels
  rm -rf "$TEST_TMPDIR"
}

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
  QUARANTINE_DIR="$FAKE_HOME/.config/mimi/quarantine"
  PLANS_DIR="$FAKE_HOME/.config/mimi/plans"
  CONFIG_DIR="$FAKE_HOME/.config/mimi"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

create_app() {
  local app_dir="$1"
  local name="$2"
  local bundle_id="$3"
  local version="$4"
  local exe="${5:-}"
  [ -z "$exe" ] && exe="$name"
  mkdir -p "$app_dir/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$app_dir/Contents/MacOS/$exe"
  chmod +x "$app_dir/Contents/MacOS/$exe"

  cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleDisplayName</key>
    <string>$name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleExecutable</key>
    <string>$exe</string>
</dict>
</plist>
EOF
}

# ---------------------------------------------------------------------------
# P4-T01: Uninstall modes and target resolution
# ---------------------------------------------------------------------------

@test "uninstall: requires a target argument" {
  run /bin/bash "$MIMI_BIN" app uninstall
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -i "requires"
}

@test "uninstall: exact path resolution succeeds for a valid app" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "2.0"

  source_lib
  RESOLVED_APP_PATH=""
  resolve_app_target "$app"
  # Compare against the canonical path (resolve /var -> /private/var symlink).
  local canon_app
  canon_app="$(cd -P "$app" 2>/dev/null && pwd -P || echo "$app")"
  [ "$RESOLVED_APP_PATH" = "$canon_app" ]
}

@test "uninstall: exact bundle-ID resolution returns unique match" {
  local app="$FAKE_HOME/Applications/IDTest.app"
  create_app "$app" "IDTest" "com.example.idtest" "1.0"

  source_lib
  RESOLVED_APP_PATH=""
  resolve_app_target "com.example.idtest"
  local canon_app
  canon_app="$(cd -P "$app" 2>/dev/null && pwd -P || echo "$app")"
  [ "$RESOLVED_APP_PATH" = "$canon_app" ]
}

@test "uninstall: case-insensitive name resolution works" {
  local app="$FAKE_HOME/Applications/MyEditor.app"
  create_app "$app" "MyEditor" "com.example.myeditor" "1.0"

  source_lib
  RESOLVED_APP_PATH=""
  resolve_app_target "myeditor"
  [ -n "$RESOLVED_APP_PATH" ]
}

@test "uninstall: ambiguous name resolution emits error and returns 1" {
  local app1="$FAKE_HOME/Applications/Widget.app"
  local app2="$FAKE_HOME/Applications/Widget-Beta.app"
  create_app "$app1" "Widget" "com.example.widget" "1.0"
  create_app "$app2" "Widget" "com.example.widget-beta" "1.0-beta"

  source_lib
  run resolve_app_target "Widget"
  [ "$status" -ne 0 ]
}

@test "uninstall: unknown target returns non-zero and prints error" {
  source_lib
  run resolve_app_target "com.this.does.not.exist"
  [ "$status" -ne 0 ]
}

@test "uninstall: system/Apple app guard refuses to uninstall" {
  local app="$FAKE_HOME/Applications/SafariSim.app"
  create_app "$app" "SafariSim" "com.apple.Safari" "17.0"

  source_lib
  # Manually mark as system app (as app_inspect_bundle would on a real system).
  APP_INFO_IS_SYSTEM=1
  APP_INFO_NAME="SafariSim"
  RESOLVED_APP_PATH="$app"
  APP_INFO_IDENTITY="$(path_identity "$app" 2>/dev/null || echo unknown)"
  APP_INFO_CANONICAL_PATH="$app"

  run uninstall_resolve_target "com.apple.Safari"
  [ "$status" -ne 0 ]
}

@test "uninstall: --keep-data flag is accepted without error" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "1.0"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --keep-data --yes
  # Exits 0 or EXIT_CANCELLED (5) — the important thing is not exit 1 (usage error).
  [ "$status" -ne 1 ]
}

@test "uninstall: --purge-data flag is accepted without error" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "1.0"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --purge-data --yes
  [ "$status" -ne 1 ]
}

# ---------------------------------------------------------------------------
# P4-T02: Running process handling
# ---------------------------------------------------------------------------

@test "process: app_process_list_pids returns 0 when no processes match" {
  source_lib
  PROC_PIDS=()
  PROC_COUNT=0
  # Use an app path that will never match a running process.
  app_process_list_pids "com.example.nonexistent" \
    "/Applications/NonExistentApp999.app" "NonExistentApp999"
  [ "$PROC_COUNT" -eq 0 ]
}

@test "process: app_process_wait_gone returns 0 immediately when no processes" {
  source_lib
  PROC_PIDS=()
  PROC_COUNT=0
  app_process_wait_gone "com.example.none" "/tmp/noop.app" "NoopApp" 1
  [ "$?" -eq 0 ]
}

@test "process: app_process_request_quit returns 1 without osascript" {
  source_lib
  # Temporarily shadow osascript with a no-op that exits 127.
  local orig_path="$PATH"
  local fake_bin="$TEST_TMPDIR/fake_bin"
  mkdir -p "$fake_bin"
  # Create a fake osascript that does not exist (remove the real one from PATH).
  PATH="$fake_bin"  # osascript absent
  run app_process_request_quit "com.example.test"
  PATH="$orig_path"
  [ "$status" -ne 0 ]
}

@test "process: app_process_force_quit returns 0 when no processes match" {
  source_lib
  run app_process_force_quit "com.example.none" "/tmp/noop.app" "NoopApp"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# P4-T03: User-scope uninstall plan
# ---------------------------------------------------------------------------

@test "uninstall plan: bundle is always included as first candidate" {
  local app="$FAKE_HOME/Applications/PlanTest.app"
  create_app "$app" "PlanTest" "com.example.plantest" "1.0"

  source_lib
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "PlanTest" "com.example.plantest" "" "PlanTest"

  plan_init "test-plan-001"
  uninstall_build_plan "$app" "PlanTest" "com.example.plantest" "" "PlanTest"
  plan_build ""

  # At least one action for the bundle.
  [ "${#PLAN_ACTIONS[@]}" -ge 1 ]
  # First action must be the bundle itself.
  local first="${PLAN_ACTIONS[0]}"
  local first_path="${first#*::*::*::}"; first_path="${first_path%%::*}"
  [ "$first_path" = "$app" ]
}

@test "uninstall plan: authoritative container is included in purge mode" {
  local app="$FAKE_HOME/Applications/ContainerApp.app"
  create_app "$app" "ContainerApp" "com.example.containerapp" "1.0"

  # Create a container entry.
  local cont="$FAKE_HOME/Library/Containers/com.example.containerapp"
  mkdir -p "$cont"
  printf 'data\n' > "$cont/prefs.plist"

  source_lib
  UNINSTALL_DATA_MODE="purge"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "ContainerApp" "com.example.containerapp" "" "ContainerApp"

  plan_init "test-plan-002"
  uninstall_build_plan "$app" "ContainerApp" "com.example.containerapp" "" "ContainerApp"
  plan_build ""

  # Should include at least the bundle and the container.
  [ "${#PLAN_ACTIONS[@]}" -ge 2 ]

  # The container should appear in the plan.
  # Compare against canonical path (resolves symlinks like /var -> /private/var).
  local found=0 item
  local canon_cont
  canon_cont="$(cd -P "$cont" 2>/dev/null && pwd -P || echo "$cont")"
  for item in "${PLAN_ACTIONS[@]}"; do
    # Kept items are recorded as "retain" actions; only moves count here.
    case "$item" in *"::retain::"*) continue ;; esac
    local p="${item#*::*::*::}"; p="${p%%::*}"
    if [ "$p" = "$canon_cont" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ]
}

@test "uninstall plan: --keep-data excludes Library data from plan" {
  local app="$FAKE_HOME/Applications/KeepDataApp.app"
  create_app "$app" "KeepDataApp" "com.example.keepdataapp" "1.0"

  # Create preferences.
  printf '<?xml version="1.0"?><plist><dict></dict></plist>' \
    > "$FAKE_HOME/Library/Preferences/com.example.keepdataapp.plist"

  source_lib
  UNINSTALL_DATA_MODE="keep"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "KeepDataApp" "com.example.keepdataapp" "" "KeepDataApp"

  plan_init "test-plan-003"
  uninstall_build_plan "$app" "KeepDataApp" "com.example.keepdataapp" "" "KeepDataApp"
  plan_build ""

  # In keep mode only the bundle (and LaunchAgents) should be in the plan.
  local has_pref=0 item
  for item in "${PLAN_ACTIONS[@]}"; do
    # Kept items are recorded as "retain" actions; only moves count here.
    case "$item" in *"::retain::"*) continue ;; esac
    local p="${item#*::*::*::}"; p="${p%%::*}"
    if echo "$p" | grep -q "Preferences"; then
      has_pref=1
      break
    fi
  done
  [ "$has_pref" -eq 0 ]
}

@test "uninstall plan: weak evidence is never included in any data mode" {
  local app="$FAKE_HOME/Applications/WeakApp.app"
  create_app "$app" "WeakApp" "com.example.weakapp" "1.0"

  # Create a cache that will be classified as weak (name match only).
  mkdir -p "$FAKE_HOME/Library/Caches/WeakApp"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/WeakApp/cache.dat"

  source_lib
  UNINSTALL_DATA_MODE="purge"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "WeakApp" "com.example.weakapp" "" "WeakApp"

  plan_init "test-plan-004"
  uninstall_build_plan "$app" "WeakApp" "com.example.weakapp" "" "WeakApp"
  plan_build ""

  # Weak Caches entry should not appear.
  local has_weak_cache=0 item
  for item in "${PLAN_ACTIONS[@]}"; do
    # Kept items are recorded as "retain" actions; only moves count here.
    case "$item" in *"::retain::"*) continue ;; esac
    local p="${item#*::*::*::}"; p="${p%%::*}"
    if echo "$p" | grep -q "Library/Caches/WeakApp"; then
      has_weak_cache=1
      break
    fi
  done
  [ "$has_weak_cache" -eq 0 ]
}

@test "uninstall plan: LaunchAgent is tracked in UNINSTALL_LAUNCHAGENTS" {
  local app="$FAKE_HOME/Applications/LaApp.app"
  create_app "$app" "LaApp" "com.example.laapp" "1.0"

  local la="$FAKE_HOME/Library/LaunchAgents/com.example.laapp.plist"
  printf '<?xml version="1.0"?><plist><dict><key>Label</key><string>com.example.laapp</string></dict></plist>' \
    > "$la"

  source_lib
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "LaApp" "com.example.laapp" "" "LaApp"

  plan_init "test-plan-005"
  UNINSTALL_DATA_MODE="purge"
  uninstall_build_plan "$app" "LaApp" "com.example.laapp" "" "LaApp"

  [ "${#UNINSTALL_LAUNCHAGENTS[@]}" -ge 1 ]
}

@test "uninstall plan: shared group container is never included" {
  local app="$FAKE_HOME/Applications/GCApp.app"
  create_app "$app" "GCApp" "com.example.gcapp" "1.0"

  mkdir -p "$FAKE_HOME/Library/Group Containers/ABCD1234.com.example.gcapp"
  printf 'shared\n' > "$FAKE_HOME/Library/Group Containers/ABCD1234.com.example.gcapp/data"

  source_lib
  UNINSTALL_DATA_MODE="purge"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "GCApp" "com.example.gcapp" "" "GCApp"

  plan_init "test-plan-006"
  uninstall_build_plan "$app" "GCApp" "com.example.gcapp" "" "GCApp"
  plan_build ""

  local has_gc=0 item
  for item in "${PLAN_ACTIONS[@]}"; do
    # Kept items are recorded as "retain" actions; only moves count here.
    case "$item" in *"::retain::"*) continue ;; esac
    local p="${item#*::*::*::}"; p="${p%%::*}"
    if echo "$p" | grep -q "Group Containers"; then
      has_gc=1
      break
    fi
  done
  [ "$has_gc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# P4-T04: User-scope apply and verification
# ---------------------------------------------------------------------------

@test "uninstall apply: quarantines app bundle and it is no longer at original path" {
  local app="$FAKE_HOME/Applications/ApplyTest.app"
  create_app "$app" "ApplyTest" "com.example.applytest" "1.0"

  source_lib
  UNINSTALL_DATA_MODE="keep"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "ApplyTest" "com.example.applytest" "" "ApplyTest"

  plan_init "apply-test-001"
  uninstall_build_plan "$app" "ApplyTest" "com.example.applytest" "" "ApplyTest"
  plan_build ""

  uninstall_apply "$app" "com.example.applytest" "ApplyTest"

  # Bundle should be gone.
  [ ! -e "$app" ]
}

@test "uninstall apply: quarantine run directory is created with manifest" {
  local app="$FAKE_HOME/Applications/ManifestTest.app"
  create_app "$app" "ManifestTest" "com.example.manifesttest" "1.0"

  source_lib
  UNINSTALL_DATA_MODE="keep"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "ManifestTest" "com.example.manifesttest" "" "ManifestTest"

  plan_init "manifest-test-001"
  uninstall_build_plan "$app" "ManifestTest" "com.example.manifesttest" "" "ManifestTest"
  plan_build ""

  uninstall_apply "$app" "com.example.manifesttest" "ManifestTest"

  [ -n "$QUARANTINE_CURRENT_RUN_DIR" ]
  [ -f "$QUARANTINE_CURRENT_RUN_DIR/manifest.jsonl" ]
}

@test "uninstall apply: quarantined bundle can be restored to original path" {
  local app="$FAKE_HOME/Applications/RestoreTest.app"
  create_app "$app" "RestoreTest" "com.example.restoretest" "1.0"

  source_lib
  UNINSTALL_DATA_MODE="keep"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "RestoreTest" "com.example.restoretest" "" "RestoreTest"

  plan_init "restore-test-001"
  uninstall_build_plan "$app" "RestoreTest" "com.example.restoretest" "" "RestoreTest"
  plan_build ""

  uninstall_apply "$app" "com.example.restoretest" "RestoreTest"

  [ ! -e "$app" ]
  local run_id="$QUARANTINE_CURRENT_RUN_ID"

  quarantine_restore_run "$run_id"

  # App should be back.
  [ -e "$app" ]
}

@test "uninstall apply: also quarantines attributable data in purge mode" {
  local app="$FAKE_HOME/Applications/PurgeDataTest.app"
  create_app "$app" "PurgeDataTest" "com.example.purgedatatest" "1.0"

  local cont="$FAKE_HOME/Library/Containers/com.example.purgedatatest"
  mkdir -p "$cont"
  printf 'data\n' > "$cont/prefs.plist"

  source_lib
  UNINSTALL_DATA_MODE="purge"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "PurgeDataTest" "com.example.purgedatatest" "" "PurgeDataTest"

  plan_init "purge-data-test-001"
  uninstall_build_plan "$app" "PurgeDataTest" "com.example.purgedatatest" "" "PurgeDataTest"
  plan_build ""

  uninstall_apply "$app" "com.example.purgedatatest" "PurgeDataTest"

  [ ! -e "$app" ]
  [ ! -e "$cont" ]
}

@test "uninstall apply: missing target does not crash (already removed)" {
  source_lib
  UNINSTALL_DATA_MODE="keep"
  PLAN_ACTIONS=()
  UNINSTALL_LAUNCHAGENTS=()

  plan_init "empty-plan-001"
  # Manually add a fake action for a path that doesn't exist.
  plan_add_action "act-0001" "uninstall-app" "quarantine" \
    "/tmp/GhostApp999.app" "unknown" "0" "moderate" "ghost bundle"

  # Apply should handle missing targets gracefully (quarantine_target returns 1).
  run uninstall_apply "/tmp/GhostApp999.app" "com.example.ghost" "GhostApp"
  # Should return partial (EXIT_PARTIAL=3) or ok, not crash.
  [ "$status" -le 5 ]
}

@test "uninstall apply: data fixture is inside test tmpdir (no escape)" {
  local app="$FAKE_HOME/Applications/EscapeTest.app"
  create_app "$app" "EscapeTest" "com.example.escapetest" "1.0"

  local cont="$FAKE_HOME/Library/Containers/com.example.escapetest"
  mkdir -p "$cont"
  printf 'data\n' > "$cont/entry"

  source_lib
  UNINSTALL_DATA_MODE="purge"
  app_inspect_bundle "$app"
  collect_app_evidence "$app" "EscapeTest" "com.example.escapetest" "" "EscapeTest"

  plan_init "escape-test-001"
  uninstall_build_plan "$app" "EscapeTest" "com.example.escapetest" "" "EscapeTest"
  plan_build ""

  uninstall_apply "$app" "com.example.escapetest" "EscapeTest"

  # Everything should be within QUARANTINE_DIR which is inside TEST_TMPDIR.
  case "$QUARANTINE_CURRENT_RUN_DIR" in
    "$TEST_TMPDIR"*) ;;
    *) false ;;
  esac
}

# ---------------------------------------------------------------------------
# P4 CLI integration tests
# ---------------------------------------------------------------------------

@test "cli: 'mimi app uninstall' without target prints usage error" {
  run /bin/bash "$MIMI_BIN" app uninstall
  [ "$status" -eq 1 ]
}

@test "cli: 'mimi app uninstall <path> --yes' exits 0 for a valid app" {
  local app="$FAKE_HOME/Applications/CLIUninstallTest.app"
  create_app "$app" "CLIUninstallTest" "com.example.cliuninstalltest" "1.0"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --keep-data

  [ "$status" -eq 0 ]
  [ ! -e "$app" ]
}

@test "cli: uninstalled app can be restored via 'mimi restore'" {
  local app="$FAKE_HOME/Applications/RestoreCLI.app"
  create_app "$app" "RestoreCLI" "com.example.restorecli" "1.0"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --keep-data

  [ "$status" -eq 0 ]
  [ ! -e "$app" ]

  # Extract the run ID from the output.
  local run_id
  run_id=$(echo "$output" | grep -o 'uninstall-[^ ]*' | head -1)
  [ -n "$run_id" ]

  run /bin/bash "$MIMI_BIN" restore "$run_id" --yes
  [ "$status" -eq 0 ]
  [ -e "$app" ]
}

@test "cli: --keep-data does not quarantine Library data" {
  local app="$FAKE_HOME/Applications/KeepDataCLI.app"
  create_app "$app" "KeepDataCLI" "com.example.keepdatacli" "1.0"

  # Create a pref file.
  printf '<?xml version="1.0"?><plist><dict></dict></plist>' \
    > "$FAKE_HOME/Library/Preferences/com.example.keepdatacli.plist"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --keep-data

  [ "$status" -eq 0 ]
  [ ! -e "$app" ]
  # Preference file should still be present.
  [ -f "$FAKE_HOME/Library/Preferences/com.example.keepdatacli.plist" ]
}

# ---------------------------------------------------------------------------
# P4-T05: Homebrew Cask hand-off tests
# ---------------------------------------------------------------------------

@test "cask hand-off: detects cask provenance and resolves by cask token" {
  mkdir -p "$FAKE_HOME/Caskroom/my-cask/1.0"
  local app="$FAKE_HOME/Applications/My Cask.app"
  create_app "$app" "My Cask" "com.example.mycask" "1.0"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app inspect "my-cask"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Provenance:          cask" ]]
}

@test "cask hand-off: ordinary uninstall of cask app prints advisory note" {
  mkdir -p "$FAKE_HOME/Caskroom/cask-note-app/1.0"
  local app="$FAKE_HOME/Applications/CaskNoteApp.app"
  create_app "$app" "CaskNoteApp" "com.example.casknote" "1.0"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --keep-data

  [ "$status" -eq 0 ]
  [[ "$output" =~ "This application was installed via Homebrew Cask" ]]
}

@test "cask hand-off: --cask delegates to brew uninstall --cask" {
  mkdir -p "$FAKE_HOME/Caskroom/delegated-cask/1.0"
  local app="$FAKE_HOME/Applications/DelegatedCask.app"
  create_app "$app" "DelegatedCask" "com.example.delegated" "1.0"

  export MOCK_CALL_LOG="$TEST_TMPDIR/mock.log"
  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --cask

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Homebrew Cask Delegation" ]]
  [[ "$output" =~ "Successfully uninstalled cask: delegated-cask" ]]
  grep -q "brew uninstall --cask delegated-cask" "$MOCK_CALL_LOG"
}

@test "cask hand-off: --zap displays shared-resource warning and delegates" {
  mkdir -p "$FAKE_HOME/Caskroom/zap-cask/1.0"
  local app="$FAKE_HOME/Applications/ZapCask.app"
  create_app "$app" "ZapCask" "com.example.zapcask" "1.0"

  export MOCK_CALL_LOG="$TEST_TMPDIR/mock.log"
  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --zap

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Homebrew Cask Delegation" ]]
  [[ "$output" =~ "--zap" ]]
  [[ "$output" =~ "Homebrew deletes these directly; mimi cannot quarantine or restore them" ]]
  grep -q "brew uninstall --cask --zap zap-cask" "$MOCK_CALL_LOG"
}

@test "cask hand-off: --zap on non-cask app refuses with usage error" {
  local app="$FAKE_HOME/Applications/PlainApp.app"
  create_app "$app" "PlainApp" "com.example.plain" "1.0"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --zap

  [ "$status" -ne 0 ]
  [[ "$output" =~ "--zap is only applicable to applications installed via Homebrew Cask" ]]
}

# ---------------------------------------------------------------------------
# Phase 4 exit gate checks
# ---------------------------------------------------------------------------

@test "phase4 gate: uninstall is fully plan-bound (plan file created)" {
  local app="$FAKE_HOME/Applications/GateTest.app"
  create_app "$app" "GateTest" "com.example.gatetest" "1.0"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --keep-data

  [ "$status" -eq 0 ]
  # A plan file must exist in PLANS_DIR.
  local plans_count
  plans_count="$(ls "$FAKE_HOME/.config/mimi/plans"/*.json 2>/dev/null | wc -l | tr -d ' ')"
  [ "$plans_count" -ge 1 ]
}

@test "phase4 gate: shared resources survive uninstall" {
  local app="$FAKE_HOME/Applications/SharedTest.app"
  create_app "$app" "SharedTest" "com.example.sharedtest" "1.0"

  # Shared group container.
  local gc="$FAKE_HOME/Library/Group Containers/TEAM1234.com.example.sharedtest"
  mkdir -p "$gc"
  printf 'shared\n' > "$gc/shared.dat"

  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --purge-data

  [ "$status" -eq 0 ]
  # Group container (shared) must still be present.
  [ -d "$gc" ]
}

@test "phase4 gate: restore works end to end before explicit purge" {
  local app="$FAKE_HOME/Applications/E2ETest.app"
  create_app "$app" "E2ETest" "com.example.e2etest" "1.0"

  # Apply uninstall.
  run /bin/bash "$MIMI_BIN" \
    --app-root "$FAKE_HOME/Applications" \
    app uninstall "$app" --yes --keep-data

  [ "$status" -eq 0 ]
  [ ! -e "$app" ]

  local run_id
  run_id=$(echo "$output" | grep -o 'uninstall-[^ ]*' | head -1)
  [ -n "$run_id" ]

  # Restore.
  run /bin/bash "$MIMI_BIN" restore "$run_id" --yes
  [ "$status" -eq 0 ]
  [ -e "$app" ]

  # Purge.
  run /bin/bash "$MIMI_BIN" purge "$run_id" --yes
  [ "$status" -eq 0 ]
  [ ! -d "$FAKE_HOME/.config/mimi/quarantine/$run_id" ]
}

# ===========================================================================
# Phase 4 completion — gaps closed on 2026-09-26
# ===========================================================================

# The plan file a --plan-only run printed.
plan_file_from() {
  printf '%s\n' "$1" | grep -o "$FAKE_HOME/.config/mimi/plans/uninstall-[^\"]*\.json" | head -1
}

# Quarantine run id from an apply summary.
run_id_from() {
  printf '%s\n' "$1" | grep -o 'uninstall-[0-9]\{8\}-[0-9]\{6\}-[0-9]*' | head -1
}

# ---------------------------------------------------------------------------
# P4-T01: modes and refusals
# ---------------------------------------------------------------------------

@test "modes: --keep-data and --purge-data together are a usage error" {
  create_app "$FAKE_HOME/Applications/Both.app" "Both" "com.example.both" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$FAKE_HOME/Applications/Both.app" --keep-data --purge-data --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "contradict each other"
  [ -d "$FAKE_HOME/Applications/Both.app" ]
}

@test "modes: the default keeps user data without a terminal and says how to include it" {
  local app="$FAKE_HOME/Applications/AskApp.app"
  create_app "$app" "AskApp" "com.example.askapp" "1.0"
  touch "$FAKE_HOME/Library/Preferences/com.example.askapp.plist"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --yes < /dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$app" ]
  [ -f "$FAKE_HOME/Library/Preferences/com.example.askapp.plist" ]
  echo "$output" | grep -q "Pass --purge-data to include it"
}

@test "modes: --purge-data moves attributable data but never shared data" {
  local app="$FAKE_HOME/Applications/PurgeApp.app"
  create_app "$app" "PurgeApp" "com.example.purgeapp" "1.0"
  touch "$FAKE_HOME/Library/Preferences/com.example.purgeapp.plist"
  mkdir -p "$FAKE_HOME/Library/Group Containers/group.com.example.purgeapp"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --purge-data --yes
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Preferences/com.example.purgeapp.plist" ]
  [ -d "$FAKE_HOME/Library/Group Containers/group.com.example.purgeapp" ]
  echo "$output" | grep -q "kept item(s) verified intact"
}

@test "authorize: bundles outside application folders, symlinks, and /System are refused" {
  source_lib
  create_app "$FAKE_HOME/Documents/Stray.app" "Stray" "com.example.stray" "1.0"
  ! uninstall_authorize_bundle "$FAKE_HOME/Documents/Stray.app"
  [ "$UNINSTALL_DENY_REASON" = "not inside an application folder" ]

  create_app "$FAKE_HOME/Applications/Real.app" "Real" "com.example.real" "1.0"
  ln -s "$FAKE_HOME/Applications/Real.app" "$FAKE_HOME/Applications/Link.app"
  ! uninstall_authorize_bundle "$FAKE_HOME/Applications/Link.app"
  [ "$UNINSTALL_DENY_REASON" = "the bundle is a symbolic link" ]

  ! uninstall_authorize_bundle "/System/Applications/Calculator.app"
  uninstall_authorize_bundle "$FAKE_HOME/Applications/Real.app"
}

@test "authorize: a vendor-folder app is allowed, a bundle inside a bundle is not" {
  source_lib
  create_app "$FAKE_HOME/Applications/Acme/Acme Tool.app" "Acme Tool" "com.acme.tool" "1.0"
  create_app "$FAKE_HOME/Applications/Host.app/Contents/Helper.app" "Helper" "com.example.helper" "1.0"
  uninstall_authorize_bundle "$FAKE_HOME/Applications/Acme/Acme Tool.app"
  ! uninstall_authorize_bundle "$FAKE_HOME/Applications/Host.app/Contents/Helper.app"
}

# ---------------------------------------------------------------------------
# P4-T02: running processes
# ---------------------------------------------------------------------------

@test "process: --yes cannot force-quit a running app" {
  source_lib
  ASSUME_YES=1
  app_process_list_pids() { PROC_PIDS=("4242:Busy"); PROC_COUNT=1; }
  app_process_request_quit() { return 0; }
  app_process_wait_gone() { return 1; }
  app_process_force_quit() { : > "$TEST_TMPDIR/killed"; return 0; }

  local rc=0
  uninstall_handle_processes "com.example.busy" "$FAKE_HOME/Applications/Busy.app" "Busy" < /dev/null > "$TEST_TMPDIR/out" 2>&1 || rc=$?
  [ "$rc" -eq "$EXIT_CANCELLED" ]
  [ ! -e "$TEST_TMPDIR/killed" ]
  grep -q "unsaved work" "$TEST_TMPDIR/out"
}

@test "process: --force-risky app-terminate authorizes the force-quit" {
  source_lib
  FORCE_RISKY_LIST="app-terminate"
  app_process_list_pids() { PROC_PIDS=("4242:Busy"); PROC_COUNT=1; }
  app_process_request_quit() { return 0; }
  app_process_wait_gone() { return 1; }
  app_process_force_quit() { : > "$TEST_TMPDIR/killed"; return 0; }

  uninstall_handle_processes "com.example.busy" "$FAKE_HOME/Applications/Busy.app" "Busy" < /dev/null > /dev/null 2>&1
  [ -e "$TEST_TMPDIR/killed" ]
}

@test "process: an app that quits normally is never force-quit" {
  source_lib
  app_process_list_pids() { PROC_PIDS=("4242:Nice"); PROC_COUNT=1; }
  app_process_request_quit() { return 0; }
  app_process_wait_gone() { return 0; }
  app_process_force_quit() { : > "$TEST_TMPDIR/killed"; return 0; }
  uninstall_handle_processes "com.example.nice" "$FAKE_HOME/Applications/Nice.app" "Nice" < /dev/null > /dev/null 2>&1
  [ ! -e "$TEST_TMPDIR/killed" ]
}

@test "cli: app-terminate is accepted by --force-risky" {
  create_app "$FAKE_HOME/Applications/Ft.app" "Ft" "com.example.ft" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$FAKE_HOME/Applications/Ft.app" --yes --force-risky app-terminate
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# P4-T03 / P4-T04: plan-bound, ordered, verified
# ---------------------------------------------------------------------------

@test "plan-bound: --plan-only saves a plan that 'mimi apply' carries out and verifies" {
  local app="$FAKE_HOME/Applications/Planned.app"
  create_app "$app" "Planned" "com.example.planned" "1.0"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --plan-only
  [ "$status" -eq 0 ]
  [ -d "$app" ]
  local plan
  plan="$(plan_file_from "$output")"
  [ -f "$plan" ]
  [ "$(stat -f '%Lp' "$plan")" = "600" ]

  run /bin/bash "$MIMI_BIN" apply "$plan" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$app" ]
  echo "$output" | grep -q "application removed"
}

@test "plan-bound: a plan edited after it was written is refused" {
  local app="$FAKE_HOME/Applications/Edited.app"
  create_app "$app" "Edited" "com.example.edited" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$app" --plan-only
  local plan
  plan="$(plan_file_from "$output")"
  sed -i '' 's#"target_path": ".*Edited.app"#"target_path": "'"$FAKE_HOME"'/Documents"#' "$plan"

  run /bin/bash "$MIMI_BIN" apply "$plan" --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "digest mismatch"
  [ -d "$app" ]
}

@test "plan-bound: a bundle replaced after planning is refused" {
  local app="$FAKE_HOME/Applications/Swapped.app"
  create_app "$app" "Swapped" "com.example.swapped" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$app" --plan-only
  local plan
  plan="$(plan_file_from "$output")"
  rm -rf "$app"
  create_app "$app" "Swapped" "com.example.swapped" "2.0"

  run /bin/bash "$MIMI_BIN" apply "$plan" --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "changed since plan creation"
  [ -d "$app" ]
}

@test "order: LaunchAgents are stopped and moved before the bundle" {
  local app="$FAKE_HOME/Applications/Ordered.app"
  create_app "$app" "Ordered" "com.example.ordered" "1.0"
  cat > "$FAKE_HOME/Library/LaunchAgents/com.example.ordered.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.example.ordered.helper</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/Ordered</string></array></dict></plist>
PLIST
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"

  source_lib
  app_inspect_bundle "$app"
  collect_app_evidence "$APP_INFO_CANONICAL_PATH" "Ordered" "com.example.ordered" "" "Ordered"
  plan_init
  uninstall_build_plan "$APP_INFO_CANONICAL_PATH" "Ordered" "com.example.ordered"
  plan_build ""
  local first="${PLAN_ACTIONS[0]#*::}" second="${PLAN_ACTIONS[1]#*::}"
  [ "${first%%::*}" = "uninstall-launchagent" ]
  [ "${second%%::*}" = "uninstall-app" ]

  uninstall_apply > /dev/null 2>&1
  [ ! -e "$FAKE_HOME/Library/LaunchAgents/com.example.ordered.helper.plist" ]
  grep -q "launchctl bootout gui/.*/com.example.ordered.helper" "$MOCK_CALL_LOG"
}

@test "verify: data recreated after planning is reported as a leftover" {
  local app="$FAKE_HOME/Applications/Regrow.app"
  create_app "$app" "Regrow" "com.example.regrow" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$app" --plan-only --purge-data
  local plan
  plan="$(plan_file_from "$output")"
  mkdir -p "$FAKE_HOME/Library/Caches/com.example.regrow"

  run /bin/bash "$MIMI_BIN" apply "$plan" --yes
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "leftover still present (new since the plan was made): .*Caches/com.example.regrow"
}

@test "history: an uninstall is recorded" {
  local app="$FAKE_HOME/Applications/Hist.app"
  create_app "$app" "Hist" "com.example.hist" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$app" --yes
  [ "$status" -eq 0 ]
  local h="$FAKE_HOME/.config/mimi/history.jsonl"
  [ -f "$h" ]
  /usr/bin/python3 -c '
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1])][-1]
assert rec["type"] == "uninstall" and rec["status"] == "ok", rec
assert rec["bundle_id"] == "com.example.hist" and rec["quarantined"] >= 1, rec
' "$h"
}

@test "json: --json emits candidates, results, and a finished event" {
  local app="$FAKE_HOME/Applications/Jay.app"
  create_app "$app" "Jay" "com.example.jay" "1.0"
  run --separate-stderr /bin/bash "$MIMI_BIN" app uninstall "$app" --yes --json
  [ "$status" -eq 0 ]
  echo "$output" | /usr/bin/python3 -c '
import json, sys
ev = [json.loads(l) for l in sys.stdin if l.strip()]
types = [e["type"] for e in ev]
assert types[0] == "hello", types
assert "candidate" in types and "action_result" in types, types
assert ev[-1]["type"] == "run_finished" and ev[-1]["status"] == "ok", ev[-1]
'
}

# ---------------------------------------------------------------------------
# P4-T05: Homebrew hand-off
# ---------------------------------------------------------------------------

@test "cask: --cask on an app Homebrew did not install is refused, not guessed" {
  create_app "$FAKE_HOME/Applications/NotCask.app" "NotCask" "com.example.notcask" "1.0"
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"
  run /bin/bash "$MIMI_BIN" app uninstall "$FAKE_HOME/Applications/NotCask.app" --cask --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "was not installed by Homebrew Cask"
  ! grep -q "brew uninstall" "$MOCK_CALL_LOG" 2>/dev/null
}

@test "cask: a token brew does not list as installed is refused" {
  mkdir -p "$FAKE_HOME/Caskroom/stale-cask/1.0"
  create_app "$FAKE_HOME/Applications/Stale Cask.app" "Stale Cask" "com.example.stale" "1.0"
  export MOCK_FAIL_CMDS="brew list*"
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"
  run /bin/bash "$MIMI_BIN" app uninstall "$FAKE_HOME/Applications/Stale Cask.app" --cask --yes
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "refusing to guess"
  ! grep -q "brew uninstall" "$MOCK_CALL_LOG"
}

@test "cask: --zap previews the cask's zap paths and flags shared ones" {
  local meta="$FAKE_HOME/Caskroom/zappy/.metadata/1.0/20260101000000.000/Casks"
  mkdir -p "$meta"
  printf '{"token":"zappy","artifacts":[{"app":["Zappy.app"]},{"zap":[{"trash":["~/Library/Preferences/com.example.zappy.plist","~/Library/Group Containers/group.com.example.zappy"]}]}]}\n' \
    > "$meta/zappy.json"
  create_app "$FAKE_HOME/Applications/Zappy.app" "Zappy" "com.example.zappy" "1.0"
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"

  run /bin/bash "$MIMI_BIN" app uninstall "$FAKE_HOME/Applications/Zappy.app" --zap --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Library/Preferences/com.example.zappy.plist"
  echo "$output" | grep -q "\[shared\] .*Group Containers/group.com.example.zappy"
  grep -q "brew uninstall --cask --zap zappy" "$MOCK_CALL_LOG"
  /usr/bin/python3 -c '
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1])][-1]
assert rec["type"] == "cask-uninstall" and rec["exit"] == 0 and rec["zap"] == 1, rec
' "$FAKE_HOME/.config/mimi/history.jsonl"
}

@test "cask: a failing brew is reported and recorded" {
  mkdir -p "$FAKE_HOME/Caskroom/broken-cask/1.0"
  create_app "$FAKE_HOME/Applications/Broken Cask.app" "Broken Cask" "com.example.broken" "1.0"
  export MOCK_FAIL_CMDS="brew uninstall*"
  run /bin/bash "$MIMI_BIN" app uninstall "$FAKE_HOME/Applications/Broken Cask.app" --cask --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Homebrew cask uninstall failed"
  grep -q '"type":"cask-uninstall","status":"failed"' "$FAKE_HOME/.config/mimi/history.jsonl"
}

# ---------------------------------------------------------------------------
# P4-T06: restore
# ---------------------------------------------------------------------------

@test "restore: bundle and data come back with the same identity, and a second restore is harmless" {
  local app="$FAKE_HOME/Applications/Back.app"
  create_app "$app" "Back" "com.example.back" "1.0"
  printf 'setting\n' > "$FAKE_HOME/Library/Preferences/com.example.back.plist"
  local ident_app
  ident_app="$(stat -f '%d:%i' "$app")"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --purge-data --yes
  local run_id
  run_id="$(run_id_from "$output")"
  [ -n "$run_id" ]

  run /bin/bash "$MIMI_BIN" restore "$run_id"
  [ "$status" -eq 0 ]
  [ "$(stat -f '%d:%i' "$app")" = "$ident_app" ]
  [ "$(cat "$FAKE_HOME/Library/Preferences/com.example.back.plist")" = "setting" ]
  echo "$output" | grep -q "re-register their login items"

  run /bin/bash "$MIMI_BIN" restore "$run_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already restored"
}

@test "restore: a reinstalled app is never overwritten" {
  local app="$FAKE_HOME/Applications/Again.app"
  create_app "$app" "Again" "com.example.again" "1.0"
  run /bin/bash "$MIMI_BIN" app uninstall "$app" --yes
  local run_id
  run_id="$(run_id_from "$output")"
  create_app "$app" "Again" "com.example.again" "2.0"

  run /bin/bash "$MIMI_BIN" restore "$run_id"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "something already exists at"
  grep -q "<string>2.0</string>" "$app/Contents/Info.plist"
  ls "$FAKE_HOME/.config/mimi/quarantine/$run_id" | grep -q "Again.app__"
}

@test "restore: LaunchAgents come back with a note that they are not running" {
  local app="$FAKE_HOME/Applications/Agented.app"
  create_app "$app" "Agented" "com.example.agented" "1.0"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>com.example.agented</string></dict></plist>\n' \
    > "$FAKE_HOME/Library/LaunchAgents/com.example.agented.plist"
  run /bin/bash "$MIMI_BIN" app uninstall "$app" --yes
  [ ! -e "$FAKE_HOME/Library/LaunchAgents/com.example.agented.plist" ]
  local run_id
  run_id="$(run_id_from "$output")"

  run /bin/bash "$MIMI_BIN" restore "$run_id"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/Library/LaunchAgents/com.example.agented.plist" ]
  echo "$output" | grep -q "launchctl bootstrap gui/"
}

@test "gate: user documents named after the app survive even --purge-data" {
  local app="$FAKE_HOME/Applications/Writer.app"
  create_app "$app" "Writer" "com.example.writer" "1.0"
  mkdir -p "$FAKE_HOME/Documents/Writer" "$FAKE_HOME/Desktop/Writer" "$FAKE_HOME/.writer"
  printf 'my novel\n' > "$FAKE_HOME/Documents/Writer/novel.txt"
  printf 'notes\n' > "$FAKE_HOME/.writer/config"
  touch "$FAKE_HOME/Library/Preferences/com.example.writer.plist"

  run /bin/bash "$MIMI_BIN" app uninstall "$app" --purge-data --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_HOME/Documents/Writer/novel.txt")" = "my novel" ]
  [ -d "$FAKE_HOME/Desktop/Writer" ]
  # A name-only dotfolder is weak evidence: kept, never moved.
  [ -f "$FAKE_HOME/.writer/config" ]
  [ ! -e "$FAKE_HOME/Library/Preferences/com.example.writer.plist" ]
}
