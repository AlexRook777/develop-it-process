#!/usr/bin/env bash
# Document contract regressions. Each entry corresponds to a spec success
# criterion. Later tasks append to this file; nothing is ever removed.
# EXPECTED RED until the task named in each assertion message lands.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

D="$PROCESS_DOC"

# Task 10 (P00): the cookbook and publisher are authored at runtime/, not in
# the document -- the document keeps prose, registries, appendices, snippets,
# and a function index. Contract assertions therefore run against the SOURCE
# SET $S: the document plus both runtime/ files, concatenated document-first
# (so document-structure slicing keeps working on $S unchanged). Assertions
# that are specifically about the DOCUMENT's own remaining content use $D;
# ones about the authored cookbook alone use $CB.
CB="$REPO_TOP/runtime/cookbook.sh"
S="$BUILD/process-source.cat"
cat "$D" "$CB" "$REPO_TOP/runtime/publish-status" > "$S"

# --- Task 5: stale model ids ---
assert_absent 'claude-opus-4-8'   "$S" "T5: no claude-opus-4-8"
assert_absent 'claude-sonnet-4-6' "$S" "T5: no claude-sonnet-4-6"

# --- Task 6: strict pinning ---
assert_absent 'gpt-5\.3-codex|gpt-5\.2'  "$S" "T6: no nonexistent codex ids"
assert_absent '[Ff]all ?back.*model|model.*[Ff]all ?back' "$S" \
  "T6: no model fallback language"
assert_present 'codex -a never -m "\$model"' "$S" "T6: codex model is bound explicitly"

# --- Task 9: environment ---
assert_absent '/home/worker|repos/GCP' "$S" "T9: no foreign hardcoded paths"
assert_present 'PROCESS_PATH="\$\{PROCESS_PATH:\?' "$S" "T9: PROCESS_PATH fails loud"
assert_present 'PROCESS_REPO_ROOT' "$S" "T9: two-root model present"
assert_present 'GREP_BIN' "$S" "T9: grep is pinned"

# --- Task 11: timing ---
assert_absent 'date \+%s%3N' "$S" "T11: no uutils-broken date format"
assert_present 'EPOCHREALTIME' "$S" "T11: EPOCHREALTIME used for ms timing"
assert_absent '^ *local t0=' "$S" "T11: no 'local' outside a function"

# --- Task 12: porcelain parsing ---
assert_absent "awk '\\{print \\\$2\\}'" "$S" "T12: no awk \$2 on porcelain"
assert_absent 'grep -Fvxf' "$S" "T12: no -x match of absolute vs relative paths"
assert_present 'porcelain=v1 -z' "$S" "T12: NUL-delimited porcelain"

# --- Task 13: parallel dispatch ---
assert_absent '(render_prompt|extract_appendix) +"?\$\{' "$S" \
  "T13: appendix names are literal"

# --- Task 15: shell hygiene ---
assert_absent 'export BASH_XTRACEFD' "$S" "T15: BASH_XTRACEFD is not exported"
assert_absent '\\S' "$S" "T15: no non-POSIX \\S in ERE"
assert_absent '\] && \\$' "$S" "T15: no trailing [ ] && mv"

# --- Task 18/19: dispatch ---
assert_present 'kill-after=60s' "$S" "T19: uniform kill-after grace"
assert_absent 'timeout [0-9]+m ' "$S" "T19: no literal minute values in invocations"
assert_present 'DISPATCH_STARTED' "$S" "T18: resumable dispatch event"

# --- Task 8: durable events and write leases ---
assert_present '^#### Event Contract Registry' "$S" "T8: Event Contract Registry heading present"
assert_present '^record_event\(\) \{' "$S" "T8: record_event is a real cookbook function"
assert_present '^event_required_fields\(\) \{' "$S" "T8: event_required_fields is a real cookbook function"
assert_present '^acquire_write_lease\(\) \{' "$S" "T8: acquire_write_lease is a real cookbook function"
assert_present '^release_write_lease\(\) \{' "$S" "T8: release_write_lease is a real cookbook function"
assert_present 'GIT_FINALIZATION_RESULT' "$S" "T8: GIT_FINALIZATION_RESULT is a registered event type"
# Code review fix (gap b): every legacy pre-schema-v2 tag the "ONLY legal
# event= tags" list normatively requires must also have an Event Contract
# Registry row, or record_event (the SOLE canonical writer) could not
# write an event the process itself mandates.
for _legacy_evt in CODEX_UNAVAILABLE CLAUDE_FAILED IMPLEMENTATION_BASELINE \
  IMPLEMENTATION_BASELINE_BLOCKED CODEX_DISABLED_BY_USER_CONSENT \
  CODEX_SKIPPED_BY_USER_CONSENT MODEL_REJECTED DISPATCH_ORPHANED; do
  assert_present "^\| ${_legacy_evt} \|" "$S" \
    "T8: legacy event type $_legacy_evt has an Event Contract Registry row"
done
assert_present '"schema_version":2,"dispatch_id":null,"lease_owner":"orchestrator-finalization"' "$S" \
  "T8: write-lease.json shape matches the spec's exact example"
assert_absent '_dispatch_lease_try_acquire\(\)\s*\{|_dispatch_lease_release\(\)\s*\{|_dispatch_lease_state\(\)\s*\{' "$S" \
  "T8: the provisional Task 6/7 lease functions are retired, not left dangling"
assert_absent 'ORCHESTRATION_DIR/write-lease\.d' "$S" "T8: no lingering directory-based lease path"
assert_present 'ORCHESTRATION_DIR/write-lease\.json' "$S" "T8: the real JSON lease path is used"

# --- Task 20: renames ---
assert_absent 'claude-opus-verdict\.md|claude-opus-findings\.md' "$S" \
  "T20: model-free artifact filenames"

# --- Task 21: contradictions (P00: the cookbook left the document) ---
assert_absent '<!-- lint: cookbook -->' "$D" \
  "T21/P00: no cookbook-marked fence remains in the document"
assert_present 'lint: snippet' "$D" "T21: remaining document bash fences are lint-classified"
assert_exists "$CB" "P00: the cookbook is authored at runtime/cookbook.sh"
assert_exists "$REPO_TOP/runtime/publish-status" "P00: the publisher is authored at runtime/publish-status"

# --- Task 8: canary and model probe ---
assert_present 'for bin in claude timeout awk sed jq git date sha256sum cut mkdir mv tail tr' \
  "$S" "T8: canary checks every used binary"
assert_present 'realpath env python3' "$S" "T8: canary checks the new runtime tools"
assert_absent 'setsid' "$S" "T8: setsid is not a dependency (no hand-rolled dispatch protocol)"
assert_absent 'for bin in claude codex ' "$S" "T8: codex is not in the hard-required list"
assert_present 'probe_models\(\)' "$S" "T8: model probe helper exists"

# --- Task 10: provenance targets the process repo ---
assert_absent 'git rev-parse HEAD 2>/dev/null \|\| echo non-git' "$S" \
  "T10: no bare git rev-parse for provenance"
assert_present 'git -C "\$PROCESS_REPO_ROOT" rev-parse HEAD' "$S" \
  "T10: provenance HEAD comes from the process repo"
assert_present 'git -C "\$PROCESS_REPO_ROOT" diff --quiet HEAD -- "\$\{_pi_files\[@\]\}"' "$CB" \
  "T10: the dirty check diffs the repo-relative process file set against HEAD"

