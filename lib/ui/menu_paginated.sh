#!/usr/bin/env bash
#
# lib/ui/menu_paginated.sh — Paginated terminal selector with search and sorting.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#
# Provides alternate-screen navigation (smcup/rmcup), dynamic terminal height
# sensing, real-time '/' search filtering, and multi-criteria sorting (Name, Size).

enter_alt_screen() {
  # Avoid alternate screen if disabled or running under test seam
  [ -t 1 ] || return 0
  [ "${MIMI_NO_ALT_SCREEN:-0}" = 1 ] && return 0
  [ -n "${MIMI_TUI_INPUT:-}" ] && return 0
  tput smcup 2>/dev/null || true
}

leave_alt_screen() {
  [ -t 1 ] || return 0
  [ "${MIMI_NO_ALT_SCREEN:-0}" = 1 ] && return 0
  [ -n "${MIMI_TUI_INPUT:-}" ] && return 0
  tput rmcup 2>/dev/null || true
}

paginated_term_rows() {
  local r
  r="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  case "$r" in ''|*[!0-9]*) r="$(tput lines 2>/dev/null)" ;; esac
  case "$r" in ''|*[!0-9]*) r=24 ;; esac
  [ "$r" -lt 10 ] && r=10
  printf '%s' "$r"
}

paginated_term_cols() {
  local c
  c="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  case "$c" in ''|*[!0-9]*) c="$(tput cols 2>/dev/null)" ;; esac
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 40 ] && c=40
  printf '%s' "$c"
}

# ASCII lowercase conversion compatible with bash 3.2
_paginated_to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Builds APP_VIEW_INDICES based on query and sort mode (name | size)
APP_VIEW_INDICES=()
APP_SEARCH_QUERY=""
APP_SEARCH_MODE=0
APP_SORT_MODE="name"
APP_SORT_REV=0

app_build_view_indices() {
  local query="${1:-}" sort_mode="${2:-name}" reverse="${3:-0}"
  local count="${#APP_INV_PATHS[@]}" i name path size query_lower
  APP_VIEW_INDICES=()
  [ "$count" -gt 0 ] || return 0

  query_lower="$(_paginated_to_lower "$query")"

  local candidates=()
  for i in "${!APP_INV_PATHS[@]}"; do
    name="${APP_INV_NAMES[$i]}"
    path="${APP_INV_PATHS[$i]}"
    if [ -n "$query_lower" ]; then
      local n_lower p_lower
      n_lower="$(_paginated_to_lower "$name")"
      p_lower="$(_paginated_to_lower "$path")"
      case "$n_lower" in
        *"$query_lower"*) candidates+=("$i") ; continue ;;
      esac
      case "$p_lower" in
        *"$query_lower"*) candidates+=("$i") ; continue ;;
      esac
    else
      candidates+=("$i")
    fi
  done

  [ "${#candidates[@]}" -gt 0 ] || return 0

  local sorted
  if [ "$sort_mode" = "size" ]; then
    local sort_flag="-rn"
    [ "$reverse" = 1 ] && sort_flag="-n"
    sorted="$(
      for i in "${candidates[@]}"; do
        size="${APP_INV_SIZES[$i]:-0}"
        printf '%d|%d\n' "$size" "$i"
      done | sort "$sort_flag" -t'|' -k1,1 | cut -d'|' -f2
    )"
  else
    local sort_flag="-f"
    [ "$reverse" = 1 ] && sort_flag="-r -f"
    sorted="$(
      for i in "${candidates[@]}"; do
        name="${APP_INV_NAMES[$i]}"
        printf '%s|%d\n' "$name" "$i"
      done | sort $sort_flag -t'|' -k1,1 | cut -d'|' -f2
    )"
  fi

  while IFS= read -r i; do
    [ -n "$i" ] && APP_VIEW_INDICES+=("$i")
  done <<< "$sorted"
}
