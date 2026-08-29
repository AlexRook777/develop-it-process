#!/usr/bin/env bash
# Check 5: fake-CLI integration. Exercises dispatch machinery with no tokens.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

load_cookbook || finish
# shellcheck source=lib/v2_fixtures.sh
source "$REPO_TOP/tests/lib/v2_fixtures.sh"

WORK="$BUILD/fakecli"; rm -rf "$WORK"; mkdir -p "$WORK"
export PATH="$PWD/fakebin:$PATH"          # the stubs must be found by name
export FAKE_ARGV_LOG="$WORK/argv.log"     # the stubs read this themselves

# A throwaway target repo, distinct from the process repo.
#
# CRITICAL: every orchestration variable below is assigned WITHOUT `export`,
# because that is how the orchestrator sets them. render_prompt resolves
# substitutions through python3's os.environ, which never sees an unexported
# shell variable -- exporting any of them here would mask that whole defect
# class. Only FAKE_ARGV_LOG and PATH are exported, because the fake CLIs run
# as separate processes and can only see the environment, not our shell vars.
REPO_ROOT="$WORK/target"; mkdir -p "$REPO_ROOT"
git -C "$REPO_ROOT" init -q
( cd "$REPO_ROOT" && : > seed && git add seed \
  && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
# A tracked placeholder under docs/superpowers/specs/ so an otherwise fully
# untracked "docs/" subtree never collapses into one porcelain line above
# $FEATURE_FOLDER (see tests/lib/assert.sh's init_fixture_env for why this
# matters to inspect_mutation_state's dirty_tree_check-based comparison).
mkdir -p "$REPO_ROOT/docs/superpowers/specs"
( cd "$REPO_ROOT" && : > docs/superpowers/specs/.gitkeep \
  && git add docs/superpowers/specs/.gitkeep \
  && git -c user.email=t@t -c user.name=t commit -qm seed-docs ) >/dev/null
FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/x-artifacts"
mkdir -p "$FEATURE_FOLDER/transcripts"
PROCESS_PATH="$PROCESS_DOC"

init_orchestration_vars \
  || { _fail "init_orchestration_vars failed in the fake environment"; finish; }

# Every role_* lookup below (role_model, role_mutates, resolved_models_block, ...)
# resolves through the extracted role-contract registry, not a hand-maintained
# case statement -- point it at a freshly extracted copy.
python3 "$REPO_TOP/tests/lib/extract.py" roles > /dev/null
export ROLE_CONTRACTS_PATH="$BUILD/roles.tsv"

# invoke_vendor's long-role headroom probe resolves its threshold via
# policy_value, which reads $RUNTIME_DIR/policy.tsv -- give it a real,
# freshly extracted copy rather than hand-writing the threshold value here.
export ORCHESTRATION_DIR="$FEATURE_FOLDER/.orchestration"
export RUNTIME_DIR="$ORCHESTRATION_DIR/runtime"
mkdir -p "$RUNTIME_DIR" "$ORCHESTRATION_DIR/snapshots"
python3 "$REPO_TOP/tests/lib/extract.py" policies > "$RUNTIME_DIR/policy.tsv"

# --- Fixture values for every key render_keys() lists ------------------------
# dispatch_reviewers_parallel renders BOTH prompts in the parent before either
# child launches (Task 13), so every variable an appendix might reference must
# already be set here or render_prompt aborts before any stub is ever invoked.
# The list is taken verbatim from `render_keys` in the loaded cookbook, not
# retyped from memory.
ITERATION=1
SPEC_PATH="$FEATURE_FOLDER/spec.md"
PLAN_PATH="$FEATURE_FOLDER/plan.md"
FINDINGS_PATHS="$FEATURE_FOLDER/transcripts/findings-01.md"
IMPLEMENTATION_BASE_SHA="deadbeef"
IMPLEMENTATION_SUMMARY_PATH="$FEATURE_FOLDER/transcripts/impl-summary.md"
DEBUGGER_STATUS_PATH="$FEATURE_FOLDER/transcripts/debugger-STATUS.md"
ROUND=1
TEST_REPORT_PATH="$FEATURE_FOLDER/transcripts/test-report.md"
RESOLVED_MODELS="$(resolved_models_block)"
CONTEXT7_POLICY="disabled"
PHASE_DIR="$FEATURE_FOLDER/3-spec-review"
DISPATCH_ID="p03-i01-spec-reviewer-claude-a01"
LOGICAL_DISPATCH_ID="p03-i01-spec-reviewer-claude"
ATTEMPT=01
STATUS_PUBLISHER_PATH="$FEATURE_FOLDER/../.orchestration/runtime/publish-status"
CONTINUATION_PATH=""
DECLARED_FOREIGN_CHANGES=""
RUNTIME_DIR="$FEATURE_FOLDER/.orchestration/runtime"

# --- Sanity check: render_prompt must succeed with these fixture values -----
# If this fails, every assertion below fails for the wrong reason (an unset
# render_keys variable, not the behaviour under test).
sanity_prompt="$(render_prompt spec-reviewer-claude)"
assert_rc 0 $? "sanity: render_prompt spec-reviewer-claude succeeds with fixture vars"
if [ -n "$sanity_prompt" ]; then
  _ok "sanity: render_prompt spec-reviewer-claude produced non-empty output"
else
  _fail "sanity: render_prompt spec-reviewer-claude produced non-empty output"
fi

# --- helpers local to this file --------------------------------------------
# Extracts the ordered sequence of event tags in RUN_LOG.md that name a given
# dispatch_id in their very next `dispatch_id:` field -- used to assert the
# DISPATCH_STARTED -> DISPATCH_COMPLETED -> ATTEMPT_FAILED durable order for
# ONE dispatch id (Task 6 Step 1).
_events_for_dispatch_id() {
  local id="$1" log="$2" tag=""
  while IFS= read -r line; do
    case "$line" in
      "--- "*"  event=DISPATCH_STARTED"|"--- "*"  event=DISPATCH_COMPLETED"| \
      "--- "*"  event=DISPATCH_NOT_LAUNCHED"|"--- "*"  event=ATTEMPT_FAILED")
        tag="${line##*event=}" ;;
      "--- "*) tag="" ;;
      "dispatch_id:"*)
        [ -n "$tag" ] || continue
        case "$line" in *"$id") printf '%s\n' "$tag"; tag="" ;; esac ;;
    esac
  done < "$log"
}

# --- 0. role_mutates / appendix_exists still hold (unaffected by Task 6) ----
assert_eq yes "$(role_mutates implementer)"           "the implementer mutates"
assert_eq yes "$(role_mutates documentation-writer)"  "the documentation writer mutates"
assert_eq no  "$(role_mutates summarizer-spec)"       "summarizers are read-only"
assert_eq no  "$(role_mutates code-reviewer-claude)"  "reviewers are read-only"

appendix_exists implementer     && _ok "appendix_exists finds a real appendix" \
                                || _fail "appendix_exists missed a real appendix"
appendix_exists no-such-role    && _fail "appendix_exists accepted a missing appendix" \
                                || _ok "appendix_exists rejects a missing appendix"

# A mutated registry copy for every test below that needs the fakebin's
# generic FAKE_MODE=complete STATUS body (`verdict: DONE`, no extra fields) to
# validate cleanly: only a role whose legal verdicts include DONE and whose
# required_status_fields is exactly `common_v2` accepts it as-is. Among the
# real registry rows that satisfy both, `summarizer-spec` (read-only, phase 3)
# is the cheapest -- it needs only $FEATURE_FOLDER. `summarizer-plan` (also
# common_v2/DONE, but phase 5) is remapped onto phase 3 too, purely so two
# such roles can be dispatched together in the SAME dispatch_parallel call --
# a throwaway registry mutation, same pattern as roles-59.tsv/roles-badvendor.tsv
# above, never the real $BUILD/roles.tsv.
pcol="$(tsv_column "$BUILD/roles.tsv" phases)"
awk -F'\t' -v OFS='\t' -v col="$pcol" \
  'NR==1{print;next} { if ($1=="summarizer-plan") $col=3; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-clean-status.tsv"

