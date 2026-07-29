#!/usr/bin/env bash
# Check 3: appendix marker integrity.
# EXPECTED RED until Task 13 (parallel-dispatch appendix naming).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

begins="$("$GREP_BIN" -oP '^<!-- BEGIN: \K[a-z0-9-]+(?= -->$)' "$PROCESS_DOC" | sort)"
ends="$("$GREP_BIN"   -oP '^<!-- END: \K[a-z0-9-]+(?= -->$)'   "$PROCESS_DOC" | sort)"

assert_eq "$begins" "$ends" "every BEGIN marker has a matching END marker"

# Duplicate names would make awk range extraction span two appendices.
dupes="$(printf '%s\n' "$begins" | uniq -d)"
assert_eq "" "$dupes" "no duplicate appendix names"

# Every appendix name referenced in prose must exist as a marker pair.
missing=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$begins" | "$GREP_BIN" -qxF "$name" || missing="$missing $name"
done < <("$GREP_BIN" -oP '(?<=`)(?:preflight|spec|plan|code|context|summarizer|readiness|all-tests|test|finishing)[a-z0-9-]*(?=` appendix)' "$PROCESS_DOC" | sort -u)
assert_eq "" "$missing" "every appendix name referenced in prose has a marker pair"

# The Phase-7 bug class: an appendix name assembled from a variable cannot be
# statically resolved, and no value of $phase yields 'code-reviewer-claude'.
constructed="$("$GREP_BIN" -nE '(render_prompt|extract_appendix) +"?\$\{' "$PROCESS_DOC")"
if [ -z "$constructed" ]; then
  _ok "no appendix name is constructed from a variable"
else
  _fail "appendix names must be literal, not interpolated"
  printf '    %s\n' "$constructed"
fi

finish
