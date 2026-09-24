#!/usr/bin/env bash
#
# lib/safety/path.sh lib/path.sh — Canonical path and containment API (P0-T03).
#
# Sourced by lib/load.sh; never executed on its own. Defines functions and
# global state only, so load order matters solely for the few assignments that
# interpolate $HOME_DIR (set in globals.sh, loaded first).

# ---------------------------------------------------------------------------
# Canonical path and containment API
#
# Every destructive action is authorized here and nowhere else. The rules:
#
#   * a path is made absolute, then resolved one component at a time against
#     the real filesystem, so ".." means "the parent of what this actually
#     is", not "drop the last word of this string";
#   * containment is decided on component boundaries, so /a/bcd is never
#     mistaken for something living inside /a/bc;
#   * the final component is deliberately NOT followed, because removing a
#     symlink removes the link itself — the link is the object being
#     authorized, not whatever it points at;
#   * a target's device+inode is captured when it is checked and confirmed
#     again immediately before it is mutated.
#
# The old resolve_path() used `cd "$p" && pwd -P`, which silently returned the
# raw unresolved string for every file (cd fails on non-directories) and for
# every path that does not exist yet. Callers then compared those strings with
# a prefix match. Both halves of that are replaced here.
# ---------------------------------------------------------------------------

# Give up rather than loop forever on a symlink cycle.
PATH_MAX_LINK_HOPS=40

# Results of the most recent path_authorize call. PATH_DENY_REASON holds the
# refusal code; PATH_CANONICAL holds the canonical path on success.
#
# These exist because command substitution runs in a subshell: a caller that
# writes `p="$(path_authorize "$x")"` gets the path but loses the reason when
# it is refused. Callers that need both read the globals and redirect stdout.
PATH_DENY_REASON=""
PATH_CANONICAL=""

# Canonical allowed roots and forbidden exact paths, built once on first use.
PATH_ALLOWED_ROOTS=()
PATH_FORBIDDEN_CANONICAL=()
_PATH_ROOTS_READY=0

# Expand a leading "~" and make the result absolute. Pure string work: the
# filesystem is not consulted and nothing is resolved yet.
path_absolute() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in
    "~") p="$HOME_DIR" ;;
    "~/"*) p="$HOME_DIR/${p#\~/}" ;;
  esac
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  printf '%s' "$p"
}

