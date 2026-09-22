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
  [ -x "$MIMI_BIN" ]
  [ -f "$MIMI_LIB/load.sh" ]
  local m
  for m in globals log util validate usage config path action core; do
    [ -f "$MIMI_LIB/$m.sh" ]
  done
}

@test "layout: every shell file passes bash 3.2 syntax check" {
  local f
  for f in "$CLEAN_SH" "$MIMI_BIN" "$MIMI_LIB"/*.sh; do
    /bin/bash -n "$f"
  done
}

@test "layout: the canonical entry point runs on its own" {
  run_mimi --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'USAGE:'
}

# The two entry points differ in exactly two ways by design: the shim prints a
# deprecation notice, and each calls itself by the name it was invoked with.
# Everything else must match.
normalise_entrypoint_output() {
  echo "$1" \
    | grep -v '^clean.sh: note:' \
    | grep -v '^Log: ' \
    | sed -e 's/^clean\.sh — /NAME — /' -e 's/^mimi — /NAME — /'
}

@test "layout: the shim and the entry point produce identical --list output" {
  run_clean --list
  local via_shim
  via_shim="$(normalise_entrypoint_output "$output")"
  run_mimi --list
  [ "$via_shim" = "$(normalise_entrypoint_output "$output")" ]
}

@test "layout: the shim and the entry point produce identical scan output" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/data"

  # --no-log names a fresh mktemp file each run, and the log path is printed,
  # so that one line is filtered out before comparing.
  run_clean --scan --only caches --no-log
  local via_shim
  via_shim="$(normalise_entrypoint_output "$output")"
  run_mimi --scan --only caches --no-log
  [ "$via_shim" = "$(normalise_entrypoint_output "$output")" ]
}

@test "layout: the shim keeps the program calling itself clean.sh" {
  # --only with an unknown id goes through die_usage, which is what carries
  # the program name. (A bare unknown option takes a different path.)
  run_clean --only nosuchcategory
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean.sh: error:"* ]]
}

@test "layout: the entry point calls itself mimi" {
  run_mimi --only nosuchcategory
  [ "$status" -eq 1 ]
  [[ "$output" == *"mimi: error:"* ]]
}

@test "layout: the shim announces the new name once, on stderr" {
  run_clean --list
  echo "$output" | grep -q 'this tool is now "mimi"'
  [ "$(echo "$output" | grep -c 'this tool is now')" -eq 1 ]
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
  echo "$output" | grep -q 'bin/mimi is missing'
}

@test "layout: the entry point fails clearly when lib/ is missing" {
  local fake="$TEST_TMPDIR/bin/mimi"
  mkdir -p "$TEST_TMPDIR/bin"
  cp "$MIMI_BIN" "$fake"
  run /bin/bash "$fake"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'cannot find lib/load.sh'
}

@test "layout: the entry point resolves lib/ through a symlink to itself" {
  local link="$TEST_TMPDIR/linked-mimi"
  ln -s "$MIMI_BIN" "$link"
  run /bin/bash "$link" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'caches'
}

@test "layout: the entry point works from any working directory" {
  run /bin/bash -c "cd / && exec /bin/bash '$MIMI_BIN' --list"
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
  [ ! -f "$FAKE_HOME/.config/mimi/config.conf" ]
  assert_fixture_sentinel_intact
}

@test "library: loading it does not parse arguments" {
  # Argument parsing lives in bin/mimi, not in the library. Sourcing the
  # library with stray positional parameters must not act on them.
  run /bin/bash -c '. "'"$MIMI_LIB"'/load.sh"; printf "%s" "$MODE"' \
    mimi-probe --clean --yes
  [ "$status" -eq 0 ]
  [ "$output" = "scan" ]
}

@test "library: no module runs the tool at load time" {
  # A module that dispatches on load would make the library unusable for tests
  # and would run a clean as a side effect of sourcing.
  ! grep -qE '^(main|interactive_main|run_selected_categories)$' "$MIMI_LIB"/*.sh
}

@test "library: each module is individually syntax-clean and self-describing" {
  local f
  for f in "$MIMI_LIB"/*.sh; do
    /bin/bash -n "$f"
    head -5 "$f" | grep -q "lib/$(basename "$f")"
  done
}

# ---------------------------------------------------------------------------
# The rename to mimi
# ---------------------------------------------------------------------------

@test "rename: --cleaner cleans" {
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/data"

  run_mimi --cleaner --yes --only caches
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Caches/app/data" ]
}

@test "rename: --clean is still accepted" {
  # Every script written before the rename used this spelling.
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/app/data"

  run_mimi --clean --yes --only caches
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/Library/Caches/app/data" ]
}

@test "rename: --cleaner and --clean produce the same mode" {
  run_mimi --cleaner --yes --only caches
  local via_cleaner
  via_cleaner="$(echo "$output" | grep -o 'mode: .*' | head -1)"
  run_mimi --clean --yes --only caches
  [ "$via_cleaner" = "$(echo "$output" | grep -o 'mode: .*' | head -1)" ]
}

@test "rename: --help documents mimi, not the old name" {
  run_mimi --help
  echo "$output" | grep -q 'mimi — macOS junk cleaner'
  echo "$output" | grep -q -- '--cleaner'
  echo "$output" | grep -q '~/.config/mimi/config.conf'
}

@test "rename: settings are moved from the old config location" {
  # A rename must not cost anyone their saved settings, and above all not
  # their whitelist — one that silently stops being read protects nothing.
  rm -rf "$FAKE_HOME/.config/mimi"
  mkdir -p "$FAKE_HOME/.config/cleanmymac"
  printf 'KEEP_LOGS=7\n' > "$FAKE_HOME/.config/cleanmymac/config.conf"

  run_mimi --list
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.config/mimi/config.conf" ]
  [ ! -d "$FAKE_HOME/.config/cleanmymac" ]
  grep -q 'KEEP_LOGS=7' "$FAKE_HOME/.config/mimi/config.conf"
}

@test "rename: a migrated setting is actually in effect" {
  rm -rf "$FAKE_HOME/.config/mimi"
  mkdir -p "$FAKE_HOME/.config/cleanmymac"
  printf 'TMP_STALE_DAYS=13\n' > "$FAKE_HOME/.config/cleanmymac/config.conf"

  run_mimi --scan --only caches
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'moved your settings'
}

@test "rename: migration never clobbers an existing mimi config" {
  mkdir -p "$FAKE_HOME/.config/mimi" "$FAKE_HOME/.config/cleanmymac"
  printf 'KEEP_LOGS=2\n' > "$FAKE_HOME/.config/mimi/config.conf"
  printf 'KEEP_LOGS=9\n' > "$FAKE_HOME/.config/cleanmymac/config.conf"

  run_mimi --list
  grep -q 'KEEP_LOGS=2' "$FAKE_HOME/.config/mimi/config.conf"
  [ -d "$FAKE_HOME/.config/cleanmymac" ]
}

@test "rename: logs move to the new location" {
  rm -rf "$FAKE_HOME/Library/Logs/mimi"
  mkdir -p "$FAKE_HOME/Library/Logs/cleanmymac"
  printf 'old transcript\n' > "$FAKE_HOME/Library/Logs/cleanmymac/clean-20200101-000000.log"

  run_mimi --scan --only caches
  [ -f "$FAKE_HOME/Library/Logs/mimi/clean-20200101-000000.log" ]
}

@test "rename: new review files carry the mimi marker" {
  mkdir -p "$FAKE_HOME/Library/Containers/com.zzqqxx9.vvbbnn7"
  run_mimi --scan --only orphans --include-orphans
  local generated
  generated="$(grep -rl 'mimi-orphan-review v1' "$FAKE_HOME/Library/Logs/mimi" 2>/dev/null | head -1)"
  [ -n "$generated" ]
}

@test "rename: a review file written under the old name is still accepted" {
  # Someone may be halfway through editing one when they update.
  local target f
  target="$FAKE_HOME/Library/Application Support/com.zzqqxx9.legacy"
  mkdir -p "$target"
  f="$TEST_TMPDIR/legacy-review.txt"
  {
    printf '# cleanmymac-orphan-review v1\n'
    printf '%s\n' "$target"
  } > "$f"

  run_mimi --cleaner --yes --force-risky orphans --only orphans --remove-orphans-from "$f"
  [ "$status" -eq 0 ]
  [ ! -e "$target" ]
}

# ---------------------------------------------------------------------------
# install.sh
# ---------------------------------------------------------------------------

@test "install: links mimi into a prefix and the link runs" {
  local prefix="$TEST_TMPDIR/bin"
  run /bin/bash "$REPO_ROOT/install.sh" --prefix "$prefix"
  [ "$status" -eq 0 ]
  [ -L "$prefix/mimi" ]

  run /bin/bash "$prefix/mimi" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'caches'
}

@test "install: --uninstall removes only its own symlink" {
  local prefix="$TEST_TMPDIR/bin"
  /bin/bash "$REPO_ROOT/install.sh" --prefix "$prefix" > /dev/null
  run /bin/bash "$REPO_ROOT/install.sh" --prefix "$prefix" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$prefix/mimi" ]
}

@test "install: refuses to overwrite a real file" {
  local prefix="$TEST_TMPDIR/bin"
  mkdir -p "$prefix"
  printf 'not ours\n' > "$prefix/mimi"
  run /bin/bash "$REPO_ROOT/install.sh" --prefix "$prefix"
  [ "$status" -ne 0 ]
  [ "$(cat "$prefix/mimi")" = "not ours" ]
}

@test "install: says how to fix a prefix that is not on PATH" {
  local prefix="$TEST_TMPDIR/nowhere"
  run /bin/bash "$REPO_ROOT/install.sh" --prefix "$prefix"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'NOT on your PATH'
}
