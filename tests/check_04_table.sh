#!/usr/bin/env bash
# Check 6: the role table and the role_* lookups are one source of truth.
# EXPECTED RED until Task 5 (role_* functions + table rewrite).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

python3 lib/extract.py roles 2>/dev/null || { _fail "role table not parseable"; finish; }
load_cookbook || finish
# role_* are pure lookups: no orchestration variables needed.

for fn in role_model role_effort role_timeout; do
  if declare -F "$fn" >/dev/null; then _ok "$fn is defined"
  else _fail "$fn is not defined in the cookbook"; fi
done
[ "$_FAILURES" -eq 0 ] || finish

rows=0
# NOTE: `IFS=$'\t' read` collapses consecutive tabs and trims blank fields
# because tab is an IFS-whitespace character regardless of what IFS is set
# to -- it is NOT preserved as a plain delimiter the way e.g. ',' would be.
# Several roles have a genuinely empty `effort` cell, so field-splitting via
# `read` silently shifts columns. Use `cut` per field instead, which treats
# tab as a literal delimiter and preserves empty fields.
while IFS= read -r _row_line; do
  [ -n "$_row_line" ] || continue
  role="$(printf '%s' "$_row_line" | cut -f1)"
  case "$role" in orchestrator) continue ;; esac
  model="$(printf '%s' "$_row_line" | cut -f3)"
  effort="$(printf '%s' "$_row_line" | cut -f4)"
  timeout="$(printf '%s' "$_row_line" | cut -f5)"
  rows=$((rows + 1))
  assert_eq "$model"   "$(role_model   "$role")" "role_model $role"
  assert_eq "$effort"  "$(role_effort  "$role")" "role_effort $role"
  assert_eq "$timeout" "$(role_timeout "$role")" "role_timeout $role"
done < "$BUILD/roles.tsv"

assert_eq 24 "$rows" "role table covers all 24 dispatched roles"

# No stale ids, and no model may be named only in the table.
# `claude-fable-5` was dropped from the table in 19eb57e (spec-fixer, plan-writer
# and plan-fixer moved to opus); it is intentionally absent from this list.
for m in claude-haiku-4-5 claude-opus-5 claude-sonnet-5 gpt-5.6-luna gpt-5.6-sol; do
  "$GREP_BIN" -qF "$m" "$BUILD/roles.tsv" || _fail "table never assigns $m"
done

# An unknown role must be a loud error, not an empty string.
if role_model definitely-not-a-role >/dev/null 2>&1; then
  _fail "role_model accepts an unknown role"
else
  _ok "role_model rejects an unknown role"
fi

finish
