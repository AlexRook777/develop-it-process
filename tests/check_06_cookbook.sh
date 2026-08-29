#!/usr/bin/env bash
# Check 2: unit tests for extracted cookbook helpers.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

load_cookbook || finish

# Every role_* lookup below resolves through the extracted role-contract
# registry, not a hand-maintained case statement -- point it at a freshly
# extracted copy.
python3 "$REPO_TOP/tests/lib/extract.py" roles > /dev/null
export ROLE_CONTRACTS_PATH="$BUILD/roles.tsv"
init_fixture_env || { _fail "fixture env setup failed"; finish; }

# --- path_in_tree: boundary-aware directory matching ---
if declare -F path_in_tree >/dev/null; then
  path_in_tree /a/b/c /a/b   && _ok "path_in_tree: child is inside"    || _fail "path_in_tree: child is inside"
  path_in_tree /a/b   /a/b   && _ok "path_in_tree: equal is inside"    || _fail "path_in_tree: equal is inside"
  path_in_tree /a/bc  /a/b   && _fail "path_in_tree: sibling prefix must NOT match" \
                             || _ok "path_in_tree: sibling prefix does not match"
  path_in_tree /a     /a/b   && _fail "path_in_tree: parent must NOT match" \
                             || _ok "path_in_tree: parent does not match"
else
  _fail "path_in_tree is not defined"
fi

# --- canon: normalizes .. and trailing slash ---
if declare -F canon >/dev/null; then
  d="$(mktemp -d)"; mkdir -p "$d/x/y"
  assert_eq "$d/x" "$(canon "$d/x/y/..")" "canon resolves .."
  assert_eq "$d/x" "$(canon "$d/x/")"     "canon strips trailing slash"
  rm -rf "$d"
else
  _fail "canon is not defined"
fi

# --- process_identity targets the process repo, not cwd ---
if declare -F process_identity >/dev/null; then
  tmp="$(mktemp -d)"
  # A decoy "target project" repo with a different HEAD.
  git -C "$tmp" init -q .
  ( cd "$tmp" && : > f && git add f \
    && git -c user.email=t@t -c user.name=t commit -qm decoy )
  PROCESS_PATH="$PROCESS_DOC"
  PROCESS_REPO_ROOT="$REPO_TOP"
  PROCESS_PATH_REL="${PROCESS_DOC#"$REPO_TOP"/}"
  ( cd "$tmp" && process_identity && printf '%s\n' "$PROCESS_GIT_HEAD" ) > "$BUILD/head.txt"
  expected="$(git -C "$REPO_TOP" rev-parse HEAD)"
  assert_eq "$expected" "$(cat "$BUILD/head.txt")" \
    "process_identity reports the process repo HEAD even when cwd is elsewhere"
  rm -rf "$tmp"
else
  _fail "process_identity is not defined"
fi

# --- now_ms returns 13-digit epoch milliseconds (uutils date lacks %3N) ---
if declare -F now_ms >/dev/null; then
  ms="$(now_ms)"
  assert_eq 13 "${#ms}" "now_ms returns 13 digits"
  case "$ms" in ''|*[!0-9]*) _fail "now_ms is not numeric: $ms" ;; *) _ok "now_ms is numeric" ;; esac
else
  _fail "now_ms is not defined"
fi

# --- parse_usage ---
if declare -F parse_usage >/dev/null; then
  out="$(parse_usage claude fixtures/claude-usage.json 4210 claude-opus-5)"
  case "$out" in
    *"model=claude-opus-5"*) _ok "parse_usage picks the main model, not the haiku helper" ;;
    *) _fail "parse_usage main-model selection: $out" ;;
  esac
  case "$out" in
    *"usage_status=ok"*) _ok "parse_usage reports ok for a good claude record" ;;
    *) _fail "parse_usage claude status: $out" ;;
  esac

  # Assert EVERY emitted field, not just one. Fixture: input_tokens=2100,
  # cached_input_tokens=1800 -> tokens_input_new must be the DIFFERENCE (300),
  # not the raw total, so a raw-vs-subtracted mistake is visible.
  out="$(parse_usage codex fixtures/codex-usage.jsonl 900 gpt-5.6-sol)"
  assert_eq \
    "model=gpt-5.6-sol duration_ms=900 tokens_input_new=300 tokens_input_cached=1800 tokens_cache_write=0 tokens_output=640 tokens_reasoning=2048 cost_usd=n/a usage_status=ok" \
    "$out" "parse_usage emits every codex field exactly (input_new is total minus cached)"

  # The regression: a transcript with no turn.completed must be 'unavailable',
  # not 'ok' with zeros.
  out="$(parse_usage codex fixtures/codex-no-turn.jsonl 900 gpt-5.6-sol)"
  case "$out" in
    *"usage_status=unavailable"*) _ok "parse_usage reports unavailable when turn.completed is absent" ;;
    *) _fail "parse_usage must not report ok with zeros: $out" ;;
  esac

  # Always nine pairs, whatever happens.
  assert_eq 9 "$(printf '%s' "$out" | tr ' ' '\n' | "$GREP_BIN" -c '=')" \
    "parse_usage always emits nine key=value pairs"
else
  _fail "parse_usage is not defined"
fi

# --- porcelain_offenders ---
if declare -F porcelain_offenders >/dev/null; then
  R="$(mktemp -d)"
  git -C "$R" init -q
  mkdir -p "$R/docs/keep" "$R/src"
  printf 'x\n' > "$R/src/a b.txt"      # a path with a space
  printf 'x\n' > "$R/src/plain.txt"
  printf 'x\n' > "$R/docs/keep/k.txt"
  git -C "$R" add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm init

  # 1. Clean tree.
  assert_eq "" "$(porcelain_offenders "$R" docs/keep)" "clean tree yields no offenders"

  # 2. An out-of-scope edit is an offender; an allow-listed one is not.
  printf 'y\n' >> "$R/src/plain.txt"
  printf 'y\n' >> "$R/docs/keep/k.txt"
  assert_eq "src/plain.txt" "$(porcelain_offenders "$R" docs/keep)" \
    "allow-listed dir is exempt, out-of-scope file is reported"
  git -C "$R" checkout -q -- .

  # 3. A path containing a space must survive parsing intact.
  printf 'y\n' >> "$R/src/a b.txt"
  assert_eq "src/a b.txt" "$(porcelain_offenders "$R" docs/keep)" \
    "a path with a space is reported intact"
  git -C "$R" checkout -q -- .

  # 4. A rename is checked on BOTH paths. Moving an out-of-scope file INTO the
  #    allow-listed dir must still be an offender: something outside it moved.
  git -C "$R" mv "src/plain.txt" "docs/keep/plain.txt"
  out="$(porcelain_offenders "$R" docs/keep)"
  case "$out" in
    *src/plain.txt*) _ok "rename reports the out-of-scope source path" ;;
    *) _fail "rename must be checked on both paths, got: [$out]" ;;
  esac
  git -C "$R" reset -q --hard

  # 5. Empty allow-list entries must not disable the gate. This was the
  #    empty-alternation bug: the whole gate silently passed.
  printf 'y\n' >> "$R/src/plain.txt"
  assert_eq "src/plain.txt" "$(porcelain_offenders "$R" "" docs/keep "")" \
    "empty allow-list entries are ignored, not gate-disabling"
  git -C "$R" checkout -q -- .

  # 6. Boundary-aware: a sibling with the allow-listed name as a prefix is NOT exempt.
  mkdir -p "$R/docs/keep-backup"
  printf 'y\n' > "$R/docs/keep-backup/b.txt"
  git -C "$R" add -A -- docs/keep-backup >/dev/null
  out="$(porcelain_offenders "$R" docs/keep)"
  case "$out" in
    *keep-backup*) _ok "sibling prefix directory is not exempted" ;;
    *) _fail "docs/keep must not exempt docs/keep-backup, got: [$out]" ;;
  esac

  rm -rf "$R"
else
  _fail "porcelain_offenders is not defined"
fi

# --- render_prompt ---
if declare -F render_prompt >/dev/null; then
  # PLAIN ASSIGNMENTS, deliberately NOT exported. The orchestrator sets these the
  # same way, so an `export` here would mask the real defect: render_prompt reads
  # them through python3's os.environ, which never sees an unexported shell
  # variable. Verified: python3 reports None for a plain assignment.
  PROCESS_PATH="$PROCESS_DOC"
  ITERATION=07
  FEATURE_FOLDER=/tmp/ff
  SPEC_PATH=/tmp/spec.md
  PLAN_PATH=/tmp/plan.md
  FINDINGS_PATHS="/tmp/a.md
