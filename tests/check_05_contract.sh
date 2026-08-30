#!/usr/bin/env bash
# Document contract regressions. Each entry corresponds to a spec success
# criterion. Later tasks append to this file; nothing is ever removed.
# EXPECTED RED until the task named in each assertion message lands.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

D="$PROCESS_DOC"

# --- Task 5: stale model ids ---
assert_absent 'claude-opus-4-8'   "$D" "T5: no claude-opus-4-8"
assert_absent 'claude-sonnet-4-6' "$D" "T5: no claude-sonnet-4-6"

# --- Task 6: strict pinning ---
assert_absent 'gpt-5\.3-codex|gpt-5\.2'  "$D" "T6: no nonexistent codex ids"
assert_absent '[Ff]all ?back.*model|model.*[Ff]all ?back' "$D" \
  "T6: no model fallback language"
assert_present 'codex -a never -m "\$model"' "$D" "T6: codex model is bound explicitly"

# --- Task 9: environment ---
assert_absent '/home/worker|repos/GCP' "$D" "T9: no foreign hardcoded paths"
assert_present 'PROCESS_PATH="\$\{PROCESS_PATH:\?' "$D" "T9: PROCESS_PATH fails loud"
assert_present 'PROCESS_REPO_ROOT' "$D" "T9: two-root model present"
assert_present 'GREP_BIN' "$D" "T9: grep is pinned"

# --- Task 11: timing ---
assert_absent 'date \+%s%3N' "$D" "T11: no uutils-broken date format"
assert_present 'EPOCHREALTIME' "$D" "T11: EPOCHREALTIME used for ms timing"
assert_absent '^ *local t0=' "$D" "T11: no 'local' outside a function"

# --- Task 12: porcelain parsing ---
assert_absent "awk '\\{print \\\$2\\}'" "$D" "T12: no awk \$2 on porcelain"
assert_absent 'grep -Fvxf' "$D" "T12: no -x match of absolute vs relative paths"
assert_present 'porcelain=v1 -z' "$D" "T12: NUL-delimited porcelain"

# --- Task 13: parallel dispatch ---
assert_absent '(render_prompt|extract_appendix) +"?\$\{' "$D" \
  "T13: appendix names are literal"

# --- Task 15: shell hygiene ---
assert_absent 'export BASH_XTRACEFD' "$D" "T15: BASH_XTRACEFD is not exported"
assert_absent '\\S' "$D" "T15: no non-POSIX \\S in ERE"
assert_absent '\] && \\$' "$D" "T15: no trailing [ ] && mv"

# --- Task 18/19: dispatch ---
assert_present 'kill-after=60s' "$D" "T19: uniform kill-after grace"
assert_absent 'timeout [0-9]+m ' "$D" "T19: no literal minute values in invocations"
assert_present 'DISPATCH_STARTED' "$D" "T18: resumable dispatch event"

# --- Task 8: durable events and write leases ---
assert_present '^#### Event Contract Registry' "$D" "T8: Event Contract Registry heading present"
assert_present '^record_event\(\) \{' "$D" "T8: record_event is a real cookbook function"
assert_present '^event_required_fields\(\) \{' "$D" "T8: event_required_fields is a real cookbook function"
assert_present '^acquire_write_lease\(\) \{' "$D" "T8: acquire_write_lease is a real cookbook function"
assert_present '^release_write_lease\(\) \{' "$D" "T8: release_write_lease is a real cookbook function"
assert_present 'GIT_FINALIZATION_RESULT' "$D" "T8: GIT_FINALIZATION_RESULT is a registered event type"
# Code review fix (gap b): every legacy pre-schema-v2 tag the "ONLY legal
# event= tags" list normatively requires must also have an Event Contract
# Registry row, or record_event (the SOLE canonical writer) could not
# write an event the process itself mandates.
for _legacy_evt in CODEX_UNAVAILABLE CLAUDE_FAILED IMPLEMENTATION_BASELINE \
  IMPLEMENTATION_BASELINE_BLOCKED CODEX_DISABLED_BY_USER_CONSENT \
  CODEX_SKIPPED_BY_USER_CONSENT MODEL_REJECTED DISPATCH_ORPHANED; do
  assert_present "^\| ${_legacy_evt} \|" "$D" \
    "T8: legacy event type $_legacy_evt has an Event Contract Registry row"
