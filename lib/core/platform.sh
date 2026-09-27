#!/usr/bin/env bash
#
# lib/core/platform.sh — the few file and date queries whose flags differ
# between macOS (BSD) and GNU tools.
#
# mimi runs on macOS; the GNU branch exists so the test suite can also run on
# Linux CI. Every caller goes through these instead of calling `stat -f` or
# `date -r` directly. None of them follows a symlink: they describe the link
# itself, like `stat` without -L.

if stat --version > /dev/null 2>&1; then
  _MIMI_GNU_STAT=1
else
  _MIMI_GNU_STAT=0
fi
if date --version > /dev/null 2>&1; then
  _MIMI_GNU_DATE=1
else
  _MIMI_GNU_DATE=0
fi

# _file_stat BSD_FORMAT GNU_FORMAT PATH...
_file_stat() {
  local bsd="$1" gnu="$2"
  shift 2
  if [ "$_MIMI_GNU_STAT" = 1 ]; then
    stat -c "$gnu" "$@"
  else
    stat -f "$bsd" "$@"
  fi
}

file_identity() { _file_stat '%d:%i' '%d:%i' "$1"; }  # device:inode
file_device()   { _file_stat '%d' '%d' "$1"; }
file_uid()      { _file_stat '%u' '%u' "$1"; }
file_mode()     { _file_stat '%Lp' '%a' "$1"; }         # permission bits, octal
file_mtime()    { _file_stat '%m' '%Y' "$1"; }          # epoch seconds
file_size()     { _file_stat '%z' '%s' "$1"; }          # bytes

# BSD file flags (uchg, restricted, ...). GNU has none: print "-" like an
# unflagged file on macOS, and fail only when the path does not exist.
file_flags() {
  if [ "$_MIMI_GNU_STAT" = 1 ]; then
    [ -e "$1" ] || [ -L "$1" ] || return 1
    printf -- '-\n'
  else
    stat -f '%Sf' "$1"
  fi
}

# Print "<mtime> <path>" for every path given, one per line.
files_by_mtime() { _file_stat '%m %N' '%Y %n' "$@"; }

# file_date PATH FORMAT — a file's modification time, formatted.
file_date() {
  local m
  m="$(file_mtime "$1")" || return 1
  epoch_format "$m" "$2"
}

# epoch_format EPOCH FORMAT [-u] — format epoch seconds, in local time or,
# with -u, in UTC.
epoch_format() {
  if [ "$_MIMI_GNU_DATE" = 1 ]; then
    date ${3:+"$3"} -d "@$1" "$2"
  else
    date ${3:+"$3"} -r "$1" "$2"
  fi
}

# date_to_epoch "YYYY-MM-DD HH:MM:SS +ZZZZ" — the form mdls prints.
date_to_epoch() {
  if [ "$_MIMI_GNU_DATE" = 1 ]; then
    date -d "$1" +%s
  else
    date -j -f '%Y-%m-%d %H:%M:%S %z' "$1" +%s
  fi
}
