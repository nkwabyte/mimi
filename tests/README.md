# Tests

Bats-based suite for the CLI. Every test runs against a throwaway fake home
directory — no test can touch your real one.

The code lives in `bin/cleanmymac` plus `lib/*.sh`; `clean.sh` at the repo root
is a shim over it. `run_clean` drives the shim, so the documented entry point
is what the whole suite exercises.

## Running

```bash
./tests/run                 # everything
./tests/run smoke           # one file (smoke.bats)
./tests/run arg_validation  # ditto
./tests/run path_api        # ditto
./tests/run orphan_review   # ditto
./tests/run orphan_report   # ditto
./tests/run mutation        # ditto
./tests/run layout          # ditto
./tests/run defects         # ditto
```

`tests/run` installs bats-core via Homebrew if it is missing, runs
`/bin/bash -n` over `clean.sh`, `bin/cleanmymac` and every `lib/*.sh` as a
syntax gate, then executes the suite.

## Developer tools

| Tool | Required? | Install |
|---|---|---|
| [bats-core](https://bats-core.readthedocs.io) | yes | `brew install bats-core` (or let `./tests/run` do it) |
| [ShellCheck](https://www.shellcheck.net) | recommended | `brew install shellcheck` |
| [shfmt](https://github.com/mvdan/sh) | recommended | `brew install shfmt` |

```bash
shellcheck -s bash clean.sh bin/cleanmymac lib/*.sh tests/test_helper.bash tests/run
shfmt -d -i 2 -ci clean.sh bin lib  # -d shows a diff; -w rewrites in place
/bin/bash -n clean.sh bin/cleanmymac lib/*.sh   # must pass on system bash 3.2
```

`clean.sh` targets macOS's system `/bin/bash` (3.2). No associative arrays, no
`${var,,}`, no fractional `read -t`. The suite runs the script under
`/bin/bash` explicitly so a newer Homebrew bash on `$PATH` cannot mask a
3.2 incompatibility.

## Layout

```text
tests/
├── run                 # entry point: tool check → syntax gate → bats
├── test_helper.bash    # fake-home fixture, sentinels, mock PATH, assertions
├── smoke.bats          # harness isolation + CLI characterization
├── arg_validation.bats # argument/config validation contract (P0-T08)
├── path_api.bats       # canonical path + containment API (P0-T03)
├── orphan_review.bats  # reviewed-orphan input validation (P0-T04)
├── orphan_report.bats  # report-only orphan discovery (P0-T06)
├── mutation.bats       # checked removals and truthful accounting (P0-T05)
├── layout.bats         # bin/lib split and the clean.sh shim
├── defects.bats        # contained correctness defects (P0-T10)
├── fixtures/           # static read-only fixture data (see its README)
└── mocks/bin/          # stubs for every external command clean.sh may call
```

## How isolation works

`setup()` in `test_helper.bash`:

1. Creates `$BATS_TMPDIR/cleanmymac-test-XXXXXX` and builds a fake
   `~/Library` tree inside it.
2. Exports `HOME` and `TMPDIR` to point into that fixture, so the script's
   config (`~/.config/cleanmymac`), logs (`~/Library/Logs/cleanmymac`),
   Trash and every Library path resolve inside it.
3. Prepends `tests/mocks/bin` to `PATH`, so `brew`, `docker`, `xcrun`,
   `qlmanage`, `mdfind`, `uv`, `go`, `yarn`, `pgrep` and friends are stubs.
   `pgrep` always reports nothing running, so results never depend on which
   apps the developer happens to have open. `mdfind`, `mdls` and `defaults`
   read an optional `$MOCK_APP_INDEX` file of `<app path>|<bundle id>` lines,
   so a test can describe exactly which applications Spotlight knows about.
4. Plants sentinel files **outside** the fixture root.

`teardown()` calls `verify_sentinels`, which fails the test if any sentinel
was deleted or modified — that is the escape alarm. It is not merely asserted
to stay quiet: `smoke.bats` deliberately tampers with a sentinel and asserts
the alarm fires, then restores it.

## Unit-testing internal helpers

Several test files need to call individual functions rather than observe them
through a whole run. They load the library directly:

```bash
load_lib        # . "$CLEANMYMAC_LIB/load.sh"
```

Every module is definitions only — argument parsing and dispatch live in
`bin/cleanmymac`, not in `lib/` — so sourcing the library defines everything
and runs nothing. `layout.bats` asserts that: loading it deletes no files,
writes no config, and ignores stray positional parameters.

One trap: bats' `run` executes its command in a subshell, so a global the
command sets — `PATH_DENY_REASON` or `ORPHAN_DENY_REASON`, for instance — is
gone by the time the assertion reads it. Call the function directly when the
global is the thing under test. The same trap bites inside the script itself:
`x="$(path_authorize "$p")"` gets the path but loses the reason, which is why
`path_authorize` also publishes `PATH_CANONICAL`.

## Driving the mocks

Two environment variables let a test steer any mocked command:

| Variable | Effect |
|---|---|
| `MOCK_CALL_LOG` | Every invocation is appended to this file as `<name> <args>`. Use it to count calls — that is how the duplicate QuickLook reset is pinned. |
| `MOCK_FAIL_CMDS` | A `\|`-separated list of glob patterns matched against the whole invocation. Any match exits 7 with a message on stderr. |

`MOCK_FAIL_CMDS` matches the *whole* invocation, not just the command name, on
purpose. Failing every `npm` call also breaks `npm config get cache`, and the
category then skips before it ever reaches the cleanup — so the test would pass
while proving nothing. Write the pattern for the call you mean:

```bash
export MOCK_FAIL_CMDS="npm cache clean*"     # the cleanup fails, queries work
export MOCK_FAIL_CMDS="yarn cache clean*|brew cleanup*"
```

A mock that answers queries has to be taught the answer. `npm config get
cache`, `pnpm store path` and `yarn cache dir` all return fixture paths; if you
add a category that asks a tool where its cache lives, extend that tool's mock
too or the category will silently skip.

## One thing the harness cannot isolate

`build_installed_identifiers` walks `/Applications`, `/System/Applications`
and friends directly, as a backstop for Spotlight. A mock on `$PATH` cannot
intercept a directory walk, so a test that drives the whole CLI really does
read the applications the developer has installed.

Unit tests avoid this by confining `ORPHAN_APP_WALK_ROOTS` to the fixture
(see `install_apps` in `orphan_report.bats`). Tests that drive the CLI cannot,
so they use fixture names no real application could match — `com.zzqqxx9.*`
rather than `com.example.*`, because `is_installed_identifier` does substring
matching in both directions and a real app called "Example" would silently
change the result.

## Adding a test

```bash
load 'test_helper'

@test "my new behaviour" {
  echo junk > "$FAKE_HOME/Library/Caches/thing.txt"

  run_clean --clean --yes --no-log --only caches

  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_HOME/Library/Caches/thing.txt" ]
}
```

Helpers available: `run_clean`, `run_cleanmymac`, `load_lib`,
`verify_sentinels`, `restore_sentinels`, `assert_fixture_exists`,
`assert_fixture_sentinel_intact`, `write_config`, and the variables
`FAKE_HOME`, `TEST_TMPDIR`, `CLEAN_SH`, `CLEANMYMAC_BIN`, `CLEANMYMAC_LIB`,
`REPO_ROOT`.

Always pass `--no-log` unless the test is specifically about logging, and
always pass `--yes` for `--clean` runs, or the script will block on a prompt.
