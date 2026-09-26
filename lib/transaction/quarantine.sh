#!/usr/bin/env bash
#
# lib/transaction/quarantine.sh lib/quarantine.sh — Quarantine executor, restore, and purge (Phase 2).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions only.

QUARANTINE_CURRENT_RUN_ID=""
QUARANTINE_CURRENT_RUN_DIR=""

# history_record TYPE STATUS [key=value ...]
#
# Append one line to HISTORY_FILE. Values are strings, except that a value
# made only of digits is written as a number. The file is created 0600 and
# only ever appended to, so an earlier record is never rewritten.
history_record() {
  local type="$1" status="$2" kv key val line
  shift 2
  line="$(printf '{"at":"%s","type":"%s","status":"%s"' \
    "$(json_now_iso)" "$(json_escape "$type")" "$(json_escape "$status")")"
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$val" in
      '' | *[!0-9]*) line="$line$(printf ',"%s":"%s"' "$(json_escape "$key")" "$(json_escape "$val")")" ;;
      *)             line="$line$(printf ',"%s":%s' "$(json_escape "$key")" "$val")" ;;
    esac
  done
  line="$line}"
  mkdir -p "$(dirname "$HISTORY_FILE")" 2>/dev/null || return 0
  if [ ! -e "$HISTORY_FILE" ]; then
    ( umask 077; : > "$HISTORY_FILE" ) 2>/dev/null || return 0
  fi
  printf '%s\n' "$line" >> "$HISTORY_FILE" 2>/dev/null || true
  return 0
}

quarantine_init_run() {
  local custom_id="${1:-}"
  if [ -n "$custom_id" ]; then
    QUARANTINE_CURRENT_RUN_ID="$custom_id"
  else
    QUARANTINE_CURRENT_RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
  fi
  QUARANTINE_CURRENT_RUN_DIR="$QUARANTINE_DIR/$QUARANTINE_CURRENT_RUN_ID"
  mkdir -p "$QUARANTINE_CURRENT_RUN_DIR" || return 1
  chmod 0700 "$QUARANTINE_CURRENT_RUN_DIR" 2>/dev/null || true
  touch "$QUARANTINE_CURRENT_RUN_DIR/manifest.jsonl" || return 1
  chmod 0600 "$QUARANTINE_CURRENT_RUN_DIR/manifest.jsonl" 2>/dev/null || true
  return 0
}

quarantine_target() {
  local act_id="$1" cat="$2" target_path="$3" expected_ident="${4:-}" expected_bytes="${5:-0}"
  if [ -z "$QUARANTINE_CURRENT_RUN_DIR" ]; then
    quarantine_init_run || return 1
  fi

  if [ ! -e "$target_path" ] && [ ! -L "$target_path" ]; then
    verbose "quarantine: target missing: $target_path"
    return 1
  fi

  local cur_ident
  cur_ident="$(path_identity "$target_path" 2>/dev/null || echo "")"
  if [ -n "$expected_ident" ] && [ "$expected_ident" != "unknown" ] && [ "$cur_ident" != "$expected_ident" ]; then
    warn "quarantine: target identity changed, skipping: $target_path"
    return 1
  fi

  local base dest_name dest_path
  base="$(basename "$target_path")"
  dest_name="${base}__${act_id}"
  dest_path="$QUARANTINE_CURRENT_RUN_DIR/$dest_name"

  # Same volume check for atomic mv
  local src_dev dst_dev
  src_dev="$(stat -f "%d" "$target_path" 2>/dev/null || echo 0)"
  dst_dev="$(stat -f "%d" "$QUARANTINE_CURRENT_RUN_DIR" 2>/dev/null || echo 0)"

  if [ "$src_dev" = "$dst_dev" ] && [ "$src_dev" != "0" ]; then
    if ! mv -f "$target_path" "$dest_path" 2>>"$LOG_FILE"; then
      err "quarantine: move failed: $target_path -> $dest_path"
      return 1
    fi
  else
    # Cross-volume: copy with attributes, verify destination, then fs_remove original
    if ! cp -pPR "$target_path" "$dest_path" 2>>"$LOG_FILE"; then
      err "quarantine: cross-volume copy failed: $target_path -> $dest_path"
      return 1
    fi
    if [ ! -e "$dest_path" ] && [ ! -L "$dest_path" ]; then
      err "quarantine: cross-volume copy destination missing: $dest_path"
      return 1
    fi
    if ! fs_remove "$target_path"; then
      err "quarantine: cross-volume removal of original failed: $target_path"
      fs_remove "$dest_path"
      return 1
    fi
  fi

  # Postcondition verification
  if [ ! -e "$target_path" ] && [ ! -L "$target_path" ] && { [ -e "$dest_path" ] || [ -L "$dest_path" ]; }; then
    local now_iso
    now_iso="$(json_now_iso)"
    printf '{"action_id":"%s","category":"%s","original_path":"%s","quarantine_path":"%s","identity":"%s","bytes":%d,"quarantined_at":"%s"}\n' \
      "$(json_escape "$act_id")" \
      "$(json_escape "$cat")" \
      "$(json_escape "$target_path")" \
      "$(json_escape "$dest_path")" \
      "$(json_escape "$cur_ident")" \
      "$expected_bytes" \
      "$(json_escape "$now_iso")" >> "$QUARANTINE_CURRENT_RUN_DIR/manifest.jsonl"
    return 0
  fi

  err "quarantine: postcondition failed for $target_path"
  return 1
}

