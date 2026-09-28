#!/usr/bin/env bash
#
# lib/transaction/quarantine.sh lib/quarantine.sh — Quarantine executor, restore, and purge (Phase 2).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions only.

# Version of the records history_record writes ("v" field). Records without
# "v" were written before 2026-09-27 and have the same shape as version 1.
HISTORY_SCHEMA_VERSION=1

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
  line="$(printf '{"v":%d,"at":"%s","type":"%s","status":"%s"' \
    "$HISTORY_SCHEMA_VERSION" "$(json_now_iso)" "$(json_escape "$type")" "$(json_escape "$status")")"
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

# One grammar for plan ids and quarantine run ids. Rejects empty, ".",
# "..", slashes, and anything outside [A-Za-z0-9._-]. ".." inside the id
# is rejected too, so a name cannot be a traversal once it is joined.
mimi_id_ok() {
  local id="$1"
  [ -n "$id" ] || return 1
  [ "${#id}" -le 128 ] || return 1
  case "$id" in
    */*|*..*|.) return 1 ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The directory for a run id, or failure. It is a real directory, not a
# symlink, and a direct child of the quarantine root.
quarantine_run_dir() {
  local id="$1" root dir
  mimi_id_ok "$id" || return 1
  root="${QUARANTINE_DIR%/}"
  dir="$root/$id"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ "$(dirname "$dir")" = "$root" ] || return 1
  printf '%s' "$dir"
}

# Create the quarantine root once: private, and kept out of Time Machine and
# Spotlight. Quarantined caches are not worth backing up a second time.
quarantine_root_init() {
  # The marker also covers a root moved here from the old location.
  [ -f "$QUARANTINE_DIR/.metadata_never_index" ] && return 0
  ( umask 077; mkdir -p "$QUARANTINE_DIR" ) || return 1
  chmod 0700 "$QUARANTINE_DIR" 2>/dev/null || true
  : > "$QUARANTINE_DIR/.metadata_never_index" 2>/dev/null || true
  if command -v tmutil > /dev/null 2>&1; then
    tmutil addexclusion "$QUARANTINE_DIR" > /dev/null 2>&1 || true
  fi
  return 0
}

# quarantine_init_run [RUN_ID]   (callers in other modules pass the id)
# shellcheck disable=SC2120
quarantine_init_run() {
  local custom_id="${1:-}"
  if [ -n "$custom_id" ]; then
    if ! mimi_id_ok "$custom_id"; then
      err "quarantine: invalid run id: $custom_id"
      return 1
    fi
    QUARANTINE_CURRENT_RUN_ID="$custom_id"
  else
    QUARANTINE_CURRENT_RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
  fi
  quarantine_root_init || return 1
  QUARANTINE_CURRENT_RUN_DIR="$QUARANTINE_DIR/$QUARANTINE_CURRENT_RUN_ID"
  ( umask 077; mkdir -p "$QUARANTINE_CURRENT_RUN_DIR" && : >> "$QUARANTINE_CURRENT_RUN_DIR/manifest.jsonl" ) || return 1
  return 0
}

_quarantine_manifest_line() {
  local act_id="$1" cat="$2" orig="$3" dest="$4" ident="$5" bytes="$6" status="${7:-}"
  printf '{"action_id":"%s","category":"%s","original_path":"%s","quarantine_path":"%s","identity":"%s","bytes":%d,"quarantined_at":"%s"%s}\n' \
    "$(json_escape "$act_id")" "$(json_escape "$cat")" "$(json_escape "$orig")" \
    "$(json_escape "$dest")" "$(json_escape "$ident")" "$bytes" "$(json_now_iso)" \
    "${status:+,\"status\":\"$status\"}" >> "$QUARANTINE_CURRENT_RUN_DIR/manifest.jsonl"
}

# Entries and allocated KB of a tree, as "count kb". Used to check a
# cross-volume copy before the original is removed.
_tree_signature() {
  printf '%s %s' "$(find "$1" 2>/dev/null | wc -l | tr -d ' ')" "$(dir_size_kb "$1")"
}

# Move one target into the current run. Same volume: one atomic rename.
# Another volume: copy, compare, then remove the original. If the original
# cannot be fully removed, the complete copy is KEPT and recorded as partial;
# it is never thrown away to "undo" the attempt.
quarantine_target() {
  local act_id="$1" cat="$2" target_path="$3" expected_ident="${4:-}" expected_bytes="${5:-0}"
  if [ -z "$QUARANTINE_CURRENT_RUN_DIR" ]; then
    # shellcheck disable=SC2119
    quarantine_init_run || return 1
  fi

  if [ ! -e "$target_path" ] && [ ! -L "$target_path" ]; then
    verbose "quarantine: target missing: $target_path"
    return 1
  fi
  if is_whitelisted "$target_path"; then
    warn "quarantine: whitelisted (or holds a whitelisted path), skipped: $target_path"
    return 1
  fi

  local cur_ident
  cur_ident="$(path_identity "$target_path" 2>/dev/null || echo "")"
  if [ -n "$expected_ident" ] && [ "$expected_ident" != "unknown" ] && [ "$cur_ident" != "$expected_ident" ]; then
    warn "quarantine: target identity changed, skipping: $target_path"
    return 1
  fi

  local dest_path="$QUARANTINE_CURRENT_RUN_DIR/${target_path##*/}__${act_id}"
  if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
    err "quarantine: destination already exists: $dest_path"
    return 1
  fi

  local src_dev dst_dev
  src_dev="$(file_device "$target_path" 2>/dev/null || echo 0)"
  dst_dev="$(file_device "$QUARANTINE_CURRENT_RUN_DIR" 2>/dev/null || echo 0)"

  if [ "$src_dev" = "$dst_dev" ] && [ "$src_dev" != "0" ]; then
    if ! mv "$target_path" "$dest_path" 2>>"$LOG_FILE"; then
      err "quarantine: move failed: $target_path"
      return 1
    fi
  else
    if ! cp -pPR "$target_path" "$dest_path" 2>>"$LOG_FILE" ||
       [ "$(_tree_signature "$target_path")" != "$(_tree_signature "$dest_path")" ]; then
      err "quarantine: copy to the quarantine volume did not match; original left in place: $target_path"
      fs_remove "$dest_path"
      return 1
    fi
    if ! fs_remove "$target_path"; then
      _quarantine_manifest_line "$act_id" "$cat" "$target_path" "$dest_path" "$cur_ident" "$expected_bytes" "partial"
      err "quarantine: the original could not be fully removed; a complete copy is kept at $dest_path"
      return 1
    fi
  fi

  if [ ! -e "$target_path" ] && [ ! -L "$target_path" ] && { [ -e "$dest_path" ] || [ -L "$dest_path" ]; }; then
    _quarantine_manifest_line "$act_id" "$cat" "$target_path" "$dest_path" "$cur_ident" "$expected_bytes"
    return 0
  fi
  err "quarantine: postcondition failed for $target_path"
  return 1
}

