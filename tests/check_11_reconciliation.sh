#!/usr/bin/env bash
# Check 11 (Task 15): event-stream and final-proposition reconciliation,
# contradiction, and readiness-audit tests (spec §21, §20.11). Offline; no
# tokens; `tests/run.sh` runs this automatically (only check_90_* is opt-in
# live).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh
# shellcheck source=lib/v2_fixtures.sh
source "$REPO_TOP/tests/lib/v2_fixtures.sh"

load_cookbook || finish

for fn in record_event append_proposition reconcile_propositions audit_run_state \
          _event_proposition_required _run_log_events_json _audit_finding; do
  declare -F "$fn" >/dev/null 2>&1 || _fail "$fn is not defined"
done

init_v2_fixture

# A real, valid runtime manifest -- REQUIRED once, up front, so every
# audit_run_state call below exercises RUNTIME_MANIFEST_INVALID's absence
# for real (a genuinely bootstrapped runtime) rather than always tripping
# it (code review fix, Task 15 round 2, MAJOR 7: an un-bootstrapped fixture
# made every `assert_rc 1` line unfailable -- rc was already 1 from this
# alone, regardless of the clause actually under test).
bootstrap_runtime >/dev/null 2>&1
rc=0; audit_run_state >/dev/null 2>&1 || rc=$?

# A real Phase 1 claude-check-status.md with context7 reachable -- keeps
# CONTEXT7_POLICY_UNRESOLVED out of every OTHER fixture's way (its own
# dedicated fixture below removes this file to exercise the real failure).
mkdir -p "$FEATURE_FOLDER/1-preflight/phase-1"
printf 'verdict: READY\ncontext7: reachable\nreason: null\n' \
  > "$FEATURE_FOLDER/1-preflight/phase-1/claude-check-status.md"

# ---- fixture helpers --------------------------------------------------------

# Fresh, empty RUN_LOG/pending-propositions/audit-findings for one fixture.
# Never touches $ORCHESTRATION_DIR/runtime (the bootstrap above) or the
# Phase 1 status file (both intentionally shared/durable across fixtures).
_t15_reset() {
  : > "$RUN_LOG"
  rm -f "$ORCHESTRATION_DIR/pending-propositions.jsonl" "$ORCHESTRATION_DIR/audit-findings.jsonl"
  rm -f "$ORCHESTRATION_DIR/write-lease.json"
  rm -f "$FEATURE_FOLDER/process-improvement-proposition.md"
  rm -rf "$FEATURE_FOLDER/9-documentation" "$FEATURE_FOLDER/8-all-tests" \
         "$FEATURE_FOLDER/3-spec-review" "$FEATURE_FOLDER/5-plan-review" "$FEATURE_FOLDER/7-code-review" \
         "$FEATURE_FOLDER/followups.jsonl"
}

# The shared "everything else is fine" baseline every clean-audit fixture
# builds on: complete Phase 9 docs and a valid, non-blocking Phase 10
# result. Callers add exactly the ONE thing they want to test on top.
_t15_clean_baseline() {
  mkdir -p "$FEATURE_FOLDER/9-documentation"
  : > "$FEATURE_FOLDER/9-documentation/uat.md"
  : > "$FEATURE_FOLDER/9-documentation/planned-vs-realized.md"
  : > "$FEATURE_FOLDER/9-documentation/documentation-validation.md"
  record_event GIT_FINALIZATION_RESULT phase=10 iteration=00 dispatch_id="" reason=finalized \
    base_sha=deadbeef final_sha=deadbeef staged_paths='[]' commit_sha=null push_performed=no \
    outcome=NO_CHANGES >/dev/null
}

# Records a DISPATCH_STARTED/DISPATCH_COMPLETED pair with sane dummy values
# for every required field -- ARGS: phase iter role dispatch_id logical
# [verdict] [classification] [status_path] [mutation_state] [checkpoint_kind]
# [develop_it_file_sha256]. Returns (via globals) T15_STARTED_ID/T15_COMPLETED_ID.
_t15_dispatch_pair() {
  local phase="$1" iter="$2" role="$3" dispatch_id="$4" logical="$5" \
    verdict="${6:-DONE}" classification="${7:-COMPLETED}" status_path="${8:-}" \
    mutation_state="${9:-NO_SIDE_EFFECTS}" checkpoint_kind="${10:-none}" \
    sha256="${11:-abc123}"
  [ -n "$status_path" ] || status_path="$FEATURE_FOLDER/status-$dispatch_id.md"
  record_event DISPATCH_STARTED phase="$phase" iteration="$iter" dispatch_id="$dispatch_id" \
    reason="t15 fixture start" phase_name=implementation role="$role" vendor=claude \
    logical_dispatch_id="$logical" model=claude-x status_path="$status_path" \
    cwd=/tmp lease=none snapshot=none >/dev/null
  T15_STARTED_ID="$RECORD_EVENT_ID"
  record_event DISPATCH_COMPLETED phase="$phase" iteration="$iter" dispatch_id="$dispatch_id" \
    reason="t15 fixture complete" phase_name=implementation role="$role" vendor=claude \
    appendix="$role" logical_dispatch_id="$logical" develop_it_git_sha=deadbeef \
    develop_it_file_sha256="$sha256" develop_it_dirty=clean status_path="$status_path" \
    verdict="$verdict" classification="$classification" exit_code=0 model=claude-x \
    start_ms=0 end_ms=1 duration_ms=1 stdout_path=/tmp/out stderr_path=/tmp/err \
    mutation_state="$mutation_state" checkpoint_kind="$checkpoint_kind" tokens_input_new=0 \
    tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 \
    cost_usd=n/a usage_status=ok >/dev/null
  T15_COMPLETED_ID="$RECORD_EVENT_ID"
}

