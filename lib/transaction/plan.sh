#!/usr/bin/env bash
#
# lib/transaction/plan.sh lib/plan.sh — Transactional execution plan model and serialization (Phase 2).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# plan state helpers conforming to schemas/plan-v1.json.

# 3: the digest covers the header (expiry, host, user, uid) as well as the
# actions, and apply re-derives every action (plan_verify_selection).
PLAN_SCHEMA_VERSION=3
PLAN_SCHEMA_SUPPORTED=3
PLAN_ID=""
PLAN_CREATED_AT=""
PLAN_EXPIRES_AT=""
PLAN_HOSTNAME=""
PLAN_USER=""
PLAN_UID=""
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
  PLAN_EXPIRES_AT="$(epoch_format "$exp_ts" +"%Y-%m-%dT%H:%M:%SZ" -u 2>/dev/null || echo "$PLAN_CREATED_AT")"
  PLAN_HOSTNAME="$(hostname 2>/dev/null || echo "localhost")"
  PLAN_USER="${USER:-$(id -un 2>/dev/null || echo "user")}"
  PLAN_UID="$(id -u 2>/dev/null || echo 0)"
  PLAN_ACTIONS=()
}

# Stable identifier for a candidate: "cand-" + 16 hex digits derived from the
# category and canonical path. It is an identifier, not an integrity check
# (the plan digest is SHA-256), so it uses the native md5 binary: shasum is a
# Perl script and cost ~10 ms per candidate, which dominated large scans.
plan_candidate_id() {
  local cat="$1" target="$2"
  local raw="${cat}:${target}" h=""
  if [ -x /sbin/md5 ]; then
    h="$(/sbin/md5 -q -s "$raw" 2>/dev/null)"
  elif command -v shasum >/dev/null 2>&1; then
    h="$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')"
  fi
  if [ -n "$h" ]; then
    printf 'cand-%s' "${h:0:16}"
  else
    printf 'cand-%s' "$(printf '%s' "$raw" | cksum | awk '{print $1}')"
  fi
}

# Candidate id of the most recent plan_candidate_add, so callers that also
# emit a JSON candidate event do not compute it a second time.
PLAN_LAST_CID=""

# Length-prefixed fields. A value may contain "::" or any other character;
# the length, not a separator, says where the next field starts.
plan_pack() {
  local out="" f
  for f in "$@"; do
    out="${out}${#f}:${f}"
  done
  printf '%s' "$out"
}

plan_unpack() {
  local s="$1" n
  PLAN_FIELDS=()
  while [ -n "$s" ]; do
    n="${s%%:*}"
    case "$n" in
      ""|*[!0-9]*) return 1 ;;
    esac
    s="${s#*:}"
    PLAN_FIELDS+=("${s:0:$n}")
    s="${s:$n}"
  done
  return 0
}

# Eight fields: id, category, operation, path, identity, bytes, risk, evidence.
plan_read_record() {
  plan_unpack "$1" || return 1
  [ "${#PLAN_FIELDS[@]}" -eq 8 ] || return 1
  PLAN_F_ID="${PLAN_FIELDS[0]}"
  PLAN_F_CAT="${PLAN_FIELDS[1]}"
  PLAN_F_OP="${PLAN_FIELDS[2]}"
  PLAN_F_PATH="${PLAN_FIELDS[3]}"
  PLAN_F_IDENT="${PLAN_FIELDS[4]}"
  PLAN_F_BYTES="${PLAN_FIELDS[5]}"
  PLAN_F_RISK="${PLAN_FIELDS[6]}"
  PLAN_F_EVID="${PLAN_FIELDS[7]}"
  return 0
}

plan_candidate_add() {
  local cat="$1" op="$2" p="$3" ident="$4" bytes="${5:-0}" risk="${6:-safe}" evid="${7:-}"
  PLAN_LAST_CID="$(plan_candidate_id "$cat" "$p")"
  PLAN_CANDIDATES+=("$(plan_pack "$PLAN_LAST_CID" "$cat" "$op" "$p" "$ident" "$bytes" "$risk" "$evid")")
}

# True when discovered candidates are needed: building a plan, or streaming
# candidate events. A plain human scan needs neither.
plan_candidates_wanted() {
  [ "$MODE" = "plan" ] || [ "${JSONL_ENABLED:-0}" = 1 ]
}