quarantine_restore_target() {
  local q_path="$1" orig_path="$2" expected_ident="${3:-}"

  if [ ! -e "$q_path" ] && [ ! -L "$q_path" ]; then
    err "quarantine restore: quarantined file missing: $q_path"
    return 1
  fi

  if [ -e "$orig_path" ] || [ -L "$orig_path" ]; then
    warn "quarantine restore: original path already occupied: $orig_path"
    return 1
  fi

  local cur_ident
  cur_ident="$(path_identity "$q_path" 2>/dev/null || echo "")"
  if [ -n "$expected_ident" ] && [ "$expected_ident" != "unknown" ] && [ "$cur_ident" != "$expected_ident" ]; then
    warn "quarantine restore: quarantined object identity changed: $q_path"
    return 1
  fi

  local orig_dir
  orig_dir="$(dirname "$orig_path")"
  mkdir -p "$orig_dir" || return 1

  local src_dev dst_dev
  src_dev="$(stat -f "%d" "$q_path" 2>/dev/null || echo 0)"
  dst_dev="$(stat -f "%d" "$orig_dir" 2>/dev/null || echo 0)"

  if [ "$src_dev" = "$dst_dev" ] && [ "$src_dev" != "0" ]; then
    mv -f "$q_path" "$orig_path" 2>>"$LOG_FILE" || return 1
  else
    cp -pPR "$q_path" "$orig_path" 2>>"$LOG_FILE" || return 1
    fs_remove "$q_path" || return 1
  fi

  if [ -e "$orig_path" ] || [ -L "$orig_path" ]; then
    return 0
  fi
  return 1
}

