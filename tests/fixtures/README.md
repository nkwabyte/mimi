# tests/fixtures

Static fixture data for the test suite.

This directory is intentionally near-empty. The harness in
`../test_helper.bash` builds a **fresh, disposable fake home** under
`$BATS_TMPDIR` for every single test, so anything that needs to be created,
mutated or deleted is generated per-test rather than stored here.

Put a file here only when it is:

- **read-only** for the duration of a test, and
- **awkward to generate** in `setup()` — for example a realistic orphan review
  file, a captured `--list` snapshot to diff against, or a malformed config
  used to pin down parser behaviour.

Never point a test at a fixture it will modify. Copy it into the per-test
fake home first, so the copy is what gets destroyed and the original stays
authoritative.
