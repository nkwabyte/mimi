#!/usr/bin/env bash
#
# lib/confirm.sh — Typed confirmations and the force policy (P0-T07).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# ---------------------------------------------------------------------------
# Confirmation classes
#
# Every prompt this tool shows belongs to exactly one class, and the class —
# not the prompt's wording — decides what can answer it:
#
#   read-only     Nothing is mutated, so nothing is asked. Scans, --report and
#                 the orphan report are all read-only and never appear here.
#   recoverable   The data comes back on its own: a cache that refills, a
#                 model that re-downloads. --yes answers these.
#   risky         Losing it costs real work or real data, but the loss is
#                 bounded and usually reconstructible. --yes does NOT answer
#                 these. A terminal y/N, or --force-risky <id>, does.
#   irreversible  Gone means gone: there is no copy anywhere else. --yes does
#                 NOT answer these. A terminal confirmation where the user
#                 types the action's own id, or --force-risky <id>, does.
#
# The point of the split is that `--yes` is the flag people paste into a cron
# line and then forget. It has to mean "do not ask me about caches", not
# "empty my Trash and delete my phone backups". Authorizing those requires
# naming them one by one — which is also why --force-risky takes a value and
# has no "all".
# ---------------------------------------------------------------------------

# Every action id that has a confirmation gate. Ids match category ids so that
# --force-risky takes the same names as --only/--skip; `orphans` gates the
# removal of a reviewed remnants file, which is the only way the orphan
# scanner's output can ever delete anything.
CONFIRM_GATED_IDS="docker mail trash orphans sim-stale android ml-caches ios-backups"

# confirm_class <action-id> -> recoverable | risky | irreversible
#
# An id with no entry is recoverable: a prompt that was never classified must
# not silently become un-skippable, and anything genuinely dangerous is listed
# here by hand.
confirm_class() {
  case "$1" in
    trash)        printf '%s' "irreversible" ;;   # ~/.Trash is the last copy
    ios-backups)  printf '%s' "irreversible" ;;   # the only local copy of a phone
    orphans)      printf '%s' "irreversible" ;;   # reviewed remnants, deleted outright
    docker)       printf '%s' "risky" ;;          # named volumes hold real data
    mail)         printf '%s' "risky" ;;          # a POP attachment has no server copy
    sim-stale)    printf '%s' "risky" ;;          # custom devices are not recreated
    android)      printf '%s' "risky" ;;          # an AVD carries its own app data
    ml-caches)    printf '%s' "recoverable" ;;    # weights re-download
    *)            printf '%s' "recoverable" ;;
  esac
}

# True when the id names something --force-risky may authorize. Recoverable
# prompts are deliberately excluded: --yes already covers them, and accepting
# them here would teach people to reach for the dangerous flag by habit.
confirm_is_forceable() {
  case "$(confirm_class "$1")" in
    risky|irreversible) return 0 ;;
    *) return 1 ;;
  esac
}

# Action ids whose typed confirmation has already been given in this run, so a
# per-item loop (one prompt per iOS backup) asks for the word once and then
# uses an ordinary y/N for each item. Typing the word is a statement about the
# class of action; the per-item prompt is about which items.
CONFIRM_TYPED_DONE=""

# ---------------------------------------------------------------------------
# Can we actually ask?
# ---------------------------------------------------------------------------

# Prompts are written to, and read from, the controlling terminal rather than
# stdin, so that piping something into the tool does not silently answer its
# questions. Both conditions are checked because both are needed: an
# interactive invocation (stdin is a terminal) and a terminal we can open.
confirm_can_prompt() {
  [ -t 0 ] || return 1
  [ -c /dev/tty ] || return 1
  { : < /dev/tty; } 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# --force-risky
# ---------------------------------------------------------------------------

# normalize_force_risky_list <source-label> <comma-separated-list>
#
# Same shape as normalize_category_list, but the accepted vocabulary is only
# the risky/irreversible action ids. Prints the normalized list. There is no
# "all": a flag that authorizes everything at once is the thing this task
# exists to remove.
normalize_force_risky_list() {
  local src="$1" raw="$2" out="" item
  local oldifs="$IFS"
  IFS=','
  set -- $raw
  IFS="$oldifs"
  for item in "$@"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] && continue
    case "$item" in
      all|ALL|'*')
        die_usage "$src: there is no '$item' — name each action you are authorizing ($(confirm_forceable_ids))" ;;
    esac
    if ! confirm_is_forceable "$item"; then
      if [ "$(confirm_class "$item")" = recoverable ] && confirm_is_gated "$item"; then
        die_usage "$src: '$item' is a recoverable action; --yes already covers it"
      fi
      die_usage "$src: '$item' is not a risky action (choose from: $(confirm_forceable_ids))"
    fi
    case ",$out," in
      *",$item,"*) continue ;;
    esac
    out="${out:+$out,}$item"
  done
  if [ -z "$out" ]; then
    die_usage "$src requires at least one action name ($(confirm_forceable_ids))"
  fi
  printf '%s' "$out"
}

confirm_is_gated() {
  local needle="$1" id
  for id in $CONFIRM_GATED_IDS; do
    [ "$id" = "$needle" ] && return 0
  done
  return 1
}