# Quarantine the CONTENTS of a planned directory, never the directory itself:
# it may carry ACLs or flags, an app may hold it open, and something like
# ~/.Trash has to stay where Finder expects it. Each child gets the checks
# clear_dir_contents applies. Returns non-zero when any child failed.
QUARANTINE_DIR_KB=0
quarantine_dir_contents() {
  local act_id="$1" cat="$2" dir="$3" expected_ident="${4:-}"
  local entry n=0 failed=0 kb
  QUARANTINE_DIR_KB=0
  if [ -n "$expected_ident" ] && [ "$expected_ident" != "unknown" ] &&
     [ "$(path_identity "$dir" 2>/dev/null)" != "$expected_ident" ]; then
    warn "quarantine: directory changed since it was planned, skipped: $dir"
    return 1
  fi
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    interrupted && return 1
    if ! path_authorize "$entry" > /dev/null; then
      verbose "refused ($PATH_DENY_REASON), kept: $entry"
      continue
    fi
    is_whitelisted "$PATH_CANONICAL" && { verbose "whitelisted, kept: $entry"; continue; }
    n=$((n + 1))
    kb="$(dir_size_kb "$entry")"
    if quarantine_target "$act_id-$n" "$cat" "$entry" "" "$((kb * 1024))"; then
      QUARANTINE_DIR_KB=$((QUARANTINE_DIR_KB + kb))
    else
      failed=$((failed + 1))
    fi
  done
  [ "$failed" = 0 ]
}

