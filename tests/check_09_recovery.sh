#!/usr/bin/env bash
# Check 9: table-driven coverage of every RM01-RM12 recovery row (spec S14.3),
# the ordered classifier's precedence (spec S14.1), and the seven resume
# states (spec S14.4). Offline; no tokens.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

load_cookbook || finish
# shellcheck source=lib/v2_fixtures.sh
source "$REPO_TOP/tests/lib/v2_fixtures.sh"

WORK="$BUILD/recovery"; rm -rf "$WORK"; mkdir -p "$WORK"
export PATH="$PWD/fakebin:$PATH"
export FAKE_ARGV_LOG="$WORK/argv.log"

# Same fixture shape as check_07_fakecli.sh (unexported orchestration vars;
# see its own header comment for why) -- including the docs/ placeholder
# commit inspect_mutation_state's dirty_tree_check-based comparison needs so
# an otherwise fully-untracked "docs/" subtree never collapses into one
# porcelain line above $FEATURE_FOLDER.
REPO_ROOT="$WORK/target"; mkdir -p "$REPO_ROOT"
git -C "$REPO_ROOT" init -q
( cd "$REPO_ROOT" && : > seed && git add seed \
  && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
mkdir -p "$REPO_ROOT/docs/superpowers/specs"
( cd "$REPO_ROOT" && : > docs/superpowers/specs/.gitkeep \
  && git add docs/superpowers/specs/.gitkeep \
  && git -c user.email=t@t -c user.name=t commit -qm seed-docs ) >/dev/null
FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/x-artifacts"
mkdir -p "$FEATURE_FOLDER/transcripts"
PROCESS_PATH="$PROCESS_DOC"

init_orchestration_vars \
  || { _fail "init_orchestration_vars failed in the fake environment"; finish; }

python3 "$REPO_TOP/tests/lib/extract.py" roles > /dev/null
export ROLE_CONTRACTS_PATH="$BUILD/roles.tsv"
export ORCHESTRATION_DIR="$FEATURE_FOLDER/.orchestration"
export RUNTIME_DIR="$ORCHESTRATION_DIR/runtime"
mkdir -p "$RUNTIME_DIR" "$ORCHESTRATION_DIR/snapshots"
python3 "$REPO_TOP/tests/lib/extract.py" policies > "$RUNTIME_DIR/policy.tsv"

# --- Fixture values for every key render_keys() lists (same set check_07 uses)
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

# A `debugger` copy with a tiny timeout (0.02min, well below the 60min
# headroom-probe threshold): every RM04-RM12 case below dispatches this same
# mutating role, and a short timeout keeps FAKE_MODE=timeout cases fast
# without an extra headroom-probe invocation muddying the picture.
tcol="$(tsv_column "$BUILD/roles.tsv" timeout_minutes)"
lrcol="$(tsv_column "$BUILD/roles.tsv" long_running)"
# long_running=no as well as a shrunk timeout: invoke_vendor's headroom-probe
# gate is an OR of "timeout>=threshold" and "long_running=yes" -- leaving the
# registry's own long_running=yes in place would still force a headroom probe
# despite the shrunk timeout, and that probe inherits whatever FAKE_MODE this
# fixture sets for the SUBSTANTIVE call too, turning every non-"complete"
# mode into a VENDOR_HEADROOM_REFUSED prelaunch failure before classify_attempt
# ever sees the real mode.
awk -F'\t' -v OFS='\t' -v tc="$tcol" -v lc="$lrcol" -v v=0.02 \
  'NR==1{print;next} { if ($1=="debugger") { $tc=v; $lc="no" }; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-debugger-tiny.tsv"

# A second debugger copy with a MODERATE timeout (2 minutes -- still below
# the 60-minute headroom-probe threshold, long_running=no) for the resume
# RUNNING_OBSERVED fixture below, which needs its fake attempt to actually
# still be sleeping when checked without the `timeout` wrapper killing it
# first (the 0.02-minute/1.2s tiny registry above is too short for that).
awk -F'\t' -v OFS='\t' -v tc="$tcol" -v lc="$lrcol" -v v=2 \
  'NR==1{print;next} { if ($1=="debugger") { $tc=v; $lc="no" }; print }' \
  "$BUILD/roles.tsv" > "$BUILD/roles-debugger-medium.tsv"

# Pristine baseline: every _drive_rm call resets the target repo back to
# this exact HEAD/clean-tree state afterward, so one test's FAKE_MUTATION
# side effect (a commit, an uncommitted fake-mutation.txt) can never leak
# into the NEXT test's "before" state.
_repo_baseline_head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
_reset_repo() {
  git -C "$REPO_ROOT" reset -q --hard "$_repo_baseline_head"
  # Exclude $FEATURE_FOLDER: it is untracked BY DESIGN (orchestration
  # artifacts, never committed) and lives under $REPO_ROOT in this fixture --
  # a bare `clean -fd` would delete RUN_LOG.md, $RUNTIME_DIR/policy.tsv, and
  # every attempt directory right along with the fake mutation's leftovers.
  git -C "$REPO_ROOT" clean -q -fd -e "${FEATURE_FOLDER#"$REPO_ROOT"/}"
}

# ============================================================================
# Step 1: table-driven coverage -- every recovery-matrix row actually executes.
# ============================================================================
executed_matrix_ids=()

# Asserts recovery_action's own output is exactly one well-formed matrix id
# (never empty, never more than one row) and records it as executed.
# <logical>/<vendor> are optional passthroughs to recovery_action, used only
# by the RM01/RM09 event-emission cases below.
_check_rm() {
  local expected_id="$1" classification="$2" state="$3" msg="$4" logical="${5:-}" vendor="${6:-}"
  recovery_action "$classification" "$state" "$logical" "$vendor"
  local rc=$?
  assert_rc 0 "$rc" "recovery_action($classification,$state) resolves: $msg"
  case "${RECOVERY_MATRIX_ID:-}" in
    RM0[1-9]|RM1[0-2]) _ok "recovery_action($classification,$state) yields exactly one well-formed matrix id" ;;
    *) _fail "recovery_action($classification,$state) yielded a malformed id: [${RECOVERY_MATRIX_ID:-}]" ;;
  esac
  assert_eq "$expected_id" "${RECOVERY_MATRIX_ID:-}" "$msg"
  [ -n "${RECOVERY_ACTION:-}" ] || _fail "$msg: RECOVERY_ACTION is empty"
  executed_matrix_ids+=("$expected_id")
}

