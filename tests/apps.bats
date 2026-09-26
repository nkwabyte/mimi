#!/usr/bin/env bats
#
# tests/apps.bats — Phase 3: Application inventory, inspection, and remnant evidence.
# Covers P3-T01 through P3-T06 and the Phase 3 exit gate.
#

load 'test_helper'

# `run --separate-stderr` is used for JSON-mode error documents.
bats_require_minimum_version 1.5.0

setup() {
  TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mimi-test-XXXXXX")"
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
    "$FAKE_HOME/Library/Group Containers"

  export HOME="$FAKE_HOME"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications"
  export MIMI_CASKROOM_DIRS="$FAKE_HOME/Caskroom"
  export MIMI_APP_SYSTEM_ROOTS=""
  export MIMI_RECEIPTS_DIR="$FAKE_HOME/receipts"
  export PATH="$MOCKS_BIN:$PATH"
}

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

# Helper to create an app bundle with Info.plist in $FAKE_HOME/Applications
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
# P3-T01: Installed-app inventory
# ---------------------------------------------------------------------------

@test "apps: list outputs human-readable table of installed applications" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "1.2.3"

  run /bin/bash "$MIMI_BIN" apps list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "=== Installed Applications"
  echo "$output" | grep -q "TestApp"
  echo "$output" | grep -q "com.example.testapp"
  echo "$output" | grep -q "1.2.3"
}

@test "apps: list --json produces valid JSON array of application objects" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "1.2.3"

  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"name": "TestApp"'
  echo "$output" | grep -q '"bundle_id": "com.example.testapp"'
  echo "$output" | grep -q '"version": "1.2.3"'
  echo "$output" | grep -q '"is_system": false'
}

@test "apps: list does not mutate or delete any application files" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "1.2.3"

  run /bin/bash "$MIMI_BIN" apps list
  [ "$status" -eq 0 ]
  [ -f "$app/Contents/Info.plist" ]
  [ -f "$app/Contents/MacOS/TestApp" ]
}

# ---------------------------------------------------------------------------
# P3-T02: Bundle and signing fingerprint
# ---------------------------------------------------------------------------

@test "bundle: detects nested helpers and XPC services" {
  local app="$FAKE_HOME/Applications/HelperApp.app"
  create_app "$app" "HelperApp" "com.example.helperapp" "2.0.0"

  mkdir -p "$app/Contents/MacOS/HelperTool.app"
  mkdir -p "$app/Contents/XPCServices/Service.xpc"
  mkdir -p "$app/Contents/Library/LoginItems/LoginHelper.app"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"nested_helpers": \["HelperTool.app"\]'
  echo "$output" | grep -q '"xpc_services": \["Service.xpc"\]'
  echo "$output" | grep -q '"login_items": \["LoginHelper.app"\]'
}

@test "bundle: flags system applications as system protected" {
  local app="$FAKE_HOME/Applications/AppleUtility.app"
  create_app "$app" "AppleUtility" "com.apple.utility" "1.0.0"

  run /bin/bash "$MIMI_BIN" app inspect "$app"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "System Protected:"
  echo "$output" | grep -q "Yes"
}

# ---------------------------------------------------------------------------
# P3-T03: Provenance inventory
# ---------------------------------------------------------------------------

@test "provenance: detects Mac App Store receipt" {
  local app="$FAKE_HOME/Applications/MASApp.app"
  create_app "$app" "MASApp" "com.example.masapp" "3.1.0"
  mkdir -p "$app/Contents/_MASReceipt"
  touch "$app/Contents/_MASReceipt/receipt"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"source": "mas"'
}

@test "provenance: detects Homebrew cask installation" {
  local app="$FAKE_HOME/Applications/CaskApp.app"
  create_app "$app" "CaskApp" "com.example.caskapp" "4.0.0"
  mkdir -p "$FAKE_HOME/Caskroom/caskapp/4.0.0"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"source": "cask"'
}

@test "provenance: detects vendor uninstaller" {
  local app="$FAKE_HOME/Applications/VendorApp.app"
  create_app "$app" "VendorApp" "com.example.vendorapp" "1.0.0"
  mkdir -p "$app/Contents/Resources"
  touch "$app/Contents/Resources/Uninstall VendorApp.sh"

  run /bin/bash "$MIMI_BIN" app inspect "$app"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Vendor Uninstaller:"
  echo "$output" | grep -q "Uninstall VendorApp.sh"
}

# ---------------------------------------------------------------------------
# P3-T04 & P3-T05: Remnant evidence collectors & confidence/shared policy
# ---------------------------------------------------------------------------

@test "evidence: collects remnants and assigns confidence levels" {
  local app="$FAKE_HOME/Applications/SlackTest.app"
  create_app "$app" "SlackTest" "com.tinyspeck.slacktest" "4.30.0"

  # 1. Authoritative: Container
  mkdir -p "$FAKE_HOME/Library/Containers/com.tinyspeck.slacktest"
  touch "$FAKE_HOME/Library/Containers/com.tinyspeck.slacktest/container.data"

  # 2. Authoritative: Preferences
  mkdir -p "$FAKE_HOME/Library/Preferences"
  touch "$FAKE_HOME/Library/Preferences/com.tinyspeck.slacktest.plist"

  # 3. Strong: Application Support with reverse-DNS
  mkdir -p "$FAKE_HOME/Library/Application Support/com.tinyspeck.slacktest"
  touch "$FAKE_HOME/Library/Application Support/com.tinyspeck.slacktest/storage.db"

  # 4. Weak: Bare-word Cache
  mkdir -p "$FAKE_HOME/Library/Caches/SlackTest"
  touch "$FAKE_HOME/Library/Caches/SlackTest/cache.tmp"

  # 5. Shared: Group Containers
  mkdir -p "$FAKE_HOME/Library/Group Containers/group.com.tinyspeck.slacktest"
  touch "$FAKE_HOME/Library/Group Containers/group.com.tinyspeck.slacktest/shared.db"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]

  # Check authoritative container
  echo "$output" | grep -q '"confidence": "authoritative"'
  echo "$output" | grep -q 'Containers/com.tinyspeck.slacktest'

  # Check strong Application Support
  echo "$output" | grep -q '"confidence": "strong"'
  echo "$output" | grep -q 'Application Support/com.tinyspeck.slacktest'

  # Check weak bare name cache
  echo "$output" | grep -q '"confidence": "weak"'
  echo "$output" | grep -q 'Caches/SlackTest'

  # Check shared group container is flagged as shared
  echo "$output" | grep -q '"confidence": "shared"'
  echo "$output" | grep -q '"is_shared": true'
  echo "$output" | grep -q 'Group Containers/group.com.tinyspeck.slacktest'
}