/tmp/b.md"
  IMPLEMENTATION_BASE_SHA=deadbeef
  IMPLEMENTATION_SUMMARY_PATH=/tmp/impl.md
  DEBUGGER_STATUS_PATH=/tmp/dbg.md
  REPO_ROOT=/tmp/repo
  ROUND=03
  TEST_REPORT_PATH=/tmp/tr.md
  RESOLVED_MODELS="  implementer: claude-opus-5"
  CONTEXT7_POLICY=required
  ACCEPTED_PLAN=/tmp/plan.md
  REVIEWED_REVISION=deadbeef
  FINDING_IDS="F1 F2"
  WRITE_LEASE=held
  RUN_LOG=/tmp/ff/RUN_LOG.md
  RELEVANT_ARTIFACTS=/tmp/a.md
  FINAL_DIFF=/tmp/final.diff
  ACCEPTED_SPEC=/tmp/spec.md
  IMPLEMENTATION_SUMMARY=/tmp/impl.md
  TEST_SUMMARY=/tmp/tests.md
  REVIEW_SUMMARY=/tmp/review.md
  DECISIONS=none
  EXCLUSIONS=none
  FOLLOWUPS=none
  DOCS_INVENTORY=/tmp/docs.txt
  PHASE_DIR=/tmp/ff/7-code-review
  DISPATCH_ID=p07-i00-implementation-fixer-a01
  LOGICAL_DISPATCH_ID=p07-i00-implementation-fixer
  ATTEMPT=01
  STATUS_PUBLISHER_PATH=/tmp/ff/.orchestration/runtime/publish-status

  body="$(render_prompt spec-reviewer-claude)" \
    && _ok "render_prompt extracts a known appendix from unexported variables" \
    || _fail "render_prompt failed on spec-reviewer-claude"
  case "$body" in
    *'$ITERATION'*) _fail "render_prompt left \$ITERATION unsubstituted" ;;
    *07*)           _ok "render_prompt substituted \$ITERATION" ;;
    *)              _fail "render_prompt output lacks the substituted value" ;;
  esac

  # THE regression: no appendix may render with an unresolved variable. This one
  # assertion covers every appendix and every key at once.
  unresolved=""
  for a in $(/usr/bin/grep -oP '^<!-- BEGIN: \K[a-z0-9-]+' "$PROCESS_DOC"); do
    out="$(render_prompt "$a" 2>&1)" || { unresolved="$unresolved $a(rc)"; continue; }
    case "$out" in
      *'$'[A-Z][A-Z]*) unresolved="$unresolved $a" ;;
    esac
  done
  assert_eq "" "$unresolved" "every appendix renders with no unresolved \$VARS"

  # Multi-line values must survive verbatim -- this is why python3, not sed.
  body="$(render_prompt spec-fixer)"
  case "$body" in
    *"/tmp/a.md"*"/tmp/b.md"*) _ok "multi-line \$FINDINGS_PATHS survives intact" ;;
    *) _fail "multi-line substitution mangled \$FINDINGS_PATHS" ;;
  esac

  # An UNSET variable that the appendix uses must be a named failure, not a
  # half-rendered prompt.
  unset SPEC_PATH
  err="$(render_prompt spec-reviewer-claude 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && _ok "render_prompt fails when an appendix variable is unset" \
                  || _fail "render_prompt must fail on an unset appendix variable"
  case "$err" in
    *SPEC_PATH*) _ok "render_prompt names the unset variable" ;;
    *) _fail "render_prompt did not name the unset variable: $err" ;;
  esac
  SPEC_PATH=/tmp/spec.md

  # A missing marker must be a legible error, not a Python traceback that
  # becomes the prompt.
  err="$(render_prompt no-such-appendix 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && _ok "render_prompt fails on an unknown appendix" \
                  || _fail "render_prompt must fail on an unknown appendix"
  case "$err" in
    *Traceback*) _fail "render_prompt emitted a Python traceback: $err" ;;
    *no-such-appendix*) _ok "render_prompt names the missing appendix" ;;
    *) _fail "render_prompt diagnostic is unhelpful: $err" ;;
  esac
else
  _fail "render_prompt is not defined"
fi

# --- status_field / validate_status ---
if declare -F status_field >/dev/null && declare -F validate_status >/dev/null; then
  S="$BUILD/status.md"
  cat > "$S" <<'EOF'
verdict: CHANGES_REQUESTED
blockers: 0
majors: 2
minors: 5
findings: claude-findings.md
reason: cannot read /etc/a:b -- unmatched " quote
EOF
  assert_eq "CHANGES_REQUESTED" "$(status_field "$S" verdict)" "status_field reads verdict"
  # A colon inside a value must survive: -F: truncated it before.
  assert_eq 'cannot read /etc/a:b -- unmatched " quote' "$(status_field "$S" reason)" \
    "status_field preserves colons and quotes in a value"

  ( cd "$BUILD" && : > claude-findings.md )
  ( cd "$BUILD" && validate_status status.md spec-reviewer-claude ) \
    && _ok "validate_status accepts a complete reviewer status" \
    || _fail "validate_status rejected a valid reviewer status"

  printf 'verdict: PASS\n' > "$BUILD/thin.md"
  ( cd "$BUILD" && validate_status thin.md spec-reviewer-claude ) \
    && _fail "validate_status must require severity counts for reviewers" \
    || _ok "validate_status rejects a reviewer status missing severity counts"

  # Contract rule: an unrecognised verdict must NOT validate. The orchestrator
  # branches on this string; an unknown value falls through every case arm.
  printf 'verdict: LOOKS_FINE\nblockers: 0\nmajors: 0\nminors: 0\nfindings: claude-findings.md\n' \
    > "$BUILD/bogus.md"
  ( cd "$BUILD" && validate_status bogus.md spec-reviewer-claude ) \
    && _fail "validate_status must reject a verdict outside the enum" \
    || _ok "validate_status rejects a verdict outside the enum"

  # Contract rule 4 (doc line 797): non-PASS/READY/DONE requires a reason.
  printf 'verdict: CHANGES_REQUESTED\nblockers: 1\nmajors: 0\nminors: 0\nfindings: claude-findings.md\n' \
    > "$BUILD/noreason.md"
  ( cd "$BUILD" && validate_status noreason.md spec-reviewer-claude ) \
    && _fail "validate_status must require reason: for a non-PASS verdict" \
    || _ok "validate_status requires reason: for a non-PASS verdict"

  # Contract rule 5 (doc line 798): implementer verification: enum.
  printf 'verdict: DONE\nverification: PASS\n' > "$BUILD/impl-ok.md"
  ( cd "$BUILD" && validate_status impl-ok.md implementer ) \
    && _ok "validate_status accepts implementer verification=PASS" \
    || _fail "validate_status rejected a valid implementer status"
  printf 'verdict: DONE\nverification: MAYBE\n' > "$BUILD/impl-bad.md"
  ( cd "$BUILD" && validate_status impl-bad.md implementer ) \
    && _fail "validate_status must reject verification outside PASS|FAIL|PARTIAL" \
    || _ok "validate_status rejects verification outside PASS|FAIL|PARTIAL"
  printf 'verdict: DONE\n' > "$BUILD/impl-missing.md"
  ( cd "$BUILD" && validate_status impl-missing.md implementer ) \
    && _fail "validate_status must require verification: for the implementer" \
    || _ok "validate_status requires verification: for the implementer"

  # A LEGAL verdict must be accepted. Rejecting implementer FAILED would turn a
  # correct failure report into a bogus malformed-STATUS Mode 4.
  printf 'verdict: FAILED\nverification: FAIL\nreason: task 3 needs human input\n' \
    > "$BUILD/impl-failed.md"
  ( cd "$BUILD" && validate_status impl-failed.md implementer ) \
    && _ok "validate_status accepts implementer verdict FAILED (legal)" \
    || _fail "validate_status must accept implementer FAILED"
  # DONE_WITH_CONCERNS is NOT in the implementer contract and must be rejected.
  printf 'verdict: DONE_WITH_CONCERNS\nverification: PASS\n' > "$BUILD/impl-inv.md"
  ( cd "$BUILD" && validate_status impl-inv.md implementer ) \
    && _fail "DONE_WITH_CONCERNS is not a legal implementer verdict" \
    || _ok "validate_status rejects DONE_WITH_CONCERNS for the implementer"

  # Role-specific enums that no generic category can express.
  printf 'verdict: SKIPPED\nreason: no test suite discovered\n' > "$BUILD/tr.md"
  ( cd "$BUILD" && validate_status tr.md all-tests-runner ) \
    && _ok "all-tests-runner accepts SKIPPED" \
    || _fail "all-tests-runner must accept SKIPPED"
  ( cd "$BUILD" && validate_status tr.md spec-fixer ) \
    && _fail "SKIPPED is not legal for spec-fixer" \
    || _ok "spec-fixer rejects SKIPPED"

  # EXHAUSTIVE + NON-CIRCULAR. Inputs are extracted from the APPENDIX BODIES, not
  # from _status_verdicts -- feeding the validator its own table would make schema
  # drift invisible, which is the whole failure this check exists to prevent.
  #
  # Each appendix declares its verdicts on a line like:
  #     - Allowed verdicts: `DONE;FAILED;NEEDS_DEBUG;BLOCKED`
  # verdicts.py only emits a row for an appendix whose body has an
  # "Allowed verdicts:" line -- an appendix reformatted so that line vanishes
  # would silently drop out of the drift check below rather than fail it.
  # Guard against that by
  # requiring the row count to match the real BEGIN-marker count first. The
  # marker regex is anchored at column 0: two lines in the cookbook itself
  # (a Python f-string and a grep -qF pattern) contain the literal text
  # "<!-- BEGIN: " but are not real markers and are indented/embedded, not at
  # the start of the line.
  verdict_rows="$(python3 "$_TESTS_DIR/lib/verdicts.py" "$PROCESS_DOC")"
  verdict_row_count="$(printf '%s\n' "$verdict_rows" | "$GREP_BIN" -c . || true)"
  begin_marker_count="$("$GREP_BIN" -c '^<!-- BEGIN: ' "$PROCESS_DOC" || true)"
  assert_eq "$begin_marker_count" "$verdict_row_count" \
    "every appendix has a verdict row (none silently dropped by verdicts.py)"

  drift=""
  while IFS=$'\t' read -r a declared; do
    [ -n "$a" ] || continue
    coded="$(_status_verdicts "$a" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"
    want="$(printf '%s' "$declared" | tr ';' '\n' | tr -d ' ' \
            | "$GREP_BIN" -v '^$' | sort | tr '\n' ' ')"
    [ "$coded" = "$want" ] || drift="$drift
  $a: appendix declares [$want] but _status_verdicts returns [$coded]"
  done < <(printf '%s\n' "$verdict_rows")
  assert_eq "" "$drift" "_status_verdicts matches every appendix declared verdict line"

  missing_schema=""
  for r in $(_role_keys); do
    [ "$r" = impl-worker ] && continue    # sub-subagent: writes no STATUS
    _status_verdicts "$r" >/dev/null 2>&1 || missing_schema="$missing_schema $r"
  done
  assert_eq "" "$missing_schema" "every dispatched role has a STATUS schema"

  role_count=0
  for r in $(_role_keys); do
    role_count=$((role_count + 1))
    [ "$r" = impl-worker ] && continue
    for vd in $(_status_verdicts "$r"); do
      f="$BUILD/x-$r-$vd.md"
      { printf 'verdict: %s\n' "$vd"
        printf 'reason: because\n'
        for k in $(_status_required_fields "$r"); do
          case "$k" in
            findings)      printf 'findings: %s\n' "f-$r.md"; : > "$BUILD/f-$r.md" ;;
            verification)  printf 'verification: PASS\n' ;;
            context7)      printf 'context7: reachable\n' ;;
            *)             printf '%s: 0\n' "$k" ;;
          esac
        done
      } > "$f"
      ( cd "$BUILD" && validate_status "${f##*/}" "$r" ) \
        || _fail "role $r must accept its own declared verdict '$vd'"
    done
  done
  if [ "$role_count" -eq 0 ]; then
    _fail "_role_keys returned zero roles -- the loop above checked nothing"
  else
    _ok "every role accepts every verdict its appendix declares ($role_count roles checked)"
  fi