# --- 1. dispatch_attempt end to end against a healthy stub -------------------
: > "$FEATURE_FOLDER/RUN_LOG.md"
: > "$FAKE_ARGV_LOG"
FAKE_MODE=complete dispatch_attempt 3 01 summarizer-spec
assert_rc 0 $? "dispatch_attempt returns 0 end to end with a healthy stub"
assert_eq COMPLETED "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "dispatch_attempt exports DISPATCH_RESULT_CLASSIFICATION=COMPLETED"
assert_present 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "RUN_LOG gained an event=DISPATCH_STARTED block"
assert_present 'event=DISPATCH_COMPLETED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "RUN_LOG gained an event=DISPATCH_COMPLETED block"

# Task 6 review fix #2: Step 3's mandated fields must actually be emitted --
# not just computed into result.kv and then silently dropped at ingest. And
# (follow-up review fix #2) not just PRESENT -- each carries the real value,
# never an empty one that a presence-only check would accept.
for _f in lease snapshot; do
  assert_present "^${_f}:" "$FEATURE_FOLDER/RUN_LOG.md" "DISPATCH_STARTED carries field: $_f"
done
for _f in exit_code start_ms end_ms stdout_path stderr_path mutation_state checkpoint_kind; do
  assert_present "^${_f}:" "$FEATURE_FOLDER/RUN_LOG.md" "DISPATCH_COMPLETED carries field: $_f"
done
assert_eq 0 "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" exit_code)" \
  "DISPATCH_COMPLETED's exit_code is the real vendor rc (0 for a healthy stub)"
assert_eq NO_SIDE_EFFECTS "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" mutation_state)" \
  "DISPATCH_COMPLETED's mutation_state reflects a non-mutating role"
assert_eq "none" "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" lease)" \
  "DISPATCH_STARTED's lease is 'none' for a non-mutating role"
assert_eq "none" "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" snapshot)" \
  "DISPATCH_STARTED's snapshot is 'none' for a non-mutating role (no lease, no manifest)"
assert_eq "$(role_checkpoint_kind summarizer-spec)" \
  "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" checkpoint_kind)" \
  "DISPATCH_COMPLETED's checkpoint_kind matches the registry lookup for this role"

id1_val="$("$GREP_BIN" -oE 'p03-i01-summarizer-spec-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
[ -n "$id1_val" ] || _fail "could not recover dispatch #1's own dispatch_id from RUN_LOG"
assert_eq "$FEATURE_FOLDER/transcripts/$id1_val.stdout" \
  "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" stdout_path)" \
  "DISPATCH_COMPLETED's stdout_path is the attempt's REAL transcript path"
assert_eq "$FEATURE_FOLDER/transcripts/$id1_val.stderr" \
  "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" stderr_path)" \
  "DISPATCH_COMPLETED's stderr_path is the attempt's REAL transcript path"

sm_val="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" start_ms)"
em_val="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" end_ms)"
case "$sm_val" in
  ''|*[!0-9]*) _fail "start_ms is not a positive integer: [$sm_val]" ;;
  *) [ "$sm_val" -gt 0 ] && _ok "start_ms is a positive integer" || _fail "start_ms is not > 0: [$sm_val]" ;;
esac
case "$em_val" in
  ''|*[!0-9]*) _fail "end_ms is not a positive integer: [$em_val]" ;;
  *) [ "$em_val" -gt 0 ] && _ok "end_ms is a positive integer" || _fail "end_ms is not > 0: [$em_val]" ;;
esac
if [ "$sm_val" -gt 0 ] 2>/dev/null && [ "$em_val" -gt 0 ] 2>/dev/null && [ "$em_val" -ge "$sm_val" ]; then
  _ok "end_ms >= start_ms"
else
  _fail "end_ms < start_ms (or non-numeric): start=$sm_val end=$em_val"
fi

# Regression for FIX 1 (Task 4): provenance fields must be REAL, not empty.
git_sha="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" develop_it_git_sha)"
file_sha256="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" develop_it_file_sha256)"
if [ -n "$git_sha" ] && [ "$git_sha" != non-git ]; then
  _ok "DISPATCH_COMPLETED's develop_it_git_sha is populated"
else
  _fail "DISPATCH_COMPLETED's develop_it_git_sha is empty or non-git: [$git_sha]"
fi
if [ -n "$file_sha256" ]; then
  _ok "DISPATCH_COMPLETED's develop_it_file_sha256 is populated"
else
  _fail "DISPATCH_COMPLETED's develop_it_file_sha256 is empty"
fi
assert_eq "spec-review" "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" phase_name)" \
  "DISPATCH_COMPLETED's phase_name is canonical, not 'unknown'"

# lease/snapshot carry real values (not "none") for a MUTATING role.
: > "$FEATURE_FOLDER/RUN_LOG.md"
rm -f "$ORCHESTRATION_DIR/write-lease.json"
FAKE_MODE=complete dispatch_attempt 6 19 debugger >/dev/null 2>&1
assert_eq "$ORCHESTRATION_DIR/write-lease.json" "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" lease)" \
  "DISPATCH_STARTED's lease names the real write-lease.json path for a mutating role"
debugger_id19="$("$GREP_BIN" -oE 'p06-i19-debugger-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
assert_eq "$ORCHESTRATION_DIR/snapshots/$debugger_id19/manifest.json" \
  "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" snapshot)" \
  "DISPATCH_STARTED's snapshot names the real manifest path for a mutating role"
assert_exists "$ORCHESTRATION_DIR/snapshots/$debugger_id19/manifest.json" \
  "the snapshot manifest was actually captured, not just named"
assert_present '"before":' "$ORCHESTRATION_DIR/snapshots/$debugger_id19/manifest.json" \
  "the manifest carries a before-mutation snapshot"
assert_present '"after":' "$ORCHESTRATION_DIR/snapshots/$debugger_id19/manifest.json" \
  "the manifest carries an after-mutation snapshot (release_write_lease captured it)"
assert_not_exists "$ORCHESTRATION_DIR/write-lease.json" \
  "the winner released the lease after finishing"

# --- 2. dispatch_parallel with codex_available=true --------------------------
: > "$FEATURE_FOLDER/RUN_LOG.md"
: > "$FAKE_ARGV_LOG"
declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
ROLE_CONTRACTS_PATH="$BUILD/roles-clean-status.tsv" \
  FAKE_MODE=complete dispatch_parallel 3 02 summarizer-spec summarizer-plan
assert_rc 0 $? "dispatch_parallel returns 0 when every role completes"
assert_eq COMPLETED "${DISPATCH_PARALLEL_CLASSIFICATION[summarizer-spec]:-}" \
  "dispatch_parallel records the first role's classification"
assert_eq COMPLETED "${DISPATCH_PARALLEL_CLASSIFICATION[summarizer-plan]:-}" \
  "dispatch_parallel records the second role's classification"
assert_eq 2 "$("$GREP_BIN" -c 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "both roles got a DISPATCH_STARTED record"
assert_present 'role:                     summarizer-spec' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the first role's DISPATCH_STARTED record is present"
assert_present 'role:                     summarizer-plan' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the second role's DISPATCH_STARTED record is present"

# --- 3. Lifecycle-order test (Task 6 Step 1) ---------------------------------
# 3a. A launched, SUCCESSFUL attempt: DISPATCH_STARTED then DISPATCH_COMPLETED,
#     no ATTEMPT_FAILED.
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete dispatch_attempt 3 03 summarizer-spec
did_ok="$DISPATCH_RESULT_STATUS_PATH"
id_ok="$("$GREP_BIN" -oE 'p03-i03-summarizer-spec-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
[ -n "$id_ok" ] || _fail "could not recover the successful attempt's dispatch_id from RUN_LOG"
seq_ok="$(_events_for_dispatch_id "$id_ok" "$FEATURE_FOLDER/RUN_LOG.md" | tr '\n' ' ')"
assert_eq "DISPATCH_STARTED DISPATCH_COMPLETED " "$seq_ok" \
  "a successful launched attempt records STARTED then COMPLETED, and nothing else"

# 3b. A launched, CLASSIFIED-FAILED attempt (permanent vendor error): STARTED,
#     COMPLETED, THEN exactly one ATTEMPT_FAILED referencing the same id.
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=permanent dispatch_attempt 3 04 summarizer-spec
id_fail="$("$GREP_BIN" -oE 'p03-i04-summarizer-spec-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
[ -n "$id_fail" ] || _fail "could not recover the failed attempt's dispatch_id from RUN_LOG"
seq_fail="$(_events_for_dispatch_id "$id_fail" "$FEATURE_FOLDER/RUN_LOG.md" | tr '\n' ' ')"
assert_eq "DISPATCH_STARTED DISPATCH_COMPLETED ATTEMPT_FAILED " "$seq_fail" \
  "a classified-failed launched attempt records STARTED, COMPLETED, then exactly one ATTEMPT_FAILED"

