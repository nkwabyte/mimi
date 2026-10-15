#!/usr/bin/env bats
#
# installer.bats — Tests for Leftover Installer Discovery & Selective Cleanup Engine (Phase 10)
#

load 'test_helper'

@test "installer: discovers .dmg, .pkg, .iso, and .xip packages in Downloads" {
  local dl="$FAKE_HOME/Downloads"
  mkdir -p "$dl"
  head -c 4096 /dev/zero > "$dl/TestApp.dmg"
  head -c 2048 /dev/zero > "$dl/Installer.pkg"
  head -c 1024 /dev/zero > "$dl/Image.iso"
  head -c 1024 /dev/zero > "$dl/XcodeArchive.xip"

  run "$MIMI_BIN" installer --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Packages Found:"* ]]
  [[ "$output" == *"4 file(s)"* ]]
  [[ "$output" == *"TestApp.dmg"* ]]
  [[ "$output" == *"Installer.pkg"* ]]
  [[ "$output" == *"Image.iso"* ]]
  [[ "$output" == *"XcodeArchive.xip"* ]]
}

@test "installer: ignores partial downloads (.crdownload, .download, .part)" {
  local dl="$FAKE_HOME/Downloads"
  mkdir -p "$dl"
  # Incomplete file with active .crdownload sibling
  touch "$dl/incomplete.dmg"
  touch "$dl/incomplete.dmg.crdownload"
  # Active download extension directly
  touch "$dl/browser.pkg.download"
  touch "$dl/torrent.iso.part"

  run "$MIMI_BIN" installer --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftover installer packages found"* ]]
}

@test "installer: detects installer zip archive containing an app while ignoring normal zips" {
  local dl="$FAKE_HOME/Downloads"
  local tmp_app="$TEST_TMPDIR/AppBundle/Sample.app/Contents"
  local tmp_txt="$TEST_TMPDIR/TxtBundle"
  mkdir -p "$dl" "$tmp_app" "$tmp_txt"
  echo "dummy" > "$tmp_app/Info.plist"
  echo "hello" > "$tmp_txt/readme.txt"

  (cd "$TEST_TMPDIR/AppBundle" && zip -q -r "$dl/SampleApp.zip" "Sample.app")
  (cd "$tmp_txt" && zip -q -r "$dl/Document.zip" "readme.txt")

  run "$MIMI_BIN" installer --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SampleApp.zip"* ]]
  [[ "$output" != *"Document.zip"* ]]
}

@test "installer: --json emits structured installer findings" {
  local dl="$FAKE_HOME/Downloads"
  mkdir -p "$dl"
  head -c 4096 /dev/zero > "$dl/Tool.dmg"

  run "$MIMI_BIN" installer --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"installer_scan"'* ]]
  [[ "$output" == *'"candidates_count":1'* ]]
  [[ "$output" == *'"name":"Tool.dmg"'* ]]
  [[ "$output" == *'"source":"Downloads"'* ]]
}

@test "installer: --yes cleans discovered packages and verifies removal" {
  local dl="$FAKE_HOME/Downloads"
  mkdir -p "$dl"
  head -c 2048 /dev/zero > "$dl/OldInstaller.dmg"
  head -c 1024 /dev/zero > "$dl/Driver.pkg"

  run "$MIMI_BIN" installer --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed 2 installer package(s)"* ]]
  [ ! -f "$dl/OldInstaller.dmg" ]
  [ ! -f "$dl/Driver.pkg" ]
}

@test "installer: whitelisted installer package is protected from deletion" {
  local dl="$FAKE_HOME/Downloads"
  mkdir -p "$dl"
  head -c 2048 /dev/zero > "$dl/Protected.dmg"
  head -c 1024 /dev/zero > "$dl/Unprotected.pkg"

  run "$MIMI_BIN" installer --whitelist "$dl/Protected.dmg" --yes
  [ "$status" -eq 0 ]
  [ -f "$dl/Protected.dmg" ]
  [ ! -f "$dl/Unprotected.pkg" ]
}

@test "installer: custom target directory scans only specified path" {
  local custom="$FAKE_HOME/CustomDrop"
  local dl="$FAKE_HOME/Downloads"
  mkdir -p "$custom" "$dl"
  touch "$dl/ShouldNotScan.dmg"
  head -c 2048 /dev/zero > "$custom/TargetInstaller.pkg"

  run "$MIMI_BIN" installer "$custom" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"TargetInstaller.pkg"* ]]
  [[ "$output" != *"ShouldNotScan.dmg"* ]]
}
