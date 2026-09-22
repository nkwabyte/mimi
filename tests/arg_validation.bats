#!/usr/bin/env bats
#
# arg_validation.bats — P0-T02 characterization + P0-T08 acceptance
#
# Covers the argument/configuration validation contract:
#   * an option that takes a value must reject a missing one with a usage
#     error, never a raw Bash "unbound variable";
#   * retention/staleness options must reject anything that is not a bounded
#     non-negative integer, before the value can reach arithmetic or find(1);
#   * category lists and whitelist presets must reject unknown names instead
#     of silently doing nothing;
#   * configuration values go through the same validation as CLI values;
#   * invalid usage always exits 1 with a stable `clean.sh: error:` prefix.
#
# Depends on: test_helper.bash

load 'test_helper'

# Every option below consumes a following value.
VALUE_OPTIONS="--only --skip --whitelist --whitelist-preset --keep-device-support --sim-stale-days --android-stale-days --tmp-stale-days --keep-toolchains --keep-logs --remove-orphans-from"

# ---------------------------------------------------------------------------
# Missing option values
# ---------------------------------------------------------------------------

@test "missing value: every value-taking option reports a usage error" {
  local opt
  for opt in $VALUE_OPTIONS; do
    run /bin/bash "$CLEAN_SH" --scan --no-log "$opt"
    if [ "$status" -ne 1 ]; then
      echo "option $opt exited $status, expected 1" >&2
      return 1
    fi
    case "$output" in
      *"requires a value"*) ;;
      *) echo "option $opt did not report a missing value: $output" >&2; return 1 ;;
    esac
  done
}

@test "missing value: never leaks a raw Bash unbound-variable error" {
  local opt
  for opt in $VALUE_OPTIONS; do
    run /bin/bash "$CLEAN_SH" --scan --no-log "$opt"
    case "$output" in
      *"unbound variable"*)
        echo "option $opt leaked a Bash error: $output" >&2; return 1 ;;
    esac
  done
}

@test "missing value: a following flag is not swallowed as the value" {
  # --only consuming "--scan" would silently produce a bogus category list.
  run_clean --no-log --only --scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "usage errors carry the stable error prefix" {
  run_clean --no-log --only
  [[ "$output" == *"clean.sh: error:"* ]]
}

# ---------------------------------------------------------------------------
# Numeric validation
# ---------------------------------------------------------------------------

@test "numeric: non-numeric retention value is rejected" {
  run_clean --scan --no-log --keep-device-support abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"whole number"* ]]
}

@test "numeric: negative staleness value is rejected" {
  run_clean --scan --no-log --tmp-stale-days -5
  [ "$status" -eq 1 ]
  [[ "$output" == *"whole number"* ]]
}

@test "numeric: float is rejected" {
  run_clean --scan --no-log --sim-stale-days 1.5
  [ "$status" -eq 1 ]
}

@test "numeric: value with embedded whitespace is rejected" {
  run_clean --scan --no-log --keep-toolchains "1 2"
  [ "$status" -eq 1 ]
}

@test "numeric: absurdly large value is rejected by the upper bound" {
  run_clean --scan --no-log --android-stale-days 99999999
  [ "$status" -eq 1 ]
  [[ "$output" == *"between"* ]]
}

@test "numeric: zero is accepted for --keep-logs" {
  run_clean --scan --no-log --only caches --keep-logs 0
  [ "$status" -eq 0 ]
}

@test "numeric: an ordinary value is accepted" {
  run_clean --scan --no-log --only caches --keep-device-support 2
  [ "$status" -eq 0 ]
}

@test "numeric: the --flag=value form is validated too" {
  run_clean --scan --no-log --keep-device-support=abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"whole number"* ]]
}

# ---------------------------------------------------------------------------
# Category list validation
# ---------------------------------------------------------------------------

@test "categories: unknown --only id is rejected" {
  run_clean --scan --no-log --only nosuchcategory
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown category"* ]]
  [[ "$output" == *"nosuchcategory"* ]]
}

@test "categories: unknown --skip id is rejected" {
  run_clean --scan --no-log --skip nosuchcategory
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown category"* ]]
}

@test "categories: one bad id in an otherwise valid list is rejected" {
  run_clean --scan --no-log --only caches,nosuchcategory,logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"nosuchcategory"* ]]
}

@test "categories: empty --only is rejected" {
  run_clean --scan --no-log --only ""
  [ "$status" -eq 1 ]
}

@test "categories: a list of only commas is rejected" {
  run_clean --scan --no-log --only ",,,"
  [ "$status" -eq 1 ]
}