# True when the path contains a ".." path component. A file genuinely named
# "..config" or "a..b" is not traversal and is not matched here.
path_has_traversal() {
  case "/$1/" in
    */../*) return 0 ;;
  esac
  return 1
}

# Canonical absolute form of a path: every intermediate symlink followed,
# every "." and ".." collapsed against the real directory structure. Works for
# paths that do not exist — the deepest existing ancestor is resolved and the
# remaining components are appended literally.
#
# Usage: path_canonicalize PATH [follow|nofollow]
#   follow    (default) resolves the final component too
#   nofollow  leaves the final component alone, giving the canonical location
#             of the object itself rather than of its symlink target
#
# Returns non-zero on an empty path or a symlink loop.
path_canonicalize() {
  local input mode resolved rest comp next link hops=0
  input="$(path_absolute "$1")" || return 1
  mode="${2:-follow}"

  resolved=""
  rest="${input#/}"

  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi

    case "$comp" in
      "" | ".") continue ;;
      "..")
        resolved="${resolved%/*}"
        continue
        ;;
    esac

    next="$resolved/$comp"

    # Final component under "nofollow": stop here, do not expand it.
    if [ "$mode" = "nofollow" ] && [ -z "$rest" ]; then
      resolved="$next"
      break
    fi

    if [ -L "$next" ]; then
      hops=$((hops + 1))
      [ "$hops" -le "$PATH_MAX_LINK_HOPS" ] || return 1
      link="$(readlink "$next" 2>/dev/null)" || return 1
      [ -n "$link" ] || return 1
      case "$link" in
        /*)
          resolved=""
          rest="${link#/}${rest:+/$rest}"
          ;;
        *)
          rest="$link${rest:+/$rest}"
          ;;
      esac
      continue
    fi

    resolved="$next"
  done

  printf '%s' "${resolved:-/}"
}

# What a path is, without following a final symlink:
#   missing | symlink | dir | file | other
# A broken symlink reports "symlink", not "missing".
path_kind() {
  local p="$1"
  if [ -L "$p" ]; then printf 'symlink'; return 0; fi
  if [ ! -e "$p" ]; then printf 'missing'; return 0; fi
  if [ -d "$p" ]; then printf 'dir'; return 0; fi
  if [ -f "$p" ]; then printf 'file'; return 0; fi
  printf 'other'
}

# "device:inode" for a path, without following a final symlink. This is the
# identity a target is pinned to between discovery and mutation; the device
# half also answers "is this still the same volume".
path_identity() {
  local p="$1" id
  [ -e "$p" ] || [ -L "$p" ] || return 1
  id="$(stat -f '%d:%i' "$p" 2>/dev/null)" || return 1
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# True when TARGET is ROOT itself or lies underneath it. Both arguments must
# already be canonical. Matching is on component boundaries only: /a/bcd is
# not inside /a/bc. Root and target are quoted inside the case pattern, so a
# filename containing *, ?, or [ is matched literally.
path_contains() {
  local root="$1" target="$2"
  [ -n "$root" ] || return 1
  [ -n "$target" ] || return 1
  root="${root%/}"
  target="${target%/}"
  [ -n "$root" ] || root="/"
  [ -n "$target" ] || target="/"

  if [ "$root" = "/" ]; then
    case "$target" in /*) return 0 ;; *) return 1 ;; esac
  fi

  [ "$target" = "$root" ] && return 0
  case "$target" in "$root"/*) return 0 ;; esac
  return 1
}

# Add one or more canonical roots to the allowed set. Used for locations a
# tool itself reports as its cache (go env GOCACHE), which are legitimate but
# not predictable from $HOME alone.
path_register_allowed_root() {
  local r c existing
  for r in "$@"; do
    [ -n "$r" ] || continue
    c="$(path_canonicalize "$r")" || continue
    [ -n "$c" ] || continue
    for existing in ${PATH_ALLOWED_ROOTS[@]+"${PATH_ALLOWED_ROOTS[@]}"}; do
      [ "$existing" = "$c" ] && continue 2
    done
    PATH_ALLOWED_ROOTS+=("$c")
  done
  return 0
}

# Build the canonical root sets. Forbidden entries are canonicalized so that
# the firewalled "/var" also catches a target that resolves to "/private/var".
path_init_roots() {
  local f c

  # Both canonical forms of every forbidden entry are stored. "/var" is itself
  # a symlink to "private/var": the nofollow form protects the link, the follow
  # form protects what it points at, and a target can arrive as either.
  PATH_FORBIDDEN_CANONICAL=()
  for f in "${FORBIDDEN_EXACT[@]}"; do
    for c in "$(path_canonicalize "$f" nofollow)" "$(path_canonicalize "$f" follow)"; do
      [ -n "$c" ] || continue
      case " ${PATH_FORBIDDEN_CANONICAL[*]:-} " in
        *" $c "*) continue ;;
      esac
      PATH_FORBIDDEN_CANONICAL+=("$c")
    done
  done

  PATH_ALLOWED_ROOTS=()
  path_register_allowed_root "$HOME_DIR"
  # The per-user temp folder. cat_tmp clears both $TMPDIR (".../T") and its
  # sibling ".../C", so the allowed root is their shared parent, not $TMPDIR.
  if [ -n "${TMPDIR:-}" ]; then
    path_register_allowed_root "$(dirname "${TMPDIR%/}")"
  fi

  _PATH_ROOTS_READY=1
}

path_roots_ready() {
  [ "$_PATH_ROOTS_READY" = 1 ] && return 0
  path_init_roots
}

# Hard safety net: an exact canonical match here is never operated on,
# regardless of whitelist or category bugs.
is_forbidden() {
  local target="$1" f
  path_roots_ready
  for f in ${PATH_FORBIDDEN_CANONICAL[@]+"${PATH_FORBIDDEN_CANONICAL[@]}"}; do
    [ "$target" = "$f" ] && return 0
  done
  return 1
}

# The single authorization gate for every destructive action.
#
#   canon="$(path_authorize TARGET [allow-symlink|no-symlink])" || refuse
#
# On success the canonical path of the target object is printed (a final
# symlink is not followed) and 0 is returned. On refusal nothing is printed,
# non-zero is returned, and PATH_DENY_REASON holds a stable code:
#
#   empty         no path given
#   relative      not absolute even after "~" expansion
#   traversal     contains a ".." component
#   unresolvable  symlink loop, or a link that could not be read
#   symlink       final component is a symlink and the caller asked for none
#   forbidden     resolves to a protected system root, or to $HOME itself
#   outside-root  resolves outside every allowed root
path_authorize() {
  local raw="$1" policy="${2:-allow-symlink}" canon root allowed=1

  PATH_DENY_REASON=""
  PATH_CANONICAL=""
  path_roots_ready

  if [ -z "$raw" ]; then
    PATH_DENY_REASON="empty"
    return 1
  fi
  case "$raw" in
    /* | "~" | "~/"*) ;;
    *)
      PATH_DENY_REASON="relative"
      return 1
      ;;
  esac
  if path_has_traversal "$raw"; then
    PATH_DENY_REASON="traversal"
    return 1
  fi

  canon="$(path_canonicalize "$raw" nofollow)" || {
    PATH_DENY_REASON="unresolvable"
    return 1
  }
  if [ -z "$canon" ]; then
    PATH_DENY_REASON="unresolvable"
    return 1
  fi

  if [ "$policy" = "no-symlink" ] && [ -L "$canon" ]; then
    PATH_DENY_REASON="symlink"
    return 1
  fi

  if is_forbidden "$canon"; then
    PATH_DENY_REASON="forbidden"
    return 1
  fi

  for root in ${PATH_ALLOWED_ROOTS[@]+"${PATH_ALLOWED_ROOTS[@]}"}; do
    if path_contains "$root" "$canon"; then
      allowed=0
      break
    fi
  done
  if [ "$allowed" != 0 ]; then
    PATH_DENY_REASON="outside-root"
    return 1
  fi

  PATH_CANONICAL="$canon"
  printf '%s' "$canon"
  return 0
}

# Human wording for the current PATH_DENY_REASON.
path_deny_message() {
  case "${PATH_DENY_REASON:-}" in
    empty) printf 'no path given' ;;
    relative) printf 'not an absolute path' ;;
    traversal) printf 'contains a ".." component' ;;
    unresolvable) printf 'could not be resolved (symlink loop?)' ;;
    symlink) printf 'is a symlink, and following it would leave the authorized location' ;;
    forbidden) printf 'is a protected system location' ;;
    outside-root) printf 'is outside every allowed root' ;;
    *) printf 'failed the path safety check' ;;
  esac
}

# Hard safety net: never operate on these regardless of whitelist/category bugs.
FORBIDDEN_EXACT=(
  "/" "/System" "/Library" "/Applications" "/usr" "/bin" "/sbin" "/etc" "/var"
  "/private" "/Users" "$HOME_DIR"
)

# A path is whitelisted when it is, or lives under, a whitelisted path entry.
# Both sides are canonicalized first, so a whitelist entry that is a symlink
# to a directory protects the directory it actually points at, and a target
# named "Xcode2" is not protected by a whitelist entry for "Xcode".
is_whitelisted() {
  local target w wn
  target="$(path_canonicalize "$1" nofollow)" || return 1
  [ -n "$target" ] || return 1
  for w in "${WHITELIST[@]:-}"; do
    [ -z "$w" ] && continue
    case "$w" in /*|\~*) ;; *) continue ;; esac   # skip identifier-style entries here
    wn="$(path_canonicalize "$w")" || continue
    [ -n "$wn" ] || continue
    path_contains "$wn" "$target" && return 0
  done
  return 1
}