# 3c. A prelaunch failure: exactly one DISPATCH_NOT_LAUNCHED, no start/completion.
: > "$FEATURE_FOLDER/RUN_LOG.md"
_saved_context7="${CONTEXT7_POLICY:-}"
unset CONTEXT7_POLICY
dispatch_attempt 1 05 preflight-claude
prelaunch_rc=$?
CONTEXT7_POLICY="$_saved_context7"
assert_rc 1 "$prelaunch_rc" "a prelaunch-rejected attempt returns non-zero"
assert_eq PRELAUNCH_FAILED "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "a prelaunch-rejected attempt is classified PRELAUNCH_FAILED"
assert_eq 1 "$("$GREP_BIN" -c 'event=DISPATCH_NOT_LAUNCHED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "exactly one DISPATCH_NOT_LAUNCHED is recorded"
assert_eq 0 "$("$GREP_BIN" -c 'event=DISPATCH_STARTED\|event=DISPATCH_COMPLETED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "a prelaunch failure records no DISPATCH_STARTED and no DISPATCH_COMPLETED"

# --- 4. Two read-only roles dispatched concurrently: disjoint attempt dirs,
#        complete parent-ingested RUN_LOG records (Task 6 Step 1) ------------
: > "$FEATURE_FOLDER/RUN_LOG.md"
declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
# Both roles launch and their vendor call succeeds (rc=0) -- their eventual
# STATUS-shape classification is irrelevant to what THIS test checks (attempt
# isolation and RUN_LOG completeness), so no rc/classification is asserted
# here; sections 1-3 above already prove a fully COMPLETED lifecycle.
FAKE_MODE=complete dispatch_parallel 1 06 preflight-claude preflight-codex >/dev/null 2>&1
id_a="$("$GREP_BIN" -oE 'p01-i06-preflight-claude-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
id_b="$("$GREP_BIN" -oE 'p01-i06-preflight-codex-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
dir_a="$(role_attempt_dir preflight-claude "$id_a" 2>/dev/null)"
dir_b="$(role_attempt_dir preflight-codex "$id_b" 2>/dev/null)"
if [ -n "$dir_a" ] && [ -n "$dir_b" ] && [ "$dir_a" != "$dir_b" ] \
   && [ -d "$dir_a" ] && [ -d "$dir_b" ]; then
  _ok "the two concurrently-dispatched roles have disjoint, real attempt directories"
else
  _fail "attempt directories are not disjoint or do not exist: [$dir_a] vs [$dir_b]"
fi
# "Complete blocks" -- every DISPATCH_COMPLETED block in this RUN_LOG carries
# the full identity/telemetry field set, not a truncated fragment.
complete_blocks="$("$GREP_BIN" -c 'event=DISPATCH_COMPLETED' "$FEATURE_FOLDER/RUN_LOG.md" || true)"
usage_status_lines="$("$GREP_BIN" -c '^usage_status:' "$FEATURE_FOLDER/RUN_LOG.md" || true)"
assert_eq 2 "$complete_blocks" "two DISPATCH_COMPLETED blocks were ingested by the parent"
assert_eq "$complete_blocks" "$usage_status_lines" \
  "every DISPATCH_COMPLETED block reaches its final usage_status field (no truncated block)"

# --- 5. group_wall_ms is max(end)-min(start), never a sum (Task 6 Step 4) ---
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete FAKE_DELAY_SECONDS=1 dispatch_parallel 1 07 preflight-claude preflight-codex \
  >/dev/null 2>&1
gw="${DISPATCH_PARALLEL_GROUP_WALL_MS:-0}"
# Two ~1s children run concurrently: a correct max(end)-min(start) computation
# stays near 1000ms; a (buggy) sum would land near 2000ms. 1700ms is a
# generous mid-point that tolerates real scheduling jitter without accepting
# a sum.
if [ "$gw" -ge 700 ] && [ "$gw" -lt 1700 ]; then
  _ok "DISPATCH_PARALLEL_GROUP_WALL_MS ($gw ms) reflects concurrent execution, not a sum of two ~1s children"
else
  _fail "DISPATCH_PARALLEL_GROUP_WALL_MS is implausible for two concurrent ~1s children: $gw ms"
fi

# --- 6. Duplicate roles are rejected before anything is dispatched ----------
: > "$FEATURE_FOLDER/RUN_LOG.md"
dispatch_parallel 1 08 preflight-claude preflight-claude 2>"$WORK/dup.err"
assert_rc 1 $? "dispatch_parallel rejects a duplicate role"
assert_contains "DISPATCH_PARALLEL_DUPLICATE_ROLE" "$WORK/dup.err" "the rejection names itself"
assert_eq 0 "$(wc -l < "$FEATURE_FOLDER/RUN_LOG.md" | tr -d ' ')" \
  "a duplicate-role rejection writes nothing to RUN_LOG.md"

# --- 7. Partial fan-out failures (Task 6 Step 7) -----------------------------
# 7a. one completed child plus one timed-out child, dispatched together.
tcol="$(tsv_column "$BUILD/roles-clean-status.tsv" timeout_minutes)"
awk -F'\t' -v OFS='\t' -v col="$tcol" -v v=0.02 \
  'NR==1{print;next} { if ($1=="summarizer-spec") $col=v; print }' \
  "$BUILD/roles-clean-status.tsv" > "$BUILD/roles-fanout-timeout.tsv"
: > "$FEATURE_FOLDER/RUN_LOG.md"
declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
ROLE_CONTRACTS_PATH="$BUILD/roles-fanout-timeout.tsv" \
  FAKE_MODE=complete FAKE_DELAY_SECONDS=2 \
  dispatch_parallel 3 09 summarizer-spec summarizer-plan >/dev/null 2>&1
case "${DISPATCH_PARALLEL_CLASSIFICATION[summarizer-spec]:-}" in
  TIMED_OUT) _ok "7a: the short-timeout role is classified TIMED_OUT" ;;
  *) _fail "7a: expected TIMED_OUT, got [${DISPATCH_PARALLEL_CLASSIFICATION[summarizer-spec]:-}]" ;;
esac
assert_eq COMPLETED "${DISPATCH_PARALLEL_CLASSIFICATION[summarizer-plan]:-}" \
  "7a: its sibling still completes normally despite the other role timing out"
assert_eq 2 "$("$GREP_BIN" -cE 'event=(DISPATCH_STARTED|DISPATCH_NOT_LAUNCHED)' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7a: one result record per requested role (both PIDs were awaited and ingested)"

# 7b. one missing result file (child produced no attempt directory at all).
: > "$FEATURE_FOLDER/RUN_LOG.md"
_dispatch_ingest_child 1 10 preflight-claude ""
assert_rc 1 $? "7b: a missing result file ingests as a failure"
assert_eq PRELAUNCH_FAILED "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "7b: a missing result file is classified PRELAUNCH_FAILED"
assert_present 'event=DISPATCH_NOT_LAUNCHED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7b: exactly one synthesized DISPATCH_NOT_LAUNCHED is still recorded"
assert_present 'DISPATCH_PARALLEL_MISSING_RESULT' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7b: the synthesized record names the missing-result reason"

# 7c. one malformed result file (unrecognized classification value).
: > "$FEATURE_FOLDER/RUN_LOG.md"
malformed_dir="$(mktemp -d)"
_dispatch_write_result "$malformed_dir" launched=yes phase=1 phase_name=preflight \
  iteration=11 role=preflight-claude vendor=claude dispatch_id=p01-i11-preflight-claude-a01 \
  logical_dispatch_id=p01-i11-preflight-claude attempt=01 status_path=/dev/null \
  classification=NOT_A_REAL_CLASSIFICATION reason="" verdict="" usage_line="" \
  start_ms=1 end_ms=2 wall_ms=1 mutates=no