@test "evidence: shared vendor directories are not claimed by a single app" {
  local app="$FAKE_HOME/Applications/ChromeTest.app"
  create_app "$app" "ChromeTest" "com.google.chrometest" "115.0"

  # Google top-level shared folder
  mkdir -p "$FAKE_HOME/Library/Application Support/Google"
  touch "$FAKE_HOME/Library/Application Support/Google/shared_config.json"

  # Chrome-specific subfolder
  mkdir -p "$FAKE_HOME/Library/Application Support/Google/ChromeTest"
  touch "$FAKE_HOME/Library/Application Support/Google/ChromeTest/profile.dat"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]

  # ChromeTest subfolder is attributable
  echo "$output" | grep -q 'Google/ChromeTest'

  # Top-level Google shared folder is NOT claimed
  ! echo "$output" | grep -q '"path": ".*/Application Support/Google"'
}

# ---------------------------------------------------------------------------
# P3-T06: App inspection command & target resolution
# ---------------------------------------------------------------------------

@test "inspect: resolves by bundle ID" {
  local app="$FAKE_HOME/Applications/TargetApp.app"
  create_app "$app" "TargetApp" "com.example.targetapp" "1.0"

  run /bin/bash "$MIMI_BIN" app inspect "com.example.targetapp"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "=== Application Inspection: TargetApp ==="
  echo "$output" | grep -q "com.example.targetapp"
}

@test "inspect: resolves by app name" {
  local app="$FAKE_HOME/Applications/UniqueAppName.app"
  create_app "$app" "UniqueAppName" "com.example.unique" "2.5"

  run /bin/bash "$MIMI_BIN" app inspect "UniqueAppName"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "=== Application Inspection: UniqueAppName ==="
  echo "$output" | grep -q "com.example.unique"
}

@test "inspect: ambiguous app name stops with error and choices" {
  local app1="$FAKE_HOME/Applications/AppOne.app"
  local app2="$FAKE_HOME/Applications/Utilities/AppOne.app"
  mkdir -p "$FAKE_HOME/Applications/Utilities"
  create_app "$app1" "AppOne" "com.example.appone.main" "1.0"
  create_app "$app2" "AppOne" "com.example.appone.util" "1.0"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications:$FAKE_HOME/Applications/Utilities"

  run /bin/bash "$MIMI_BIN" app inspect "AppOne"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ambiguous application target"
  echo "$output" | grep -q "AppOne.app"
}

@test "inspect: nonexistent app exits with clear error" {
  run /bin/bash "$MIMI_BIN" app inspect "NonExistentApp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'application "NonExistentApp" not found'
}

# ---------------------------------------------------------------------------
# Phase 3 Exit Gate
# ---------------------------------------------------------------------------

@test "gate: inventory works without mutation and weak/shared evidence is retained" {
  local app="$FAKE_HOME/Applications/GateApp.app"
  create_app "$app" "GateApp" "com.example.gateapp" "5.0.0"

  mkdir -p "$FAKE_HOME/Library/Group Containers/group.com.example.gateapp"
  touch "$FAKE_HOME/Library/Group Containers/group.com.example.gateapp/keep.me"

  mkdir -p "$FAKE_HOME/Library/Application Support/GateApp"
  touch "$FAKE_HOME/Library/Application Support/GateApp/data.bin"

  # Run inspect
  run /bin/bash "$MIMI_BIN" app inspect "GateApp"
  [ "$status" -eq 0 ]

  # Check that Retained / Shared Resources is prominently displayed
  echo "$output" | grep -q "Retained / Shared Resources (Vetoed from Removal"
  echo "$output" | grep -q "group.com.example.gateapp"

  # Assert no files were modified or deleted
  [ -f "$FAKE_HOME/Library/Group Containers/group.com.example.gateapp/keep.me" ]
  [ -f "$FAKE_HOME/Library/Application Support/GateApp/data.bin" ]
  [ -f "$app/Contents/Info.plist" ]
}

# ===========================================================================
# Phase 3 completion — gaps closed on 2026-09-26
# ===========================================================================

# Canonical form of a fixture path (/var -> /private/var), as the tool prints it.
canon() {
  local d b
  d="$(cd -P "$(dirname "$1")" && pwd -P)"
  b="$(basename "$1")"
  printf '%s/%s' "$d" "$b"
}

# Evaluate a Python expression against JSON on stdin; `d` is the document.
# Prints the result; exits non-zero when the JSON does not parse.
json_eval() {
  /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1])
print(json.dumps(r) if not isinstance(r, str) else r)
' "$1"
}

