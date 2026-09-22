#!/usr/bin/env bats
#
# path_api.bats — P0-T03: canonical path and containment API.
#
# Two layers:
#   1. unit tests that source clean.sh with MIMI_LIB_ONLY=1 and call the
#      path helpers directly;
#   2. end-to-end tests that drive the real CLI and assert that nothing outside
#      the fixture's allowed roots was touched.
#
# The escape cases here are the whole point of the task: every one of them is a
# path that the previous string-prefix checks accepted.

load 'test_helper'

# Load clean.sh's helper library without running the CLI.
source_lib() {
  load_lib
  LOG_FILE="$TEST_TMPDIR/test.log"
  : > "$LOG_FILE"
}

# `run` executes its command in a subshell, so a global the command sets is
# invisible afterwards. PATH_DENY_REASON is exactly such a global, so refusals
# are asserted through this helper instead: a plain function call shares the
# caller's shell, and only the canonical path (unwanted here) is redirected.
authorize_fails() {
  if path_authorize "$@" > /dev/null; then
    echo "expected path_authorize to refuse: $1" >&2
    return 1
  fi
  return 0
}

# $FAKE_HOME lives under $BATS_TMPDIR, which on macOS is itself reached through
# the /var -> /private/var symlink. Canonical output is therefore never the
# literal $FAKE_HOME string, so tests compare against the physical path.
real() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# ---------------------------------------------------------------------------
# path_canonicalize
# ---------------------------------------------------------------------------

@test "canonicalize: an existing directory resolves to its physical path" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  run path_canonicalize "$FAKE_HOME/Library/Caches/app"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches/app")" ]
}

@test "canonicalize: an existing *file* resolves (the old cd-based version could not)" {
  source_lib
  printf 'x\n' > "$FAKE_HOME/Library/Caches/loose.bin"
  run path_canonicalize "$FAKE_HOME/Library/Caches/loose.bin"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/loose.bin" ]
}

@test "canonicalize: a path that does not exist still resolves its real ancestor" {
  source_lib
  run path_canonicalize "$FAKE_HOME/Library/Caches/not/here/yet"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/not/here/yet" ]
}

@test "canonicalize: '.' and redundant slashes are collapsed" {
  source_lib
  run path_canonicalize "$FAKE_HOME/Library/./Caches//"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")" ]
}

@test "canonicalize: '..' is collapsed against the real directory structure" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/a/b"
  run path_canonicalize "$FAKE_HOME/Library/Caches/a/b/../b"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches/a/b")" ]
}

@test "canonicalize: '..' walks out of HOME instead of being ignored" {
  source_lib
  run path_canonicalize "$FAKE_HOME/Library/Caches/../../.."
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/..")" ]
}

@test "canonicalize: a tilde path expands to HOME" {
  source_lib
  run path_canonicalize "~/Library/Caches"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")" ]
}

@test "canonicalize: an intermediate symlink is followed" {
  source_lib
  mkdir -p "$FAKE_HOME/real/inner"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"
  run path_canonicalize "$FAKE_HOME/Library/Caches/link/inner"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/real/inner")" ]
}

@test "canonicalize: a relative symlink is resolved against its own directory" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/target/inner"
  ln -s "target" "$FAKE_HOME/Library/Caches/rel"
  run path_canonicalize "$FAKE_HOME/Library/Caches/rel/inner"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches/target/inner")" ]
}

@test "canonicalize: follow resolves a final symlink, nofollow keeps it" {
  source_lib
  mkdir -p "$FAKE_HOME/real"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"

  run path_canonicalize "$FAKE_HOME/Library/Caches/link" follow
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/real")" ]

  run path_canonicalize "$FAKE_HOME/Library/Caches/link" nofollow
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/link" ]
}

@test "canonicalize: a broken symlink resolves to its missing target, not an error" {
  source_lib
  ln -s "$FAKE_HOME/Library/Caches/gone" "$FAKE_HOME/Library/Caches/dangling"

  run path_canonicalize "$FAKE_HOME/Library/Caches/dangling" follow
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/gone" ]

  run path_canonicalize "$FAKE_HOME/Library/Caches/dangling" nofollow
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/dangling" ]
}