# True iff audit-findings.jsonl carries a line with the given check code
# whose record_ids array contains EXACTLY the given token. -s (slurp) +
# any(): jq -e WITHOUT -s bases its exit code on only the LAST value a
# multi-line filter emits, so with several findings sharing $check a
# per-line exit code would silently ignore a true match on an earlier row.
_t15_finding_has() {
  local check="$1" id_token="$2" file="${3:-$ORCHESTRATION_DIR/audit-findings.jsonl}"
  [ -f "$file" ] || return 1
  jq -e -s --arg c "$check" --arg id "$id_token" \
    'any(.[]; .check==$c and (.record_ids | index($id) != null))' "$file" >/dev/null 2>&1
}
_t15_no_finding() {
  local check="$1" file="${2:-$ORCHESTRATION_DIR/audit-findings.jsonl}"
  [ -f "$file" ] || return 0
  ! jq -e --arg c "$check" 'select(.check==$c)' "$file" >/dev/null 2>&1
}
# True iff NO finding of ANY check code references this exact id token --
# unlike _t15_no_finding (which needs a real check CODE), this is the right
# tool for "this event_id is fully clean, whatever a bug might mislabel it
# as" (MAJOR fix, Task 15 round 2: the previous test passed an EVENT TYPE
# where a check CODE belongs, which is not, and can never become, a real
# code emitted anywhere -- tautologically true).
_t15_no_finding_for_id() {
  local id_token="$1" file="${2:-$ORCHESTRATION_DIR/audit-findings.jsonl}"
  [ -f "$file" ] || return 0
  ! jq -e -s --arg id "$id_token" 'any(.[]; .record_ids | index($id) != null)' \
    "$file" >/dev/null 2>&1
}

# =============================================================================
# BLOCKER 1 pin: an ordinary run containing one authorized retry reaches a
# CLEAN audit (rc=0, empty audit-findings.jsonl) -- this is the exact
# scenario that was unreachable before record_event auto-fulfilled every
# proposition_required=yes header: ATTEMPT_FAILED and RECOVERY_AUTHORIZED
# both fire here, and nothing else ever completed their proposition.
# =============================================================================
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  FAILED TRANSIENT_TRANSPORT_ERROR "" NO_SIDE_EFFECTS
record_event ATTEMPT_FAILED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="transient transport error on first attempt" phase_name=implementation role=implementer \
  classification=TRANSIENT_TRANSPORT_ERROR >/dev/null
record_event RECOVERY_AUTHORIZED logical_dispatch_id=p06-i00-implementer action=TRANSIENT_RETRY \
  reason="retry authorized under transient_retry_cap (0/1 used)" >/dev/null
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a02 p06-i00-implementer \
  DONE COMPLETED
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 0 "$rc" "BLOCKER1: an ordinary run with one authorized retry (ATTEMPT_FAILED + RECOVERY_AUTHORIZED, both auto-fulfilled) reaches a clean audit"
assert_eq "" "$(cat "$ORCHESTRATION_DIR/audit-findings.jsonl" 2>/dev/null)" \
  "BLOCKER1: audit-findings.jsonl is EMPTY for this ordinary run -- READY is reachable"

# =============================================================================
# append_proposition: direct behavior (auto-fulfillment is record_event's
# job now, so these test append_proposition's OWN validation paths, not
# the "orchestrator manually fulfils" path that no longer exists).
# =============================================================================
_t15_reset
record_event HALT reason="t15 append_proposition direct-behavior fixture" >/dev/null
_t15_halt_id="$RECORD_EVENT_ID"
assert_exists "$FEATURE_FOLDER/process-improvement-proposition.md" \
  "append_proposition: record_event's own auto-fulfillment already created process-improvement-proposition.md"
assert_contains "trigger: HALT" "$FEATURE_FOLDER/process-improvement-proposition.md" \
  "append_proposition: the auto-written entry carries the trigger tag"

rc=0; append_proposition 999999999 failure "no such event" 2>/dev/null || rc=$?
assert_rc 1 "$rc" "append_proposition rejects an event_id with no pending header"

rc=0; append_proposition "$_t15_halt_id" success "wrong kind" 2>"$BUILD/t15-kindmismatch.err" || rc=$?
assert_rc 1 "$rc" "append_proposition rejects a KIND that disagrees with the header's own auto-recorded kind"
assert_contains "APPEND_PROPOSITION_KIND_MISMATCH" "$BUILD/t15-kindmismatch.err" \
  "the kind-mismatch failure names itself"

rc=0; append_proposition "$_t15_halt_id" failure "a second, manual fulfillment" >/dev/null 2>&1 || rc=$?
assert_rc 0 "$rc" "append_proposition itself does not refuse re-fulfilling an already-fulfilled event_id"
reconcile_propositions >/dev/null 2>&1
assert_eq yes "$(_t15_finding_has DUPLICATE_PROPOSITION_COVERAGE "event_id:$_t15_halt_id" && echo yes || echo no)" \
  "...but reconcile_propositions catches the resulting duplicate coverage -- this is why nothing may call append_proposition manually for an auto-fulfilled type"

# =============================================================================
# 1. Missing / duplicate proposition header
# =============================================================================
_t15_reset
record_event RECOVERY_CAP_REACHED logical_dispatch_id=p06-i00-implementer \
  cap=continuation_cap cap_value=3 attempts_used=4 reason="t15 missing-header fixture" >/dev/null
_t15_rcr_id="$RECORD_EVENT_ID"
jq -c --argjson id "$_t15_rcr_id" 'select(.event_id != $id)' \
  "$ORCHESTRATION_DIR/pending-propositions.jsonl" > "$BUILD/t15-pending.tmp" 2>/dev/null
mv "$BUILD/t15-pending.tmp" "$ORCHESTRATION_DIR/pending-propositions.jsonl"
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "1a: reconcile_propositions fails when a mandatory event has NO proposition header"
assert_eq yes "$(_t15_finding_has MANDATORY_EVENT_WITHOUT_HEADER "event_id:$_t15_rcr_id" && echo yes || echo no)" \
  "1a: the finding names the exact missing event_id"

_t15_reset
record_event RECOVERY_CAP_REACHED logical_dispatch_id=p06-i00-implementer \
  cap=continuation_cap cap_value=3 attempts_used=4 reason="t15 duplicate-header fixture" >/dev/null
