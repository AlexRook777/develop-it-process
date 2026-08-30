#!/usr/bin/env bash
# Check 3: appendix marker integrity, and (Task 2) one complete appendix
# contract per executable role, with no retired role marker left behind.
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

# --- Task 2: one complete appendix contract per executable (non-child) role,
# and no retired role marker (e.g. `finishing-branch`) left behind. ---
python3 lib/extract.py roles >/dev/null 2>&1 || { _fail "role table not parseable"; finish; }

top_level_roles="$(awk -F '\t' 'NR>1 && $16 != "child" {print $1}' "$BUILD/roles.tsv" | sort)"

# No appendix exists for a role outside the registry's top-level set (catches
# a retired marker like `finishing-branch`, or any other orphan).
retired="$(comm -23 <(printf '%s\n' "$begins") <(printf '%s\n' "$top_level_roles"))"
assert_eq "" "$retired" "no appendix marker for a retired or unregistered role"

# Every top-level dispatched role has EXACTLY one appendix.
missing_appendix="$(comm -13 <(printf '%s\n' "$begins") <(printf '%s\n' "$top_level_roles"))"
assert_eq "" "$missing_appendix" "every top-level dispatched role has an appendix"

# Every appendix declares the full six-part contract: Inputs (required +
# optional), Outputs, Allowed verdicts, Required status fields, Checkpoint
# kind, Phases -- each with a value matching its registry row exactly. Driven
# through the shared `contract_drift` helper (tests/lib/assert.sh) so this is
# the SAME comparison tests/check_06_cookbook.sh's negative case 4 drives
# against a deliberately tampered appendix -- one detector, not two.
drift=""
while IFS= read -r role; do
  [ -n "$role" ] || continue
  for spec in "Required inputs:required_inputs:APPENDIX_CONTRACT_DRIFT" \
              "Optional inputs:optional_inputs:APPENDIX_CONTRACT_DRIFT" \
              "Outputs:outputs:APPENDIX_CONTRACT_DRIFT" \
              "Allowed verdicts:verdicts:VERDICT_SCHEMA_DRIFT" \
              "Required status fields:required_status_fields:APPENDIX_CONTRACT_DRIFT" \
              "Checkpoint kind:checkpoint_kind:APPENDIX_CONTRACT_DRIFT" \
              "Phases:phases:APPENDIX_CONTRACT_DRIFT"; do
    key="${spec%%:*}"; rest="${spec#*:}"; column="${rest%%:*}"; token="${rest#*:}"
    msg="$(contract_drift "$PROCESS_DOC" "$BUILD/roles.tsv" "$role" "$key" "$column" "$token")" \
      || drift="$drift
  $msg"
  done
done < <(printf '%s\n' "$top_level_roles")
assert_eq "" "$drift" "every appendix contract declaration matches its registry row"

# --- Task 13: impl-worker (child-only, phases=child) never gets a top-level
# appendix marker of its own -- it has no independent dispatch identity, so
# a `BEGIN: impl-worker` marker would be an orphan nothing ever renders.
assert_absent 'BEGIN: impl-worker' "$PROCESS_DOC" \
  "T13: impl-worker (child-only role) has no top-level appendix marker"

finish
