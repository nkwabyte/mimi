#!/usr/bin/env bats
#
# tests/spinner.bats — unit tests for the background braille spinner.

load 'test_helper'

source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

@test "spinner: format_spinner_message strips newlines and carriage returns" {
  source_lib
  local msg=$'Line 1\r\nLine 2\n'
  local out
  out="$(format_spinner_message "$msg")"
  [[ "$out" != *$'\n'* ]]
  [[ "$out" != *$'\r'* ]]
  [[ "$out" =~ "Line 1" ]]
  [[ "$out" =~ "Line 2" ]]
}

@test "spinner: format_spinner_message truncates long strings cleanly" {
  source_lib
  local long="This is a very long message that is definitely going to exceed any small column terminal width limitation test"
  local out
  out="$(COLUMNS=30 format_spinner_message "$long")"
  [ "${#out}" -le 22 ]
  [[ "$out" =~ \.\.\.$ ]]
}

@test "spinner: spinner_allowed respects JSONL_ENABLED and NO_SPINNER" {
  source_lib
  (
    JSONL_ENABLED=1
    ! spinner_allowed
  )
  (
    NO_SPINNER=1
    ! spinner_allowed
  )
}

@test "spinner: non-TTY mode does not spawn background process" {
  source_lib
  # In Bats subshell, stderr is a pipe, so start_spinner safely degrades
  start_spinner "Testing non-tty"
  [ -z "$SPINNER_PID" ]
  [ -z "$SPINNER_CONTROL_DIR" ]
}

@test "spinner: lifecycle works when forced on terminal" {
  source_lib
  # Force spinner_is_tty to return 0 for test
  spinner_is_tty() { return 0; }
  spinner_allowed() { return 0; }

  start_spinner "Testing active spinner"
  [ -n "$SPINNER_PID" ]
  [ -n "$SPINNER_CONTROL_DIR" ]
  [ -d "$SPINNER_CONTROL_DIR" ]
  [ -f "$SPINNER_MSG_FILE" ]

  # Check that process is alive
  kill -0 "$SPINNER_PID" 2>/dev/null

  # Update message
  update_spinner_message "Updated message text"
  grep -q "Updated message text" "$SPINNER_MSG_FILE"

  # Stop spinner
  local saved_pid="$SPINNER_PID"
  local saved_dir="$SPINNER_CONTROL_DIR"
  stop_spinner

  [ -z "$SPINNER_PID" ]
  [ -z "$SPINNER_CONTROL_DIR" ]
  # Background subshell must be terminated
  ! kill -0 "$saved_pid" 2>/dev/null
  # Temp control dir must be deleted
  [ ! -d "$saved_dir" ]
}

@test "spinner: update_spinner_message returns 1 when no spinner running" {
  source_lib
  stop_spinner
  run update_spinner_message "Should fail"
  [ "$status" -eq 1 ]
}

@test "spinner: _cleanup_on_exit stops running spinner" {
  source_lib
  spinner_is_tty() { return 0; }
  spinner_allowed() { return 0; }

  start_spinner "Will be stopped by exit"
  local pid="$SPINNER_PID"
  [ -n "$pid" ]
  kill -0 "$pid" 2>/dev/null

  _cleanup_on_exit
  [ -z "$SPINNER_PID" ]
  ! kill -0 "$pid" 2>/dev/null
}

@test "spinner: say stops running spinner before printing" {
  source_lib
  spinner_is_tty() { return 0; }
  spinner_allowed() { return 0; }

  start_spinner "Active before say"
  [ -n "$SPINNER_PID" ]

  say "A permanent message"
  [ -z "$SPINNER_PID" ]
}