# --- RM01: correctable prelaunch defect (render-check failure; vendor never
# invoked) -- a REAL prelaunch rejection, then the (non-lease) default state.
: > "$FEATURE_FOLDER/RUN_LOG.md"
_saved_spec_path="$SPEC_PATH"; unset SPEC_PATH
dispatch_attempt 3 21 spec-reviewer-claude >/dev/null 2>&1
rm01_rc=$?
SPEC_PATH="$_saved_spec_path"
assert_rc 1 "$rm01_rc" "RM01 fixture: dispatch_attempt fails closed on a missing render key"
assert_eq PRELAUNCH_FAILED "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "RM01 fixture: a render-check defect classifies PRELAUNCH_FAILED"
: > "$FEATURE_FOLDER/RUN_LOG.md"
_check_rm RM01 PRELAUNCH_FAILED CORRECTABLE \
  "RM01: correctable prelaunch defect -> correct once and retry" \
  p03-i21-spec-reviewer-claude
assert_present 'event=ORCHESTRATION_CORRECTION' "$FEATURE_FOLDER/RUN_LOG.md" \
  "RM01 emits ORCHESTRATION_CORRECTION (spec S14.3's own row 1 action, never silently skipped)"
assert_present 'logical_dispatch_id: *p03-i21-spec-reviewer-claude' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the ORCHESTRATION_CORRECTION event names the actual logical dispatch"

# --- RM02: a lease actively held by a genuinely running attempt.
rm -f "$ORCHESTRATION_DIR/write-lease.json"
: > "$FEATURE_FOLDER/RUN_LOG.md"
rm02_marker="20.$$"
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
  FAKE_MODE=complete FAKE_DELAY_SECONDS="$rm02_marker" \
  dispatch_attempt 6 22 debugger >/dev/null 2>&1 &
rm02_pid=$!
rm02_seen=0
for _ in $(seq 1 50); do
  pgrep -f "sleep $rm02_marker" >/dev/null 2>&1 && { rm02_seen=1; break; }
  sleep 0.1
done
[ "$rm02_seen" -eq 1 ] \
  && _ok "RM02 fixture: the lease-holding attempt was actually observed running" \
  || _fail "RM02 fixture: never observed the lease holder running (test would not be meaningful)"
rm02_state="$(_write_lease_state "$ORCHESTRATION_DIR/write-lease.json")"
assert_eq ACTIVE_LEASE_OWNER "$rm02_state" \
  "RM02 fixture: a lease held by a live DISPATCH_STARTED is ACTIVE_LEASE_OWNER"
_check_rm RM02 PRELAUNCH_FAILED ACTIVE_LEASE_OWNER \
  "RM02: active lease owner -> wait/observe, never steal"
# Active collision: a second acquire against the SAME still-live lease is
# refused quietly (wait/observe, spec RM02) -- never an integrity alarm,
# which is reserved for stale/ambiguous/malformed ownership (RM03).
rm02_owner_sha="$(sha256sum "$ORCHESTRATION_DIR/write-lease.json" | cut -d' ' -f1)"
rc=0
acquire_write_lease debugger-second role p06-i98-debugger-second-a01 6 "." 2>/dev/null || rc=$?
assert_rc 1 "$rc" "RM02: a second acquire against an ACTIVE lease is refused"
assert_eq "$rm02_owner_sha" "$(sha256sum "$ORCHESTRATION_DIR/write-lease.json" | cut -d' ' -f1)" \
  "RM02: the active owner's lease file is untouched by the refused collision"
assert_eq 0 "$("$GREP_BIN" -c 'event=ARTIFACT_INTEGRITY_BLOCKED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "RM02: an active collision is a quiet refusal, never an integrity alarm"
wait "$rm02_pid" 2>/dev/null
pkill -9 -f "sleep $rm02_marker" 2>/dev/null || true
rm -f "$ORCHESTRATION_DIR/write-lease.json"

# --- RM03: a stale/ambiguous lease (owner names a dispatch id that was never
# started -- no automatic reclaiming, ever).
write_fake_lease "$ORCHESTRATION_DIR/write-lease.json" p06-i99-debugger-a01 debugger
rm03_state="$(_write_lease_state "$ORCHESTRATION_DIR/write-lease.json")"
assert_eq AMBIGUOUS_LEASE "$rm03_state" \
  "RM03 fixture: a lease naming a never-started dispatch id is ambiguous"
_check_rm RM03 PRELAUNCH_FAILED "$(_write_lease_recovery_state "$rm03_state")" \
  "RM03: stale/ambiguous lease -> HALT for integrity reconciliation"
# Bonus (not separately counted): a malformed (non-JSON) lease file is ALSO
# stale/ambiguous, never treated as "no lease at all".
printf 'not json\n' > "$ORCHESTRATION_DIR/write-lease.json"
assert_eq MALFORMED_LEASE "$(_write_lease_state "$ORCHESTRATION_DIR/write-lease.json")" \
  "a malformed lease file is also classified, never treated as absent"
assert_eq STALE_OR_AMBIGUOUS_LEASE \
  "$(_write_lease_recovery_state "$(_write_lease_state "$ORCHESTRATION_DIR/write-lease.json")")" \
  "a malformed lease also routes to RM03, never RM02"
rm -f "$ORCHESTRATION_DIR/write-lease.json"

# Drives one dispatch_attempt of the `debugger` role (mutating, tiny timeout)
# under the given FAKE_MODE/FAKE_MUTATION, asserts the REAL observed
# classification/mutation_state, then feeds them to recovery_action.
_drive_rm() {
  local expected_id="$1" expected_class="$2" expected_state="$3" mode="$4" mutation="$5" iter="$6" msg="$7"
  : > "$FEATURE_FOLDER/RUN_LOG.md"
  ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
    FAKE_MODE="$mode" FAKE_MUTATION="$mutation" \
    dispatch_attempt 6 "$iter" debugger >/dev/null 2>&1
  assert_eq "$expected_class" "${DISPATCH_RESULT_CLASSIFICATION:-}" \
    "$msg: classify_attempt reports $expected_class"
  assert_eq "$expected_state" "${DISPATCH_RESULT_MUTATION_STATE:-}" \
    "$msg: inspect_mutation_state reports $expected_state"
  _check_rm "$expected_id" "${DISPATCH_RESULT_CLASSIFICATION:-}" "${DISPATCH_RESULT_MUTATION_STATE:-}" "$msg"
  _reset_repo
}

# --- RM04: publication lost, nothing mutated yet -> one publication retry.
_drive_rm RM04 PUBLICATION_LOST NO_SIDE_EFFECTS publication-lost none 23 \
  "RM04: publication lost, NO_SIDE_EFFECTS"