quarantine_restore_run() {
  local run_id="$1"
  local run_dir="$QUARANTINE_DIR/$run_id"
  [ -d "$run_dir" ] || run_dir="$run_id"
  if [ ! -d "$run_dir" ]; then
    err "quarantine restore: run directory not found: $run_id"
    return 1
  fi

  local manifest="$run_dir/manifest.jsonl"
  if [ ! -f "$manifest" ]; then
    err "quarantine restore: manifest missing in $run_dir"
    return 1
  fi

  local line restored=0 failed=0 already=0 conflicts=0 agents=0 bundles=0
  local act_id orig_path q_path ident now_ident
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    orig_path="$(printf '%s' "$line" | sed -n 's/.*"original_path":"\([^"]*\)".*/\1/p')"
    q_path="$(printf '%s' "$line" | sed -n 's/.*"quarantine_path":"\([^"]*\)".*/\1/p')"
    ident="$(printf '%s' "$line" | sed -n 's/.*"identity":"\([^"]*\)".*/\1/p')"
    act_id="$(printf '%s' "$line" | sed -n 's/.*"action_id":"\([^"]*\)".*/\1/p')"

    if [ -z "$orig_path" ] || [ -z "$q_path" ]; then
      continue
    fi

    # Re-running restore is safe: an item already back where it belongs, as
    # the same object, is reported and skipped rather than counted as failed.
    if { [ ! -e "$q_path" ] && [ ! -L "$q_path" ]; } && { [ -e "$orig_path" ] || [ -L "$orig_path" ]; }; then
      now_ident="$(path_identity "$orig_path" 2>/dev/null || echo "")"
      if [ -z "$ident" ] || [ "$now_ident" = "$ident" ]; then
        info "already restored: $orig_path"
        already=$((already + 1))
        continue
      fi
    fi

    # Original path taken (the app was reinstalled, or the data recreated):
    # never overwrite it. The quarantined copy stays where it is.
    if { [ -e "$q_path" ] || [ -L "$q_path" ]; } && { [ -e "$orig_path" ] || [ -L "$orig_path" ]; }; then
      warn "not restored, something already exists at: $orig_path"
      warn "  the quarantined copy is kept at: $q_path"
      warn "  move or remove the existing item, then run restore again"
      conflicts=$((conflicts + 1))
      failed=$((failed + 1))
      printf '{"action_id":"%s","status":"conflict","original_path":"%s","attempted_at":"%s"}\n' \
        "$(json_escape "$act_id")" "$(json_escape "$orig_path")" "$(json_now_iso)" >> "$run_dir/restore.jsonl"
      continue
    fi

    if quarantine_restore_target "$q_path" "$orig_path" "$ident"; then
      now_ident="$(path_identity "$orig_path" 2>/dev/null || echo "")"
      if [ -n "$ident" ] && [ "$ident" != "unknown" ] && [ "$now_ident" != "$ident" ]; then
        # Expected only after a cross-volume copy back.
        warn "restored (as a copy — file identity differs from the original): $orig_path"
      else
        ok "restored: $orig_path"
      fi
      case "$orig_path" in
        */LaunchAgents/*.plist) agents=$((agents + 1)) ;;
        *.app) bundles=$((bundles + 1)) ;;
      esac
      restored=$((restored + 1))
      printf '{"action_id":"%s","status":"restored","original_path":"%s","restored_at":"%s"}\n' \
        "$(json_escape "$act_id")" \
        "$(json_escape "$orig_path")" \
        "$(json_now_iso)" >> "$run_dir/restore.jsonl"
    else
      failed=$((failed + 1))
      printf '{"action_id":"%s","status":"failed","original_path":"%s","attempted_at":"%s"}\n' \
        "$(json_escape "$act_id")" \
        "$(json_escape "$orig_path")" \
        "$(json_now_iso)" >> "$run_dir/restore.jsonl"
    fi
  done < "$manifest"

  say "Restore finished: $restored restored, $already already in place, $failed failed"
  if [ "$agents" -gt 0 ]; then
    info "$agents LaunchAgent(s) are back but not running; they start at your next login,"
    info "or now with: launchctl bootstrap gui/$(id -u) <plist>"
  fi
  if [ "$bundles" -gt 0 ]; then
    info "Restored apps re-register their login items and background services the next"
    info "time they are opened."
  fi
  [ "$failed" -eq 0 ]
}

quarantine_purge_run() {
  local run_id="$1"
  local run_dir="$QUARANTINE_DIR/$run_id"
  [ -d "$run_dir" ] || run_dir="$run_id"
  if [ ! -d "$run_dir" ]; then
    err "quarantine purge: run directory not found: $run_id"
    return 1
  fi

  if ! fs_remove "$run_dir"; then
    err "quarantine purge: failed to purge run directory: $run_dir"
    return 1
  fi
  ok "purged quarantine run: $run_id"
  return 0
}