_t15_rcr_id2="$RECORD_EVENT_ID"
write_pending_proposition_header "$ORCHESTRATION_DIR/pending-propositions.jsonl" \
  "$_t15_rcr_id2" 6 failure RECOVERY_CAP_REACHED
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "1b: reconcile_propositions fails when a mandatory event has MORE THAN ONE proposition header"
assert_eq yes "$(_t15_finding_has DUPLICATE_PROPOSITION_HEADER "event_id:$_t15_rcr_id2" && echo yes || echo no)" \
  "1b: the finding names the exact duplicated event_id"

# =============================================================================
# 2. Proposition without real trigger (header names an event RUN_LOG never
#    recorded)
# =============================================================================
_t15_reset
write_pending_proposition_header "$ORCHESTRATION_DIR/pending-propositions.jsonl" \
  999999 6 failure ATTEMPT_FAILED
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "2: reconcile_propositions fails when a header names an event_id RUN_LOG never recorded"
assert_eq yes "$(_t15_finding_has PROPOSITION_HEADER_WITHOUT_EVENT "event_id:999999" && echo yes || echo no)" \
  "2: the finding names the exact phantom event_id"

# =============================================================================
# 3. DISPATCH_NOT_LAUNCHED mislabeled as launched vendor failure
# =============================================================================
_t15_reset
record_event DISPATCH_NOT_LAUNCHED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="prelaunch defect" phase_name=implementation role=implementer \
  logical_dispatch_id=p06-i00-implementer >/dev/null
_t15_dnl_id="$RECORD_EVENT_ID"
write_pending_proposition_header "$ORCHESTRATION_DIR/pending-propositions.jsonl" \
  "$_t15_dnl_id" 6 failure ATTEMPT_FAILED
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "3: reconcile_propositions fails when a proposition claims a launched vendor failure for a DISPATCH_NOT_LAUNCHED event"
assert_eq yes "$(_t15_finding_has PRELAUNCH_MISLABELED_AS_VENDOR_FAILURE "event_id:$_t15_dnl_id" && echo yes || echo no)" \
  "3: the finding names the exact mislabeled event_id"

# =============================================================================
# 4. Unauthorized retry/continuation (no causal RECOVERY_AUTHORIZED)
# =============================================================================
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer FAILED PERMANENT_VENDOR_ERROR
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a02 \
  reason="unauthorized retry" phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=claude-x status_path=/tmp/s2.md \
  cwd=/tmp lease=none snapshot=none >/dev/null
_t15_retry_started_id="$RECORD_EVENT_ID"
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "4: reconcile_propositions fails when a continuation attempt has no causal RECOVERY_AUTHORIZED"
assert_eq yes "$(_t15_finding_has RETRY_WITHOUT_RECOVERY_AUTHORIZED "event_id:$_t15_retry_started_id" && echo yes || echo no)" \
  "4: the finding names the exact unauthorized retry's own event_id"

# Positive control: the SAME shape, but with a causal RECOVERY_AUTHORIZED
# recorded first, must NOT trip this rule.
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer FAILED PERMANENT_VENDOR_ERROR
record_event RECOVERY_AUTHORIZED logical_dispatch_id=p06-i00-implementer action=HALT_OR_DEGRADE \
  reason="t15 authorized retry" >/dev/null
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a02 \
  reason="authorized retry" phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=claude-x status_path=/tmp/s3.md \
  cwd=/tmp lease=none snapshot=none >/dev/null
_t15_retry2_started_id="$RECORD_EVENT_ID"
reconcile_propositions >/dev/null 2>&1
assert_eq no "$(_t15_finding_has RETRY_WITHOUT_RECOVERY_AUTHORIZED "event_id:$_t15_retry2_started_id" && echo yes || echo no)" \
  "4 (positive control): a retry preceded by a causal RECOVERY_AUTHORIZED is NOT flagged"

# Negative control: RECOVERY_AUTHORIZED must be CAUSAL (strictly BEFORE the
# retry's own DISPATCH_STARTED event_id) -- one recorded AFTER the retry it
# supposedly justifies must still be flagged.
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer FAILED PERMANENT_VENDOR_ERROR
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a02 \
  reason="retry BEFORE any authorization exists" phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=claude-x status_path=/tmp/s6.md \
  cwd=/tmp lease=none snapshot=none >/dev/null
_t15_retry3_started_id="$RECORD_EVENT_ID"
record_event RECOVERY_AUTHORIZED logical_dispatch_id=p06-i00-implementer action=HALT_OR_DEGRADE \
  reason="t15 authorization recorded AFTER the retry it cannot justify" >/dev/null
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "4 (negative control): a RECOVERY_AUTHORIZED recorded AFTER the retry it supposedly authorizes does not satisfy the rule"
assert_eq yes "$(_t15_finding_has RETRY_WITHOUT_RECOVERY_AUTHORIZED "event_id:$_t15_retry3_started_id" && echo yes || echo no)" \
  "4 (negative control): the finding still names the retry's own event_id despite the later, non-causal authorization"

# =============================================================================
# 5. Duplicate / missing dispatch completion block
# =============================================================================
_t15_reset
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 missing-completion fixture" phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=claude-x status_path=/tmp/s4.md \
  cwd=/tmp lease=none snapshot=none >/dev/null
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "5a: reconcile_propositions fails when a started dispatch has NO completion record"
assert_eq yes "$(_t15_finding_has DISPATCH_COMPLETION_MISSING "dispatch_id:p06-i00-implementer-a01" && echo yes || echo no)" \
  "5a: the finding names the exact dispatch_id with a missing completion"
# The SAME fixture also leaves the logical dispatch un-quiesced (a durable
# start with no completion and no live child) -- audit_run_state's own
# DISPATCH_NOT_QUIESCED clause.
mkdir -p "$FEATURE_FOLDER/9-documentation"
: > "$FEATURE_FOLDER/9-documentation/uat.md"
: > "$FEATURE_FOLDER/9-documentation/planned-vs-realized.md"
: > "$FEATURE_FOLDER/9-documentation/documentation-validation.md"
record_event GIT_FINALIZATION_RESULT phase=10 iteration=00 dispatch_id="" reason=finalized \
  base_sha=deadbeef final_sha=deadbeef staged_paths='[]' commit_sha=null push_performed=no \
  outcome=NO_CHANGES >/dev/null
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "5a (audit_run_state): fails on the same un-quiesced dispatch"
assert_eq yes "$(_t15_finding_has DISPATCH_NOT_QUIESCED "logical_dispatch_id:p06-i00-implementer" && echo yes || echo no)" \
  "5a (audit_run_state): DISPATCH_NOT_QUIESCED names the exact logical_dispatch_id"

