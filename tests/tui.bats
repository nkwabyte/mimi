#!/usr/bin/env bats
#
# tui.bats — key handling of the interactive screens, driven through the
# MIMI_TUI_INPUT test seam (a file of keystrokes read instead of /dev/tty).

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

# keys STRING — write the keystrokes (printf escapes allowed) for the screen.
keys() {
  printf "$1" > "$TEST_TMPDIR/keys"
  export MIMI_TUI_INPUT="$TEST_TMPDIR/keys"
}

DOWN=$'\033[B'
UP=$'\033[A'

@test "picker: space toggles, j moves, x clears all, q leaves" {
  source_lib
  build_category_state
  keys 'x jj q'
  interactive_choose_categories > /dev/null 2>&1
  local i on=""
  for i in "${!CATEGORY_STATE_ON[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = 1 ] && on="$on $i"
  done
  [ "$on" = " 0 2" ]
}

@test "picker: arrow keys move the cursor" {
  source_lib
  build_category_state
  keys "x${DOWN}${DOWN}${DOWN}${UP} q"
  interactive_choose_categories > /dev/null 2>&1
  [ "${CATEGORY_STATE_ON[2]}" = 1 ]
  [ "${CATEGORY_STATE_ON[0]}" = 0 ]
}

@test "picker: a selects every category" {
  source_lib
  build_category_state
  keys 'xaq'
  interactive_choose_categories > /dev/null 2>&1
  local i
  for i in "${!CATEGORY_STATE_ON[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = 1 ]
  done
}

@test "picker: c cleans exactly the selection, without questions" {
  source_lib
  build_category_state
  run_selected_categories() {
    printf '%s|%s|%s\n' "$MODE" "$ONLY_LIST" "$ASSUME_YES" > "$TEST_TMPDIR/ran"
  }
  keys 'x c\nq'
  interactive_choose_categories > /dev/null 2>&1
  [ "$(cat "$TEST_TMPDIR/ran")" = "clean|${CATEGORY_STATE_IDS[0]}|1" ]
  [ "$ASSUME_YES" = 0 ]
}

@test "picker: c with nothing selected runs nothing" {
  source_lib
  build_category_state
  run_selected_categories() { : > "$TEST_TMPDIR/ran"; }
  keys 'xc\nq'
  interactive_choose_categories > "$TEST_TMPDIR/out" 2>&1
  [ ! -e "$TEST_TMPDIR/ran" ]
  grep -q "nothing selected" "$TEST_TMPDIR/out"
}

@test "picker: enter scans the selection" {
  source_lib
  build_category_state
  run_selected_categories() { printf '%s\n' "$MODE" > "$TEST_TMPDIR/ran"; }
  keys 'x \n\nq'
  interactive_choose_categories > /dev/null 2>&1
  [ "$(cat "$TEST_TMPDIR/ran")" = "scan" ]
}

@test "menu: j j enter selects the third item; a digit jumps straight to one" {
  source_lib
  MENU_LABELS=("one" "two" "three")
  keys 'jj\n'
  menu_select "Test" 0 > /dev/null 2>&1
  [ "$MENU_CHOICE" = 2 ]

  # A new key file needs the seam reopened.
  keys '2'
  _TUI_INPUT_OPEN=0
  menu_select "Test" 0 > /dev/null 2>&1
  [ "$MENU_CHOICE" = 1 ]
}

@test "menu: q returns no choice" {
  source_lib
  MENU_LABELS=("one" "two")
  keys 'q'
  ! menu_select "Test" 0 > /dev/null 2>&1
  [ "$MENU_CHOICE" = -1 ]
}

@test "settings: space toggles a switch, l and h adjust a number" {
  source_lib
  VERBOSE=0
  KEEP_DEVICE_SUPPORT=3
  # Row 0 is keep-device-support: l l l h -> 3+1+1+1-1 = 5. Two ups from row 0
  # wrap to the second-to-last row, verbose, where space toggles it on.
  keys "lllh${UP}${UP} q"
  interactive_settings > /dev/null 2>&1
  [ "$KEEP_DEVICE_SUPPORT" = 5 ]
  [ "$VERBOSE" = 1 ]
}