# --- Task 20: contradictions ---
assert_absent 'Cheap \(micro\)|cheap mode|Cheap mode' "$S" "T20: cheap/deep renamed"
assert_present 'scoped' "$S" "T20: modes renamed to scoped"
assert_present 'diff-aware' "$S" "T20: modes renamed to diff-aware"
assert_absent 'Phase 1 spec review|Phase 3 plan review|Phase 6 final review' "$S" \
  "T20: Codex-mode phase numbers corrected"
assert_absent 'frontend/src/features/canvas|Google ADK' "$S" "T20: leaked project specifics removed"
assert_present 'uv run pytest' "$S" "T20: test discovery uses uv"
assert_present 'CODEX_CONSENT' "$S" "T20: non-interactive consent override"
assert_present 'context7.*MCP server' "$S" "T20: context7 is described as an MCP server"

# --- Task 9: resumable role checkpoints ---
assert_present '^checkpoint_append\(\) \{' "$S" "T9: checkpoint_append is a real cookbook function"
assert_present '^checkpoint_resume_state\(\) \{' "$S" "T9: checkpoint_resume_state is a real cookbook function"
assert_present '^checkpoint_partial_isolated\(\) \{' "$S" "T9: checkpoint_partial_isolated is a real cookbook function"
assert_present '^reconstruct_checkpoint_state\(\) \{' "$S" "T9: reconstruct_checkpoint_state is a real cookbook function"
assert_present 'CONTINUATION_CAP_REACHED' "$S" "T9: CONTINUATION_CAP_REACHED is a registered event type"
assert_present '\| document-fixer \|' "$S" "T9: spec/plan fixers get a real checkpoint kind, not none"
assert_present 'artifact-complete\.json' "$S" "T9: plan-writer's structural-completion artifact is documented"
assert_present '\$FEATURE_FOLDER/6-implementation/sdd/' "$S" "T9: SDD custody root is documented"
assert_present 'continuation_path;declared_foreign_changes' "$S" \
  "T9: at least one role declares the new continuation-input optional inputs"

# --- Final review: non-fragile timeout-literal guard ---
# `assert_absent 'timeout [0-9]+m '` (T19) and a hand-composed `Timeout:? +N
# *min` guard both missed real regressions ("120 min", "300-minute") because
# neither matches free-form prose. A literal minute/hour value is legitimate
# ONLY inside the Models table, whose rows all start with `|`. assert_absent
# takes a whole file, so this needs its own pipeline rather than that helper:
# grep -n to keep the real doc line number, then drop table rows (content
# starting with `|` immediately after the "N:" prefix `grep -n` adds).
offenders="$("$GREP_BIN" -nE '[0-9]+ *-?(min|minute|hour|hr)\b' "$S" \
             | "$GREP_BIN" -v -E '^[0-9]+:\|')"
if [ -z "$offenders" ]; then
  _ok "T-final: no literal minute/hour values outside the Models table"
else
  _fail "T-final: literal minute/hour values found outside the Models table"
  printf '%s\n' "$offenders" | while IFS= read -r l; do note "$l"; done
fi

# --- Task 10: preflight and context evidence gates --------------------------
assert_present '^preflight_zero_token_gates\(\) \{' "$S" \
  "T10: preflight_zero_token_gates is a real cookbook function"
assert_present '^validate_existing_run_log\(\) \{' "$S" \
  "T10: validate_existing_run_log is a real cookbook function"
assert_present '^vendor_proven\(\) \{' "$S" "T10: vendor_proven is a real cookbook function"
assert_present '^vendor_proven_mark\(\) \{' "$S" "T10: vendor_proven_mark is a real cookbook function"
assert_present '^applicable_optional_skills\(\) \{' "$S" \
  "T10: applicable_optional_skills is a real cookbook function"
assert_present '^skills_reprobe_needed\(\) \{' "$S" \
  "T10: skills_reprobe_needed is a real cookbook function"
assert_present '^verify_gitignore_guard\(\) \{' "$S" \
  "T10: verify_gitignore_guard is a real cookbook function"

for _t10_evt in PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE LOCAL_CLI_CANARIES_PASSED \
  TARGET_DIRTY_TREE_GATE_PASSED PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED \
  RUNTIME_AND_REGISTRIES_VERIFIED VENDOR_PROVEN; do
  assert_present "^\| ${_t10_evt} \|" "$S" \
    "T10: $_t10_evt has an Event Contract Registry row"
done

# The gate-order function must have a real call site in Phase -1's own prose
# (the "helper that works but sits on no path a real run reaches" failure
# mode named in prior task reviews) -- not just a cookbook definition.
assert_present '`preflight_zero_token_gates` \(see cookbook\) to run them' "$S" \
  "T10: preflight_zero_token_gates has a real call site in Phase -1 prose"

# vendor_proven_mark's real call site: _dispatch_ingest_result marks every
# substantive (non-preflight) COMPLETED dispatch proven, at the ONE choke
# point every dispatch_attempt/dispatch_parallel call routes through.
assert_present 'vendor_proven_mark "\$vendor" "\$role" "\$dispatch_id"' "$S" \
  "T10: vendor_proven_mark has a real call site in _dispatch_ingest_result"

# DEGRADED_REVIEW_ACCEPTED (spec S16.5): registry row already covered by the
# Task 8 legacy-event loop above; Task 10 adds its first real call site.
assert_present 'record_event DEGRADED_REVIEW_ACCEPTED' "$S" \
  "T10: DEGRADED_REVIEW_ACCEPTED has a real call site (Phase 7 one-vendor continuation)"

# Skill-evidence fields are real registry columns for BOTH preflight roles,
# not just prose -- required_status_fields is what publish-status actually
# enforces (STATUS_MISSING_ROLE_FIELD), so a drift here is a real appendix bug.
assert_present '\| preflight-claude \|.*required_skills_present;required_skills_missing;optional_skills_present;optional_skills_absent' \
  "$S" "T10: preflight-claude's registry row declares skill-evidence fields"
assert_present '\| preflight-codex \|.*required_skills_present;required_skills_missing;optional_skills_present;optional_skills_absent' \
  "$S" "T10: preflight-codex's registry row declares skill-evidence fields"

# develop_it_dirty is a FOUR-state enum (spec S16.2), not the old yes/no pair.
assert_present 'develop_it_dirty: +no \| yes \| untracked \| unknown' "$S" \
  "T10: develop_it_dirty is documented as a four-state enum"
assert_present 'git ls-files --error-unmatch' "$S" \
  "T10: untracked detection uses git ls-files --error-unmatch before diffing"

# --- Code review round 2 fixes -----------------------------------------------
# Finding 1: the RUN_LOG lock helper must tolerate an unset $ORCHESTRATION_DIR
# (the exact state gate 1 of Phase -1's first real shell is in, before gate 5
# ever runs bootstrap_runtime).
assert_present 'local lockfile="\$\{1:-\$\{ORCHESTRATION_DIR:-\$FEATURE_FOLDER/\.orchestration\}/log\.lock\}"' "$S" \
  "T10 review: _run_log_lock_acquire/_release tolerate an unset ORCHESTRATION_DIR"

# Finding 2: bootstrap_runtime must never be called inside a command
# substitution (that would discard the globals it exists to set).
assert_absent 'bootstrap_result="\$\(bootstrap_runtime\)"' "$S" \
  "T10 review: bootstrap_runtime is never called inside \$(...) at gate 5"