# Every file under DIR with its size and mtime — a fingerprint for "nothing changed".
tree_fingerprint() {
  find "$1" -exec stat -f '%N %z %m %i' {} \; | sort | cksum
}

# ---------------------------------------------------------------------------
# P3-T01: explicit roots, vendor folders, unavailable roots, identity, JSON
# ---------------------------------------------------------------------------

@test "inventory: --app-root is repeatable and skips Spotlight for explicit roots" {
  mkdir -p "$TEST_TMPDIR/rootA" "$TEST_TMPDIR/rootB"
  create_app "$TEST_TMPDIR/rootA/AlphaApp.app" "AlphaApp" "com.example.alpha" "1.0"
  create_app "$TEST_TMPDIR/rootB/BetaApp.app" "BetaApp" "com.example.beta" "1.0"
  unset MIMI_APP_SEARCH_ROOTS

  run /bin/bash "$MIMI_BIN" apps list --json --app-root "$TEST_TMPDIR/rootA" --app-root "$TEST_TMPDIR/rootB"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted(a["name"] for a in d["apps"])')" = '["AlphaApp", "BetaApp"]' ]
  [ "$(echo "$output" | json_eval 'd["inventory"]["spotlight"]')" = "skipped" ]
  [ "$(echo "$output" | json_eval 'd["inventory"]["complete"]')" = "true" ]
}

@test "inventory: finds apps in vendor folders but never bundles nested inside bundles" {
  create_app "$FAKE_HOME/Applications/Vendor Suite/VendorTool.app" "VendorTool" "com.example.vendortool" "1.0"
  create_app "$FAKE_HOME/Applications/Outer.app" "Outer" "com.example.outer" "1.0"
  create_app "$FAKE_HOME/Applications/Outer.app/Inner.app" "Inner" "com.example.inner" "1.0"

  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted(a["name"] for a in d["apps"])')" = '["Outer", "VendorTool"]' ]
}

@test "inventory: an unavailable root marks the inventory incomplete, explicitly" {
  create_app "$FAKE_HOME/Applications/TestApp.app" "TestApp" "com.example.testapp" "1.0"
  local missing="$TEST_TMPDIR/Volumes/Unplugged/Applications"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications:$missing"

  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["inventory"]["complete"]')" = "false" ]
  [ "$(echo "$output" | json_eval 'd["inventory"]["unavailable_roots"]')" = "[\"$missing\"]" ]
  [ "$(echo "$output" | json_eval 'len(d["apps"])')" = "1" ]

  run /bin/bash "$MIMI_BIN" apps list
  echo "$output" | grep -q "incomplete: 1 application root(s) unavailable or unreadable"
}

@test "inventory: Spotlight that misses walked apps is reported as an incomplete index" {
  create_app "$FAKE_HOME/Applications/Indexed.app" "Indexed" "com.example.indexed" "1.0"
  create_app "$FAKE_HOME/Applications/Unindexed.app" "Unindexed" "com.example.unindexed" "1.0"
  printf '%s|com.example.indexed\n' "$(canon "$FAKE_HOME/Applications/Indexed.app")" > "$TEST_TMPDIR/index"
  export MOCK_APP_INDEX="$TEST_TMPDIR/index"

  source_lib
  APP_SEARCH_ROOTS=("$FAKE_HOME/Applications")
  APP_ROOTS_EXPLICIT=0
  inventory_scan_apps list
  [ "$APP_INV_SPOTLIGHT" = "used" ]
  [ "$APP_INV_COUNT" -eq 2 ]
  [ "$APP_INV_COMPLETE" -eq 0 ]
  [[ "$APP_INV_NOTE" == *"Spotlight missed 1 application(s)"* ]]
}

@test "inventory: an empty Spotlight index is reported, not trusted" {
  create_app "$FAKE_HOME/Applications/Solo.app" "Solo" "com.example.solo" "1.0"
  source_lib
  APP_SEARCH_ROOTS=("$FAKE_HOME/Applications")
  APP_ROOTS_EXPLICIT=0
  inventory_scan_apps list
  [ "$APP_INV_COUNT" -eq 1 ]
  [ "$APP_INV_COMPLETE" -eq 0 ]
  [[ "$APP_INV_NOTE" == *"Spotlight index is empty"* ]]
}

@test "inventory: JSON records canonical path and device:inode identity" {
  local app="$FAKE_HOME/Applications/TestApp.app"
  create_app "$app" "TestApp" "com.example.testapp" "1.0"
  local expect_id
  expect_id="$(stat -f '%d:%i' "$app")"

  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["schema"]')" = "mimi.apps-list/1" ]
  [ "$(echo "$output" | json_eval 'd["apps"][0]["path"]')" = "$(canon "$app")" ]
  [ "$(echo "$output" | json_eval 'd["apps"][0]["identity"]')" = "$expect_id" ]
  [ "$(echo "$output" | json_eval 'd["apps"][0]["eligible"]')" = "true" ]
}

@test "inventory: --source filters by provenance and rejects unknown values" {
  create_app "$FAKE_HOME/Applications/Plain.app" "Plain" "com.example.plain" "1.0"
  create_app "$FAKE_HOME/Applications/Store.app" "Store" "com.example.store" "1.0"
  mkdir -p "$FAKE_HOME/Applications/Store.app/Contents/_MASReceipt"
  touch "$FAKE_HOME/Applications/Store.app/Contents/_MASReceipt/receipt"

  run /bin/bash "$MIMI_BIN" apps list --json --source mas
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[a["name"] for a in d["apps"]]')" = '["Store"]' ]

  run /bin/bash "$MIMI_BIN" apps list --source bogus
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "source must be one of"
}

