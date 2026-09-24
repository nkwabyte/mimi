#!/usr/bin/env bash
#
# lib/transaction/plan.sh lib/plan.sh — Transactional execution plan model and serialization (Phase 2).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# plan state helpers conforming to schemas/plan-v1.json.

PLAN_SCHEMA_VERSION=1
PLAN_ID=""
PLAN_CREATED_AT=""
PLAN_EXPIRES_AT=""
PLAN_HOSTNAME=""
PLAN_USER=""
PLAN_ACTIONS=()
PLAN_CANDIDATES=()

plan_init() {
  local custom_id="${1:-}"
  if [ -n "$custom_id" ]; then
    PLAN_ID="$custom_id"
  else
    PLAN_ID="plan-$(date +%Y%m%d-%H%M%S)-$$"
  fi
  PLAN_CREATED_AT="$(json_now_iso)"
  # Default expiry: 24 hours (86400 seconds)
  local now_ts
  now_ts="$(date +%s 2>/dev/null || echo 0)"
  local exp_ts=$((now_ts + 86400))
  PLAN_EXPIRES_AT="$(date -u -r "$exp_ts" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$PLAN_CREATED_AT")"
  PLAN_HOSTNAME="$(hostname 2>/dev/null || echo "localhost")"
  PLAN_USER="${USER:-$(id -un 2>/dev/null || echo "user")}"
  PLAN_ACTIONS=()
}

plan_candidate_id() {
  local cat="$1" target="$2"
  local raw="${cat}:${target}"
  if command -v shasum >/dev/null 2>&1; then
    printf 'cand-%s' "$(printf '%s' "$raw" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'cand-%s' "$(printf '%s' "$raw" | cksum | awk '{print $1}')"
  fi
}

plan_candidate_add() {
  local cat="$1" op="$2" p="$3" ident="$4" bytes="${5:-0}" risk="${6:-safe}" evid="${7:-}"
  local cid
  cid="$(plan_candidate_id "$cat" "$p")"
  PLAN_CANDIDATES+=("${cid}::${cat}::${op}::${p}::${ident}::${bytes}::${risk}::${evid}")
}

plan_candidate_count() {
  echo "${#PLAN_CANDIDATES[@]}"
}

plan_build() {
  local selected_cids="${1:-}"
  plan_init "${2:-}"

  local item cid cat op p ident bytes risk evid act_id
  for item in "${PLAN_CANDIDATES[@]}"; do
    cid="${item%%::*}"
    if [ -n "$selected_cids" ]; then
      case ",${selected_cids}," in
        *",${cid},"*) ;;
        *) continue ;;
      esac
    fi
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    p="${item#*::*::*::}"; p="${p%%::*}"
    ident="${item#*::*::*::*::}"; ident="${ident%%::*}"
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    evid="${item##*::}"

    act_id="$(printf 'act-%04d' "$(( ${#PLAN_ACTIONS[@]} + 1 ))")"
    plan_add_action "$act_id" "$cat" "$op" "$p" "$ident" "$bytes" "$risk" "$evid"
  done
}

plan_add_action() {
  local action_id="$1" category="$2" operation="$3" target_path="$4" target_identity="$5" expected_bytes="${6:-0}" risk="${7:-safe}" evidence="${8:-}"
  PLAN_ACTIONS+=("${action_id}::${category}::${operation}::${target_path}::${target_identity}::${expected_bytes}::${risk}::${evidence}")
}

plan_compute_digest() {
  local input=""
  local item
  for item in "${PLAN_ACTIONS[@]}"; do
    input="${input}${item}
"
  done
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$input" | cksum | awk '{print $1}'
  fi
}

plan_serialize() {
  local digest
  digest="$(plan_compute_digest)"
  local total_bytes=0
  local count="${#PLAN_ACTIONS[@]}"
  local safe_cnt=0 mod_cnt=0 risky_cnt=0 irr_cnt=0

  local item act_id cat op p ident bytes risk evid
  for item in "${PLAN_ACTIONS[@]}"; do
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    total_bytes=$((total_bytes + bytes))
    case "$risk" in
      safe) safe_cnt=$((safe_cnt + 1)) ;;
      moderate) mod_cnt=$((mod_cnt + 1)) ;;
      risky) risky_cnt=$((risky_cnt + 1)) ;;
      irreversible) irr_cnt=$((irr_cnt + 1)) ;;
    esac
  done

  printf '{\n'
  printf '  "schema_version": %d,\n' "$PLAN_SCHEMA_VERSION"
  printf '  "plan_id": "%s",\n' "$(json_escape "$PLAN_ID")"
  printf '  "created_at": "%s",\n' "$(json_escape "$PLAN_CREATED_AT")"
  printf '  "expires_at": "%s",\n' "$(json_escape "$PLAN_EXPIRES_AT")"
  printf '  "host_binding": {\n'
  printf '    "hostname": "%s",\n' "$(json_escape "$PLAN_HOSTNAME")"
  printf '    "user": "%s",\n' "$(json_escape "$PLAN_USER")"
  printf '    "uid": %d\n' "$(id -u 2>/dev/null || echo 0)"
  printf '  },\n'
  printf '  "digest": "%s",\n' "$digest"
  printf '  "summary": {\n'
  printf '    "total_candidates": %d,\n' "$count"
  printf '    "total_bytes": %d,\n' "$total_bytes"
  printf '    "risk_distribution": {\n'
  printf '      "safe": %d,\n' "$safe_cnt"
  printf '      "moderate": %d,\n' "$mod_cnt"
  printf '      "risky": %d,\n' "$risky_cnt"
  printf '      "irreversible": %d\n' "$irr_cnt"
  printf '    }\n'
  printf '  },\n'
  printf '  "actions": [\n'

  local i=0
  for item in "${PLAN_ACTIONS[@]}"; do
    act_id="${item%%::*}"
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    p="${item#*::*::*::}"; p="${p%%::*}"
    ident="${item#*::*::*::*::}"; ident="${ident%%::*}"
    bytes="${item#*::*::*::*::*::}"; bytes="${bytes%%::*}"
    risk="${item#*::*::*::*::*::*::}"; risk="${risk%%::*}"
    evid="${item##*::}"

    i=$((i + 1))
    printf '    {\n'
    printf '      "action_id": "%s",\n' "$(json_escape "$act_id")"
    printf '      "category": "%s",\n' "$(json_escape "$cat")"
    printf '      "operation": "%s",\n' "$(json_escape "$op")"
    printf '      "target_path": "%s",\n' "$(json_escape "$p")"
    printf '      "target_identity": "%s",\n' "$(json_escape "$ident")"
    printf '      "expected_bytes": %d,\n' "$bytes"
    printf '      "risk": "%s",\n' "$(json_escape "$risk")"
    printf '      "evidence": "%s"\n' "$(json_escape "$evid")"
    if [ "$i" -lt "$count" ]; then
      printf '    },\n'
    else
      printf '    }\n'
    fi
  done

  printf '  ]\n'
  printf '}\n'
}