assert_present 'if ! bootstrap_runtime >"\$bootstrap_tmp"' "$S" \
  "T10 review: gate 5 calls bootstrap_runtime bare, capturing stdout via a plain redirect"

# Finding 3: vendor_proven (the reader) needs a real call site beyond the
# vendor_proven_mark writer, or proven-capability evidence is write-only.
assert_present '^vendor_preflight_reprobe_once\(\) \{' "$S" \
  "T10 review: vendor_preflight_reprobe_once is a real cookbook function"
assert_present 'call `vendor_preflight_reprobe_once codex' "$S" \
  "T10 review: vendor_preflight_reprobe_once has real call sites in the per-phase preflight gates"
_reprobe_sites="$("$GREP_BIN" -c 'call `vendor_preflight_reprobe_once codex' "$S" || true)"
assert_eq 3 "$_reprobe_sites" \
  "T10 review: vendor_preflight_reprobe_once is wired into all three per-phase gates (3, 5, 7)"

# Finding 4/8: the Step 1.0 HALT-logging rule names the CURRENT gate order
# and numbering, not the pre-Task-10 one (canary was step 2, model probe was
# step 3 -- both moved).
assert_present 'gates 2 \(local CLI canaries\), 3 \(target dirty-tree gate\), 5 \(runtime \+' "$S" \
  "T10 review: the HALT-logging rule paragraph names the CURRENT gate order"
assert_present 'one exception is gate 1.s existing-run-log validation' "$S" \
  "T10 review: gate 1's zero-write exception to the uniform HALT rule is documented, not contradicted"

# Finding 5: every gate failure in preflight_zero_token_gates must itself
# durably record event=HALT -- not leave it to unenforced prose.
assert_present '^_preflight_halt\(\) \{' "$S" "T10 review: _preflight_halt is a real cookbook function"
_halt_call_sites="$("$GREP_BIN" -c '_preflight_halt "gate' "$S" || true)"
assert_eq 4 "$_halt_call_sites" \
  "T10 review: preflight_zero_token_gates calls _preflight_halt at all four failable gates (1, 2, 3, 5)"

# Finding 6: applicable_optional_skills has a real call site (durable
# reconstruction, not a dangling variable), and plan-writer actually
# receives it as a rendered appendix input.
assert_present 'APPLICABLE_OPTIONAL_SKILLS="\$\(applicable_optional_skills "\$OPTIONAL_SKILLS" "\$_relevant_skills"' "$S" \
  "T10 review: applicable_optional_skills has a real call site in reconstruct_durable_inputs"
assert_present '[[:space:]]APPLICABLE_OPTIONAL_SKILLS([[:space:]]|$)' "$S" \
  "T10 review: APPLICABLE_OPTIONAL_SKILLS is listed as a render_keys() entry"
assert_present '\| plan-writer \|.*applicable_optional_skills' "$S" \
  "T10 review: plan-writer's registry row declares applicable_optional_skills as an input"
assert_absent '\$\{?RELEVANT_SKILLS' "$S" \
  "T10 review: no dangling \$RELEVANT_SKILLS reference remains"

# --- Task 11: stable findings and review convergence ------------------------
assert_present '^## Structural Artifact Manifest Registry' "$S" \
  "T11: Structural Artifact Manifest Registry heading present"
assert_present '^\| plan-writer \| PLAN_PATH \|' "$S" \
  "T11: plan-writer's structural manifest row is present"
assert_present '^\| spec-fixer \| SPEC_PATH \|' "$S" \
  "T11: spec-fixer's structural manifest row is present"
assert_present '^\| plan-fixer \| PLAN_PATH \|' "$S" \
  "T11: plan-fixer's structural manifest row is present"
assert_present '^\| implementation-fixer \| IMPLEMENTATION_SUMMARY_PATH \|' "$S" \
  "T11: implementation-fixer's structural manifest row is present"

for _t11_fn in _artifact_manifest_field validate_artifact ingest_findings \
  select_finding_batch record_finding_disposition dispositions_complete \
  record_convergence_signals divergence_check; do
  assert_present "^${_t11_fn}\(\) \{" "$S" "T11: $_t11_fn is a real cookbook function"
done

for _t11_evt in CONVERGENCE_RECORDED DIVERGENCE_DETECTED DIVERGENT_ROUND_CAP_REACHED; do
  assert_present "^\| ${_t11_evt} \|" "$S" \
    "T11: $_t11_evt has an Event Contract Registry row"
done

# The retired "final fix pass, no re-review" shortcut must not survive
# anywhere in the document -- spec S18.2's "no unreviewed final fix" is the
# whole point of this task; a single surviving mention would mean a gate
# still authorizes an unreviewed revision somewhere.
assert_absent 'Do NOT re-dispatch reviewers afterwards' "$S" \
  "T11: the retired unreviewed-final-fix shortcut is gone"
# "final fix pass" and "deferred major(s)" remain legitimate terms (a major
# explicitly deferred/accepted-risk still exists as a concept) -- what must
# be gone is the OLD semantics: fixed/addressed WITHOUT a subsequent review.
assert_absent 'fixed, not re-reviewed' "$S" \
  "T11: the old 'fixed but never re-reviewed' semantics are retired everywhere"
assert_absent 'without reviewer re-verification' "$S" \
  "T11: the old 'no reviewer re-verification' semantics are retired everywhere"

# Phase 7 must dispatch the bounded implementation-fixer for code-review
# fixes, never the full implementer role (that Mode C is retired) -- the
# exact "helper with no real call site" failure mode named in prior reviews.
assert_present 'role .implementation-fixer. \(NOT .implementer' "$S" \
  "T11: Phase 7's iteration loop dispatches implementation-fixer, not implementer, for fixes"
assert_absent 'Re-dispatch the implementer subagent' "$S" \
  "T11: the retired implementer-as-Phase-7-fixer prose is gone"

# spec-fixer/plan-fixer batch on canonical finding IDs, never whole findings
# files, matching implementation-fixer's pre-existing bounded-batch shape.
assert_present '\| spec-fixer \|.*finding_ids' "$S" \
  "T11: spec-fixer's registry row declares finding_ids, not findings_paths"
assert_present '\| plan-fixer \|.*finding_ids' "$S" \
  "T11: plan-fixer's registry row declares finding_ids, not findings_paths"
assert_absent '\| spec-fixer \|.*findings_paths' "$S" \
  "T11: spec-fixer no longer declares findings_paths"
assert_absent '\| plan-fixer \|.*findings_paths' "$S" \
  "T11: plan-fixer no longer declares findings_paths"

# Reviewer findings are canonical JSONL now, never the retired Markdown
# "### Finding N" prose block.
assert_absent '### Finding N' "$S" \
  "T11: the retired Markdown findings-block format is gone from every appendix"

# Code review fix (round 2, item B): the three gate summarizers must read
# the SAME attempt-scoped STATUS paths and findings-catalog.jsonl the gate
# loop and fixer appendices actually write -- not a "claude-verdict.md" /
# "iteration-*" alias that stopped existing when reviewer STATUS became
# attempt-scoped. Assert both directions: the retired paths are gone, and
# every summarizer's own body cites findings-catalog.jsonl.
assert_absent 'Enumerate iteration folders under .*iteration-\*' "$S" \
  "T11: no summarizer still enumerates the retired iteration-* glob (real iteration dirs are two-digit numeric)"
