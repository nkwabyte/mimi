#!/usr/bin/env bash
#
# lib/apps/receipts.sh — Installer package receipt ownership graph (Phase 5, P5-T02).
#
# Read-only. Maps a package receipt's payload to canonical paths, groups it
# into the top-level items an uninstall would act on, and finds which of them
# other installed packages also own. Nothing here removes anything, and
# `pkgutil --forget` is never run: forgetting a receipt only deletes
# bookkeeping, and belongs after a verified removal (P5-T05), never instead
# of one.
#
# Why not `pkgutil --file-info`: receipt payload paths are stored relative to
# the package's install location, and --file-info does not find the owner of
# a path when that location is not "/". Ownership is therefore computed from
# every third-party receipt's own file list, resolved against its location.
# Apple's receipts are excluded from the index: they are very large, and mimi
# never acts on Apple-owned paths anyway.
#
# Compatible with Bash 3.2+ (no associative arrays).

# Directories that are structure, not an item any one package owns. Payload
# paths are grouped at the first component below these.
RCPT_STRUCTURAL="Applications|Applications/Utilities|Library|Library/Application Support|Library/LaunchAgents|Library/LaunchDaemons|Library/PrivilegedHelperTools|Library/Preferences|Library/Frameworks|Library/Extensions|Library/SystemExtensions|Library/Audio|Library/Audio/Plug-Ins|Library/Audio/Plug-Ins/Components|Library/Audio/Plug-Ins/HAL|Library/Audio/Plug-Ins/VST|Library/Audio/Plug-Ins/VST3|Library/Internet Plug-Ins|Library/PreferencePanes|Library/QuickLook|Library/Spotlight|Library/Fonts|Library/Printers|Library/Filesystems|Library/Caches|Library/Logs|Library/Services|Library/Scripts|Library/Input Methods|Library/Keyboard Layouts|Library/Screen Savers|Library/ColorSync|Library/ColorSync/Profiles|Library/Components|Library/Contextual Menu Items|Library/CoreMediaIO|Library/CoreMediaIO/Plug-Ins|Library/CoreMediaIO/Plug-Ins/DAL|Library/DriverExtensions|bin|sbin|usr|usr/bin|usr/sbin|usr/lib|usr/libexec|usr/share|usr/local|usr/local/bin|usr/local/sbin|usr/local/lib|usr/local/include|usr/local/share|usr/local/share/man|usr/local/etc|opt|private|private/etc|private/var|etc|var"

# Results of the last receipt_analyze (parallel arrays).
RCPT_ITEM_PKGS=()      # package id the item came from
RCPT_ITEM_PATHS=()     # absolute path
RCPT_ITEM_STATUS=()    # exclusive | shared
RCPT_ITEM_OWNERS=()    # comma-separated OTHER package ids that own it (or files in it)
RCPT_ITEM_PRESENT=()   # 1 when the path exists now
RCPT_ITEM_COUNT=0
RCPT_LOCATIONS=()      # "<pkg id>|<absolute install location>"

# Absolute install location of a package ("/" + location, or "/").
receipt_pkg_location() {
  local id="$1" loc vol
  local info
  info="$(pkgutil --pkg-info "$id" 2>/dev/null)" || return 1
  vol="$(printf '%s\n' "$info" | sed -n 's/^volume: //p')"
  loc="$(printf '%s\n' "$info" | sed -n 's/^location: //p')"
  [ -n "$vol" ] || vol="/"
  vol="${vol%/}"
  loc="${loc#/}"
  loc="${loc%/}"
  if [ -n "$loc" ]; then
    printf '%s/%s\n' "$vol" "$loc"
  else
    printf '%s/\n' "$vol"
  fi
}

# Absolute payload paths of a package, one per line.
receipt_pkg_paths() {
  local id="$1" base
  base="$(receipt_pkg_location "$id")" || return 1
  base="${base%/}"
  pkgutil --files "$id" 2>/dev/null | awk -v b="$base" 'NF { sub(/^\.\//, ""); print b "/" $0 }'
}

# Items of a package's payload under PREFIX: the first path below PREFIX that
# is not a structural directory. Reads absolute paths on stdin.
# Usage: ... | _rcpt_items_under PREFIX
_rcpt_items_under() {
  awk -v pre="$1" -v structs="$RCPT_STRUCTURAL" '
    BEGIN { n = split(structs, a, "|"); for (i = 1; i <= n; i++) S["/" a[i]] = 1 }
    {
      p = $0
      if (pre == "/") { rest = substr(p, 2); cur = "" }
      else {
        if (index(p, pre "/") != 1) next
        rest = substr(p, length(pre) + 2); cur = pre
      }
      while (rest != "") {
        k = index(rest, "/")
        if (k == 0) { comp = rest; rest = "" } else { comp = substr(rest, 1, k - 1); rest = substr(rest, k + 1) }
        cur = cur "/" comp
        if (!(cur in S)) { if (!(cur in seen)) { seen[cur] = 1; print cur }; break }
      }
    }'
}

# "<pkg>\t<abs path>" for every third-party receipt, except the ids in the
# comma-separated SKIP list. Listing every receipt takes about a second, so
# the full index is built once per process and filtered afterwards.
RCPT_INDEX_ALL=""
RCPT_INDEX_BUILT=0

_rcpt_index_emit() {
  local p b
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in com.apple.*) continue ;; esac
    b="$(receipt_pkg_location "$p")" || continue
    b="${b%/}"
    pkgutil --files "$p" 2>/dev/null | awk -v b="$b" -v id="$p" 'NF { sub(/^\.\//, ""); print id "\t" b "/" $0 }'
  done < <(pkgutil --pkgs 2>/dev/null)
}

