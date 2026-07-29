#!/usr/bin/env bash
# Check 5: fake-CLI integration. Exercises dispatch machinery with no tokens.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

load_cookbook || finish

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
FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/x-artifacts"
mkdir -p "$FEATURE_FOLDER/transcripts"
PROCESS_PATH="$PROCESS_DOC"

init_orchestration_vars \
  || { _fail "init_orchestration_vars failed in the fake environment"; finish; }

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

# --- 1. claude_invoke passes the resolved model and timeout ---
: > "$FAKE_ARGV_LOG"
printf 'prompt\n' | claude_invoke spec-reviewer-claude "$WORK/o.json" "$WORK/o.err"
assert_rc 0 $? "claude_invoke succeeds with a healthy stub"
assert_present "--model claude-opus-5" "$FAKE_ARGV_LOG" \
  "claude_invoke passes the role's resolved model"

# --- 2. codex_invoke pins the model, effort, and --json ---
: > "$FAKE_ARGV_LOG"
printf 'prompt\n' | codex_invoke spec-reviewer-codex "$WORK/c.json" "$WORK/c.err"
assert_present "-m gpt-5.6-sol" "$FAKE_ARGV_LOG" "codex_invoke pins the model"
assert_present "model_reasoning_effort=high" "$FAKE_ARGV_LOG" "codex_invoke sets high effort"
assert_present "--json" "$FAKE_ARGV_LOG" "codex_invoke always passes --json"

# --- 2b. The codex stub rejects global options placed after `exec` ---
# This reproduces the real CLI's ordering bug (codex 0.146.0): -a/-m/-c MUST
# precede `exec`. If the stub silently accepted the wrong order, it would mask
# that defect class entirely.
codex exec -a never -m gpt-5.6-sol - < /dev/null \
  > "$WORK/codex_bad_order.out" 2> "$WORK/codex_bad_order.err"
assert_rc 2 $? "codex stub rejects a global option placed after exec"
assert_present "unexpected argument" "$WORK/codex_bad_order.err" \
  "codex stub's rejection message names the offending argument"

# --- 3. --add-dir appears only when the feature folder is outside REPO_ROOT ---
case "$(cat "$FAKE_ARGV_LOG")" in
  *--add-dir*) _fail "--add-dir must be absent when FEATURE_FOLDER is inside REPO_ROOT" ;;
  *) _ok "--add-dir absent for an in-repo feature folder" ;;
esac
: > "$FAKE_ARGV_LOG"
(
  # Plain assignment, no export: validate_roots and codex_invoke run as bash
  # functions in this SAME forked subshell process, so they see this variable
  # without needing it in the environment. Only the actual `codex` stub
  # (a separate process) needs anything exported, and it reads FAKE_ARGV_LOG
  # and PATH, not FEATURE_FOLDER.
  FEATURE_FOLDER="$WORK/outside"; mkdir -p "$FEATURE_FOLDER"
  validate_roots >/dev/null 2>&1
  printf '%s' "${FEATURE_FOLDER_OUTSIDE_REPO:-<unset>}" > "$WORK/outside_flag.txt"
  printf 'p\n' | codex_invoke plan-reviewer-codex "$WORK/c2.json" "$WORK/c2.err"
)
assert_eq "yes" "$(cat "$WORK/outside_flag.txt")" \
  "validate_roots sets FEATURE_FOLDER_OUTSIDE_REPO=yes for an out-of-repo feature folder"
assert_present "--add-dir" "$FAKE_ARGV_LOG" \
  "--add-dir present for an out-of-repo feature folder"

# --- 4. A failing stub is reported as failed ---
: > "$FAKE_ARGV_LOG"
FAKE_RC=3 dispatch_reviewers_parallel spec-reviewer-claude spec-reviewer-codex 3 01
assert_eq 3 "${CLAUDE_RC}" "a failing claude stub is detected (was always 0 before)"
assert_eq -1 "${CODEX_RC}" "CODEX_RC is -1 when codex is not dispatched"