assert_absent 'read the verdict files \(.claude-verdict\.md' "$S" \
  "T11: no summarizer still reads the retired claude-verdict.md/codex-verdict.md pair"
for _t11_summarizer in summarizer-spec summarizer-plan summarizer-code-review; do
  _t11_summarizer_body="$(python3 - "$S" "$_t11_summarizer" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
role = sys.argv[2]
m = re.search(rf"<!-- BEGIN: {re.escape(role)} -->(.*?)<!-- END: {re.escape(role)} -->", text, re.S)
print(m.group(1) if m else "")
PY
)"
  case "$_t11_summarizer_body" in
    *findings-catalog.jsonl*) _ok "T11: \`$_t11_summarizer\` reads findings-catalog.jsonl, not a stale per-reviewer alias" ;;
    *) _fail "T11: \`$_t11_summarizer\` does NOT mention findings-catalog.jsonl" ;;
  esac
done

# Code review fix (round 4, item 2): pick ONE path convention for a
# gate's iteration directory and never let the retired "<phase-dir>/
# iteration-NN" shape coexist with the real "$PHASE_DIR/$ITERATION" one --
# a real run would otherwise write BOTH a findings-catalog.jsonl under
# 01/ and a claude-findings.jsonl/codex-findings.jsonl under iteration-01/
# that nothing ever reads. Scoped to a phase-dir prefix (`N-name/
# iteration-`) so this does not false-positive on unrelated English
# compounds like "token/iteration-marker".
assert_absent '[0-9]-[a-z-]+/iteration-' "$S"   "T11: no phase-dir + iteration- path convention survives anywhere (spec-review/plan-review/code-review all use \$PHASE_DIR/\$ITERATION)"

# --- Task 12: executable plans and explicit verification results -----------
assert_present '^## Plan Task Contract \(spec §19\.1\)' "$S" \
  "T12: Plan Task Contract heading present"
assert_present '^## Verification Record Contract \(spec §19\.2\)' "$S" \
  "T12: Verification Record Contract heading present"

for _t12_fn in validate_plan_tasks _plan_task_block validate_verification_records \
  _verification_result_legal append_verification_record plan_review_window_closed \
  plan_ready_for_implementation; do
  assert_present "^${_t12_fn}\(\) \{" "$S" "T12: $_t12_fn is a real cookbook function"
done

# The four-state verification result enum is exact: PASS, FAIL, EXCLUDED,
# NOT_RUN. SKIPPED is never a legal value.
assert_present 'PASS\|FAIL\|EXCLUDED\|NOT_RUN' "$S" \
  "T12: the verification result enum is documented as PASS|FAIL|EXCLUDED|NOT_RUN"
assert_present 'SKIPPED and empty are rejected' "$S" \
  "T12: the verification-record validator explicitly documents rejecting SKIPPED and empty results"

# actor enum, no-secret rule, and DAG requirement are documented in the
# executable task contract prose, not only in the validator's own code.
assert_present 'actor=implementer\|owner\|CI\|deployed_environment' "$S" \
  "T12: the four-actor enum is documented"
assert_present 'No secret material' "$S" "T12: the no-secret-material rule is documented"
assert_present 'form a DAG' "$S" "T12: dependencies forming a DAG is documented"

# Once Phase 6 starts, the plan's pre-implementation review window closes.
assert_present '^\| PLAN_REVIEW_STALE \|' "$S" \
  "T12: PLAN_REVIEW_STALE has an Event Contract Registry row"
assert_present 'pre-implementation review window is closed' "$S" \
  "T12: the plan-review window closure rule is documented"
assert_present 'marked `STALE` without a vendor call' "$S" \
  "T12: later plan-review requests are marked STALE without a vendor call"

# DONE_WITH_EXCLUSIONS is a real implementer verdict, wired into the
# Role Contract Registry row and the Phase 6 gating prose, not just prose.
assert_present '\| implementer \|.*DONE;DONE_WITH_EXCLUSIONS;FAILED;NEEDS_DEBUG;BLOCKED' "$S" \
  "T12: implementer's registry row declares DONE_WITH_EXCLUSIONS as a legal verdict"
assert_present 'DONE_WITH_EXCLUSIONS' "$S" "T12: DONE_WITH_EXCLUSIONS is documented"

# --- Task 13: separate implementation continuation from finding repair -----
# No ACTIVE Mode C section survives (the one surviving mention is the
# historical "that role's Mode C is retired" footnote in Phase 7's own
# dispatch prose, never a heading naming a live behavior).
assert_absent '^### Mode C' "$S" \
  "T13: no active 'Mode C' section survives"
assert_present '### Mode D' "$S" \
  "T13: Mode D (continuation) is its own documented section, not folded into Mode A"
assert_present 'INCOMPLETE_CONTINUABLE' "$S" \
  "T13: a clean timeout after committed tasks is documented as INCOMPLETE_CONTINUABLE, not terminal failure"
assert_present '\| implementer \|.*;mode \|' "$S" \
  "T13: implementer's registry row declares mode as a required input"
assert_present 'ROLE_SCOPE_VIOLATION' "$S" \
  "T13: a role dispatched with another role's exclusive scope (e.g. finding_ids) is rejected as ROLE_SCOPE_VIOLATION"
assert_present 'DISPATCH_INVALID_MODE' "$S" \
  "T13: an implementer \$MODE outside A|B|D is rejected before launch as DISPATCH_INVALID_MODE"
assert_present 'disjoint' "$S" \
  "T13: concurrently-dispatched impl-worker children receive a disjoint declared-path set"
for _t13_field in x_completed_task_ids x_baseline_sha x_final_sha \
  x_declared_foreign_changes x_remaining_handoffs; do
  assert_present "^${_t13_field}:" "$S" \
    "T13: implementer's published STATUS template carries $_t13_field"
done

# Code review fix (round 1, finding 5): implementation-fixer's own appendix
# must carry a ripple check, remeasurement of measurement-based findings, and
# an explicit "unrelated opportunity -> follow-up, not code" rule -- all
# three explicit in spec S17.3/S18.4 and Task 13 Step 5, none of which the
# fixer's own bounded-batch loop previously stated. Scoped to the fixer's own
# appendix body (the same extraction T11's summarizer checks already use) so
# this cannot pass on the strength of spec-fixer/plan-fixer/debugger already
# saying "ripple check"/"remeasure" elsewhere in the document.
_t13_fixer_body="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"<!-- BEGIN: implementation-fixer -->(.*?)<!-- END: implementation-fixer -->", text, re.S)
print(m.group(1) if m else "")
PY
)"
case "$_t13_fixer_body" in
  *'ripple check'*) _ok "T13: implementation-fixer's own appendix states the ripple-check rule" ;;
  *) _fail "T13: implementation-fixer's own appendix does NOT mention a ripple check" ;;
esac
case "$_t13_fixer_body" in
  *'remeasure'*) _ok "T13: implementation-fixer's own appendix requires remeasuring measurement-based findings" ;;
  *) _fail "T13: implementation-fixer's own appendix does NOT require remeasurement" ;;
esac
case "$_t13_fixer_body" in
  *'UNRELATED'*'follow-up'*) _ok "T13: implementation-fixer's own appendix states the unrelated-opportunity-becomes-a-follow-up rule" ;;
  *) _fail "T13: implementation-fixer's own appendix does NOT state the unrelated-opportunity rule" ;;