@test "whitelist: d removes the highlighted entry, a adds one" {
  source_lib
  WHITELIST=("alpha" "beta" "gamma")
  keys 'jda~/Keep/This\nq'
  interactive_whitelist > /dev/null 2>&1
  [ "${WHITELIST[*]}" = "alpha gamma ~/Keep/This" ]
}

@test "seam: end of input leaves the screen instead of hanging" {
  source_lib
  build_category_state
  keys ' '
  run interactive_choose_categories
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# App picker (`mimi uninstall`). The inventory and the uninstall itself are
# stubbed: these tests are about the screen, not about removing files.
# ---------------------------------------------------------------------------

# Three apps plus one system app, which the picker must not list.
fake_inventory() {
  inventory_scan_apps() {
    APP_INV_NAMES=("Alpha" "Beta" "Safari" "Gamma")
    APP_INV_PATHS=("/Applications/Alpha.app" "/Applications/Beta.app" "/Applications/Safari.app" "$HOME/Applications/Gamma.app")
    APP_INV_SOURCES=("app" "cask" "system" "app")
    APP_INV_SYSTEM=(0 0 1 0)
    APP_INV_ELIGIBLE=(1 1 0 1)
    APP_INV_COUNT=4
  }
  mimi_app_uninstall() {
    printf '%s|%s|%s\n' "$APP_TARGET" "$UNINSTALL_DATA_MODE" "$FORCE_RISKY_LIST" >> "$TEST_TMPDIR/uninstalled"
  }
}

@test "apps picker: system apps are not listed, and rows use circles" {
  source_lib
  fake_inventory
  keys ' q'
  interactive_uninstall_apps command > "$TEST_TMPDIR/out" 2>&1
  ! grep -q "Safari" "$TEST_TMPDIR/out"
  grep -q "Alpha" "$TEST_TMPDIR/out"
  grep -q "Gamma" "$TEST_TMPDIR/out"
  grep -q "●" "$TEST_TMPDIR/out"
  grep -q "○" "$TEST_TMPDIR/out"
  [ ! -e "$TEST_TMPDIR/uninstalled" ]
}

@test "apps picker: space selects, enter and the typed word uninstall exactly the selection" {
  source_lib
  fake_inventory
  # Select Alpha, skip Beta, select Gamma, then enter and confirm.
  keys ' jj \nuninstall\n'
  run interactive_uninstall_apps command
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/uninstalled")" = "/Applications/Alpha.app|purge|uninstall
$HOME/Applications/Gamma.app|purge|uninstall" ]
}

@test "apps picker: anything but the typed word deletes nothing" {
  source_lib
  fake_inventory
  keys ' \nyes\n'
  run interactive_uninstall_apps command
  [ "$status" -eq 5 ]
  [ ! -e "$TEST_TMPDIR/uninstalled" ]
  echo "$output" | grep -q "Nothing was deleted"
}

@test "apps picker: enter with nothing selected stays on the list" {
  source_lib
  fake_inventory
  keys '\nq'
  run interactive_uninstall_apps command
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/uninstalled" ]
  echo "$output" | grep -q "Nothing selected"
}

@test "apps picker: a selects all, x clears, and --keep-data is honoured" {
  source_lib
  fake_inventory
  UNINSTALL_DATA_MODE=keep
  keys 'axa\nuninstall\n'
  run interactive_uninstall_apps command
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_TMPDIR/uninstalled" | tr -d ' ')" = 3 ]
  ! grep -q "Safari" "$TEST_TMPDIR/uninstalled"
  ! grep -qv "|keep|" "$TEST_TMPDIR/uninstalled"
}

@test "mimi uninstall: without a terminal it asks for a target instead of listing" {
  run /bin/bash "$MIMI_BIN" uninstall < /dev/null
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "mimi uninstall' in a terminal"
}