@test "inventory: an empty root produces a valid, empty JSON document" {
  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["apps"]')" = "[]" ]
}

# ---------------------------------------------------------------------------
# P3-T02: nested components, signing, and ambiguous identities
# ---------------------------------------------------------------------------

@test "bundle: reports Electron helpers, extensions, and bundled launchd jobs" {
  local app="$FAKE_HOME/Applications/ElectronApp.app"
  create_app "$app" "ElectronApp" "com.example.electronapp" "1.0"
  mkdir -p "$app/Contents/Frameworks/ElectronApp Helper (GPU).app" \
           "$app/Contents/PlugIns/Share.appex" \
           "$app/Contents/Library/LaunchAgents" \
           "$app/Contents/Library/LaunchServices"
  touch "$app/Contents/Library/LaunchAgents/com.example.electronapp.agent.plist" \
        "$app/Contents/Library/LaunchServices/com.example.electronapp.helper"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["nested_helpers"]')" = '["ElectronApp Helper (GPU).app"]' ]
  [ "$(echo "$output" | json_eval 'd["app"]["extensions"]')" = '["Share.appex"]' ]
  [ "$(echo "$output" | json_eval 'sorted(d["app"]["bundled_launchd"])')" = \
    '["Library/LaunchAgents/com.example.electronapp.agent.plist", "Library/LaunchServices/com.example.electronapp.helper"]' ]
}

@test "bundle: records signing identifier and Team ID" {
  local app="$FAKE_HOME/Applications/Signed.app"
  create_app "$app" "Signed" "com.example.signed" "1.0"
  printf '%s|com.example.signed|ABCDE12345|Developer ID Application: Example (ABCDE12345)\n' \
    "$(canon "$app")" > "$TEST_TMPDIR/cs"
  export MOCK_CODESIGN_INDEX="$TEST_TMPDIR/cs"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["signing"]["status"]')" = "signed" ]
  [ "$(echo "$output" | json_eval 'd["app"]["signing"]["team_id"]')" = "ABCDE12345" ]
  [ "$(echo "$output" | json_eval 'd["app"]["eligible"]')" = "true" ]
  [ "$(echo "$output" | json_eval 'd["app"]["identity_warnings"]')" = "[]" ]
}

@test "bundle: Apple-signed apps outside /System are system and ineligible" {
  local app="$FAKE_HOME/Applications/Pages.app"
  create_app "$app" "Pages" "com.example.notapple" "1.0"
  printf '%s|com.example.notapple||Software Signing\n' "$(canon "$app")" > "$TEST_TMPDIR/cs"
  export MOCK_CODESIGN_INDEX="$TEST_TMPDIR/cs"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["is_system"]')" = "true" ]
  [ "$(echo "$output" | json_eval 'd["app"]["eligible"]')" = "false" ]
  [ "$(echo "$output" | json_eval 'd["app"]["source"]')" = "system" ]
}

@test "bundle: a signature identifier that contradicts the bundle id is ambiguous" {
  local app="$FAKE_HOME/Applications/Imposter.app"
  create_app "$app" "Imposter" "com.example.imposter" "1.0"
  printf '%s|com.other.real|ZZZZZ99999|Developer ID Application: Other (ZZZZZ99999)\n' \
    "$(canon "$app")" > "$TEST_TMPDIR/cs"
  export MOCK_CODESIGN_INDEX="$TEST_TMPDIR/cs"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["eligible"]')" = "false" ]
  echo "$output" | json_eval 'd["app"]["ineligible_reason"]' | grep -q "does not match bundle identifier"
}

@test "bundle: a bundle without an identifier is ineligible" {
  local app="$FAKE_HOME/Applications/NoId.app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleName</key><string>NoId</string></dict></plist>
PLIST

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["eligible"]')" = "false" ]
  [ "$(echo "$output" | json_eval 'd["app"]["ineligible_reason"]')" = "no bundle identifier; identity is ambiguous" ]
}

@test "bundle: inspecting through a symlink reports the canonical bundle and warns" {
  local app="$FAKE_HOME/Applications/Real.app"
  create_app "$app" "Real" "com.example.real" "1.0"
  ln -s "$app" "$TEST_TMPDIR/Link.app"

  run /bin/bash "$MIMI_BIN" app inspect "$TEST_TMPDIR/Link.app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["path"]')" = "$(canon "$app")" ]
  echo "$output" | json_eval 'd["app"]["identity_warnings"]' | grep -q "symbolic link"
}

# ---------------------------------------------------------------------------
# P3-T03: provenance facts
# ---------------------------------------------------------------------------

@test "provenance: cask definition metadata identifies a cask whose token differs from the app name" {
  local app="$FAKE_HOME/Applications/Visual Studio Code.app"
  create_app "$app" "Code" "com.microsoft.VSCode" "1.90.0"
  local meta="$FAKE_HOME/Caskroom/visual-studio-code/.metadata/1.90.0/20260101000000.000/Casks"
  mkdir -p "$meta"
  printf '{"token":"visual-studio-code","artifacts":[{"app":["Visual Studio Code.app"]}]}\n' \
    > "$meta/visual-studio-code.json"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["source"]')" = "cask" ]
  [ "$(echo "$output" | json_eval 'd["app"]["cask"]')" = '{"token": "visual-studio-code", "method": "metadata"}' ]

  run /bin/bash "$MIMI_BIN" app inspect visual-studio-code --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["resolution"]["method"]')" = "cask" ]
}