done
assert_present '"schema_version":2,"dispatch_id":null,"lease_owner":"orchestrator-finalization"' "$D" \
  "T8: write-lease.json shape matches the spec's exact example"
assert_absent '_dispatch_lease_try_acquire\(\)\s*\{|_dispatch_lease_release\(\)\s*\{|_dispatch_lease_state\(\)\s*\{' "$D" \
  "T8: the provisional Task 6/7 lease functions are retired, not left dangling"
assert_absent 'ORCHESTRATION_DIR/write-lease\.d' "$D" "T8: no lingering directory-based lease path"
assert_present 'ORCHESTRATION_DIR/write-lease\.json' "$D" "T8: the real JSON lease path is used"

# --- Task 20: renames ---
assert_absent 'claude-opus-verdict\.md|claude-opus-findings\.md' "$D" \
  "T20: model-free artifact filenames"

# --- Task 21: contradictions ---
assert_present 'lint: cookbook' "$D" "T21: cookbook blocks are lint-classified"

# --- Task 8: canary and model probe ---
assert_present 'for bin in claude timeout awk sed jq git date sha256sum cut mkdir mv tail tr' \
  "$D" "T8: canary checks every used binary"
assert_present 'realpath env python3' "$D" "T8: canary checks the new runtime tools"
assert_absent 'setsid' "$D" "T8: setsid is not a dependency (no hand-rolled dispatch protocol)"
assert_absent 'for bin in claude codex ' "$D" "T8: codex is not in the hard-required list"
assert_present 'probe_models\(\)' "$D" "T8: model probe helper exists"

# --- Task 10: provenance targets the process repo ---
assert_absent 'git rev-parse HEAD 2>/dev/null \|\| echo non-git' "$D" \
  "T10: no bare git rev-parse for provenance"
assert_present 'git -C "\$PROCESS_REPO_ROOT" rev-parse HEAD' "$D" \
  "T10: provenance HEAD comes from the process repo"
assert_present 'HEAD:\$PROCESS_PATH_REL|HEAD:\$\{PROCESS_PATH_REL\}' "$D" \
  "T10: git show uses a repo-relative path"

# --- Task 20: contradictions ---
assert_absent 'Cheap \(micro\)|cheap mode|Cheap mode' "$D" "T20: cheap/deep renamed"
assert_present 'scoped' "$D" "T20: modes renamed to scoped"
assert_present 'diff-aware' "$D" "T20: modes renamed to diff-aware"
assert_absent 'Phase 1 spec review|Phase 3 plan review|Phase 6 final review' "$D" \
  "T20: Codex-mode phase numbers corrected"
assert_absent 'frontend/src/features/canvas|Google ADK' "$D" "T20: leaked project specifics removed"
assert_present 'uv run pytest' "$D" "T20: test discovery uses uv"
assert_present 'CODEX_CONSENT' "$D" "T20: non-interactive consent override"
assert_present 'context7.*MCP server' "$D" "T20: context7 is described as an MCP server"

# --- Task 9: resumable role checkpoints ---
assert_present '^checkpoint_append\(\) \{' "$D" "T9: checkpoint_append is a real cookbook function"
assert_present '^checkpoint_resume_state\(\) \{' "$D" "T9: checkpoint_resume_state is a real cookbook function"
assert_present '^checkpoint_partial_isolated\(\) \{' "$D" "T9: checkpoint_partial_isolated is a real cookbook function"
assert_present '^reconstruct_checkpoint_state\(\) \{' "$D" "T9: reconstruct_checkpoint_state is a real cookbook function"
assert_present 'CONTINUATION_CAP_REACHED' "$D" "T9: CONTINUATION_CAP_REACHED is a registered event type"
assert_present '\| document-fixer \|' "$D" "T9: spec/plan fixers get a real checkpoint kind, not none"
assert_present 'artifact-complete\.json' "$D" "T9: plan-writer's structural-completion artifact is documented"
assert_present '\$FEATURE_FOLDER/6-implementation/sdd/' "$D" "T9: SDD custody root is documented"
assert_present 'continuation_path;declared_foreign_changes' "$D" \
  "T9: at least one role declares the new continuation-input optional inputs"