# Put one quarantined object back. The source is always a direct child of its
# run directory, whatever path the manifest spells.
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
  if ! path_authorize "$orig_path" > /dev/null 2>&1 &&
     ! uninstall_authorize_bundle "$orig_path" > /dev/null 2>&1; then
    err "quarantine restore: destination outside authorized roots: $orig_path"
    return 1
  fi

  local cur_ident
  cur_ident="$(path_identity "$q_path" 2>/dev/null || echo "")"
  if [ -n "$expected_ident" ] && [ "$expected_ident" != "unknown" ] && [ "$cur_ident" != "$expected_ident" ]; then
    warn "quarantine restore: quarantined object identity changed: $q_path"
    return 1
  fi

  local orig_dir src_dev dst_dev
  orig_dir="$(dirname "$orig_path")"
  mkdir -p "$orig_dir" || return 1
  src_dev="$(file_device "$q_path" 2>/dev/null || echo 0)"
  dst_dev="$(file_device "$orig_dir" 2>/dev/null || echo 0)"

  if [ "$src_dev" = "$dst_dev" ] && [ "$src_dev" != "0" ]; then
    mv "$q_path" "$orig_path" 2>>"$LOG_FILE" || return 1
  else
    if ! cp -pPR "$q_path" "$orig_path" 2>>"$LOG_FILE" ||
       [ "$(_tree_signature "$q_path")" != "$(_tree_signature "$orig_path")" ]; then
      fs_remove "$orig_path"
      return 1
    fi
    fs_remove "$q_path" || warn "restored, but the quarantined copy could not be removed: $q_path"
  fi
  [ -e "$orig_path" ] || [ -L "$orig_path" ]
}

# One JSON string field of a manifest line written by us, unescaped. Fails
# when the key is absent.
_manifest_field() {
  local line="$1" key="$2" rest raw="" ch esc=0
  rest="${line#*\""${key}"\":\"}"
  [ "$rest" != "$line" ] || return 1
  while [ -n "$rest" ]; do
    ch="${rest:0:1}"
    rest="${rest:1}"
    if [ "$esc" = 1 ]; then
      raw="$raw$ch"
      esc=0
    elif [ "$ch" = "\\" ]; then
      raw="$raw$ch"
      esc=1
    elif [ "$ch" = '"' ]; then
      json_unescape_to raw "$raw"
      printf '%s' "$raw"
      return 0
    else
      raw="$raw$ch"
    fi
  done
  return 1
}

quarantine_restore_run() {
  local run_id="$1"
  local run_dir
  run_dir="$(quarantine_run_dir "$run_id")" || {
    err "quarantine restore: invalid run id: $run_id"
    return 1
  }

  local manifest="$run_dir/manifest.jsonl"
  if [ ! -f "$manifest" ]; then
    err "quarantine restore: manifest missing in $run_dir"
    return 1
  fi

  local line restored=0 failed=0 already=0 conflicts=0 agents=0 bundles=0
  local act_id orig_path q_path ident now_ident
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    orig_path="$(_manifest_field "$line" original_path || true)"
    q_path="$(_manifest_field "$line" quarantine_path || true)"
    ident="$(_manifest_field "$line" identity || true)"
    act_id="$(_manifest_field "$line" action_id || true)"

    if [ -z "$orig_path" ] || [ -z "$q_path" ] || [ -z "$ident" ] || [ "$ident" = "unknown" ]; then
      warn "quarantine restore: manifest line is missing a path or an identity; skipped"
      failed=$((failed + 1))
      continue
    fi
    # The source is the direct child of this run with the manifest's file
    # name, wherever the manifest says it was: a manifest cannot point a
    # restore at any other file, and a run moved with the quarantine root
    # still restores.
    q_path="$run_dir/${q_path##*/}"
    case "${q_path##*/}" in
      "" | . | ..)
        warn "quarantine restore: manifest line names no quarantined file; skipped"
        failed=$((failed + 1))
        continue
        ;;
    esac

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
  local run_dir
  run_dir="$(quarantine_run_dir "$run_id")" || {
    err "quarantine purge: invalid run id: $run_id"
    return 1
  }

  if ! fs_remove "$run_dir"; then
    err "quarantine purge: failed to purge run directory: $run_dir"
    return 1
  fi
  ok "purged quarantine run: $run_id"
  return 0
}