plan_save() {
  local target_file="$1"
  local dir
  dir="$(dirname "$target_file")"
  mkdir -p "$dir" || return 1
  local tmp
  tmp="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! plan_serialize > "$tmp"; then
    : > "$tmp"
    return 1
  fi
  mv -f "$tmp" "$target_file"
}

plan_load() {
  local file="$1"
  [ -f "$file" ] && [ -r "$file" ] || return 1
  PLAN_ACTIONS=()
  local in_actions=0 in_action=0
  local line act_id="" cat="" op="" p="" ident="" bytes=0 risk="safe" evid=""
  local cur_schema=0 cur_id="" cur_created="" cur_expires="" cur_host="" cur_user="" cur_digest=""

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[! ]*}"}"
    line="${line%"${line##*[! ]}"}"
    case "$line" in
      '"schema_version":'*)
        cur_schema="${line#*:}"
        cur_schema="${cur_schema%,}"
        cur_schema="${cur_schema// /}"
        ;;
      '"plan_id":'*)
        cur_id="${line#*: \"}"
        cur_id="${cur_id%\"*}"
        ;;
      '"created_at":'*)
        cur_created="${line#*: \"}"
        cur_created="${cur_created%\"*}"
        ;;
      '"expires_at":'*)
        cur_expires="${line#*: \"}"
        cur_expires="${cur_expires%\"*}"
        ;;
      '"hostname":'*)
        cur_host="${line#*: \"}"
        cur_host="${cur_host%\"*}"
        ;;
      '"user":'*)
        cur_user="${line#*: \"}"
        cur_user="${cur_user%\"*}"
        ;;
      '"digest":'*)
        cur_digest="${line#*: \"}"
        cur_digest="${cur_digest%\"*}"
        ;;
      '"actions": ['*)
        in_actions=1
        ;;
      '{'*)
        if [ "$in_actions" = 1 ]; then
          in_action=1
          act_id="" cat="" op="" p="" ident="" bytes=0 risk="safe" evid=""
        fi
        ;;
      '"action_id":'*)
        act_id="${line#*: \"}"; act_id="${act_id%\"*}" ;;
      '"category":'*)
        cat="${line#*: \"}"; cat="${cat%\"*}" ;;
      '"operation":'*)
        op="${line#*: \"}"; op="${op%\"*}" ;;
      '"target_path":'*)
        p="${line#*: \"}"; p="${p%\"*}" ;;
      '"target_identity":'*)
        ident="${line#*: \"}"; ident="${ident%\"*}" ;;
      '"expected_bytes":'*)
        bytes="${line#*:}"; bytes="${bytes%,}"; bytes="${bytes// /}" ;;
      '"risk":'*)
        risk="${line#*: \"}"; risk="${risk%\"*}" ;;
      '"evidence":'*)
        evid="${line#*: \"}"; evid="${evid%\"*}" ;;
      '}'*|'},'*)
        if [ "$in_action" = 1 ]; then
          if [ -n "$act_id" ]; then
            PLAN_ACTIONS+=("${act_id}::${cat}::${op}::${p}::${ident}::${bytes}::${risk}::${evid}")
          fi
          in_action=0
        fi
        ;;
      ']'*)
        in_actions=0
        ;;
    esac
  done < "$file"

  PLAN_SCHEMA_VERSION="$cur_schema"
  PLAN_ID="$cur_id"
  PLAN_CREATED_AT="$cur_created"
  PLAN_EXPIRES_AT="$cur_expires"
  PLAN_HOSTNAME="$cur_host"
  PLAN_USER="$cur_user"
  PLAN_DIGEST="$cur_digest"
  return 0
}