_dispatch_ingest_result "$malformed_dir/result.kv"
assert_rc 1 $? "7c: a malformed result record ingests as a failure, never a crash"
assert_present 'event=ATTEMPT_FAILED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7c: a malformed classification still yields exactly one ingested failure record"
assert_present 'DISPATCH_RESULT_MALFORMED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7c: the malformed-record reason names itself"
# One ingest call must yield exactly one of EACH block _dispatch_ingest_result
# itself owns (DISPATCH_COMPLETED, ATTEMPT_FAILED) -- never duplicated by a
# second call. DISPATCH_STARTED is NOT one of them any more (the review fix):
# it is written earlier, by _dispatch_write_started inside
# _dispatch_launch_attempt, immediately before the vendor launches -- calling
# _dispatch_ingest_result directly, as this test does, must never manufacture
# one out of thin air.
assert_eq 0 "$("$GREP_BIN" -c 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7c: _dispatch_ingest_result never writes DISPATCH_STARTED itself"
assert_eq 1 "$("$GREP_BIN" -c 'event=DISPATCH_COMPLETED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7c: exactly one DISPATCH_COMPLETED for the malformed record"
assert_eq 1 "$("$GREP_BIN" -c 'event=ATTEMPT_FAILED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7c: exactly one ATTEMPT_FAILED for the malformed record -- not silently dropped or duplicated"

# 7d. two mutating attempts competing for the (Task 6 seam) write lease.
# Whether the winner's OWN STATUS shape then classifies as COMPLETED or
# MALFORMED_STATUS is irrelevant here (implementer additionally requires a
# `verification:` STATUS field the generic fake envelope omits) -- what this
# case proves is the LEASE property: exactly one of the two ever reaches
# DISPATCH_STARTED (it was actually launched); the other is rejected before
# launch (DISPATCH_NOT_LAUNCHED), never left to overlap in mutation.
: > "$FEATURE_FOLDER/RUN_LOG.md"
rm -f "$ORCHESTRATION_DIR/write-lease.json"
declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
FAKE_MODE=complete dispatch_parallel 6 12 implementer debugger >/dev/null 2>&1
assert_eq 1 "$("$GREP_BIN" -c 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7d: exactly one of the two mutating roles was actually launched"
assert_eq 1 "$("$GREP_BIN" -c 'event=DISPATCH_NOT_LAUNCHED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7d: the other is rejected as a typed prelaunch failure, never left to overlap"
assert_present 'DISPATCH_WRITE_LEASE_UNAVAILABLE:ACTIVE_LEASE_OWNER' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7d: the loser's rejection names ACTIVE_LEASE_OWNER -- ordinary same-batch contention (RM02 wait), never RM03's ambiguous/stale alarm (code review fix #1)"
assert_eq 0 "$("$GREP_BIN" -c 'event=ARTIFACT_INTEGRITY_BLOCKED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "7d: ordinary same-batch lease contention never emits an integrity alarm"
assert_not_exists "$ORCHESTRATION_DIR/write-lease.json" \
  "7d: the winner released the lease after finishing (nothing left held)"

# 7e. render failure in one role yields ZERO invocations for its peer (Task 6
# review fix #4 -- restores v1 dispatch_reviewers_parallel's invariant:
# "rendering up front means a codex render failure cannot leave a claude
# child already spending", generalized to the whole batch).
: > "$FEATURE_FOLDER/RUN_LOG.md"
: > "$FAKE_ARGV_LOG"
declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
_saved_spec_path="$SPEC_PATH"
unset SPEC_PATH
dispatch_parallel 3 15 spec-reviewer-claude summarizer-spec >/dev/null 2>&1
rc_batch=$?
SPEC_PATH="$_saved_spec_path"
assert_rc 1 "$rc_batch" "7e: dispatch_parallel fails when one role's render fails"
assert_eq 0 "$("$GREP_BIN" -c '^claude \|^codex ' "$FAKE_ARGV_LOG" || true)" \
  "7e: the peer role (summarizer-spec, whose own render would have succeeded) got ZERO invocations"
assert_eq PRELAUNCH_FAILED "${DISPATCH_PARALLEL_CLASSIFICATION[spec-reviewer-claude]:-}" \
  "7e: the role that actually failed render is PRELAUNCH_FAILED"
assert_eq PRELAUNCH_FAILED "${DISPATCH_PARALLEL_CLASSIFICATION[summarizer-spec]:-}" \
  "7e: its peer is ALSO PRELAUNCH_FAILED -- never silently launched anyway"
assert_present 'DISPATCH_PARALLEL_PEER_REJECTED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7e: the peer's rejection names the batch-abort reason, distinct from its own (nonexistent) render failure"

# 7f. orphan-process check for dispatch_parallel's fan-out (Task 6 review fix
# #10): mutating the wait loop to "wait \${pids[0]}" only must be caught by
# observing a REAL leftover process, the same discipline section 9.10 already
# applies to invoke_vendor -- not just by a RUN_LOG-shaped assertion.
orphan_marker="2.$$"
: > "$FEATURE_FOLDER/RUN_LOG.md"
declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
ROLE_CONTRACTS_PATH="$BUILD/roles-fanout-timeout.tsv" \
  FAKE_MODE=timeout FAKE_DELAY_SECONDS="$orphan_marker" \
  dispatch_parallel 3 16 summarizer-spec summarizer-plan >/dev/null 2>&1 &
orphan_pid=$!
seen_orphan=0
for _ in $(seq 1 50); do
  pgrep -f "sleep $orphan_marker" >/dev/null 2>&1 && { seen_orphan=1; break; }
  sleep 0.1
done
[ "$seen_orphan" -eq 1 ] \
  && _ok "7f: the fan-out's slower child was actually observed running before dispatch_parallel returned" \
  || _fail "7f: never observed the slower child running (test would not be meaningful)"
wait "$orphan_pid"
if pgrep -f "sleep $orphan_marker" >/dev/null 2>&1; then
  _fail "7f: dispatch_parallel returned while a forked child's process was still running (an unawaited PID)"
  pkill -9 -f "sleep $orphan_marker" 2>/dev/null
else
  _ok "7f: no forked child's process remains after dispatch_parallel returns (every PID was truly awaited)"
fi

# 7g. a corrupt/empty `mutates` registry cell fails CLOSED (Task 6 review fix
# #7): never silently coerced to "no", which would skip the write lease for a
# role that actually mutates.
mcol_mut="$(tsv_column "$BUILD/roles.tsv" mutates)"
awk -F'\t' -v OFS='\t' -v col="$mcol_mut" -v v="maybe" \
  'NR==1{print;next} { if ($1=="implementer") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-corrupt-mutates.tsv"
: > "$FEATURE_FOLDER/RUN_LOG.md"
ROLE_CONTRACTS_PATH="$BUILD/roles-corrupt-mutates.tsv" \
  FAKE_MODE=complete dispatch_attempt 6 17 implementer >/dev/null 2>&1
rc_corrupt=$?
assert_rc 1 "$rc_corrupt" "7g: a corrupt mutates cell fails the dispatch, not a silent 'no' guess"
assert_eq PRELAUNCH_FAILED "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "7g: a corrupt mutates cell is a typed PRELAUNCH_FAILED"
assert_present 'DISPATCH_MUTATES_LOOKUP_FAILED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "7g: the rejection names the mutates-lookup failure specifically"

# 7h. orphan branch (Task 6 review fix #1 follow-up): a child that already
# wrote a durable DISPATCH_STARTED, then died before writing its result, must
# be recorded as an orphan by the parent's ingestion -- NEVER overwritten
# with a contradictory DISPATCH_NOT_LAUNCHED. That contradiction is the exact
# log corruption blocker-1's fix exists to prevent, and _dispatch_ingest_child
# is the ONLY code standing between a real crash and that corruption, so it
# is driven here with a REAL killed process, not a hand-injected RUN_LOG line.
#
# _dispatch_launch_attempt is called directly (bypassing dispatch_parallel's
# own forking loop) so the test can grab its PID and kill it mid-flight; it
# reads the roles/dp_*/phase/iteration/phase_name arrays via bash's dynamic
# scoping for `local`, which works identically for plain globals -- this
# script runs at top level, so every array/scalar set below IS a global.
orphan_kill_marker="9.$$"
: > "$FEATURE_FOLDER/RUN_LOG.md"
_dispatch_prelaunch 3 18 summarizer-spec   || _fail "7h: prelaunch for the orphan-branch fixture failed (test setup broken)"
phase=3; iteration=18; phase_name=spec-review
roles=(summarizer-spec)
dp_attempt_dir=("$PREP_ATTEMPT_DIR"); dp_dispatch_id=("$PREP_DISPATCH_ID")
dp_logical=("$PREP_LOGICAL"); dp_attempt=("$PREP_ATTEMPT")
dp_status_path=("$PREP_STATUS_PATH"); dp_stdout_path=("$PREP_STDOUT_PATH")
dp_stderr_path=("$PREP_STDERR_PATH"); dp_vendor=("$PREP_VENDOR")
dp_mutates=("$PREP_MUTATES"); dp_prompt_file=("$PREP_PROMPT_FILE")

FAKE_MODE=timeout FAKE_DELAY_SECONDS="$orphan_kill_marker" _dispatch_launch_attempt 0 &
orphan_child_pid=$!
orphan_seen=0
for _ in $(seq 1 50); do
  dispatch_is_running "${dp_dispatch_id[0]}" && { orphan_seen=1; break; }
  sleep 0.1
done
[ "$orphan_seen" -eq 1 ]   && _ok "7h: the child's own DISPATCH_STARTED became durable before it was killed"   || _fail "7h: never observed a durable DISPATCH_STARTED (test would not be meaningful)"

kill -9 "$orphan_child_pid" 2>/dev/null
wait "$orphan_child_pid" 2>/dev/null
pkill -9 -f "sleep $orphan_kill_marker" 2>/dev/null   # reap the orphaned vendor stub too

assert_not_exists "${dp_attempt_dir[0]}/result.kv"   "7h: the killed child really did die before writing its result (the crash landed where intended)"

_dispatch_ingest_child 3 18 summarizer-spec "${dp_attempt_dir[0]}"
assert_rc 1 $? "7h: an orphaned attempt ingests as a failure"
assert_eq ORPHANED_NO_RESULT "${DISPATCH_RESULT_CLASSIFICATION:-}"   "7h: it is classified ORPHANED_NO_RESULT, not PRELAUNCH_FAILED"
assert_eq INTEGRITY_UNKNOWN "${DISPATCH_RESULT_MUTATION_STATE:-}" \
  "7h: its mutation_state is INTEGRITY_UNKNOWN (a real spec S14.2 state), never the bare word UNKNOWN"
assert_eq DISPATCH_PARALLEL_CHILD_DIED_AFTER_START "${DISPATCH_RESULT_REASON:-}"   "7h: the reason names itself"
assert_eq 0 "$("$GREP_BIN" -c 'event=DISPATCH_NOT_LAUNCHED' "$FEATURE_FOLDER/RUN_LOG.md" || true)"   "7h: the parent never overwrites the durable DISPATCH_STARTED with a contradictory DISPATCH_NOT_LAUNCHED"
assert_present 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md"   "7h: the original DISPATCH_STARTED record is still intact"

# --- 8. Turn-start reconciliation: dispatch_is_running (spec S13.3) ---------
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete dispatch_attempt 1 13 preflight-claude >/dev/null 2>&1
completed_id="$("$GREP_BIN" -oE 'p01-i13-preflight-claude-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" | head -1)"
dispatch_is_running "$completed_id"
assert_rc 1 $? "a completed dispatch id is no longer 'running'"