# The valid --force-risky vocabulary, in registry order, for error messages
# and help text so the two can never drift apart.
confirm_forceable_ids() {
  local id out=""
  for id in $CONFIRM_GATED_IDS; do
    confirm_is_forceable "$id" && out="${out:+$out, }$id"
  done
  printf '%s' "$out"
}

force_risky_authorized() {
  local needle="$1" item
  [ -n "$FORCE_RISKY_LIST" ] || return 1
  local oldifs="$IFS"
  IFS=','
  set -- $FORCE_RISKY_LIST
  IFS="$oldifs"
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Prompts
#
# Return values are three-valued on purpose. 0 authorized, 1 declined by a
# human, 2 no confirmation was obtainable — the caller words its message
# differently for the last one, because "skipped by user" would be a lie when
# nobody was ever asked.
# ---------------------------------------------------------------------------

confirm_prompt_yesno() {
  local prompt="$1" reply
  if ! confirm_can_prompt; then
    return 2
  fi
  read -r -p "${C_YELLOW}${prompt} [y/N] ${C_RESET}" reply < /dev/tty || return 2
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# The irreversible prompt refuses to accept a keystroke. "y" is muscle memory;
# typing the action's own name is not something a hand does by accident.
confirm_prompt_typed() {
  local id="$1" prompt="$2" reply
  if ! confirm_can_prompt; then
    return 2
  fi
  say "${C_YELLOW}${prompt}${C_RESET}"
  say "${C_BOLD}This cannot be undone.${C_RESET} Type ${C_BOLD}${id}${C_RESET} to confirm, anything else to skip."
  read -r -p "> " reply < /dev/tty || return 2
  if [ "$reply" = "$id" ]; then
    CONFIRM_TYPED_DONE="${CONFIRM_TYPED_DONE:+$CONFIRM_TYPED_DONE,}$id"
    return 0
  fi
  return 1
}

confirm_typed_already_given() {
  local needle="$1"
  case ",$CONFIRM_TYPED_DONE," in
    *",$needle,"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The two entry points the rest of the tool calls
# ---------------------------------------------------------------------------

# confirm <prompt>
#
# An unclassified, recoverable prompt: --yes answers it. Used for the
# whole-run gate and for caches that refill by themselves.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  confirm_prompt_yesno "$1"
}

# confirm_action <action-id> <prompt>
#
# The classed prompt. --yes cannot answer a risky or irreversible one; only a
# terminal confirmation or --force-risky <id> can.
confirm_action() {
  local id="$1" prompt="$2" class
  class="$(confirm_class "$id")"

  if [ "$class" = recoverable ]; then
    confirm "$prompt"
    return $?
  fi

  if force_risky_authorized "$id"; then
    warn "$id: authorized by --force-risky"
    return 0
  fi

  if [ "$class" = irreversible ] && ! confirm_typed_already_given "$id"; then
    confirm_prompt_typed "$id" "$prompt"
    return $?
  fi
  confirm_prompt_yesno "$prompt"
}

# Reports a prompt that could not be asked, in the one place that knows why.
confirm_report_unavailable() {
  local id="$1"
  err "$id: needs confirmation, and there is no terminal to ask on."
  err "Run it from a terminal, or authorize it explicitly: --force-risky $id"
}

# confirm_action_ok <action-id> <prompt>
#
# confirm_action plus the message that explains a "no", so every call site is
# a plain `if ! confirm_action_ok ...`. The two refusals are worded
# differently on purpose: "skipped by user" is a false statement when nobody
# was ever in a position to be asked.
confirm_action_ok() {
  local id="$1" prompt="$2" rc=0
  confirm_action "$id" "$prompt" || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 2 ]; then
    confirm_report_unavailable "$id"
  else
    warn "$id: skipped by user"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Pre-flight
#
# A run that cannot possibly confirm what it was asked to do should say so
# before it deletes anything else, not halfway down the category list. This is
# the whole check, run once, against the fully resolved selection.
# ---------------------------------------------------------------------------

# True when this run will actually reach <id>'s gated action.
confirm_action_selected() {
  local id="$1" var
  # The orphan scanner never deletes; the reviewed file is the gated action.
  if [ "$id" = orphans ]; then
    [ -n "$REMOVE_ORPHANS_FILE" ] && return 0
    return 1
  fi
  should_run_category "$id" || return 1
  var="$(category_include_var "$id")"
  [ -n "$var" ] || return 0
  [ "${!var}" = 1 ] && return 0
  return 1
}

# preflight_confirmations
#
# Returns EXIT_CANCELLED when the run selected risky or irreversible work,
# has no terminal to confirm it on, and did not authorize it on the command
# line. Prints exactly which flag each missing action needs.
preflight_confirmations() {
  [ "$MODE" = "clean" ] || return 0
  confirm_can_prompt && return 0

  local id missing=""
  for id in $CONFIRM_GATED_IDS; do
    confirm_is_forceable "$id" || continue
    confirm_action_selected "$id" || continue
    force_risky_authorized "$id" && continue
    missing="${missing:+$missing }$id"
  done
  [ -n "$missing" ] || return 0

  err "This run has no terminal to ask for confirmation on, and these actions"
  err "cannot be authorized by --yes:"
  for id in $missing; do
    err "  $id  ($(confirm_class "$id")) — authorize with: --force-risky $id"
  done
  err "Nothing was removed. Re-run from a terminal, or add the flags above."
  return "$EXIT_CANCELLED"
}
