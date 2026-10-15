#!/usr/bin/env bash
#
# lib/ui/spinner.sh — Background braille loading spinner with atomic IPC updates.
#
# Sourced by lib/load.sh; never executed on its own.
# Provides start_spinner, update_spinner_message, and stop_spinner.
#
# Compatible with macOS /bin/bash 3.2+:
#   - Slices multibyte UTF-8 braille frames safely via indexed arrays.
#   - Uses cooperative file-based IPC to avoid signal races.
#   - Outputs exclusively to stderr so stdout pipes remain clean.
#   - Degrades safely to quiet/static mode when stderr is not a terminal.

SPINNER_PID=""
SPINNER_CONTROL_DIR=""
SPINNER_STOP_FILE=""
SPINNER_MSG_FILE=""

# Format spinner message: strip line breaks and truncate to terminal width.
format_spinner_message() {
  local msg="$1"
  # Replace carriage returns and newlines with spaces
  msg="${msg//$'\r'/ }"
  msg="${msg//$'\n'/ }"

  local cols=""
  if [ -n "${COLUMNS:-}" ]; then
    cols="$COLUMNS"
  elif command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || echo 80)"
  fi
  case "$cols" in
    ''|*[!0-9]*) cols=80 ;;
  esac

  # Reserve 8 columns for prefix, braille frame, and spacing
  local avail=$((cols - 8))
  [ "$avail" -lt 20 ] && avail=20

  if [ "${#msg}" -gt "$avail" ]; then
    if [ "$avail" -gt 3 ]; then
      msg="${msg:0:$((avail - 3))}..."
    else
      msg="${msg:0:$avail}"
    fi
  fi

  printf '%s' "$msg"
}

spinner_is_tty() {
  [ -t 2 ] || [ -t 1 ]
}

spinner_allowed() {
  # Disallow if JSONL output mode is active, or if NO_SPINNER=1
  [ "${JSONL_ENABLED:-0}" = 1 ] && return 1
  [ "${NO_SPINNER:-0}" = 1 ] && return 1
  spinner_is_tty || return 1
  return 0
}

start_spinner() {
  stop_spinner 2>/dev/null || true

  local raw_msg="${1:-Processing...}"
  local display_msg
  display_msg="$(format_spinner_message "$raw_msg")"

  if ! spinner_allowed; then
    # Non-TTY or JSON mode: no background subshell
    return 0
  fi

  local tmp_root="${TMPDIR:-/tmp}"
  [ -d "$tmp_root" ] || tmp_root="/tmp"

  SPINNER_CONTROL_DIR="$(mktemp -d "$tmp_root/.mimi-spinner.XXXXXX" 2>/dev/null)" || return 0
  SPINNER_STOP_FILE="$SPINNER_CONTROL_DIR/stop"
  SPINNER_MSG_FILE="$SPINNER_CONTROL_DIR/message"

  # Initial message file
  if ! printf '%s\n' "$display_msg" > "$SPINNER_MSG_FILE" 2>/dev/null; then
    rmdir "$SPINNER_CONTROL_DIR" 2>/dev/null || true
    SPINNER_CONTROL_DIR=""
    SPINNER_STOP_FILE=""
    SPINNER_MSG_FILE=""
    return 0
  fi

  (
    local stop_f="$SPINNER_STOP_FILE"
    local msg_f="$SPINNER_MSG_FILE"
    # Centered 2x2 braille frames
    local frames=("⠖" "⠲" "⠴" "⠦")
    local count=${#frames[@]}
    local i=0
    local cur_msg="$display_msg"
    local next_msg=""
    local frame_lead="\r\033[2K"

    # Hide cursor on terminal
    printf '\033[?25l' >&2 2>/dev/null || true

    while [ ! -f "$stop_f" ]; do
      local frame="${frames[$((i % count))]}"
      if [ -f "$msg_f" ]; then
        IFS= read -r next_msg < "$msg_f" 2>/dev/null || next_msg=""
        if [ -n "$next_msg" ] && [ "$next_msg" != "$cur_msg" ]; then
          cur_msg="$next_msg"
          frame_lead="\r\033[2K"
        fi
      fi

      # Print spinner frame + cyan color + message
      printf "${frame_lead}${C_CYAN}%s${C_RESET} %s" "$frame" "$cur_msg" >&2 2>/dev/null || break
      frame_lead="\r"
      i=$((i + 1))
      /bin/sleep 0.08 2>/dev/null || sleep 1
    done

    # Clean the line on exit
    printf '\r\033[2K' >&2 2>/dev/null || true
    [ -f "$stop_f" ] && unlink "$stop_f" 2>/dev/null || true
    exit 0
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
  return 0
}

# Update running spinner message in-place without restarting loop.
update_spinner_message() {
  local new_msg="$1"
  [ -n "$SPINNER_PID" ] || return 1
  [ -n "$SPINNER_CONTROL_DIR" ] || return 1
  [ -d "$SPINNER_CONTROL_DIR" ] || return 1

  if ! kill -0 "$SPINNER_PID" 2>/dev/null; then
    SPINNER_PID=""
    return 1
  fi

  local display_msg
  display_msg="$(format_spinner_message "$new_msg")"

  # Write to temp file and atomically move to target message file
  local tmp_f="$SPINNER_CONTROL_DIR/msg.tmp.$$"
  if printf '%s\n' "$display_msg" > "$tmp_f" 2>/dev/null; then
    mv -f "$tmp_f" "$SPINNER_MSG_FILE" 2>/dev/null || { [ -f "$tmp_f" ] && unlink "$tmp_f" 2>/dev/null; } || true
  fi
  return 0
}

stop_spinner() {
  if [ -n "$SPINNER_PID" ]; then
    # Cooperative stop signal via file
    if [ -n "$SPINNER_STOP_FILE" ]; then
      : > "$SPINNER_STOP_FILE" 2>/dev/null || true
    fi

    # Give subshell brief window (up to 250ms) to exit cleanly
    local wait_count=0
    while kill -0 "$SPINNER_PID" 2>/dev/null && [ "$wait_count" -lt 5 ]; do
      /bin/sleep 0.05 2>/dev/null || break
      wait_count=$((wait_count + 1))
    done

    # Force kill if still lingering
    if kill -0 "$SPINNER_PID" 2>/dev/null; then
      kill -KILL "$SPINNER_PID" 2>/dev/null || true
    fi
    wait "$SPINNER_PID" 2>/dev/null || true
  fi

  # Clean up IPC files
  if [ -n "$SPINNER_CONTROL_DIR" ] && [ -d "$SPINNER_CONTROL_DIR" ]; then
    local _f
    for _f in "$SPINNER_STOP_FILE" "$SPINNER_MSG_FILE" "$SPINNER_CONTROL_DIR"/msg.tmp.*; do
      [ -f "$_f" ] && unlink "$_f" 2>/dev/null || true
    done
    rmdir "$SPINNER_CONTROL_DIR" 2>/dev/null || true
  fi

  SPINNER_PID=""
  SPINNER_CONTROL_DIR=""
  SPINNER_STOP_FILE=""
  SPINNER_MSG_FILE=""

  # Clear terminal line and restore cursor
  if spinner_is_tty; then
    printf '\r\033[2K\033[?25h' >&2 2>/dev/null || true
  fi
  return 0
}