# A REAL backgrounded dispatch, not a hand-injected RUN_LOG block: proves the
# ENGINE itself (not just dispatch_is_running's own parser) makes
# DISPATCH_STARTED durable before the vendor launches (Task 6 review fix #1 --
# a state the pre-fix engine could never produce, since it wrote
# DISPATCH_STARTED only after the child had already finished).
real_live_marker="3.$$"
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete FAKE_DELAY_SECONDS="$real_live_marker"   dispatch_attempt 1 14 preflight-claude >/dev/null 2>&1 &
real_live_pid=$!
seen_real_live=0
real_live_id=""
for _ in $(seq 1 50); do
  pgrep -f "sleep $real_live_marker" >/dev/null 2>&1 && seen_real_live=1
  real_live_id="$("$GREP_BIN" -oE 'p01-i14-preflight-claude-a[0-9]{2}' "$FEATURE_FOLDER/RUN_LOG.md" 2>/dev/null | head -1)"
  [ "$seen_real_live" -eq 1 ] && [ -n "$real_live_id" ] && break
  sleep 0.1
done
[ "$seen_real_live" -eq 1 ]   && _ok "the real dispatch's own vendor process was actually observed running"   || _fail "never observed the real dispatch's vendor process running (test would not be meaningful)"
if [ -n "$real_live_id" ]; then
  dispatch_is_running "$real_live_id"
  assert_rc 0 $? "dispatch_is_running is TRUE for a real attempt while its vendor process is genuinely still running"
else
  _fail "never recovered the real attempt's dispatch_id from RUN_LOG while it was running"
fi
wait "$real_live_pid"
[ -n "$real_live_id" ] && { dispatch_is_running "$real_live_id"; assert_rc 1 $? "and FALSE again once that same attempt has completed"; }

live_id="p09-i99-liveness-probe-a01"
{
  printf -- '--- %s  event=DISPATCH_STARTED\n' "$(iso_now)"
  printf 'phase:                    9\n'
  printf 'phase_name:               git-finalization\n'
  printf 'iteration:                99\n'
  printf 'role:                     liveness-probe\n'
  printf 'dispatch_id:              %s\n' "$live_id"
  printf '\n'
} >> "$FEATURE_FOLDER/RUN_LOG.md"
dispatch_is_running "$live_id"
assert_rc 0 $? "a DISPATCH_STARTED with no matching completion IS 'running'"

# A narration matching durable evidence: no correction needed.
pre_count="$("$GREP_BIN" -c 'event=PROCESS_DEVIATION' "$FEATURE_FOLDER/RUN_LOG.md" || true)"
assert_dispatch_running_claim "$live_id" "liveness-probe is running"
assert_rc 0 $? "a narration backed by DISPATCH_STARTED needs no correction"
post_count="$("$GREP_BIN" -c 'event=PROCESS_DEVIATION' "$FEATURE_FOLDER/RUN_LOG.md" || true)"
assert_eq "$pre_count" "$post_count" "no PROCESS_DEVIATION is appended for a truthful claim"

# A narration NOT backed by durable evidence: corrected.
assert_dispatch_running_claim "p09-i99-nonexistent-a01" "a role that was never dispatched is running"
assert_rc 1 $? "a false 'is running' narration is rejected"
assert_present 'event=PROCESS_DEVIATION' "$FEATURE_FOLDER/RUN_LOG.md" \
  "a false narration is recorded as a durable process deviation"

# --- 9. A render failure must produce ZERO CLI invocations ------------------
: > "$FEATURE_FOLDER/RUN_LOG.md"
: > "$FAKE_ARGV_LOG"
unset SPEC_PATH
dispatch_attempt 7 01 code-reviewer-claude \
  && _fail "dispatch must fail when a render key is unset" \
  || _ok "dispatch fails when a render key is unset"
assert_eq 0 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "a render failure invokes the CLI zero times"
SPEC_PATH="$WORK/spec.md"

# --- 10. the fake CLI's own argument-order guard (unrelated to dispatch,
#     regression coverage for the stub itself) -------------------------------
codex exec -a never -m gpt-5.6-sol - < /dev/null \
  > "$WORK/codex_bad_order.out" 2> "$WORK/codex_bad_order.err"
assert_rc 2 $? "codex stub rejects a global option placed after exec"
assert_present "unexpected argument" "$WORK/codex_bad_order.err" \
  "codex stub's rejection message names the offending argument"

# --- 11. timeout escalates to --kill-after for a stub that ignores SIGTERM --
FAKE_IGNORE_TERM=1 FAKE_DELAY=30 \
  timeout --kill-after=1s 1s claude --model x -p - </dev/null >/dev/null 2>&1
rc=$?
case "$rc" in
  124|137) _ok "timeout kills a SIGTERM-ignoring process (rc=$rc)" ;;
  *) _fail "expected 124 or 137 from timeout escalation, got $rc" ;;
esac

