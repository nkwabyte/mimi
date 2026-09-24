#!/usr/bin/env bash
#
# lib/core/validate.sh lib/validate.sh — Argument and configuration validation (P0-T08).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# ---------------------------------------------------------------------------
# Argument and configuration validation  (P0-T08)
#
# Every value that reaches arithmetic, find(1) or a category lookup is checked
# here first. The rules are identical whether the value came from the command
# line or from the saved config file, so a hand-edited config cannot smuggle
# past what the CLI would reject.
#
# Invalid usage always exits 1 with the same `<name>: error:` prefix, and
# always writes to stderr — this runs before any log file exists. <name> is
# how the program was invoked: "clean.sh" through the compatibility shim,
# "cleanmymac" when bin/mimi is run directly.
# ---------------------------------------------------------------------------

EXIT_OK=0
EXIT_USAGE=1
# 2 is deliberately unused: too many tools read it as "usage", and DEC-004
# already settled that invalid usage here exits 1.
EXIT_PARTIAL=3       # the run finished, but at least one selected action failed
EXIT_INTERRUPTED=4   # a signal stopped the run before it finished
# 5 is authorization, not usage: the command line was well-formed and the
# answer was simply "no" — either because a human said so at a prompt, or
# because a required confirmation could not be obtained at all. A script needs
# to tell that apart from a malformed invocation (1) and from work that ran
# and failed (3). See DEC-029.
EXIT_CANCELLED=5     # a required confirmation was declined or unobtainable

# Upper bound for every count/day setting. Generous enough that no real
# retention policy hits it, small enough that a typo or an overflow attempt
# does not reach arithmetic.
VALIDATE_INT_MAX=36500

die_usage() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  printf "Try './%s --help' for the full list of options.\n" "$SCRIPT_NAME" >&2
  exit "$EXIT_USAGE"
}

# require_arg <flag> <remaining-arg-count> <candidate-value>
#
# Guards `$2` before anything reads it, so `set -u` can never surface a raw
# "unbound variable" to the user. A candidate that is itself a long option is
# treated as missing: `--only --scan` is a typo, not a category named
# "--scan". A leading single dash is allowed through so that a negative
# number reaches the numeric validator and gets its more specific message.
require_arg() {
  local flag="$1" remaining="$2" candidate="${3-}"
  if [ "$remaining" -lt 2 ]; then
    die_usage "$flag requires a value"
  fi
  case "$candidate" in
    --*) die_usage "$flag requires a value (got the option '$candidate')" ;;
  esac
  return 0
}

# validate_int <source-label> <value>
#
# Accepts a bounded non-negative integer and nothing else: no signs, no
# decimals, no whitespace, no empty string. <source-label> is the flag name
# for CLI values and a config-file description for config values, so the
# error always points at what the user actually has to edit.
validate_int() {
  local src="$1" val="${2-}"
  case "$val" in
    ''|*[!0-9]*)
      die_usage "$src expects a whole number between 0 and $VALIDATE_INT_MAX (got: '$val')" ;;
  esac
  if [ "$val" -gt "$VALIDATE_INT_MAX" ]; then
    die_usage "$src expects a whole number between 0 and $VALIDATE_INT_MAX (got: '$val')"
  fi
  return 0
}

is_known_category() {
  local needle="$1" id
  for id in $ALL_CATEGORY_IDS; do
    [ "$id" = "$needle" ] && return 0
  done
  return 1
}

# normalize_category_list <source-label> <comma-separated-list>
#
# Trims whitespace around each id, drops empty fields, removes duplicates and
# rejects anything that is not a real category. Prints the normalized list.
# An empty result is an error: `--only ""` almost certainly means the shell
# ate an argument, and silently running everything would be the worst
# possible interpretation.
normalize_category_list() {
  local src="$1" raw="$2" out="" item
  local oldifs="$IFS"
  IFS=','
  set -- $raw
  IFS="$oldifs"
  for item in "$@"; do
    # Strip surrounding whitespace (bash 3.2: no ${var//pattern} niceties
    # that handle this in one step reliably).
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] && continue
    if ! is_known_category "$item"; then
      die_usage "$src: unknown category '$item' (run './$SCRIPT_NAME --list' to see them all)"
    fi
    case ",$out," in
      *",$item,"*) continue ;;    # already present, drop the duplicate
    esac
    out="${out:+$out,}$item"
  done
  if [ -z "$out" ]; then
    die_usage "$src requires at least one category name"
  fi
  printf '%s' "$out"
}

# Applies the CLI validation rules to whatever the config file supplied, with
# an error that names the file and key rather than a flag the user never
# typed. Called once, after argument parsing.
validate_config_values() {
  local line key val
  local oldifs="$IFS"
  while IFS='	' read -r key val; do
    [ -z "$key" ] && continue
    validate_int "$CONFIG_FILE ($key)" "$val"
  done <<EOF
$CONFIG_NUMERIC_SEEN
EOF
  IFS="$oldifs"

  if [ -n "$CONFIG_SELECTED_CATEGORIES" ]; then
    CONFIG_SELECTED_CATEGORIES="$(normalize_category_list "$CONFIG_FILE (SELECTED_CATEGORIES)" "$CONFIG_SELECTED_CATEGORIES")" \
      || exit "$EXIT_USAGE"
  fi

  if [ -n "$CONFIG_PROFILE" ]; then
    validate_profile "$CONFIG_FILE (PROFILE)" "$CONFIG_PROFILE"
  fi
  return 0
}

is_known_profile() {
  case "$1" in
    safe|developer|dev|aggressive|all) return 0 ;;
    *) return 1 ;;
  esac
}

validate_profile() {
  local src="$1" val="${2-}"
  if ! is_known_profile "$val"; then
    die_usage "$src: unknown profile '$val' (valid: safe, developer, aggressive)"
  fi
  return 0
}

profile_category_list() {
  case "$1" in
    safe)
      printf '%s' "browsers,electron,dev-caches,tmp,diagnostics,dsstore,quicklook,xcode-derived,sim-caches,sim-unavailable,homebrew,npm,yarn,pnpm,cocoapods,gradle,pip"
      ;;
    developer|dev)
      printf '%s' "browsers,electron,dev-caches,tmp,diagnostics,dsstore,quicklook,xcode-derived,sim-caches,sim-unavailable,homebrew,npm,yarn,pnpm,cocoapods,gradle,pip,claude-cache,docker-cache,xcode-archives,device-support,ide-stale,toolchains"
      ;;
    aggressive|all)
      printf '%s' "browsers,electron,dev-caches,tmp,diagnostics,dsstore,quicklook,xcode-derived,sim-caches,sim-unavailable,homebrew,homebrew-old,npm,yarn,pnpm,cocoapods,gradle,pip,claude-cache,docker-cache,xcode-archives,device-support,ide-stale,toolchains,caches,logs,timemachine,whatsapp,ml-caches"
      ;;
    *)
      return 1
      ;;
  esac
}