@test "provenance: installer receipts are correlated by path and never modified" {
  local app="$FAKE_HOME/Applications/PkgApp.app"
  create_app "$app" "PkgApp" "com.example.pkgapp" "1.0"
  printf '%s|com.example.pkg.installer\n' "$(canon "$app")" > "$TEST_TMPDIR/pkgs"
  export MOCK_PKG_INDEX="$TEST_TMPDIR/pkgs"
  export MOCK_CALL_LOG="$TEST_TMPDIR/calls"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["source"]')" = "pkg" ]
  [ "$(echo "$output" | json_eval 'd["app"]["pkg_receipts"]')" = '["com.example.pkg.installer"]' ]
  # Only read-only queries reached pkgutil.
  ! grep '^pkgutil' "$MOCK_CALL_LOG" | grep -v -- '--file-info'
}

@test "provenance: a receipt named after the bundle id is reported" {
  local app="$FAKE_HOME/Applications/RcptApp.app"
  create_app "$app" "RcptApp" "com.example.rcptapp" "1.0"
  mkdir -p "$MIMI_RECEIPTS_DIR"
  touch "$MIMI_RECEIPTS_DIR/com.example.rcptapp.plist" "$MIMI_RECEIPTS_DIR/com.example.rcptapp.bom"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["pkg_receipts"]')" = '["com.example.rcptapp"]' ]
  [ -f "$MIMI_RECEIPTS_DIR/com.example.rcptapp.bom" ]
}

@test "provenance: all applicable facts are listed, primary follows precedence" {
  local app="$FAKE_HOME/Applications/Both.app"
  create_app "$app" "Both" "com.example.both" "1.0"
  mkdir -p "$app/Contents/_MASReceipt" "$FAKE_HOME/Caskroom/both/1.0"
  touch "$app/Contents/_MASReceipt/receipt"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["source"]')" = "mas" ]
  [ "$(echo "$output" | json_eval 'sorted(f.split(":")[0] for f in d["app"]["provenance_facts"])')" = '["cask", "mas"]' ]
}

@test "provenance: an uninstall icon is not mistaken for a vendor uninstaller" {
  local app="$FAKE_HOME/Applications/IconApp.app"
  create_app "$app" "IconApp" "com.example.iconapp" "1.0"
  mkdir -p "$app/Contents/Resources"
  touch "$app/Contents/Resources/uninstall.png" "$app/Contents/Resources/UninstallHelp.html"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["vendor_uninstaller"]')" = "null" ]
}

@test "provenance: a vendor-folder uninstaller is reported and left untouched" {
  local vendor="$FAKE_HOME/Applications/Acme"
  create_app "$vendor/Acme Studio.app" "Acme Studio" "com.acme.studio" "1.0"
  create_app "$vendor/Uninstall Acme Studio.app" "Uninstall Acme Studio" "com.acme.uninstaller" "1.0"

  run /bin/bash "$MIMI_BIN" app inspect "$vendor/Acme Studio.app"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Vendor Uninstaller:.*Uninstall Acme Studio.app (report-only)"
  [ -f "$vendor/Uninstall Acme Studio.app/Contents/Info.plist" ]
}

# ---------------------------------------------------------------------------
# P3-T04: additional roots — sandbox, cookies, startup, crash logs, dev dirs
# ---------------------------------------------------------------------------

@test "evidence: sandbox scripts, cookies, WebKit, ByHost are authoritative by exact id" {
  local app="$FAKE_HOME/Applications/Sandy.app"
  create_app "$app" "Sandy" "com.example.sandy" "1.0"
  local L="$FAKE_HOME/Library"
  mkdir -p "$L/Application Scripts/com.example.sandy" "$L/Cookies" "$L/WebKit/com.example.sandy" \
           "$L/Preferences/ByHost" "$L/HTTPStorages/com.example.sandy"
  touch "$L/Cookies/com.example.sandy.binarycookies" \
        "$L/Preferences/ByHost/com.example.sandy.0A1B2C3D-0000-0000-0000-000000000000.plist"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted(r["root"] for r in d["remnants"] if r["confidence"] == "authoritative")')" = \
    '["Application Scripts", "Cookies", "HTTPStorages", "Preferences (ByHost)", "WebKit"]' ]
}

@test "evidence: a LaunchAgent that runs the app's binary is strong even with an unrelated name" {
  local app="$FAKE_HOME/Applications/Agent.app"
  create_app "$app" "Agent" "com.example.agent" "1.0"
  mkdir -p "$FAKE_HOME/Library/LaunchAgents"
  cat > "$FAKE_HOME/Library/LaunchAgents/io.unrelated.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>io.unrelated.helper</string>
<key>ProgramArguments</key><array><string>$(canon "$app")/Contents/MacOS/Agent</string><string>--daemon</string></array>
</dict></plist>
PLIST

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[r["confidence"] for r in d["remnants"] if r["root"] == "LaunchAgents"]')" = '["strong"]' ]
}

@test "evidence: crash reports need the bundle id in their contents to be corroborated" {
  local app="$FAKE_HOME/Applications/Crashy.app"
  create_app "$app" "Crashy" "com.example.crashy" "1.0"
  local dr="$FAKE_HOME/Library/Logs/DiagnosticReports"
  mkdir -p "$dr"
  printf '{"bundleID":"com.example.crashy"}\n' > "$dr/Crashy-2026-09-01-101010.ips"
  printf 'no identifiers here\n' > "$dr/Crashy-2026-09-02-101010.ips"
  printf 'other app\n' > "$dr/CrashyOther-2026-09-02-101010.ips"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted((r["path"].rsplit("/",1)[1], r["confidence"]) for r in d["remnants"] if r["root"] == "Crash Reports")')" = \
    '[["Crashy-2026-09-01-101010.ips", "corroborated"], ["Crashy-2026-09-02-101010.ips", "weak"]]' ]
}