plan_validate_schema() {
  local file="$1"
  plan_load "$file" || return 1
  [ "$PLAN_SCHEMA_VERSION" = "1" ] || return 1
}

plan_preflight() {
  local plan_file="$1"
  if [ ! -f "$plan_file" ] || [ ! -r "$plan_file" ]; then
    err "plan preflight: plan file missing or unreadable: $plan_file"
    return 1
  fi

  if ! plan_load "$plan_file"; then
    err "plan preflight: failed to parse plan file: $plan_file"
    return 1
  fi

  # 1. Schema version check
  if [ "$PLAN_SCHEMA_VERSION" != "1" ]; then
    err "plan preflight: unsupported plan schema version: $PLAN_SCHEMA_VERSION"
    return 1
  fi

  # 2. Host binding check
  local current_user
  current_user="${USER:-$(id -un 2>/dev/null || echo "user")}"
  if [ "$PLAN_USER" != "$current_user" ]; then
    err "plan preflight: user mismatch (plan created for user '$PLAN_USER', running as '$current_user')"
    return 1
  fi

  # 3. Expiry check (ISO 8601 lexicographical comparison)
  local now_iso
  now_iso="$(json_now_iso)"
  if [ -n "$PLAN_EXPIRES_AT" ] && [ "$now_iso" \> "$PLAN_EXPIRES_AT" ]; then
    err "plan preflight: plan expired at $PLAN_EXPIRES_AT (current time: $now_iso)"
    return 1
  fi

  # 4. Digest verification
  local computed_digest
  computed_digest="$(plan_compute_digest)"
  if [ "$computed_digest" != "$PLAN_DIGEST" ]; then
    err "plan preflight: plan digest mismatch: plan file has been tampered with or corrupted"
    return 1
  fi

  # 5. Target validations (containment, identity, whitelist)
  local item act_id cat op p ident bytes risk evid
  local cur_ident canon
  for item in "${PLAN_ACTIONS[@]}"; do
    act_id="${item%%::*}"
    cat="${item#*::}"; cat="${cat%%::*}"
    op="${item#*::*::}"; op="${op%%::*}"
    p="${item#*::*::*::}"; p="${p%%::*}"
    ident="${item#*::*::*::*::}"; ident="${ident%%::*}"

    # Operation tool_cleanup might not have a target_path
    [ -z "$p" ] && continue

    if ! canon="$(path_authorize "$p")"; then
      err "plan preflight: target outside authorized roots: $p ($(path_deny_message))"
      return 1
    fi

    if is_whitelisted "$canon"; then
      warn "plan preflight: target is whitelisted: $p"
    fi

    # Target identity check
    if [ -e "$canon" ] || [ -L "$canon" ]; then
      cur_ident="$(path_identity "$canon" 2>/dev/null || echo "")"
      if [ -n "$ident" ] && [ "$ident" != "unknown" ] && [ "$cur_ident" != "$ident" ]; then
        err "plan preflight: target object changed since plan creation: $p"
        return 1
      fi
    else
      # Target was expected to exist with an identity
      if [ -n "$ident" ] && [ "$ident" != "unknown" ]; then
        err "plan preflight: target object missing since plan creation: $p"
        return 1
      fi
    fi
  done

  return 0
}