# --- Final review: non-fragile timeout-literal guard ---
# `assert_absent 'timeout [0-9]+m '` (T19) and a hand-composed `Timeout:? +N
# *min` guard both missed real regressions ("120 min", "300-minute") because
# neither matches free-form prose. A literal minute/hour value is legitimate
# ONLY inside the Models table, whose rows all start with `|`. assert_absent
# takes a whole file, so this needs its own pipeline rather than that helper:
# grep -n to keep the real doc line number, then drop table rows (content
# starting with `|` immediately after the "N:" prefix `grep -n` adds).
offenders="$("$GREP_BIN" -nE '[0-9]+ *-?(min|minute|hour|hr)\b' "$D" \
             | "$GREP_BIN" -v -E '^[0-9]+:\|')"
if [ -z "$offenders" ]; then
  _ok "T-final: no literal minute/hour values outside the Models table"
else
  _fail "T-final: literal minute/hour values found outside the Models table"
  printf '%s\n' "$offenders" | while IFS= read -r l; do note "$l"; done
fi

# --- Task 10: preflight and context evidence gates --------------------------
assert_present '^preflight_zero_token_gates\(\) \{' "$D" \
  "T10: preflight_zero_token_gates is a real cookbook function"
assert_present '^validate_existing_run_log\(\) \{' "$D" \
  "T10: validate_existing_run_log is a real cookbook function"
assert_present '^vendor_proven\(\) \{' "$D" "T10: vendor_proven is a real cookbook function"
assert_present '^vendor_proven_mark\(\) \{' "$D" "T10: vendor_proven_mark is a real cookbook function"
assert_present '^applicable_optional_skills\(\) \{' "$D" \
  "T10: applicable_optional_skills is a real cookbook function"
assert_present '^skills_reprobe_needed\(\) \{' "$D" \
  "T10: skills_reprobe_needed is a real cookbook function"
assert_present '^verify_gitignore_guard\(\) \{' "$D" \
  "T10: verify_gitignore_guard is a real cookbook function"

for _t10_evt in PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE LOCAL_CLI_CANARIES_PASSED \
  TARGET_DIRTY_TREE_GATE_PASSED PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED \
  RUNTIME_AND_REGISTRIES_VERIFIED VENDOR_PROVEN; do
  assert_present "^\| ${_t10_evt} \|" "$D" \
    "T10: $_t10_evt has an Event Contract Registry row"
done

# The gate-order function must have a real call site in Phase -1's own prose
# (the "helper that works but sits on no path a real run reaches" failure
# mode named in prior task reviews) -- not just a cookbook definition.
assert_present '`preflight_zero_token_gates` \(see cookbook\) to run them' "$D" \
  "T10: preflight_zero_token_gates has a real call site in Phase -1 prose"

# vendor_proven_mark's real call site: _dispatch_ingest_result marks every
# substantive (non-preflight) COMPLETED dispatch proven, at the ONE choke
# point every dispatch_attempt/dispatch_parallel call routes through.
assert_present 'vendor_proven_mark "\$vendor" "\$role" "\$dispatch_id"' "$D" \
  "T10: vendor_proven_mark has a real call site in _dispatch_ingest_result"

# DEGRADED_REVIEW_ACCEPTED (spec S16.5): registry row already covered by the
# Task 8 legacy-event loop above; Task 10 adds its first real call site.
assert_present 'record_event DEGRADED_REVIEW_ACCEPTED' "$D" \
  "T10: DEGRADED_REVIEW_ACCEPTED has a real call site (Phase 7 one-vendor continuation)"

# Skill-evidence fields are real registry columns for BOTH preflight roles,
# not just prose -- required_status_fields is what publish-status actually
# enforces (STATUS_MISSING_ROLE_FIELD), so a drift here is a real appendix bug.
assert_present '\| preflight-claude \|.*required_skills_present;required_skills_missing;optional_skills_present;optional_skills_absent' \
  "$D" "T10: preflight-claude's registry row declares skill-evidence fields"
assert_present '\| preflight-codex \|.*required_skills_present;required_skills_missing;optional_skills_present;optional_skills_absent' \
  "$D" "T10: preflight-codex's registry row declares skill-evidence fields"

# develop_it_dirty is a FOUR-state enum (spec S16.2), not the old yes/no pair.
assert_present 'develop_it_dirty: +no \| yes \| untracked \| unknown' "$D" \
  "T10: develop_it_dirty is documented as a four-state enum"
assert_present 'git ls-files --error-unmatch' "$D" \
  "T10: untracked detection uses git ls-files --error-unmatch before diffing"

