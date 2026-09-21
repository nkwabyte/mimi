# Tests

Bats-based suite for `clean.sh`. Every test runs against a throwaway fake home
directory — no test can touch your real one.

## Running

```bash
./tests/run                 # everything
./tests/run smoke           # one file (smoke.bats)
./tests/run arg_validation  # ditto
```

`tests/run` installs bats-core via Homebrew if it is missing, runs
`/bin/bash -n clean.sh` as a syntax gate, then executes the suite.

## Developer tools

| Tool | Required? | Install |
|---|---|---|
| [bats-core](https://bats-core.readthedocs.io) | yes | `brew install bats-core` (or let `./tests/run` do it) |
| [ShellCheck](https://www.shellcheck.net) | recommended | `brew install shellcheck` |
| [shfmt](https://github.com/mvdan/sh) | recommended | `brew install shfmt` |

```bash
shellcheck -s bash clean.sh tests/test_helper.bash tests/run
shfmt -d -i 2 -ci clean.sh          # -d shows a diff; -w rewrites in place
/bin/bash -n clean.sh               # must pass on system bash 3.2
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
   apps the developer happens to have open.
4. Plants sentinel files **outside** the fixture root.

`teardown()` calls `verify_sentinels`, which fails the test if any sentinel
was deleted or modified — that is the escape alarm. It is not merely asserted
to stay quiet: `smoke.bats` deliberately tampers with a sentinel and asserts
the alarm fires, then restores it.

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

Helpers available: `run_clean`, `verify_sentinels`, `restore_sentinels`,
`assert_fixture_exists`, `assert_fixture_sentinel_intact`, `write_config`,
and the variables `FAKE_HOME`, `TEST_TMPDIR`, `CLEAN_SH`, `REPO_ROOT`.

Always pass `--no-log` unless the test is specifically about logging, and
always pass `--yes` for `--clean` runs, or the script will block on a prompt.