# --- 12. post_dispatch must treat an empty rc, a non-numeric rc, and rc=124
# (timeout's own exit code) as failure -- not a syntax error, not success.
: > "$WORK/pd-status.md"; : > "$WORK/pd.err"
post_dispatch "" "$WORK/pd-status.md" "$WORK/pd.err" >/dev/null 2>&1
assert_rc 1 $? "post_dispatch treats an empty rc as failure"
post_dispatch "abc" "$WORK/pd-status.md" "$WORK/pd.err" >/dev/null 2>&1
assert_rc 1 $? "post_dispatch treats a non-numeric rc as failure"
post_dispatch 124 "$WORK/pd-status.md" "$WORK/pd.err" >/dev/null 2>&1
assert_rc 1 $? "post_dispatch treats rc=124 (timeout) as failure"

# =============================================================================
# 9. invoke_vendor (Task 5) -- normalized registry-driven vendor invocation.
# =============================================================================
iv_prompt="$WORK/iv-prompt.txt"; printf 'hello prompt\n' > "$iv_prompt"

# --- 9.1 cwd, environment, argv, print/foreground semantics (claude) --------
: > "$FAKE_ARGV_LOG"
iv_claude_log="$WORK/iv-claude.fake.tsv"; : > "$iv_claude_log"
FAKE_ENV_LOG="$WORK/iv-claude.env" FAKE_LOG="$iv_claude_log" \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/iv-claude.out" "$WORK/iv-claude.err"
assert_rc 0 $? "invoke_vendor succeeds end to end for a claude role"

assert_eq "$REPO_ROOT" "$(cut -f3 "$iv_claude_log")" \
  "invoke_vendor launches Claude with cwd == \$REPO_ROOT"
assert_present '^CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0$' "$WORK/iv-claude.env" \
  "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 reaches the Claude subprocess environment"
assert_contains '-p ' "$FAKE_ARGV_LOG" "claude runs in print mode (-p, foreground)"
assert_contains '--output-format=json' "$FAKE_ARGV_LOG" "claude uses foreground JSON output"
assert_contains '--model claude-sonnet-5' "$FAKE_ARGV_LOG" \
  "invoke_vendor passes the role's resolved model (context-discovery)"
assert_present 'prompt_received' "$WORK/iv-claude.out" "stdout carries the vendor envelope"
if [ -s "$WORK/iv-claude.err" ]; then
  _fail "stderr should be empty for a clean claude run (stdout/stderr must stay separate streams)"
else
  _ok "stdout and stderr are separate, independently-checkable attempt files"
fi

# --- 9.2 argv and -C \$REPO_ROOT (codex) -------------------------------------
: > "$FAKE_ARGV_LOG"
invoke_vendor preflight-codex "$iv_prompt" "$WORK/iv-codex.out" "$WORK/iv-codex.err"
assert_rc 0 $? "invoke_vendor succeeds end to end for a codex role"
assert_contains "-C $REPO_ROOT" "$FAKE_ARGV_LOG" "invoke_vendor preserves codex -C \$REPO_ROOT"
assert_contains '-m gpt-5.6-luna' "$FAKE_ARGV_LOG" "invoke_vendor passes the role's resolved model (preflight-codex)"
assert_contains 'model_reasoning_effort=medium' "$FAKE_ARGV_LOG" "invoke_vendor passes the role's resolved effort"

# --- 9.3 boundary: only timeout_minutes >= threshold gets the headroom probe -
tcol="$(tsv_column "$BUILD/roles.tsv" timeout_minutes)"
awk -F'\t' -v OFS='\t' -v col="$tcol" -v v=59 \
  'NR==1{print;next} { if ($1=="context-discovery") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-59.tsv"
awk -F'\t' -v OFS='\t' -v col="$tcol" -v v=60 \
  'NR==1{print;next} { if ($1=="context-discovery") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-60.tsv"

: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-59.tsv" \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/b59.out" "$WORK/b59.err"
assert_eq 1 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "a 59-minute role gets exactly one claude invocation (no headroom probe)"

: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-60.tsv" \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/b60.out" "$WORK/b60.err"
assert_eq 2 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "a 60-minute role gets TWO claude invocations (headroom probe, then substantive launch)"

# --- 9.4 negative: unknown vendor is rejected before any CLI launch ----------
# (registry-logic coverage lives in check_06_cookbook.sh; this proves it holds
# with a real PATH pointing at the fakebin stubs too -- no invocation at all.)
mcol_v="$(tsv_column "$BUILD/roles.tsv" vendor)"
awk -F'\t' -v OFS='\t' -v col="$mcol_v" -v v="carrier-pigeon" \
  'NR==1{print;next} { if ($1=="context-discovery") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-badvendor.tsv"
: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-badvendor.tsv" \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/badvendor.out" "$WORK/badvendor.err" \
  2>"$WORK/badvendor.stderr"
assert_rc 95 $? "invoke_vendor rejects an unknown vendor"
assert_contains "INVOKE_VENDOR_UNKNOWN_VENDOR" "$WORK/badvendor.stderr" "unknown-vendor rejection names itself"
assert_eq 0 "$("$GREP_BIN" -c '^claude \|^codex ' "$FAKE_ARGV_LOG" || true)" \
  "an unknown vendor never reaches a CLI invocation"

# --- 9.5 negative: missing CLI binary returns the raw rc, unclassified -------
: > "$FAKE_ARGV_LOG"
PATH="/usr/bin:/bin" invoke_vendor context-discovery "$iv_prompt" "$WORK/nobin.out" "$WORK/nobin.err" \
  2>"$WORK/nobin.stderr"
assert_rc 127 $? "invoke_vendor returns the raw exit code when the CLI binary is missing"
assert_eq "" "$(cat "$WORK/nobin.stderr")" \
  "a missing binary is never reclassified into an INVOKE_VENDOR_* token -- it is passed through verbatim"

# --- 9.6 negative: model mismatch -- argv must reflect a MUTATED registry ----
# (not a hardcoded literal the implementation could get away with)
mcol_m="$(tsv_column "$BUILD/roles.tsv" model)"
awk -F'\t' -v OFS='\t' -v col="$mcol_m" -v v="carrier-pigeon-model" \
  'NR==1{print;next} { if ($1=="context-discovery") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-mm-claude.tsv"
: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-mm-claude.tsv" \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/mm.out" "$WORK/mm.err"
assert_contains "carrier-pigeon-model" "$FAKE_ARGV_LOG" \
  "claude: invoke_vendor launches with the REGISTRY's model, proven via a mutated copy"

awk -F'\t' -v OFS='\t' -v col="$mcol_m" -v v="carrier-pigeon-model-x" \
  'NR==1{print;next} { if ($1=="preflight-codex") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-mm-codex.tsv"
: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-mm-codex.tsv" \
  invoke_vendor preflight-codex "$iv_prompt" "$WORK/mmx.out" "$WORK/mmx.err"
assert_contains "carrier-pigeon-model-x" "$FAKE_ARGV_LOG" \
  "codex: invoke_vendor launches with the REGISTRY's model, proven via a mutated copy"

# --- 9.7 negative: a spend-ceiling headroom probe suppresses the launch -----
: > "$FAKE_ARGV_LOG"
FAKE_MODE=spend-ceiling invoke_vendor spec-reviewer-claude "$iv_prompt" "$WORK/sc.out" "$WORK/sc.err" \
  2>"$WORK/sc.stderr"
assert_rc 97 $? "a spend-ceiling headroom probe suppresses the substantive launch"
assert_contains "VENDOR_HEADROOM_REFUSED" "$WORK/sc.stderr" "the refusal names itself"
assert_eq 1 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "only the probe ran -- the substantive launch never happened"
# The probe's OWN transcript is preserved (never rm -f'd) as the evidence a
# future run-scoped VENDOR_UNAVAILABLE event (Task 6/8) will need to carry.
assert_exists "$WORK/sc.err.headroom-probe" \
  "the headroom probe's stderr transcript is preserved as evidence, not deleted"
assert_contains "usage limit reached" "$WORK/sc.err.headroom-probe" \
  "the preserved probe transcript carries the actual refusal signature"

# --- 9.7b negative: a probe that cannot even prove liveness is refused too --
# (review finding #9: a missing binary, a probe timeout, or a 5xx must NOT be
# read as "no refusal signature found, so it's fine" -- only rc=0 AND no
# signature proves liveness.)
: > "$FAKE_ARGV_LOG"
PATH="/usr/bin:/bin" FAKE_MODE=complete \
  invoke_vendor spec-reviewer-claude "$iv_prompt" "$WORK/probe-nolive.out" "$WORK/probe-nolive.err" \
  2>"$WORK/probe-nolive.stderr"