# A category whose cleanup is a delegated command (brew, npm, simctl, ...) has
# no path to plan. It is recorded once, as a whole-category tool_cleanup
# action; apply re-runs the category's own cleanup for it (plan_apply_tool).
#
#   plan_tool_candidate BYTES_KB
PLAN_TOOL_CATEGORIES=","
plan_tool_candidate() {
  local cat="${CURRENT_CATEGORY_ID:-}" kb="${1:-0}"
  [ -n "$cat" ] || return 0
  plan_candidates_wanted || return 0
  case "$PLAN_TOOL_CATEGORIES" in *",$cat,"*) return 0 ;; esac
  PLAN_TOOL_CATEGORIES="$PLAN_TOOL_CATEGORIES$cat,"
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  plan_candidate_add "$cat" "tool_cleanup" "" "" "$((kb * 1024))" "${CURRENT_CATEGORY_RISK:-safe}" "category cleanup command"
  [ "${JSONL_ENABLED:-0}" = 1 ] && json_emit_candidate "$cat" "" "$kb" "${CURRENT_CATEGORY_RISK:-safe}" "$PLAN_LAST_CID"
  return 0
}

plan_build() {
  local selected_cids="${1:-}"
  plan_init "${2:-}"

  local item cid cat op p ident bytes risk evid act_id
  for item in "${PLAN_CANDIDATES[@]}"; do
    plan_read_record "$item" || continue
    cid="$PLAN_F_ID"
    if [ -n "$selected_cids" ]; then
      case ",${selected_cids}," in
        *",${cid},"*) ;;
        *) continue ;;
      esac
    fi
    cat="$PLAN_F_CAT"
    op="$PLAN_F_OP"
    p="$PLAN_F_PATH"
    ident="$PLAN_F_IDENT"
    bytes="$PLAN_F_BYTES"
    risk="$PLAN_F_RISK"
    evid="$PLAN_F_EVID"

    printf -v act_id 'act-%04d' "$(( ${#PLAN_ACTIONS[@]} + 1 ))"
    plan_add_action "$act_id" "$cat" "$op" "$p" "$ident" "$bytes" "$risk" "$evid"
  done
}

plan_add_action() {
  local action_id="$1" category="$2" operation="$3" target_path="$4" target_identity="$5" expected_bytes="${6:-0}" risk="${7:-safe}" evidence="${8:-}"
  PLAN_ACTIONS+=("$(plan_pack "$action_id" "$category" "$operation" "$target_path" "$target_identity" "$expected_bytes" "$risk" "$evidence")")
}

# SHA-256 over the header fields and every packed action, one per line. It
# detects a plan that was edited or damaged; it is not a signature (anyone can
# recompute it). Authority comes from plan_verify_selection instead.
plan_compute_digest() {
  _plan_digest_input | {
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 | awk '{print $1}'
    else
      cksum | awk '{print $1}'
    fi
  }
}

_plan_digest_input() {
  plan_pack "$PLAN_SCHEMA_VERSION" "$PLAN_ID" "$PLAN_CREATED_AT" "$PLAN_EXPIRES_AT" \
    "$PLAN_HOSTNAME" "$PLAN_USER" "$PLAN_UID"
  printf '\n'
  [ "${#PLAN_ACTIONS[@]}" -gt 0 ] || return 0
  printf '%s\n' "${PLAN_ACTIONS[@]}"
}

