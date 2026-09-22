#!/usr/bin/env bash
#
# clean.sh — compatibility shim for the tool now called mimi.
#
# The implementation lives in bin/mimi plus lib/*.sh. This keeps every
# previously documented ./clean.sh invocation working unchanged.
#
# It *sources* the entry point rather than exec'ing it, for two reasons:
#
#   * $0 stays pointing at this file, so the tool keeps calling itself
#     "clean.sh" in usage errors and prompts — the contract DEC-004 fixed;
#   * the interpreter does not change. `/bin/bash clean.sh` really does run
#     under bash 3.2, which an exec would hand to whatever `env bash` finds
#     first, quietly defeating the test suite's 3.2 guarantee.

_mimi_shim_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

if [ ! -f "$_mimi_shim_dir/bin/mimi" ]; then
  printf 'clean.sh: error: bin/mimi is missing from %s\n' "$_mimi_shim_dir" >&2
  exit 1
fi

# On stderr so that piping or capturing stdout is unaffected.
printf 'clean.sh: note: this tool is now "mimi". ./clean.sh still works.\n' >&2

# shellcheck source=bin/mimi
. "$_mimi_shim_dir/bin/mimi"