# --- Code review round 2 fixes -----------------------------------------------
# Finding 1: the RUN_LOG lock helper must tolerate an unset $ORCHESTRATION_DIR
# (the exact state gate 1 of Phase -1's first real shell is in, before gate 5
# ever runs bootstrap_runtime).
assert_present 'local lockfile="\$\{1:-\$\{ORCHESTRATION_DIR:-\$FEATURE_FOLDER/\.orchestration\}/log\.lock\}"' "$D" \
  "T10 review: _run_log_lock_acquire/_release tolerate an unset ORCHESTRATION_DIR"

# Finding 2: bootstrap_runtime must never be called inside a command
# substitution (that would discard the globals it exists to set).
assert_absent 'bootstrap_result="\$\(bootstrap_runtime\)"' "$D" \
  "T10 review: bootstrap_runtime is never called inside \$(...) at gate 5"
assert_present 'if ! bootstrap_runtime >"\$bootstrap_tmp"' "$D" \
  "T10 review: gate 5 calls bootstrap_runtime bare, capturing stdout via a plain redirect"

# Finding 3: vendor_proven (the reader) needs a real call site beyond the
# vendor_proven_mark writer, or proven-capability evidence is write-only.
assert_present '^vendor_preflight_reprobe_once\(\) \{' "$D" \
  "T10 review: vendor_preflight_reprobe_once is a real cookbook function"
assert_present 'call `vendor_preflight_reprobe_once codex' "$D" \
  "T10 review: vendor_preflight_reprobe_once has real call sites in the per-phase preflight gates"
_reprobe_sites="$("$GREP_BIN" -c 'call `vendor_preflight_reprobe_once codex' "$D" || true)"
assert_eq 3 "$_reprobe_sites" \
  "T10 review: vendor_preflight_reprobe_once is wired into all three per-phase gates (3, 5, 7)"

# Finding 4/8: the Step 1.0 HALT-logging rule names the CURRENT gate order
# and numbering, not the pre-Task-10 one (canary was step 2, model probe was
# step 3 -- both moved).
assert_present 'gates 2 \(local CLI canaries\), 3 \(target dirty-tree gate\), 5 \(runtime \+' "$D" \
  "T10 review: the HALT-logging rule paragraph names the CURRENT gate order"
assert_present 'one exception is gate 1.s existing-run-log validation' "$D" \
  "T10 review: gate 1's zero-write exception to the uniform HALT rule is documented, not contradicted"

# Finding 5: every gate failure in preflight_zero_token_gates must itself
# durably record event=HALT -- not leave it to unenforced prose.
assert_present '^_preflight_halt\(\) \{' "$D" "T10 review: _preflight_halt is a real cookbook function"
_halt_call_sites="$("$GREP_BIN" -c '_preflight_halt "gate' "$D" || true)"
assert_eq 4 "$_halt_call_sites" \
  "T10 review: preflight_zero_token_gates calls _preflight_halt at all four failable gates (1, 2, 3, 5)"

# Finding 6: applicable_optional_skills has a real call site (durable
# reconstruction, not a dangling variable), and plan-writer actually
# receives it as a rendered appendix input.
assert_present 'APPLICABLE_OPTIONAL_SKILLS="\$\(applicable_optional_skills "\$OPTIONAL_SKILLS" "\$_relevant_skills"' "$D" \
  "T10 review: applicable_optional_skills has a real call site in reconstruct_durable_inputs"
assert_present '^[[:space:]]+APPLICABLE_OPTIONAL_SKILLS$' "$D" \
  "T10 review: APPLICABLE_OPTIONAL_SKILLS is listed as a render_keys() entry"
assert_present '\| plan-writer \|.*applicable_optional_skills' "$D" \
  "T10 review: plan-writer's registry row declares applicable_optional_skills as an input"
assert_absent '\$\{?RELEVANT_SKILLS' "$D" \
  "T10 review: no dangling \$RELEVANT_SKILLS reference remains"

# --- Task 11: stable findings and review convergence ------------------------
assert_present '^## Structural Artifact Manifest Registry' "$D" \
  "T11: Structural Artifact Manifest Registry heading present"
assert_present '^\| plan-writer \| PLAN_PATH \|' "$D" \
  "T11: plan-writer's structural manifest row is present"
assert_present '^\| spec-fixer \| SPEC_PATH \|' "$D" \
  "T11: spec-fixer's structural manifest row is present"
assert_present '^\| plan-fixer \| PLAN_PATH \|' "$D" \
  "T11: plan-fixer's structural manifest row is present"