@test "evidence: developer dotfolders are reported for review, never selectable" {
  local app="$FAKE_HOME/Applications/Toolbox.app"
  create_app "$app" "Toolbox" "com.example.toolbox" "1.0"
  mkdir -p "$FAKE_HOME/.toolbox" "$FAKE_HOME/.config/toolbox"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted((r["class"], r["selectable"]) for r in d["remnants"] if r["root"] == "Developer Artifacts")')" = \
    '[["review", false], ["review", false]]' ]
}

@test "evidence: system locations are report-only and never selectable" {
  local app="$FAKE_HOME/Applications/SysApp.app"
  create_app "$app" "SysApp" "com.example.sysapp" "1.0"
  local sys="$TEST_TMPDIR/Library/LaunchDaemons"
  mkdir -p "$sys"
  touch "$sys/com.example.sysapp.helper.plist"
  export MIMI_APP_SYSTEM_ROOTS="$sys"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[(r["is_system_location"], r["class"], r["selectable"]) for r in d["remnants"]]')" = \
    '[[true, "retained", false]]' ]
}

# ---------------------------------------------------------------------------
# P3-T05: adversarial, rebrand, and shared-sibling fixtures
# ---------------------------------------------------------------------------

@test "policy: a longer bundle id that merely starts with the target id is not claimed" {
  local app="$FAKE_HOME/Applications/App.app"
  create_app "$app" "Appish" "com.example.app" "1.0"
  mkdir -p "$FAKE_HOME/Library/Caches/com.example.application" "$FAKE_HOME/Library/Group Containers/group.com.example.application"
  touch "$FAKE_HOME/Library/Preferences/com.example.application.plist"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["remnants"]')" = "[]" ]
}

@test "policy: data of an installed sibling with a more specific bundle id is conflicting" {
  create_app "$FAKE_HOME/Applications/Editor.app" "Editor" "com.example.editor" "1.0"
  create_app "$FAKE_HOME/Applications/Editor Beta.app" "Editor Beta" "com.example.editor.beta" "2.0"
  mkdir -p "$FAKE_HOME/Library/Caches/com.example.editor" "$FAKE_HOME/Library/Caches/com.example.editor.beta"

  run /bin/bash "$MIMI_BIN" app inspect "com.example.editor" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted((r["path"].rsplit("/",1)[1], r["confidence"], r["selectable"]) for r in d["remnants"])')" = \
    '[["com.example.editor", "strong", true], ["com.example.editor.beta", "conflicting", false]]' ]
  # The sibling is untouched.
  [ -d "$FAKE_HOME/Library/Caches/com.example.editor.beta" ]
}

@test "policy: a second installed copy with the same bundle id makes all id evidence conflicting" {
  create_app "$FAKE_HOME/Applications/Twin.app" "Twin" "com.example.twin" "1.0"
  mkdir -p "$TEST_TMPDIR/Apps2"
  create_app "$TEST_TMPDIR/Apps2/Twin.app" "Twin" "com.example.twin" "1.1"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications:$TEST_TMPDIR/Apps2"
  mkdir -p "$FAKE_HOME/Library/Containers/com.example.twin"

  run /bin/bash "$MIMI_BIN" app inspect "$FAKE_HOME/Applications/Twin.app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[(r["confidence"], r["selectable"]) for r in d["remnants"]]')" = '[["conflicting", false]]' ]
  echo "$output" | json_eval 'd["notes"]' | grep -q "another installed copy shares this bundle id"
}

@test "policy: a rebranded app keeps bundle-id evidence and does not claim its old name" {
  local app="$FAKE_HOME/Applications/NewBrand.app"
  create_app "$app" "NewBrand" "com.example.oldbrand" "3.0"
  touch "$FAKE_HOME/Library/Preferences/com.example.oldbrand.plist"
  mkdir -p "$FAKE_HOME/Library/Application Support/OldBrand"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[(r["root"], r["confidence"]) for r in d["remnants"]]')" = '[["Preferences", "authoritative"]]' ]
}

@test "policy: a name-only preference plist is weak; bundle-id contents corroborate it" {
  create_app "$FAKE_HOME/Applications/Notary.app" "Notary" "com.example.notary" "1.0"
  printf 'LastLaunchedBy=com.example.notary\n' > "$FAKE_HOME/Library/Preferences/Notary.plist"
  printf 'nothing\n' > "$FAKE_HOME/Library/Preferences/notary-legacy.plist"
  mkdir -p "$FAKE_HOME/Library/Saved Application State/Notary.savedState"

  run /bin/bash "$MIMI_BIN" app inspect "Notary" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'sorted((r["root"], r["confidence"]) for r in d["remnants"])')" = \
    '[["Preferences", "corroborated"], ["Saved Application State", "weak"]]' ]
}

@test "policy: a symlinked remnant is recorded as the link, weak, and its target untouched" {
  local app="$FAKE_HOME/Applications/Linky.app"
  create_app "$app" "Linky" "com.example.linky" "1.0"
  mkdir -p "$TEST_TMPDIR/elsewhere/precious"
  printf 'user document\n' > "$TEST_TMPDIR/elsewhere/precious/doc.txt"
  ln -s "$TEST_TMPDIR/elsewhere/precious" "$FAKE_HOME/Library/Application Support/com.example.linky"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[(r["kind"], r["confidence"], r["selectable"]) for r in d["remnants"]]')" = '[["symlink", "weak", false]]' ]
  [ "$(echo "$output" | json_eval 'd["remnants"][0]["path"]')" = "$(canon "$FAKE_HOME/Library/Application Support")/com.example.linky" ]
  [ -f "$TEST_TMPDIR/elsewhere/precious/doc.txt" ]
}