@test "canonicalize: a symlink loop fails instead of hanging" {
  source_lib
  ln -s "$FAKE_HOME/Library/Caches/loopB" "$FAKE_HOME/Library/Caches/loopA"
  ln -s "$FAKE_HOME/Library/Caches/loopA" "$FAKE_HOME/Library/Caches/loopB"
  run path_canonicalize "$FAKE_HOME/Library/Caches/loopA/x"
  [ "$status" -ne 0 ]
}

@test "canonicalize: an empty path fails" {
  source_lib
  run path_canonicalize ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# path_kind
# ---------------------------------------------------------------------------

@test "kind: reports missing, file, dir, and symlink distinctly" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/adir"
  printf 'x\n' > "$FAKE_HOME/Library/Caches/afile"
  ln -s "$FAKE_HOME/Library/Caches/adir" "$FAKE_HOME/Library/Caches/alink"

  [ "$(path_kind "$FAKE_HOME/Library/Caches/nothing")" = "missing" ]
  [ "$(path_kind "$FAKE_HOME/Library/Caches/afile")" = "file" ]
  [ "$(path_kind "$FAKE_HOME/Library/Caches/adir")" = "dir" ]
  [ "$(path_kind "$FAKE_HOME/Library/Caches/alink")" = "symlink" ]
}

@test "kind: a broken symlink is a symlink, not missing" {
  source_lib
  ln -s "$FAKE_HOME/Library/Caches/gone" "$FAKE_HOME/Library/Caches/dangling"
  [ "$(path_kind "$FAKE_HOME/Library/Caches/dangling")" = "symlink" ]
}

# ---------------------------------------------------------------------------
# path_identity
# ---------------------------------------------------------------------------

@test "identity: is stable for one path and differs between two files" {
  source_lib
  printf 'a\n' > "$FAKE_HOME/Library/Caches/one"
  printf 'b\n' > "$FAKE_HOME/Library/Caches/two"
  local a b c
  a="$(path_identity "$FAKE_HOME/Library/Caches/one")"
  b="$(path_identity "$FAKE_HOME/Library/Caches/one")"
  c="$(path_identity "$FAKE_HOME/Library/Caches/two")"
  [ -n "$a" ]
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
}

@test "identity: changes when a path is replaced by a different object" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/swap"
  local before after
  before="$(path_identity "$FAKE_HOME/Library/Caches/swap")"
  rm -rf "$FAKE_HOME/Library/Caches/swap"
  mkdir -p "$FAKE_HOME/Library/Caches/swap"
  after="$(path_identity "$FAKE_HOME/Library/Caches/swap")"
  [ "$before" != "$after" ]
}

@test "identity: does not follow a final symlink" {
  source_lib
  mkdir -p "$FAKE_HOME/real"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"
  [ "$(path_identity "$FAKE_HOME/Library/Caches/link")" != "$(path_identity "$FAKE_HOME/real")" ]
}

@test "identity: a missing path fails" {
  source_lib
  run path_identity "$FAKE_HOME/Library/Caches/nothing"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# path_contains — component boundaries, not string prefixes
# ---------------------------------------------------------------------------

@test "contains: a direct child is contained" {
  source_lib
  path_contains "/a/b" "/a/b/c"
}

@test "contains: a deep descendant is contained" {
  source_lib
  path_contains "/a/b" "/a/b/c/d/e"
}

@test "contains: the root itself is contained" {
  source_lib
  path_contains "/a/b" "/a/b"
}

@test "contains: a sibling with the same textual prefix is NOT contained" {
  source_lib
  ! path_contains "/a/b" "/a/bc"
  ! path_contains "/a/b" "/a/bcd/e"
  ! path_contains "$FAKE_HOME/Library/Caches" "$FAKE_HOME/Library/Caches2/x"
}

@test "contains: a parent is not contained in its own child" {
  source_lib
  ! path_contains "/a/b/c" "/a/b"
}

@test "contains: a root containing glob characters is matched literally" {
  source_lib
  path_contains '/a/*/b' '/a/*/b/c'
  ! path_contains '/a/*/b' '/a/zzz/b/c'
  path_contains '/a/[x]' '/a/[x]/y'
}

@test "contains: trailing slashes do not change the answer" {
  source_lib
  path_contains "/a/b/" "/a/b/c/"
  path_contains "/a/b/" "/a/b"
}

# ---------------------------------------------------------------------------
# path_authorize — the single gate
# ---------------------------------------------------------------------------

@test "authorize: a direct child under an allowed root is authorized" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/app"
  run path_authorize "$FAKE_HOME/Library/Caches/app"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches/app")" ]
}