# --- RM05: transient/no-status, NO_SIDE_EFFECTS -> fresh transient retry.
# Both declared classifications for this row are exercised.
_drive_rm RM05 TRANSIENT_TRANSPORT_ERROR NO_SIDE_EFFECTS transient none 24 \
  "RM05a: transient, NO_SIDE_EFFECTS"
_drive_rm RM05 EXITED_NO_STATUS NO_SIDE_EFFECTS exit-no-status none 25 \
  "RM05b: exited-no-status, NO_SIDE_EFFECTS"

# --- RM06: timeout/transient/no-status/publication-lost, CLEAN_CHECKPOINTED
# -> continuation. Two of its four declared classifications are exercised
# (TIMED_OUT and PUBLICATION_LOST -- the latter proves the table/function
# reconciliation from Task 7 review finding #8: PUBLICATION_LOST +
# CLEAN_CHECKPOINTED routes here, not RM04, once anything is actually
# checkpointed).
_drive_rm RM06 TIMED_OUT CLEAN_CHECKPOINTED timeout clean-checkpointed 26 \
  "RM06a: timed out, CLEAN_CHECKPOINTED"
_drive_rm RM06 PUBLICATION_LOST CLEAN_CHECKPOINTED publication-lost clean-checkpointed 60 \
  "RM06b: publication lost, CLEAN_CHECKPOINTED"

# --- RM07: same family (plus publication-lost), DIRTY_CHECKPOINTED ->
# reconcile then continue only if isolated. Both declared classifications
# exercised.
_drive_rm RM07 TRANSIENT_TRANSPORT_ERROR DIRTY_CHECKPOINTED transient dirty-checkpointed 27 \
  "RM07a: transient, DIRTY_CHECKPOINTED"
_drive_rm RM07 PUBLICATION_LOST DIRTY_CHECKPOINTED publication-lost dirty-checkpointed 28 \
  "RM07b: publication lost, DIRTY_CHECKPOINTED"

# --- RM08: any failure, DIRTY_UNCHECKPOINTED or INTEGRITY_UNKNOWN -> HALT.
# Every declared mutation state for this row is exercised.
_drive_rm RM08 TRANSIENT_TRANSPORT_ERROR DIRTY_UNCHECKPOINTED transient dirty-uncheckpointed 29 \
  "RM08a: transient, DIRTY_UNCHECKPOINTED"
_drive_rm RM08 TRANSIENT_TRANSPORT_ERROR INTEGRITY_UNKNOWN transient unknown 30 \
  "RM08b: transient, INTEGRITY_UNKNOWN"

# --- RM09: spend ceiling -> suppress vendor, halt/degrade. Both the
# non-zero-wrapper and zero-wrapper shapes are exercised (spec S14.1: a real
# ceiling can present as rc=0 wrapping an is_error envelope just as easily as
# a non-zero exit).
: > "$FEATURE_FOLDER/RUN_LOG.md"
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
  FAKE_MODE=spend-ceiling FAKE_MUTATION=none dispatch_attempt 6 31 debugger >/dev/null 2>&1
assert_eq SPEND_CEILING "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "RM09a (non-zero wrapper): classify_attempt reports SPEND_CEILING"
_check_rm RM09 SPEND_CEILING NO_SIDE_EFFECTS "RM09a: spend ceiling, non-zero wrapper" \
  p06-i31-debugger claude
assert_present 'event=VENDOR_UNAVAILABLE' "$FEATURE_FOLDER/RUN_LOG.md" \
  "RM09 emits a run-scoped vendor-unavailable event (spec S14.3's own row 9 action)"
assert_present 'vendor: *claude' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the VENDOR_UNAVAILABLE event names the suppressed vendor"
: > "$FEATURE_FOLDER/RUN_LOG.md"
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
  FAKE_MODE=spend-ceiling FAKE_EXIT_CODE=0 FAKE_MUTATION=none dispatch_attempt 6 32 debugger >/dev/null 2>&1
assert_eq SPEND_CEILING "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "RM09b (zero wrapper): classify_attempt STILL reports SPEND_CEILING, not COMPLETED/EXITED_NO_STATUS"
_check_rm RM09 SPEND_CEILING NO_SIDE_EFFECTS "RM09b: spend ceiling, zero wrapper"

# --- RM10: permanent/unknown vendor error -> no retry. Both declared
# classifications exercised.
_drive_rm RM10 PERMANENT_VENDOR_ERROR NO_SIDE_EFFECTS permanent none 33 \
  "RM10a: permanent vendor error"
_drive_rm RM10 UNKNOWN_VENDOR_ERROR NO_SIDE_EFFECTS unknown none 34 \
  "RM10b: unknown vendor error"

# --- RM11: malformed STATUS. All three of its declared mutation states.
_drive_rm RM11 MALFORMED_STATUS NO_SIDE_EFFECTS malformed-status none 35 \
  "RM11a: malformed STATUS, NO_SIDE_EFFECTS (non-mutating correction retry)"
_drive_rm RM11 MALFORMED_STATUS CLEAN_CHECKPOINTED malformed-status clean-checkpointed 36 \
  "RM11b: malformed STATUS, CLEAN_CHECKPOINTED (reconcile first)"
_drive_rm RM11 MALFORMED_STATUS DIRTY_CHECKPOINTED malformed-status dirty-checkpointed 37 \
  "RM11c: malformed STATUS, DIRTY_CHECKPOINTED (reconcile first)"

# --- RM12: completed -> branch on verdict. summarizer-spec is the cheapest
# real role whose legal verdict set includes the fake CLI's default DONE body
# (see check_07_fakecli.sh's own comment on this exact fixture choice).
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete FAKE_MUTATION=none dispatch_attempt 3 38 summarizer-spec >/dev/null 2>&1
assert_eq COMPLETED "${DISPATCH_RESULT_CLASSIFICATION:-}" "RM12: classify_attempt reports COMPLETED"
_check_rm RM12 COMPLETED NO_SIDE_EFFECTS "RM12: completed -> branch on validated verdict"

# --- Step 1's own assertion: every recovery-matrix row from the prompt
# actually executed, sorted, exactly RM01-RM12.
expected_ids="$(python3 "$REPO_TOP/tests/lib/extract.py" recovery | tail -n +2 | cut -f1 | sort)"
actual_ids="$(printf '%s\n' "${executed_matrix_ids[@]}" | sort -u)"
assert_eq "$expected_ids" "$actual_ids" "every recovery-matrix row executed at least one case"
assert_eq 12 "$(printf '%s\n' "$actual_ids" | sed '/^$/d' | wc -l | tr -d ' ')" "RM01-RM12, no more, no fewer"