assert_present '^\| implementation-fixer \| IMPLEMENTATION_SUMMARY_PATH \|' "$D" \
  "T11: implementation-fixer's structural manifest row is present"

for _t11_fn in _artifact_manifest_field validate_artifact ingest_findings \
  select_finding_batch record_finding_disposition dispositions_complete \
  record_convergence_signals divergence_check; do
  assert_present "^${_t11_fn}\(\) \{" "$D" "T11: $_t11_fn is a real cookbook function"
done

for _t11_evt in CONVERGENCE_RECORDED DIVERGENCE_DETECTED DIVERGENT_ROUND_CAP_REACHED; do
  assert_present "^\| ${_t11_evt} \|" "$D" \
    "T11: $_t11_evt has an Event Contract Registry row"
done

# The retired "final fix pass, no re-review" shortcut must not survive
# anywhere in the document -- spec S18.2's "no unreviewed final fix" is the
# whole point of this task; a single surviving mention would mean a gate
# still authorizes an unreviewed revision somewhere.
assert_absent 'Do NOT re-dispatch reviewers afterwards' "$D" \
  "T11: the retired unreviewed-final-fix shortcut is gone"
# "final fix pass" and "deferred major(s)" remain legitimate terms (a major
# explicitly deferred/accepted-risk still exists as a concept) -- what must
# be gone is the OLD semantics: fixed/addressed WITHOUT a subsequent review.
assert_absent 'fixed, not re-reviewed' "$D" \
  "T11: the old 'fixed but never re-reviewed' semantics are retired everywhere"
assert_absent 'without reviewer re-verification' "$D" \
  "T11: the old 'no reviewer re-verification' semantics are retired everywhere"

# Phase 7 must dispatch the bounded implementation-fixer for code-review
# fixes, never the full implementer role (that Mode C is retired) -- the
# exact "helper with no real call site" failure mode named in prior reviews.
assert_present 'role .implementation-fixer. \(NOT .implementer' "$D" \
  "T11: Phase 7's iteration loop dispatches implementation-fixer, not implementer, for fixes"
assert_absent 'Re-dispatch the implementer subagent' "$D" \
  "T11: the retired implementer-as-Phase-7-fixer prose is gone"

# spec-fixer/plan-fixer batch on canonical finding IDs, never whole findings
# files, matching implementation-fixer's pre-existing bounded-batch shape.
assert_present '\| spec-fixer \|.*finding_ids' "$D" \
  "T11: spec-fixer's registry row declares finding_ids, not findings_paths"
assert_present '\| plan-fixer \|.*finding_ids' "$D" \
  "T11: plan-fixer's registry row declares finding_ids, not findings_paths"
assert_absent '\| spec-fixer \|.*findings_paths' "$D" \
  "T11: spec-fixer no longer declares findings_paths"
assert_absent '\| plan-fixer \|.*findings_paths' "$D" \
  "T11: plan-fixer no longer declares findings_paths"

# Reviewer findings are canonical JSONL now, never the retired Markdown
# "### Finding N" prose block.
assert_absent '### Finding N' "$D" \
  "T11: the retired Markdown findings-block format is gone from every appendix"

# Code review fix (round 2, item B): the three gate summarizers must read
# the SAME attempt-scoped STATUS paths and findings-catalog.jsonl the gate
# loop and fixer appendices actually write -- not a "claude-verdict.md" /
# "iteration-*" alias that stopped existing when reviewer STATUS became
# attempt-scoped. Assert both directions: the retired paths are gone, and
# every summarizer's own body cites findings-catalog.jsonl.
assert_absent 'Enumerate iteration folders under .*iteration-\*' "$D" \
  "T11: no summarizer still enumerates the retired iteration-* glob (real iteration dirs are two-digit numeric)"
assert_absent 'read the verdict files \(.claude-verdict\.md' "$D" \
  "T11: no summarizer still reads the retired claude-verdict.md/codex-verdict.md pair"
for _t11_summarizer in summarizer-spec summarizer-plan summarizer-code-review; do
  _t11_summarizer_body="$(python3 - "$D" "$_t11_summarizer" <<'PY'
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
assert_absent '[0-9]-[a-z-]+/iteration-' "$D"   "T11: no phase-dir + iteration- path convention survives anywhere (spec-review/plan-review/code-review all use \$PHASE_DIR/\$ITERATION)"

finish
