#!/usr/bin/env bash
#
# scripts/lib.sh — shared helpers for the release scripts. Sourced, not run.
#
# Bash 3.2 compatible, like the rest of mimi, so the scripts run on a stock Mac.

REPO_ROOT="${MIMI_RELEASE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
GLOBALS_FILE="$REPO_ROOT/lib/core/globals.sh"
CHANGELOG_FILE="$REPO_ROOT/CHANGELOG.md"
GITHUB_REPO="${MIMI_GITHUB_REPO:-nkwabyte/mimi}"
DEV_BRANCH="${MIMI_DEV_BRANCH:-dev}"
MAIN_BRANCH="${MIMI_MAIN_BRANCH:-main}"
RELEASE_WORKFLOW="homebrew-release.yml"

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

if [ -t 1 ]; then
  _B=$'\033[1m' _R=$'\033[31m' _G=$'\033[32m' _Y=$'\033[33m' _D=$'\033[2m' _N=$'\033[0m'
else
  _B="" _R="" _G="" _Y="" _D="" _N=""
fi

step() { printf '\n%s==> %s%s\n' "$_B" "$*" "$_N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$_G" "$_N" "$*"; }
warn() { printf '    %s!%s %s\n' "$_Y" "$_N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_R" "$_N" "$*" >&2; exit 1; }

# Run a command that changes something (git, gh). In dry-run mode it is only
# printed. Arguments are passed as an array — never through a shell string.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s' "$_D" "$_N"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  printf '    %s$%s' "$_D" "$_N"
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

# y/N question; --yes answers it. Never asks in dry-run mode.
ask() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 0
  local reply
  if [ ! -t 0 ]; then
    die "cannot ask \"$1\" without a terminal; pass --yes"
  fi
  read -r -p "    $1 [y/N] " reply
  case "$reply" in y|Y|yes|YES) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

current_version() {
  sed -n 's/^MIMI_VERSION="\(.*\)"$/\1/p' "$GLOBALS_FILE"
}

is_semver() {
  case "$1" in
    *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  [ "$#" -eq 3 ]
}

# 0 when $1 > $2 (both X.Y.Z).
version_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}

# next_version patch|minor|major FROM
next_version() {
  local kind="$1" v1 v2 v3
  IFS=. read -r v1 v2 v3 <<< "$2"
  case "$kind" in
    patch) printf '%s.%s.%s' "$v1" "$v2" "$((v3 + 1))" ;;
    minor) printf '%s.%s.0' "$v1" "$((v2 + 1))" ;;
    major) printf '%s.0.0' "$((v1 + 1))" ;;
    *) return 1 ;;
  esac
}

# Newest vX.Y.Z tag (without the v), or 0.0.0.
latest_tag_version() {
  local t
  t="$(git -C "$REPO_ROOT" tag --list 'v[0-9]*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  printf '%s' "${t:-0.0.0}"
}

# Resolve "patch|minor|major|X.Y.Z" against the last released tag.
resolve_version() {
  case "$1" in
    patch|minor|major) next_version "$1" "$(latest_tag_version)" ;;
    *) printf '%s' "${1#v}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Changelog
# ---------------------------------------------------------------------------

# The body of "## [VERSION]" (heading excluded), up to the next "## [".
changelog_section() {
  awk -v v="$1" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on && /^\[[^]]*\]: / { exit }
    on { print }
  ' "$CHANGELOG_FILE" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed '/./,$!d'
}

# True when the Unreleased section has any non-blank line.
changelog_unreleased_nonempty() {
  changelog_section "Unreleased" | grep -q '[^[:space:]]'
}

# True when a "## [VERSION]" section exists.
changelog_has_version() {
  grep -q "^## \[$1\]" "$CHANGELOG_FILE"
}
