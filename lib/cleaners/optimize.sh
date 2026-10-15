#!/usr/bin/env bash
#
# lib/cleaners/optimize.sh — Safe macOS Performance & Cache Optimizations.
#
# Sourced by lib/load.sh; never executed on its own.
# Provides safe, non-destructive optimization routines inspired by Mole:
# DNS cache flush, QuickLook thumbnail reset, preferences linting,
# .DS_Store network suppression, and Spotlight index verification.

opt_flush_dns() {
  local dry_run="${1:-0}"
  if [ "$dry_run" = 1 ]; then
    say "  ${C_YELLOW}${ICON_WARNING}${C_RESET} [preview] Would flush DNS cache and signal mDNSResponder"
    return 0
  fi

  local flushed=0
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -flushcache 2>/dev/null || true
    flushed=1
  fi
  killall -HUP mDNSResponder 2>/dev/null || true
  if [ "$flushed" = 1 ]; then
    say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} DNS resolver cache flushed successfully"
    return 0
  else
    say "  ${C_DIM}${ICON_EMPTY}${C_RESET} DNS cache flush skipped (dscacheutil not available)"
    return 0
  fi
}

opt_refresh_quicklook() {
  local dry_run="${1:-0}"
  local targets=(
    "$HOME_DIR/Library/Caches/com.apple.QuickLook.thumbnailcache"
    "$HOME_DIR/Library/Caches/com.apple.iconservices.store"
  )
  local t freed_total=0 found=0

  for t in "${targets[@]}"; do
    if [ -e "$t" ]; then
      found=1
      local sz=0
      sz="$(measure_path_kb "$t")"
      freed_total=$(( freed_total + sz ))

      if is_whitelisted "$t"; then
        say "  ${C_DIM}${ICON_EMPTY}${C_RESET} QuickLook cache whitelisted: $(basename "$t")"
        continue
      fi

      if [ "$dry_run" = 1 ]; then
        say "  ${C_YELLOW}${ICON_WARNING}${C_RESET} [preview] Would refresh $(basename "$t") ($(human_kb "$sz"))"
      else
        fs_remove "$t" >/dev/null 2>&1 || true
      fi
    fi
  done

  if [ "$dry_run" != 1 ]; then
    command -v qlmanage >/dev/null 2>&1 && qlmanage -r >/dev/null 2>&1 || true
    killall quicklookd >/dev/null 2>&1 || true
    if [ "$found" = 1 ]; then
      say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} QuickLook thumbnails & icon services cache refreshed"
    else
      say "  ${C_DIM}${ICON_EMPTY}${C_RESET} QuickLook caches already clean"
    fi
  fi
  return 0
}

opt_lint_preferences() {
  local dry_run="${1:-0}"
  local prefs_dir="$HOME_DIR/Library/Preferences"
  [ -d "$prefs_dir" ] || return 0

  command -v plutil >/dev/null 2>&1 || return 0

  local broken_count=0 plist f_size
  for plist in "$prefs_dir"/*.plist; do
    [ -f "$plist" ] || continue
    # Protect core system preferences from deletion
    case "$(basename "$plist")" in
      com.apple.*|.GlobalPreferences*) continue ;;
    esac

    f_size="$(stat -f%z "$plist" 2>/dev/null || echo "1")"
    local is_corrupted=0
    if [ "$f_size" = "0" ]; then
      is_corrupted=1
    elif ! plutil -lint "$plist" >/dev/null 2>&1; then
      is_corrupted=1
    fi

    if [ "$is_corrupted" = 1 ]; then
      if is_whitelisted "$plist"; then
        continue
      fi
      broken_count=$(( broken_count + 1 ))
      if [ "$dry_run" = 1 ]; then
        say "  ${C_YELLOW}${ICON_WARNING}${C_RESET} [preview] Would remove corrupted preference: $(basename "$plist")"
      else
        fs_remove "$plist" >/dev/null 2>&1 || true
      fi
    fi
  done

  if [ "$broken_count" -gt 0 ]; then
    if [ "$dry_run" != 1 ]; then
      say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} Repaired $broken_count corrupted preference files"
    fi
  else
    say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} Preference plists verified (no corrupted files found)"
  fi
  return 0
}

opt_prevent_network_dsstore() {
  local dry_run="${1:-0}"
  command -v defaults >/dev/null 2>&1 || return 0

  local net_curr usb_curr
  net_curr="$(defaults read com.apple.desktopservices DSDontWriteNetworkStores 2>/dev/null || echo "false")"
  usb_curr="$(defaults read com.apple.desktopservices DSDontWriteUSBStores 2>/dev/null || echo "false")"

  if [ "$net_curr" = "true" ] || [ "$net_curr" = "1" ]; then
    say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} Finder .DS_Store suppression on network shares already active"
  else
    if [ "$dry_run" = 1 ]; then
      say "  ${C_YELLOW}${ICON_WARNING}${C_RESET} [preview] Would disable .DS_Store generation on network and USB volumes"
    else
      defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true 2>/dev/null || true
      defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true 2>/dev/null || true
      say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} Configured Finder to stop writing .DS_Store on network & USB drives"
    fi
  fi
  return 0
}

opt_verify_spotlight() {
  local spot_out
  if ! command -v mdutil >/dev/null 2>&1; then
    say "  ${C_DIM}${ICON_EMPTY}${C_RESET} Spotlight verification skipped (mdutil not available)"
    return 0
  fi

  spot_out="$(mdutil -s / 2>/dev/null || echo "")"
  if printf '%s\n' "$spot_out" | grep -qi "disabled"; then
    say "  ${C_YELLOW}${ICON_WARNING}${C_RESET} Spotlight indexing is currently disabled on /"
  else
    say "  ${C_GREEN}${ICON_SUCCESS}${C_RESET} Spotlight index verified (active)"
  fi
  return 0
}

run_optimize() {
  log_init
  local dry_run=0
  if [ "$MODE" = "scan" ] || [ "${OPTIMIZE_DRY_RUN:-0}" = 1 ]; then
    dry_run=1
  fi

  say "${C_BOLD}${SCRIPT_NAME}${C_RESET} — system optimization"
  say "Mode: $([ "$dry_run" = 1 ] && echo "${C_YELLOW}preview (dry-run)${C_RESET}" || echo "${C_GREEN}apply${C_RESET}")"
  say ""

  start_spinner "Flushing DNS resolver cache..."
  opt_flush_dns "$dry_run"
  stop_spinner

  start_spinner "Refreshing QuickLook thumbnails & icon caches..."
  opt_refresh_quicklook "$dry_run"
  stop_spinner

  start_spinner "Inspecting preference plists for corruption..."
  opt_lint_preferences "$dry_run"
  stop_spinner

  start_spinner "Configuring Finder .DS_Store suppression..."
  opt_prevent_network_dsstore "$dry_run"
  stop_spinner

  start_spinner "Verifying Spotlight indexing..."
  opt_verify_spotlight
  stop_spinner

  say ""
  say "${C_GREEN}${ICON_SUCCESS} Optimization pass complete.${C_RESET}"
  return 0
}
