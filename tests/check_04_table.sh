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

# --- timeout_minutes must be a positive number (Task 5 review finding #1):
# invoke_vendor builds "${timeout_minutes}m" for GNU `timeout` and compares it
# numerically against the headroom threshold via awk. A non-numeric cell
# (empty, "n/a", ...) would coerce to 0 in that awk comparison and silently
# skip the paid headroom probe -- exactly the "silently defaulting" policy_value's
# own doc comment forbids. This is the loud, extraction-time backstop.
bad_timeout="$(awk -F '\t' '
  NR==1 { for (i=1;i<=NF;i++) if ($i=="timeout_minutes") col=i; next }
  { if ($col !~ /^[0-9]+(\.[0-9]+)?$/ || $col+0 <= 0) print $1 ":" $col }
' "$BUILD/roles.tsv")"
assert_eq "" "$bad_timeout" "every role's timeout_minutes is a positive number"

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
assert_eq 26 "$(tail -n +2 "$BUILD/roles.tsv" | wc -l | tr -d ' ')" "26 registry rows including child-only impl-worker"
assert_eq 25 "$(awk -F '\t' 'NR>1 && $16 != "child" {n++} END {print n+0}' "$BUILD/roles.tsv")" "25 top-level dispatched roles"

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

assert_eq 26 "$rows" "role table covers all 26 registry rows"

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

# --- Task 13: implementer modes + child-worker spawn boundary --------------
assert_tsv_field "$BUILD/roles.tsv" implementer required_inputs \
  "feature_folder;plan_path;spec_path;implementation_base_sha;context7_policy;mode"
assert_eq yes "$(role_may_spawn_children implementer)" \
  "T13: the implementer's own contract says may_spawn_children=yes"
assert_eq no  "$(role_may_spawn_children impl-worker)" \
  "T13: impl-worker's own contract forbids spawning a grandchild"

# Code review fix (round 1, finding 11): the two checks above only look at
# TWO of the 26 registry rows -- prove the claim in their own messages ("only
# the implementer") against every OTHER role too, not just these two.
_t13_spawn_offenders="$(awk -F '\t' 'NR>1 && $1!="implementer" && $8=="yes" {print $1}' "$BUILD/roles.tsv")"
assert_eq "" "$_t13_spawn_offenders" \
  "T13: no role OTHER than implementer says may_spawn_children=yes anywhere in the registry"

# --- Task 14: phase renumbering -- documentation-writer stays phase 9,
# readiness-writer moves from 10 to 11. No new role is added for Phase 10
# (local git finalization): it is a direct orchestrator operation, never a
# dispatched role, so the registry never gains a phase-10 row (Task 5/P01's
# seam-verifier is a phase-7 row, not phase 10, and brings the registry to
# 26 rows / 25 top-level roles).
assert_tsv_field "$BUILD/roles.tsv" documentation-writer phases 9
assert_tsv_field "$BUILD/roles.tsv" readiness-writer phases 11
assert_eq 0 "$(awk -F '\t' 'NR>1 && $16=="10" {n++} END {print n+0}' "$BUILD/roles.tsv")" \
  "T14: no role in the registry claims phase 10 -- local git finalization dispatches no role"
assert_absent 'documentation-review' "$BUILD/roles.tsv" \
  "T14: no documentation-review role was added (spec: do not add a documentation-review model)"

# The invariant, not a hardcoded list: every DISTINCT phase token any role's
# `phases` cell actually uses must be legal per the real _legal_phase_token
# function -- this is what a stale token allowlist (e.g. one that stops at
# 10 while a role has moved to 11) fails, instead of a bare grep for "11".
_t14_distinct_tokens="$(tail -n +2 "$BUILD/roles.tsv" | cut -f16 | tr ';' '
' | sort -u)"
_t14_bad_tokens=""
while IFS= read -r _t14_tok; do
  [ -n "$_t14_tok" ] || continue
  _legal_phase_token "$_t14_tok" || _t14_bad_tokens="$_t14_bad_tokens $_t14_tok"
done <<<"$_t14_distinct_tokens"
assert_eq "" "$_t14_bad_tokens" \
  "T14: every distinct phases token in the registry is accepted by _legal_phase_token"

finish