_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer DONE COMPLETED
record_event DISPATCH_COMPLETED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 duplicate-completion fixture" phase_name=implementation role=implementer vendor=claude \
  appendix=implementer logical_dispatch_id=p06-i00-implementer develop_it_git_sha=deadbeef \
  develop_it_file_sha256=abc123 develop_it_dirty=clean status_path=/tmp/s5.md \
  verdict=DONE classification=COMPLETED exit_code=0 model=claude-x \
  start_ms=0 end_ms=1 duration_ms=1 stdout_path=/tmp/out stderr_path=/tmp/err \
  mutation_state=NO_SIDE_EFFECTS checkpoint_kind=none tokens_input_new=0 \
  tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 \
  cost_usd=n/a usage_status=ok >/dev/null
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "5b: reconcile_propositions fails when a dispatch has MORE THAN ONE completion record"
assert_eq yes "$(_t15_finding_has DISPATCH_COMPLETION_DUPLICATE "dispatch_id:p06-i00-implementer-a01" && echo yes || echo no)" \
  "5b: the finding names the exact dispatch_id with duplicate completions"

# =============================================================================
# 6. §21.2 case 6: EVENT_CORRECTED.replacement_classification not reflected
#    in what actually happened next (real classification check, not mere
#    fulfillment coverage).
# =============================================================================
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  FAILED PERMANENT_VENDOR_ERROR "" NO_SIDE_EFFECTS
record_event ATTEMPT_FAILED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 correction target" phase_name=implementation role=implementer \
  classification=PERMANENT_VENDOR_ERROR >/dev/null
_t15_af_id="$RECORD_EVENT_ID"
# Correct it to TRANSIENT_TRANSPORT_ERROR -- recovery_action(TRANSIENT_
# TRANSPORT_ERROR, NO_SIDE_EFFECTS) is RM05/TRANSIENT_RETRY, which implies
# a continuation SHOULD follow. None does.
record_event EVENT_CORRECTED corrected_event_id="$_t15_af_id" \
  replacement_classification=TRANSIENT_TRANSPORT_ERROR evidence="retro-classified as transient" \
  downstream_effect=none reason="t15 correction implying an unfollowed retry" >/dev/null
_t15_ec_id="$RECORD_EVENT_ID"
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "6a: reconcile_propositions fails when a correction implies a continuation that never happened"
assert_eq yes "$(_t15_finding_has EVENT_CORRECTION_NOT_REFLECTED "corrected_event_id:$_t15_af_id" && echo yes || echo no)" \
  "6a: the finding names the exact corrected event_id"

# 6b: the SAME correction, but this time the implied continuation DID
# happen -- must NOT be flagged.
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  FAILED PERMANENT_VENDOR_ERROR "" NO_SIDE_EFFECTS
record_event ATTEMPT_FAILED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 correction target (reflected)" phase_name=implementation role=implementer \
  classification=PERMANENT_VENDOR_ERROR >/dev/null
_t15_af_id2="$RECORD_EVENT_ID"
record_event EVENT_CORRECTED corrected_event_id="$_t15_af_id2" \
  replacement_classification=TRANSIENT_TRANSPORT_ERROR evidence="retro-classified as transient" \
  downstream_effect=none reason="t15 correction that IS reflected" >/dev/null
_t15_ec_id2="$RECORD_EVENT_ID"
record_event RECOVERY_AUTHORIZED logical_dispatch_id=p06-i00-implementer action=TRANSIENT_RETRY \
  reason="t15 authorized continuation reflecting the correction" >/dev/null
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a02 \
  reason="the reflected continuation" phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=claude-x status_path=/tmp/s7.md \
  cwd=/tmp lease=none snapshot=none >/dev/null
reconcile_propositions >/dev/null 2>&1
assert_eq no "$(_t15_finding_has EVENT_CORRECTION_NOT_REFLECTED "corrected_event_id:$_t15_af_id2" && echo yes || echo no)" \
  "6b: a correction whose implied continuation DID happen is NOT flagged"

# 6c: the reverse direction -- a correction implying NO further attempt
# (HALT_OR_DEGRADE), but a later attempt was dispatched anyway.
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  FAILED TRANSIENT_TRANSPORT_ERROR "" NO_SIDE_EFFECTS
record_event ATTEMPT_FAILED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 correction target (halt-implied)" phase_name=implementation role=implementer \
  classification=TRANSIENT_TRANSPORT_ERROR >/dev/null
_t15_af_id3="$RECORD_EVENT_ID"
record_event EVENT_CORRECTED corrected_event_id="$_t15_af_id3" \
  replacement_classification=PERMANENT_VENDOR_ERROR evidence="retro-classified as permanent" \
  downstream_effect=none reason="t15 correction implying no further attempt" >/dev/null
_t15_ec_id3="$RECORD_EVENT_ID"
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a02 \
  reason="an attempt that should never have been dispatched" phase_name=implementation \
  role=implementer vendor=claude logical_dispatch_id=p06-i00-implementer model=claude-x \
  status_path=/tmp/s8.md cwd=/tmp lease=none snapshot=none >/dev/null
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "6c: reconcile_propositions fails when a halt-implying correction was followed by a further attempt anyway"
assert_eq yes "$(_t15_finding_has EVENT_CORRECTION_NOT_REFLECTED "corrected_event_id:$_t15_af_id3" && echo yes || echo no)" \
  "6c: the finding names the exact corrected event_id"