esac

# Code review fix (round 1, finding 6): "the reviewed baseline/final diff"
# (spec S20.7) means IMPLEMENTATION_BASE_SHA..REVIEWED_REVISION -- the WHOLE
# reviewed implementation -- not REVIEWED_REVISION..HEAD, which is the
# fixer's OWN in-progress commit range and is trivially empty at dispatch
# time (REVIEWED_REVISION is captured as HEAD immediately before dispatch).
# implementation_base_sha must be a real optional input AND actually read.
assert_present '\| implementation-fixer \|.*implementation_base_sha' "$S" \
  "T13: implementation-fixer's registry row declares implementation_base_sha as an input"
case "$_t13_fixer_body" in
  *'IMPLEMENTATION_BASE_SHA..$REVIEWED_REVISION'*) _ok "T13: implementation-fixer's own appendix reads the reviewed baseline/final diff (IMPLEMENTATION_BASE_SHA..REVIEWED_REVISION)" ;;
  *) _fail "T13: implementation-fixer's own appendix does NOT read IMPLEMENTATION_BASE_SHA..REVIEWED_REVISION" ;;
esac

# Code review fix (round 1, finding 8): three of the five new x_ STATUS
# fields (x_baseline_sha, x_final_sha, x_remaining_handoffs) now have a real
# reader -- readiness-writer's own "Implementation result" section -- not
# just a template emitting them into a file nothing else opens.
_t13_readiness_body="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"<!-- BEGIN: readiness-writer -->(.*?)<!-- END: readiness-writer -->", text, re.S)
print(m.group(1) if m else "")
PY
)"
for _t13_consumed_field in x_baseline_sha x_final_sha x_remaining_handoffs; do
  case "$_t13_readiness_body" in
    *"$_t13_consumed_field"*) _ok "T13: readiness-writer's own appendix reads implementer-status.md's $_t13_consumed_field" ;;
    *) _fail "T13: readiness-writer's own appendix does NOT read $_t13_consumed_field" ;;
  esac
done

# =============================================================================
# Task 14: documentation, handoff, and orchestrator finalization phases
# =============================================================================

# The normative phase tail is exactly this, in this order -- the highest-risk
# operation in the whole plan, so pin every heading literally.
assert_present '^## Phase 8 — All tests' "$S" "T14: Phase 8 heading is 'All tests'"
assert_present '^## Phase 9 — Documentation and handoff' "$S" \
  "T14: Phase 9 heading is 'Documentation and handoff' (no longer git finalization)"
assert_present '^## Phase 10 — Local git finalization' "$S" \
  "T14: Phase 10 heading is 'Local git finalization' (no longer the readiness report)"
assert_present '^## Phase 11 — Readiness and completion' "$S" \
  "T14: Phase 11 heading is 'Readiness and completion'"
assert_absent '^## Phase 9 — Git finalization' "$S" \
  "T14: the old 'Phase 9 — Git finalization' heading is gone"
assert_absent '^## Phase 10 — Final readiness report' "$S" \
  "T14: the old 'Phase 10 — Final readiness report' heading is gone"

# The phase-token mapping (_phase_name) must agree with the new tail --
# this is the single riskiest hand-edit in the renumbering (PHASE_DIR
# construction reads it for every dispatch).
assert_present '9\)    echo documentation ;;' "$S" \
  "T14: _phase_name maps phase 9 to 'documentation'"
assert_present '10\)   echo git-finalization ;;' "$S" \
  "T14: _phase_name maps phase 10 to 'git-finalization'"
assert_present '11\)   echo readiness-report ;;' "$S" \
  "T14: _phase_name maps phase 11 to 'readiness-report'"

# append_followup: a real cookbook function, with its own contract section,
# and the follow-up ledger is documented as orchestrator-only.
assert_present '^append_followup\(\) \{' "$S" "T14: append_followup is a real cookbook function"
assert_present '^## Follow-up Ledger Contract' "$S" "T14: Follow-up Ledger Contract heading present"
assert_present 'called ONLY by the' "$S" \
  "T14: the follow-up ledger is documented as orchestrator-only, never a role's own write"
assert_present 'A role never writes this file' "$S" \
  "T14: roles never write followups.jsonl directly -- documented explicitly"

# GIT_FINALIZATION_RESULT gained its real fields (Task 8 left a placeholder
# base_sha;candidate_sha;outcome triple with no call site) and its first real
# call site, directly in Phase 10's own prose.
assert_present '\| GIT_FINALIZATION_RESULT \| base_sha;final_sha;staged_paths;commit_sha;push_performed;outcome \|' "$S" \
  "T14: GIT_FINALIZATION_RESULT's registry row carries all six spec fields"
# Task 8/P19: event_required_fields no longer hand-duplicates a per-type case
# line to cross-check against this row -- it is a thin TSV lookup
# (event_contract_field) reading the SAME table this row lives in, so a
# GIT_FINALIZATION_RESULT/registry mismatch is now structurally impossible
# rather than merely caught by a bidirectional test. Assert the delegation
# shape instead of a literal case-line match.
assert_present 'event_contract_field "\$1" required_fields' "$S" \
  "T14/P19: event_required_fields is a thin event_contract_field lookup, not a hand-duplicated case"
assert_present 'record_event GIT_FINALIZATION_RESULT reason=\$REASON base_sha=\$BASE_SHA' "$S" \
  "T14: Phase 10's own prose has a real record_event GIT_FINALIZATION_RESULT call site, with reason set on EVERY branch (record_event refuses an empty reason)"

# Phase 10 is a direct orchestrator operation -- no dispatch, no subagent,
# push is always forbidden.
assert_present 'Phase 10 is executed \*\*directly by the orchestrator' "$S" \
  "T14: Phase 10 is documented as a direct orchestrator operation"
assert_absent 'Dispatch one `claude` subprocess for role `finishing-branch`' "$S" \
  "T14: Phase 10 no longer dispatches finishing-branch"
assert_present 'MUST NOT push' "$S" "T14: Phase 10 explicitly forbids pushing"
assert_present 'push_performed.*always .no.' "$S" \
  "T14: push_performed is documented as always 'no'"

# Phase 8's all-tests gate reuses Task 12's verification-record contract --
# never a phase-level rollup standing in for per-command evidence.
_t14_phase8_range="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r"^## Phase 8 —", text, re.M)
m2 = re.search(r"^## Phase 9 —", text, re.M)
print(text[m1.end():m2.start()])
PY
)"
case "$_t14_phase8_range" in
  *append_verification_record*) _ok "T14: Phase 8's own prose calls append_verification_record" ;;
  *) _fail "T14: Phase 8's own prose has NO append_verification_record call site" ;;
esac
case "$_t14_phase8_range" in
  *validate_verification_records*) _ok "T14: Phase 8's own prose calls validate_verification_records" ;;
  *) _fail "T14: Phase 8's own prose has NO validate_verification_records call site" ;;
esac

# Phase 9's own prose calls append_followup (never inside documentation-writer's
# own appendix, which is a DIFFERENT document region than the phase loop).
_t14_phase9_range="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r"^## Phase 9 —", text, re.M)
m2 = re.search(r"^## Phase 10 —", text, re.M)
print(text[m1.end():m2.start()])
PY
)"
case "$_t14_phase9_range" in
  *append_followup*) _ok "T14: Phase 9's own prose calls append_followup" ;;
  *) _fail "T14: Phase 9's own prose has NO append_followup call site" ;;
