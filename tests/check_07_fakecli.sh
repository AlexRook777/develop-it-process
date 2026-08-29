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
assert_eq yes "$(role_mutates documentation-writer)"  "the documentation writer mutates"
assert_eq no  "$(role_mutates summarizer-spec)"       "summarizers are read-only"
assert_eq no  "$(role_mutates code-reviewer-claude)"  "reviewers are read-only"

# 6. Pre-launch validation: a missing appendix must fail before any CLI runs.
appendix_exists implementer     && _ok "appendix_exists finds a real appendix" \
                                || _fail "appendix_exists missed a real appendix"
appendix_exists no-such-role    && _fail "appendix_exists accepted a missing appendix" \
                                || _ok "appendix_exists rejects a missing appendix"

# 7. dispatch_role run TO COMPLETION against the fakebin stubs. Every prior
#    assertion in this file either called a helper directly or deliberately
#    failed at render -- nothing exercised the success path all the way through
#    log_dispatch, which is exactly where the Critical finding lived:
#    process_identity had zero call sites, so PROCESS_GIT_HEAD was an unbound
#    variable and log_dispatch died mid-`{ }` group under `set -uo pipefail`,
#    AFTER the CLI had already been invoked, appending a TRUNCATED block to the
#    append-only RUN_LOG. Isolate RUN_LOG first so the field-order and
#    provenance checks below see exactly one dispatch block.
: > "$FEATURE_FOLDER/RUN_LOG.md"
: > "$FAKE_ARGV_LOG"
dispatch_role 3 01 spec-reviewer-claude "$SD/dr7-status.md"
assert_rc 0 $? "dispatch_role returns 0 end to end with a healthy stub"

assert_present 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "RUN_LOG gained an event=DISPATCH_STARTED block"
assert_present '^--- .*  dispatch$' "$FEATURE_FOLDER/RUN_LOG.md" \
  "RUN_LOG gained a full dispatch block"

# Regression test for FIX 1: provenance fields must be REAL, not empty/unbound.
git_sha="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" develop_it_git_sha)"
file_sha256="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" develop_it_file_sha256)"
if [ -n "$git_sha" ] && [ "$git_sha" != non-git ]; then
  _ok "dispatch block's develop_it_git_sha is populated (FIX1 regression)"
else
  _fail "dispatch block's develop_it_git_sha is empty or non-git: [$git_sha]"
fi
if [ -n "$file_sha256" ]; then
  _ok "dispatch block's develop_it_file_sha256 is populated (FIX1 regression)"
else
  _fail "dispatch block's develop_it_file_sha256 is empty"
fi

# Regression test for FIX 2: phase_name must be the canonical name, not 'unknown'.
assert_eq "spec-review" "$(status_field "$FEATURE_FOLDER/RUN_LOG.md" phase_name)" \
  "dispatch block's phase_name is canonical, not 'unknown' (FIX2 regression)"

# Regression test for FIX 7: emitted key order must match the declared grammar
# field-for-field. Walk the dispatch block's own lines rather than trusting any
# single-key lookup, which cannot see ordering.
dr_keys=""
in_dispatch_block=0
while IFS= read -r line; do
  case "$line" in
    "--- "*"  dispatch")
      in_dispatch_block=1
      continue
      ;;
  esac
  if [ "$in_dispatch_block" -eq 1 ]; then
    [ -z "$line" ] && break
    dr_keys="$dr_keys ${line%%:*}"
  fi
done < "$FEATURE_FOLDER/RUN_LOG.md"
dr_keys="${dr_keys# }"
assert_eq \
  "phase phase_name iteration role vendor appendix develop_it_git_sha develop_it_file_sha256 develop_it_dirty status_path verdict model duration_ms tokens_input_new tokens_input_cached tokens_cache_write tokens_output tokens_reasoning cost_usd usage_status" \
  "$dr_keys" \
  "log_dispatch emits keys in the declared grammar order (FIX7 regression)"

# 7b. dispatch_reviewers_parallel with codex_available=true: exercises the
# codex render path, the second subshell, the second `wait`, and CODEX_RC
# coming from that wait -- none of which any existing assertion touched.
# Also the regression test for FIX 3: BOTH roles must get a DISPATCH_STARTED
# record before either subshell launches, or dispatch_state can never see them
# on resume.
: > "$FEATURE_FOLDER/RUN_LOG.md"
: > "$FAKE_ARGV_LOG"
codex_available=true dispatch_reviewers_parallel spec-reviewer-claude spec-reviewer-codex 3 02
assert_rc 0 $? "dispatch_reviewers_parallel returns 0 with codex_available=true"
assert_eq 0 "${CLAUDE_RC}" "codex path: claude subprocess succeeds (rc from wait)"
assert_eq 0 "${CODEX_RC}" "codex path: codex subprocess succeeds (rc from the second wait)"
assert_eq 2 "$("$GREP_BIN" -c 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "both claude and codex roles got a DISPATCH_STARTED record (FIX3 regression)"
assert_present 'role:                     spec-reviewer-claude' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the claude role's DISPATCH_STARTED record is present"
assert_present 'role:                     spec-reviewer-codex' "$FEATURE_FOLDER/RUN_LOG.md" \
  "the codex role's DISPATCH_STARTED record is present"

# 7c. post_dispatch must treat an empty rc, a non-numeric rc, and rc=124
# (timeout's own exit code) as failure -- not a syntax error, not success.
: > "$WORK/pd-status.md"; : > "$WORK/pd.err"
post_dispatch "" "$WORK/pd-status.md" "$WORK/pd.err" >/dev/null 2>&1
assert_rc 1 $? "post_dispatch treats an empty rc as failure"
post_dispatch "abc" "$WORK/pd-status.md" "$WORK/pd.err" >/dev/null 2>&1
assert_rc 1 $? "post_dispatch treats a non-numeric rc as failure"
post_dispatch 124 "$WORK/pd-status.md" "$WORK/pd.err" >/dev/null 2>&1
assert_rc 1 $? "post_dispatch treats rc=124 (timeout) as failure"

# 8. A render failure must produce ZERO CLI invocations. Asserting only that the
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

finish
