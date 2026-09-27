#!/usr/bin/env bash
#
# lib/ui/json.sh lib/json.sh — Pure Bash 3.2 JSON Lines protocol serialization (P1-T06).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# constants only. Emits strict JSON Lines conforming to schemas/protocol-v1.json.

PROTOCOL_VERSION=1

JSONL_ENABLED=0
JSON_SEQ=0
JSON_REQ_ID=""
CURRENT_CATEGORY_ID=""
CURRENT_CATEGORY_RISK=""

json_escape() {
  local __e
  json_escape_to __e "$1"
  printf '%s' "$__e"
}

# json_escape_to VAR STRING — json_escape without a subshell: sets VAR.
# Quote and backslash always; control characters take the slow path only
# when present: \n \r \t keep their short forms, every other one is \u00XX,
# so a file name holding ESC or 0x01 still produces valid JSON.
json_escape_to() {
  local __s="$2" __o="" __c __i __u
  __s="${__s//\\/\\\\}"
  __s="${__s//\"/\\\"}"
  case "$__s" in
    *[[:cntrl:]]*)
      for ((__i = 0; __i < ${#__s}; __i++)); do
        __c="${__s:__i:1}"
        case "$__c" in
          $'\n') __o="$__o\\n" ;;
          $'\r') __o="$__o\\r" ;;
          $'\t') __o="$__o\\t" ;;
          [[:cntrl:]]) printf -v __u '\\u%04x' "'$__c"; __o="$__o$__u" ;;
          *) __o="$__o$__c" ;;
        esac
      done
      __s="$__o"
      ;;
  esac
  printf -v "$1" '%s' "$__s"
}

# json_unescape_to VAR STRING — the inverse of json_escape_to, without a
# subshell. Used when reading a plan or manifest back, so a path survives the
# round trip exactly and a plan's digest is recomputed over the original.
json_unescape_to() {
  local __s="$2" __o="" __c __i=0 __n
  case "$__s" in
    *\\*) ;;
    *) printf -v "$1" '%s' "$__s"; return 0 ;;
  esac
  __n=${#__s}
  while [ "$__i" -lt "$__n" ]; do
    __c="${__s:__i:1}"
    if [ "$__c" = "\\" ]; then
      __i=$((__i + 1))
      __c="${__s:__i:1}"
      case "$__c" in
        n) __c=$'\n' ;;
        r) __c=$'\r' ;;
        t) __c=$'\t' ;;
        u)
          # shellcheck disable=SC2059  # the format IS the escape being decoded
          printf -v __c "\\x${__s:__i+3:2}"
          __i=$((__i + 4))
          ;;
      esac
    fi
    __o="$__o$__c"
    __i=$((__i + 1))
  done
  printf -v "$1" '%s' "$__o"
}

json_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# The event timestamp, re-read at most once a second: one `date` per event
# dominated long candidate streams.
_JSON_TS=""
_JSON_TS_SEC=-1
json_emit() {
  [ "$JSONL_ENABLED" = 1 ] || return 0
  local type="$1" payload="${2:-}" req
  JSON_SEQ=$((JSON_SEQ + 1))
  if [ "$SECONDS" != "$_JSON_TS_SEC" ]; then
    _JSON_TS="$(json_now_iso)"
    _JSON_TS_SEC="$SECONDS"
  fi
  json_escape_to req "${JSON_REQ_ID:-mimi-${TIMESTAMP:-0}}"
  printf '{"type":"%s","seq":%d,"request_id":"%s","timestamp":"%s"%s}\n' \
    "$type" "$JSON_SEQ" "$req" "$_JSON_TS" "${payload:+,$payload}"
}

json_emit_hello() {
  local payload
  payload=$(printf '"protocol_version":%d,"engine_version":"%s","plan_schema_version":%d,"capabilities":["scan","clean","report","profile","config"]' \
    "$PROTOCOL_VERSION" "$(json_escape "$MIMI_VERSION")" "$PLAN_SCHEMA_VERSION")
  json_emit "hello" "$payload"
}

json_emit_phase_started() {
  json_emit "phase_started" "\"phase\":\"$1\""
}

json_emit_phase_finished() {
  json_emit "phase_finished" "\"phase\":\"$1\",\"status\":\"${2:-ok}\""
}

json_emit_candidate() {
  local cat="$1" path="$2" size_kb="${3:-0}" risk="${4:-safe}" cid="${5:-}" e_path p
  json_escape_to e_path "$path"
  printf -v p '"category":"%s","path":"%s","size_kb":%d,"risk":"%s"' "$cat" "$e_path" "$size_kb" "$risk"
  [ -n "$cid" ] && p="\"candidate_id\":\"$cid\",$p"
  json_emit "candidate" "$p"
}

json_emit_action_result() {
  local status="$1" path="$2" bytes="${3:-0}" e_path p
  json_escape_to e_path "$path"
  printf -v p '"status":"%s","path":"%s","bytes_reclaimed":%d' "$status" "$e_path" "$bytes"
  json_emit "action_result" "$p"
}

json_emit_warning() {
  local code="$1" msg="$2"
  local p
  p=$(printf '"code":"%s","message":"%s"' \
    "$(json_escape "$code")" "$(json_escape "$msg")")
  json_emit "warning" "$p"
}

json_emit_permission_required() {
  local perm="$1" msg="$2"
  local p
  p=$(printf '"permission":"%s","message":"%s"' \
    "$(json_escape "$perm")" "$(json_escape "$msg")")
  json_emit "permission_required" "$p"
}

json_emit_error() {
  local code="$1" msg="$2" detail="${3:-}"
  local p
  p=$(printf '"code":"%s","message":"%s","detail":"%s"' \
    "$(json_escape "$code")" "$(json_escape "$msg")" "$(json_escape "$detail")")
  json_emit "error" "$p"
}

json_emit_run_finished() {
  local status="$1" exit_code="$2" reclaimed_kb="$3" scanned_kb="$4" ok_cnt="$5" skip_cnt="$6" denied_cnt="$7" fail_cnt="$8"
  local p
  p=$(printf '"status":"%s","exit_code":%d,"reclaimed_kb":%d,"quarantined_kb":%d,"scanned_kb":%d,"actions_ok":%d,"actions_skipped":%d,"actions_denied":%d,"actions_failed":%d' \
    "$(json_escape "$status")" "$exit_code" "$reclaimed_kb" "${TOTAL_QUARANTINED_KB:-0}" "$scanned_kb" "$ok_cnt" "$skip_cnt" "$denied_cnt" "$fail_cnt")
  json_emit "run_finished" "$p"
}