# 6d: fault isolation (code review fix) -- a malformed EVENT_CORRECTED (a
# non-numeric corrected_event_id, simulating hand-corrupted RUN_LOG data)
# must NOT abort the single-pass jq rule and silently swallow every OTHER
# finding queued behind it. Recorded FIRST (RUN_LOG is append-only, so file
# order is chronological) -- the exact ordering that reproduced a real bug:
# jq's fatal "startswith()/tonumber requires string inputs" error on this
# record aborted the WHOLE jq invocation with zero stdout, so
# reconcile_propositions previously reported a CLEAN audit (rc=0, no
# findings at all) even though the well-formed violation below is real.
_t15_reset
record_event EVENT_CORRECTED corrected_event_id="not-a-real-event-id" \
  replacement_classification=TRANSIENT_TRANSPORT_ERROR evidence="hand-corrupted fixture" \
  downstream_effect=none reason="t15 malformed correction -- must not abort the pass" >/dev/null
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  FAILED PERMANENT_VENDOR_ERROR "" NO_SIDE_EFFECTS
record_event ATTEMPT_FAILED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 correction target (behind a malformed record)" phase_name=implementation \
  role=implementer classification=PERMANENT_VENDOR_ERROR >/dev/null
_t15_af_id4="$RECORD_EVENT_ID"
record_event EVENT_CORRECTED corrected_event_id="$_t15_af_id4" \
  replacement_classification=TRANSIENT_TRANSPORT_ERROR evidence="retro-classified as transient" \
  downstream_effect=none reason="t15 correction implying an unfollowed retry, behind a malformed record" >/dev/null
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "6d: a malformed EVENT_CORRECTED earlier in the stream does not mask a real, later violation"
assert_eq yes "$(_t15_finding_has EVENT_CORRECTION_NOT_REFLECTED "corrected_event_id:$_t15_af_id4" && echo yes || echo no)" \
  "6d: the well-formed violation is still reported despite the earlier malformed record"

# =============================================================================
# 7. A lost/interrupted fulfillment (PROPOSITION_NOT_FULFILLED) -- record_
#    event auto-fulfills every mandatory header immediately, so this
#    simulates the ONE way a header can still end up unfulfilled: the
#    fulfillment record itself was lost after the fact (e.g. a crash
#    between the two appends append_proposition itself makes).
# =============================================================================
_t15_reset
record_event VENDOR_UNAVAILABLE logical_dispatch_id=p06-i00-implementer vendor=claude \
  reason="t15 lost-fulfillment fixture" >/dev/null
_t15_vu_id="$RECORD_EVENT_ID"
jq -c --argjson id "$_t15_vu_id" 'select(.event_id != $id or (has("fulfilled_at")|not))' \
  "$ORCHESTRATION_DIR/pending-propositions.jsonl" > "$BUILD/t15-lost.tmp"
mv "$BUILD/t15-lost.tmp" "$ORCHESTRATION_DIR/pending-propositions.jsonl"
rc=0; reconcile_propositions || rc=$?
assert_rc 1 "$rc" "7: reconcile_propositions fails when a mandatory event's own fulfillment record was lost"
assert_eq yes "$(_t15_finding_has PROPOSITION_NOT_FULFILLED "event_id:$_t15_vu_id" && echo yes || echo no)" \
  "7: the finding names the exact unfulfilled event_id"

# =============================================================================
# 8. Accepted revision mismatch / accepted output missing (PHASE_ACCEPTED)
# =============================================================================
_t15_reset
_t15_status_path="$FEATURE_FOLDER/status-accepted.md"
printf 'verdict: DONE\nartifact_revision: real-sha-111\nreason: null\n' > "$_t15_status_path"
_t15_dispatch_pair 5 00 plan-writer p05-i00-plan-writer-a01 p05-i00-plan-writer DONE COMPLETED "$_t15_status_path"
record_event PHASE_ACCEPTED decision_id=t15-decision-1 authority_identity=operator \
  scope=phase=5 artifact_path="$FEATURE_FOLDER/4-plan-writing/plan.md" artifact_revision=different-sha-222 \
  evidence="t15 fixture" alternatives_rejected=none residual_risk=none expiry="this run" \
  independent_rereview=false follow_up_id=null \
  dispatch_id=p05-i00-plan-writer-a01 reason="t15 accepted-revision-mismatch fixture" >/dev/null
_t15_pa_id="$RECORD_EVENT_ID"
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "8a: audit_run_state fails when a PHASE_ACCEPTED artifact_revision differs from the accepted dispatch's own STATUS"
assert_eq yes "$(_t15_finding_has PHASE_ACCEPTED_REVISION_MISMATCH "event_id:$_t15_pa_id" && echo yes || echo no)" \
  "8a: the finding names the exact mismatched PHASE_ACCEPTED event_id"

# 8b: MAJOR fix (Task 15 round 2) -- "every accepted output EXISTS" leg.
# The DISPATCH_COMPLETED's own status_path points at a file that was never
# written; the OLD code silently `continue`d past this.
_t15_reset
_t15_dispatch_pair 5 00 plan-writer p05-i00-plan-writer-a01 p05-i00-plan-writer \
  DONE COMPLETED "$FEATURE_FOLDER/status-does-not-exist.md"
record_event PHASE_ACCEPTED decision_id=t15-decision-2 authority_identity=operator \
  scope=phase=5 artifact_path="$FEATURE_FOLDER/4-plan-writing/plan.md" artifact_revision=whatever \
  evidence="t15 fixture" alternatives_rejected=none residual_risk=none expiry="this run" \
  independent_rereview=false follow_up_id=null \
  dispatch_id=p05-i00-plan-writer-a01 reason="t15 accepted-output-missing fixture" >/dev/null
_t15_pa_id2="$RECORD_EVENT_ID"
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "8b: audit_run_state fails when an accepted dispatch's own STATUS file does not exist"
assert_eq yes "$(_t15_finding_has ACCEPTED_OUTPUT_MISSING "event_id:$_t15_pa_id2" && echo yes || echo no)" \
  "8b: the finding names the exact PHASE_ACCEPTED event_id whose output is missing"

