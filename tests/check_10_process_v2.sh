#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/assert.sh"

assert_contains '| process_schema_version | 2 |' "$PROCESS_DOC" "schema v2 policy"
assert_contains '| prelaunch_correction_cap | 1 |' "$PROCESS_DOC" "prelaunch cap"
assert_contains '| publication_retry_cap | 1 |' "$PROCESS_DOC" "publication cap"
assert_contains '| transient_retry_cap | 1 |' "$PROCESS_DOC" "transient cap"
assert_contains '| continuation_cap | 3 |' "$PROCESS_DOC" "continuation cap"
assert_contains '| review_iteration_cap | 10 |' "$PROCESS_DOC" "review cap"
assert_contains '| document_fixer_batch_size | 8 |' "$PROCESS_DOC" "batch cap"
assert_contains '| documentation_fix_cap | 2 |' "$PROCESS_DOC" "documentation cap"
assert_contains '| artifact_growth_warning_pct | 10 |' "$PROCESS_DOC" "growth threshold"
assert_contains '| divergent_round_cap | 2 |' "$PROCESS_DOC" "divergence cap"
assert_contains '| long_role_headroom_threshold_minutes | 60 |' "$PROCESS_DOC" "long-role threshold"

# extract.py writes $BUILD/policies.tsv itself; redirecting stdout onto the same
# path would splice two independent writes at offset 0.
python3 "$REPO_TOP/tests/lib/extract.py" policies > /dev/null
assert_line_count 12 "$BUILD/policies.tsv" "policy header plus 11 rows"

# shellcheck source=lib/v2_fixtures.sh
source "$REPO_TOP/tests/lib/v2_fixtures.sh"
load_cookbook || finish
init_v2_fixture

for p in "$ORCHESTRATION_DIR" "$RUNTIME_DIR" "$SDD_DIR" "$RUN_LOG" "$LEASE_FILE" "$TRANSCRIPTS_DIR"; do
  case "$p" in
    "$FEATURE_FOLDER"|"$FEATURE_FOLDER"/*) _ok "fixture path under \$FEATURE_FOLDER: $p" ;;
    *) _fail "fixture path escapes \$FEATURE_FOLDER: $p" ;;
  esac
done
case "$REPO_ROOT" in
  "$FEATURE_FOLDER"|"$FEATURE_FOLDER"/*) _fail "\$REPO_ROOT must not be under \$FEATURE_FOLDER: $REPO_ROOT" ;;
  *) _ok "\$REPO_ROOT stays outside \$FEATURE_FOLDER" ;;
esac

# policy_value reads the generated registry, not the Markdown table. Task 3's
# bootstrap_runtime materializes it for real; here we stage it by hand so the
# helper is covered by behaviour rather than by grep.
mkdir -p "$RUNTIME_DIR"
cp "$BUILD/policies.tsv" "$RUNTIME_DIR/policy.tsv"
assert_eq 10 "$(policy_value review_iteration_cap)" "policy_value prints only the value"

rc=0; out=$(policy_value no_such_policy 2>"$BUILD/policy.err") || rc=$?
assert_rc 1 "$rc" "unknown policy fails"
assert_eq "" "$out" "unknown policy prints nothing on stdout"
assert_contains 'POLICY_UNKNOWN:no_such_policy' "$BUILD/policy.err" "unknown policy names itself"

printf 'review_iteration_cap\t99\tdup\n' >> "$RUNTIME_DIR/policy.tsv"
rc=0; policy_value review_iteration_cap 2>"$BUILD/policy.err" >/dev/null || rc=$?
assert_rc 1 "$rc" "duplicate policy fails"
assert_contains 'POLICY_DUPLICATE:review_iteration_cap' "$BUILD/policy.err" "duplicate policy names itself"

rm -f "$RUNTIME_DIR/policy.tsv"
rc=0; policy_value review_iteration_cap 2>"$BUILD/policy.err" >/dev/null || rc=$?
assert_rc 1 "$rc" "missing registry fails without killing the shell"
assert_contains 'POLICY_REGISTRY_MISSING' "$BUILD/policy.err" "missing registry is typed"

# Spec 6.3: reconstruction must run at the start of EVERY phase shell. The
# helper being correct is worthless if the normative per-phase bootstrap never
# names it -- that regression already happened once.
assert_present '^init_orchestration_vars [0-9-]+ \|\| exit 1$' "$PROCESS_DOC" \
  "the per-phase bootstrap snippet calls init_orchestration_vars <phase>"
# assert_absent pipes into head; under `set -euo pipefail` a no-match grep would
# abort this script instead of passing. Count instead.
stale=$(grep -c '^CONTEXT7_POLICY=' "$PROCESS_DOC" || true)
assert_eq 0 "$stale" "no phase block reconstructs only the context7 policy"

finish
