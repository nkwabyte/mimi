#!/usr/bin/env bash
#
# lib/config.sh — Reading and writing ~/.config/cleanmymac/config.conf.
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# Numeric keys the config file supplied, as "KEY<TAB>value" lines. Validated
# by validate_config_values() after argument parsing, so that an unusable
# config still leaves --help and --list working — otherwise the user has no
# in-tool way to find out how to fix it.
CONFIG_NUMERIC_SEEN=""

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      ''|'#'*) continue ;;
    esac
    case "$key" in
      SIM_STALE_DAYS|ANDROID_STALE_DAYS|KEEP_DEVICE_SUPPORT|TMP_STALE_DAYS|KEEP_TOOLCHAINS|KEEP_LOGS)
        CONFIG_NUMERIC_SEEN="$CONFIG_NUMERIC_SEEN$key	$val
" ;;
    esac
    case "$key" in
      SIM_STALE_DAYS) SIM_STALE_DAYS="$val" ;;
      ANDROID_STALE_DAYS) ANDROID_STALE_DAYS="$val" ;;
      KEEP_DEVICE_SUPPORT) KEEP_DEVICE_SUPPORT="$val" ;;
      TMP_STALE_DAYS) TMP_STALE_DAYS="$val" ;;
      KEEP_TOOLCHAINS) KEEP_TOOLCHAINS="$val" ;;
      KEEP_LOGS) KEEP_LOGS="$val" ;;
      WHITELIST)
        local _wl
        IFS=',' read -r -a _wl <<< "$val"
        WHITELIST+=("${_wl[@]}")
        ;;
      SELECTED_CATEGORIES) CONFIG_SELECTED_CATEGORIES="$val" ;;
    esac
  done < "$CONFIG_FILE"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  local wl_joined="" w
  for w in "${WHITELIST[@]:-}"; do
    [ -z "$w" ] && continue
    wl_joined="${wl_joined:+$wl_joined,}$w"
  done
  local sel_joined="" i
  for i in "${!CATEGORY_STATE_IDS[@]}"; do
    [ "${CATEGORY_STATE_ON[$i]}" = "1" ] && sel_joined="${sel_joined:+$sel_joined,}${CATEGORY_STATE_IDS[$i]}"
  done
  # Written to a temporary file in the same directory and then renamed over
  # the target. A partial write here is not cosmetic: validate_config_values()
  # refuses to run at all on a malformed config (DEC-006), so a config
  # truncated by a full disk or an interrupted save would lock the user out of
  # every run until they hand-edited it.
  local tmp
  tmp="$(mktemp "$CONFIG_DIR/.config.conf.XXXXXX" 2>/dev/null)" || {
    err "could not create a temporary file in $CONFIG_DIR; settings not saved"
    return 1
  }
  # mktemp already creates 0600; being explicit because this file records
  # whitelist paths, which describe the layout of the user's filesystem.
  chmod 600 "$tmp" 2>/dev/null || true

  if ! {
    printf '# clean.sh saved settings — edit by hand or via the interactive menu (-i)\n'
    printf 'SIM_STALE_DAYS=%s\n' "$SIM_STALE_DAYS"
    printf 'ANDROID_STALE_DAYS=%s\n' "$ANDROID_STALE_DAYS"
    printf 'KEEP_DEVICE_SUPPORT=%s\n' "$KEEP_DEVICE_SUPPORT"
    printf 'TMP_STALE_DAYS=%s\n' "$TMP_STALE_DAYS"
    printf 'KEEP_TOOLCHAINS=%s\n' "$KEEP_TOOLCHAINS"
    printf 'KEEP_LOGS=%s\n' "$KEEP_LOGS"
    printf 'WHITELIST=%s\n' "$wl_joined"
    printf 'SELECTED_CATEGORIES=%s\n' "$sel_joined"
  } > "$tmp"; then
    # Justified raw rm: our own half-written temporary file, which no user
    # action selected and which must not be counted as one.
    rm -f "$tmp"
    err "could not write settings to $CONFIG_DIR; nothing was changed"
    return 1
  fi

  if ! mv -f "$tmp" "$CONFIG_FILE"; then
    # Justified raw rm: as above.
    rm -f "$tmp"
    err "could not replace $CONFIG_FILE; the previous settings are still in place"
    return 1
  fi

  ok "settings saved to $CONFIG_FILE"
  return 0
}