# =============================================================================
# 9. Missing documentation
# =============================================================================
_t15_reset
record_event GIT_FINALIZATION_RESULT phase=10 iteration=00 dispatch_id="" reason=finalized \
  base_sha=deadbeef final_sha=deadbeef staged_paths='[]' commit_sha=null push_performed=no \
  outcome=NO_CHANGES >/dev/null
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "9: audit_run_state fails when required documentation outputs are missing"
for _t15_doc in uat.md planned-vs-realized.md documentation-validation.md; do
  assert_eq yes "$(_t15_finding_has DOCUMENTATION_OUTPUT_MISSING "9-documentation/$_t15_doc" && echo yes || echo no)" \
    "9: the finding names the exact missing path 9-documentation/$_t15_doc"
done

# =============================================================================
# 10. Remaining lease
# =============================================================================
_t15_reset
_t15_clean_baseline
write_fake_lease "$ORCHESTRATION_DIR/write-lease.json" p06-i00-implementer-a01 debugger role
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "10: audit_run_state fails when a write lease remains at readiness time"
assert_eq yes "$(_t15_finding_has WRITE_LEASE_REMAINS "lease_owner:debugger" && echo yes || echo no)" \
  "10: the finding names the exact lease owner"
rm -f "$ORCHESTRATION_DIR/write-lease.json"

# =============================================================================
# 11. Degraded coverage (an auto-fulfilled degradation must not itself
#     blank the audit -- it downgrades the Phase 11 VERDICT, not the audit)
# =============================================================================
_t15_reset
_t15_clean_baseline
record_event DEGRADED_REVIEW_ACCEPTED phase=7 iteration=00 decision_id=p7-degraded-t15 \
  scope="phase=7;iteration=00" evidence="codex_unavailable failure_mode=1" \
  reason="t15 degraded coverage fixture" >/dev/null
_t15_dra_id="$RECORD_EVENT_ID"
rc=0; audit_run_state || rc=$?
assert_rc 0 "$rc" "11: an accepted, auto-fulfilled DEGRADED_REVIEW_ACCEPTED produces a CLEAN audit"
assert_eq yes "$(_t15_no_finding_for_id "event_id:$_t15_dra_id" && echo yes || echo no)" \
  "11: the degraded-coverage event's own event_id appears in NO finding at all"

# =============================================================================
# 12. Valid exclusion
# =============================================================================
_t15_reset
_t15_clean_baseline
mkdir -p "$FEATURE_FOLDER/8-all-tests/00"
jq -cn '{verification_id:"v1", command:"pytest tests/unrelated.py", environment:"local",
  result:"EXCLUDED", exit_code:null, evidence_path:"ev.txt",
  baseline_comparison:"baseline-2026-01-01.json",
  reason:"pre-existing failure, unrelated to this change", followup_id:null,
  exclusion_class:"pre_existing"}' \
  > "$FEATURE_FOLDER/8-all-tests/00/verification-records.jsonl"
rc=0; audit_run_state || rc=$?
assert_rc 0 "$rc" "12: a valid EXCLUDED verification record produces a CLEAN audit"
assert_eq yes "$(_t15_no_finding VERIFICATION_NOT_PASS && echo yes || echo no)" \
  "12: a valid EXCLUDED verification record is never reported as VERIFICATION_NOT_PASS"

# 12b (negative control): a REAL FAIL result must be caught -- proves the
# VERIFICATION_NOT_PASS scan is load-bearing, not merely satisfied by
# EXCLUDED evidence it never actually inspects.
_t15_reset
_t15_clean_baseline
mkdir -p "$FEATURE_FOLDER/8-all-tests/00"
jq -cn '{verification_id:"v2", command:"pytest tests/test_widget.py", environment:"local",
  result:"FAIL", exit_code:1, evidence_path:null, baseline_comparison:null,
  reason:"genuine regression", followup_id:null, exclusion_class:null}' \
  > "$FEATURE_FOLDER/8-all-tests/00/verification-records.jsonl"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "12b: audit_run_state fails when a verification record's latest result is a real FAIL"
assert_eq yes "$(_t15_finding_has VERIFICATION_NOT_PASS "verification_id:v2" && echo yes || echo no)" \
  "12b: the finding names the exact failing verification_id"

# =============================================================================
# 13. Phase 10 NO_CHANGES / 14. Phase 10 COMMITTED
# =============================================================================
_t15_reset
mkdir -p "$FEATURE_FOLDER/9-documentation"
: > "$FEATURE_FOLDER/9-documentation/uat.md"
: > "$FEATURE_FOLDER/9-documentation/planned-vs-realized.md"
: > "$FEATURE_FOLDER/9-documentation/documentation-validation.md"
record_event GIT_FINALIZATION_RESULT phase=10 iteration=00 dispatch_id="" reason=no-in-scope-changes \
  base_sha=deadbeef final_sha=deadbeef staged_paths='[]' commit_sha=null push_performed=no \
  outcome=NO_CHANGES >/dev/null
rc=0; audit_run_state || rc=$?
assert_rc 0 "$rc" "13: Phase 10 NO_CHANGES on an otherwise-clean run produces a CLEAN audit"

_t15_reset
mkdir -p "$FEATURE_FOLDER/9-documentation"
: > "$FEATURE_FOLDER/9-documentation/uat.md"
: > "$FEATURE_FOLDER/9-documentation/planned-vs-realized.md"
: > "$FEATURE_FOLDER/9-documentation/documentation-validation.md"
record_event GIT_FINALIZATION_RESULT phase=10 iteration=00 dispatch_id="" reason=finalized \
  base_sha=deadbeef final_sha=cafef00d staged_paths='["9-documentation/uat.md"]' \
  commit_sha=cafef00d push_performed=no outcome=COMMITTED >/dev/null
rc=0; audit_run_state || rc=$?
assert_rc 0 "$rc" "14: Phase 10 COMMITTED on an otherwise-clean run produces a CLEAN audit"

# Negative controls: a MISSING GIT_FINALIZATION_RESULT (Phase 10 never ran)
# and a FAILED outcome both block readiness.
_t15_reset
_t15_clean_baseline_docs_only() {
  mkdir -p "$FEATURE_FOLDER/9-documentation"
  : > "$FEATURE_FOLDER/9-documentation/uat.md"
  : > "$FEATURE_FOLDER/9-documentation/planned-vs-realized.md"
  : > "$FEATURE_FOLDER/9-documentation/documentation-validation.md"
}
_t15_clean_baseline_docs_only
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "negative control: audit_run_state fails when no GIT_FINALIZATION_RESULT is durable at all"
assert_eq yes "$(_t15_no_finding GIT_FINALIZATION_MISSING && echo no || echo yes)" \
  "negative control: the finding is GIT_FINALIZATION_MISSING"