_rcpt_index_build() {
  [ "$RCPT_INDEX_BUILT" = 1 ] && return 0
  RCPT_INDEX_BUILT=1
  # A function, not an inline loop: Bash 3.2 misparses a case pattern's ")"
  # inside $(...).
  RCPT_INDEX_ALL="$(_rcpt_index_emit)"
}

_rcpt_index() {
  _rcpt_index_build
  [ -n "$RCPT_INDEX_ALL" ] || return 0
  if [ -z "$1" ]; then
    printf '%s\n' "$RCPT_INDEX_ALL"
  else
    printf '%s\n' "$RCPT_INDEX_ALL" | awk -F'\t' -v skip=",$1," 'index(skip, "," $1 ",") == 0'
  fi
}

# Every ".app" path in a third-party receipt, as "<abs path>\t<pkg id>" lines.
# Built once per process: finding an app's package by its path cannot use
# `pkgutil --file-info` for packages installed to their own location.
RCPT_APP_TABLE=""
RCPT_APP_TABLE_BUILT=0

receipt_app_table() {
  if [ "$RCPT_APP_TABLE_BUILT" != 1 ]; then
    RCPT_APP_TABLE_BUILT=1
    command -v pkgutil > /dev/null 2>&1 || return 0
    RCPT_APP_TABLE="$(_rcpt_index "" | awk -F'\t' '$2 ~ /\.app$/ { print $2 "\t" $1 }')"
  fi
  return 0
}

# Package ids whose payload contains exactly this app bundle path.
receipt_pkgs_for_app() {
  local app="$1"
  receipt_app_table
  [ -n "$RCPT_APP_TABLE" ] || return 0
  printf '%s\n' "$RCPT_APP_TABLE" | awk -F'\t' -v a="$app" '$1 == a { print $2 }'
}

# Other owners of each item (reads items from ITEMS_FILE, index on stdin).
# Prints "<item>\t<owner,owner>" for items with at least one other owner.
_rcpt_owners() {
  awk -F'\t' -v items="$1" '
    BEGIN { while ((getline line < items) > 0) { I[line] = 1; n++ } }
    {
      p = $2
      # The item itself, or anything inside it, belongs to another package.
      q = p
      while (q != "" && q != "/") {
        # if/else, not `O[q] = (q in O) ? ...`: mawk creates O[q] before
        # testing it, which put a leading comma on the first owner.
        if (q in I) {
          key = q SUBSEP $1
          if (!(key in done)) {
            done[key] = 1
            if (q in O) O[q] = O[q] "," $1; else O[q] = $1
          }
        }
        sub(/\/[^\/]*$/, "", q)
      }
    }
    END { for (q in O) print q "\t" O[q] }'
}

# receipt_analyze PKG_ID...
#
# Fills RCPT_ITEM_* with the top-level payload items of the given packages and
# which other installed third-party packages share them. A shared item is
# split one level further (up to two levels) so that exclusive parts inside a
# shared vendor folder are still identified.
receipt_analyze() {
  RCPT_ITEM_PKGS=()
  RCPT_ITEM_PATHS=()
  RCPT_ITEM_STATUS=()
  RCPT_ITEM_OWNERS=()
  RCPT_ITEM_PRESENT=()
  RCPT_ITEM_COUNT=0
  RCPT_LOCATIONS=()
  [ "$#" -gt 0 ] || return 0
  command -v pkgutil > /dev/null 2>&1 || return 1

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/mimi-rcpt-XXXXXX")" || return 1

  local ids="" id loc
  for id in "$@"; do
    ids="${ids:+$ids,}$id"
  done
  _rcpt_index "$ids" > "$tmp/index"

  for id in "$@"; do
    loc="$(receipt_pkg_location "$id")" || continue
    RCPT_LOCATIONS+=("$id|$loc")
    receipt_pkg_paths "$id" > "$tmp/paths"
    [ -s "$tmp/paths" ] || continue

    # Start at the install location; descend into shared items.
    _rcpt_items_under "${loc%/}" < "$tmp/paths" > "$tmp/items"
    local depth=0 item owners
    while [ -s "$tmp/items" ]; do
      _rcpt_owners "$tmp/items" < "$tmp/index" > "$tmp/owners"
      : > "$tmp/next"
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        owners="$(awk -F'\t' -v i="$item" '$1 == i { print $2; exit }' "$tmp/owners")"
        if [ -n "$owners" ] && [ "$depth" -lt 2 ] && _rcpt_items_under "$item" < "$tmp/paths" | grep -q .; then
          _rcpt_items_under "$item" < "$tmp/paths" >> "$tmp/next"
          continue
        fi
        RCPT_ITEM_PKGS+=("$id")
        RCPT_ITEM_PATHS+=("$item")
        if [ -n "$owners" ]; then
          RCPT_ITEM_STATUS+=("shared")
        else
          RCPT_ITEM_STATUS+=("exclusive")
        fi
        RCPT_ITEM_OWNERS+=("$owners")
        if [ -e "$item" ] || [ -L "$item" ]; then RCPT_ITEM_PRESENT+=(1); else RCPT_ITEM_PRESENT+=(0); fi
        RCPT_ITEM_COUNT=$((RCPT_ITEM_COUNT + 1))
      done < "$tmp/items"
      mv -f "$tmp/next" "$tmp/items"
      depth=$((depth + 1))
    done
  done

  # Our own mktemp directory; through the checked primitive like every other
  # removal (tests/mutation.bats forbids raw rm outside it).
  fs_remove "$tmp" || true
  return 0
}
