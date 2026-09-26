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
