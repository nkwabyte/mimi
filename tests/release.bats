#!/usr/bin/env bats
#
# release.bats — scripts/bump-version.sh, scripts/version.sh, and the checks
# in scripts/release.sh, run against a throwaway repository with a local bare
# "origin" and a stub gh. Nothing reaches GitHub.

load 'test_helper'

setup() {
  TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mimi-test-XXXXXX")"
  TEST_TMPDIR="$(cd -P "$TEST_TMPDIR" && pwd -P)"
  SENTINEL_PARENT="${TEST_TMPDIR%/*}/.sentinel-parent-$$"
  SENTINEL_SIBLING="${TEST_TMPDIR%/*}/.sentinel-sibling-$$"
  printf 'sentinel-parent\n'  > "$SENTINEL_PARENT"
  printf 'sentinel-sibling\n' > "$SENTINEL_SIBLING"
  SENTINEL_PARENT_HASH="$(cksum "$SENTINEL_PARENT" | awk '{print $1}')"
  SENTINEL_SIBLING_HASH="$(cksum "$SENTINEL_SIBLING" | awk '{print $1}')"

  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"
  git config --global user.email test@example.com
  git config --global user.name Test
  git config --global init.defaultBranch main

  # A repository shaped like mimi: globals, changelog, scripts.
  ORIGIN="$TEST_TMPDIR/origin.git"
  WORK="$TEST_TMPDIR/work"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$WORK" 2> /dev/null
  mkdir -p "$WORK/lib/core" "$WORK/scripts"
  printf '# globals\nMIMI_VERSION="0.1.0"\n' > "$WORK/lib/core/globals.sh"
  cat > "$WORK/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

### Added

- A new thing.

## [0.1.0] - 2026-09-24

First release.

[Unreleased]: https://github.com/nkwabyte/mimi/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nkwabyte/mimi/releases/tag/v0.1.0
MD
  cp "$REPO_ROOT"/scripts/*.sh "$WORK/scripts/"
  (cd "$WORK" && git add -A && git commit -q -m init && git tag v0.1.0 \
    && git push -q origin main v0.1.0 2> /dev/null && git checkout -q -b dev && git push -q -u origin dev 2> /dev/null)

  # gh stub: logged in, no pull requests, every call recorded.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" <<'SH'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$GH_LOG"
exit 0
SH
  chmod +x "$TEST_TMPDIR/bin/gh"
  export GH_LOG="$TEST_TMPDIR/gh.log"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
  verify_sentinels
  rm -rf "$TEST_TMPDIR"
}

bump()    { run /bin/bash "$WORK/scripts/bump-version.sh" "$@"; }
release() { run /bin/bash -c 'cd "$1" && shift && /bin/bash scripts/release.sh "$@" < /dev/null' _ "$WORK" "$@"; }

@test "bump: moves Unreleased notes into a dated section and updates the links" {
  bump minor --date 2026-10-01
  [ "$status" -eq 0 ]
  grep -q '^MIMI_VERSION="0.2.0"$' "$WORK/lib/core/globals.sh"
  run awk '/^## \[/' "$WORK/CHANGELOG.md"
  [ "${lines[0]}" = "## [Unreleased]" ]
  [ "${lines[1]}" = "## [0.2.0] - 2026-10-01" ]
  [ "${lines[2]}" = "## [0.1.0] - 2026-09-24" ]
  grep -q '^\[Unreleased\]: https://github.com/nkwabyte/mimi/compare/v0.2.0...HEAD$' "$WORK/CHANGELOG.md"
  grep -q '^\[0.2.0\]: https://github.com/nkwabyte/mimi/compare/v0.1.0...v0.2.0$' "$WORK/CHANGELOG.md"
  # The notes moved, they were not copied.
  [ "$(grep -c 'A new thing' "$WORK/CHANGELOG.md")" = 1 ]
}

@test "bump: dates a section written ahead of time" {
  sed -i '' 's/^## \[Unreleased\]$/## [Unreleased]\
\
## [0.2.0]\
\
- Planned./' "$WORK/CHANGELOG.md"
  sed -i '' '/^- A new thing\.$/d; /^### Added$/d' "$WORK/CHANGELOG.md"
  bump 0.2.0 --date 2026-10-02
  [ "$status" -eq 0 ]
  grep -q '^## \[0.2.0\] - 2026-10-02$' "$WORK/CHANGELOG.md"
  grep -q '^- Planned\.$' "$WORK/CHANGELOG.md"
}

@test "bump: refuses a version that is not newer, and nothing to release" {
  bump 0.1.0
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not newer than the last release v0.1.0"
  bump 1.2
  [ "$status" -eq 1 ]
  sed -i '' '/^- A new thing\.$/d; /^### Added$/d' "$WORK/CHANGELOG.md"
  bump patch
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "nothing under \[Unreleased\]"
  grep -q '^MIMI_VERSION="0.1.0"$' "$WORK/lib/core/globals.sh"
}

@test "version: reports current, last tag, candidates, and unreleased notes" {
  run /bin/bash "$WORK/scripts/version.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "last released tag: *v0.1.0"
  echo "$output" | grep -q "0.1.1 / 0.2.0 / 1.0.0"
  echo "$output" | grep -q "\[Unreleased\] has notes"
}

@test "release: refuses to run off the dev branch or with uncommitted changes" {
  (cd "$WORK" && git checkout -q main)
  release minor --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "release from the dev branch"

  (cd "$WORK" && git checkout -q dev && printf 'x\n' > stray.txt)
  release minor --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "uncommitted changes"
}

@test "release: refuses an existing tag" {
  (cd "$WORK" && git tag v0.2.0 && git push -q origin v0.2.0 2> /dev/null)
  release 0.2.0 --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not newer than the last release v0.2.0"
}

@test "release: a dry run shows every step and changes nothing" {
  local before
  before="$(cd "$WORK" && git rev-parse HEAD; git tag; cat CHANGELOG.md lib/core/globals.sh)"
  release minor --dry-run
  [ "$status" -eq 0 ]
  for s in "1. Checks" "2. Tests" "3. Bump" "4. Pull request" "5. Verify" "6. Tag v0.2.0" "7. Publish" "9. Sync"; do
    echo "$output" | grep -q "$s"
  done
  echo "$output" | grep -q "\[dry-run\] git push origin v0.2.0"
  echo "$output" | grep -q "\[dry-run\] gh release create v0.2.0"
  echo "$output" | grep -q "\[dry-run\] gh pr checks .* --watch --fail-fast"
  echo "$output" | grep -q "Dry run complete"
  [ "$(cd "$WORK" && git rev-parse HEAD; git tag; cat CHANGELOG.md lib/core/globals.sh)" = "$before" ]
  ! grep -q -E 'gh (pr create|pr merge|release create)' "$GH_LOG"
}

@test "release: without a terminal it asks for --yes instead of pushing" {
  release minor --skip-tests
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "pass --yes"
  # The bump is left in the working tree; nothing was committed or pushed.
  [ "$(cd "$WORK" && git rev-parse HEAD)" = "$(cd "$WORK" && git rev-parse origin/dev)" ]
}