@test "policy: a same-named second app makes name-only evidence conflicting" {
  create_app "$FAKE_HOME/Applications/Widget.app" "Widget" "com.alpha.widget" "1.0"
  mkdir -p "$TEST_TMPDIR/Apps2"
  create_app "$TEST_TMPDIR/Apps2/Widget.app" "Widget" "com.beta.widget" "1.0"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications:$TEST_TMPDIR/Apps2"
  mkdir -p "$FAKE_HOME/Library/Caches/Widget"

  run /bin/bash "$MIMI_BIN" app inspect "com.alpha.widget" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[r["confidence"] for r in d["remnants"]]')" = '["conflicting"]' ]
}

@test "policy: shared vendor updaters are vetoed even when they match the app" {
  source_lib
  is_shared_updater_name "com.google.keystone.agent.plist"
  is_shared_updater_name "Microsoft AutoUpdate"
  ! is_shared_updater_name "com.example.updater"
}

@test "policy: names too short for matching disable name-based evidence" {
  local app="$FAKE_HOME/Applications/Go.app"
  create_app "$app" "Go" "com.example.go" "1.0"
  mkdir -p "$FAKE_HOME/Library/Caches/Go" "$FAKE_HOME/Library/Caches/com.example.go"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval '[r["path"].rsplit("/",1)[1] for r in d["remnants"]]')" = '["com.example.go"]' ]
  echo "$output" | json_eval 'd["notes"]' | grep -q "too short for name-based matching"
}

@test "policy: ev_id_match is boundary-aware" {
  source_lib
  [ "$(ev_id_match com.foo.app com.foo.app)" = "exact" ]
  [ "$(ev_id_match com.foo.app.helper com.foo.app)" = "child" ]
  [ "$(ev_id_match ABCDE12345.com.foo.app com.foo.app)" = "prefix" ]
  [ "$(ev_id_match COM.FOO.APP com.foo.app)" = "exact" ]
  ! ev_id_match com.foo.application com.foo.app
  ! ev_id_match xcom.foo.app com.foo.app
}

# ---------------------------------------------------------------------------
# P3-T06: resolution rules and stable JSON
# ---------------------------------------------------------------------------

@test "inspect: JSON is valid, versioned, and records how the target was resolved" {
  create_app "$FAKE_HOME/Applications/Resolver.app" "Resolver" "com.example.Resolver" "1.0"

  run /bin/bash "$MIMI_BIN" app inspect "com.example.Resolver" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["schema"]')" = "mimi.app-inspect/1" ]
  [ "$(echo "$output" | json_eval 'd["resolution"]["method"]')" = "bundle_id" ]

  run /bin/bash "$MIMI_BIN" app inspect "COM.EXAMPLE.RESOLVER" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["resolution"]["method"]')" = "bundle_id" ]

  run /bin/bash "$MIMI_BIN" app inspect "resolver" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["resolution"]["method"]')" = "name" ]
}

@test "inspect: ambiguous target in JSON mode returns an error object with every candidate" {
  mkdir -p "$FAKE_HOME/Applications/Utilities"
  create_app "$FAKE_HOME/Applications/Dup.app" "Dup" "com.example.dup.one" "1.0"
  create_app "$FAKE_HOME/Applications/Utilities/Dup.app" "Dup" "com.example.dup.two" "1.0"

  run --separate-stderr /bin/bash "$MIMI_BIN" app inspect "Dup" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | json_eval 'd["error"]["code"]')" = "ambiguous" ]
  [ "$(echo "$output" | json_eval 'sorted(c["bundle_id"] for c in d["error"]["candidates"])')" = \
    '["com.example.dup.one", "com.example.dup.two"]' ]
}

@test "inspect: a path that is not an application bundle is refused" {
  mkdir -p "$TEST_TMPDIR/NotAnApp.app"
  run /bin/bash "$MIMI_BIN" app inspect "$TEST_TMPDIR/NotAnApp.app"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not an application bundle"

  run /bin/bash "$MIMI_BIN" app inspect "$TEST_TMPDIR/missing/Thing.app"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "no such application path"
}

@test "inspect: a bare name is never treated as a path in the current directory" {
  create_app "$FAKE_HOME/Applications/Local.app" "Local" "com.example.installed" "1.0"
  mkdir -p "$TEST_TMPDIR/cwd"
  create_app "$TEST_TMPDIR/cwd/Local" "Local" "com.example.cwdcopy" "1.0"

  cd "$TEST_TMPDIR/cwd"
  run /bin/bash "$MIMI_BIN" app inspect "Local" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | json_eval 'd["app"]["bundle_id"]')" = "com.example.installed" ]
}

@test "inspect: human output separates attributable, review, and retained evidence" {
  local app="$FAKE_HOME/Applications/Sections.app"
  create_app "$app" "Sections" "com.example.sections" "1.0"
  touch "$FAKE_HOME/Library/Preferences/com.example.sections.plist"
  mkdir -p "$FAKE_HOME/Library/Caches/Sections" "$FAKE_HOME/Library/Group Containers/group.com.example.sections"

  run /bin/bash "$MIMI_BIN" app inspect "$app"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Attributable User Data (Estimated: .*, 1 items)"
  echo "$output" | grep -q "Needs Review (weak evidence, never selected automatically"
  echo "$output" | grep -q "Retained / Shared Resources (Vetoed from Removal"
  echo "$output" | grep -q "Eligible:.*Yes"
}

# ---------------------------------------------------------------------------
# Phase 3 exit gate (strengthened)
# ---------------------------------------------------------------------------

