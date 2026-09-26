#!/usr/bin/env bash
#
# scripts/release.sh — cut a mimi release end to end.
#
# Usage:
#   scripts/release.sh X.Y.Z | patch | minor | major [options]
#
# Options:
#   --dry-run       Show every step and command; change nothing.
#   --yes           Do not ask before pushing, merging, or publishing.
#   --skip-tests    Do not run ./tests/run first (not recommended).
#   --no-watch      Do not wait for the Homebrew tap workflow.
#   --publish-only  Skip preparation: the release commit is already on main
#                   (use after merging the release PR yourself). Tags,
#                   publishes, watches, and syncs dev.
#   -h, --help      Show this help.
#
# What it does, in order:
#   1. Checks: on the dev branch, clean tree, in sync with origin, gh logged
#      in, version newer than the last tag, tag unused, notes in CHANGELOG.md.
#   2. Runs the full test suite.
#   3. Bumps MIMI_VERSION and dates CHANGELOG.md (scripts/bump-version.sh),
#      commits "release: vX.Y.Z" on dev, pushes dev.
#   4. Opens (or reuses) the dev -> main pull request, waits for its CI
#      checks to pass, and merges it.
#   5. Verifies main carries MIMI_VERSION X.Y.Z.
#   6. Tags main as vX.Y.Z and pushes the tag.
#   7. Publishes the GitHub release with the CHANGELOG.md notes. Publishing
#      runs .github/workflows/homebrew-release.yml, which refuses a tag that
#      does not match MIMI_VERSION and updates the nkwabyte/homebrew-mimi tap.
#   8. Waits for that workflow.
#   9. Fast-forwards dev to main so the next change starts from the release.
#
# patch/minor/major count from the newest vX.Y.Z tag. Stops at the first
# failure; every step before publishing can simply be run again.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

target="" SKIP_TESTS=0 WATCH=1 PUBLISH_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --no-watch) WATCH=0; shift ;;
    --publish-only) PUBLISH_ONLY=1; shift ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$target" ] || die "only one version, please"; target="$1"; shift ;;
  esac
done
[ -n "$target" ] || usage 1

cd "$REPO_ROOT"
version="$(resolve_version "$target")"
is_semver "$version" || die "not a version (X.Y.Z): $target"
tag="v$version"
[ "$DRY_RUN" = 1 ] && printf '%s(dry run: nothing will be changed)%s\n' "$_Y" "$_N"

# ---------------------------------------------------------------------------
step "1. Checks"
# ---------------------------------------------------------------------------
command -v git > /dev/null || die "git is required"
command -v gh > /dev/null || die "the GitHub CLI (gh) is required: brew install gh"
gh auth status > /dev/null 2>&1 || die "gh is not logged in: gh auth login"
ok "git and gh available, gh logged in"

git fetch --quiet --tags origin || die "git fetch failed"
last="$(latest_tag_version)"
version_gt "$version" "$last" || die "$version is not newer than the last release v$last"
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null || git ls-remote --exit-code --tags origin "refs/tags/$tag" > /dev/null 2>&1; then
  die "tag $tag already exists"
fi
ok "$tag is new (last release v$last)"