plan_serialize() {
  local digest
  digest="$(plan_compute_digest)"
  local total_bytes=0
  local count="${#PLAN_ACTIONS[@]}"
  local safe_cnt=0 mod_cnt=0 risky_cnt=0 irr_cnt=0

  local item act_id cat op p ident bytes risk evid
  for item in "${PLAN_ACTIONS[@]}"; do
    plan_read_record "$item" || continue
    bytes="$PLAN_F_BYTES"
    risk="$PLAN_F_RISK"
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
  printf '    "uid": %d\n' "${PLAN_UID:-0}"
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
    plan_read_record "$item" || continue
    act_id="$PLAN_F_ID"
    cat="$PLAN_F_CAT"
    op="$PLAN_F_OP"
    p="$PLAN_F_PATH"
    ident="$PLAN_F_IDENT"
    bytes="$PLAN_F_BYTES"
    risk="$PLAN_F_RISK"
    evid="$PLAN_F_EVID"

    i=$((i + 1))
    local e_act e_cat e_op e_p e_ident e_risk e_evid
    json_escape_to e_act "$act_id"
    json_escape_to e_cat "$cat"
    json_escape_to e_op "$op"
    json_escape_to e_p "$p"
    json_escape_to e_ident "$ident"
    json_escape_to e_risk "$risk"
    json_escape_to e_evid "$evid"
    printf '    {\n'
    printf '      "action_id": "%s",\n' "$e_act"
    printf '      "category": "%s",\n' "$e_cat"
    printf '      "operation": "%s",\n' "$e_op"
    printf '      "target_path": "%s",\n' "$e_p"
    printf '      "target_identity": "%s",\n' "$e_ident"
    printf '      "expected_bytes": %d,\n' "$bytes"
    printf '      "risk": "%s",\n' "$e_risk"
    printf '      "evidence": "%s"\n' "$e_evid"
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
  local cur_schema=0 cur_id="" cur_created="" cur_expires="" cur_host="" cur_user="" cur_digest="" cur_uid="" cur_total=""

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
        if ! mimi_id_ok "$cur_id"; then
          err "plan_load: invalid plan_id: $cur_id"
          return 1
        fi
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
      '"uid":'*)
        cur_uid="${line#*:}"; cur_uid="${cur_uid%,}"; cur_uid="${cur_uid// /}"
        ;;
      '"total_candidates":'*)
        cur_total="${line#*:}"; cur_total="${cur_total%,}"; cur_total="${cur_total// /}"
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
        bytes="${line#*:}"; bytes="${bytes%,}"; bytes="${bytes// /}"
        case "$bytes" in *[!0-9]*|"") bytes=0 ;; esac
        ;;
      '"risk":'*)
        risk="${line#*: \"}"; risk="${risk%\"*}" ;;
      '"evidence":'*)
        evid="${line#*: \"}"; evid="${evid%\"*}" ;;
      '}'*)
        if [ "$in_action" = 1 ]; then
          if [ -n "$act_id" ]; then
            # Values were written JSON-escaped; restore the originals so the
            # recomputed digest matches (a path with " or \ used to fail).
            json_unescape_to act_id "$act_id"
            json_unescape_to cat "$cat"
            json_unescape_to op "$op"
            json_unescape_to p "$p"
            json_unescape_to ident "$ident"
            json_unescape_to risk "$risk"
            json_unescape_to evid "$evid"
            PLAN_ACTIONS+=("$(plan_pack "$act_id" "$cat" "$op" "$p" "$ident" "$bytes" "$risk" "$evid")")
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
  PLAN_UID="$cur_uid"
  PLAN_DIGEST="$cur_digest"
  # The reader expects the layout plan_serialize writes. A reformatted file
  # loses actions silently, so say that rather than report a bad digest.
  if [ -n "$cur_total" ] && [ "$cur_total" != "${#PLAN_ACTIONS[@]}" ]; then
    err "plan_load: $file is not in the layout mimi writes (was it reformatted?)"
    return 1
  fi
  return 0
}