# Release runs older than QUARANTINE_KEEP_DAYS (0 keeps them forever). Called
# at the start of every run that quarantines, so the quarantine behaves like a
# trash with a retention period instead of growing until someone purges it.
quarantine_expire_runs() {
  local days="${QUARANTINE_KEEP_DAYS:-7}" d n=0 kb=0 k
  [ "$days" -gt 0 ] 2>/dev/null || return 0
  [ -d "$QUARANTINE_DIR" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] && [ ! -L "$d" ] || continue
    mimi_id_ok "${d##*/}" || continue
    k="$(dir_size_kb "$d")"
    if fs_remove "$d"; then
      n=$((n + 1))
      kb=$((kb + k))
      history_record "expire" "ok" "run_id=${d##*/}" "size_kb=$k"
    fi
  done < <(find "$QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null)
  [ "$n" -gt 0 ] && info "released $n quarantine run(s) older than $days day(s) ($(human_kb "$kb"))"
  return 0
}

# ---------------------------------------------------------------------------
# mimi history
# ---------------------------------------------------------------------------
#
# What mimi has done (HISTORY_FILE) and what can still be undone (user-scope
# quarantine runs). Read-only. --limit N (default 20) caps the records shown.

_history_value() {
  # $1 = JSON line, $2 = key. Top-level string or number; empty when absent.
  local line="$1" key="$2" v
  v="$(printf '%s' "$line" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\\1/p")"
  [ -n "$v" ] || v="$(printf '%s' "$line" | sed -n "s/.*\"$key\":\([0-9][0-9]*\).*/\\1/p")"
  printf '%s' "$v"
}

# The log file name to put in a history record: the transcript of this run,
# or nothing when --no-log keeps no transcript.
history_log_name() {
  [ "$NO_LOG" = 1 ] && return 0
  case "${LOG_FILE:-}" in "$LOG_DIR"/*) printf '%s' "${LOG_FILE##*/}" ;; esac
}

# Files mimi itself writes to LOG_DIR: run transcripts and orphan review
# files. Only these are listed by `history`, and only these can be cleared.
history_log_files() {
  local f
  for f in "$LOG_DIR"/clean-*.log "$LOG_DIR"/orphans-review-*.txt; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
}

