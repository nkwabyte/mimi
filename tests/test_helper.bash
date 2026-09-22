#!/usr/bin/env bash
#
# test_helper.bash — shared harness for the mimi bats tests
#
# Sourced by every .bats file via:
#   load 'test_helper'
#
# What this does
# --------------
# 1. Creates a completely isolated fake-home directory under $BATS_TMPDIR
#    for each test. HOME, TMPDIR, and all mimi library paths are
#    redirected there so no test can touch the real home.
# 2. Plants sentinel files *above* and *beside* the fixture root. Teardown
#    fails the test if any sentinel is missing or modified.
# 3. Prepends tests/mocks/bin to PATH so macOS tools (mdfind, xcrun,
#    qlmanage, brew, npm, docker, mdls, defaults) are intercepted by stubs.
# 4. Provides helper functions used across test files.
#
# Bash 3.2 compatibility: no associative arrays, no process substitution
# features beyond what 3.2 supports.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Absolute path to the repository root (two levels up from this file).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# The documented entry point: the root shim. run_clean drives this rather than
# bin/mimi directly, so the compatibility path is what the whole suite
# exercises — including the program calling itself "clean.sh" in its messages.
CLEAN_SH="$REPO_ROOT/clean.sh"
# The canonical entry point and the library, for the tests that address them.
MIMI_BIN="$REPO_ROOT/bin/mimi"
MIMI_LIB="$REPO_ROOT/lib"
MOCKS_BIN="$REPO_ROOT/tests/mocks/bin"

# ---------------------------------------------------------------------------
# Per-test setup — called automatically by bats before each test
# ---------------------------------------------------------------------------

setup() {
  # Create a fresh disposable root for this test. bats sets BATS_TMPDIR.
  TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mimi-test-XXXXXX")"

  # Sentinel files planted *outside* the fixture root.
  # Teardown asserts these are untouched.
  SENTINEL_PARENT="${TEST_TMPDIR%/*}/.sentinel-parent-$$"
  SENTINEL_SIBLING="${TEST_TMPDIR%/*}/.sentinel-sibling-$$"
  printf 'sentinel-parent\n'  > "$SENTINEL_PARENT"
  printf 'sentinel-sibling\n' > "$SENTINEL_SIBLING"
  SENTINEL_PARENT_HASH="$(cksum "$SENTINEL_PARENT" | awk '{print $1}')"
  SENTINEL_SIBLING_HASH="$(cksum "$SENTINEL_SIBLING" | awk '{print $1}')"

  # Build a fake home directory tree that mirrors what mimi expects.
  FAKE_HOME="$TEST_TMPDIR/home"
  mkdir -p \
    "$FAKE_HOME/Library/Caches" \
    "$FAKE_HOME/Library/Logs" \
    "$FAKE_HOME/Library/Preferences" \
    "$FAKE_HOME/Library/Application Support" \
    "$FAKE_HOME/Library/Containers" \
    "$FAKE_HOME/Library/Saved Application State" \
    "$FAKE_HOME/Library/WebKit" \
    "$FAKE_HOME/Library/HTTPStorages" \
    "$FAKE_HOME/Library/Cookies" \
    "$FAKE_HOME/Library/Developer/Xcode/DerivedData" \
    "$FAKE_HOME/Library/Developer/CoreSimulator/Caches" \
    "$FAKE_HOME/Library/Developer/CoreSimulator/Devices" \
    "$FAKE_HOME/.config/mimi" \
    "$FAKE_HOME/.Trash"

  # Sentinel *inside* the fixture — must still be present after a scan.
  SENTINEL_FIXTURE="$FAKE_HOME/.sentinel-fixture-$$"
  printf 'sentinel-fixture\n' > "$SENTINEL_FIXTURE"

  # Override HOME so mimi writes only inside the fixture.
  export HOME="$FAKE_HOME"
  # Override TMPDIR so any tmp-category work stays sandboxed.
  export TMPDIR="$TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"

  # Prepend mock stubs so real macOS tools are never called.
  export PATH="$MOCKS_BIN:$PATH"

  # Silence interactive-mode auto-detection: tests always run non-interactively.
  # mimi checks [ -t 0 ] && [ -t 1 ]; stdin/stdout are not a tty in bats.
}