else
  _fail "status_field / validate_status not defined"
fi

# --- post_dispatch survives Task 15 and tolerates an empty rc ---
if declare -F post_dispatch >/dev/null; then
  _ok "post_dispatch was preserved (it implements the transcript-read policy)"
else
  _fail "post_dispatch was deleted; the transcript-read policy and dispatch_role both reference it"
fi

# --- vendor_error_text: the stdout channel a zero-byte stderr hides ---
# Regression for the real incident: an org monthly spend limit killed a dispatch
# with rc=1, NO stderr, and the entire diagnosis on stdout. Classifying on the
# stderr tail alone reported nothing and looked like a bare Mode 3.
if declare -F vendor_error_text >/dev/null; then
  out="$(vendor_error_text fixtures/claude-spend-ceiling.json)"
  case "$out" in
    *"monthly spend limit"*) _ok "vendor_error_text extracts claude .result when is_error=true" ;;
    *) _fail "vendor_error_text missed the claude spend-ceiling result: [$out]" ;;
  esac

  # A SUCCESSFUL transcript must yield nothing: this function is only ever
  # called on the failure path, and a non-empty return here would print a bogus
  # "vendor error" banner under every healthy dispatch.
  out="$(vendor_error_text fixtures/claude-usage.json)"
  assert_eq "" "$out" "vendor_error_text is silent on a successful claude transcript"

  # Codex JSONL: same filter, N-element slurp.
  out="$(vendor_error_text fixtures/codex-error.jsonl)"
  case "$out" in
    *"429 Too Many Requests"*) _ok "vendor_error_text extracts a codex JSONL error item" ;;
    *) _fail "vendor_error_text missed the codex error: [$out]" ;;
  esac

  out="$(vendor_error_text fixtures/codex-usage.jsonl)"
  assert_eq "" "$out" "vendor_error_text is silent on a successful codex transcript"

  # Absent and empty transcripts must be silent successes, not errors: the
  # caller distinguishes "no vendor error" from "no transcript" by emptiness.
  vendor_error_text /nonexistent/transcript.json >/dev/null 2>&1
  assert_rc 0 $? "vendor_error_text succeeds on a missing transcript"
  assert_eq "" "$(vendor_error_text /nonexistent/transcript.json 2>/dev/null)" \
    "vendor_error_text prints nothing for a missing transcript"

  # Non-JSON must degrade to empty, never leak raw bytes into a halt message.
  _tmp_nonjson="$(mktemp)"; printf 'not json at all\n' > "$_tmp_nonjson"
  assert_eq "" "$(vendor_error_text "$_tmp_nonjson" 2>/dev/null)" \
    "vendor_error_text prints nothing for a non-JSON transcript"
  rm -f "$_tmp_nonjson"

  # Truncation must not be implemented with `| head -c`: under the mandated
  # `set -o pipefail` that sends printf SIGPIPE and returns 141 on precisely the
  # oversized inputs the bound exists for. Assert both the bound and the rc.
  _tmp_big="$(mktemp)"
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"type":"result","is_error":True,"result":"X"*9000}))' \
    > "$_tmp_big"
  ( set -o pipefail; vendor_error_text "$_tmp_big" >/dev/null 2>&1 )
  assert_rc 0 $? "vendor_error_text returns 0 under pipefail when truncating"
  _big_len="$(vendor_error_text "$_tmp_big" 2>/dev/null | tr -d '\n' | wc -c)"
  assert_eq 2000 "$_big_len" "vendor_error_text bounds the vendor text at 2000 chars"
  rm -f "$_tmp_big"
else
  _fail "vendor_error_text is not defined"
fi

# --- post_dispatch surfaces the stdout vendor error, not just the stderr tail ---
if declare -F post_dispatch >/dev/null; then
  _pd_status="$(mktemp -u)"          # deliberately absent -> failure path
  _pd_err="$(mktemp)"; : > "$_pd_err" # deliberately EMPTY -> the real shape
  _pd_out="$(post_dispatch 1 "$_pd_status" "$_pd_err" fixtures/claude-spend-ceiling.json 2>&1)"
  case "$_pd_out" in
    *"monthly spend limit"*) _ok "post_dispatch surfaces the vendor error when stderr is empty" ;;
    *) _fail "post_dispatch lost the stdout diagnosis: [$_pd_out]" ;;
  esac
  case "$_pd_out" in
    *"stderr empty"*) _ok "post_dispatch names the empty-stderr case explicitly" ;;
    *) _fail "post_dispatch did not explain the empty stderr: [$_pd_out]" ;;
  esac

  # Backward compatibility: the 4th argument is optional and its absence must
  # not break the pre-existing three-argument call shape.
  post_dispatch 1 "$_pd_status" "$_pd_err" >/dev/null 2>&1
  assert_rc 1 $? "post_dispatch still works with the legacy 3-argument form"
  rm -f "$_pd_err"
fi

# --- dispatch_role actually CALLS post_dispatch, with the stdout transcript ---
# post_dispatch spent a revision as an orphan: defined, documented as "the"
# implementation of the transcript-read policy, and invoked from nowhere. That
# is why a spend-ceiling failure reached the user with no diagnostic. Pin both
# the call and the 4th argument.
if declare -F dispatch_role >/dev/null; then
  _dr_body="$(declare -f dispatch_role)"
  case "$_dr_body" in
    *post_dispatch*) _ok "dispatch_role calls post_dispatch" ;;
    *) _fail "dispatch_role no longer calls post_dispatch — the policy is unenforced again" ;;
  esac
  case "$_dr_body" in
    *'post_dispatch "$DISPATCH_RC" "$status_path" "$base.err" "$base.json"'*)
      _ok "dispatch_role passes the stdout transcript to post_dispatch" ;;
    *) _fail "dispatch_role's post_dispatch call is missing the stdout transcript argument" ;;
  esac
else
  _fail "dispatch_role is not defined"
fi

# --- Task 2 Step 7: eight negative cases, one per failure token -------------
# Each case tampers a temporary copy of the extracted role-contract registry
# (or, where the defect is appendix-shaped rather than registry-shaped, a
# temporary copy of the process document itself) and asserts the exact
# machine-readable token the plan names. Never mutate the real $BUILD/roles.tsv
# or $PROCESS_DOC in place -- every case works on its own throwaway copy.
NEG="$BUILD/negcases"; rm -rf "$NEG"; mkdir -p "$NEG"

# 1. One duplicate role -> ROLE_UNKNOWN_OR_DUPLICATE.
cp "$BUILD/roles.tsv" "$NEG/dup.tsv"
"$GREP_BIN" '^spec-fixer	' "$BUILD/roles.tsv" >> "$NEG/dup.tsv"
err="$(ROLE_CONTRACTS_PATH="$NEG/dup.tsv" role_model spec-fixer 2>&1 >/dev/null)"; rc=$?
case "$err" in
  ROLE_UNKNOWN_OR_DUPLICATE:*) [ "$rc" -ne 0 ] && _ok "duplicate role -> ROLE_UNKNOWN_OR_DUPLICATE" \
                                                || _fail "duplicate role must fail (rc=0): $err" ;;
  *) _fail "duplicate role did not report ROLE_UNKNOWN_OR_DUPLICATE: [$err]" ;;
esac

# 2. One unknown role field -> ROLE_FIELD_UNKNOWN.
err="$(ROLE_CONTRACTS_PATH="$BUILD/roles.tsv" role_field spec-fixer bogus_field 2>&1 >/dev/null)"; rc=$?
case "$err" in
  ROLE_FIELD_UNKNOWN:*) [ "$rc" -ne 0 ] && _ok "unknown role field -> ROLE_FIELD_UNKNOWN" \
                                        || _fail "unknown field must fail (rc=0): $err" ;;
  *) _fail "unknown role field did not report ROLE_FIELD_UNKNOWN: [$err]" ;;
esac

# 3. One empty required field -> ROLE_CONTRACT_EMPTY.
awk -F '\t' 'BEGIN{OFS="\t"} NR==1{print; next} $1=="test-fixer"{$12=""} {print}' \
  "$BUILD/roles.tsv" > "$NEG/empty.tsv"
err="$(ROLE_CONTRACTS_PATH="$NEG/empty.tsv" role_outputs test-fixer 2>&1 >/dev/null)"; rc=$?
case "$err" in
  ROLE_CONTRACT_EMPTY:*) [ "$rc" -ne 0 ] && _ok "empty required field -> ROLE_CONTRACT_EMPTY" \
                                         || _fail "empty required field must fail (rc=0): $err" ;;
  *) _fail "empty required field did not report ROLE_CONTRACT_EMPTY: [$err]" ;;
esac

# 4. One appendix verdict mismatch -> VERDICT_SCHEMA_DRIFT.
# Drives the SAME `contract_drift` helper check_02_markers.sh's real,
# suite-wide (currently-passing) contract check uses -- not a reimplemented
# comparison that would keep passing if that real detector were deleted.
cp "$PROCESS_DOC" "$NEG/verdict-drift.md"
python3 - "$NEG/verdict-drift.md" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text, n = re.subn(
    r"(<!-- BEGIN: spec-fixer -->.*?- Allowed verdicts: `)DONE;BLOCKED(`)",
    r"\1DONE;BLOCKED;BOGUS_VERDICT\2", text, count=1, flags=re.S)
assert n == 1, "fixture setup: spec-fixer Allowed verdicts line not found"
open(path, "w").write(text)
PY
msg4="$(contract_drift "$NEG/verdict-drift.md" "$BUILD/roles.tsv" spec-fixer "Allowed verdicts" verdicts VERDICT_SCHEMA_DRIFT)"; rc4=$?
case "$msg4" in
  VERDICT_SCHEMA_DRIFT:spec-fixer*) [ "$rc4" -ne 0 ] && _ok "tampered appendix verdict -> $msg4" \
                                                       || _fail "drift must fail (rc=0): $msg4" ;;
  *) _fail "tampered appendix verdict did not report VERDICT_SCHEMA_DRIFT: [$msg4]" ;;
esac

