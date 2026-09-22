#!/usr/bin/env bats
#
# layout.bats — the bin/ + lib/ split, and the clean.sh compatibility shim.
#
# The rest of the suite drives ./clean.sh, so the shim is exercised everywhere.
# These tests pin the things only this file cares about: that the canonical
# entry point works on its own, that the two agree, that the library is
# loadable in isolation, and that no module does anything at load time except
# define things.

load 'test_helper'

@test "layout: the expected files exist and are executable" {
  [ -x "$CLEAN_SH" ]
  [ -x "$CLEANMYMAC_BIN" ]
  [ -f "$CLEANMYMAC_LIB/load.sh" ]
  local m
  for m in globals log util validate usage config path action core; do
    [ -f "$CLEANMYMAC_LIB/$m.sh" ]
  done
}

@test "layout: every shell file passes bash 3.2 syntax check" {
  local f
  for f in "$CLEAN_SH" "$CLEANMYMAC_BIN" "$CLEANMYMAC_LIB"/*.sh; do
    /bin/bash -n "$f"
  done
}

@test "layout: the canonical entry point runs on its own" {
  run_cleanmymac --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'USAGE:'
}

@test "layout: the shim and the entry point produce identical --list output" {
  run_clean --list
  local via_shim="$output"
  run_cleanmymac --list
  [ "$via_shim" = "$output" ]
}

@test "layout: the shim and the entry point produce identical scan output" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/data"

  # --no-log names a fresh mktemp file each run, and the log path is printed,
  # so that one line is filtered out before comparing.
  run_clean --scan --only caches --no-log
  local via_shim
  via_shim="$(echo "$output" | grep -v '^Log: ')"
  run_cleanmymac --scan --only caches --no-log
  [ "$via_shim" = "$(echo "$output" | grep -v '^Log: ')" ]
}

@test "layout: the shim keeps the program calling itself clean.sh" {
  # --only with an unknown id goes through die_usage, which is what carries
  # the program name. (A bare unknown option takes a different path.)
  run_clean --only nosuchcategory
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean.sh: error:"* ]]
}

@test "layout: the entry point calls itself cleanmymac" {
  run_cleanmymac --only nosuchcategory
  [ "$status" -eq 1 ]
  [[ "$output" == *"cleanmymac: error:"* ]]
}

@test "layout: running under /bin/bash really means bash 3.2" {
  # The suite's 3.2 guarantee depends on the shim sourcing rather than
  # exec'ing: an exec would hand the entry point to whatever `env bash` finds
  # first, which on a dev machine is usually Homebrew's bash 5.
  run /bin/bash -c 'printf "%s" "${BASH_VERSINFO[0]}"' probe
  [ "$output" = "3" ]
  # And the shim does not spawn a different interpreter.
  # A real exec command, not the word in the comment explaining why there is none.
  ! grep -qE '^[[:space:]]*exec ' "$CLEAN_SH"
}

@test "layout: the shim fails clearly when the entry point is missing" {
  local fake="$TEST_TMPDIR/clean.sh"
  cp "$CLEAN_SH" "$fake"
  run /bin/bash "$fake"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'bin/cleanmymac is missing'
}

@test "layout: the entry point fails clearly when lib/ is missing" {
  local fake="$TEST_TMPDIR/bin/cleanmymac"
  mkdir -p "$TEST_TMPDIR/bin"
  cp "$CLEANMYMAC_BIN" "$fake"
  run /bin/bash "$fake"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'cannot find lib/load.sh'
}

@test "layout: the entry point resolves lib/ through a symlink to itself" {
  local link="$TEST_TMPDIR/linked-cleanmymac"
  ln -s "$CLEANMYMAC_BIN" "$link"
  run /bin/bash "$link" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'caches'
}

@test "layout: the entry point works from any working directory" {
  run /bin/bash -c "cd / && exec /bin/bash '$CLEANMYMAC_BIN' --list"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'caches'
}

# ---------------------------------------------------------------------------
# The library is loadable on its own, and inert at load time
# ---------------------------------------------------------------------------

@test "library: load.sh defines the public helpers" {
  load_lib
  local fn
  for fn in path_authorize path_canonicalize fs_remove remove_path \
            clear_dir_contents is_whitelisted validate_orphan_target \
            human_kb dir_size_kb die_usage load_config usage main; do
    declare -f "$fn" > /dev/null || {
      echo "missing after load: $fn" >&2
      return 1
    }
  done
}

@test "library: loading it twice is harmless" {
  load_lib
  load_lib
  declare -f path_authorize > /dev/null
}

@test "library: loading it deletes nothing and writes no config" {
  local before
  before="$(find "$FAKE_HOME" | sort)"
  load_lib
  [ "$before" = "$(find "$FAKE_HOME" | sort)" ]
  [ ! -f "$FAKE_HOME/.config/cleanmymac/config.conf" ]
  assert_fixture_sentinel_intact
}

@test "library: loading it does not parse arguments" {
  # Argument parsing lives in bin/cleanmymac, not in the library. Sourcing the
  # library with stray positional parameters must not act on them.
  run /bin/bash -c '. "'"$CLEANMYMAC_LIB"'/load.sh"; printf "%s" "$MODE"' \
    cleanmymac-probe --clean --yes
  [ "$status" -eq 0 ]
  [ "$output" = "scan" ]
}

@test "library: no module runs the tool at load time" {
  # A module that dispatches on load would make the library unusable for tests
  # and would run a clean as a side effect of sourcing.
  ! grep -qE '^(main|interactive_main|run_selected_categories)$' "$CLEANMYMAC_LIB"/*.sh
}

@test "library: each module is individually syntax-clean and self-describing" {
  local f
  for f in "$CLEANMYMAC_LIB"/*.sh; do
    /bin/bash -n "$f"
    head -5 "$f" | grep -q "lib/$(basename "$f")"
  done
}