# ============================================================================
# Step 3: ordered-classifier precedence -- hand-crafted transcripts prove
# EACH earlier row wins over a later one it could otherwise also match.
# ============================================================================
_mk_envelope() {
  # Usage: _mk_envelope <path> <is_error true|false> <result-text>
  printf '{"type":"result","is_error":%s,"result":%s,"total_cost_usd":0.01,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}\n' \
    "$2" "$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" > "$1"
}

ord_dir="$WORK/ordering"; mkdir -p "$ord_dir"

# 1. rc=95 (prelaunch) wins even when a fully valid STATUS sits at the path.
o1_status="$ord_dir/o1-STATUS.md"
printf 'verdict: DONE\nreason: irrelevant\n' > "$o1_status"
: > "$ord_dir/o1.out"; : > "$ord_dir/o1.err"
classify_attempt summarizer-spec 95 "$ord_dir/o1.out" "$ord_dir/o1.err" "$o1_status"
assert_eq PRELAUNCH_FAILED "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: rc=95 outranks a valid STATUS (PRELAUNCH_FAILED, never COMPLETED)"

# 2. rc=124 (timeout) wins even when a fully valid STATUS sits at the path.
: > "$ord_dir/o2.out"; : > "$ord_dir/o2.err"
classify_attempt summarizer-spec 124 "$ord_dir/o2.out" "$ord_dir/o2.err" "$o1_status"
assert_eq TIMED_OUT "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: rc=124 outranks a valid STATUS (TIMED_OUT, never COMPLETED)"

# 3. An orchestration refusal arriving as a GENUINE SUCCESS envelope
# (is_error:false, rc=0, NO status file at all) outranks the EXITED_NO_STATUS
# bucket it would otherwise fall into. is_error IS false here deliberately
# (Task 7 review finding #5): vendor_error_text only extracts .result text
# when is_error==true, so a test using an ERROR envelope would prove nothing
# about the actual success-envelope code path (_claude_result_text) this
# case exists to cover.
_mk_envelope "$ord_dir/o3.out" false "I cannot complete this task: the requested path is outside the repository."
: > "$ord_dir/o3.err"
classify_attempt summarizer-spec 0 "$ord_dir/o3.out" "$ord_dir/o3.err" "$ord_dir/o3-STATUS.md"
assert_eq PRELAUNCH_FAILED "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: a SUCCESS-envelope orchestration refusal outranks EXITED_NO_STATUS"
case "$CLASSIFY_ATTEMPT_REASON" in
  ORCHESTRATION_REFUSAL:*) _ok "ordering: the refusal's reason names itself" ;;
  *) _fail "ordering: expected an ORCHESTRATION_REFUSAL reason, got [$CLASSIFY_ATTEMPT_REASON]" ;;
esac

# 3b. The SAME refusal text, embedded in an is_error:true ERROR envelope,
# must ALSO still be caught (vendor_error_text's own extraction path) --
# proves _orchestration_refusal_text reads BOTH shapes, not just one.
_mk_envelope "$ord_dir/o3b.out" true "I cannot complete this task: the requested path is outside the repository."
: > "$ord_dir/o3b.err"
classify_attempt summarizer-spec 0 "$ord_dir/o3b.out" "$ord_dir/o3b.err" "$ord_dir/o3b-STATUS.md"
assert_eq PRELAUNCH_FAILED "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: an ERROR-envelope orchestration refusal ALSO outranks EXITED_NO_STATUS"

# 3c (Task 7 review finding #6): the refusal check is evaluated AFTER
# TIMED_OUT (spec row 2), never before it -- a timed-out MUTATING attempt
# that left a partial error-shaped transcript must still route through
# RM06/RM07/RM08's mutation-state gate (via TIMED_OUT), not RM01's ungated
# CORRECT_AND_RETRY (which never even inspects mutation state).
classify_attempt summarizer-spec 124 "$ord_dir/o3b.out" "$ord_dir/o3b.err" "$ord_dir/o3b-STATUS.md"
assert_eq TIMED_OUT "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: TIMED_OUT outranks a refusal-shaped transcript left behind by a killed attempt"

# 3d (Task 7 review round 2, finding #1): a VALID STATUS already proves the
# role did not refuse -- its own summary prose is free to legitimately say
# things like "fixed invalid input handling" or "the wrong working directory
# case" without that being misread as a refusal. rc=0, a genuine success
# envelope (is_error:false) whose .result contains refusal-shaped phrasing,
# but a fresh valid STATUS sits at the path: must be COMPLETED, never
# PRELAUNCH_FAILED. (Revert the "only fall back to _claude_result_text when
# there is no valid STATUS" guard in _orchestration_refusal_text and this is
# exactly the case that turns red.)
_mk_envelope "$ord_dir/o3d.out" false "Fixed invalid input handling; added a guard for the wrong working directory case. 12 tests pass."
: > "$ord_dir/o3d.err"
classify_attempt summarizer-spec 0 "$ord_dir/o3d.out" "$ord_dir/o3d.err" "$o1_status"
assert_eq COMPLETED "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: a valid STATUS overrides refusal-shaped SUCCESS prose -- a finished attempt is never misread as a refusal"

# 4. SPEND_CEILING outranks PERMANENT_VENDOR_ERROR when BOTH signatures are
# present in the same transcript (evaluated in order; first match wins).
_mk_envelope "$ord_dir/o4.out" true "usage limit reached: credit balance is too low. Also: authentication_error: invalid api key."
: > "$ord_dir/o4.err"
classify_attempt summarizer-spec 1 "$ord_dir/o4.out" "$ord_dir/o4.err" "$ord_dir/o4-STATUS.md"
assert_eq SPEND_CEILING "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: SPEND_CEILING outranks a co-occurring PERMANENT_VENDOR_ERROR signature"

# 5. PERMANENT_VENDOR_ERROR outranks TRANSIENT_TRANSPORT_ERROR similarly.
_mk_envelope "$ord_dir/o5.out" true "authentication_error: invalid api key; permission denied. Also: please try again later (rate limited)."
: > "$ord_dir/o5.err"
classify_attempt summarizer-spec 1 "$ord_dir/o5.out" "$ord_dir/o5.err" "$ord_dir/o5-STATUS.md"
assert_eq PERMANENT_VENDOR_ERROR "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: PERMANENT_VENDOR_ERROR outranks a co-occurring TRANSIENT_TRANSPORT_ERROR signature"

