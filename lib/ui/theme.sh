#!/usr/bin/env bash
#
# lib/ui/theme.sh — Terminal design tokens, icons, brand banner, and diagnostics.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#
# Adheres to the NO_COLOR standard (https://no-color.org) and degrades
# gracefully to non-colored ASCII when stdout is not a terminal or TERM=dumb.

# ---------------------------------------------------------------------------
# Color & Style Tokens
# ---------------------------------------------------------------------------

theme_colors_enabled() {
  [ -n "${NO_COLOR:-}" ] && return 1
  [ "${TERM:-}" = "dumb" ] && return 1
  [ -t 1 ] || [ "${MIMI_FORCE_COLOR:-0}" = 1 ] || return 1
  return 0
}

if theme_colors_enabled; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_ITALIC=$'\033[3m'
  C_UNDERLINE=$'\033[4m'

  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_PURPLE=$'\033[35m'
  C_PURPLE_BOLD=$'\033[1;35m'
  C_CYAN=$'\033[36m'
  C_WHITE_BOLD=$'\033[1;37m'
  C_GRAY=$'\033[38;5;244m'
  C_FAINT=$'\033[2m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_ITALIC=""
  C_UNDERLINE=""

  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_PURPLE=""
  C_PURPLE_BOLD=""
  C_CYAN=""
  C_WHITE_BOLD=""
  C_GRAY=""
  C_FAINT=""
fi

render_card_header() {
  local title="${1:-}"
  local border="─────────────────────────────────────────────────────────────────"
  if [ -n "$title" ]; then
    say "${C_CYAN}─── ${C_BOLD}${title}${C_RESET} ${C_CYAN}${border:${#title}+5}${C_RESET}"
  else
    say "${C_CYAN}${border}${C_RESET}"
  fi
}

render_card_footer() {
  say "${C_CYAN}─────────────────────────────────────────────────────────────────${C_RESET}"
}

# ---------------------------------------------------------------------------
# Icon Definitions (UTF-8)
# ---------------------------------------------------------------------------

ICON_CONFIRM="◎"
ICON_ADMIN="⚙"
ICON_SUCCESS="✓"
ICON_ERROR="☻"
ICON_WARNING="◎"
ICON_EMPTY="○"
ICON_SOLID="●"
ICON_BULLET="•"
ICON_SUBLIST="↳"
ICON_ARROW="➤"
ICON_DRY_RUN="→"
ICON_REVIEW="⊙"
ICON_NAV_UP="↑"
ICON_NAV_DOWN="↓"
ICON_INFO="ℹ"
ICON_LOCK="🔒"
ICON_DISK="💾"
ICON_CLEAN="🧹"

# ---------------------------------------------------------------------------
# Brand Identity & Banner
# ---------------------------------------------------------------------------

show_brand_banner() {
  printf '%s\n' "${C_CYAN} __  __ _           _ ${C_RESET}"
  printf '%s\n' "${C_CYAN}|  \/  (_)_ __ ___ (_)${C_RESET}"
  printf '%s\n' "${C_CYAN}| |\/| | | '_ \` _ \| |${C_RESET}  ${C_GRAY}v${MIMI_VERSION}${C_RESET}"
  printf '%s\n' "${C_CYAN}| |  | | | | | | | | |${C_RESET}  ${C_DIM}macOS System Cleaner & Optimizer${C_RESET}"
  printf '%s\n' "${C_CYAN}|_|  |_|_|_| |_| |_|_|${C_RESET}  ${C_CYAN}Apple Silicon & Developer Aware${C_RESET}"
}

get_quick_status_line() {
  local os_prod arch free_info touchid_info=""
  arch="$(uname -m 2>/dev/null || echo "mac")"
  free_info="$(df -H / 2>/dev/null | awk 'NR==2{print $4 " free (" $5 " used)"}' || echo "")"
  if command -v sw_vers > /dev/null 2>&1; then
    os_prod="$(sw_vers -productVersion 2>/dev/null || echo "macOS")"
  else
    os_prod="macOS"
  fi
  if declare -F is_touchid_configured >/dev/null 2>&1; then
    if is_touchid_configured; then
      touchid_info=" • Touch ID: ${C_GREEN}on${C_DIM}"
    else
      touchid_info=" • Touch ID: ${C_YELLOW}off${C_DIM}"
    fi
  fi
  printf '%s' "${C_DIM}macOS $os_prod ($arch) • $free_info • config: $(basename "${CONFIG_FILE:-config}")${touchid_info}${C_RESET}"
}