# 5. One missing render input -> RENDER_REQUIRED_INPUT_MISSING.
# The assertion MUST run in the main shell: `_fail`'s $_FAILURES increment
# made inside a `( ... )` subshell is discarded the instant the subshell
# exits, so a subshelled assertion can never fail the suite (proven: deleting
# the RENDER_REQUIRED_INPUT_MISSING branch from render_prompt_check still
# yielded "-- all assertions passed" with this case run inside `( ... )`).
# Capture the child's output/rc, restore state, THEN assert.
_saved_spec_path="$SPEC_PATH"
unset SPEC_PATH
err5="$(render_prompt --check spec-reviewer-claude 2>&1 >/dev/null)"
SPEC_PATH="$_saved_spec_path"
case "$err5" in
  *RENDER_REQUIRED_INPUT_MISSING:spec_path*) _ok "missing required input -> RENDER_REQUIRED_INPUT_MISSING" ;;
  *) _fail "missing required input did not report RENDER_REQUIRED_INPUT_MISSING: [$err5]" ;;
esac

# 6. One illegal phase -> ROLE_PHASE_UNSUPPORTED.
awk -F '\t' 'BEGIN{OFS="\t"} NR==1{print; next} $1=="spec-fixer"{$16="99"} {print}' \
  "$BUILD/roles.tsv" > "$NEG/badphase.tsv"
err="$(ROLE_CONTRACTS_PATH="$NEG/badphase.tsv" render_prompt --check spec-fixer 2>&1 >/dev/null)"; rc=$?
case "$err" in
  *ROLE_PHASE_UNSUPPORTED:99*) [ "$rc" -ne 0 ] && _ok "illegal phase -> ROLE_PHASE_UNSUPPORTED" \
                                                || _fail "illegal phase must fail (rc=0): $err" ;;
  *) _fail "illegal phase did not report ROLE_PHASE_UNSUPPORTED: [$err]" ;;
esac

# 7. One unresolved appendix variable -> RENDER_VARIABLE_UNRESOLVED.
cp "$PROCESS_DOC" "$NEG/unresolved-var.md"
python3 - "$NEG/unresolved-var.md" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text, n = re.subn(
    r"(<!-- BEGIN: spec-reviewer-claude -->\n# Role: spec-reviewer-claude\n)",
    r"\1\nReferences an input this appendix never declares: $BOGUS_UNDECLARED_VAR.\n",
    text, count=1)
assert n == 1, "fixture setup: spec-reviewer-claude intro not found"
open(path, "w").write(text)
PY
# Same subshell hazard as case 5 -- assert in the main shell.
_saved_process_path="$PROCESS_PATH"
PROCESS_PATH="$NEG/unresolved-var.md"
err7="$(render_prompt --check spec-reviewer-claude 2>&1 >/dev/null)"
PROCESS_PATH="$_saved_process_path"
case "$err7" in
  *RENDER_VARIABLE_UNRESOLVED*BOGUS_UNDECLARED_VAR*) _ok "unresolved appendix variable -> RENDER_VARIABLE_UNRESOLVED" ;;
  *) _fail "unresolved appendix variable did not report RENDER_VARIABLE_UNRESOLVED: [$err7]" ;;
esac

# 8. One absent upstream contract during reconstruction -> PRELAUNCH_FAILED.
# Same subshell hazard as case 5 -- run in a subshell for isolation (its own
# $REPO_ROOT/$FEATURE_FOLDER/$PROCESS_PATH), but capture output/rc OUT of it
# and assert in the main shell.
_neg8_out="$(
  RF="$BUILD/prelaunch-artifacts"; rm -rf "$RF"
  REPO_ROOT="$(mktemp -d)"; git -C "$REPO_ROOT" init -q
  ( cd "$REPO_ROOT" && : > seed && git add seed \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
  FEATURE_FOLDER="$RF"; mkdir -p "$FEATURE_FOLDER/transcripts"
  PROCESS_PATH="$PROCESS_DOC"
  # Phase 6 requires BOTH an accepted spec and an accepted plan. Satisfy the
  # spec gate so the fixture actually exercises the plan gate it targets --
  # accepted_plan, not accepted_spec, is the contract under test here.
  mkdir -p "$FEATURE_FOLDER/3-spec-review"
  : > "$FEATURE_FOLDER/3-spec-review/spec-review-summary.md"
  slug="$(basename "$RF" -artifacts)"
  : > "$(dirname "$RF")/$slug-design.md"
  # 4-plan-writing/plan-status.md is deliberately never created.
  init_orchestration_vars 6 2>&1 >/dev/null
  printf '%s\n' "rc=$?"
)"
case "$_neg8_out" in
  *PRELAUNCH_FAILED:accepted_plan*rc=1*|*rc=1*PRELAUNCH_FAILED:accepted_plan*)
    _ok "absent upstream contract -> PRELAUNCH_FAILED" ;;
  *) _fail "absent upstream contract did not report PRELAUNCH_FAILED (rc=1): [$_neg8_out]" ;;
esac

# --- Reviewer defect 1: reconstruct_durable_inputs must ACTUALLY reconstruct,
# unconditionally when a phase is given -- not silently skip. Build every
# upstream artifact Phase 7 needs and assert init_orchestration_vars 7 both
# succeeds AND leaves the durable variables genuinely populated. (Mutation-
# tested: reverting reconstruct_durable_inputs to its old dead-code form,
# which assigned nothing, makes this fail.)
(
  RF="$BUILD/recon-happy-artifacts"; rm -rf "$RF"
  RR="$(mktemp -d)"; git -C "$RR" init -q
  ( cd "$RR" && : > seed && git add seed \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
  REPO_ROOT="$RR"; FEATURE_FOLDER="$RF"; mkdir -p "$FEATURE_FOLDER/transcripts"
  PROCESS_PATH="$PROCESS_DOC"

  mkdir -p "$FEATURE_FOLDER/3-spec-review" "$FEATURE_FOLDER/4-plan-writing" "$FEATURE_FOLDER/6-implementation"
  : > "$FEATURE_FOLDER/3-spec-review/spec-review-summary.md"
  slug="$(basename "$RF" -artifacts)"
  spec_path="$(dirname "$RF")/$slug-design.md"
  : > "$spec_path"
  plan_path="$FEATURE_FOLDER/plan.md"; : > "$plan_path"
  printf 'verdict: DONE\nplan_path: %s\n' "$plan_path" > "$FEATURE_FOLDER/4-plan-writing/plan-status.md"
  printf 'verdict: DONE\nverification: PASS\n' > "$FEATURE_FOLDER/6-implementation/implementer-status.md"
  printf 'implementation_base_sha: cafef00d\n\n' > "$FEATURE_FOLDER/RUN_LOG.md"

  init_orchestration_vars 7 >/dev/null 2>&1
  rc=$?
  printf '%s\n' "rc=$rc" "SPEC_PATH=$SPEC_PATH" "PLAN_PATH=$PLAN_PATH" \
    "IMPLEMENTATION_BASE_SHA=$IMPLEMENTATION_BASE_SHA" \
    "IMPLEMENTATION_FINAL_SHA=$IMPLEMENTATION_FINAL_SHA" \
    "CONTEXT7_POLICY=$CONTEXT7_POLICY"
) > "$BUILD/recon-happy.out"
recon_out="$(cat "$BUILD/recon-happy.out")"
assert_contains "rc=0" "$BUILD/recon-happy.out" "init_orchestration_vars 7 succeeds once every upstream contract exists"
case "$recon_out" in
  *SPEC_PATH=*-design.md*) _ok "reconstruction actually sets SPEC_PATH (not skipped)" ;;
  *) _fail "SPEC_PATH was not reconstructed: [$recon_out]" ;;
esac
case "$recon_out" in
  *PLAN_PATH=*/plan.md*) _ok "reconstruction actually sets PLAN_PATH (not skipped)" ;;
  *) _fail "PLAN_PATH was not reconstructed: [$recon_out]" ;;
esac
case "$recon_out" in
  *IMPLEMENTATION_BASE_SHA=cafef00d*) _ok "reconstruction reads IMPLEMENTATION_BASE_SHA from RUN_LOG (not skipped)" ;;
  *) _fail "IMPLEMENTATION_BASE_SHA was not reconstructed: [$recon_out]" ;;
esac
case "$recon_out" in
  *IMPLEMENTATION_FINAL_SHA=*) [ -n "$(printf '%s' "$recon_out" | "$GREP_BIN" -oE 'IMPLEMENTATION_FINAL_SHA=.+')" ] \
    && _ok "reconstruction sets IMPLEMENTATION_FINAL_SHA (current HEAD)" \
    || _fail "IMPLEMENTATION_FINAL_SHA is empty: [$recon_out]" ;;
  *) _fail "IMPLEMENTATION_FINAL_SHA was not reconstructed: [$recon_out]" ;;
esac
case "$recon_out" in
  *CONTEXT7_POLICY=best-effort*|*CONTEXT7_POLICY=required*) _ok "reconstruction sets CONTEXT7_POLICY (not skipped)" ;;
  *) _fail "CONTEXT7_POLICY was not reconstructed: [$recon_out]" ;;
esac

# --- Task 3 Step 6: bootstrap_runtime -- six named outcomes ----------------
# shellcheck source=lib/v2_fixtures.sh
source "$REPO_TOP/tests/lib/v2_fixtures.sh"
init_v2_fixture

# 1. Fresh extraction -> BOOTSTRAP_OK, all four generated files plus manifest.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
rc=0; out="$(bootstrap_runtime 2>"$BUILD/b1.err")" || rc=$?
assert_rc 0 "$rc" "1 fresh: bootstrap_runtime succeeds"
assert_eq "BOOTSTRAP_OK" "$out" "1 fresh: reports BOOTSTRAP_OK"
for f in develop-it-runtime.sh role-contracts.tsv policy.tsv publish-status manifest.sha256; do
  assert_exists "$RUNTIME_DIR/$f" "1 fresh: writes $f"
done

# 2. Idempotent rerun -> BOOTSTRAP_REUSED, no new staging directory.
rc=0; out="$(bootstrap_runtime 2>"$BUILD/b2.err")" || rc=$?
assert_rc 0 "$rc" "2 idempotent: rerun succeeds"
assert_eq "BOOTSTRAP_REUSED" "$out" "2 idempotent: reports BOOTSTRAP_REUSED"
assert_glob_count 0 "$ORCHESTRATION_DIR/.runtime.tmp.*" "2 idempotent: creates no staging directory"