@test "authorize: a path inside the per-user temp root is authorized" {
  source_lib
  mkdir -p "$TMPDIR/scratch"
  run path_authorize "$TMPDIR/scratch"
  [ "$status" -eq 0 ]
}

@test "authorize: a '..' component is rejected outright" {
  source_lib
  authorize_fails "$FAKE_HOME/Library/Caches/../../../etc/passwd"
  [ "$PATH_DENY_REASON" = "traversal" ]
}

@test "authorize: a '..' that stays inside HOME is still rejected" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/a"
  authorize_fails "$FAKE_HOME/Library/Caches/a/../a"
  [ "$PATH_DENY_REASON" = "traversal" ]
}

@test "authorize: a filename that merely contains dots is not traversal" {
  source_lib
  printf 'x\n' > "$FAKE_HOME/Library/Caches/..config"
  run path_authorize "$FAKE_HOME/Library/Caches/..config"
  [ "$status" -eq 0 ]
}

@test "authorize: a relative path is rejected" {
  source_lib
  authorize_fails "Library/Caches"
  [ "$PATH_DENY_REASON" = "relative" ]
}

@test "authorize: an empty path is rejected" {
  source_lib
  authorize_fails ""
  [ "$PATH_DENY_REASON" = "empty" ]
}

@test "authorize: a path outside every allowed root is rejected" {
  source_lib
  authorize_fails "/etc/passwd"
  [ "$PATH_DENY_REASON" = "outside-root" ]
}

@test "authorize: the fixture's own parent directory is outside the allowed roots" {
  source_lib
  authorize_fails "$SENTINEL_PARENT"
  [ "$PATH_DENY_REASON" = "outside-root" ]
}

@test "authorize: HOME itself is forbidden" {
  source_lib
  authorize_fails "$FAKE_HOME"
  [ "$PATH_DENY_REASON" = "forbidden" ]
}

@test "authorize: the forbidden exact roots are all rejected" {
  source_lib
  local p
  for p in / /System /Library /Applications /usr /bin /sbin /etc /var /private /Users; do
    run path_authorize "$p"
    [ "$status" -ne 0 ]
  done
}

@test "authorize: /var is still caught after resolving to /private/var" {
  source_lib
  authorize_fails "/var"
  [ "$PATH_DENY_REASON" = "forbidden" ]
  authorize_fails "/private/var"
  [ "$PATH_DENY_REASON" = "forbidden" ]
}

@test "authorize: a symlink in an intermediate component cannot escape the allowed roots" {
  source_lib
  local outside="${TEST_TMPDIR%/*}/outside-$$"
  mkdir -p "$outside/secret"
  ln -s "$outside" "$FAKE_HOME/Library/Caches/escape"
  authorize_fails "$FAKE_HOME/Library/Caches/escape/secret"
  [ "$PATH_DENY_REASON" = "outside-root" ]
  rm -rf "$outside"
}

@test "authorize: a final symlink is authorized as the link itself, not its target" {
  source_lib
  local outside="${TEST_TMPDIR%/*}/outside-$$"
  mkdir -p "$outside"
  ln -s "$outside" "$FAKE_HOME/Library/Caches/escape"
  run path_authorize "$FAKE_HOME/Library/Caches/escape"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/escape" ]
  rm -rf "$outside"
}

@test "authorize: the no-symlink policy refuses a final symlink" {
  source_lib
  mkdir -p "$FAKE_HOME/real"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"
  authorize_fails "$FAKE_HOME/Library/Caches/link" no-symlink
  [ "$PATH_DENY_REASON" = "symlink" ]
}