@test "categories: surrounding whitespace is tolerated" {
  run_clean --scan --no-log --only " caches , logs "
  [ "$status" -eq 0 ]
}

@test "categories: duplicates are normalized away, not an error" {
  run_clean --scan --no-log --only caches,caches,logs
  [ "$status" -eq 0 ]
}

@test "categories: a valid list still runs the right categories" {
  run_clean --scan --no-log --only caches,logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"User caches"* ]]
  [[ "$output" == *"User logs"* ]]
  [[ "$output" != *"QuickLook"* ]]
}

# ---------------------------------------------------------------------------
# Whitelist preset validation
# ---------------------------------------------------------------------------

@test "preset: unknown whitelist preset is rejected" {
  run_clean --scan --no-log --whitelist-preset nosuchpreset
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown whitelist preset"* ]]
}

@test "preset: the error lists every real preset name" {
  run_clean --scan --no-log --whitelist-preset nosuchpreset
  local p
  for p in xcode-simulator xcode-derived node browsers ml; do
    case "$output" in
      *"$p"*) ;;
      *) echo "preset $p missing from error message: $output" >&2; return 1 ;;
    esac
  done
}

@test "preset: every real preset name is accepted" {
  local p
  for p in xcode-simulator xcode-derived node browsers ml; do
    run_clean --scan --no-log --only caches --whitelist-preset "$p"
    if [ "$status" -ne 0 ]; then
      echo "preset $p was rejected: $output" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# --remove-orphans-from
# ---------------------------------------------------------------------------

@test "orphans file: a missing review file is reported, not silently ignored" {
  run_clean --clean --yes --no-log --remove-orphans-from "$FAKE_HOME/nope.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean.sh: error:"* ]]
}

# ---------------------------------------------------------------------------
# Configuration validation — same rules as the CLI
# ---------------------------------------------------------------------------

@test "config: non-numeric value in config is rejected" {
  write_config "KEEP_DEVICE_SUPPORT=abc"
  run_clean --scan --no-log --only caches
  [ "$status" -eq 1 ]
  [[ "$output" == *"whole number"* ]]
}

@test "config: negative value in config is rejected" {
  write_config "TMP_STALE_DAYS=-3"
  run_clean --scan --no-log --only caches
  [ "$status" -eq 1 ]
}

@test "config: unknown category in SELECTED_CATEGORIES is rejected" {
  write_config "SELECTED_CATEGORIES=caches,nosuchcategory"
  run_clean --scan --no-log
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown category"* ]]
}

@test "config: the error names the config file, not a CLI flag" {
  write_config "KEEP_DEVICE_SUPPORT=abc"
  run_clean --scan --no-log --only caches
  [[ "$output" == *"config.conf"* ]]
}

@test "config: a valid config is accepted" {
  write_config "KEEP_DEVICE_SUPPORT=2
TMP_STALE_DAYS=7
SELECTED_CATEGORIES=caches,logs"
  run_clean --scan --no-log
  [ "$status" -eq 0 ]
}

@test "config: CLI value overrides a valid config value" {
  write_config "KEEP_DEVICE_SUPPORT=2"
  run_clean --scan --no-log --only caches --keep-device-support 4
  [ "$status" -eq 0 ]
}

@test "config: whitelist entries from config and CLI are merged" {
  write_config "WHITELIST=$FAKE_HOME/Library/Caches/from-config"
  mkdir -p "$FAKE_HOME/Library/Caches/from-config" \
           "$FAKE_HOME/Library/Caches/from-cli"
  echo x > "$FAKE_HOME/Library/Caches/from-config/f.txt"
  echo x > "$FAKE_HOME/Library/Caches/from-cli/f.txt"

  run_clean --clean --yes --no-log --only caches \
    --whitelist "$FAKE_HOME/Library/Caches/from-cli"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/Library/Caches/from-config/f.txt" ]
  [ -f "$FAKE_HOME/Library/Caches/from-cli/f.txt" ]
}

# ---------------------------------------------------------------------------
# Validation must not fire on the informational paths
# ---------------------------------------------------------------------------

@test "informational: --help still exits 0" {
  run_clean --help
  [ "$status" -eq 0 ]
}

@test "informational: --list still exits 0" {
  run_clean --list
  [ "$status" -eq 0 ]
}

@test "informational: an invalid config does not break --help" {
  # --help must work even when the saved config is unusable, or the user has
  # no way to read the documentation that explains how to fix it.
  write_config "KEEP_DEVICE_SUPPORT=abc"
  run_clean --help
  [ "$status" -eq 0 ]
}