# 3. Interrupted extraction -> BOOTSTRAP_INTERRUPTED, never a usable runtime/.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
rc=0
BOOTSTRAP_FAIL_AFTER=1 bootstrap_runtime >"$BUILD/b3.out" 2>"$BUILD/b3.err" || rc=$?
assert_rc 1 "$rc" "3 interrupted: bootstrap_runtime fails"
assert_contains "BOOTSTRAP_INTERRUPTED" "$BUILD/b3.err" "3 interrupted: names itself"
assert_not_exists "$RUNTIME_DIR" "3 interrupted: never leaves a usable runtime/"

# 4. A final runtime that exists but fails to verify -> RUNTIME_MANIFEST_INVALID.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
bootstrap_runtime >/dev/null 2>&1
printf 'tampered\n' >> "$RUNTIME_DIR/role-contracts.tsv"
rc=0; bootstrap_runtime >"$BUILD/b4.out" 2>"$BUILD/b4.err" || rc=$?
assert_rc 1 "$rc" "4 corrupt final: bootstrap_runtime fails closed"
assert_contains "RUNTIME_MANIFEST_INVALID" "$BUILD/b4.err" "4 corrupt final: names itself"

# 5. Race lost to a VALID winner -> BOOTSTRAP_RACE_LOST_VALID. Build a second,
#    independently valid staging directory and publish it against the winner
#    bootstrap_runtime already produced -- exercises _bootstrap_publish's
#    race branch directly, since a genuine concurrent race cannot be forced
#    deterministically from a single-process test.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
bootstrap_runtime >/dev/null 2>&1
tmp5="$ORCHESTRATION_DIR/.runtime.tmp.race-valid"
mkdir -p "$tmp5"
_bootstrap_extract_all "$tmp5" >/dev/null 2>&1
rc=0; out5="$(_bootstrap_publish "$tmp5" 2>"$BUILD/b5.err")" || rc=$?
assert_rc 0 "$rc" "5 race-lost-valid: publish against a valid winner succeeds"
assert_eq "BOOTSTRAP_RACE_LOST_VALID" "$out5" "5 race-lost-valid: reports BOOTSTRAP_RACE_LOST_VALID"
assert_not_exists "$tmp5" "5 race-lost-valid: losing directory moved out of .orchestration/"
assert_glob_count 1 "$ORCHESTRATION_DIR/quarantine/$(basename "$tmp5")"'*' \
  "5 race-lost-valid: losing directory is quarantined, not deleted or merged"

# 6. Race lost to an INVALID winner -> BOOTSTRAP_RACE_LOST_INVALID (distinct
#    from case 4: the failure is discovered while publishing, not at entry).
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
bootstrap_runtime >/dev/null 2>&1
printf 'tampered\n' >> "$RUNTIME_DIR/policy.tsv"
tmp6="$ORCHESTRATION_DIR/.runtime.tmp.race-invalid"
mkdir -p "$tmp6"
_bootstrap_extract_all "$tmp6" >/dev/null 2>&1
rc=0; out6="$(_bootstrap_publish "$tmp6" 2>"$BUILD/b6.err")" || rc=$?
assert_rc 1 "$rc" "6 race-lost-invalid: publish against an invalid winner fails"
assert_contains "BOOTSTRAP_RACE_LOST_INVALID" "$BUILD/b6.err" "6 race-lost-invalid: names itself"
assert_not_exists "$tmp6" "6 race-lost-invalid: losing directory still moved out, not left dangling"

# --- Task 3 Step 6: shell-rule assertions (spec §7.2) -----------------------

# The generated runtime file is bit-for-bit the extracted cookbook: it must
# execute zero top-level commands when sourced (same probe check_01 uses).
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
bootstrap_runtime >/dev/null 2>&1
_runtime_sidelog="$BUILD/runtime-sideeffects.txt"
env -i bash --noprofile --norc "$REPO_TOP/tests/lib/sideeffects.sh" \
  "$RUNTIME_DIR/develop-it-runtime.sh" > "$_runtime_sidelog" 2>&1
_runtime_side_rc=$?
if [ "$_runtime_side_rc" -eq 0 ] && [ ! -s "$_runtime_sidelog" ]; then
  _ok "the generated runtime has no top-level phase action"
else
  _fail "the generated runtime executed a top-level action or failed to source"
fi

# --- F5: enumerate EVERY phase-opening snippet (one with a numeric
# `init_orchestration_vars <phase>` call), not just prove >=1 occurrence of
# the source line somewhere in the document. Reuses extract.py's own block
# parser rather than re-implementing fence detection here.
_phase_snippet_report="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$REPO_TOP/tests/lib" "$PYTHON_BIN" - <<'PY'
import re
import extract

total = 0
missing = []
for kind, language, line, body in extract.blocks():
    if kind != "snippet":
        continue
    text = "\n".join(body)
    if not re.search(r'\binit_orchestration_vars\s+[0-9]', text):
        continue
    total += 1
    if "bootstrap_runtime" not in text or 'source "$RUNTIME_DIR/develop-it-runtime.sh"' not in text:
        missing.append(str(line))
print(total)
print(" ".join(missing))
PY
)"
_phase_snippet_total="$(printf '%s\n' "$_phase_snippet_report" | sed -n '1p')"
_phase_snippet_missing="$(printf '%s\n' "$_phase_snippet_report" | sed -n '2p')"
if [ "${_phase_snippet_total:-0}" -ge 1 ] 2>/dev/null; then
  _ok "found $_phase_snippet_total phase-opening snippet(s) to enumerate"
else
  _fail "zero phase-opening snippets found -- the enumeration checked nothing"
fi
assert_eq "" "$_phase_snippet_missing" \
  "every phase-opening snippet bootstraps and sources the verified final runtime"

# --- F5: widen the 'local' detector to the STATED rule (split a 'local'
# declaration from any assignment that MASKS $? or REFERENCES a sibling
# declared earlier in the SAME statement) -- not just the narrower
# `local X=$(...)` shape.
local_mask_hits=$(python3 - "$PROCESS_DOC" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
hits = 0
for m in re.finditer(r'^[ \t]*local\s+(.+)$', text, re.MULTILINE):
    decl = m.group(1)
    tokens = re.findall(r'([A-Za-z_][A-Za-z0-9_]*)=("(?:[^"\\]|\\.)*"|\S*)|([A-Za-z_][A-Za-z0-9_]*)(?![=])', decl)
    declared = []
    for name_eq, value, bare_name in tokens:
        name = name_eq or bare_name
        if not name:
            continue
        if name_eq:
            if re.search(r'\$\?', value):
                hits += 1  # local NAME=$? -- masks the preceding command's exit status
            elif re.match(r'^\$\(', value):
                hits += 1  # local NAME=$(...) -- masks the command substitution's exit status
            for prior in declared:
                if re.search(r'\$\{?' + re.escape(prior) + r'\b', value):
                    hits += 1  # local a=.. b=$a -- b references a sibling from the SAME statement
        declared.append(name)
print(hits)
PY
)
assert_eq 0 "$local_mask_hits" \
  "a 'local' declaration is split from any assignment that masks \$? or references a sibling in the same statement"

pipeline_global_hits=$(grep -cE '\| *(while|read) ' "$BUILD/cookbook.sh" || true)
assert_eq 0 "$pipeline_global_hits" \
  "no helper relies on a pipeline/subshell to preserve a global result variable"

# --- F5: widen the trailing-&&-finalizer detector beyond the `[ ... ] &&`
# shape to ANY top-level `cmd && cmd` (bracket test, `test`, `[[ ]]`, or two
# plain commands) as the literal last statement before a function's closing
# brace -- the documented anti-pattern (see the doc's own "An `if` is
# required, not `[ -f … ] && mv`" comment) generalizes to any such pair.
trailing_and_hits=$(python3 - "$BUILD/cookbook.sh" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
hits = 0
for i, line in enumerate(lines):
    if line.strip() == "}" and i > 0:
        prev = lines[i - 1].strip()
        if not prev or prev.startswith(("if ", "elif ", "while ", "until ", "#")):
            continue
        # A bare "cmd &&" with nothing after it is itself a syntax error, so
        # it can never occur in code that actually sources -- require
        # trailing content to distinguish a real finalizer from that.
        if re.search(r'&&\s*\S', prev):
            hits += 1
print(hits)
PY
)
assert_eq 0 "$trailing_and_hits" \
  "no publication ends with a conditional && as its final statement"