@test "gate: list and inspect change nothing on disk" {
  local app="$FAKE_HOME/Applications/Frozen.app"
  create_app "$app" "Frozen" "com.example.frozen" "1.0"
  touch "$FAKE_HOME/Library/Preferences/com.example.frozen.plist"
  mkdir -p "$FAKE_HOME/Library/Caches/Frozen" "$FAKE_HOME/Library/Group Containers/group.com.example.frozen"
  local before
  before="$(tree_fingerprint "$FAKE_HOME")"

  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  run /bin/bash "$MIMI_BIN" app inspect "Frozen" --json
  [ "$status" -eq 0 ]
  run /bin/bash "$MIMI_BIN" app inspect "Frozen"
  [ "$status" -eq 0 ]

  [ "$(tree_fingerprint "$FAKE_HOME")" = "$before" ]
}

@test "gate: only attributable evidence is selectable, and every association is explained" {
  local app="$FAKE_HOME/Applications/Gate2.app"
  create_app "$app" "Gate2" "com.example.gate2" "1.0"
  local L="$FAKE_HOME/Library"
  mkdir -p "$L/Containers/com.example.gate2" "$L/Caches/Gate2" "$L/Group Containers/group.com.example.gate2" \
           "$L/Application Support/Gate2" "$L/Logs/com.example.gate2"
  touch "$L/Preferences/com.example.gate2.plist"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  echo "$output" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["remnants"], "fixture produced no evidence"
for r in d["remnants"]:
    assert r["reason"].strip(), r
    assert r["selectable"] == (r["class"] == "attributable"), r
    if r["confidence"] in ("weak", "shared", "conflicting") or r["is_system_location"]:
        assert not r["selectable"], r
    assert r["class"] == {"authoritative": "attributable", "strong": "attributable",
        "corroborated": "attributable", "weak": "review"}.get(r["confidence"], "retained") \
        or r["is_system_location"], r
s = d["summary"]
assert s["attributable_count"] + s["review_count"] + s["retained_count"] == len(d["remnants"])
'
}

# Minimal draft-07 subset checker (type, const, enum, required,
# additionalProperties:false, properties, items, $ref, oneOf) — the system
# Python has no jsonschema module, and the subset is all these schemas use.
schema_check() {
  /usr/bin/python3 -c '
import json, sys
schema = json.load(open(sys.argv[1]))
doc = json.load(sys.stdin)
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}
def resolve(s):
    while "$ref" in s:
        node = schema
        for part in s["$ref"].lstrip("#/").split("/"):
            node = node[part]
        s = node
    return s
def ok_type(v, t):
    ts = t if isinstance(t, list) else [t]
    for x in ts:
        if x == "integer" and isinstance(v, int) and not isinstance(v, bool): return True
        if x in TYPES and isinstance(v, TYPES[x]) and not (x != "boolean" and isinstance(v, bool)): return True
    return False
def check(v, s, path):
    s = resolve(s)
    if "oneOf" in s:
        errs = []
        for alt in s["oneOf"]:
            try: check(v, alt, path); return
            except AssertionError as e: errs.append(str(e))
        raise AssertionError("%s: matches no alternative: %s" % (path, errs))
    if "type" in s: assert ok_type(v, s["type"]), "%s: %r is not %s" % (path, v, s["type"])
    if "const" in s: assert v == s["const"], "%s: %r != %r" % (path, v, s["const"])
    if "enum" in s: assert v in s["enum"], "%s: %r not in %r" % (path, v, s["enum"])
    if "minLength" in s: assert len(v) >= s["minLength"], path
    if isinstance(v, dict):
        for k in s.get("required", []): assert k in v, "%s: missing %s" % (path, k)
        props = s.get("properties", {})
        if s.get("additionalProperties") is False:
            extra = set(v) - set(props)
            assert not extra, "%s: unexpected %s" % (path, sorted(extra))
        for k, sub in props.items():
            if k in v: check(v[k], sub, path + "." + k)
    if isinstance(v, list) and "items" in s:
        for i, x in enumerate(v): check(x, s["items"], "%s[%d]" % (path, i))
check(doc, schema, "$")
' "$1"
}

@test "schema: apps list, inspect, and inspect errors conform to their JSON Schemas" {
  local app="$FAKE_HOME/Applications/Schematic.app"
  create_app "$app" "Schematic" "com.example.schematic" "1.0"
  mkdir -p "$app/Contents/_MASReceipt" "$FAKE_HOME/Caskroom/schematic/1.0" \
           "$FAKE_HOME/Library/Caches/Schematic" "$FAKE_HOME/Library/Group Containers/group.com.example.schematic"
  touch "$app/Contents/_MASReceipt/receipt" "$FAKE_HOME/Library/Preferences/com.example.schematic.plist"
  export MIMI_APP_SEARCH_ROOTS="$FAKE_HOME/Applications:$TEST_TMPDIR/not-mounted"

  run /bin/bash "$MIMI_BIN" apps list --json
  [ "$status" -eq 0 ]
  echo "$output" | schema_check "$REPO_ROOT/schemas/apps-list-v1.json"

  run /bin/bash "$MIMI_BIN" app inspect "Schematic" --json
  [ "$status" -eq 0 ]
  echo "$output" | schema_check "$REPO_ROOT/schemas/app-inspect-v1.json"

  run /bin/bash "$MIMI_BIN" app inspect "$app" --json
  [ "$status" -eq 0 ]
  echo "$output" | schema_check "$REPO_ROOT/schemas/app-inspect-v1.json"

  run --separate-stderr /bin/bash "$MIMI_BIN" app inspect "Nope" --json
  [ "$status" -eq 1 ]
  echo "$output" | schema_check "$REPO_ROOT/schemas/app-inspect-v1.json"
}
