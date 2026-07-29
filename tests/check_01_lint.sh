#!/usr/bin/env bash
# Check 1: every fenced bash block is lint-classified; cookbook blocks lint clean.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

# 1. No unmarked blocks. An unmarked block would silently escape the linter.
unmarked="$(python3 lib/extract.py unmarked)"
if [ -z "$unmarked" ]; then
  _ok "every bash fence carries a lint: marker"
else
  _fail "unmarked bash fences at document lines: $(printf '%s' "$unmarked" | tr '\n' ' ')"
fi

# 2. Syntax-check everything.
python3 lib/extract.py cookbook >/dev/null 2>&1 || { _fail "cookbook not extractable"; finish; }
python3 lib/extract.py snippets
snippets_extract_rc=$?
if [ "$snippets_extract_rc" -ne 0 ]; then
  _fail "extract.py snippets exited non-zero (rc=$snippets_extract_rc)"
fi

# 2a. INVARIANT: the cookbook is definitions only. A top-level statement would
#     execute on `source`, and a top-level ${VAR:?} would abort the sourcing
#     shell -- which is exactly how the test suite loads these helpers.
#     Detect this by TRACING EXECUTION, not by parsing braces and not by diffing
#     variables. Two weaker detectors were tried and both fail:
#       - A brace-counting awk heuristic: a one-liner such as `f() { :; }`
#         increments the depth and never matches a lone `^}`, so every following
#         top-level statement is treated as inside a function. Verified: it
#         reported no offender for a file containing a bare `LEAK=1`.
#       - Diffing `compgen -v` before/after sourcing: it only sees NEW VARIABLE
#         NAMES, so `umask 000`, `cd`, `trap`, `touch`, or reassigning an existing
#         variable all pass. Verified: a file with top-level `umask 000` reported
#         no leak.
#
#     `set -o functrace` makes a DEBUG trap fire for commands inside a sourced
#     file, and — verified — it fires for `umask 000` and `touch` but NOT for a
#     function definition. So a definitions-only file executes zero top-level
#     commands, and anything the trap reports is a real side effect.
#     Note: any non-zero rc means "did not source cleanly". A top-level ${VAR:?}
#     kills the shell outright, so a trailing `|| exit N` never runs and the
#     observed code is bash's own -- do not test for a sentinel value.
sidelog="$BUILD/sideeffects.txt"
env -i bash --noprofile --norc lib/sideeffects.sh "$BUILD/cookbook.sh" > "$sidelog" 2>&1
src_rc=$?

if [ "$src_rc" -ne 0 ]; then
  # Any non-zero status: the file did not source cleanly. The probe cannot use a
  # sentinel code because a top-level ${VAR:?} kills the shell before the probe's
  # own exit runs.
  _fail "cookbook does not source cleanly in a pristine shell (rc=$src_rc)"
  note "a top-level \${VAR:?} aborts the sourcing shell; move it into init_orchestration_vars"
  head -3 "$sidelog" | while IFS= read -r l; do note "$l"; done
elif [ ! -s "$sidelog" ]; then
  _ok "cookbook executes no top-level commands (definitions only)"
else
  _fail "cookbook executes top-level commands; move them into init_orchestration_vars"
  head -10 "$sidelog" | while IFS= read -r l; do note "$l"; done
fi

bash -n "$BUILD/cookbook.sh" && _ok "cookbook.sh is syntactically valid" \
                             || _fail "cookbook.sh has a syntax error"
snippet_count=0
snippet_syntax_bad=0
for s in "$BUILD"/snippets/*.sh; do
  [ -e "$s" ] || break
  snippet_count=$((snippet_count + 1))
  bash -n "$s" || { _fail "syntax error in snippet from document line ${s##*/}"; snippet_syntax_bad=1; }
done
if [ "$snippet_count" -eq 0 ]; then
  _fail "zero snippets extracted -- extract.py snippets checked NOTHING (a snippet-extraction regression would silently pass here)"
elif [ "$snippet_syntax_bad" -eq 0 ]; then
  _ok "all $snippet_count snippets are syntactically valid"
fi

# 3. shellcheck the cookbook only. Snippets legitimately reference variables
#    they do not define, so full linting there would be noise.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --shell=bash --severity=warning "$BUILD/cookbook.sh"; then
    _ok "shellcheck is clean at severity=warning"
  else
    _fail "shellcheck reported warnings or errors"
  fi
  finish
else
  note "shellcheck is not installed; install with: sudo apt-get install -y shellcheck"
  note "syntax checks above still ran and passed"
  [ "$_FAILURES" -eq 0 ] && skip "shellcheck unavailable (syntax checks passed)"
  finish
fi