@test "authorize: a broken symlink is authorized as the link itself" {
  source_lib
  ln -s "$FAKE_HOME/Library/Caches/gone" "$FAKE_HOME/Library/Caches/dangling"
  run path_authorize "$FAKE_HOME/Library/Caches/dangling"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$FAKE_HOME/Library/Caches")/dangling" ]
}

@test "authorize: a broken symlink pointing outside is refused under follow semantics too" {
  source_lib
  ln -s "/etc/nope" "$FAKE_HOME/Library/Caches/dangling"
  # nofollow authorizes the link's own location...
  run path_authorize "$FAKE_HOME/Library/Caches/dangling"
  [ "$status" -eq 0 ]
  # ...and the target it names is not itself authorizable.
  run path_authorize "/etc/nope"
  [ "$status" -ne 0 ]
}

@test "authorize: an explicitly registered root widens the envelope" {
  source_lib
  local extra="${TEST_TMPDIR%/*}/extra-$$"
  mkdir -p "$extra/cache"
  run path_authorize "$extra/cache"
  [ "$status" -ne 0 ]
  path_roots_ready
  path_register_allowed_root "$extra"
  run path_authorize "$extra/cache"
  [ "$status" -eq 0 ]
  rm -rf "$extra"
}

@test "authorize: an allowed root containing a space is not word-split" {
  source_lib
  # Outside $TEST_TMPDIR, whose parent is already an allowed root by way of
  # $TMPDIR, so that the refusal below means something.
  local outside="${TEST_TMPDIR%/*}/split-$$"
  local extra="$outside/an allowed root"
  mkdir -p "$extra/inner" "$outside/an"

  path_roots_ready
  path_register_allowed_root "$extra"

  run path_authorize "$extra/inner"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$extra/inner")" ]

  # A sibling matching the root's first whitespace-delimited word must still be
  # refused; it would be authorized if the root had been split on whitespace.
  authorize_fails "$outside/an"
  [ "$PATH_DENY_REASON" = "outside-root" ]

  rm -rf "$outside"
}

@test "whitelist: an entry containing a space protects only that path" {
  source_lib
  local base="$FAKE_HOME/Library/Caches"
  mkdir -p "$base/my app" "$base/my other app"
  WHITELIST=("$base/my app")
  is_whitelisted "$base/my app"
  ! is_whitelisted "$base/my other app"
}

# ---------------------------------------------------------------------------
# Hostile filenames — every one of these must survive round-tripping intact
# ---------------------------------------------------------------------------

@test "authorize: whitespace, glob, dash, hash, tab and unicode filenames round-trip exactly" {
  source_lib
  local base="$FAKE_HOME/Library/Caches"
  local names=(
    "a file with spaces"
    "star*glob"
    "question?mark"
    "brackets[abc]"
    "-leading-dash"
    "has#hash"
    "has'quote"
    'has"doublequote'
    'has$dollar'
    'back\slash'
    "semi;colon"
    "café-ünïcode-日本語"
    "trailing "
  )
  local n
  for n in "${names[@]}"; do
    mkdir -p "$base/$n"
    run path_authorize "$base/$n"
    [ "$status" -eq 0 ]
    [ "$output" = "$(real "$base")/$n" ]
  done
}

@test "authorize: a filename containing a tab round-trips exactly" {
  source_lib
  local base name
  base="$FAKE_HOME/Library/Caches"
  name="$(printf 'has\tTAB')"
  mkdir -p "$base/$name"
  run path_authorize "$base/$name"
  [ "$status" -eq 0 ]
  [ "$output" = "$(real "$base")/$name" ]
}

@test "authorize: a filename containing a newline round-trips exactly" {
  source_lib
  local base name got
  base="$FAKE_HOME/Library/Caches"
  name="$(printf 'has\nNEWLINE')"
  mkdir -p "$base/$name"
  # `run` strips trailing newlines from $output, so capture directly instead.
  got="$(path_authorize "$base/$name")"
  [ "$got" = "$(real "$base")/$name" ]
}

