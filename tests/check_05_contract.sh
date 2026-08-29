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

finish