# ---------------------------------------------------------------------------
# System & Version Diagnostics
# ---------------------------------------------------------------------------

show_version() {
  local os_ver arch kernel sip_status disk_free fda_status
  local os_prod os_build

  if command -v sw_vers > /dev/null 2>&1; then
    os_prod="$(sw_vers -productVersion 2>/dev/null || echo "macOS")"
    os_build="$(sw_vers -buildVersion 2>/dev/null || echo "")"
    if [ -n "$os_build" ]; then
      os_ver="$os_prod ($os_build)"
    else
      os_ver="$os_prod"
    fi
  else
    os_ver="Unknown"
  fi

  arch="$(uname -m 2>/dev/null || echo "Unknown")"
  kernel="$(uname -r 2>/dev/null || echo "Unknown")"

  if command -v csrutil > /dev/null 2>&1; then
    local raw_sip
    raw_sip="$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' || echo 'Unknown')"
    case "$raw_sip" in
      enabled)  sip_status="${C_GREEN}Enabled${C_RESET}" ;;
      disabled) sip_status="${C_YELLOW}Disabled${C_RESET}" ;;
      *)        sip_status="Unknown" ;;
    esac
  else
    sip_status="Unknown"
  fi

  disk_free="$(df -H / 2>/dev/null | awk 'NR==2{print $4}' || echo 'Unknown')"

  check_full_disk_access 2>/dev/null || true
  if [ "${FDA_OK:-0}" = 1 ]; then
    fda_status="${C_GREEN}${ICON_SUCCESS} Granted${C_RESET}"
  else
    fda_status="${C_YELLOW}${ICON_WARNING} Not Granted (limited access to system logs/caches)${C_RESET}"
  fi

  printf '\n'
  printf "${C_BOLD}Mimi version %s${C_RESET}\n" "$MIMI_VERSION"
  printf '  %s %-14s %s\n' "${C_CYAN}${ICON_BULLET}${C_RESET}" "macOS:" "$os_ver"
  printf '  %s %-14s %s (%s)\n' "${C_CYAN}${ICON_BULLET}${C_RESET}" "Architecture:" "$arch" "$([ "$arch" = "arm64" ] && echo "Apple Silicon" || echo "Intel")"
  printf '  %s %-14s %s\n' "${C_CYAN}${ICON_BULLET}${C_RESET}" "Kernel:" "$kernel"
  printf '  %s %-14s %s\n' "${C_CYAN}${ICON_BULLET}${C_RESET}" "SIP:" "$sip_status"
  printf '  %s %-14s %s\n' "${C_CYAN}${ICON_BULLET}${C_RESET}" "Disk Free:" "$disk_free"
  printf '  %s %-14s %s\n' "${C_CYAN}${ICON_BULLET}${C_RESET}" "Full Disk:" "$fda_status"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Standard Summary Reporting Card
# ---------------------------------------------------------------------------

render_summary_card() {
  local mode="$1"
  local before_kb="$2"
  local reclaimed_kb="$3"
  local free_before="${4:-}"
  local free_after="${5:-}"

  if [ "$mode" = "scan" ]; then
    say "Estimated reclaimable space: ${C_BOLD}$(human_kb "$before_kb")${C_RESET}"
    say "  ${C_CYAN}${ICON_ARROW}${C_RESET} Run again with ${C_BOLD}--clean${C_RESET} to safely remove these files."
  else
    say "Space freed this run: ${C_BOLD}$(human_kb "$reclaimed_kb")${C_RESET}"
    if [ -n "$free_before" ] && [ -n "$free_after" ]; then
      say "  ${C_CYAN}${ICON_DISK}${C_RESET} Free space: ${C_BOLD}$free_before${C_RESET} ${ICON_ARROW} ${C_BOLD}$free_after${C_RESET}"
    fi
    say "Actions: ${ACTION_OK} succeeded, ${ACTION_SKIPPED} skipped, ${ACTION_DENIED} permission-denied, ${ACTION_FAILED} failed"
  fi
}