# 6. Baseline floor: rc=0, no signature, no STATUS, no sibling temp ->
# EXITED_NO_STATUS (proves the ladder is reached only once nothing above matches).
: > "$ord_dir/o6.out"; : > "$ord_dir/o6.err"
classify_attempt summarizer-spec 0 "$ord_dir/o6.out" "$ord_dir/o6.err" "$ord_dir/o6-STATUS.md"
assert_eq EXITED_NO_STATUS "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: the floor case (nothing else matches) is EXITED_NO_STATUS"

# 7. A malformed STATUS outranks COMPLETED (a present-but-invalid STATUS is
# never silently accepted).
o7_status="$ord_dir/o7-STATUS.md"; printf 'verdict: NOT_A_REAL_VERDICT\n' > "$o7_status"
: > "$ord_dir/o7.out"; : > "$ord_dir/o7.err"
classify_attempt summarizer-spec 0 "$ord_dir/o7.out" "$ord_dir/o7.err" "$o7_status"
assert_eq MALFORMED_STATUS "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: an invalid verdict is MALFORMED_STATUS, never COMPLETED"

# 8. Positive floor: a genuinely valid STATUS is COMPLETED.
classify_attempt summarizer-spec 0 "$ord_dir/o6.out" "$ord_dir/o6.err" "$o1_status"
assert_eq COMPLETED "$CLASSIFY_ATTEMPT_RESULT" \
  "ordering: a fresh, valid, belongs-to-the-attempt STATUS is COMPLETED"

# ============================================================================
# Task 7 review finding #8: the Recovery Matrix table and recovery_action
# must agree for EVERY (classification, mutation_state) pair, not just the
# representative ones Step 1 drives through a real dispatch. This is an
# INDEPENDENT oracle (a second, hand-written mapping matching the
# reconciled table) rather than a re-read of recovery_action's own source,
# so a future edit to one without the other is caught here.
# ============================================================================
# Table-driven, not a hand-written duplicate oracle: reads the ACTUAL
# extracted "recovery" TSV (the same one extract.py recovery produces for
# any future consumer) and expands every row's classification/mutation_state
# cell (comma-separated sets, plus RM08's ANY_FAILURE and RM12's ANY
# wildcards) into the full set of concrete pairs it covers, then asserts
# recovery_action agrees for EVERY one. A future edit to the MARKDOWN table
# that recovery_action's code does not follow (or vice versa) shows up here,
# not just a change to this test file's own beliefs about what the table says.
recovery_tsv="$BUILD/recovery-crosscheck.tsv"
python3 "$REPO_TOP/tests/lib/extract.py" recovery > "$recovery_tsv"
all_failure_classifications="TIMED_OUT SPEND_CEILING PERMANENT_VENDOR_ERROR TRANSIENT_TRANSPORT_ERROR UNKNOWN_VENDOR_ERROR EXITED_NO_STATUS PUBLICATION_LOST MALFORMED_STATUS"
all_states="NO_SIDE_EFFECTS CLEAN_CHECKPOINTED DIRTY_CHECKPOINTED DIRTY_UNCHECKPOINTED INTEGRITY_UNKNOWN"

declare -A _expected=()
while IFS=$'\t' read -r mid classes states _action; do
  [ "$mid" = matrix_id ] && continue
  IFS=',' read -ra c_list <<< "$classes"
  IFS=',' read -ra s_list <<< "$states"
  for c in "${c_list[@]}"; do
    if [ "$c" = ANY_FAILURE ]; then c_expanded="$all_failure_classifications"; else c_expanded="$c"; fi
    for cc in $c_expanded; do
      for st in "${s_list[@]}"; do
        if [ "$st" = ANY ]; then st_expanded="$all_states"; else st_expanded="$st"; fi
        for ss in $st_expanded; do
          if [ -n "${_expected["$cc,$ss"]:-}" ] && [ "${_expected["$cc,$ss"]}" != "$mid" ]; then
            note "Recovery Matrix table conflict: ($cc,$ss) is claimed by both ${_expected["$cc,$ss"]} and $mid"
            _fail "the Recovery Matrix table assigns each (classification, mutation_state) pair to at most one row"
          fi
          _expected["$cc,$ss"]="$mid"
        done
      done
    done
  done
done < "$recovery_tsv"

# Enumerate the FULL fixed cross product (never just "${!_expected[@]}"):
# iterating only the table's own keys would silently stop checking a pair
# the table dropped, rather than catching that omission as a mismatch --
# a missing table entry must show up as expected="" clashing with whatever
# real matrix id recovery_action's (unchanged) code still returns for it.
_cross_check_mismatches=0
_cross_check_pairs=0
for classification in PRELAUNCH_FAILED $all_failure_classifications COMPLETED; do
  if [ "$classification" = PRELAUNCH_FAILED ]; then
    probe_states="CORRECTABLE ACTIVE_LEASE_OWNER STALE_OR_AMBIGUOUS_LEASE"
  elif [ "$classification" = COMPLETED ]; then
    probe_states="NO_SIDE_EFFECTS"   # state is ignored by recovery_action for COMPLETED
  else
    probe_states="$all_states"
  fi
  for state in $probe_states; do
    key="$classification,$state"
    expected="${_expected[$key]:-}"
    recovery_action "$classification" "$state" >/dev/null 2>&1
    actual="${RECOVERY_MATRIX_ID:-}"
    _cross_check_pairs=$((_cross_check_pairs + 1))
    if [ "$actual" != "$expected" ]; then
      _cross_check_mismatches=$((_cross_check_mismatches + 1))
      note "table/function disagree for ($classification,$state): table says [$expected], function says [$actual]"
    fi
  done
done
assert_eq 0 "$_cross_check_mismatches" \
  "the Recovery Matrix table and recovery_action agree for every (classification, mutation_state) pair"
[ "$_cross_check_pairs" -ge 40 ] \
  && _ok "the cross-check actually enumerated a non-trivial number of pairs ($_cross_check_pairs)" \
  || _fail "the cross-check enumerated suspiciously few pairs ($_cross_check_pairs) -- likely vacuous"