if [ "$PUBLISH_ONLY" = 0 ]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "$DEV_BRANCH" ] || die "release from the $DEV_BRANCH branch (you are on $branch)"
  [ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes; commit or stash them first"
  behind="$(git rev-list --count "HEAD..origin/$DEV_BRANCH")"
  [ "$behind" = 0 ] || die "$DEV_BRANCH is $behind commit(s) behind origin/$DEV_BRANCH; pull first"
  ok "on $DEV_BRANCH, clean, up to date"
  if ! changelog_has_version "$version" && ! changelog_unreleased_nonempty; then
    die "CHANGELOG.md has no notes for $version: add them under ## [Unreleased]"
  fi
  ok "CHANGELOG.md has notes for $version"
fi

if [ "$PUBLISH_ONLY" = 0 ]; then
  # -------------------------------------------------------------------------
  step "2. Tests"
  # -------------------------------------------------------------------------
  if [ "$SKIP_TESTS" = 1 ]; then
    warn "skipped (--skip-tests)"
  elif [ "$DRY_RUN" = 1 ]; then
    info "would run ./tests/run (skipped in a dry run)"
  else
    ./tests/run < /dev/null > "${TMPDIR:-/tmp}/mimi-release-tests.log" 2>&1 || {
      tail -20 "${TMPDIR:-/tmp}/mimi-release-tests.log" >&2
      die "tests failed; full output in ${TMPDIR:-/tmp}/mimi-release-tests.log"
    }
    ok "$(grep -c '^ok ' "${TMPDIR:-/tmp}/mimi-release-tests.log") tests passed"
  fi

  # -------------------------------------------------------------------------
  step "3. Bump version and changelog"
  # -------------------------------------------------------------------------
  if [ "$DRY_RUN" = 1 ]; then
    info "would set MIMI_VERSION=$version and date CHANGELOG.md [$version]"
    run git commit -m "release: $tag"
    run git push origin "$DEV_BRANCH"
  else
    "$REPO_ROOT/scripts/bump-version.sh" "$version"
    git --no-pager diff --stat
    ask "Commit \"release: $tag\" on $DEV_BRANCH and push it?" || die "stopped before committing (the bump is left in your working tree)"
    run git add "$GLOBALS_FILE" "$CHANGELOG_FILE"
    run git commit -m "release: $tag"
    run git push origin "$DEV_BRANCH"
  fi

  # -------------------------------------------------------------------------
  step "4. Pull request $DEV_BRANCH -> $MAIN_BRANCH"
  # -------------------------------------------------------------------------
  notes="$(mktemp "${TMPDIR:-/tmp}/mimi-notes-XXXXXX")"
  trap 'rm -f "$notes"' EXIT
  if [ "$DRY_RUN" = 1 ]; then
    changelog_section "Unreleased" > "$notes"
  else
    changelog_section "$version" > "$notes"
  fi
  pr="$(gh pr list -R "$GITHUB_REPO" --base "$MAIN_BRANCH" --head "$DEV_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$pr" ]; then
    ok "reusing open pull request #$pr"
  elif [ "$DRY_RUN" = 1 ]; then
    run gh pr create -R "$GITHUB_REPO" --base "$MAIN_BRANCH" --head "$DEV_BRANCH" --title "Release $tag" --body-file "$notes"
    pr="<new>"
  else
    run gh pr create -R "$GITHUB_REPO" --base "$MAIN_BRANCH" --head "$DEV_BRANCH" --title "Release $tag" --body-file "$notes"
    pr="$(gh pr list -R "$GITHUB_REPO" --base "$MAIN_BRANCH" --head "$DEV_BRANCH" --state open --json number --jq '.[0].number')"
    [ -n "$pr" ] || die "could not find the pull request that was just created"
    ok "opened pull request #$pr"
  fi
  # CI runs on an older macOS than most development machines; a release
  # must not merge while it is red or still running.
  if [ "$DRY_RUN" = 1 ]; then
    run gh pr checks -R "$GITHUB_REPO" "$pr" --watch --fail-fast
  else
    info "waiting for CI on pull request #$pr ..."
    sleep 10
    if ! gh pr checks -R "$GITHUB_REPO" "$pr" --watch --fail-fast; then
      die "CI failed on pull request #$pr; fix it on $DEV_BRANCH and run this again (the PR is reused)"
    fi
    ok "CI passed on pull request #$pr"
  fi
  ask "Merge pull request #$pr into $MAIN_BRANCH?" || die "stopped before merging; merge #$pr yourself, then run: scripts/release.sh $version --publish-only"
  if ! run gh pr merge -R "$GITHUB_REPO" "$pr" --merge; then
    die "merge failed (checks or review pending?). Merge #$pr, then run: scripts/release.sh $version --publish-only"
  fi
fi

# ---------------------------------------------------------------------------
step "5. Verify $MAIN_BRANCH"
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  info "would check that origin/$MAIN_BRANCH has MIMI_VERSION=\"$version\""
else
  git fetch --quiet origin "$MAIN_BRANCH"
  main_version="$(git show "origin/$MAIN_BRANCH:lib/core/globals.sh" | sed -n 's/^MIMI_VERSION="\(.*\)"$/\1/p')"
  [ "$main_version" = "$version" ] || die "origin/$MAIN_BRANCH has MIMI_VERSION=$main_version, expected $version (is the release PR merged?)"
  git show "origin/$MAIN_BRANCH:CHANGELOG.md" | grep -q "^## \[$version\]" || die "origin/$MAIN_BRANCH CHANGELOG.md has no [$version] section"
  ok "origin/$MAIN_BRANCH is at $version ($(git rev-parse --short "origin/$MAIN_BRANCH"))"
fi

# ---------------------------------------------------------------------------
step "6. Tag $tag"
# ---------------------------------------------------------------------------
ask "Tag origin/$MAIN_BRANCH as $tag and push the tag?" || die "stopped before tagging"
run git tag -a "$tag" "origin/$MAIN_BRANCH" -m "mimi $tag"
run git push origin "$tag"

# ---------------------------------------------------------------------------
step "7. Publish the GitHub release"
# ---------------------------------------------------------------------------
notes="${notes:-$(mktemp "${TMPDIR:-/tmp}/mimi-notes-XXXXXX")}"
trap 'rm -f "$notes"' EXIT
if [ "$DRY_RUN" = 1 ] && ! changelog_has_version "$version"; then
  changelog_section "Unreleased" > "$notes"
else
  git show "origin/$MAIN_BRANCH:CHANGELOG.md" > "$notes.full" 2>/dev/null || cp "$CHANGELOG_FILE" "$notes.full"
  CHANGELOG_FILE="$notes.full" changelog_section "$version" > "$notes"
  rm -f "$notes.full"
fi
if [ -s "$notes" ]; then
  info "release notes: $(wc -l < "$notes" | tr -d ' ') line(s) from CHANGELOG.md [$version]"
else
  warn "release notes are empty"
fi
ask "Publish release $tag? This updates the Homebrew tap for everyone." || die "stopped before publishing; the tag is pushed. Publish later with: gh release create $tag --verify-tag"
run gh release create "$tag" -R "$GITHUB_REPO" --verify-tag --title "mimi $tag" --notes-file "$notes"

# ---------------------------------------------------------------------------
step "8. Homebrew tap workflow"
# ---------------------------------------------------------------------------
if [ "$WATCH" = 0 ] || [ "$DRY_RUN" = 1 ]; then
  info "not waiting; check with: gh run list -R $GITHUB_REPO --workflow $RELEASE_WORKFLOW"
else
  run_id=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    run_id="$(gh run list -R "$GITHUB_REPO" --workflow "$RELEASE_WORKFLOW" --event release --limit 1 \
      --json databaseId,createdAt --jq '.[0].databaseId' 2>/dev/null || true)"
    [ -n "$run_id" ] && break
    sleep 5
  done
  if [ -z "$run_id" ]; then
    warn "could not find the workflow run; check: gh run list -R $GITHUB_REPO --workflow $RELEASE_WORKFLOW"
  elif gh run watch -R "$GITHUB_REPO" "$run_id" --exit-status; then
    ok "Homebrew tap updated"
  else
    die "the Homebrew workflow failed: gh run view -R $GITHUB_REPO $run_id --log-failed"
  fi
fi

# ---------------------------------------------------------------------------
step "9. Sync $DEV_BRANCH with $MAIN_BRANCH"
# ---------------------------------------------------------------------------
if [ "$(git rev-parse --abbrev-ref HEAD)" = "$DEV_BRANCH" ] && [ -z "$(git status --porcelain)" ]; then
  if run git merge --ff-only "origin/$MAIN_BRANCH"; then
    run git push origin "$DEV_BRANCH"
  else
    warn "$DEV_BRANCH cannot fast-forward to $MAIN_BRANCH; merge origin/$MAIN_BRANCH into it yourself"
  fi
else
  warn "not on a clean $DEV_BRANCH; update it later with: git checkout $DEV_BRANCH && git merge --ff-only origin/$MAIN_BRANCH"
fi

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run complete — nothing was changed"
  exit 0
fi
step "Released $tag"
info "Users update with:  brew update && brew upgrade nkwabyte/mimi/mimi"
info "Release page:       https://github.com/$GITHUB_REPO/releases/tag/$tag"