esac

# Phase 10's own prose calls acquire_write_lease/release_write_lease directly
# (never dispatch_attempt/dispatch_parallel -- there is no role to dispatch).
_t14_phase10_range="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r"^## Phase 10 —", text, re.M)
m2 = re.search(r"^## Phase 11 —", text, re.M)
print(text[m1.end():m2.start()])
PY
)"
for _t14_fn in acquire_write_lease release_write_lease; do
  case "$_t14_phase10_range" in
    *"$_t14_fn"*) _ok "T14: Phase 10's own prose calls $_t14_fn" ;;
    *) _fail "T14: Phase 10's own prose has NO $_t14_fn call site" ;;
  esac
done
case "$_t14_phase10_range" in
  *dispatch_attempt*|*dispatch_parallel*)
    _fail "T14: Phase 10's own prose calls dispatch_attempt/dispatch_parallel -- it must never dispatch a role" ;;
  *) _ok "T14: Phase 10's own prose never calls dispatch_attempt/dispatch_parallel" ;;
esac

# The documentation-writer appendix carries the full UAT structure, including
# the distinct "Not yet executed" section, and the follow-up-candidate rule.
_t14_docwriter_body="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"<!-- BEGIN: documentation-writer -->(.*?)<!-- END: documentation-writer -->", text, re.S)
print(m.group(1) if m else "")
PY
)"
for _t14_uat_kw in Prerequisites Actions "Expected results" "Smoke checks" "Rollback" "Not yet executed"; do
  case "$_t14_docwriter_body" in
    *"$_t14_uat_kw"*) _ok "T14: documentation-writer's own appendix requires a '$_t14_uat_kw' UAT section" ;;
    *) _fail "T14: documentation-writer's own appendix does NOT mention '$_t14_uat_kw'" ;;
  esac
done
# Code review finding #8: the loop above is substring-anywhere-in-a-130-line
# appendix, so deleting the "Not yet executed" BULLET from the writer's own
# section-order list (step 4) still passes on an incidental mention
# elsewhere (step 5's validation clause). Isolate the ACTUAL step-4 bulleted
# list itself and require the six headers in the documented ORDER, back to
# back -- a mutation that removes or reorders one bullet breaks this even
# though other prose still says the words.
_t14_uat_list_block="$(printf '%s' "$_t14_docwriter_body" | python3 -c "
import re, sys
body = sys.stdin.read()
m = re.search(r'Write \`uat\.md\` with these sections, in this order:(.*?)\n[0-9]+\. Validate', body, re.S)
print(m.group(1) if m else '')
")"
if [ -n "$_t14_uat_list_block" ]; then
  _ok "T14: documentation-writer's own step-4 UAT section-order list was isolated"
else
  _fail "T14: could not isolate documentation-writer's step-4 UAT section-order list"
fi
if printf '%s' "$_t14_uat_list_block" | "$GREP_BIN" -Pzo '(?s)Prerequisites.*Actions.*Expected results.*Smoke checks.*Rollback.*Not yet executed' >/dev/null 2>&1; then
  _ok "T14: the six UAT sections appear in the documented order, back to back, in the writer's own step-4 list"
else
  _fail "T14: the writer's own step-4 list is missing a UAT section or has them out of order"
fi
case "$_t14_docwriter_body" in
  *'never write `followups.jsonl` yourself'*) _ok "T14: documentation-writer's own appendix states it never writes followups.jsonl directly" ;;
  *) _fail "T14: documentation-writer's own appendix does NOT state the no-direct-write rule for followups.jsonl" ;;
esac
case "$_t14_docwriter_body" in
  *x_followup_candidates*) _ok "T14: documentation-writer's own STATUS template carries x_followup_candidates" ;;
  *) _fail "T14: documentation-writer's own STATUS template does NOT carry x_followup_candidates" ;;
esac

# Code review finding #7: no role appendix may itself write followups.jsonl
# -- append_followup is orchestrator-only (Phase 9's own prose is its ONLY
# real call site, per the earlier phase-range-scoped check). Scan EVERY
# appendix body for the writer's own name or a hand-rolled redirect into
# the file -- this is a real, distinct scanner (not the same substring
# checks already used above), and it covers every role, not only
# documentation-writer.
_t14_direct_write_offenders="$(python3 - "$S" <<'PYSCAN'
import re, sys
text = open(sys.argv[1]).read()
for m in re.finditer(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", text, re.S):
    role, body = m.group(1), m.group(2)
    # Only real, executable snippet code counts as "writing it yourself" --
    # a prose sentence explaining the orchestrator-only rule (which legally
    # names append_followup/followups.jsonl to state the rule) must not
    # trip this. Fenced ```bash blocks are the only place an appendix's own
    # runnable instructions live.
    code_blocks = "\n".join(re.findall(r"```bash\n(.*?)```", body, re.S))
    if "append_followup" in code_blocks or re.search(r"[>]{1,2}[^\n]*followups\.jsonl", code_blocks):
        print(role)
PYSCAN
)"
assert_eq "" "$_t14_direct_write_offenders" \
  "T14: no role appendix calls append_followup or redirects into followups.jsonl directly"

# =============================================================================
# Task 15: proposition ledger and audit (spec §21)
# =============================================================================

assert_present '^reconcile_propositions\(\) \{' "$S" "T15: reconcile_propositions is a real cookbook function"
assert_present '^audit_run_state\(\) \{' "$S" "T15: audit_run_state is a real cookbook function"
assert_present '^append_proposition\(\) \{' "$S" "T15: append_proposition is a real cookbook function"
assert_present '^_event_proposition_required\(\) \{' "$S" "T15: _event_proposition_required is a real cookbook function"

# record_event (Task 8's own function, modified by Task 15) has a real call
# site writing pending-propositions.jsonl -- never merely documented in
# prose next to an unwired definition (the GIT_FINALIZATION_RESULT gap
# earlier tasks left for six tasks).
_t15_record_event_body="$(python3 - "$CB" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^record_event\(\) \{\n(.*?)\n\}$", text, re.S | re.M)
print(m.group(1) if m else "")
PY
)"
case "$_t15_record_event_body" in
  *pending-propositions.jsonl*) _ok "T15: record_event's own body writes pending-propositions.jsonl" ;;
  *) _fail "T15: record_event's own body does NOT write pending-propositions.jsonl" ;;
esac
case "$_t15_record_event_body" in
  *_event_proposition_required*) _ok "T15: record_event consults _event_proposition_required before writing a header" ;;
  *) _fail "T15: record_event does NOT consult _event_proposition_required" ;;
esac

# Phase 11's own prose (the phase-range-scoped slice, same technique Task 14
# already uses for Phases 8/9/10) calls the deterministic audit BEFORE
# dispatching readiness-writer -- never merely described in the cookbook
# with no orchestrator call site.
_t15_phase11_range="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r"^## Phase 11 —", text, re.M)
m2 = re.search(r"^## Failure handling", text, re.M)
print(text[m1.end():m2.start()] if m1 and m2 else "")
PY
)"
[ -n "$_t15_phase11_range" ] || _fail "T15: could not isolate Phase 11's own prose range"
for _t15_fn in reconcile_propositions audit_run_state; do
  case "$_t15_phase11_range" in
    *"$_t15_fn"*) _ok "T15: Phase 11's own prose calls $_t15_fn" ;;
    *) _fail "T15: Phase 11's own prose has NO $_t15_fn call site" ;;
  esac
