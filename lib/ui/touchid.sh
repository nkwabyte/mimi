#!/usr/bin/env bash
#
# lib/ui/touchid.sh — Touch ID PAM configuration and status for sudo (Phase 9).
#
# Inspired by Mole's touchid module. Enables seamless biometric authentication
# for administrative tasks by managing /etc/pam.d/sudo_local (macOS Sonoma+)
# or /etc/pam.d/sudo with strict permission preservation.
#
# Sourced by lib/load.sh; never executed on its own.
# Compatible with macOS /bin/bash 3.2+.
#

PAM_SUDO_FILE="${MIMI_PAM_SUDO_FILE:-/etc/pam.d/sudo}"
PAM_SUDO_LOCAL_FILE="${MIMI_PAM_SUDO_LOCAL_FILE:-$(dirname "$PAM_SUDO_FILE")/sudo_local}"
PAM_TID_LINE="auth       sufficient     pam_tid.so"

# Check if the hardware/architecture supports Touch ID
supports_touchid() {
  if [ "${MIMI_MOCK_TOUCHID_SUPPORT:-}" = "1" ]; then
    return 0
  elif [ "${MIMI_MOCK_TOUCHID_SUPPORT:-}" = "0" ]; then
    return 1
  fi

  if command -v bioutil >/dev/null 2>&1; then
    if bioutil -r 2>/dev/null | grep -iq "Touch ID"; then
      return 0
    fi
  fi

  local arch
  arch="$(uname -m 2>/dev/null || echo "")"
  if [ "$arch" = "arm64" ]; then
    return 0
  fi

  return 1
}