assert_rc 97 $? "a probe that can't even find the vendor binary is refused, not silently treated as live"
assert_contains "VENDOR_HEADROOM_REFUSED" "$WORK/probe-nolive.stderr" "the refusal names itself"

# --- 9.8 positive: a successful probe still lets the launch happen ----------
: > "$FAKE_ARGV_LOG"
FAKE_MODE=complete invoke_vendor spec-reviewer-claude "$iv_prompt" "$WORK/ok.out" "$WORK/ok.err"
assert_rc 0 $? "a successful headroom probe lets the substantive launch happen"
assert_eq 2 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "both the probe and the substantive launch ran"

# --- 9.8b codex headroom-probe coverage (review finding #10: zero coverage) -
: > "$FAKE_ARGV_LOG"
FAKE_MODE=complete invoke_vendor spec-reviewer-codex "$iv_prompt" "$WORK/codex-ok.out" "$WORK/codex-ok.err"
assert_rc 0 $? "codex: a successful headroom probe lets the substantive launch happen"
assert_eq 2 "$("$GREP_BIN" -c '^codex ' "$FAKE_ARGV_LOG" || true)" \
  "codex: both the probe and the substantive launch ran"

: > "$FAKE_ARGV_LOG"
FAKE_MODE=spend-ceiling invoke_vendor spec-reviewer-codex "$iv_prompt" "$WORK/codex-sc.out" "$WORK/codex-sc.err" \
  2>"$WORK/codex-sc.stderr"
assert_rc 97 $? "codex: a spend-ceiling headroom probe suppresses the substantive launch"
assert_contains "VENDOR_HEADROOM_REFUSED" "$WORK/codex-sc.stderr" "codex: the refusal names itself"
assert_eq 1 "$("$GREP_BIN" -c '^codex ' "$FAKE_ARGV_LOG" || true)" \
  "codex: only the probe ran -- the substantive launch never happened"

# --- 9.8c long_running=yes forces the probe even below the timeout threshold
# (review finding #10: Step 4 names long_running as a field invoke_vendor
# reads; it must actually gate on it, not just fetch and discard it -- this
# is the phases=child / may_spawn_children=yes disjunct a bare
# timeout>=threshold compare can never see.)
lrcol="$(tsv_column "$BUILD/roles.tsv" long_running)"
tcol4="$(tsv_column "$BUILD/roles.tsv" timeout_minutes)"
awk -F'\t' -v OFS='\t' -v lc="$lrcol" -v tc="$tcol4" \
  'NR==1{print;next} { if ($1=="context-discovery") { $lc="yes"; $tc=10 }; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-longrunning-override.tsv"
: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-longrunning-override.tsv" \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/lr.out" "$WORK/lr.err"
assert_eq 2 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "long_running=yes forces the headroom probe even when timeout_minutes (10) is below the threshold (60)"

# --- 9.9 negative: stdout containing status-like text is never a STATUS file
# Uses a REAL attempt identity from allocate_attempt (not an untouchable dummy
# path invoke_vendor never receives) -- $STATUS_PATH is a path the fake CLI
# genuinely CAN write to (see 9.11's complete/malformed-status/publication-lost
# cases, which do write it), so its absence here is a meaningful assertion:
# mode=exit-no-status is what keeps it absent, not an inherent inability to
# create it.
: > "$FEATURE_FOLDER/RUN_LOG.md"
allocate_attempt 2 00 context-discovery \
  || { _fail "allocate_attempt failed while setting up the STATUS negative test"; finish; }
neg_status="$STATUS_PATH"
[ -n "$neg_status" ] || _fail "allocate_attempt did not set \$STATUS_PATH"
rm -f "$neg_status" "$neg_status".tmp.*
FAKE_MODE=exit-no-status FAKE_STDOUT=$'verdict: DONE\nverification: PASS' \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/status-like.out" "$WORK/status-like.err"
assert_rc 0 $? "a status-shaped stdout body does not itself fail the launch"
assert_present 'verdict: DONE' "$WORK/status-like.out" \
  "the status-like text really did reach stdout (the check below is not vacuous)"
assert_not_exists "$neg_status" \
  "invoke_vendor (mode=exit-no-status) never materializes the attempt's REAL \$STATUS_PATH from stdout content -- only a real STATUS file, validated by classify_attempt (a later task), can establish completion"
unset STATUS_PATH  # do not leak into the launches that follow

# --- 9.9b EXTRA_VENDOR_ARGS (Phase 6 --agents sub-subagent model pin) reaches
# the real argv, with the model GENERATED from role_model -- never a literal,
# so the sub-subagent model cannot silently drift from the single source of
# truth (Task 6 review fix #10: previously untested).
: > "$FAKE_ARGV_LOG"
agents_json="$(jq -nc --arg m "$(role_model impl-worker)" \
  '{"impl-worker":{description:"d",prompt:"p",model:$m}}')"
EXTRA_VENDOR_ARGS=(--agents "$agents_json")
invoke_vendor context-discovery "$iv_prompt" "$WORK/agents.out" "$WORK/agents.err"
rc_agents=$?
assert_rc 0 "$rc_agents" "invoke_vendor succeeds with EXTRA_VENDOR_ARGS set"
assert_contains "--agents" "$FAKE_ARGV_LOG" \
  "invoke_vendor forwards EXTRA_VENDOR_ARGS (--agents) to claude"
assert_contains "$(role_model impl-worker)" "$FAKE_ARGV_LOG" \
  "the --agents payload carries the REGISTRY's impl-worker model, proven via role_model, not a literal"
# EXTRA_VENDOR_ARGS is left SET (not unset) across this next call -- the
# claim under test is that codex ignores it (claude-only), which the array
# being empty/unset would prove nothing about.
: > "$FAKE_ARGV_LOG"
invoke_vendor preflight-codex "$iv_prompt" "$WORK/agents-codex.out" "$WORK/agents-codex.err"
unset EXTRA_VENDOR_ARGS
assert_eq 0 "$("$GREP_BIN" -c -- '--agents' "$FAKE_ARGV_LOG" || true)" \
  "EXTRA_VENDOR_ARGS is claude-only and never reaches a codex launch, even when set"

# --- 9.10 TERM-respecting and TERM-ignoring timeouts, with a real process check
# Markers are scoped with $$ (this script's own PID) so a leftover from any
# OTHER concurrent run of this suite, or a prior failed run, can never match
# and produce a false pass OR a false "still running" failure. On assertion
# failure the orphan is killed immediately, so one bad run never poisons the
# next (a bare marker previously left a real `sleep` alive for later runs to
# trip over).
tcol2="$(tsv_column "$BUILD/roles.tsv" timeout_minutes)"
awk -F'\t' -v OFS='\t' -v col="$tcol2" -v v=0.02 \
  'NR==1{print;next} { if ($1=="context-discovery") $col=v; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-tiny.tsv"

term_marker="99$$.101"
: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-tiny.tsv" FAKE_MODE=timeout \
  FAKE_DELAY_SECONDS="$term_marker" FAKE_IGNORE_TERM=0 \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/term-ok.out" "$WORK/term-ok.err" &
term_ok_pid=$!
seen=0
for _ in $(seq 1 50); do
  pgrep -f "sleep $term_marker" >/dev/null 2>&1 && { seen=1; break; }
  sleep 0.1
done
[ "$seen" -eq 1 ] \
  && _ok "TERM-respecting case: the fake process was actually observed running before the deadline" \
  || _fail "TERM-respecting case: never observed the fake process running (test would not be meaningful)"
wait "$term_ok_pid"; rc=$?
# uutils and GNU coreutils disagree on the reported code for a timeout that
# resolves via plain TERM (this host's uutils returns 124; GNU can too, but
# is not guaranteed to on every build) -- accept either, per the plan's Global
# Constraints naming GNU coreutils as supported without pinning this detail.
case "$rc" in
  124) _ok "TERM-respecting timeout: invoke_vendor reports a plain timeout exit (rc=124)" ;;
  *) _fail "TERM-respecting timeout: expected rc 124 (no --kill-after escalation), got $rc" ;;
esac
sleep 0.2
if pgrep -f "sleep $term_marker" >/dev/null 2>&1; then
  _fail "TERM-respecting timeout: a fake process is still running after the timeout path"
  pkill -9 -f "sleep $term_marker" 2>/dev/null