done
case "$_t15_phase11_range" in
  *audit-findings.jsonl*) _ok "T15: Phase 11's own prose names the audit-findings.jsonl artifact" ;;
  *) _fail "T15: Phase 11's own prose does NOT name audit-findings.jsonl" ;;
esac

# The readiness-writer appendix reads the audit artifact and the terminal-
# verdict rule is gated on it -- an empty appendix contract or an ungated
# verdict rule would let a real failed audit slip through to a silent READY.
_t15_readiness_body="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"<!-- BEGIN: readiness-writer -->(.*?)<!-- END: readiness-writer -->", text, re.S)
print(m.group(1) if m else "")
PY
)"
case "$_t15_readiness_body" in
  *audit-findings.jsonl*) _ok "T15: readiness-writer's own appendix reads audit-findings.jsonl" ;;
  *) _fail "T15: readiness-writer's own appendix does NOT read audit-findings.jsonl" ;;
esac
case "$_t15_readiness_body" in
  *'the verdict is unconditionally `NOT_READY`'*) _ok "T15: readiness-writer's terminal-verdict rule is unconditionally gated by a non-empty audit" ;;
  *) _fail "T15: readiness-writer's terminal-verdict rule is NOT gated by the deterministic audit" ;;
esac

# Event Contract Registry / event_required_fields agreement already gets its
# own bidirectional cross-check in check_06_cookbook.sh (proposition_required
# column); this document-level check only pins the exact count of fifteen so
# a future registry edit that silently drops or adds a `yes` row is caught
# here too, independent of that runtime cross-check.
_t15_yes_count="$("$GREP_BIN" -cE '^\| [A-Z_]+ \|.*\| (yes) \|$' "$S" || true)"
assert_eq 15 "$_t15_yes_count" \
  "T15: exactly fifteen Event Contract Registry rows declare proposition_required=yes"

# =============================================================================
# Task 16 Step 1: negative checks for nine retired concepts. Every pattern is
# scoped to a normative marker/heading/formula/enum literal, or to the
# executable ```bash``` blocks inside a role appendix / phase range -- never
# to free English prose -- because the document legitimately narrates its own
# history ("that role's Mode C is retired", "no compatibility reader ... is
# provided") and a naive substring/keyword match on those retired NAMES would
# false-positive on the very sentences that correctly bury them.
# =============================================================================

# 1. finishing-branch role or appendix. (check_02_markers.sh already proves
# no marker exists for any role outside the registry's own set; this pins
# the specific retired name directly, independent of that generic proof.)
assert_absent '<!-- BEGIN: finishing-branch -->' "$S" \
  "T16: no finishing-branch appendix marker survives"
assert_absent '^\| finishing-branch \|' "$S" \
  "T16: no finishing-branch role-registry row survives"
# Widened per code review: "finishing-branch" as a value in some OTHER
# role's own column (not column 1) would evade the line-anchored check
# above. Scan every table row inside the Role Contract Registry section
# specifically (not the whole document, which legitimately narrates
# "finishing-branch is retired" in prose outside any table row).
_t16_registry_section="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r"^## Role Contract Registry", text, re.M)
m2 = re.search(r"^## Structural Artifact Manifest Registry", text, re.M)
print(text[m1.end():m2.start()] if m1 and m2 else "")
PY
)"
_t16_finishing_branch_anywhere="$(printf '%s\n' "$_t16_registry_section" | "$GREP_BIN" -nE '^\|.*finishing-branch.*\|$' || true)"
assert_eq "" "$_t16_finishing_branch_anywhere" \
  "T16: no registry table row mentions finishing-branch in ANY column, not just column 1"
# The retired skill itself: `superpowers:finishing-a-development-branch` is
# never a required skill probe, for any vendor, at any phase (it was a
# required skill for a role -- finishing-branch -- that no longer exists;
# Phase 10's own local-git-finalization is documented as having no subagent
# and no skill of its own).
assert_absent 'superpowers:finishing-a-development-branch' "$S" \
  "T16: superpowers:finishing-a-development-branch is never a required (or any) skill probe"

# 2. implementer Mode C. An active "### Mode C" heading would define real
# behavior; a rationale sentence merely naming "Mode C" as retired (e.g. "that
# role's Mode C is retired") does not match a heading anchor and is legitimate.
assert_absent '^#{2,6} Mode C\b' "$S" \
  "T16: no active 'Mode C' section heading survives at ANY heading level"
assert_present '`\$MODE` — `A`, `B`, or `D`' "$S" \
  "T16: implementer's own \$MODE enum is exactly A, B, D (no C)"

# 3. direct role writes or moves to STATUS. Scan every appendix's OWN fenced
# blocks -- ANY fence language, including a bare untagged ``` ``` (the
# extractor's own executable-block scanner only recognizes ```bash/```python,
# so a bare fence is invisible to check_01_lint.sh's "unmarked" detector too;
# an LLM subprocess reading its own appendix does not care whether a fence is
# tagged, so neither can this scanner) -- never its surrounding PROSE, which
# legitimately explains the prohibition by naming STATUS.md -- for a
# write/rename/copy that targets a STATUS.md path by any means other than the
# sanctioned generated publisher.
_t16_direct_status_writes="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
appendix_re = re.compile(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", re.S)
offenders = []
for m in appendix_re.finditer(text):
    role, body = m.group(1), m.group(2)
    for code in re.findall(r"```[a-zA-Z0-9_+-]*\n(.*?)```", body, re.S):
        for line in code.splitlines():
            if "STATUS.md" not in line or "STATUS_PUBLISHER_PATH" in line:
                continue
            if re.search(r"(>{1,2}|\bmv\b|\bcp\b)\s*\S*STATUS\.md", line) or \
               re.search(r"STATUS\.md\s*(>{1,2}|<)", line):
                offenders.append(f"{role}: {line.strip()}")
print("\n".join(offenders))
PY
)"
assert_eq "" "$_t16_direct_status_writes" \
  "T16: no role appendix's own executable code writes/moves/copies a STATUS.md file directly"

# 4. line-number-based Markdown finding identity. The document must keep its
# explicit disclaimer AND the finding_id formula must still omit any line
# component -- proving the identity is location/anchor/fingerprint-derived,
# never a hash over the line number (the `line` field remains legal as
# diagnostic evidence only, per the plan's Global Constraints).
assert_present 'never the line number itself' "$S" \
  "T16: markdown finding identity explicitly documents excluding the line number"
# Anchored end-to-end (not just a prefix substring) so inserting an extra
# ingredient (e.g. `+ line +`) between the documented three arguments and the
# closing paren actually breaks this -- a prefix-only match would keep
# matching regardless of what gets appended before the close paren.
_t16_finding_id_formula="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
pat = re.compile(r'sha256\(artifact_kind \+ "\\0" \+ normalized_location \+ "\\0" \+\s*normalized_issue_key\)', re.S)
print("MATCH" if pat.search(text) else "NO_MATCH")
PY
)"
assert_eq "MATCH" "$_t16_finding_id_formula" \
  "T16: finding_id's own formula is EXACTLY the three documented arguments -- no line-number ingredient inserted"