# Check if Touch ID is configured in sudo_local or sudo
is_touchid_configured() {
  if [ -f "$PAM_SUDO_LOCAL_FILE" ]; then
    if grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" 2>/dev/null; then
      return 0
    fi
  fi

  if [ -f "$PAM_SUDO_FILE" ]; then
    if grep -q "pam_tid.so" "$PAM_SUDO_FILE" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

# Display Touch ID status in human-readable or JSON format
touchid_status() {
  local is_cfg=0 is_sup=0 active_file=""
  is_touchid_configured && is_cfg=1
  supports_touchid && is_sup=1

  if [ "$is_cfg" = 1 ]; then
    if [ -f "$PAM_SUDO_LOCAL_FILE" ] && grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" 2>/dev/null; then
      active_file="$PAM_SUDO_LOCAL_FILE"
    else
      active_file="$PAM_SUDO_FILE"
    fi
  fi

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '{"type":"touchid_status","configured":%s,"supported":%s,"file":"%s"}\n' \
      "$([ "$is_cfg" = 1 ] && echo "true" || echo "false")" \
      "$([ "$is_sup" = 1 ] && echo "true" || echo "false")" \
      "$(json_escape "$active_file")"
    return 0
  fi

  render_card_header "Touch ID for sudo Status"
  if [ "$is_cfg" = 1 ]; then
    printf "  %b Touch ID is ${C_GREEN}${C_BOLD}enabled${C_RESET} for sudo.\n" "${C_GREEN}${ICON_SUCCESS}${C_RESET}"
    printf "  ${C_DIM}Configured in: %s${C_RESET}\n" "$active_file"
  else
    printf "  %b Touch ID is ${C_YELLOW}not configured${C_RESET} for sudo.\n" "${C_YELLOW}${ICON_WARNING}${C_RESET}"
    if [ "$is_sup" = 1 ]; then
      printf "  ${C_DIM}Hardware: Supported on this Mac. Enable with: mimi touchid enable${C_RESET}\n"
    else
      printf "  ${C_DIM}Hardware: May not be supported or detected on this machine.${C_RESET}\n"
    fi
  fi
  render_card_footer
  return 0
}

# Helper to install PAM file with root:wheel permissions (or unprivileged in test mode)
_secure_install_pam() {
  local src="$1" dst="$2"
  if [ "${MIMI_TEST_PAM_NO_ROOT:-0}" = 1 ] || [ -w "$(dirname "$dst")" ]; then
    install -m 444 "$src" "$dst"
  else
    local admin_exec
    admin_exec="$(command -v sudo 2>/dev/null || echo "")"
    if [ -n "$admin_exec" ]; then
      "$admin_exec" install -m 444 -o root -g wheel "$src" "$dst"
    else
      err "Cannot write to $dst and privilege escalation tool is unavailable."
      return 1
    fi
  fi
}

# Enable Touch ID for sudo
enable_touchid() {
  local is_dry=0
  [ "${DRY_RUN:-0}" = 1 ] && is_dry=1

  if [ "$is_dry" = 1 ]; then
    if is_touchid_configured; then
      say "${C_GREEN}${ICON_SUCCESS} Touch ID is already configured, no changes needed.${C_RESET}"
    else
      say "${C_GREEN}${ICON_SUCCESS} [DRY RUN] Would enable Touch ID for sudo via $PAM_SUDO_LOCAL_FILE${C_RESET}"
    fi
    return 0
  fi

  if is_touchid_configured; then
    say "${C_GREEN}${ICON_SUCCESS} Touch ID is already enabled for sudo.${C_RESET}"
    return 0
  fi

  if ! supports_touchid; then
    warn "This Mac may not support Touch ID hardware."
  fi

  local tmp
  tmp="$(mktemp "${MIMI_TMPDIR:-/tmp}/.mimi-pam.XXXXXX")" || return 1

  if [ -f "$PAM_SUDO_LOCAL_FILE" ]; then
    cp "$PAM_SUDO_LOCAL_FILE" "$tmp"
    printf '%s\n' "$PAM_TID_LINE" >> "$tmp"
  else
    printf '# sudo_local: local customizations for sudo\n%s\n' "$PAM_TID_LINE" > "$tmp"
  fi

  if _secure_install_pam "$tmp" "$PAM_SUDO_LOCAL_FILE"; then
    /bin/unlink "$tmp" 2>/dev/null || true
    say "${C_GREEN}${ICON_SUCCESS} Touch ID enabled for sudo via $PAM_SUDO_LOCAL_FILE.${C_RESET}"
    say "  ${C_DIM}Test it by opening a new terminal tab and running: sudo ls${C_RESET}"
    return 0
  else
    /bin/unlink "$tmp" 2>/dev/null || true
    err "Failed to install Touch ID PAM configuration."
    return 1
  fi
}

# Disable Touch ID for sudo
disable_touchid() {
  local is_dry=0
  [ "${DRY_RUN:-0}" = 1 ] && is_dry=1

  if [ "$is_dry" = 1 ]; then
    if ! is_touchid_configured; then
      say "${C_YELLOW}${ICON_WARNING} Touch ID is not currently enabled for sudo.${C_RESET}"
    else
      say "${C_GREEN}${ICON_SUCCESS} [DRY RUN] Would disable Touch ID for sudo${C_RESET}"
    fi
    return 0
  fi

  if ! is_touchid_configured; then
    say "${C_YELLOW}${ICON_WARNING} Touch ID is not currently configured for sudo.${C_RESET}"
    return 0
  fi

  local changed=0

  if [ -f "$PAM_SUDO_LOCAL_FILE" ] && grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" 2>/dev/null; then
    local tmp
    tmp="$(mktemp "${MIMI_TMPDIR:-/tmp}/.mimi-pam.XXXXXX")" || return 1
    grep -v "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" > "$tmp" || true
    if _secure_install_pam "$tmp" "$PAM_SUDO_LOCAL_FILE"; then
      changed=1
    fi
    /bin/unlink "$tmp" 2>/dev/null || true
  fi

  if [ -f "$PAM_SUDO_FILE" ] && grep -q "pam_tid.so" "$PAM_SUDO_FILE" 2>/dev/null; then
    local tmp2
    tmp2="$(mktemp "${MIMI_TMPDIR:-/tmp}/.mimi-pam.XXXXXX")" || return 1
    grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$tmp2" || true
    if _secure_install_pam "$tmp2" "$PAM_SUDO_FILE"; then
      changed=1
    fi
    /bin/unlink "$tmp2" 2>/dev/null || true
  fi

  if [ "$changed" = 1 ]; then
    say "${C_GREEN}${ICON_SUCCESS} Touch ID disabled for sudo.${C_RESET}"
    return 0
  else
    err "Failed to remove Touch ID from PAM configuration."
    return 1
  fi
}

# Toggle Touch ID
touchid_toggle() {
  if is_touchid_configured; then
    disable_touchid
  else
    enable_touchid
  fi
}

# Top-level subcommand router
run_touchid() {
  local action="${1:-status}"
  case "$action" in
    enable)  enable_touchid ;;
    disable) disable_touchid ;;
    toggle)  touchid_toggle ;;
    status|"") touchid_status ;;
    *)
      err "unknown touchid action: $action (valid: status, enable, disable, toggle)"
      return "$EXIT_USAGE"
      ;;
  esac
}