# ============================================================================
# Task 7 review finding #4: inspect_mutation_state must see a document-
# mutating role's OWNED path (SPEC_PATH/PLAN_PATH), not just $REPO_ROOT's
# git-tracked source -- reusing dirty_tree_check's allow-list (which exempts
# $PLAN_PATH/$SPEC_PATH/the whole $FEATURE_FOLDER) silently read every such
# role as NO_SIDE_EFFECTS regardless of what it actually wrote.
# ============================================================================
owned_snap="$WORK/owned-path-snapshot"; mkdir -p "$owned_snap"
git -C "$REPO_ROOT" rev-parse HEAD > "$owned_snap/pre-head"
: > "$PLAN_PATH"
printf 'a freshly written plan\n' >> "$PLAN_PATH"
owned_state="$(MUTATION_SNAPSHOT_DIR="$owned_snap" inspect_mutation_state plan-writer)"
assert_eq DIRTY_UNCHECKPOINTED "$owned_state" \
  "plan-writer's own \$PLAN_PATH edit is visible to inspect_mutation_state (HEAD unmoved, real content changed)"
recovery_action TIMED_OUT "$owned_state" >/dev/null 2>&1
assert_eq RM08 "${RECOVERY_MATRIX_ID:-}" \
  "an owned-path mutation with no checkpoint correctly routes to RM08 (HALT), never RM05's ungated retry"
git -C "$REPO_ROOT" checkout -q -- . 2>/dev/null; rm -f "$PLAN_PATH"

# ============================================================================
# Task 7 review round 2, finding #2: the */attempts/* exclusion inside
# _mutation_dirty must be anchored under $FEATURE_FOLDER, not matched
# anywhere in the repo -- a target repo that happens to have its OWN
# "attempts/" directory (a test harness, retry/scheduling code, migrations)
# must never have real changes under it silently excluded as if it were
# this attempt's own bookkeeping.
# ============================================================================
attempts_snap="$WORK/attempts-path-snapshot"; mkdir -p "$attempts_snap"
git -C "$REPO_ROOT" rev-parse HEAD > "$attempts_snap/pre-head"
mkdir -p "$REPO_ROOT/src/attempts"
printf 'def run(): pass
' > "$REPO_ROOT/src/attempts/runner.py"
attempts_state="$(MUTATION_SNAPSHOT_DIR="$attempts_snap" inspect_mutation_state implementer)"
assert_eq DIRTY_UNCHECKPOINTED "$attempts_state"   "a target repo's OWN src/attempts/ directory is real content, never mistaken for this attempt's own bookkeeping"
git -C "$REPO_ROOT" clean -q -fd -e "${FEATURE_FOLDER#"$REPO_ROOT"/}"

# ============================================================================
# Task 7 review findings #1-#3: retry-cap enforcement, exact counts, and the
# peer-rejected carry-over.
# ============================================================================

# --- finding #1: a cap of 1 ("retry once") permits exactly one retry and
# denies the next -- the off-by-one this review caught denied the FIRST
# retry outright (used_count>=cap treated the ORIGINAL failing attempt
# itself as already having consumed the one retry).
cap_logical="p06-i50-debugger"
: > "$FEATURE_FOLDER/RUN_LOG.md"
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
  FAKE_MODE=transient FAKE_MUTATION=none dispatch_attempt 6 50 debugger >/dev/null 2>&1
assert_eq TRANSIENT_TRANSPORT_ERROR "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "cap fixture: first attempt (a01) really did fail transient"
recovery_retry_allowed "$cap_logical" TRANSIENT_RETRY
assert_rc 0 $? "cap fixture: after failure #1 (0 retries spent), transient_retry_cap=1 still permits a retry"
assert_present 'event=RECOVERY_AUTHORIZED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "code review fix #9: an authorized retry emits a durable RECOVERY_AUTHORIZED event"
assert_present "logical_dispatch_id: *${cap_logical}\$" "$FEATURE_FOLDER/RUN_LOG.md" \
  "RECOVERY_AUTHORIZED names the actual logical dispatch"
# finding #2 (Step 4's "every retry allocates a new attempt id"): the retry
# itself goes through the normal allocate_attempt/dispatch_attempt path, so
# it lands in a genuinely NEW, distinct attempt directory (a02), never
# reusing a01's -- allocate_attempt's own bare `mkdir` (no -p) on the leaf
# is what a real caller relies on to guarantee this.
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
  FAKE_MODE=transient FAKE_MUTATION=none dispatch_attempt 6 50 debugger >/dev/null 2>&1
retry_id="$("$GREP_BIN" -oE "${cap_logical}-a[0-9]{2}" "$FEATURE_FOLDER/RUN_LOG.md" | sort -u)"
assert_eq "$(printf '%s\n' "${cap_logical}-a01" "${cap_logical}-a02")" "$retry_id" \
  "every retry allocates a genuinely new, distinct attempt id (a01 then a02)"
dir_a01="$(role_attempt_dir debugger "${cap_logical}-a01")"
dir_a02="$(role_attempt_dir debugger "${cap_logical}-a02")"
if [ -n "$dir_a01" ] && [ -n "$dir_a02" ] && [ "$dir_a01" != "$dir_a02" ] \
   && [ -d "$dir_a01" ] && [ -d "$dir_a02" ]; then
  _ok "the retry's attempt directory is real and disjoint from the original's"
else
  _fail "retry attempt directories are not disjoint or do not exist: [$dir_a01] vs [$dir_a02]"
fi
recovery_retry_allowed "$cap_logical" TRANSIENT_RETRY
assert_rc 1 $? "cap fixture: after failure #2 (the one retry also failed), transient_retry_cap=1 now denies"
assert_present 'event=RECOVERY_CAP_REACHED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the cap-reached event is durable"
assert_present 'cap: *transient_retry_cap' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the cap-reached event names the actual cap"

# --- continuation_cap=3: exactly three continuations are permitted (after
# failures #1, #2, #3), the one after failure #4 denied. Checked BETWEEN
# each dispatch (not after all four have already happened, which would
# always see the FINAL used_count and deny every check retroactively).
cont_logical="p06-i51-debugger"
: > "$FEATURE_FOLDER/RUN_LOG.md"
for n in 1 2 3 4; do
  ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
    FAKE_MODE=timeout FAKE_MUTATION=clean-checkpointed dispatch_attempt 6 51 debugger >/dev/null 2>&1
  assert_eq TIMED_OUT "${DISPATCH_RESULT_CLASSIFICATION:-}" \
    "continuation fixture: failure #$n really did happen (TIMED_OUT/CLEAN_CHECKPOINTED)"
  _reset_repo
  recovery_retry_allowed "$cont_logical" CONTINUE_WITHIN_CAP
  rc=$?
  if [ "$n" -le 3 ]; then
    assert_rc 0 "$rc" "continuation_cap=3: the continuation after failure #$n is permitted"
  else
    assert_rc 1 "$rc" "continuation_cap=3: the continuation after failure #$n (a 4th) is denied"
  fi
