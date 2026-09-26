#!/usr/bin/env bash
#
# scripts/version.sh — where the version stands and what the next one would be.
#
# Usage: scripts/version.sh
#
# Read-only: prints MIMI_VERSION, the last released tag, the candidate next
# versions, and whether CHANGELOG.md has unreleased notes.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

last="$(latest_tag_version)"
cur="$(current_version)"

printf 'MIMI_VERSION (lib/core/globals.sh): %s\n' "$cur"
printf 'last released tag:                  v%s\n' "$last"
printf 'next patch / minor / major:         %s / %s / %s\n' \
  "$(next_version patch "$last")" "$(next_version minor "$last")" "$(next_version major "$last")"
if changelog_has_version "$cur" && version_gt "$cur" "$last"; then
  printf 'CHANGELOG.md:                       [%s] is written and not yet released\n' "$cur"
fi
if changelog_unreleased_nonempty; then
  printf 'CHANGELOG.md:                       [Unreleased] has notes\n'
else
  printf 'CHANGELOG.md:                       [Unreleased] is empty\n'
fi
