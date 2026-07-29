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
while IFS=$'\t' read -r role vendor model effort timeout; do
  [ -n "$role" ] || continue
  case "$role" in orchestrator) continue ;; esac
  rows=$((rows + 1))
  assert_eq "$model"   "$(role_model   "$role")" "role_model $role"
  assert_eq "$effort"  "$(role_effort  "$role")" "role_effort $role"
  assert_eq "$timeout" "$(role_timeout "$role")" "role_timeout $role"
done < "$BUILD/roles.tsv"

assert_eq 24 "$rows" "role table covers all 24 dispatched roles"

# No stale ids, and no model may be named only in the table.
for m in claude-fable-5 claude-opus-5 claude-sonnet-5 gpt-5.6-sol; do
  "$GREP_BIN" -qF "$m" "$BUILD/roles.tsv" || _fail "table never assigns $m"
done

# An unknown role must be a loud error, not an empty string.
if role_model definitely-not-a-role >/dev/null 2>&1; then
  _fail "role_model accepts an unknown role"
else
  _ok "role_model rejects an unknown role"
fi

finish