# plan_preflight FILE [fresh]
#   fresh: the plan was built by this process a moment ago (app uninstall),
#          so re-deriving its selection would only repeat that work.
plan_preflight() {
  local plan_file="$1" fresh="${2:-}"
  if [ ! -f "$plan_file" ] || [ ! -r "$plan_file" ]; then
    err "plan preflight: plan file missing or unreadable: $plan_file"
    return 1
  fi

  if ! plan_load "$plan_file"; then
    err "plan preflight: failed to parse plan file: $plan_file"
    return 1
  fi

  # 1. Schema version check
  if [ "$PLAN_SCHEMA_VERSION" != "$PLAN_SCHEMA_SUPPORTED" ]; then
    err "plan preflight: unsupported plan schema version: $PLAN_SCHEMA_VERSION"
    return 1
  fi

  # 2. Host binding check
  local current_user
  current_user="${USER:-$(id -un 2>/dev/null || echo "user")}"
  if [ "$PLAN_USER" != "$current_user" ] || [ "$PLAN_UID" != "$(id -u 2>/dev/null)" ]; then
    err "plan preflight: user mismatch (plan created for user '$PLAN_USER', running as '$current_user')"
    return 1
  fi
  if [ "$PLAN_HOSTNAME" != "$(hostname 2>/dev/null || echo localhost)" ]; then
    err "plan preflight: the plan was made on another Mac ($PLAN_HOSTNAME)"
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
    err "plan preflight: digest mismatch: the plan file was edited or damaged after it was written"
    return 1
  fi

  # 5. Target validations (containment, identity, whitelist)
  local item act_id cat op p ident bytes risk evid
  case " ${PLAN_ACTIONS[*]:-} " in *dev-caches*) dev_caches_register_roots || true ;; esac
  local cur_ident canon
  for item in "${PLAN_ACTIONS[@]}"; do
    plan_read_record "$item" || return 1
    act_id="$PLAN_F_ID"
    cat="$PLAN_F_CAT"
    op="$PLAN_F_OP"
    p="$PLAN_F_PATH"
    ident="$PLAN_F_IDENT"

    # Operation tool_cleanup might not have a target_path
    [ -z "$p" ] && continue
    # A retain action records something the plan must NOT touch; it is
    # verified after apply, never authorized for mutation.
    [ "$op" = "retain" ] && continue

    if [ "$cat" = "uninstall-app" ]; then
      # Application bundles live outside $HOME, so the general path gate
      # (home and temp only) cannot authorize them. They get their own,
      # narrower rule instead of a wider global root: see
      # uninstall_authorize_bundle.
      if ! uninstall_authorize_bundle "$p"; then
        err "plan preflight: application bundle refused: $p ($UNINSTALL_DENY_REASON)"
        return 1
      fi
      canon="$UNINSTALL_CANONICAL"
    elif ! canon="$(path_authorize "$p")"; then
      err "plan preflight: target outside authorized roots: $p ($(path_deny_message))"
      return 1
    fi

    # A folder whose contents are cleared keeps whitelisted entries inside
    # it (quarantine_dir_contents skips them); anything else is refused.
    if { [ "$op" = "clear_dir_contents" ] && whitelist_covers "$canon"; } ||
       { [ "$op" != "clear_dir_contents" ] && is_whitelisted "$canon"; }; then
      err "plan preflight: target is whitelisted: $p"
      return 1
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

  [ "$fresh" = "fresh" ] && return 0
  plan_verify_selection
}

# A plan only SELECTS among what mimi would pick itself right now. Every path
# action is re-derived: cleaner categories are scanned again in plan mode, and
# an uninstall's data is attributed again from the bundle. An action that is
# not among the fresh results is refused, so an edited or hand-made plan
# cannot widen what gets removed.
plan_verify_selection() {
  local item cats="," current cid
  for item in ${PLAN_ACTIONS[@]+"${PLAN_ACTIONS[@]}"}; do
    plan_read_record "$item" || return 1
    case "$PLAN_F_OP" in retain|tool_cleanup) continue ;; esac
    case "$PLAN_F_CAT" in uninstall-*) continue ;; esac
    case "$cats" in *",$PLAN_F_CAT,"*) ;; *) cats="$cats$PLAN_F_CAT," ;; esac
  done

  if [ "$cats" != "," ]; then
    current="$(plan_rederive_cids "$cats")"
    for item in "${PLAN_ACTIONS[@]}"; do
      plan_read_record "$item" || return 1
      case "$PLAN_F_OP" in retain|tool_cleanup) continue ;; esac
      case "$PLAN_F_CAT" in uninstall-*) continue ;; esac
      # Candidates are recorded by canonical path; compare like with like.
      cid="$(plan_candidate_id "$PLAN_F_CAT" "$(path_canonicalize "$PLAN_F_PATH" nofollow)")"
      case $'\n'"$current"$'\n' in
        *$'\n'"$cid"$'\n'*) ;;
        *)
          err "plan preflight: '$PLAN_F_CAT' would not select this now: $PLAN_F_PATH"
          return 1
          ;;
      esac
    done
  fi

  uninstall_plan_detect || return 0
  uninstall_verify_selection
}

# Candidate ids the given categories (",a,b,") would plan right now, one per
# line. Runs in a subshell with its output discarded; nothing is changed.
plan_rederive_cids() {
  local cats="$1"
  (
    local id var item
    MODE="plan"
    JSONL_ENABLED=0
    PLAN_CANDIDATES=()
    SKIP_LIST=""
    ONLY_LIST="${cats#,}"
    ONLY_LIST="${ONLY_LIST%,}"
    for id in $ALL_CATEGORY_IDS; do
      case "$cats" in *",$id,"*) ;; *) continue ;; esac
      var="$(category_include_var "$id")"
      [ -n "$var" ] && printf -v "$var" '1'
      run_category "$id"
    done > /dev/null 2>&1
    for item in ${PLAN_CANDIDATES[@]+"${PLAN_CANDIDATES[@]}"}; do
      plan_read_record "$item" && printf '%s\n' "$PLAN_F_ID"
    done
  )
}