done

# --- finding #3: DISPATCH_PARALLEL_PEER_REJECTED must NOT consume the
# innocent peer's own retry/correction budget -- it never had a chance to
# fail on its own merits. Reuses check_07_fakecli.sh's own batch-reject
# fixture shape (one role's render fails, its peer never even launches).
peer_logical="p03-i52-summarizer-spec"
: > "$FEATURE_FOLDER/RUN_LOG.md"
_saved_spec_path="$SPEC_PATH"; unset SPEC_PATH
# Rejected TWICE (exceeding prelaunch_correction_cap=1 if the budget were
# WRONGLY keyed on allocated attempt ids instead of real failures): a single
# peer-rejection cannot distinguish the two counting methods, since even the
# buggy one still has 0 retries "spent" after just one allocation.
dispatch_parallel 3 52 spec-reviewer-claude summarizer-spec >/dev/null 2>&1
dispatch_parallel 3 52 spec-reviewer-claude summarizer-spec >/dev/null 2>&1
SPEC_PATH="$_saved_spec_path"
assert_present "DISPATCH_PARALLEL_PEER_REJECTED" "$FEATURE_FOLDER/RUN_LOG.md" \
  "peer-rejected fixture: the innocent peer really was rejected as a peer, not its own defect"
peer_attempts="$("$GREP_BIN" -oE "${peer_logical}-a[0-9]{2}" "$FEATURE_FOLDER/RUN_LOG.md" | sort -u | wc -l | tr -d ' ')"
assert_eq 2 "$peer_attempts" \
  "peer-rejected fixture: TWO attempt ids were allocated for the peer across the two batches (test setup is meaningful)"
recovery_retry_allowed "$peer_logical" CORRECT_AND_RETRY
assert_rc 0 $? \
  "a peer-rejected role's own correction budget is UNSPENT even after TWO peer-rejections (Task 6 carry-over, Task 7 review finding #3)"
assert_eq 0 "$("$GREP_BIN" -c 'event=RECOVERY_CAP_REACHED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "no cap-reached event fires for a peer that never failed on its own merits"

# ============================================================================
# Step 5: resume-state classification -- all seven states.
# ============================================================================

# 1. NOT_STARTED: no attempt record for this logical id anywhere.
assert_eq NOT_STARTED "$(resume_dispatch_state p03-i97-summarizer-spec)" \
  "resume: a logical dispatch with no attempt at all is NOT_STARTED"

# 2. PRELAUNCH_FAILED: DISPATCH_NOT_LAUNCHED exists for its only attempt.
: > "$FEATURE_FOLDER/RUN_LOG.md"
_saved_spec_path="$SPEC_PATH"; unset SPEC_PATH
dispatch_attempt 3 39 spec-reviewer-claude >/dev/null 2>&1
SPEC_PATH="$_saved_spec_path"
assert_eq PRELAUNCH_FAILED "$(resume_dispatch_state p03-i39-spec-reviewer-claude)" \
  "resume: a prelaunch-rejected logical dispatch is PRELAUNCH_FAILED"

# 3. RUNNING_OBSERVED: start exists, the child is genuinely still live.
: > "$FEATURE_FOLDER/RUN_LOG.md"
rm -f "$ORCHESTRATION_DIR/write-lease.json"
resume_marker="2.$$"
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-medium.tsv" \
  FAKE_MODE=complete FAKE_DELAY_SECONDS="$resume_marker" \
  dispatch_attempt 6 40 debugger >/dev/null 2>&1 &
resume_pid=$!
resume_seen=0
for _ in $(seq 1 50); do
  pgrep -f "sleep $resume_marker" >/dev/null 2>&1 && { resume_seen=1; break; }
  sleep 0.1
done
[ "$resume_seen" -eq 1 ] \
  && _ok "resume RUNNING_OBSERVED fixture: the child was actually observed running" \
  || _fail "resume RUNNING_OBSERVED fixture: never observed the child running"
assert_eq RUNNING_OBSERVED "$(resume_dispatch_state p06-i40-debugger)" \
  "resume: a live, still-running dispatch is RUNNING_OBSERVED"
wait "$resume_pid" 2>/dev/null
pkill -9 -f "sleep $resume_marker" 2>/dev/null || true
assert_eq COMPLETED_VALID "$(resume_dispatch_state p06-i40-debugger)" \
  "resume: the same logical id is no longer RUNNING_OBSERVED once it actually finishes"

# 4. ORPHANED_UNOBSERVED: start exists, no completion, no child is live
# (a REAL killed process -- never a hand-injected RUN_LOG line, same
# discipline check_07_fakecli.sh's own orphan cases already apply).
: > "$FEATURE_FOLDER/RUN_LOG.md"
_dispatch_prelaunch 3 41 summarizer-spec \
  || _fail "resume ORPHANED_UNOBSERVED fixture: prelaunch failed (test setup broken)"
phase=3; iteration=41; phase_name=spec-review
roles=(summarizer-spec)
dp_attempt_dir=("$PREP_ATTEMPT_DIR"); dp_dispatch_id=("$PREP_DISPATCH_ID")
dp_logical=("$PREP_LOGICAL"); dp_attempt=("$PREP_ATTEMPT")
dp_status_path=("$PREP_STATUS_PATH"); dp_stdout_path=("$PREP_STDOUT_PATH")
dp_stderr_path=("$PREP_STDERR_PATH"); dp_vendor=("$PREP_VENDOR")
dp_mutates=("$PREP_MUTATES"); dp_prompt_file=("$PREP_PROMPT_FILE")
orphan_marker="22.$$"
FAKE_MODE=timeout FAKE_DELAY_SECONDS="$orphan_marker" _dispatch_launch_attempt 0 &
orphan_pid=$!
orphan_seen=0
for _ in $(seq 1 50); do
  dispatch_is_running "${dp_dispatch_id[0]}" && { orphan_seen=1; break; }
  sleep 0.1
done
[ "$orphan_seen" -eq 1 ] \
  && _ok "resume ORPHANED_UNOBSERVED fixture: DISPATCH_STARTED became durable before the kill" \
  || _fail "resume ORPHANED_UNOBSERVED fixture: never observed a durable DISPATCH_STARTED"