@test "authorize: a glob-named sibling is not protected by a whitelist for another name" {
  source_lib
  mkdir -p "$FAKE_HOME/Library/Caches/keep" "$FAKE_HOME/Library/Caches/keep2"
  WHITELIST=("$FAKE_HOME/Library/Caches/keep")
  is_whitelisted "$FAKE_HOME/Library/Caches/keep"
  is_whitelisted "$FAKE_HOME/Library/Caches/keep/inner"
  ! is_whitelisted "$FAKE_HOME/Library/Caches/keep2"
}

@test "whitelist: an entry that is a symlink protects what it points at" {
  source_lib
  mkdir -p "$FAKE_HOME/real/inner"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"
  WHITELIST=("$FAKE_HOME/Library/Caches/link")
  is_whitelisted "$FAKE_HOME/real/inner"
}

# ---------------------------------------------------------------------------
# Mutation primitives
# ---------------------------------------------------------------------------

@test "clear_dir_contents: refuses a directory that is really a symlink" {
  source_lib
  MODE="clean"
  mkdir -p "$FAKE_HOME/real/keepme"
  printf 'precious\n' > "$FAKE_HOME/real/keepme/data"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/link"

  run clear_dir_contents "$FAKE_HOME/Library/Caches/link"
  [ "$status" -ne 0 ]
  [ -f "$FAKE_HOME/real/keepme/data" ]
}

@test "clear_dir_contents: removes a broken symlink inside the directory" {
  source_lib
  MODE="clean"
  mkdir -p "$FAKE_HOME/Library/Caches/junk"
  ln -s "$FAKE_HOME/Library/Caches/junk/gone" "$FAKE_HOME/Library/Caches/junk/dangling"
  run clear_dir_contents "$FAKE_HOME/Library/Caches/junk"
  [ "$status" -eq 0 ]
  [ ! -L "$FAKE_HOME/Library/Caches/junk/dangling" ]
}

@test "clear_dir_contents: a symlink inside the directory is unlinked, its target is not" {
  source_lib
  MODE="clean"
  mkdir -p "$FAKE_HOME/Library/Caches/junk" "$FAKE_HOME/real"
  printf 'precious\n' > "$FAKE_HOME/real/data"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/junk/pointer"

  run clear_dir_contents "$FAKE_HOME/Library/Caches/junk"
  [ "$status" -eq 0 ]
  [ ! -L "$FAKE_HOME/Library/Caches/junk/pointer" ]
  [ -f "$FAKE_HOME/real/data" ]
}

@test "clear_dir_contents: refuses HOME itself" {
  source_lib
  MODE="clean"
  run clear_dir_contents "$FAKE_HOME"
  [ "$status" -ne 0 ]
  assert_fixture_sentinel_intact
}

@test "clear_dir_contents: refuses a directory outside every allowed root" {
  source_lib
  MODE="clean"
  local outside="${TEST_TMPDIR%/*}/outside-$$"
  mkdir -p "$outside"
  printf 'precious\n' > "$outside/data"
  run clear_dir_contents "$outside"
  [ "$status" -ne 0 ]
  [ -f "$outside/data" ]
  rm -rf "$outside"
}

@test "clear_dir_contents: refuses when the directory is replaced between check and mutation" {
  source_lib
  MODE="clean"
  mkdir -p "$FAKE_HOME/Library/Caches/victim"
  printf 'old\n' > "$FAKE_HOME/Library/Caches/victim/old"

  # dir_size_kb runs between the identity capture and the recheck, so swapping
  # the directory there is exactly the race the recheck exists to catch.
  dir_size_kb() {
    if [ -d "$FAKE_HOME/Library/Caches/victim/.swapped" ]; then
      printf '1'
      return 0
    fi
    rm -rf "$FAKE_HOME/Library/Caches/victim"
    mkdir -p "$FAKE_HOME/Library/Caches/victim/.swapped"
    printf 'planted\n' > "$FAKE_HOME/Library/Caches/victim/planted"
    printf '1'
  }

  run clear_dir_contents "$FAKE_HOME/Library/Caches/victim"
  [ "$status" -ne 0 ]
  [ -f "$FAKE_HOME/Library/Caches/victim/planted" ]
}