else
  _ok "TERM-respecting timeout: no fake process remains"
fi

term_marker2="99$$.102"
: > "$FAKE_ARGV_LOG"
ROLE_CONTRACTS_PATH="$BUILD/roles-tiny.tsv" FAKE_MODE=timeout \
  FAKE_DELAY_SECONDS="$term_marker2" FAKE_IGNORE_TERM=1 \
  invoke_vendor context-discovery "$iv_prompt" "$WORK/term-ig.out" "$WORK/term-ig.err" &
term_ig_pid=$!
seen2=0
for _ in $(seq 1 50); do
  pgrep -f "sleep $term_marker2" >/dev/null 2>&1 && { seen2=1; break; }
  sleep 0.1
done
[ "$seen2" -eq 1 ] \
  && _ok "TERM-ignoring case: the fake process was actually observed running before the deadline" \
  || _fail "TERM-ignoring case: never observed the fake process running (test would not be meaningful)"
wait "$term_ig_pid"; rc=$?
# Both hosts must escalate here (the fake CLI ignores TERM) -- 124 (uutils'
# reserved "timed out" code) or 137 (128+SIGKILL, if the implementation
# reports the underlying signal) are both legitimate escalation evidence.
case "$rc" in
  124|137) _ok "TERM-ignoring timeout: invoke_vendor escalates via --kill-after (rc=$rc)" ;;
  *) _fail "TERM-ignoring timeout: expected rc 124 or 137, got $rc" ;;
esac
sleep 0.2
if pgrep -f "sleep $term_marker2" >/dev/null 2>&1; then
  _fail "TERM-ignoring timeout: a fake process is still running after the kill-after escalation"
  pkill -9 -f "sleep $term_marker2" 2>/dev/null
else
  _ok "TERM-ignoring timeout: no fake process remains (kill-after reaped it, nothing orphaned)"
fi

# --- 9.11 run_fake_attempt: every FAKE_MODE is distinctly observable -------
# (review finding #5: exit-no-status/malformed-status/publication-lost were
# previously byte-identical to `complete` -- a row-count assertion alone
# cannot catch that. Each mode now leaves a genuinely different STATUS_PATH
# shape, asserted directly below.)
rm -f "$BUILD/fake-attempt-results.tsv"
for vendor in claude codex; do
  run_fake_attempt "$vendor" complete none 0 >/dev/null 2>&1
  assert_rc 0 $? "$vendor complete: exits 0"
  assert_present '^verdict: DONE$' "$FAKE_ATTEMPT_STATUS_PATH" \
    "$vendor complete: writes a valid final STATUS file"
  assert_glob_count 0 "${FAKE_ATTEMPT_STATUS_PATH}.tmp.*" \
    "$vendor complete: no leftover STATUS temp"

  run_fake_attempt "$vendor" exit-no-status none 0 >/dev/null 2>&1
  assert_rc 0 $? "$vendor exit-no-status: exits 0"
  assert_not_exists "$FAKE_ATTEMPT_STATUS_PATH" "$vendor exit-no-status: no STATUS file"
  assert_glob_count 0 "${FAKE_ATTEMPT_STATUS_PATH}.tmp.*" \
    "$vendor exit-no-status: no sibling temp either"

  run_fake_attempt "$vendor" malformed-status none 0 >/dev/null 2>&1
  assert_rc 0 $? "$vendor malformed-status: exits 0"
  assert_exists "$FAKE_ATTEMPT_STATUS_PATH" "$vendor malformed-status: a STATUS file exists"
  assert_absent '^verdict: DONE$' "$FAKE_ATTEMPT_STATUS_PATH" \
    "$vendor malformed-status: its verdict is not the legal DONE (distinct from complete)"

  run_fake_attempt "$vendor" publication-lost none 0 >/dev/null 2>&1
  assert_rc 0 $? "$vendor publication-lost: exits 0"
  assert_not_exists "$FAKE_ATTEMPT_STATUS_PATH" "$vendor publication-lost: final STATUS absent"
  assert_glob_count 1 "${FAKE_ATTEMPT_STATUS_PATH}.tmp.*" \
    "$vendor publication-lost: exactly one sibling temp exists (distinct from exit-no-status)"

  for m in transient permanent unknown spend-ceiling; do
    run_fake_attempt "$vendor" "$m" none 1 >/dev/null 2>&1
    assert_rc 1 $? "$vendor mode=$m: fake CLI exits 1"
    assert_not_exists "$FAKE_ATTEMPT_STATUS_PATH" "$vendor mode=$m: no STATUS side effect"
  done

  run_fake_attempt "$vendor" orchestration-refusal none 0 >/dev/null 2>&1
  assert_rc 0 $? "$vendor orchestration-refusal: exits 0 (success envelope carrying a refusal)"

  run_fake_attempt "$vendor" timeout none 124 >/dev/null 2>&1
  rc=$?
  case "$rc" in
    124|137) _ok "run_fake_attempt $vendor mode=timeout is actually killed by the wrapper (rc=$rc)" ;;
    *) _fail "run_fake_attempt $vendor mode=timeout: expected rc 124 or 137, got $rc" ;;
  esac
done
assert_exists "$BUILD/fake-attempt-results.tsv" "run_fake_attempt appends to the shared results ledger"
assert_eq 21 "$(wc -l < "$BUILD/fake-attempt-results.tsv" | tr -d ' ')" \
  "run_fake_attempt recorded one row per (vendor, mode) pair, for every mode, plus the header"

# --- FAKE_LOG TSV framing is a parsing contract, not cosmetics --------------
# Every field is sanitized, not just argv: an unsanitized field carrying a tab
# or newline splits the row, after which `cut -f3` reads the wrong column and
# every downstream field assertion silently reads garbage. Feed hostile values
# through each field and assert the framing survives.
san_log="$WORK/san-framing.tsv"
: > "$san_log"
san_dir="$WORK/san dir"
mkdir -p "$san_dir"
for hostile in "$(printf 'evil\tmode')" "$(printf 'evil\nmode')" "plain"; do
  ( cd "$san_dir" && FAKE_LOG="$san_log" FAKE_MODE="$hostile" \
      DISPATCH_ID="$(printf 'd\tid')" LOGICAL_DISPATCH_ID="$(printf 'l\nid')" ATTEMPT="01" \
      "$REPO_TOP/tests/fakebin/claude" --model "$(printf 'm\todel')" -p x \
      </dev/null >/dev/null 2>&1 ) || true
done
san_rows=$(wc -l < "$san_log" | tr -d ' ')
assert_eq 3 "$san_rows" "a hostile FAKE_MODE/model/dispatch id still yields one log row per call"
san_bad=$(awk -F'\t' 'NF != 10 { n++ } END { print n+0 }' "$san_log")
assert_eq 0 "$san_bad" "every FAKE_LOG row has exactly 10 tab-separated fields"

# --- Task 8 Step 6: unauthorized mutation with NO lease held at all --------
# A read-only role (mutates=no) never calls acquire_write_lease. If it still
# leaves evidence of a repo change (FAKE_MUTATION's real-git side effect),
# inspect_mutation_state's own contract (above) makes that INTEGRITY_UNKNOWN,
# never a guessed clean/dirty state -- and Task 8 wires that straight into a
# durable ARTIFACT_INTEGRITY_BLOCKED event. Run LAST in this file: it leaves
# $REPO_ROOT genuinely dirty on purpose, which would otherwise pollute every
# later dirty-tree comparison in this same fixture.
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete FAKE_MUTATION=dirty-uncheckpointed \
  dispatch_attempt 3 22 summarizer-spec >/dev/null 2>&1
assert_eq INTEGRITY_UNKNOWN "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" mutation_state)" \
  "a read-only role that left a real repo change (no lease ever held) is INTEGRITY_UNKNOWN"
assert_present 'event=ARTIFACT_INTEGRITY_BLOCKED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the unauthorized mutation with no lease held emits a durable ARTIFACT_INTEGRITY_BLOCKED"
assert_present 'lease_owner:[[:space:]]*summarizer-spec' "$FEATURE_FOLDER/RUN_LOG.md" \
  "ARTIFACT_INTEGRITY_BLOCKED names the offending role"
git -C "$REPO_ROOT" checkout -q -- . 2>/dev/null
git -C "$REPO_ROOT" clean -q -fd -- fake-mutation.txt 2>/dev/null || true

finish
