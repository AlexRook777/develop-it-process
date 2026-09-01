#!/usr/bin/env bash
# Self-test: the harness itself works.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

assert_eq "a" "a" "assert_eq accepts equal values"
assert_present '^# Universal SDLC' "$PROCESS_DOC" "process doc is readable and looks right"
assert_absent 'ZZZ_NEVER_PRESENT_ZZZ' "$PROCESS_DOC" "assert_absent works"

if python3 lib/extract.py cookbook 2>/dev/null && [ -s "$BUILD/cookbook.sh" ]; then
  note "cookbook staged from runtime/cookbook.sh ($(wc -l < "$BUILD/cookbook.sh") lines)"
else
  note "cookbook not stageable -- is runtime/cookbook.sh missing?"
fi

finish