@test "remove_path: refuses when the target is replaced between check and mutation" {
  source_lib
  MODE="clean"
  mkdir -p "$FAKE_HOME/Library/Caches/victim"
  printf 'old\n' > "$FAKE_HOME/Library/Caches/victim/old"

  dir_size_kb() {
    if [ -f "$FAKE_HOME/Library/Caches/victim/planted" ]; then
      printf '1'
      return 0
    fi
    rm -rf "$FAKE_HOME/Library/Caches/victim"
    mkdir -p "$FAKE_HOME/Library/Caches/victim"
    printf 'planted\n' > "$FAKE_HOME/Library/Caches/victim/planted"
    printf '1'
  }

  run remove_path "$FAKE_HOME/Library/Caches/victim"
  [ "$status" -ne 0 ]
  [ -f "$FAKE_HOME/Library/Caches/victim/planted" ]
}

@test "remove_path: refuses a path outside every allowed root" {
  source_lib
  MODE="clean"
  printf 'precious\n' > "$SENTINEL_PARENT.extra"
  run remove_path "$SENTINEL_PARENT.extra"
  [ "$status" -ne 0 ]
  [ -f "$SENTINEL_PARENT.extra" ]
  rm -f "$SENTINEL_PARENT.extra"
}

@test "remove_path: unlinks a symlink without touching its target" {
  source_lib
  MODE="clean"
  mkdir -p "$FAKE_HOME/real"
  printf 'precious\n' > "$FAKE_HOME/real/data"
  ln -s "$FAKE_HOME/real" "$FAKE_HOME/Library/Caches/pointer"

  run remove_path "$FAKE_HOME/Library/Caches/pointer"
  [ "$status" -eq 0 ]
  [ ! -L "$FAKE_HOME/Library/Caches/pointer" ]
  [ -f "$FAKE_HOME/real/data" ]
}

@test "remove_path: a missing path is a silent no-op, not a failure" {
  source_lib
  MODE="clean"
  run remove_path "$FAKE_HOME/Library/Caches/never-existed"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# End to end through the real CLI
# ---------------------------------------------------------------------------

@test "cli: --clean does not follow a symlinked cache directory out of the allowed roots" {
  local outside="${TEST_TMPDIR%/*}/outside-$$"
  mkdir -p "$outside/precious"
  printf 'do not delete\n' > "$outside/precious/data"
  ln -s "$outside/precious" "$FAKE_HOME/Library/Caches/escape"

  run_clean --clean --yes --only caches
  [ -f "$outside/precious/data" ]
  verify_sentinels
  rm -rf "$outside"
}

@test "cli: --clean removes cache entries with hostile filenames" {
  local base="$FAKE_HOME/Library/Caches" d
  # cat_caches clears the contents of each cache subdirectory (keeping the
  # directory) and removes loose files outright.
  for d in "star*glob" "-leading-dash" "has#hash" "café-ünïcode" "with spaces"; do
    mkdir -p "$base/$d"
    printf 'x\n' > "$base/$d/payload"
  done
  printf 'x\n' > "$base/a loose file"

  run_clean --clean --yes --only caches
  [ "$status" -eq 0 ]
  for d in "star*glob" "-leading-dash" "has#hash" "café-ünïcode" "with spaces"; do
    [ -d "$base/$d" ]
    [ ! -e "$base/$d/payload" ]
  done
  [ ! -e "$base/a loose file" ]
  assert_fixture_sentinel_intact
}

@test "cli: --whitelist protects a path but not a same-prefix sibling" {
  local base="$FAKE_HOME/Library/Caches"
  mkdir -p "$base/keep" "$base/keep2"
  printf 'x\n' > "$base/keep/data"
  printf 'x\n' > "$base/keep2/data"

  run_clean --clean --yes --only caches --whitelist "$base/keep"
  [ "$status" -eq 0 ]
  [ -f "$base/keep/data" ]
  [ ! -e "$base/keep2/data" ]
}
