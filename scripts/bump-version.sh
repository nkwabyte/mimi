#!/usr/bin/env bash
#
# scripts/bump-version.sh — set the release version and date the changelog.
#
# Usage:
#   scripts/bump-version.sh X.Y.Z | patch | minor | major [--date YYYY-MM-DD]
#
#   * MIMI_VERSION in lib/core/globals.sh becomes X.Y.Z (the one place the
#     version lives; `mimi --version`, the JSON protocol, and the release
#     workflow's tag check all read it);
#   * CHANGELOG.md: the "## [Unreleased]" notes move into "## [X.Y.Z] - DATE".
#     If a "## [X.Y.Z]" section already exists (written ahead of time), it is
#     dated and any Unreleased notes are added to the top of it;
#   * the compare links at the bottom are updated.
#
# Changes files only — no git. scripts/release.sh calls this and commits.
# patch/minor/major count from the newest vX.Y.Z tag.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() { sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

target="" date_str="$(date +%Y-%m-%d)"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --date) [ $# -ge 2 ] || die "--date needs a value"; date_str="$2"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$target" ] || die "only one version, please"; target="$1"; shift ;;
  esac
done
[ -n "$target" ] || usage 1

version="$(resolve_version "$target")"
is_semver "$version" || die "not a version (X.Y.Z): $target"
case "$date_str" in
  [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;;
  *) die "--date must be YYYY-MM-DD" ;;
esac

current="$(current_version)"
[ -n "$current" ] || die "MIMI_VERSION not found in $GLOBALS_FILE"
last_tag="$(latest_tag_version)"
if ! version_gt "$version" "$last_tag"; then
  die "$version is not newer than the last release v$last_tag"
fi
if ! changelog_has_version "$version" && ! changelog_unreleased_nonempty; then
  die "CHANGELOG.md has nothing under [Unreleased] and no [$version] section to release"
fi

# 1. MIMI_VERSION
tmp="$(mktemp "${GLOBALS_FILE}.XXXXXX")"
sed "s/^MIMI_VERSION=\".*\"$/MIMI_VERSION=\"$version\"/" "$GLOBALS_FILE" > "$tmp"
grep -q "^MIMI_VERSION=\"$version\"$" "$tmp" || { rm -f "$tmp"; die "could not set MIMI_VERSION"; }
mv -f "$tmp" "$GLOBALS_FILE"

# 2. CHANGELOG.md
tmp="$(mktemp "${CHANGELOG_FILE}.XXXXXX")"
awk -v v="$version" -v d="$date_str" -v prev="$last_tag" -v repo="$GITHUB_REPO" '
  { line[NR] = $0 }
  END {
    n = NR
    # Locate the Unreleased section and an existing section for v.
    for (i = 1; i <= n; i++) {
      if (index(line[i], "## [Unreleased]") == 1) ur = i
      else if (index(line[i], "## [" v "]") == 1) vs = i
    }
    if (!ur) { print "no [Unreleased] heading" > "/dev/stderr"; exit 2 }
    # Unreleased body: up to the next heading or link definition.
    ue = n + 1
    for (i = ur + 1; i <= n; i++) if (line[i] ~ /^## \[/ || line[i] ~ /^\[[^]]*\]: /) { ue = i; break }
    body = ""
    for (i = ur + 1; i < ue; i++) body = body line[i] "\n"
    gsub(/^\n+|\n+$/, "", body)

    for (i = 1; i <= n; i++) {
      if (i == ur) {
        print "## [Unreleased]"
        print ""
        if (!vs) {
          print "## [" v "] - " d
          print ""
          if (body != "") { print body; print "" }
        }
        i = ue - 1
        continue
      }
      if (vs && i == vs) {
        print "## [" v "] - " d
        print ""
        if (body != "") { print body; print "" }
        # Skip blank lines right after the old heading.
        while (i + 1 <= n && line[i + 1] ~ /^[[:space:]]*$/) i++
        continue
      }
      if (index(line[i], "[Unreleased]: ") == 1) {
        print "[Unreleased]: https://github.com/" repo "/compare/v" v "...HEAD"
        print "[" v "]: https://github.com/" repo "/compare/v" prev "...v" v
        continue
      }
      if (index(line[i], "[" v "]: ") == 1) continue
      print line[i]
    }
  }
' "$CHANGELOG_FILE" > "$tmp" || { rm -f "$tmp"; die "could not rewrite CHANGELOG.md"; }
mv -f "$tmp" "$CHANGELOG_FILE"

ok "MIMI_VERSION: $current -> $version"
ok "CHANGELOG.md: [$version] - $date_str"
