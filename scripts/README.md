# Release scripts

Maintainer tools for cutting a `mimi` release. They need `git`, the GitHub CLI
(`gh auth login`), and run on the stock macOS Bash 3.2.

| Script | What it does |
|---|---|
| `scripts/version.sh` | Shows `MIMI_VERSION`, the last released tag, the next patch/minor/major, and whether `CHANGELOG.md` has unreleased notes. Read-only. |
| `scripts/bump-version.sh X.Y.Z\|patch\|minor\|major` | Sets `MIMI_VERSION` in `lib/core/globals.sh` and turns `## [Unreleased]` in `CHANGELOG.md` into `## [X.Y.Z] - <date>`, with compare links. Files only, no git. |
| `scripts/release.sh X.Y.Z\|patch\|minor\|major` | The whole release, below. |

## Cutting a release

Work happens on `dev`. Before releasing, describe the changes under
`## [Unreleased]` in `CHANGELOG.md` and commit everything.

```bash
scripts/version.sh                 # where are we?
scripts/release.sh minor --dry-run # see every step and command, change nothing
scripts/release.sh minor           # do it (asks before each push/merge/publish)
```

`release.sh` stops at the first failure, and asks before anything leaves your
machine:

1. **Checks**: on `dev`, clean, up to date with `origin/dev`; `gh` logged in;
   the version is newer than the last tag and the tag is unused; there are
   notes to release.
2. **Tests**: `./tests/run` (skip with `--skip-tests`, not recommended).
3. **Bump**: `bump-version.sh`, then commits `release: vX.Y.Z` on `dev` and
   pushes it.
4. **Pull request** `dev → main`: opened (or an open one reused) with the
   release notes, then merged.
5. **Verify** that `origin/main` carries the new `MIMI_VERSION` and changelog.
6. **Tag** `vX.Y.Z` on `origin/main` and push the tag.
7. **Publish** the GitHub release with the notes from `CHANGELOG.md`. This
   triggers `.github/workflows/homebrew-release.yml`, which refuses a tag that
   does not match `MIMI_VERSION` and updates the `nkwabyte/homebrew-mimi` tap.
8. **Wait** for that workflow (skip with `--no-watch`).
9. **Sync** `dev` to `main` (fast-forward) so the next change starts from the
   release.

Once step 7 is done, users get it with
`brew update && brew upgrade nkwabyte/mimi/mimi`.

### If it stops part-way

- **Before the merge** (tests, bump, PR): fix the problem and run the same
  command again. An open release PR is reused.
- **The merge failed or you merged the PR yourself**:
  `scripts/release.sh X.Y.Z --publish-only` tags `main`, publishes, watches,
  and syncs `dev`.
- **After the tag was pushed but before publishing**:
  `gh release create vX.Y.Z --verify-tag --notes-file <notes>`, or delete the
  tag (`git push origin :refs/tags/vX.Y.Z`) and start again.

Options: `--dry-run`, `--yes` (no questions), `--skip-tests`, `--no-watch`,
`--publish-only`, `--help`. `tests/release.bats` exercises the scripts against
a throwaway repository with a stub `gh`.
