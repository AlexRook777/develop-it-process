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

finish