# ---------------------------------------------------------------------------
# Per-test teardown — called automatically by bats after each test
# ---------------------------------------------------------------------------

# Checks every sentinel planted outside the fixture. Returns 0 when all are
# byte-identical to what setup() wrote, non-zero (with a message on stdout)
# when any was deleted or modified.
#
# This is a named function rather than inline teardown code specifically so a
# test can tamper with a sentinel and assert that detection fires. A guard
# that is never exercised is not a guard.
verify_sentinels() {
  local failed=0 hash

  if [ ! -f "$SENTINEL_PARENT" ]; then
    echo "ESCAPE DETECTED: parent sentinel was deleted: $SENTINEL_PARENT"
    failed=1
  else
    hash="$(cksum "$SENTINEL_PARENT" | awk '{print $1}')"
    if [ "$hash" != "$SENTINEL_PARENT_HASH" ]; then
      echo "ESCAPE DETECTED: parent sentinel was modified: $SENTINEL_PARENT"
      failed=1
    fi
  fi

  if [ ! -f "$SENTINEL_SIBLING" ]; then
    echo "ESCAPE DETECTED: sibling sentinel was deleted: $SENTINEL_SIBLING"
    failed=1
  else
    hash="$(cksum "$SENTINEL_SIBLING" | awk '{print $1}')"
    if [ "$hash" != "$SENTINEL_SIBLING_HASH" ]; then
      echo "ESCAPE DETECTED: sibling sentinel was modified: $SENTINEL_SIBLING"
      failed=1
    fi
  fi

  [ "$failed" = 1 ] && return 1
  return 0
}

# Restore both outside-sentinels to their original contents. Used by the
# escape-detection test so that deliberately tampering with one does not then
# fail its own teardown.
restore_sentinels() {
  printf 'sentinel-parent\n'  > "$SENTINEL_PARENT"
  printf 'sentinel-sibling\n' > "$SENTINEL_SIBLING"
}

teardown() {
  local failed=0 output

  output="$(verify_sentinels)" || failed=1
  [ -n "$output" ] && echo "$output" >&2

  rm -f "$SENTINEL_PARENT" "$SENTINEL_SIBLING"
  rm -rf "$TEST_TMPDIR"

  if [ "$failed" = 1 ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helpers available to all test files
# ---------------------------------------------------------------------------

# Run the tool through the documented ./clean.sh entry point, with the fake
# home already in the environment. /bin/bash is explicit so a newer Homebrew
# bash on PATH cannot mask a 3.2 incompatibility — which is also why the shim
# sources bin/mimi instead of exec'ing it.
# Usage: run_clean [args...]
run_clean() {
  run /bin/bash "$CLEAN_SH" "$@"
}

# Run the canonical entry point directly, bypassing the shim.
run_mimi() {
  run /bin/bash "$MIMI_BIN" "$@"
}

# Load the function library into the current shell so a helper can be called
# directly. Replaces the MIMI_LIB_ONLY hook the single-file layout needed.
load_lib() {
  # shellcheck source=/dev/null
  . "$MIMI_LIB/load.sh"
}

# Assert that a fixture path still exists (scan must not delete it).
assert_fixture_exists() {
  local p="$1"
  if [ ! -e "$p" ]; then
    echo "FIXTURE DESTROYED: $p" >&2
    return 1
  fi
  return 0
}

# Assert the fixture-sentinel inside HOME is still present.
assert_fixture_sentinel_intact() {
  assert_fixture_exists "$SENTINEL_FIXTURE"
}

# Write a minimal config file to $FAKE_HOME/.config/mimi/config.conf
write_config() {
  cat > "$FAKE_HOME/.config/mimi/config.conf" <<EOF
$*
EOF
}