_history_log_name_ok() {
  case "$1" in
    '' | */* | .*) return 1 ;;
    clean-*.log | orphans-review-*.txt) ;;
    *) return 1 ;;
  esac
  [ -f "$LOG_DIR/$1" ] && [ ! -L "$LOG_DIR/$1" ]
}

# The last LIMIT records as JSON objects, each with an "id" added in front:
# "r<line>@<at>". Deleting by id checks both, so a line that moved or changed
# since it was listed is never removed by mistake.
_history_records_json() {
  local limit="$1" total start
  [ -f "$HISTORY_FILE" ] || return 0
  total="$(awk 'END { print NR }' "$HISTORY_FILE")"
  start=$((total - limit))
  [ "$start" -lt 0 ] && start=0
  awk -v start="$start" '
    NR > start && /^\{".*\}$/ {
      at = ""
      if (match($0, /"at":"[^"]*"/)) at = substr($0, RSTART + 6, RLENGTH - 7)
      printf "%s\n    {\"id\":\"r%d@%s\",%s", (n++ ? "," : ""), NR, at, substr($0, 2)
    }
    END { if (n) printf "\n  " }' "$HISTORY_FILE"
}

_history_logs_json() {
  local name first=1 kb mtime
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    kb="$(dir_size_kb "$LOG_DIR/$name")"
    mtime="$(file_mtime "$LOG_DIR/$name" 2>/dev/null)"
    [ "$first" = 1 ] || printf ','
    first=0
    printf '\n    {"name": "%s", "size_kb": %d, "modified": "%s"}' \
      "$(json_escape "$name")" "${kb:-0}" \
      "$(epoch_format "${mtime:-0}" '+%Y-%m-%dT%H:%M:%SZ' -u 2>/dev/null)"
  done < <(history_log_files)
  [ "$first" = 1 ] || printf '\n  '
}

mimi_history() {
  local limit="${HISTORY_LIMIT:-20}" line d n items kb restored first

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '{\n  "schema": "mimi.history/2",\n  "records": ['
    _history_records_json "$limit"
    printf '],\n  "quarantine_runs": ['
    first=1
    for d in "$QUARANTINE_DIR"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      items="$(grep -c . "$d/manifest.jsonl" 2>/dev/null)"
      restored="$(grep -c '"status":"restored"' "$d/restore.jsonl" 2>/dev/null)"
      kb="$(dir_size_kb "$d")"
      [ "$first" = 1 ] || printf ','
      first=0
      printf '\n    {"run_id": "%s", "items": %d, "restored": %d, "size_kb": %d}' \
        "$(json_escape "$(basename "$d")")" "${items:-0}" "${restored:-0}" "${kb:-0}"
    done
    [ "$first" = 1 ] || printf '\n  '
    printf '],\n  "logs": ['
    _history_logs_json
    printf ']\n}\n'
    return 0
  fi

  say "${C_BOLD}History${C_RESET} (last $limit, from $HISTORY_FILE)"
  if [ ! -s "$HISTORY_FILE" ]; then
    say "  (nothing recorded yet)"
  else
    n=0
    while IFS= read -r line; do
      case "$line" in '{'*'}') ;; *) continue ;; esac
      n=$((n + 1))
      local what
      what="$(_history_value "$line" app)"
      [ -n "$what" ] || what="$(_history_value "$line" bundle_id)"
      [ -n "$what" ] || what="$(_history_value "$line" token)"
      [ -n "$what" ] || what="$(_history_value "$line" plan_id)"
      printf '  %-20s  %-18s  %-10s  %s %s\n' \
        "$(_history_value "$line" at)" "$(_history_value "$line" type)" \
        "$(_history_value "$line" status)" "$what" \
        "$(r="$(_history_value "$line" run_id)"; [ -n "$r" ] && printf '(run %s)' "$r")"
    done < <(tail -n "$limit" "$HISTORY_FILE")
  fi

  say ""
  say "${C_BOLD}Quarantine runs${C_RESET} (restorable until purged, in $QUARANTINE_DIR)"
  n=0
  for d in "$QUARANTINE_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    n=$((n + 1))
    items="$(grep -c . "$d/manifest.jsonl" 2>/dev/null)"
    restored="$(grep -c '"status":"restored"' "$d/restore.jsonl" 2>/dev/null)"
    printf '  %-40s  %4d item(s)  %9s' "$(basename "$d")" "${items:-0}" "$(human_kb "$(dir_size_kb "$d")")"
    [ "${restored:-0}" -gt 0 ] && printf '  (%d restored)' "$restored"
    printf '\n'
  done
  [ "$n" -gt 0 ] || say "  (none)"
  if [ "$n" -gt 0 ]; then
    say ""
    say "Undo one:            $SCRIPT_NAME restore <run-id>"
    say "Release its space:   $SCRIPT_NAME purge <run-id>"
  fi

  say ""
  n=0 kb=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    kb=$((kb + $(dir_size_kb "$LOG_DIR/$line")))
  done < <(history_log_files)
  say "${C_BOLD}Logs${C_RESET}: $n file(s), $(human_kb "$kb"), in $LOG_DIR"
  if [ -s "$HISTORY_FILE" ] || [ "$n" -gt 0 ]; then
    say "Clear history and logs: $SCRIPT_NAME history clear --all"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# history clear
#
#   mimi history clear --all                  every record and every log file
#   mimi history clear --records ID,... --logs NAME,...
#
# Only mimi's own bookkeeping goes: records in history.jsonl and the files
# history_log_files lists. Quarantine runs are not touched (`mimi purge`
# releases those), and neither is anything the records point at.
# ---------------------------------------------------------------------------

HISTORY_CLEAR_ALL=0
HISTORY_CLEAR_RECORDS=""
HISTORY_CLEAR_LOGS=""

# Rewrites HISTORY_FILE without the records whose id is in IDS (comma list).
# Prints how many were removed.
_history_drop_records() {
  local ids="$1" tmp removed
  [ -s "$HISTORY_FILE" ] || { printf '0'; return 0; }
  tmp="$(mktemp "$HISTORY_FILE.XXXXXX")" || return 1
  removed="$(awk -v ids=",$ids," -v out="$tmp" '
    {
      at = ""
      if (match($0, /"at":"[^"]*"/)) at = substr($0, RSTART + 6, RLENGTH - 7)
      if (index(ids, ",r" NR "@" at ",")) { n++; next }
      print > out
    }
    END { close(out); print n + 0 }' "$HISTORY_FILE")"
  : >> "$tmp"
  chmod 600 "$tmp" 2>/dev/null
  if ! mv -f "$tmp" "$HISTORY_FILE"; then
    # Justified raw rm: our own half-written temporary copy of the history.
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "${removed:-0}"
}

mimi_history_clear() {
  local records=0 logs=0 missing=0 name n rc=0
  local -a log_names=()

  if [ "$HISTORY_CLEAR_ALL" = 1 ]; then
    [ -z "$HISTORY_CLEAR_RECORDS$HISTORY_CLEAR_LOGS" ] \
      || die_usage "history clear: --all already covers --records and --logs"
    while IFS= read -r name; do
      [ -n "$name" ] && log_names+=("$name")
    done < <(history_log_files)
  else
    [ -n "$HISTORY_CLEAR_RECORDS$HISTORY_CLEAR_LOGS" ] \
      || die_usage "history clear needs --all, or --records and/or --logs"
    local IFS=,
    for name in $HISTORY_CLEAR_LOGS; do
      [ -n "$name" ] && log_names+=("$name")
    done
    unset IFS
  fi

  run_lock || return "$EXIT_BUSY"
  # No transcript for this command, but the lock must still be released.
  install_exit_trap

  local what
  if [ "$HISTORY_CLEAR_ALL" = 1 ]; then
    n=0
    [ -s "$HISTORY_FILE" ] && n="$(grep -c . "$HISTORY_FILE" 2>/dev/null)"
    what="all ${n:-0} history record(s) and ${#log_names[@]} log file(s)"
  else
    n=0
    [ -n "$HISTORY_CLEAR_RECORDS" ] && n="$(printf '%s' "$HISTORY_CLEAR_RECORDS" | tr ',' '\n' | grep -c .)"
    what="$n history record(s) and ${#log_names[@]} log file(s)"
  fi
  if [ "${JSONL_ENABLED:-0}" != 1 ]; then
    say "Delete $what from $CONFIG_DIR and $LOG_DIR?"
    say "Quarantine runs are kept; release them with: $SCRIPT_NAME purge <run-id>"
  fi
  if ! confirm "Delete $what?"; then
    [ "${JSONL_ENABLED:-0}" = 1 ] || say "Cancelled. Nothing was deleted."
    return "$EXIT_CANCELLED"
  fi

  if [ "$HISTORY_CLEAR_ALL" = 1 ]; then
    if [ -s "$HISTORY_FILE" ]; then
      records="$(grep -c . "$HISTORY_FILE" 2>/dev/null)"
      : > "$HISTORY_FILE" || rc="$EXIT_FAILURE"
    fi
  elif [ -n "$HISTORY_CLEAR_RECORDS" ]; then
    records="$(_history_drop_records "$HISTORY_CLEAR_RECORDS")" || { records=0; rc="$EXIT_FAILURE"; }
    local asked
    asked="$(printf '%s' "$HISTORY_CLEAR_RECORDS" | tr ',' '\n' | grep -c .)"
    missing=$((missing + asked - records))
  fi

  for name in "${log_names[@]}"; do
    if ! _history_log_name_ok "$name"; then
      missing=$((missing + 1))
      continue
    fi
    # Justified raw rm: this is the tool's own transcript housekeeping, a
    # log file mimi wrote into its own LOG_DIR, checked by name and type.
    if rm -f -- "$LOG_DIR/$name"; then
      logs=$((logs + 1))
    else
      rc="$EXIT_PARTIAL"
    fi
  done

  if [ "${JSONL_ENABLED:-0}" = 1 ]; then
    printf '{\n  "schema": "mimi.history-clear/1",\n  "records_removed": %d,\n  "logs_removed": %d,\n  "not_found": %d\n}\n' \
      "${records:-0}" "$logs" "$missing"
  else
    ok "Deleted ${records:-0} history record(s) and $logs log file(s)."
    [ "$missing" -gt 0 ] && warn "$missing item(s) were not found (already gone, or changed since they were listed)"
  fi
  [ "$rc" = 0 ] && [ "$missing" -gt 0 ] && rc="$EXIT_PARTIAL"
  return "$rc"
}