_t15_reset
_t15_clean_baseline_docs_only
record_event GIT_FINALIZATION_RESULT phase=10 iteration=00 dispatch_id="" reason=commit-hook-failed \
  base_sha=deadbeef final_sha=deadbeef staged_paths='["9-documentation/uat.md"]' commit_sha=null \
  push_performed=no outcome=FAILED >/dev/null
_t15_gfr_id="$RECORD_EVENT_ID"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "negative control: audit_run_state fails when Phase 10's outcome is FAILED"
assert_eq yes "$(_t15_finding_has GIT_FINALIZATION_FAILED "event_id:$_t15_gfr_id" && echo yes || echo no)" \
  "negative control: the finding names the exact FAILED GIT_FINALIZATION_RESULT event_id"

# =============================================================================
# 15. Runtime manifest tampered after bootstrap
# =============================================================================
_t15_reset
_t15_clean_baseline
sed -i 's/^process_document_sha256=.*/process_document_sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "$RUNTIME_DIR/manifest.sha256"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "15: audit_run_state fails when the runtime manifest has been tampered with"
assert_eq yes "$(_t15_no_finding RUNTIME_MANIFEST_INVALID && echo no || echo yes)" \
  "15: the finding is RUNTIME_MANIFEST_INVALID"
bootstrap_runtime >/dev/null 2>&1   # restore for every fixture after this one

# =============================================================================
# 16. Process identity mismatch across dispatches
# =============================================================================
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  DONE COMPLETED "" NO_SIDE_EFFECTS none sha-one
_t15_id_a="$T15_COMPLETED_ID"
_t15_dispatch_pair 6 00 implementer p06-i01-implementer-a01 p06-i01-implementer \
  DONE COMPLETED "" NO_SIDE_EFFECTS none sha-two
_t15_id_b="$T15_COMPLETED_ID"
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "16: audit_run_state fails when two dispatches disagree on develop_it_file_sha256"
assert_eq yes "$(_t15_finding_has PROCESS_IDENTITY_MISMATCH "event_id:$_t15_id_a" && echo yes || echo no)" \
  "16: the finding names the first conflicting event_id"
assert_eq yes "$(_t15_finding_has PROCESS_IDENTITY_MISMATCH "event_id:$_t15_id_b" && echo yes || echo no)" \
  "16: the finding names the second conflicting event_id"

# =============================================================================
# 17. Followups invalid
# =============================================================================
_t15_reset
_t15_clean_baseline
printf '{"id":"fu-bad","origin_phase":9}\n' > "$FEATURE_FOLDER/followups.jsonl"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "17: audit_run_state fails on a malformed followups.jsonl record"
assert_eq yes "$(_t15_finding_has FOLLOWUP_INVALID "id:fu-bad" && echo yes || echo no)" \
  "17: the finding names the exact malformed record id"
rm -f "$FEATURE_FOLDER/followups.jsonl"

# =============================================================================
# 18. context7 policy unresolved
# =============================================================================
_t15_reset
_t15_clean_baseline
rm -f "$FEATURE_FOLDER/1-preflight/phase-1/claude-check-status.md"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "18: audit_run_state fails when context7_policy cannot resolve (no Phase 1 STATUS, no RUN_LOG event)"
assert_eq yes "$(_t15_no_finding CONTEXT7_POLICY_UNRESOLVED && echo no || echo yes)" \
  "18: the finding is CONTEXT7_POLICY_UNRESOLVED"
# Round 3 fix: record_ids must name the concrete missing artifact, never a
# bare phase label ("phase:1" was not a record id -- the same class of gap
# already fixed for WRITE_LEASE_REMAINS/PROCESS_IDENTITY_MISMATCH).
assert_eq yes "$(_t15_finding_has CONTEXT7_POLICY_UNRESOLVED "1-preflight/phase-1/claude-check-status.md" && echo yes || echo no)" \
  "18: the finding names the exact missing Phase 1 status path, not a bare phase label"
mkdir -p "$FEATURE_FOLDER/1-preflight/phase-1"
printf 'verdict: READY\ncontext7: reachable\nreason: null\n' \
  > "$FEATURE_FOLDER/1-preflight/phase-1/claude-check-status.md"

# =============================================================================
# 22. Review cap causal ordering + phase-agnostic HALT (round 3 pin)
# =============================================================================
# 22a negative-order: an ITERATION_CAP_OVERRIDE recorded BEFORE the cap it
# supposedly authorizes must NOT satisfy the rule -- the exact "authorized
# strictly before" discipline already pinned for RECOVERY_AUTHORIZED,
# now pinned for REVIEW_CAP_NOT_RESPECTED too.
_t15_reset
_t15_clean_baseline
record_event ITERATION_CAP_OVERRIDE phase_name=code-review iteration_cap=10 \
  reason="t15 override recorded BEFORE the cap it cannot justify" >/dev/null
record_event ITERATION_CAP_REACHED phase_name=code-review iteration_cap=10 \
  reason="t15 cap reached AFTER a stale override" >/dev/null
_t15_cap_id3="$RECORD_EVENT_ID"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "22a: audit_run_state fails when the only ITERATION_CAP_OVERRIDE for a cap was recorded BEFORE that cap"
assert_eq yes "$(_t15_finding_has REVIEW_CAP_NOT_RESPECTED "event_id:$_t15_cap_id3" && echo yes || echo no)" \
  "22a: the finding names the exact cap-reached event_id despite the earlier, non-causal override"

# 22b positive control: intended semantics are PHASE-AGNOSTIC HALT -- any
# later HALT (the whole run stopped) authorizes any phase's own cap, not
# just a same-phase one. Pinned explicitly so a future same-phase
# tightening is a deliberate choice, not a silent regression.
_t15_reset
_t15_clean_baseline
record_event ITERATION_CAP_REACHED phase_name=plan-review iteration_cap=10 \
  reason="t15 cap reached in a different phase than the HALT below" >/dev/null