# --- 5. timeout escalates to --kill-after for a stub that ignores SIGTERM ---
FAKE_IGNORE_TERM=1 FAKE_DELAY=30 \
  timeout --kill-after=1s 1s claude --model x -p - </dev/null >/dev/null 2>&1
rc=$?
case "$rc" in
  124|137) _ok "timeout kills a SIGTERM-ignoring process (rc=$rc)" ;;
  *) _fail "expected 124 or 137 from timeout escalation, got $rc" ;;
esac

# --- long dispatch: recording and resume classification ---
for fn in dispatch_id role_mutates appendix_exists log_dispatch_started dispatch_state; do
  declare -F "$fn" >/dev/null || _fail "$fn is not defined"
done
[ "$_FAILURES" -eq 0 ] || finish

assert_eq "6-iter00-implementer" "$(dispatch_id 6 00 implementer)" \
  "dispatch_id is deterministic"

# dispatch_state sets a GLOBAL and must be called directly: "$(dispatch_state ...)"
# would run it in a subshell and discard it.
state_of() { dispatch_state "$1" "$2" "$3" "$4"; printf '%s' "$DISPATCH_STATE"; }

SD="$FEATURE_FOLDER/6-implementation"; mkdir -p "$SD"
ST="$SD/implementer-status.md"
: > "$FEATURE_FOLDER/RUN_LOG.md"

# 1. Nothing recorded, no STATUS -> never launched.
assert_eq NEVER_LAUNCHED "$(state_of 6 00 implementer "$ST")" \
  "no DISPATCH_STARTED record means NEVER_LAUNCHED"

# 2. Recorded, but no STATUS -> unfinished. This is the session-crash case.
log_dispatch_started 6 implementation 00 implementer
assert_present 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the dispatch is recorded BEFORE it runs"
assert_eq UNFINISHED "$(state_of 6 00 implementer "$ST")" \
  "a recorded dispatch with no STATUS is UNFINISHED"

# 3. Recorded and a valid STATUS -> completed.
printf 'verdict: DONE\nverification: PASS\n' > "$ST"
assert_eq COMPLETED "$(state_of 6 00 implementer "$ST")" \
  "a recorded dispatch with a valid STATUS is COMPLETED"

# 4. A STATUS that fails validation is NOT completion. A half-written artifact
#    must never be mistaken for a finished dispatch.
printf 'verdict: DONE\nverification: MAYBE\n' > "$ST"
assert_eq UNFINISHED "$(state_of 6 00 implementer "$ST")" \
  "an invalid STATUS is UNFINISHED, not COMPLETED"

# 5. role_mutates decides what UNFINISHED means. This is the rule that keeps a
#    half-run implementer from being silently re-run over its own commits.
assert_eq yes "$(role_mutates implementer)"           "the implementer mutates"
assert_eq yes "$(role_mutates finishing-branch)"      "the git finalizer mutates"
assert_eq no  "$(role_mutates summarizer-spec)"       "summarizers are read-only"
assert_eq no  "$(role_mutates code-reviewer-claude)"  "reviewers are read-only"

# 6. Pre-launch validation: a missing appendix must fail before any CLI runs.
appendix_exists implementer     && _ok "appendix_exists finds a real appendix" \
                                || _fail "appendix_exists missed a real appendix"
appendix_exists no-such-role    && _fail "appendix_exists accepted a missing appendix" \
                                || _ok "appendix_exists rejects a missing appendix"

# 7. A render failure must produce ZERO CLI invocations. Asserting only that the
#    delivered prompt has no $VARS is insufficient: an empty prompt also passes
#    that test.
: > "$FAKE_ARGV_LOG"
unset SPEC_PATH
dispatch_role 7 01 code-reviewer-claude "$SD/x-status.md" \
  && _fail "dispatch must fail when a render key is unset" \
  || _ok "dispatch fails when a render key is unset"
assert_eq 0 "$("$GREP_BIN" -c '^claude ' "$FAKE_ARGV_LOG" || true)" \
  "a render failure invokes the CLI zero times"
SPEC_PATH="$WORK/spec.md"

finish