kill -9 "$orphan_pid" 2>/dev/null
wait "$orphan_pid" 2>/dev/null
pkill -9 -f "sleep $orphan_marker" 2>/dev/null || true
# Killing orphan_pid (the orchestrator-side subshell) does not kill its own
# descendants (the nested invoke_vendor subshell, `timeout`, the fakebin
# script) -- SIGKILL never propagates to children. Each of those notices its
# own child died and exits in turn, but that unwind is not instantaneous;
# poll for _dispatch_child_live to actually clear rather than asserting
# against a race (same "wait for the real condition" discipline check_07's
# own process-liveness assertions already use, just for disappearance
# instead of appearance).
# Budget raised (was 30x0.1s=3s) and exhaustion now fails EXPLICITLY (Task 7
# review finding #12): a probe whose cost scales with host process count can
# legitimately need longer than 3s, and silently falling through to the
# downstream assertion on exhaustion made a flake read as "wrong resume
# state" instead of "the child never actually died" -- the two have very
# different fixes.
child_cleared=0
for _ in $(seq 1 150); do
  if ! _dispatch_child_live "${dp_dispatch_id[0]}"; then child_cleared=1; break; fi
  sleep 0.1
done
if [ "$child_cleared" -eq 1 ]; then
  _ok "resume ORPHANED_UNOBSERVED fixture: the killed child's process cleared within the poll budget"
else
  _fail "resume ORPHANED_UNOBSERVED fixture: the killed child never cleared within 15s -- cannot meaningfully test ORPHANED_UNOBSERVED (this is a process-teardown flake, not a resume-state bug)"
fi
assert_eq ORPHANED_UNOBSERVED "$(resume_dispatch_state p03-i41-summarizer-spec)" \
  "resume: a started-then-killed dispatch with no completion is ORPHANED_UNOBSERVED"

# 5. FAILED_OBSERVED: completion exists, classification is not COMPLETED.
: > "$FEATURE_FOLDER/RUN_LOG.md"
ROLE_CONTRACTS_PATH="$BUILD/roles-debugger-tiny.tsv" \
  FAKE_MODE=permanent FAKE_MUTATION=none dispatch_attempt 6 42 debugger >/dev/null 2>&1
assert_eq FAILED_OBSERVED "$(resume_dispatch_state p06-i42-debugger)" \
  "resume: a completed-but-not-COMPLETED (vendor failure) dispatch is FAILED_OBSERVED"

# 6. COMPLETED_VALID: completion exists, classification COMPLETED, verdict
# is one of the terminal PASS/READY/DONE values.
: > "$FEATURE_FOLDER/RUN_LOG.md"
FAKE_MODE=complete FAKE_MUTATION=none dispatch_attempt 3 43 summarizer-spec >/dev/null 2>&1
assert_eq COMPLETED_VALID "$(resume_dispatch_state p03-i43-summarizer-spec)" \
  "resume: a completed dispatch with a terminal verdict (DONE) is COMPLETED_VALID"

# 7. COMPLETED_UNACCEPTED: completed and COMPLETED, but the verdict is a
# legal NON-terminal one (e.g. a reviewer's CHANGES_REQUESTED) -- the fake
# CLI's canned STATUS body can't express this, so it is constructed directly
# from the same primitives allocate_attempt/validate_status/RUN_LOG use.
: > "$FEATURE_FOLDER/RUN_LOG.md"
allocate_attempt 3 44 spec-reviewer-claude \
  || _fail "resume COMPLETED_UNACCEPTED fixture: allocate_attempt failed"
cu_logical="$LOGICAL_DISPATCH_ID"; cu_id="$DISPATCH_ID"
cu_dir="$ATTEMPT_DIR"; cu_status="$STATUS_PATH"
: > "$cu_dir/findings.md"
{
  printf 'verdict: CHANGES_REQUESTED\n'
  printf 'reason: needs another pass\n'
  printf 'blockers: 0\n'
  printf 'majors: 1\n'
  printf 'minors: 0\n'
  printf 'findings: findings.md\n'
} > "$cu_status"
validate_status "$cu_status" spec-reviewer-claude >/dev/null 2>&1
assert_rc 0 $? "resume COMPLETED_UNACCEPTED fixture: the hand-built STATUS is itself legal"
{
  printf -- '--- %s  event=DISPATCH_STARTED\n' "$(iso_now)"
  printf 'phase:                    3\n'
  printf 'role:                     spec-reviewer-claude\n'
  printf 'dispatch_id:              %s\n' "$cu_id"
  printf 'logical_dispatch_id:      %s\n' "$cu_logical"
  printf '\n'
  printf -- '--- %s  event=DISPATCH_COMPLETED\n' "$(iso_now)"
  printf 'phase:                    3\n'
  printf 'role:                     spec-reviewer-claude\n'
  printf 'dispatch_id:              %s\n' "$cu_id"
  printf 'logical_dispatch_id:      %s\n' "$cu_logical"
  printf 'status_path:              %s\n' "$cu_status"
  printf 'classification:           COMPLETED\n'
  printf 'verdict:                  CHANGES_REQUESTED\n'
  printf '\n'
} >> "$FEATURE_FOLDER/RUN_LOG.md"
assert_eq COMPLETED_UNACCEPTED "$(resume_dispatch_state "$cu_logical")" \
  "resume: COMPLETED with a legal non-terminal verdict is COMPLETED_UNACCEPTED, not COMPLETED_VALID"

# ============================================================================
# Task 7 review round 2, finding #3: _dispatch_child_live must match the
# WHOLE NUL-record (-x), never a substring -- otherwise a search for
# "DISPATCH_ID=<id>" is satisfied by a sibling "LOGICAL_DISPATCH_ID=<id>"
# environ entry (a real record every dispatched vendor subprocess also
# carries), turning a logical-id liveness check into a guaranteed false
# positive.
# ============================================================================
child_live_marker="clmarker.$$"
env LOGICAL_DISPATCH_ID="$child_live_marker" sleep 5 &
child_live_pid=$!
child_live_seen=0
for _ in $(seq 1 50); do
  pgrep -f "sleep 5" >/dev/null 2>&1 && [ -r "/proc/$child_live_pid/environ" ] && { child_live_seen=1; break; }
  sleep 0.1
done
[ "$child_live_seen" -eq 1 ]   && _ok "child-live substring fixture: a real process carrying LOGICAL_DISPATCH_ID (never DISPATCH_ID) is running"   || _fail "child-live substring fixture: never observed the marker process running"
_dispatch_child_live "$child_live_marker"
assert_rc 1 $?   "a LOGICAL_DISPATCH_ID=<id> environ entry must NOT satisfy a DISPATCH_ID=<id> search (whole-record match, not substring)"
kill -9 "$child_live_pid" 2>/dev/null
wait "$child_live_pid" 2>/dev/null

finish