_t15_cap_id4="$RECORD_EVENT_ID"
record_event HALT reason="t15 phase-agnostic HALT authorizing any phase's cap" >/dev/null
rc=0; audit_run_state || rc=$?
assert_eq yes "$(_t15_no_finding_for_id "event_id:$_t15_cap_id4" && echo yes || echo no)" \
  "22b: a later HALT in a DIFFERENT phase still satisfies the cap -- phase-agnostic by design"

# =============================================================================
# 19. Attempt not classified
# =============================================================================
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  DONE BOGUS_NOT_A_REAL_CLASSIFICATION
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "19: audit_run_state fails when a DISPATCH_COMPLETED carries an illegal classification"
assert_eq yes "$(_t15_finding_has ATTEMPT_NOT_CLASSIFIED "event_id:$T15_COMPLETED_ID" && echo yes || echo no)" \
  "19: the finding names the exact unclassified dispatch's event_id"

# =============================================================================
# 20. Checkpoint malformed / snapshot missing
# =============================================================================
_t15_reset
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer \
  DONE COMPLETED "" NO_SIDE_EFFECTS common_v2
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "20a: audit_run_state fails when a checkpointed dispatch's own progress.jsonl does not exist"
assert_eq yes "$(_t15_finding_has CHECKPOINT_MALFORMED "event_id:$T15_COMPLETED_ID" && echo yes || echo no)" \
  "20a: the finding names the exact dispatch's event_id"

_t15_reset
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id=p06-i00-implementer-a01 \
  reason="t15 snapshot-missing fixture" phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=claude-x status_path=/tmp/s9.md \
  cwd=/tmp lease=none snapshot="$ORCHESTRATION_DIR/snapshots/does-not-exist/manifest.json" >/dev/null
_t15_snap_started_id="$RECORD_EVENT_ID"
_t15_dispatch_pair 6 00 implementer p06-i00-implementer-a01 p06-i00-implementer DONE COMPLETED >/dev/null 2>&1 || true
_t15_clean_baseline
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "20b: audit_run_state fails when a DISPATCH_STARTED's own declared snapshot manifest does not exist"
assert_eq yes "$(_t15_finding_has SNAPSHOT_MISSING "event_id:$_t15_snap_started_id" && echo yes || echo no)" \
  "20b: the finding names the exact dispatch's event_id"

# =============================================================================
# 21. Blocking finding unresolved / review cap not respected
# =============================================================================
_t15_reset
_t15_clean_baseline
mkdir -p "$FEATURE_FOLDER/7-code-review/02"
jq -cn '{finding_id:"F1", status:"open", severity:"blocker"}' \
  > "$FEATURE_FOLDER/7-code-review/02/findings-catalog.jsonl"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "21a: audit_run_state fails on an open blocker in the LAST iteration's findings catalog"
assert_eq yes "$(_t15_finding_has BLOCKING_FINDING_UNRESOLVED "finding_id:F1" && echo yes || echo no)" \
  "21a: the finding names the exact open finding id"

_t15_reset
_t15_clean_baseline
record_event ITERATION_CAP_REACHED phase_name=code-review iteration_cap=10 \
  reason="t15 unauthorized cap-bypass fixture" >/dev/null
_t15_cap_id="$RECORD_EVENT_ID"
rc=0; audit_run_state || rc=$?
assert_rc 1 "$rc" "21b: audit_run_state fails when a review cap was reached with neither a later override nor a later HALT"
assert_eq yes "$(_t15_finding_has REVIEW_CAP_NOT_RESPECTED "event_id:$_t15_cap_id" && echo yes || echo no)" \
  "21b: the finding names the exact cap-reached event_id"

# 21c (positive control): the SAME cap event, but with a later
# ITERATION_CAP_OVERRIDE for the same phase -- must NOT be flagged.
_t15_reset
_t15_clean_baseline
record_event ITERATION_CAP_REACHED phase_name=code-review iteration_cap=10 \
  reason="t15 authorized cap-bypass fixture" >/dev/null
_t15_cap_id2="$RECORD_EVENT_ID"
record_event ITERATION_CAP_OVERRIDE phase_name=code-review iteration_cap=10 \
  reason="t15 owner override recorded" >/dev/null
rc=0; audit_run_state || rc=$?
assert_eq yes "$(_t15_no_finding_for_id "event_id:$_t15_cap_id2" && echo yes || echo no)" \
  "21c: a cap followed by a recorded ITERATION_CAP_OVERRIDE is NOT flagged"

# =============================================================================
# 23. _write_lease_foreign_paths_now must NOT declare process-improvement-
#     proposition.md as foreign dirt (round 3 pin -- the same orchestrator-
#     bookkeeping exclusion already pinned indirectly for _mutation_dirty
#     via check_09_recovery.sh and for checkpoint_partial_isolated via
#     check_10_process_v2.sh's RM07 end-to-end test, but never directly for
#     THIS third copy of the same exclusion list).
# =============================================================================
_t15_reset
printf '# fixture proposition file\n' > "$FEATURE_FOLDER/process-improvement-proposition.md"
rm -f "$ORCHESTRATION_DIR/write-lease.json"
allocate_attempt 6 00 implementer >/dev/null
_t15_lease_dispatch="$DISPATCH_ID"
acquire_write_lease implementer role "$_t15_lease_dispatch" 6 "." >/dev/null
_t15_declared_foreign="$(jq -c '.declared_foreign_paths' "$ORCHESTRATION_DIR/write-lease.json" 2>/dev/null)"
case "$_t15_declared_foreign" in
  *process-improvement-proposition.md*)
    _fail "23: _write_lease_foreign_paths_now wrongly declares process-improvement-proposition.md as foreign dirt: [$_t15_declared_foreign]" ;;
  *)
    _ok "23: _write_lease_foreign_paths_now excludes process-improvement-proposition.md from declared foreign dirt" ;;
esac
release_write_lease implementer >/dev/null 2>&1 || true

finish

