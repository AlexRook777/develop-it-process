#!/usr/bin/env bash
# Document contract regressions. Each entry corresponds to a spec success
# criterion. Later tasks append to this file; nothing is ever removed.
# EXPECTED RED until the task named in each assertion message lands.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

D="$PROCESS_DOC"

# --- Task 5: stale model ids ---
assert_absent 'claude-opus-4-8'   "$D" "T5: no claude-opus-4-8"
assert_absent 'claude-sonnet-4-6' "$D" "T5: no claude-sonnet-4-6"

# --- Task 6: strict pinning ---
assert_absent 'gpt-5\.3-codex|gpt-5\.2'  "$D" "T6: no nonexistent codex ids"
assert_absent '[Ff]all ?back.*model|model.*[Ff]all ?back' "$D" \
  "T6: no model fallback language"
assert_present 'codex .*-m "\$CODEX_MODEL"' "$D" "T6: codex model is bound explicitly"

# --- Task 9: environment ---
assert_absent '/home/worker|repos/GCP' "$D" "T9: no foreign hardcoded paths"
assert_present 'PROCESS_PATH="\$\{PROCESS_PATH:\?' "$D" "T9: PROCESS_PATH fails loud"
assert_present 'PROCESS_REPO_ROOT' "$D" "T9: two-root model present"
assert_present 'GREP_BIN' "$D" "T9: grep is pinned"

# --- Task 11: timing ---
assert_absent 'date \+%s%3N' "$D" "T11: no uutils-broken date format"
assert_present 'EPOCHREALTIME' "$D" "T11: EPOCHREALTIME used for ms timing"
assert_absent '^ *local t0=' "$D" "T11: no 'local' outside a function"

# --- Task 12: porcelain parsing ---
assert_absent "awk '\\{print \\\$2\\}'" "$D" "T12: no awk \$2 on porcelain"
assert_absent 'grep -Fvxf' "$D" "T12: no -x match of absolute vs relative paths"
assert_present 'porcelain=v1 -z' "$D" "T12: NUL-delimited porcelain"

# --- Task 13: parallel dispatch ---
assert_absent '(render_prompt|extract_appendix) +"?\$\{' "$D" \
  "T13: appendix names are literal"

# --- Task 15: shell hygiene ---
assert_absent 'export BASH_XTRACEFD' "$D" "T15: BASH_XTRACEFD is not exported"
assert_absent '\\\\S' "$D" "T15: no non-POSIX \\S in ERE"
assert_absent '\] && mv ' "$D" "T15: no trailing [ ] && mv"

# --- Task 18/19: dispatch ---
assert_present 'kill-after=60s' "$D" "T19: uniform kill-after grace"
assert_absent 'timeout [0-9]+m ' "$D" "T19: no literal minute values in invocations"
assert_present 'DISPATCH_STARTED' "$D" "T18: resumable dispatch event"

# --- Task 20: renames ---
assert_absent 'claude-opus-verdict\.md|claude-opus-findings\.md' "$D" \
  "T20: model-free artifact filenames"

# --- Task 21: contradictions ---
assert_present 'lint: cookbook' "$D" "T21: cookbook blocks are lint-classified"

finish
