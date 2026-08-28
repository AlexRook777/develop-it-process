#!/usr/bin/env bash
# Check 4: the role contract registry is one complete, non-drifting source of
# truth -- one 16-column row per role, no duplicates, no empty required cells.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

EXPECTED_HEADER="role	vendor	model	effort	timeout_minutes	mutates	long_running	may_spawn_children	required_inputs	optional_inputs	status_template	outputs	verdicts	required_status_fields	checkpoint_kind	phases"

python3 lib/extract.py roles >/dev/null 2>&1 || { _fail "role table not parseable"; finish; }

header="$(head -n1 "$BUILD/roles.tsv")"
assert_eq "$EXPECTED_HEADER" "$header" "role table header is the complete 16-column contract"
[ "$_FAILURES" -eq 0 ] || finish

# --- reject duplicate roles ---
dupes="$(tail -n +2 "$BUILD/roles.tsv" | cut -f1 | sort | uniq -d)"
assert_eq "" "$dupes" "no duplicate role rows in the registry"

# --- reject empty required fields (every column except effort/optional_inputs) ---
empty_report="$(awk -F '\t' '
  NR==1 { for (i=1;i<=NF;i++) name[i]=$i; next }
  {
    for (i=1;i<=NF;i++) {
      if (name[i] == "effort" || name[i] == "optional_inputs") continue
      if ($i == "") print $1 "." name[i]
    }
  }
' "$BUILD/roles.tsv")"
assert_eq "" "$empty_report" "no empty required-field cells in the registry"

load_cookbook || finish

for fn in role_vendor role_model role_effort role_timeout role_mutates \
          role_may_spawn_children role_required_inputs role_optional_defaults \
          role_status_path role_outputs role_verdicts \
          role_required_status_fields role_checkpoint_kind role_phases; do
  if declare -F "$fn" >/dev/null; then _ok "$fn is defined"
  else _fail "$fn is not defined in the cookbook"; fi
done
[ "$_FAILURES" -eq 0 ] || finish

export ROLE_CONTRACTS_PATH="$BUILD/roles.tsv"

# --- explicit deltas and counts from the plan ---
assert_tsv_key "$BUILD/roles.tsv" role implementation-fixer
assert_tsv_key "$BUILD/roles.tsv" role documentation-writer
assert_tsv_missing_key "$BUILD/roles.tsv" role finishing-branch
assert_tsv_field "$BUILD/roles.tsv" impl-worker status_template none
assert_tsv_field "$BUILD/roles.tsv" impl-worker phases child
assert_eq 25 "$(tail -n +2 "$BUILD/roles.tsv" | wc -l | tr -d ' ')" "25 registry rows including child-only impl-worker"
assert_eq 24 "$(awk -F '\t' 'NR>1 && $16 != "child" {n++} END {print n+0}' "$BUILD/roles.tsv")" "24 top-level dispatched roles"

# --- role_* wrappers agree with the registry, for every row ---
rows=0
while IFS= read -r _row_line; do
  [ -n "$_row_line" ] || continue
  role="$(printf '%s' "$_row_line" | cut -f1)"
  model="$(printf '%s' "$_row_line" | cut -f3)"
  effort="$(printf '%s' "$_row_line" | cut -f4)"
  timeout="$(printf '%s' "$_row_line" | cut -f5)"
  rows=$((rows + 1))
  assert_eq "$model"   "$(role_model   "$role" 2>/dev/null)" "role_model $role"
  assert_eq "$effort"  "$(role_effort  "$role" 2>/dev/null)" "role_effort $role"
  assert_eq "$timeout" "$(role_timeout "$role" 2>/dev/null)" "role_timeout $role"
done < <(tail -n +2 "$BUILD/roles.tsv")

assert_eq 25 "$rows" "role table covers all 25 registry rows"

# No stale ids, and no model may be named only in the table.
for m in claude-haiku-4-5 claude-opus-5 claude-sonnet-5 gpt-5.6-luna gpt-5.6-sol; do
  "$GREP_BIN" -qF "$m" "$BUILD/roles.tsv" || _fail "table never assigns $m"
done

# An unknown role must be a loud error, not an empty string.
if role_model definitely-not-a-role >/dev/null 2>&1; then
  _fail "role_model accepts an unknown role"
else
  _ok "role_model rejects an unknown role"
fi

# no extracted contract may name the retired finishing-branch role
assert_absent 'finishing-branch' "$BUILD/roles.tsv" "no extracted contract contains finishing-branch"

finish
