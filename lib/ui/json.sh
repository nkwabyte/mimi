#!/usr/bin/env bash
#
# lib/ui/json.sh lib/json.sh — Pure Bash 3.2 JSON Lines protocol serialization (P1-T06).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# constants only. Emits strict JSON Lines conforming to schemas/protocol-v1.json.

MIMI_VERSION="0.2.0"
PROTOCOL_VERSION=1
PLAN_SCHEMA_VERSION=1

JSONL_ENABLED=0
JSON_SEQ=0
JSON_REQ_ID=""
CURRENT_CATEGORY_ID=""

json_escape() {
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}

json_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}

json_emit() {
  [ "$JSONL_ENABLED" = 1 ] || return 0
  local type="$1" payload="${2:-}"
  JSON_SEQ=$((JSON_SEQ + 1))
  local req_id="${JSON_REQ_ID:-mimi-${TIMESTAMP:-0}}"
  local ts
  ts="$(json_now_iso)"
  if [ -n "$payload" ]; then
    printf '{"type":"%s","seq":%d,"request_id":"%s","timestamp":"%s",%s}\n' \
      "$type" "$JSON_SEQ" "$(json_escape "$req_id")" "$ts" "$payload"
  else
    printf '{"type":"%s","seq":%d,"request_id":"%s","timestamp":"%s"}\n' \
      "$type" "$JSON_SEQ" "$(json_escape "$req_id")" "$ts"
  fi
}

json_emit_hello() {
  local payload
  payload=$(printf '"protocol_version":%d,"engine_version":"%s","plan_schema_version":%d,"capabilities":["scan","clean","report","profile","config"]' \
    "$PROTOCOL_VERSION" "$(json_escape "$MIMI_VERSION")" "$PLAN_SCHEMA_VERSION")
  json_emit "hello" "$payload"
}

json_emit_phase_started() {
  local phase="$1"
  json_emit "phase_started" "\"phase\":\"$(json_escape "$phase")\""
}

json_emit_phase_finished() {
  local phase="$1" status="${2:-ok}"
  json_emit "phase_finished" "\"phase\":\"$(json_escape "$phase")\",\"status\":\"$(json_escape "$status")\""
}

json_emit_candidate() {
  local cat="$1" path="$2" size_kb="${3:-0}" risk="${4:-safe}" cid="${5:-}"
  local p
  if [ -n "$cid" ]; then
    p=$(printf '"candidate_id":"%s","category":"%s","path":"%s","size_kb":%d,"risk":"%s"' \
      "$(json_escape "$cid")" "$(json_escape "$cat")" "$(json_escape "$path")" "$size_kb" "$(json_escape "$risk")")
  else
    p=$(printf '"category":"%s","path":"%s","size_kb":%d,"risk":"%s"' \
      "$(json_escape "$cat")" "$(json_escape "$path")" "$size_kb" "$(json_escape "$risk")")
  fi
  json_emit "candidate" "$p"
}

json_emit_action_result() {
  local status="$1" path="$2" bytes="${3:-0}"
  local p
  p=$(printf '"status":"%s","path":"%s","bytes_reclaimed":%d' \
    "$(json_escape "$status")" "$(json_escape "$path")" "$bytes")
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
  p=$(printf '"status":"%s","exit_code":%d,"reclaimed_kb":%d,"scanned_kb":%d,"actions_ok":%d,"actions_skipped":%d,"actions_denied":%d,"actions_failed":%d' \
    "$(json_escape "$status")" "$exit_code" "$reclaimed_kb" "$scanned_kb" "$ok_cnt" "$skip_cnt" "$denied_cnt" "$fail_cnt")
  json_emit "run_finished" "$p"
}
