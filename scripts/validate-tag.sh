#!/bin/bash
# Accept only vMAJOR.MINOR.PATCH. Reject trailing junk and newlines.
# The release workflow inlines the same rule because it runs before checkout.
set -euo pipefail
tag="${1:-}"
case "$tag" in
  *$'\n'*|*$'\r'*|*' '*)
    echo "ERROR: tag contains whitespace." >&2
    exit 1
    ;;
esac
if ! printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: tag '$tag' is not a valid semantic version (vX.Y.Z)." >&2
  exit 1
fi
printf '%s\n' "${tag#v}"
