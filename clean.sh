#!/usr/bin/env bash
#
# clean.sh — compatibility shim.
#
# The implementation moved to bin/cleanmymac plus lib/*.sh. This keeps the
# documented ./clean.sh invocation working exactly as before.
#
# It *sources* the entry point rather than exec'ing it, for two reasons:
#
#   * $0 stays pointing at this file, so the tool keeps calling itself
#     "clean.sh" in usage errors and prompts — the contract DEC-004 fixed;
#   * the interpreter does not change. `/bin/bash clean.sh` really does run
#     under bash 3.2, which an exec would hand to whatever `env bash` finds
#     first, quietly defeating the test suite's 3.2 guarantee.

_cleanmymac_shim_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

if [ ! -f "$_cleanmymac_shim_dir/bin/cleanmymac" ]; then
  printf 'clean.sh: error: bin/cleanmymac is missing from %s\n' "$_cleanmymac_shim_dir" >&2
  exit 1
fi

# shellcheck source=bin/cleanmymac
. "$_cleanmymac_shim_dir/bin/cleanmymac"