# 5. unreviewed final fixer acceptance. (T11 above already retires the old
# "final fix pass, no re-review" shortcut phrase; this pins the affirmative
# replacement rule -- a fixer's own STATUS never substitutes for a subsequent
# reviewer verdict, at any iteration including the cap.)
assert_present "there is no iteration, including the cap, at which a fixer's own STATUS substitutes for a subsequent reviewer verdict" "$S" \
  "T16: a fixer's own STATUS never substitutes for a subsequent reviewer verdict, at any iteration"

# 6. unbounded retry/review language. Every retry/review loop in this
# document is bounded by a named policy cap; no prose authorizes retrying or
# reviewing indefinitely, without limit, or until success.
assert_absent 'retr(y|ied|ies).{0,20}indefinitely|indefinitely.{0,20}retr(y|ied|ies)' "$S" \
  "T16: no 'retry indefinitely' language survives"
assert_absent 'no (retry|iteration|review) limit|unlimited (retr(y|ies)|iterations?|reviews?)' "$S" \
  "T16: no 'unlimited/no limit' retry-or-review language survives"
assert_absent 'as many (times|iterations|rounds) as (it takes|needed|necessary)|until it (succeeds|passes)\b' "$S" \
  "T16: no 'as many times as needed' / 'until it succeeds' retry language survives"

# 7. subprocess writes to RUN_LOG.md. The parent orchestrator is RUN_LOG.md's
# sole writer (record_event's own definition, called only from phase prose);
# no role appendix's own fenced content -- ANY fence language, including a
# bare untagged ``` ``` (same evasion class as check 3 above; an LLM
# subprocess follows an appendix's instructions regardless of fence tag) --
# may call record_event or redirect into RUN_LOG.md itself.
_t16_subprocess_run_log_writes="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
appendix_re = re.compile(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", re.S)
offenders = []
for m in appendix_re.finditer(text):
    role, body = m.group(1), m.group(2)
    for code in re.findall(r"```[a-zA-Z0-9_+-]*\n(.*?)```", body, re.S):
        if re.search(r"\brecord_event\b", code) or re.search(r"(>{1,2})\s*\S*RUN_LOG\.md", code):
            offenders.append(role)
print("\n".join(sorted(set(offenders))))
PY
)"
assert_eq "" "$_t16_subprocess_run_log_writes" \
  "T16: no role appendix's own executable code calls record_event or writes RUN_LOG.md directly"

# 8. Phase 10 remote action, push, or pull-request creation. Scoped to Phase
# 10's own prose range (the same phase-range-scoped slicing T14/T15 already
# use). Phase 10 is (today) a direct orchestrator operation with no fenced
# code blocks of its own -- every command it runs is narrated inline -- but a
# regression could add one (bash, another language, or a bare untagged
# ``` ``` -- see the check-3/check-7 fence-evasion note above), so this scans
# BOTH inline `code span` text AND any fenced block found in the range, never
# bare prose words -- scoping to code spans/fences (not prose) is what lets
# the surrounding plain-English prohibition sentence ("Phase 10 MUST NOT
# push, open a pull request...") coexist without tripping this.
_t16_phase10_range="$(python3 - "$S" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r"^## Phase 10 —", text, re.M)
m2 = re.search(r"^## Phase 11 —", text, re.M)
print(text[m1.end():m2.start()] if m1 and m2 else "")
PY
)"
[ -n "$_t16_phase10_range" ] || _fail "T16: could not isolate Phase 10's own prose range"
_t16_phase10_remote_offenders="$(printf '%s' "$_t16_phase10_range" | python3 -c "
import re, sys
seg = sys.stdin.read()
offenders = []
pat = re.compile(r'git push|gh pr create|hub pull-request|git remote (add|set-url)')
for span in re.findall(r'\`([^\`\n]+)\`', seg):
    if pat.search(span):
        offenders.append(span)
for code in re.findall(r'\`\`\`[a-zA-Z0-9_+-]*\n(.*?)\`\`\`', seg, re.S):
    if pat.search(code):
        offenders.append(code.strip()[:80])
print('\n'.join(offenders))
")"
assert_eq "" "$_t16_phase10_remote_offenders" \
  "T16: Phase 10's own narrated commands (inline spans AND any fenced block) never push, open a pull request, or touch a remote"
# Scoped to Phase 10's own range (not document-wide, which would pass even if
# THIS phase's own record_event call regressed, as long as some OTHER phase's
# prose happened to say push_performed=no somewhere).
case "$_t16_phase10_range" in
  *'push_performed=no'*) _ok "T16: Phase 10's own record_event call (within Phase 10's own range) hardcodes push_performed=no" ;;
  *) _fail "T16: Phase 10's own range does NOT contain push_performed=no" ;;
esac

# 10. transcript filenames: exactly one form, `<dispatch-id>.stdout`/`.stderr`
# (allocate_attempt's own real assignment). Two OTHER, incompatible spellings
# must never appear as an actual example/extension -- the retired
# `<phase>-iter<NN>-<role>` identifier WITH a file extension attached (the
# bare identifier alone is legitimate: the document's own rationale sentence
# names it, unextended, specifically to ban it), and the `.{json,err}`
# extension pair from an earlier draft of the canonical write list.
assert_absent '<phase>-iter<NN>-<role>\.(json|err|stdout|stderr)' "$S" \
  "T16: no retired <phase>-iter<NN>-<role> transcript filename EXAMPLE (with an extension) survives"
assert_absent '\{json,err\}' "$S" \
  "T16: no transcript is ever named with the retired .{json,err} extension pair"

# 11. Phase 10 stages REPO-ROOT-relative paths, not feature-folder-relative
# ones (code review finding A9): `git -C "$REPO_ROOT" add` needs paths
# relative to $REPO_ROOT, but the three fixed documentation outputs and
# followups.jsonl live under $FEATURE_FOLDER, a SUBDIRECTORY of $REPO_ROOT --
# a bare `9-documentation/uat.md` staging-path argument would never match a
# real file relative to $REPO_ROOT and every run would silently stage
# nothing (a bogus NO_CHANGES/BLOCKED outcome, never COMMITTED).
case "$_t16_phase10_range" in
  *'FEATURE_FOLDER_REL='*) _ok "T16: Phase 10's own prose computes FEATURE_FOLDER_REL before building staging paths" ;;
  *) _fail "T16: Phase 10's own prose does NOT compute FEATURE_FOLDER_REL -- its staging paths are feature-folder-relative, not repo-root-relative" ;;
esac
case "$_t16_phase10_range" in
  *'FEATURE_FOLDER_REL/9-documentation/uat.md'*) _ok "T16: Phase 10's own prose prefixes the fixed doc-output staging paths with \$FEATURE_FOLDER_REL" ;;
  *) _fail "T16: Phase 10's own prose does NOT prefix its fixed doc-output staging paths with \$FEATURE_FOLDER_REL" ;;
esac

# 9. schema-v1 fallback or historical artifact migration. No helper reads,
# converts, or upgrades a schema-v1 (or unrecognized) RUN_LOG -- the
# documented behavior is an unconditional HALT token, never a silent
# compatibility read.
assert_absent 'read_legacy_run_log|convert_v1_to_v2|migrate_run_log|schema_v1_compat|v1_compatibility_reader|upgrade_schema_v1' "$S" \
  "T16: no schema-v1 compatibility-reader or migration helper exists"
assert_present 'RUN_LOG_SCHEMA_V1_OR_UNKNOWN' "$S" \
  "T16: an unrecognized/schema-v1 RUN_LOG is an explicit HALT token, never a silent migration"

finish