# --- F5: widen the set -e detector to also catch the long-option spelling
# `set -o errexit`, not just a short `-e`-containing flag cluster.
set_e_hits=$(( $(grep -cE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)' "$BUILD/cookbook.sh" || true) \
             + $(grep -cE '^[[:space:]]*set\b.*-o[[:space:]]+errexit\b' "$BUILD/cookbook.sh" || true) ))
assert_eq 0 "$set_e_hits" "no runtime block enables set -e (short or -o errexit form)"

dupe_defs=""
for fn in $(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' "$BUILD/cookbook.sh" | sed -E 's/\(\) \{$//'); do
  fn_count=$(grep -cE "^${fn}\\(\\) \\{" "$PROCESS_DOC" || true)
  if [ "$fn_count" -gt 1 ]; then
    dupe_defs="$dupe_defs $fn($fn_count)"
  fi
done
assert_eq "" "$dupe_defs" \
  "no phase block copies a runtime helper body (every helper is defined exactly once)"

# --- Code review fixes: F1(a) every _bootstrap_extract_all failure path names
# itself, and surfaces the failing command's own stderr ---------------------
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
_saved_process_repo_root="$PROCESS_REPO_ROOT"

# 1. Missing extractor (e.g. a checkout whose tests/ directory is absent):
#    empty stdout/stderr was the bug -- now must be a named token, and the
#    interpreter's own "can't open file" diagnostic must ride along.
PROCESS_REPO_ROOT="$(mktemp -d)"   # a repo with no tests/lib/extract.py at all
rc=0; out="$(bootstrap_runtime 2>"$BUILD/f1a-missing.err")" || rc=$?
PROCESS_REPO_ROOT="$_saved_process_repo_root"
assert_rc 1 "$rc" "F1a missing-extractor: bootstrap_runtime fails"
assert_eq "" "$out" "F1a missing-extractor: nothing on stdout"
assert_contains "BOOTSTRAP_IO_ERROR" "$BUILD/f1a-missing.err" "F1a missing-extractor: names itself with a token"
[ -s "$BUILD/f1a-missing.err" ] && [ "$(wc -l < "$BUILD/f1a-missing.err")" -ge 2 ]   && _ok "F1a missing-extractor: the interpreter's own diagnostic rides along with the token"   || _fail "F1a missing-extractor: stderr is just the bare token, no underlying diagnostic: $(cat "$BUILD/f1a-missing.err")"

# 2. Extractor present but exits non-zero (a malformed process document, or
#    any other extractor failure): its own stderr (a SystemExit message, a
#    traceback, ...) must be surfaced, not swallowed into a discarded temp file.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
_fake_repo="$(mktemp -d)"
mkdir -p "$_fake_repo/tests/lib"
printf '#!/usr/bin/env python3
import sys
sys.stderr.write("BOGUS_EXTRACTOR_FAILURE: synthetic\n")
sys.exit(1)
'   > "$_fake_repo/tests/lib/extract.py"
PROCESS_REPO_ROOT="$_fake_repo"
rc=0; out="$(bootstrap_runtime 2>"$BUILD/f1a-nonzero.err")" || rc=$?
PROCESS_REPO_ROOT="$_saved_process_repo_root"
assert_rc 1 "$rc" "F1a extractor-non-zero: bootstrap_runtime fails"
assert_contains "BOOTSTRAP_IO_ERROR" "$BUILD/f1a-nonzero.err" "F1a extractor-non-zero: names itself with a token"
assert_contains "BOGUS_EXTRACTOR_FAILURE" "$BUILD/f1a-nonzero.err"   "F1a extractor-non-zero: the extractor's own stderr is surfaced, not buried"
rm -rf "$_fake_repo"

# --- F1(b): the GENERATOR is pinned in the manifest, not just the document --
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
bootstrap_runtime >/dev/null 2>&1
assert_present '^extractor_sha256=[0-9a-f]{64}$' "$RUNTIME_DIR/manifest.sha256"   "F1b: manifest records the extractor's own SHA-256"
# Editing tests/lib/extract.py with the document UNCHANGED must invalidate
# the existing runtime: copy the real extractor to a scratch repo, mutate
# it, and confirm a runtime whose manifest pins the ORIGINAL extractor hash
# no longer verifies against the mutated one.
_pin_repo="$(mktemp -d)"
mkdir -p "$_pin_repo/tests/lib"
cp "$REPO_TOP/tests/lib/extract.py" "$_pin_repo/tests/lib/extract.py"
printf '
# harmless trailing comment -- changes the extractor bytes only
'   >> "$_pin_repo/tests/lib/extract.py"
PROCESS_REPO_ROOT="$_pin_repo"
rc=0; _bootstrap_verify_manifest "$RUNTIME_DIR" || rc=$?
PROCESS_REPO_ROOT="$_saved_process_repo_root"
assert_rc 1 "$rc"   "F1b: a runtime verifies against the extractor that built it, not a since-edited one"
rm -rf "$_pin_repo"

# --- F2: BOOTSTRAP_OK verifies the just-published runtime before reporting --
# A staging directory that is fully valid right up until publish, then
# corrupted in the instant BEFORE _bootstrap_publish is called, must fail on
# THIS call (Phase -1), not be deferred to the next phase's BOOTSTRAP_REUSED.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
tmp_f2="$ORCHESTRATION_DIR/.runtime.tmp.corrupt-before-publish"
mkdir -p "$tmp_f2"
_bootstrap_extract_all "$tmp_f2" >/dev/null 2>&1
printf 'tampered
' >> "$tmp_f2/policy.tsv"   # corrupt AFTER extraction, BEFORE publish
rc=0; out="$(_bootstrap_publish "$tmp_f2" 2>"$BUILD/f2.err")" || rc=$?
assert_rc 1 "$rc" "F2: publishing a since-corrupted staging directory fails immediately"
assert_contains "RUNTIME_MANIFEST_INVALID" "$BUILD/f2.err" "F2: names itself"
assert_eq "" "$out" "F2: never reports BOOTSTRAP_OK for a runtime that does not verify"

# The write-loop fix (short os.write can truncate a file whose hash the
# manifest would then certify): round-trip a payload through
# _bootstrap_atomic_write and confirm every byte survives intact. This
# exercises the actual deployed code path (unlike a mocked unit test), even
# though forcing a genuine short write against a regular file is not
# reliably reproducible in a sandboxed test -- see the mocked-loop self-check
# immediately below for a deterministic proof of the retry pattern itself.
_wl_src="$(mktemp)"; _wl_dst="$(mktemp -u)"
head -c 5000000 /dev/urandom > "$_wl_src"
_bootstrap_atomic_write "$_wl_dst" 600 < "$_wl_src"
assert_eq "$(sha256sum < "$_wl_src")" "$(sha256sum < "$_wl_dst")"   "_bootstrap_atomic_write round-trips a 5MB payload byte-for-byte"
rm -f "$_wl_src" "$_wl_dst"

# Deterministic proof that the retry-LOOP shape (as deployed in both
# _bootstrap_atomic_write and publish-status) is what makes a short write
# safe: monkeypatch os.write to always return a short count and confirm the
# loop still delivers every byte, where a single-call `os.write(fd, data)`
# would silently truncate.
_loop_proof="$(python3 - <<'PY'
import os

written = bytearray()

def fake_write(fd, data):
    # Simulate a short write: never accept more than 3 bytes at a time.
    chunk = bytes(data)[:3]
    written.extend(chunk)
    return len(chunk)

real_write = os.write
os.write = fake_write
try:
    payload = b"x" * 97
    view = memoryview(payload)
    while view:
        n = os.write(1234, view)
        view = view[n:]
finally:
    os.write = real_write

print("OK" if bytes(written) == payload else "TRUNCATED")
PY
)"
assert_eq "OK" "$_loop_proof"   "the write-retry loop delivers every byte even when each os.write call is short"

# --- F3: the orphan sweep must not sweep a LIVE concurrent bootstrap's -----
# staging directory (only genuinely stale ones, by age).
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
live_orphan="$ORCHESTRATION_DIR/.runtime.tmp.concurrent-live"
mkdir -p "$live_orphan"
: > "$live_orphan/develop-it-runtime.sh"   # as if another bootstrap is mid-write
stale_orphan="$ORCHESTRATION_DIR/.runtime.tmp.stale"
mkdir -p "$stale_orphan"
touch -d '@1' "$stale_orphan"   # ancient mtime -- genuinely abandoned

bootstrap_runtime >/dev/null 2>&1
assert_exists "$live_orphan"   "F3: a fresh (live-looking) staging directory is NOT swept out from under a concurrent bootstrap"
assert_not_exists "$stale_orphan" "F3: a genuinely stale orphan is still swept"
assert_glob_count 1 "$ORCHESTRATION_DIR/quarantine/.runtime.tmp.stale"'*'   "F3: only the stale orphan was quarantined"
rm -rf "$live_orphan"

# --- F4: prove RENAME_NOREPLACE itself, not merely "target dir non-empty" --
# Plain rename(2) already refuses to replace a NON-EMPTY directory, so racing
# against one (as cases 5/6 above do) cannot distinguish RENAME_NOREPLACE
# from that unrelated behaviour. Race against an EMPTY existing runtime/,
# which plain rename(2) WOULD happily replace -- only the flag stops it.
rm -rf "$ORCHESTRATION_DIR"; mkdir -p "$ORCHESTRATION_DIR"
mkdir -p "$RUNTIME_DIR"   # empty target
tmp_f4="$ORCHESTRATION_DIR/.runtime.tmp.empty-target-race"
mkdir -p "$tmp_f4"
rc=0
_bootstrap_rename_noreplace "$tmp_f4" "$RUNTIME_DIR" || rc=$?
assert_rc 1 "$rc"   "F4: renaming onto an EMPTY existing runtime/ still fails -- proves RENAME_NOREPLACE, not just ENOTEMPTY"
assert_exists "$tmp_f4" "F4: the staging directory is untouched on refusal"
rm -rf "$tmp_f4" "$RUNTIME_DIR"

# Short-write guard on the GENERATED artifacts, not on a copy of the pattern.
# A single os.write(fd, data) can return short, leaving a truncated file whose
# hash the manifest then certifies as correct. No behavioural test reaches this:
# a 5MB write to a regular Linux file never short-writes, and neither helper
# takes an injectable fd. Greping for a literal is normally worthless -- it
# earns its place here precisely because the behaviour is unobservable from
# outside, so this is the only thing standing between a reversion and silence.
python3 "$REPO_TOP/tests/lib/extract.py" cookbook >/dev/null
python3 "$REPO_TOP/tests/lib/extract.py" publisher >/dev/null
for _artifact in "$BUILD/cookbook.sh" "$BUILD/publish-status"; do
  _loops=$(grep -c 'while view:' "$_artifact" || true)
  assert_eq 1 "$_loops" "$(basename "$_artifact") writes through a short-write retry loop"
  _bare=$(grep -cE '^[[:space:]]*os\.write\(fd, data\)[[:space:]]*$' "$_artifact" || true)
  assert_eq 0 "$_bare" "$(basename "$_artifact") has no unchecked single os.write"
done

# --- Task 4 Step 1/3: allocate_attempt -- exact identity, monotonic attempts,
# collision safety, lock serialization, and the launched:false prelaunch
# record ----------------------------------------------------------------------
python3 "$REPO_TOP/tests/lib/extract.py" roles > "$BUILD/roles.tsv"

_aa_dir="$(mktemp -d)"
REPO_ROOT="$_aa_dir/target"; mkdir -p "$REPO_ROOT"
git -C "$REPO_ROOT" init -q
( cd "$REPO_ROOT" && : > seed && git add seed \
  && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
FEATURE_FOLDER="$_aa_dir/ff"
ORCHESTRATION_DIR="$FEATURE_FOLDER/.orchestration"
mkdir -p "$ORCHESTRATION_DIR" "$FEATURE_FOLDER/transcripts"
ROLE_CONTRACTS_PATH="$BUILD/roles.tsv"
: > "$FEATURE_FOLDER/RUN_LOG.md"

allocate_attempt -1 0 preflight-claude
assert_eq "pm1-i00-preflight-claude" "$LOGICAL_DISPATCH_ID" \
  "allocate_attempt -1 0 preflight-claude: logical_dispatch_id"
assert_eq "pm1-i00-preflight-claude-a01" "$DISPATCH_ID" \
  "allocate_attempt -1 0 preflight-claude: dispatch_id"

allocate_attempt 5 2 plan-fixer
assert_eq "p05-i02-plan-fixer" "$LOGICAL_DISPATCH_ID" \
  "allocate_attempt 5 2 plan-fixer: logical_dispatch_id"
assert_eq "p05-i02-plan-fixer-a01" "$DISPATCH_ID" \
  "allocate_attempt 5 2 plan-fixer: dispatch_id (first attempt)"
_aa_first_dir="$ATTEMPT_DIR"

allocate_attempt 5 2 plan-fixer
assert_eq "p05-i02-plan-fixer-a02" "$DISPATCH_ID" \
  "a second attempt of the same logical dispatch gets -a02"
assert_eq 2 "$ATTEMPT" "\$ATTEMPT is the raw (unpadded) attempt number"
if [ "$_aa_first_dir" != "$ATTEMPT_DIR" ]; then
  _ok "the second attempt gets its own directory, never reusing the first"
else
  _fail "the second attempt reused the first attempt's directory"
fi
assert_exists "$_aa_first_dir" "the FIRST attempt's directory still exists (never moved/deleted)"

assert_eq 3 "$("$GREP_BIN" -c 'event=ATTEMPT_ALLOCATED$' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "three allocations recorded three ATTEMPT_ALLOCATED events"
assert_eq 3 "$("$GREP_BIN" -c '^launched: *false$' "$FEATURE_FOLDER/RUN_LOG.md" || true)" \
  "every allocation records launched: false (this is what a prelaunch failure leaves as its terminal record)"

# allocate_attempt sets EXACTLY the nine documented variables -- in
# particular it must never clobber the caller's own $ITERATION.
ITERATION=sentinel-untouched
allocate_attempt 5 2 plan-fixer
assert_eq "sentinel-untouched" "$ITERATION" "allocate_attempt does not set/clobber \$ITERATION"
for v in PHASE_TOKEN LOGICAL_DISPATCH_ID ATTEMPT DISPATCH_ID ATTEMPT_DIR \
         STATUS_PATH STDOUT_PATH STDERR_PATH SNAPSHOT_DIR; do
  [ -n "${!v:-}" ] && _ok "allocate_attempt sets \$$v" || _fail "allocate_attempt left \$$v unset"
done
unset ITERATION

# Collision safety: if the computed attempt directory was somehow already
# created on disk out-of-band, allocate_attempt must fail loudly rather than
# merge into it -- this is the backstop behind the RUN_LOG-derived number.
_aa_next_num="$(next_unused_attempt p05-i02-plan-fixer)"
_aa_next_dispatch="p05-i02-plan-fixer-a$(printf '%02d' "$_aa_next_num")"
_aa_next_dir="$(role_attempt_dir plan-fixer "$_aa_next_dispatch")"
mkdir -p "$_aa_next_dir"
rc=0
allocate_attempt 5 2 plan-fixer >"$BUILD/aa-collision.out" 2>"$BUILD/aa-collision.err" || rc=$?
assert_rc 1 "$rc" "allocate_attempt fails when its computed attempt directory already exists"
assert_contains "ATTEMPT_DIR_COLLISION" "$BUILD/aa-collision.err" "collision failure names itself"

# Lock serialization: allocate_attempt must actually WAIT for the run-log
# lock, not merely define lock helpers nobody calls.
mkdir -p "$ORCHESTRATION_DIR/run-log.lock.d"   # simulate a lock held by someone else
rm -f "$BUILD/aa-lock-done"
( allocate_attempt 5 4 plan-fixer >/dev/null 2>&1; : > "$BUILD/aa-lock-done" ) &
_aa_bg_pid=$!
sleep 0.3
if [ -f "$BUILD/aa-lock-done" ]; then
  _fail "allocate_attempt proceeded despite a run-log lock held by someone else"
else
  _ok "allocate_attempt blocks while the run-log lock is held by someone else"
fi
rmdir "$ORCHESTRATION_DIR/run-log.lock.d"
wait "$_aa_bg_pid"
assert_exists "$BUILD/aa-lock-done" "allocate_attempt proceeds once the lock is released"
rm -f "$BUILD/aa-lock-done"

# Code review fix #5: attempt identity is fixed two-digit by design; a 100th
# attempt must fail loudly (ATTEMPT_OVERFLOW), never silently produce a
# 3-digit "-a100" that then stops matching next_unused_attempt's own regex
# and collides with the pre-existing a99 directory.
: > "$FEATURE_FOLDER/RUN_LOG.md"
printf 'dispatch_id:              p05-i02-plan-fixer-a99

' >> "$FEATURE_FOLDER/RUN_LOG.md"
rc=0
out="$(next_unused_attempt p05-i02-plan-fixer 2>"$BUILD/aa-overflow.err")" || rc=$?
assert_rc 1 "$rc" "next_unused_attempt refuses to derive a 100th attempt"
assert_contains "ATTEMPT_OVERFLOW:p05-i02-plan-fixer" "$BUILD/aa-overflow.err"   "attempt-overflow failure names the logical dispatch"
rc=0
allocate_attempt 5 2 plan-fixer >/dev/null 2>"$BUILD/aa-overflow2.err" || rc=$?
assert_rc 1 "$rc" "allocate_attempt itself fails (not just next_unused_attempt in isolation) at the 100th attempt"
assert_contains "ATTEMPT_OVERFLOW" "$BUILD/aa-overflow2.err" "allocate_attempt surfaces the overflow token, not a bare non-zero exit"

rm -rf "$_aa_dir"

# --- Task 4 Step 4/5: the generated publish-status CLI -----------------------
python3 "$REPO_TOP/tests/lib/extract.py" publisher >/dev/null
_ps="$BUILD/publish-status"
_ps_dir="$(mktemp -d)"
_ps_ff="$_ps_dir/ff"; mkdir -p "$_ps_ff"
cat > "$_ps_dir/roles.tsv" <<'TSV'
role	vendor	model	effort	timeout_minutes	mutates	long_running	may_spawn_children	required_inputs	optional_inputs	status_template	outputs	verdicts	required_status_fields	checkpoint_kind	phases
spec-reviewer-claude	claude	claude-opus-5	—	60	no	yes	no	feature_folder;iteration;spec_path	—	x	verdict;findings	PASS;CHANGES_REQUESTED	common_v2;blockers;majors;minors;findings	review	3
TSV

_ps_common=(--contracts "$_ps_dir/roles.tsv" --role spec-reviewer-claude \
  --dispatch-id p03-i01-spec-reviewer-claude-a01 \
  --logical-dispatch-id p03-i01-spec-reviewer-claude \
  --phase 3 --iteration 01 --attempt 01 --allowed-root "$_ps_ff")

_ps_baseline() {
  cat <<EOF
schema_version: 2
dispatch_id: p03-i01-spec-reviewer-claude-a01
logical_dispatch_id: p03-i01-spec-reviewer-claude
role: spec-reviewer-claude
phase: 3
iteration: 01
attempt: 01
verdict: PASS
reason: null
published_at: 2026-08-29T12:00:00Z
artifact_revision: null
output_count: 0
checkpoint_path: null
blockers: 0
majors: 0
minors: 0
findings: none
EOF
}

rm -f "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >"$BUILD/ps-happy.out" 2>"$BUILD/ps-happy.err" || rc=$?
assert_rc 0 "$rc" "publish-status: valid STATUS with reason: null publishes successfully"
assert_exists "$_ps_ff/STATUS.md" "publish-status: the final STATUS file was created"
assert_contains "reason: null" "$_ps_ff/STATUS.md" "publish-status: reason: null is a valid, accepted value"

rm -f "$_ps_ff/STATUS.md"
rc=0
( _ps_baseline; echo "x_note: hello" ) | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-xok.err" || rc=$?
assert_rc 0 "$rc" "publish-status: an x_-namespaced extension field is accepted"

rm -f "$_ps_ff/STATUS.md"
rc=0
( _ps_baseline; echo "blockers: 1" ) | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-dup.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a duplicate key is rejected"
assert_contains "STATUS_DUPLICATE_KEY" "$BUILD/ps-dup.err" "duplicate-key failure names itself"

rm -f "$_ps_ff/STATUS.md"
rc=0
( _ps_baseline; echo "bogus: 1" ) | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-unk.err" || rc=$?
assert_rc 1 "$rc" "publish-status: an unnamespaced unknown key is rejected"
assert_contains "STATUS_UNKNOWN_FIELD" "$BUILD/ps-unk.err" "unnamespaced-unknown-key failure names itself"

rm -f "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | grep -v '^published_at' | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-miss-common.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a missing common field is rejected"
assert_contains "STATUS_MISSING_FIELD:published_at" "$BUILD/ps-miss-common.err" \
  "missing-common-field failure names the field"

rm -f "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | grep -v '^findings' | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-miss-role.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a missing role-specific required field is rejected"
assert_contains "STATUS_MISSING_ROLE_FIELD:findings" "$BUILD/ps-miss-role.err" \
  "missing-role-field failure names the field"

rm -f "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | sed 's/-a01$/-a02/' | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-wrongid.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a dispatch_id that disagrees with --dispatch-id is rejected"
assert_contains "STATUS_DISPATCH_ID_MISMATCH" "$BUILD/ps-wrongid.err" "wrong-dispatch-id failure names itself"

rm -f "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | sed 's/^verdict: PASS/verdict: MAYBE/' | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-verdict.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a verdict outside the role's registry-declared set is rejected"
assert_contains "STATUS_BAD_VERDICT" "$BUILD/ps-verdict.err" "invalid-verdict failure names itself"

rm -f "$_ps_ff/STATUS.md"
rc=0
( _ps_baseline | sed "s#^output_count: 0#output_count: 2#; \
    s#^checkpoint_path: null#output_01: $_ps_ff/a.md\ncheckpoint_path: null#" ) \
  | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-missout.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a missing output_NN index (count=2, only output_01) is rejected"
assert_contains "STATUS_MISSING_OUTPUT:output_02" "$BUILD/ps-missout.err" "missing-output failure names the index"

rm -f "$_ps_ff/STATUS.md"
rc=0
( _ps_baseline | sed "s#^output_count: 0#output_count: 1#; \
    s#^checkpoint_path: null#output_01: $_ps_ff/a.md\noutput_02: $_ps_ff/b.md\ncheckpoint_path: null#" ) \
  | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-extraout.err" || rc=$?
assert_rc 1 "$rc" "publish-status: an extra undeclared output_NN (count=1, output_01 and output_02) is rejected"
assert_contains "STATUS_EXTRA_OUTPUT:output_02" "$BUILD/ps-extraout.err" "extra-output failure names the index"

rm -f "$_ps_ff/STATUS.md"
rc=0
( _ps_baseline | sed "s#^output_count: 0#output_count: 1#; \
    s#^checkpoint_path: null#output_01: /etc/passwd\ncheckpoint_path: null#" ) \
  | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-outside.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a declared output path outside every --allowed-root is rejected"
assert_contains "STATUS_OUTPUT_OUTSIDE_ROOT" "$BUILD/ps-outside.err" "outside-root failure names itself"

: > "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-exists.err" || rc=$?
assert_rc 1 "$rc" "publish-status: refuses to publish when the final STATUS path already exists"
assert_contains "STATUS_ALREADY_EXISTS" "$BUILD/ps-exists.err" "existing-final-STATUS failure names itself"
rm -f "$_ps_ff/STATUS.md"

rc=0
_ps_baseline | PUBLISH_STATUS_FAIL_RENAME=1 python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >"$BUILD/ps-rename.out" 2>"$BUILD/ps-rename.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a rename failure is reported, not silently swallowed"
assert_contains "classification=PUBLICATION_LOST" "$BUILD/ps-rename.out" "rename failure reports classification=PUBLICATION_LOST"
assert_contains "tmp_path=" "$BUILD/ps-rename.out" "rename failure reports tmp_path"
assert_contains "tmp_sha256=" "$BUILD/ps-rename.out" "rename failure reports tmp_sha256"
assert_not_exists "$_ps_ff/STATUS.md" "rename failure never leaves a final STATUS file behind"
assert_exists "$_ps_ff/STATUS.md.tmp.p03-i01-spec-reviewer-claude-a01" \
  "rename failure preserves the temp file as diagnostics"
rm -f "$_ps_ff/STATUS.md.tmp."*

_ps_tmp="$_ps_ff/STATUS.md.tmp.p03-i01-spec-reviewer-claude-a01"
printf 'leaked-token: abc123\nsome-other-field: fine\n' > "$_ps_tmp"
rc=0
_ps_baseline | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >"$BUILD/ps-sibling.out" 2>"$BUILD/ps-sibling.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a pre-existing sibling temp (no final) is refused, not overwritten"
assert_contains "STATUS_TMP_SIBLING_EXISTS" "$BUILD/ps-sibling.err" "sibling-temp failure names itself"
assert_contains "classification=PUBLICATION_LOST" "$BUILD/ps-sibling.out" "sibling temp is reported as PUBLICATION_LOST evidence"
assert_eq "leaked-token: abc123" "$(head -1 "$_ps_tmp")" \
  "the pre-existing sibling temp's content is left untouched, not overwritten"
assert_absent "abc123" "$BUILD/ps-sibling.out" \
  "a secret-shaped key in the preserved temp is redacted before it is ever logged"
rm -f "$_ps_tmp"

rc=0
_ps_baseline | PUBLISH_STATUS_CORRUPT_AFTER_RENAME=1 python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >"$BUILD/ps-reread.out" 2>"$BUILD/ps-reread.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a final file that fails reread validation is rejected, not accepted"
assert_contains "STATUS_REREAD_INVALID" "$BUILD/ps-reread.err" "reread-mismatch failure names itself"
assert_contains "classification=PUBLICATION_LOST" "$BUILD/ps-reread.out" "reread mismatch reports PUBLICATION_LOST"
assert_not_exists "$_ps_ff/STATUS.md" \
  "reread mismatch never leaves the (invalid) final content sitting at the canonical STATUS path"
rm -f "$_ps_ff/STATUS.md.tmp."*

mkdir -p "$_ps_ff/locked" && chmod 555 "$_ps_ff/locked"
rc=0
_ps_baseline | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/locked/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-tmpfail.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a temp-file creation failure (permission denied) is reported"
assert_contains "STATUS_TMP_CREATE_FAILED" "$BUILD/ps-tmpfail.err" "temp-create failure names itself"
chmod 755 "$_ps_ff/locked"; rm -rf "$_ps_ff/locked"

# Code review fix #6a: bare int() accepts "0_0" (Python digit-group
# separators), so output_count must be validated with a strict digit-only
# check first.
rm -f "$_ps_ff/STATUS.md"
rc=0
_ps_baseline | sed 's/^output_count: 0/output_count: 0_0/' | python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >/dev/null 2>"$BUILD/ps-badcount.err" || rc=$?
assert_rc 1 "$rc" "publish-status: output_count: 0_0 is rejected (int() would silently accept it)"
assert_contains "STATUS_BAD_OUTPUT_COUNT" "$BUILD/ps-badcount.err" "bad-output-count failure names itself"

# Code review fix #6b: tmp_header_preview must cap at 512 BYTES, not 512
# characters -- a naive preview[:512] under-truncates multi-byte UTF-8.
rc=0
_ps_python_preview_check() {
  python3 - "$1" <<'CHECKPY'
import sys
ns = {"__name__": "_publish_status_under_test"}
exec(compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec"), ns)
raw = ("x: " + ("\u20ac" * 600) + "\n").encode("utf-8")
preview = ns["_redact_preview"](raw)
print(len(preview.encode("utf-8")))
CHECKPY
}
_preview_bytes="$(_ps_python_preview_check "$_ps")"
if [ "$_preview_bytes" -le 512 ]; then
  _ok "tmp_header_preview caps at 512 BYTES for multi-byte UTF-8 content (got $_preview_bytes)"
else
  _fail "tmp_header_preview exceeded 512 bytes for multi-byte UTF-8 content (got $_preview_bytes)"
fi

# Code review: STATUS_TMP_WRITE_FAILED was previously untested (only the
# temp-CREATE failure was). Exercise the write-failure path via its
# equivalent test hook to PUBLISH_STATUS_FAIL_RENAME above.
rm -f "$_ps_ff/STATUS.md" "$_ps_ff/STATUS.md.tmp."*
rc=0
_ps_baseline | PUBLISH_STATUS_FAIL_WRITE=1 python3 "$_ps" "${_ps_common[@]}" --status "$_ps_ff/STATUS.md" \
  >"$BUILD/ps-writefail.out" 2>"$BUILD/ps-writefail.err" || rc=$?
assert_rc 1 "$rc" "publish-status: a write failure (not just a create failure) is reported"
assert_contains "STATUS_TMP_WRITE_FAILED" "$BUILD/ps-writefail.err" "write failure names itself (distinct from create failure)"
assert_contains "classification=PUBLICATION_LOST" "$BUILD/ps-writefail.out" "write failure reports PUBLICATION_LOST evidence"
rm -f "$_ps_ff/STATUS.md.tmp."*

rm -rf "$_ps_dir"

# --- invoke_vendor: prelaunch validation (Task 5) ----------------------------
# Pure registry-logic checks -- no PATH/fakebin, no RUNTIME_DIR/policy.tsv --
# because both cases below must fail BEFORE invoke_vendor ever reaches the
# policy_value/vendor-launch code that would need either.
if declare -F invoke_vendor >/dev/null; then
  python3 "$REPO_TOP/tests/lib/extract.py" roles > "$BUILD/roles-iv.tsv"
  awk -F'\t' -v OFS='\t' '
    NR==1 { print; next }
    { if ($1=="preflight-claude") $2="carrier-pigeon"; print }
  ' "$BUILD/roles-iv.tsv" > "$BUILD/roles-iv-bad.tsv"

  iv_prompt="$BUILD/iv-prompt.txt"; printf 'hi\n' > "$iv_prompt"

  # invoke_vendor's own prelaunch diagnostics go to ITS caller's stderr (fd 2),
  # not to the $STDERR_FILE argument -- that argument is only ever wired to
  # the underlying vendor subprocess once launch actually happens. Capture the
  # subshell's stderr from the outside, not via the passed-in path.
  iv_err1="$BUILD/iv-unknown.err"
  ( ROLE_CONTRACTS_PATH="$BUILD/roles-iv-bad.tsv" \
      invoke_vendor preflight-claude "$iv_prompt" "$BUILD/iv-unknown.out" "$BUILD/iv-unknown-inner.err" \
  ) 2>"$iv_err1"
  rc=$?
  assert_rc 95 "$rc" "invoke_vendor rejects an unknown vendor"
  assert_present 'INVOKE_VENDOR_UNKNOWN_VENDOR' "$iv_err1" \
    "unknown-vendor rejection names itself"

  iv_missing="$BUILD/does-not-exist-prompt.txt"; rm -f "$iv_missing"
  iv_err2="$BUILD/iv-missing-prompt.err"
  ( ROLE_CONTRACTS_PATH="$BUILD/roles-iv.tsv" \
      invoke_vendor preflight-claude "$iv_missing" "$BUILD/iv-missing.out" "$BUILD/iv-missing-inner.err" \
  ) 2>"$iv_err2"
  rc=$?
  assert_rc 96 "$rc" "invoke_vendor fails when the prompt file does not exist"
  assert_present 'INVOKE_VENDOR_PROMPT_MISSING' "$iv_err2" \
    "missing-prompt failure names itself"

  # A non-numeric or non-positive timeout_minutes cell must fail loudly
  # (review finding #1): the gate below coerces via awk, which silently reads
  # "" or "n/a" as 0 and would skip the paid headroom probe entirely.
  tcol_bad="$(tsv_column "$BUILD/roles-iv.tsv" timeout_minutes)"
  awk -F'\t' -v OFS='\t' -v col="$tcol_bad" -v v="n/a" \
    'NR==1{print;next} { if ($1=="preflight-claude") $col=v; print }' \
    "$BUILD/roles-iv.tsv" > "$BUILD/roles-iv-badtimeout.tsv"
  iv_err3="$BUILD/iv-badtimeout.err"
  ( ROLE_CONTRACTS_PATH="$BUILD/roles-iv-badtimeout.tsv" \
      invoke_vendor preflight-claude "$iv_prompt" "$BUILD/iv-badtimeout.out" "$BUILD/iv-badtimeout-inner.err" \
  ) 2>"$iv_err3"
  rc=$?
  assert_rc 96 "$rc" "invoke_vendor rejects a non-numeric timeout_minutes"
  assert_present 'INVOKE_VENDOR_BAD_TIMEOUT' "$iv_err3" \
    "bad-timeout rejection names itself"
else
  _fail "invoke_vendor is not defined"
fi

finish
