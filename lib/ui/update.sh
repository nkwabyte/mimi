#!/usr/bin/env bash
#
# lib/ui/update.sh — Mimi self-update & version check engine (Phase 12).
#
# Inspired by Mole's update module (mo update). Detects installation channels
# (Homebrew, Git repository checkout, standalone script install), discovers
# latest remote releases via GitHub API, and handles seamless upgrades.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#

GITHUB_MIMI_REPO="nkwabyte/mimi"

# Detect which channel mimi was installed with
detect_install_channel() {
  # 1. Homebrew tap
  if command -v brew >/dev/null 2>&1; then
    if brew list nkwabyte/mimi/mimi >/dev/null 2>&1 || brew list mimi >/dev/null 2>&1; then
      printf 'homebrew'
      return 0
    fi
  fi

  # 2. Git checkout
  local script_dir="${MIMI_ROOT_DIR:-}"
  if [ -n "$script_dir" ] && [ -d "$script_dir/.git" ]; then
    printf 'git'
    return 0
  fi

  # 3. Direct script install
  printf 'script'
}

# Fetch the latest release tag from GitHub API
fetch_latest_github_version() {
  if [ -n "${MIMI_MOCK_LATEST_VERSION:-}" ]; then
    printf '%s' "${MIMI_MOCK_LATEST_VERSION#v}"
    return 0
  fi

  local api_url="https://api.github.com/repos/$GITHUB_MIMI_REPO/releases/latest"
  local json_out=""

  if command -v curl >/dev/null 2>&1; then
    json_out="$(curl -fsSL --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null)" || true
  elif command -v wget >/dev/null 2>&1; then
    json_out="$(wget -qO- --timeout=10 "$api_url" 2>/dev/null)" || true
  fi

  if [ -z "$json_out" ]; then
    # Fallback to git remote tags if in a git repo
    local script_dir="${MIMI_ROOT_DIR:-}"
    if [ -n "$script_dir" ] && [ -d "$script_dir/.git" ]; then
      local tag
      tag="$(git -C "$script_dir" ls-remote --tags --refs origin 'v*' 2>/dev/null | tail -1 | sed 's@.*/v@@')"
      if [ -n "$tag" ]; then
        printf '%s' "$tag"
        return 0
      fi
    fi
    return 1
  fi

  # Parse tag_name: "vX.Y.Z"
  local tag
  tag="$(printf '%s\n' "$json_out" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/')"
  if [ -n "$tag" ]; then
    printf '%s' "$tag"
    return 0
  fi
  return 1
}

# Version comparison: returns 0 if $1 is newer than $2
is_newer_semver() {
  local remote="${1#v}" local_v="${2#v}"
  [ "$remote" = "$local_v" ] && return 1

  local -a r=() l=()
  IFS=. read -r -a r <<< "$remote"
  IFS=. read -r -a l <<< "$local_v"
  local i

  for i in 0 1 2; do
    local r_num="${r[i]:-0}"
    local l_num="${l[i]:-0}"
    # Strip any pre-release suffixes for basic comparison
    r_num="${r_num%%[!0-9]*}"
    l_num="${l_num%%[!0-9]*}"
    [ -z "$r_num" ] && r_num=0
    [ -z "$l_num" ] && l_num=0

    if [ "$r_num" -gt "$l_num" ]; then
      return 0
    elif [ "$r_num" -lt "$l_num" ]; then
      return 1
    fi
  done
  return 1
}

# Run the update flow
run_update() {
  local check_only=0
  [ "${UPDATE_CHECK_ONLY:-0}" = 1 ] && check_only=1

  local channel
  channel="$(detect_install_channel)"

  say "${C_BOLD}Mimi Update Check${C_RESET}"
  say "Current Version:      ${C_CYAN}v${MIMI_VERSION}${C_RESET}"
  say "Install Channel:      ${C_DIM}${channel}${C_RESET}"

  start_spinner "Checking GitHub for latest release..."
  local latest_v=""
  latest_v="$(fetch_latest_github_version)" || true
  stop_spinner

  if [ -z "$latest_v" ]; then
    if [ "${JSONL_ENABLED:-0}" = 1 ]; then
      printf '{"type":"update_check","current_version":"%s","error":"check_failed","channel":"%s"}\n' \
        "$MIMI_VERSION" "$channel"
      return 0
    fi
    warn "Could not check latest release from GitHub (network or rate limit)."
    say "To check manually: https://github.com/$GITHUB_MIMI_REPO/releases"
    return 0
  fi

  say "Latest Release:       ${C_GREEN}v${latest_v}${C_RESET}"
  say ""

  local update_avail=0
  if is_newer_semver "$latest_v" "$MIMI_VERSION"; then
    update_avail=1
  fi

  # Telemetry in JSON mode
  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '{"type":"update_check","current_version":"%s","latest_version":"%s","update_available":%s,"channel":"%s"}\n' \
      "$MIMI_VERSION" "$latest_v" "$([ "$update_avail" = 1 ] && echo true || echo false)" "$channel"
    return 0
  fi

  if [ "$update_avail" -eq 0 ]; then
    say "${C_GREEN}${ICON_SUCCESS} Mimi is already up to date.${C_RESET}"
    return 0
  fi

  say "${C_YELLOW}${ICON_WARNING} A new version of Mimi is available: v${latest_v}${C_RESET}"

  if [ "$check_only" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
    say "Run 'mimi update' to install the latest version."
    return 0
  fi

  case "$channel" in
    homebrew)
      say "Updating via Homebrew..."
      if [ "${ASSUME_YES:-0}" != 1 ]; then
        confirm "Upgrade Homebrew tap to v${latest_v}?" || return 0
      fi
      brew update && brew upgrade nkwabyte/mimi/mimi
      ;;
    git)
      local script_dir="${MIMI_ROOT_DIR:-}"
      say "Updating git repository at $script_dir..."
      if [ "${ASSUME_YES:-0}" != 1 ]; then
        confirm "Pull latest changes from origin?" || return 0
      fi
      git -C "$script_dir" pull origin main
      say "${C_GREEN}${ICON_SUCCESS} Updated repository to latest release.${C_RESET}"
      ;;
    script)
      say "To update your standalone script installation, run:"
      say "  ${C_CYAN}curl -fsSL https://raw.githubusercontent.com/$GITHUB_MIMI_REPO/main/install.sh | bash${C_RESET}"
      ;;
  esac
  return 0
}
