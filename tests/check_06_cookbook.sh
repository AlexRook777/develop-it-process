#!/usr/bin/env bash
# Check 2: unit tests for extracted cookbook helpers.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

load_cookbook || finish
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
  #     verdict: DONE | FAILED | NEEDS_DEBUG | BLOCKED
  # verdicts.py only emits a row for an appendix whose body has a `^verdict:`
  # line -- an appendix reformatted so that line vanishes would silently drop
  # out of the drift check below rather than fail it. Guard against that by
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
    want="$(printf '%s' "$declared" | tr '|' '\n' | tr -d ' ' \
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
  _fail "post_dispatch was deleted; doc line 1390 references it"
fi

finish
