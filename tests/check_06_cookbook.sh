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

# --- Task 10: process_identity's four typed develop_it_dirty states --------
if declare -F process_identity >/dev/null; then
  _t10_pi="$(mktemp -d)"
  git -C "$_t10_pi" init -q
  printf 'v1\n' > "$_t10_pi/f.txt"
  ( cd "$_t10_pi" && git add f.txt \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null

  # no: tracked, matches HEAD exactly.
  PROCESS_PATH="$_t10_pi/f.txt" PROCESS_REPO_ROOT="$_t10_pi" PROCESS_PATH_REL="f.txt" process_identity
  assert_eq no "$PROCESS_DIRTY" "T10 develop_it_dirty=no: tracked and matches HEAD"
  assert_eq "" "$PROCESS_DIRTY_REASON" "T10 develop_it_dirty=no: no reason attached"

  # yes: tracked, differs from HEAD.
  printf 'v2\n' >> "$_t10_pi/f.txt"
  PROCESS_PATH="$_t10_pi/f.txt" PROCESS_REPO_ROOT="$_t10_pi" PROCESS_PATH_REL="f.txt" process_identity
  assert_eq yes "$PROCESS_DIRTY" "T10 develop_it_dirty=yes: tracked and differs from HEAD"
  ( cd "$_t10_pi" && git checkout -q -- f.txt )

  # untracked: never added to the index at all.
  printf 'never added\n' > "$_t10_pi/untracked.txt"
  PROCESS_PATH="$_t10_pi/untracked.txt" PROCESS_REPO_ROOT="$_t10_pi" PROCESS_PATH_REL="untracked.txt" process_identity
  assert_eq untracked "$PROCESS_DIRTY" "T10 develop_it_dirty=untracked: never in the index"

  # untracked (ignored-untracked counts the same, per spec S16.2 step 4).
  printf 'ignored.txt\n' > "$_t10_pi/.gitignore"
  printf 'ignored content\n' > "$_t10_pi/ignored.txt"
  PROCESS_PATH="$_t10_pi/ignored.txt" PROCESS_REPO_ROOT="$_t10_pi" PROCESS_PATH_REL="ignored.txt" process_identity
  assert_eq untracked "$PROCESS_DIRTY" "T10 develop_it_dirty=untracked: ignored-untracked is the SAME outcome as plain-untracked"

  # unknown: non-git PROCESS_REPO_ROOT, with a reason attached.
  _t10_nongit="$(mktemp -d)"
  printf 'x\n' > "$_t10_nongit/f.txt"
  PROCESS_PATH="$_t10_nongit/f.txt" PROCESS_REPO_ROOT="$_t10_nongit" PROCESS_PATH_REL="f.txt" process_identity
  assert_eq unknown "$PROCESS_DIRTY" "T10 develop_it_dirty=unknown: non-git PROCESS_REPO_ROOT"
  [ -n "$PROCESS_DIRTY_REASON" ] \
    && _ok "T10 develop_it_dirty=unknown: a reason is always attached" \
    || _fail "T10 develop_it_dirty=unknown: no reason attached"
  rm -rf "$_t10_nongit"

  # Code review round 2 fix: an UNBORN branch (a real git repo, zero commits)
  # is a DIFFERENT non-git-HEAD case than a non-git directory -- git
  # rev-parse HEAD there prints the literal word "HEAD" to stdout AND still
  # exits non-zero, which "2>/dev/null || echo non-git" INSIDE the command
  # substitution used to turn into the two-line garbage "HEAD" + "non-git"
  # (never matching a plain "= non-git" test, so the unborn-branch case fell
  # through to git ls-files and was misreported as untracked).
  _t10_unborn="$(mktemp -d)"
  git -C "$_t10_unborn" init -q
  printf 'x\n' > "$_t10_unborn/f.txt"
  PROCESS_PATH="$_t10_unborn/f.txt" PROCESS_REPO_ROOT="$_t10_unborn" PROCESS_PATH_REL="f.txt" process_identity
  assert_eq unknown "$PROCESS_DIRTY" \
    "T10 develop_it_dirty=unknown: an UNBORN branch (real git repo, zero commits) is unknown, not untracked"
  assert_eq non-git "$PROCESS_GIT_HEAD" \
    "T10 develop_it_dirty=unknown: PROCESS_GIT_HEAD is the clean sentinel, never git's own multi-line stdout garbage"
  rm -rf "$_t10_unborn"

  # PROCESS_FILE_SHA256 is computed independently of git in every state
  # (spec S16.2 step 6) -- verify it against a plain sha256sum even for the
  # non-git case above, and again here for the untracked case.
  expected_sha="$(sha256sum "$_t10_pi/untracked.txt" | cut -d' ' -f1)"
  PROCESS_PATH="$_t10_pi/untracked.txt" PROCESS_REPO_ROOT="$_t10_pi" PROCESS_PATH_REL="untracked.txt" process_identity
  assert_eq "$expected_sha" "$PROCESS_FILE_SHA256" \
    "T10 PROCESS_FILE_SHA256 matches a plain sha256sum regardless of develop_it_dirty state"

  rm -rf "$_t10_pi"
else
  _fail "process_identity is not defined (Task 10 four-state coverage)"
fi

# --- Task 10: validate_existing_run_log's four states -----------------------
if declare -F validate_existing_run_log >/dev/null; then
  _t10_ff="$(mktemp -d)/artifacts"; mkdir -p "$_t10_ff"
  FEATURE_FOLDER="$_t10_ff"

  # absent: no file at all.
  rc=0; out="$(validate_existing_run_log 2>"$BUILD/t10-velog-absent.err")" || rc=$?
  assert_rc 0 "$rc" "T10 validate_existing_run_log: absent RUN_LOG.md succeeds"
  assert_eq NEW_RUN_ELIGIBLE "$out" "T10 validate_existing_run_log: absent -> NEW_RUN_ELIGIBLE"
  assert_eq "" "$(cat "$BUILD/t10-velog-absent.err")" "T10 absent: writes nothing to stderr either"

  # malformed: has a real "event=" tag (so it is NOT the v1/garbage case
  # below) but no entry declares process_schema_version: 2.
  printf -- '--- 2020-01-01T00:00:00Z  event=DISPATCH_STARTED\nphase: 1\n\n' > "$_t10_ff/RUN_LOG.md"
  _t10_malformed_size="$(wc -c < "$_t10_ff/RUN_LOG.md")"
  rc=0; out="$(validate_existing_run_log 2>"$BUILD/t10-velog-malformed.err")" || rc=$?
  assert_rc 1 "$rc" "T10 validate_existing_run_log: malformed RUN_LOG.md fails"
  assert_contains "RUN_LOG_SCHEMA_MALFORMED" "$BUILD/t10-velog-malformed.err" \
    "T10 malformed: names itself distinctly from the v1 case"
  assert_contains "recorded process version" "$BUILD/t10-velog-malformed.err" \
    "T10 malformed: instructs use of the recorded process version"
  assert_eq "$_t10_malformed_size" "$(wc -c < "$_t10_ff/RUN_LOG.md")" \
    "T10 malformed: RUN_LOG.md is byte-identical after the call -- zero bytes written"

  # v1: legacy bare "--- <ts>  dispatch" blocks, no "event=" tag anywhere.
  printf -- '--- 2020-01-01T00:00:00Z  dispatch\nphase: 1\n\n' > "$_t10_ff/RUN_LOG.md"
  _t10_v1_size="$(wc -c < "$_t10_ff/RUN_LOG.md")"
  rc=0; out="$(validate_existing_run_log 2>"$BUILD/t10-velog-v1.err")" || rc=$?
  assert_rc 1 "$rc" "T10 validate_existing_run_log: v1 RUN_LOG.md fails"
  assert_contains "RUN_LOG_SCHEMA_V1_OR_UNKNOWN" "$BUILD/t10-velog-v1.err" "T10 v1: names itself"
  assert_contains "recorded process version" "$BUILD/t10-velog-v1.err" \
    "T10 v1: instructs use of the recorded process version"
  assert_eq "$_t10_v1_size" "$(wc -c < "$_t10_ff/RUN_LOG.md")" \
    "T10 v1: RUN_LOG.md is byte-identical after the call -- zero bytes written"

  # mismatched-identity: valid schema-v2 shape, but develop_it_git_sha names a
  # commit that is NOT the current PROCESS_GIT_HEAD.
  PROCESS_GIT_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  printf -- '--- 2020-01-01T00:00:00Z  event=PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE\nprocess_schema_version:   2\ndevelop_it_git_sha:       0000000000000000000000000000000000000000\n\n' \
    > "$_t10_ff/RUN_LOG.md"
  _t10_mismatch_size="$(wc -c < "$_t10_ff/RUN_LOG.md")"
  rc=0; out="$(validate_existing_run_log 2>"$BUILD/t10-velog-mismatch.err")" || rc=$?
  assert_rc 1 "$rc" "T10 validate_existing_run_log: mismatched-identity RUN_LOG.md fails"
  assert_contains "RUN_LOG_IDENTITY_MISMATCH" "$BUILD/t10-velog-mismatch.err" "T10 mismatch: names itself"
  assert_contains "recorded process version" "$BUILD/t10-velog-mismatch.err" \
    "T10 mismatch: instructs use of the recorded process version"
  assert_eq "$_t10_mismatch_size" "$(wc -c < "$_t10_ff/RUN_LOG.md")" \
    "T10 mismatch: RUN_LOG.md is byte-identical after the call -- zero bytes written"

  # A MATCHING identity is RESUME_ELIGIBLE, never a false HALT.
  PROCESS_GIT_HEAD="0000000000000000000000000000000000000000"
  rc=0; out="$(validate_existing_run_log 2>"$BUILD/t10-velog-match.err")" || rc=$?
  assert_rc 0 "$rc" "T10 validate_existing_run_log: matching identity succeeds"
  assert_eq RESUME_ELIGIBLE "$out" "T10 validate_existing_run_log: matching schema-v2 + identity -> RESUME_ELIGIBLE"

  unset PROCESS_GIT_HEAD
  rm -rf "$(dirname "$_t10_ff")"
else
  _fail "validate_existing_run_log is not defined"
fi

# --- Task 10: vendor_proven / vendor_proven_mark revocation rules -----------
if declare -F vendor_proven >/dev/null && declare -F vendor_proven_mark >/dev/null; then
  _t10_vp_ff="$(mktemp -d)/artifacts"; mkdir -p "$_t10_vp_ff"
  FEATURE_FOLDER="$_t10_vp_ff"
  ORCHESTRATION_DIR="$_t10_vp_ff/.orchestration"
  mkdir -p "$ORCHESTRATION_DIR"
  : > "$_t10_vp_ff/RUN_LOG.md"

  assert_eq false "$(vendor_proven claude)" "T10 vendor_proven: false before any evidence exists"

  vendor_proven_mark claude implementer >/dev/null
  assert_eq true "$(vendor_proven claude)" \
    "T10 vendor_proven: a substantive dispatch success marks the vendor proven"
  assert_eq false "$(vendor_proven codex)" \
    "T10 vendor_proven: marking one vendor never proves the OTHER"

  # A cheap/publication failure classification for the SAME vendor must NOT
  # revoke a prior proof (spec S16.3: "a later cheap probe/publication
  # failure cannot revoke it").
  record_event DISPATCH_COMPLETED phase=6 iteration=00 dispatch_id=p06-i00-x-a01 \
    reason="attempt classified: PUBLICATION_LOST" phase_name=implementation role=implementer \
    vendor=claude appendix=implementer logical_dispatch_id=p06-i00-x \
    develop_it_git_sha=non-git develop_it_file_sha256=deadbeef develop_it_dirty=no \
    status_path=/dev/null verdict="" classification=PUBLICATION_LOST exit_code=0 model=m \
    start_ms=0 end_ms=0 duration_ms=0 stdout_path=/dev/null stderr_path=/dev/null \
    mutation_state=NO_SIDE_EFFECTS checkpoint_kind=none tokens_input_new=0 \
    tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 \
    cost_usd=n/a usage_status=unavailable >/dev/null
  assert_eq true "$(vendor_proven claude)" \
    "T10 vendor_proven: a PUBLICATION_LOST classification does NOT revoke a prior proof"

  # A PERMANENT_VENDOR_ERROR classification (auth/permission/invalid-model
  # refusal) for the SAME vendor DOES revoke it.
  record_event DISPATCH_COMPLETED phase=6 iteration=00 dispatch_id=p06-i00-x-a02 \
    reason="attempt classified: PERMANENT_VENDOR_ERROR" phase_name=implementation role=implementer \
    vendor=claude appendix=implementer logical_dispatch_id=p06-i00-x \
    develop_it_git_sha=non-git develop_it_file_sha256=deadbeef develop_it_dirty=no \
    status_path=/dev/null verdict="" classification=PERMANENT_VENDOR_ERROR exit_code=1 model=m \
    start_ms=0 end_ms=0 duration_ms=0 stdout_path=/dev/null stderr_path=/dev/null \
    mutation_state=NO_SIDE_EFFECTS checkpoint_kind=none tokens_input_new=0 \
    tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 \
    cost_usd=n/a usage_status=unavailable >/dev/null
  assert_eq false "$(vendor_proven claude)" \
    "T10 vendor_proven: a PERMANENT_VENDOR_ERROR classification DOES revoke a prior proof"

  # Re-marking after revocation re-proves it.
  vendor_proven_mark claude implementer >/dev/null
  assert_eq true "$(vendor_proven claude)" \
    "T10 vendor_proven: a fresh substantive success re-proves the vendor after revocation"

  # event=MODEL_REJECTED for the SAME vendor also revokes.
  record_event MODEL_REJECTED phase=1 iteration=00 phase_name=preflight role=implementer \
    model=m vendor=claude reason="rejected" >/dev/null
  assert_eq false "$(vendor_proven claude)" \
    "T10 vendor_proven: a MODEL_REJECTED event for the same vendor revokes it"

  # Code review round 2 fix: SPEND_CEILING (the other named revoking
  # classification, spec S16.3) was implemented but never covered by a test.
  vendor_proven_mark claude implementer >/dev/null
  assert_eq true "$(vendor_proven claude)" \
    "T10 vendor_proven: re-proven before the SPEND_CEILING case"
  record_event DISPATCH_COMPLETED phase=6 iteration=00 dispatch_id=p06-i00-x-a03 \
    reason="attempt classified: SPEND_CEILING" phase_name=implementation role=implementer \
    vendor=claude appendix=implementer logical_dispatch_id=p06-i00-x \
    develop_it_git_sha=non-git develop_it_file_sha256=deadbeef develop_it_dirty=no \
    status_path=/dev/null verdict="" classification=SPEND_CEILING exit_code=1 model=m \
    start_ms=0 end_ms=0 duration_ms=0 stdout_path=/dev/null stderr_path=/dev/null \
    mutation_state=NO_SIDE_EFFECTS checkpoint_kind=none tokens_input_new=0 \
    tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 \
    cost_usd=n/a usage_status=unavailable >/dev/null
  assert_eq false "$(vendor_proven claude)" \
    "T10 vendor_proven: a SPEND_CEILING classification DOES revoke a prior proof"

  rm -rf "$(dirname "$_t10_vp_ff")"
else
  _fail "vendor_proven / vendor_proven_mark are not both defined"
fi

# --- Task 10: applicable_optional_skills is the installed ∩ relevant set ----
if declare -F applicable_optional_skills >/dev/null; then
  assert_eq "b;c" "$(applicable_optional_skills "a;b;c" "b;c;d")" \
    "T10 applicable_optional_skills: intersection, installed order preserved"
  assert_eq "" "$(applicable_optional_skills "a;b" "c;d")" \
    "T10 applicable_optional_skills: disjoint sets -> empty"
  assert_eq "" "$(applicable_optional_skills "" "a;b")" \
    "T10 applicable_optional_skills: nothing installed -> empty (optional absence never halts)"
else
  _fail "applicable_optional_skills is not defined"
fi

# --- Task 10: skills_reprobe_needed re-probes on any single trigger --------
if declare -F skills_reprobe_needed >/dev/null; then
  assert_eq false "$(skills_reprobe_needed no no no)" \
    "T10 skills_reprobe_needed: no trigger -> no re-probe"
  assert_eq true "$(skills_reprobe_needed yes no no)" \
    "T10 skills_reprobe_needed: prior READY contradiction -> re-probe (the observed preflight-codex false negative)"
  assert_eq true "$(skills_reprobe_needed no yes no)" \
    "T10 skills_reprobe_needed: filesystem evidence of presence -> re-probe"
  assert_eq true "$(skills_reprobe_needed no no yes)" \
    "T10 skills_reprobe_needed: publication lost -> re-probe"
else
  _fail "skills_reprobe_needed is not defined"
fi

# --- Code review round 2 fix (finding 3): vendor_preflight_reprobe_once
# makes vendor_proven a real behavioural input at Phases 3/5/7, not
# write-only telemetry.
if declare -F vendor_preflight_reprobe_once >/dev/null; then
  _t10_vpr_ff="$(mktemp -d)/artifacts"; mkdir -p "$_t10_vpr_ff"
  FEATURE_FOLDER="$_t10_vpr_ff"
  ORCHESTRATION_DIR="$_t10_vpr_ff/.orchestration"
  mkdir -p "$ORCHESTRATION_DIR"
  : > "$_t10_vpr_ff/RUN_LOG.md"

  assert_eq no "$(vendor_preflight_reprobe_once codex 0)"     "T10 vendor_preflight_reprobe_once: not proven -> no re-probe, accept the failure"

  vendor_proven_mark codex spec-reviewer-codex >/dev/null
  assert_eq yes "$(vendor_preflight_reprobe_once codex 0)"     "T10 vendor_preflight_reprobe_once: proven + Mode 0 (cheap probe shape) -> re-probe once"
  assert_eq yes "$(vendor_preflight_reprobe_once codex 4)"     "T10 vendor_preflight_reprobe_once: proven + Mode 4 (malformed STATUS) -> re-probe once"
  assert_eq no "$(vendor_preflight_reprobe_once codex 5)"     "T10 vendor_preflight_reprobe_once: proven + Mode 5 (quota/rate-limit signal) -> NEVER re-probe, accept as real"

  rm -rf "$(dirname "$_t10_vpr_ff")"
else
  _fail "vendor_preflight_reprobe_once is not defined"
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
  RELEVANT_ARTIFACTS="/tmp/a.md
/tmp/b.md"
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
  CONTINUATION_PATH=""
  DECLARED_FOREIGN_CHANGES=""
  APPLICABLE_OPTIONAL_SKILLS=""
  RUNTIME_DIR="$FEATURE_FOLDER/.orchestration/runtime"
  MODE=A
  CONTINUATION_PRIOR_CLASSIFICATION=""

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
  # (Task 11: spec-fixer/plan-fixer switched to the single-line, space-
  # separated $FINDING_IDS batch; $RELEVANT_ARTIFACTS -- implementation-
  # fixer's own newline-separated list -- is the genuinely multi-line
  # variable now, same substitution code path.)
  body="$(render_prompt implementation-fixer)"
  case "$body" in
    *"/tmp/a.md"*"/tmp/b.md"*) _ok "multi-line \$RELEVANT_ARTIFACTS survives intact" ;;
    *) _fail "multi-line substitution mangled \$RELEVANT_ARTIFACTS" ;;
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

# --- _dispatch_launch_attempt actually CALLS post_dispatch, with the stdout transcript ---
# post_dispatch spent a revision as an orphan: defined, documented as "the"
# implementation of the transcript-read policy, and invoked from nowhere. That
# is why a spend-ceiling failure reached the user with no diagnostic. Pin both
# the call and the stdout-transcript argument. dispatch_role is gone (Task 6);
# _dispatch_launch_attempt is the part of dispatch_attempt/dispatch_parallel's
# lifecycle that actually invokes the vendor and classifies the result.
if declare -F _dispatch_launch_attempt >/dev/null; then
  _dr_body="$(declare -f _dispatch_launch_attempt)"
  case "$_dr_body" in
    *post_dispatch*) _ok "_dispatch_launch_attempt calls post_dispatch" ;;
    *) _fail "_dispatch_launch_attempt no longer calls post_dispatch — the policy is unenforced again" ;;
  esac
  case "$_dr_body" in
    *'post_dispatch "$vrc" "$s_path" "$err_path" "$out_path"'*)
      _ok "_dispatch_launch_attempt passes the stdout transcript to post_dispatch" ;;
    *) _fail "_dispatch_launch_attempt's post_dispatch call is missing the stdout transcript argument" ;;
  esac
  # Step 3 order (review fix #9): write the attempt result BEFORE releasing
  # the lease -- a single ordered-substring match on the function's own body,
  # same style as the post_dispatch pin two cases above.
  case "$_dr_body" in
    *'_dispatch_write_result "$a_dir" launched=yes'*'release_write_lease "$role"'*)
      _ok "_dispatch_launch_attempt writes the attempt result BEFORE releasing the lease" ;;
    *) _fail "_dispatch_launch_attempt releases the lease before (or without) writing the attempt result" ;;
  esac
else
  _fail "_dispatch_launch_attempt is not defined"
fi

for _fn in dispatch_attempt dispatch_parallel _dispatch_prelaunch _dispatch_launch_attempt \
           _dispatch_write_started _dispatch_ingest_result _dispatch_ingest_child \
           dispatch_is_running acquire_write_lease release_write_lease _write_lease_state \
           record_event event_required_fields classify_attempt inspect_mutation_state \
           recovery_action recovery_retry_allowed resume_dispatch_state; do
  declare -F "$_fn" >/dev/null && _ok "$_fn is defined" || _fail "$_fn is not defined"
done

# Task 8: the provisional Task 6/7 lease seam is retired wholesale, not left
# defined-but-uncalled -- see check_06's "retired" pattern two blocks below.
for _fn in _dispatch_lease_try_acquire _dispatch_lease_release _dispatch_lease_state; do
  declare -F "$_fn" >/dev/null \
    && _fail "$_fn should have been retired by Task 8's real write-lease protocol" \
    || _ok "$_fn is removed (replaced by acquire_write_lease/release_write_lease)"
done

for _fn in _dispatch_run_attempt; do
  declare -F "$_fn" >/dev/null \
    && _fail "$_fn should have been split into _dispatch_prelaunch/_dispatch_launch_attempt in the review fix" \
    || _ok "$_fn is removed (split into _dispatch_prelaunch/_dispatch_launch_attempt)"
done

# _dispatch_classify (Task 6's four-outcome seam) is retired wholesale by
# Task 7's classify_attempt -- same pattern as _dispatch_run_attempt above.
for _fn in dispatch_role dispatch_reviewers_parallel dispatch_id log_dispatch_started log_dispatch dispatch_state \
           claude_invoke codex_invoke _dispatch_classify; do
  declare -F "$_fn" >/dev/null && _fail "$_fn should have been removed (Task 6/7)" \
    || _ok "$_fn is removed"
done

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
# Code review fix (round 1, finding 4): the original detector inspected only
# the SINGLE physical line before a function's closing brace. A block closer
# (`fi`/`done`/`esac`) on that line hides the real last-executed statement
# one level INSIDE the block -- e.g. `[ -n "$X" ] && Y=1` immediately
# followed by `fi` then `}` -- which is exactly the shape Task 13's own
# reconstruct_checkpoint_state regression took (proven live: with its
# `return 0` removed, this detector still printed 0 hits while check_10
# aborted mid-run under set -e). Walk backward through any depth of trailing
# bare block-closer lines to find the statement that actually executes last.
CLOSERS = {"fi", "done", "esac"}
def _skippable(s):
    return s in CLOSERS or s == "" or s.startswith("#")
for i, line in enumerate(lines):
    if line.strip() == "}" and i > 0:
        j = i - 1
        while j >= 0 and _skippable(lines[j].strip()):
            j -= 1
        if j < 0:
            continue
        prev = lines[j].strip()
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
: > "$ORCHESTRATION_DIR/log.lock"   # simulate a lock held by someone else (a plain file now, ln-based)
rm -f "$BUILD/aa-lock-done"
( allocate_attempt 5 4 plan-fixer >/dev/null 2>&1; : > "$BUILD/aa-lock-done" ) &
_aa_bg_pid=$!
sleep 0.3
if [ -f "$BUILD/aa-lock-done" ]; then
  _fail "allocate_attempt proceeded despite a run-log lock held by someone else"
else
  _ok "allocate_attempt blocks while the run-log lock is held by someone else"
fi
rm -f "$ORCHESTRATION_DIR/log.lock"
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

# ============================================================================
# Task 8: record_event, the Event Contract Registry, write leases, and
# mutation snapshots.
# ============================================================================
init_v2_fixture
mkdir -p "$RUNTIME_DIR"
python3 "$REPO_TOP/tests/lib/extract.py" policies > "$RUNTIME_DIR/policy.tsv"

# --- context7_policy: full spec S15.5 latest-event-wins precedence (code
# review fix #6 -- out of Task 8's own steps, but a genuine behaviour
# change with previously zero coverage).
mkdir -p "$FEATURE_FOLDER/1-preflight/phase-1"
_t8_c7_status="$FEATURE_FOLDER/1-preflight/phase-1/claude-check-status.md"
printf 'verdict: READY\ncontext7: reachable\n' > "$_t8_c7_status"
: > "$RUN_LOG"
assert_eq required "$(context7_policy)" \
  "context7_policy: STATUS reachable, no RUN_LOG event, is required (baseline unchanged)"

# The behaviour CHANGE this fix delivers: a LATER CONTEXT7_UNAVAILABLE event
# overrides an already-reachable Phase 1 STATUS -- the old implementation
# checked STATUS first and could never downgrade it.
record_event CONTEXT7_UNAVAILABLE phase=3 iteration=00 reason="probe failed mid-run" >/dev/null
assert_eq best-effort "$(context7_policy)" \
  "context7_policy: a later CONTEXT7_UNAVAILABLE downgrades an already-reachable Phase 1 STATUS"

# CONTEXT7_RESTORED requires a successful deterministic probe citation to
# re-promote back to required; anything else (or a missing probe field)
# stays best-effort.
: > "$RUN_LOG"
record_event CONTEXT7_UNAVAILABLE phase=3 iteration=00 reason="probe failed" >/dev/null
record_event CONTEXT7_RESTORED phase=5 iteration=00 probe=success reason="probe succeeded" >/dev/null
assert_eq required "$(context7_policy)" \
  "context7_policy: CONTEXT7_RESTORED with probe=success re-promotes to required"

: > "$RUN_LOG"
record_event CONTEXT7_UNAVAILABLE phase=3 iteration=00 reason="probe failed" >/dev/null
record_event CONTEXT7_RESTORED phase=5 iteration=00 probe=unconfirmed reason="no deterministic probe" >/dev/null
assert_eq best-effort "$(context7_policy)" \
  "context7_policy: CONTEXT7_RESTORED without a successful probe citation stays best-effort"

# No STATUS, no RUN_LOG event at all: refuse to guess.
rm -f "$_t8_c7_status"
: > "$RUN_LOG"
rc=0; context7_policy >/dev/null 2>"$BUILD/t8-c7.err" || rc=$?
assert_rc 1 "$rc" "context7_policy halts (never guesses) with no STATUS and no RUN_LOG evidence"
assert_contains "halt:" "$BUILD/t8-c7.err" "the halt names itself"

# --- Event Contract Registry: event_required_fields (the runtime mirror)
# agrees with extract.py events (the markdown table) for EVERY row, in BOTH
# directions -- a row in one but not the other is a real drift, not a subset.
python3 "$REPO_TOP/tests/lib/extract.py" events > "$BUILD/events.tsv"
_t8_registry_types="$(tail -n +2 "$BUILD/events.tsv" | cut -f1 | sort)"
_t8_code_types="$(printf '%s\n' \
  DISPATCH_NOT_LAUNCHED DISPATCH_STARTED DISPATCH_COMPLETED ATTEMPT_FAILED \
  RECOVERY_AUTHORIZED RECOVERY_CAP_REACHED CONTINUATION_CAP_REACHED ORCHESTRATION_CORRECTION HALT \
  OWNER_DECISION RISK_ACCEPTED PHASE_ACCEPTED EVENT_CORRECTED VENDOR_UNAVAILABLE \
  DEGRADED_REVIEW_ACCEPTED CONTEXT7_UNAVAILABLE CONTEXT7_RESTORED \
  WRITE_LEASE_ACQUIRED WRITE_LEASE_RELEASED ARTIFACT_INTEGRITY_BLOCKED \
  GIT_FINALIZATION_RESULT ITERATION_CAP_REACHED ITERATION_CAP_OVERRIDE \
  PROCESS_DEVIATION ATTEMPT_ALLOCATED \
  CODEX_UNAVAILABLE CLAUDE_FAILED IMPLEMENTATION_BASELINE IMPLEMENTATION_BASELINE_BLOCKED \
  CODEX_DISABLED_BY_USER_CONSENT CODEX_SKIPPED_BY_USER_CONSENT MODEL_REJECTED DISPATCH_ORPHANED \
  PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE LOCAL_CLI_CANARIES_PASSED TARGET_DIRTY_TREE_GATE_PASSED \
  PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED RUNTIME_AND_REGISTRIES_VERIFIED VENDOR_PROVEN \
  CONVERGENCE_RECORDED DIVERGENCE_DETECTED DIVERGENT_ROUND_CAP_REACHED \
  PLAN_REVIEW_STALE \
  | sort)"
assert_eq "$_t8_code_types" "$_t8_registry_types" \
  "event_required_fields' own type list matches the Event Contract Registry exactly"
_t8_mismatch=""
# NOTE: bash `read` collapses consecutive tab delimiters (tab is IFS
# "whitespace" regardless of what IFS is set to), which would silently
# misalign an empty required_fields cell -- use awk -F '\t' per column, the
# same discipline Task 4's own tests already apply to this exact TSV shape.
_t8_fields_col="$(tsv_column "$BUILD/events.tsv" required_fields)"
while IFS= read -r _t8_type; do
  _t8_fields="$(awk -F'\t' -v k="$_t8_type" -v c="$_t8_fields_col" \
    '$1==k{print $c}' "$BUILD/events.tsv")"
  _t8_code_fields="$(event_required_fields "$_t8_type" 2>/dev/null)"
  [ "$_t8_code_fields" = "$_t8_fields" ] || _t8_mismatch="$_t8_mismatch $_t8_type"
done < <(printf '%s\n' "$_t8_registry_types")
assert_eq "" "$_t8_mismatch" \
  "event_required_fields agrees with the registry's required_fields column for every type"
_t8_yes_count="$(tail -n +2 "$BUILD/events.tsv" | awk -F'\t' '$3=="yes"' | wc -l | tr -d ' ')"
assert_eq 15 "$_t8_yes_count" \
  "exactly fifteen event types are proposition_required=yes (Task 11 adds DIVERGENCE_DETECTED and DIVERGENT_ROUND_CAP_REACHED)"

# --- record_event flushes/fsyncs its append (Step 3, code review fix #5) ---
if declare -F record_event >/dev/null; then
  case "$(declare -f record_event)" in
    *'_bootstrap_fsync_path "$FEATURE_FOLDER/RUN_LOG.md"'*)
      _ok "record_event fsyncs RUN_LOG.md after appending" ;;
    *) _fail "record_event no longer fsyncs its append" ;;
  esac
fi

# --- record_event: envelope validation ---
: > "$RUN_LOG"
record_event ATTEMPT_ALLOCATED dispatch_id=p01-i01-x-a01 logical_dispatch_id=p01-i01-x \
  phase=1 iteration=01 role=x attempt=1 launched=false reason="t8 fixture"
assert_rc 0 $? "record_event succeeds for a well-formed known event type"
for _f in event_id process_schema_version phase iteration dispatch_id \
          caused_by_event_id authority reason; do
  assert_present "^${_f}:" "$RUN_LOG" "record_event's block carries common field: $_f"
done
assert_present '^event_id:[[:space:]]*1$' "$RUN_LOG" "the first event_id assigned is 1"
record_event ATTEMPT_ALLOCATED dispatch_id=p01-i02-x-a01 logical_dispatch_id=p01-i02-x \
  phase=1 iteration=02 role=x attempt=1 launched=false reason="t8 fixture 2" >/dev/null
assert_present '^event_id:[[:space:]]*2$' "$RUN_LOG" "event_id is monotonically increasing across calls"

rc=0; record_event NO_SUCH_TYPE foo=bar 2>"$BUILD/t8-err1.log" || rc=$?
assert_rc 1 "$rc" "record_event rejects an unregistered event type"
assert_contains "EVENT_TYPE_UNKNOWN" "$BUILD/t8-err1.log" "unknown type names itself"

rc=0; record_event ATTEMPT_ALLOCATED dispatch_id=x logical_dispatch_id=y phase=1 iteration=1 \
  role=r attempt=1 launched=false 2>"$BUILD/t8-err2.log" || rc=$?
assert_rc 1 "$rc" "record_event rejects a missing reason (the one common field required non-empty)"
assert_contains "RECORD_EVENT_MISSING_REASON" "$BUILD/t8-err2.log" "missing-reason failure names itself"

rc=0; record_event ATTEMPT_ALLOCATED dispatch_id=x logical_dispatch_id=y phase=1 iteration=1 \
  role=r attempt=1 reason=ok 2>"$BUILD/t8-err3.log" || rc=$?
assert_rc 1 "$rc" "record_event rejects a missing event-specific required field (launched)"
assert_contains "RECORD_EVENT_MISSING_FIELD:ATTEMPT_ALLOCATED:launched" "$BUILD/t8-err3.log" \
  "missing-field failure names the type and field"

rc=0; record_event ATTEMPT_ALLOCATED dispatch_id=x logical_dispatch_id=y phase=1 iteration=1 \
  role=r attempt=1 launched=false reason=ok bogus=1 2>"$BUILD/t8-err4.log" || rc=$?
assert_rc 1 "$rc" "record_event rejects an undeclared field, never silently accepting it"
assert_contains "RECORD_EVENT_UNKNOWN_FIELD:ATTEMPT_ALLOCATED:bogus" "$BUILD/t8-err4.log" \
  "unknown-field failure names the type and field"

rc=0; record_event ATTEMPT_ALLOCATED dispatch_id=x logical_dispatch_id=y phase=1 iteration=1 \
  role=r attempt=1 launched=false reason=ok authority=bogus 2>"$BUILD/t8-err5.log" || rc=$?
assert_rc 1 "$rc" "record_event rejects an authority value outside process|owner|role|system"
assert_contains "RECORD_EVENT_BAD_AUTHORITY:bogus" "$BUILD/t8-err5.log" \
  "bad-authority failure names the value"

# --- Concurrency: record_event's monotonic event_id under REAL concurrent
# writers, not just sequential calls (Task 8 code review fix #0). The
# mkdir-based lock this replaced was invisible to every prior test because
# none of them raced concurrent writers -- an 8-way race is the same shape
# the review reproduced duplicates with.
: > "$RUN_LOG"
rm -f "$ORCHESTRATION_DIR/log.lock"
_t8c_n=8
_t8c_pids=()
for _t8c_i in $(seq 1 "$_t8c_n"); do
  ( record_event ATTEMPT_ALLOCATED dispatch_id="p01-i01-c${_t8c_i}-a01"       logical_dispatch_id="p01-i01-c${_t8c_i}" phase=1 iteration=01 role="c${_t8c_i}"       attempt=1 launched=false reason="concurrency probe ${_t8c_i}" ) &
  _t8c_pids+=("$!")
done
for _t8c_pid in "${_t8c_pids[@]}"; do wait "$_t8c_pid"; done
_t8c_ids="$("$GREP_BIN" -oE '^event_id:[[:space:]]+[0-9]+$' "$RUN_LOG" | "$GREP_BIN" -oE '[0-9]+$' | sort -n)"
_t8c_count="$(printf '%s\n' "$_t8c_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "$_t8c_n" "$_t8c_count"   "record_event under ${_t8c_n}-way concurrency produced exactly ${_t8c_n} events (no lost writes)"
assert_eq "$(seq 1 "$_t8c_n")" "$_t8c_ids"   "record_event's event_id sequence is contiguous 1..N with no duplicates under real concurrency"

# --- Append-only: RUN_LOG's prior content is always a byte-exact PREFIX of
# its content after another record_event call -- never rewritten in place.
_t8_before_sha="$(sha256sum "$RUN_LOG" | cut -d' ' -f1)"
_t8_before_bytes="$(wc -c < "$RUN_LOG" | tr -d ' ')"
record_event ATTEMPT_ALLOCATED dispatch_id=p01-i03-x-a01 logical_dispatch_id=p01-i03-x \
  phase=1 iteration=03 role=x attempt=1 launched=false reason="append-only probe" >/dev/null
head -c "$_t8_before_bytes" "$RUN_LOG" | sha256sum | cut -d' ' -f1 > "$BUILD/t8-prefix.sha"
assert_contains "$_t8_before_sha" "$BUILD/t8-prefix.sha" \
  "RUN_LOG's prior bytes remain an exact prefix after another event is appended"

# --- Decision records and corrections (spec S15.3/S15.4): OWNER_DECISION's
# full field list, then a correcting EVENT_CORRECTED referencing it by ID.
: > "$RUN_LOG"
record_event OWNER_DECISION decision_id=d1 authority=owner authority_identity=operator \
  scope="finding-7" artifact_path="src/x.py" artifact_revision=abc123 evidence="reviewed by hand" \
  alternatives_rejected="revert instead" residual_risk="low" expiry="this phase" \
  independent_rereview=no follow_up_id="" reason="owner accepted the residual risk"
assert_rc 0 $? "record_event accepts a full OWNER_DECISION (spec S15.3's whole field list)"
decision_event_id="$(status_field "$RUN_LOG" event_id)"
record_event EVENT_CORRECTED corrected_event_id="$decision_event_id" \
  replacement_classification="RISK_ACCEPTED" evidence="follow-up review changed the finding" \
  downstream_effect="none" reason="correcting event $decision_event_id"
assert_rc 0 $? "record_event accepts EVENT_CORRECTED naming the original decision's event_id"
assert_present "corrected_event_id:[[:space:]]*${decision_event_id}\$" "$RUN_LOG" \
  "EVENT_CORRECTED names the exact original event_id"
_t8_owner_decision_still_present="$(grep -c 'event=OWNER_DECISION' "$RUN_LOG")"
assert_eq 1 "$_t8_owner_decision_still_present" \
  "the original OWNER_DECISION block is retained verbatim, never edited or removed"

# --- Write leases: the remaining substates check_09_recovery.sh's RM02/RM03
# fixtures do not already cover directly (ACTIVE_LEASE_OWNER and
# AMBIGUOUS_LEASE/MALFORMED_LEASE are proven there against a real dispatch).
: > "$RUN_LOG"
rm -f "$LEASE_FILE"

record_event DISPATCH_STARTED phase=6 iteration=01 dispatch_id=p06-i01-implementer-a01 \
  reason=x phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i01-implementer model=m status_path=/dev/null cwd=/tmp \
  lease=none snapshot=none >/dev/null
record_event DISPATCH_COMPLETED phase=6 iteration=01 dispatch_id=p06-i01-implementer-a01 \
  reason=x phase_name=implementation role=implementer vendor=claude appendix=implementer \
  logical_dispatch_id=p06-i01-implementer develop_it_git_sha=x develop_it_file_sha256=x \
  develop_it_dirty=no status_path=/dev/null verdict="" classification=TIMED_OUT exit_code=1 \
  model=m start_ms=1 end_ms=2 duration_ms=1 stdout_path=/dev/null stderr_path=/dev/null \
  mutation_state=NO_SIDE_EFFECTS checkpoint_kind=none tokens_input_new=0 tokens_input_cached=0 \
  tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=0 usage_status=ok >/dev/null
write_fake_lease "$LEASE_FILE" p06-i01-implementer-a01 implementer
assert_eq OBSERVED_FAILED_OWNER "$(_write_lease_state "$LEASE_FILE")" \
  "a launched-then-classified-failed owner (no release recorded) is OBSERVED_FAILED_OWNER"
assert_eq STALE_OR_AMBIGUOUS_LEASE "$(_write_lease_recovery_state OBSERVED_FAILED_OWNER)" \
  "OBSERVED_FAILED_OWNER folds into RM03's STALE_OR_AMBIGUOUS_LEASE -- never auto-reclaimed"

: > "$RUN_LOG"
record_event DISPATCH_STARTED phase=6 iteration=02 dispatch_id=p06-i02-implementer-a01 \
  reason=x phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i02-implementer model=m status_path=/dev/null cwd=/tmp \
  lease=none snapshot=none >/dev/null
record_event DISPATCH_COMPLETED phase=6 iteration=02 dispatch_id=p06-i02-implementer-a01 \
  reason=x phase_name=implementation role=implementer vendor=claude appendix=implementer \
  logical_dispatch_id=p06-i02-implementer develop_it_git_sha=x develop_it_file_sha256=x \
  develop_it_dirty=no status_path=/dev/null verdict=DONE classification=COMPLETED exit_code=0 \
  model=m start_ms=1 end_ms=2 duration_ms=1 stdout_path=/dev/null stderr_path=/dev/null \
  mutation_state=CLEAN_CHECKPOINTED checkpoint_kind=none tokens_input_new=0 tokens_input_cached=0 \
  tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=0 usage_status=ok >/dev/null
printf '{"dispatch_id":"p06-i02-implementer-a01","lease_owner":"implementer","authority":"role"}\n' \
  > "$LEASE_FILE"
assert_eq COMPLETED_LOST_RELEASE "$(_write_lease_state "$LEASE_FILE")" \
  "a COMPLETED owner whose release record is lost (lease file still present) is COMPLETED_LOST_RELEASE"

: > "$RUN_LOG"
record_event DISPATCH_STARTED phase=6 iteration=03 dispatch_id=p06-i03-implementer-a01 \
  reason=x phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i03-implementer model=m status_path=/dev/null cwd=/tmp \
  lease=none snapshot=none >/dev/null
printf '{"dispatch_id":"p06-i03-implementer-a01","lease_owner":"implementer","authority":"role"}\n' \
  > "$LEASE_FILE"
assert_eq ORPHANED_UNOBSERVED_OWNER "$(_write_lease_state "$LEASE_FILE")" \
  "a durable DISPATCH_STARTED with no live process behind it is ORPHANED_UNOBSERVED_OWNER"

rm -f "$LEASE_FILE"
assert_eq NO_LEASE "$(_write_lease_state "$LEASE_FILE")" "an absent lease file is NO_LEASE"

# --- acquire_write_lease: repository containment and exclusive creation ---
rc=0; acquire_write_lease implementer role p06-i04-implementer-a01 6 /etc/passwd \
  2>"$BUILD/t8-lease-abs.err" || rc=$?
assert_rc 1 "$rc" "acquire_write_lease rejects an absolute declared path"
assert_contains "WRITE_LEASE_PATH_NOT_CONTAINED" "$BUILD/t8-lease-abs.err" \
  "absolute-path rejection names itself"
assert_not_exists "$LEASE_FILE" "the rejected acquisition never created a lease file"

# Code review fix #8: without this, a fully-broken _write_lease_path_ok
# would still make THIS case's own rc=1 check pass (for the wrong reason --
# the PRECEDING case's own acquisition, if also unrejected, would leave a
# real lease file behind, and `ln` fails on that collision regardless of
# whether containment itself works). Start from a guaranteed-clean lease
# state so this case's rc/reason are meaningful on their own.
rm -f "$LEASE_FILE"
rc=0; acquire_write_lease implementer role p06-i05-implementer-a01 6 "../outside" \
  2>"$BUILD/t8-lease-esc.err" || rc=$?
assert_rc 1 "$rc" "acquire_write_lease rejects a path that escapes \$REPO_ROOT via .."
assert_contains "WRITE_LEASE_PATH_NOT_CONTAINED" "$BUILD/t8-lease-esc.err" \
  "path-escape rejection names itself"

# --- release_write_lease: non-owner and malformed refusals never remove the
# lease file (spec S11.3: "removes only an exact, valid owner match"). ---
acquire_write_lease implementer role p06-i06-implementer-a01 6 "." >/dev/null
assert_eq 6 "$(jq -r '.phase' "$LEASE_FILE")" \
  "acquire_write_lease records the EXPLICIT phase parameter (code review fix #2), never an ambient guess"
rc=0; release_write_lease debugger 2>"$BUILD/t8-rel1.err" || rc=$?
assert_rc 1 "$rc" "release_write_lease refuses a non-owner caller"
assert_contains "WRITE_LEASE_NOT_OWNER" "$BUILD/t8-rel1.err" "non-owner refusal names itself"
assert_exists "$LEASE_FILE" "a non-owner release call never removes the lease file"
printf 'not json\n' > "$LEASE_FILE"
rc=0; release_write_lease implementer 2>"$BUILD/t8-rel2.err" || rc=$?
assert_rc 1 "$rc" "release_write_lease refuses a malformed lease file"
assert_contains "WRITE_LEASE_MALFORMED" "$BUILD/t8-rel2.err" "malformed-lease refusal names itself"
assert_exists "$LEASE_FILE" "a malformed lease file is left in place, never force-removed"
rm -f "$LEASE_FILE"
rc=0; release_write_lease implementer 2>"$BUILD/t8-rel3.err" || rc=$?
assert_rc 1 "$rc" "release_write_lease refuses when no lease is held at all"
assert_contains "WRITE_LEASE_NOT_HELD" "$BUILD/t8-rel3.err" "not-held refusal names itself"

# --- Snapshot capture: a real declared artifact gets hashed and copied into
# the manifest's before/after tree, never just the whole-repo "." shortcut.
( cd "$REPO_ROOT" && printf 'hello\n' > tracked.txt && git add tracked.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "seed tracked.txt" ) >/dev/null
rm -f "$LEASE_FILE"
# A pre-existing, untracked "foreign" change -- present BEFORE this lease is
# even acquired, standing in for another writer's already-dirty tree state
# (spec S11.2's "known foreign changes").
( cd "$REPO_ROOT" && printf 'not mine\n' > foreign.txt )
acquire_write_lease implementer role p06-i07-implementer-a01 6 tracked.txt >/dev/null
_t8_manifest="$ORCHESTRATION_DIR/snapshots/p06-i07-implementer-a01/manifest.json"
assert_exists "$_t8_manifest" "acquiring the lease captured a before-manifest"
assert_present '"path": *"tracked.txt"' "$_t8_manifest" \
  "the before-manifest names the declared artifact by path"
assert_exists "$ORCHESTRATION_DIR/snapshots/p06-i07-implementer-a01/before/tracked.txt" \
  "the before-manifest's own artifact copy was actually written to disk"
_t8_allow_list_len="$(jq '.before.allow_list | length' "$_t8_manifest")"
[ "$_t8_allow_list_len" -gt 0 ] && _ok "the before-manifest records a non-empty allow-list" \
  || _fail "the before-manifest's allow_list is empty"
( cd "$REPO_ROOT" && printf 'changed\n' >> tracked.txt )
release_write_lease implementer >/dev/null
assert_present '"before":' "$_t8_manifest" "the manifest keeps the before snapshot after release"
assert_present '"after":' "$_t8_manifest" "release_write_lease added the after snapshot"
_t8_foreign="$(jq -r '.after.foreign_changes' "$_t8_manifest")"
case "$_t8_foreign" in
  *foreign.txt*) _ok "the after-snapshot's foreign_changes names the pre-existing untracked file" ;;
  *) _fail "foreign_changes did not carry the pre-existing foreign dirt: [$_t8_foreign]" ;;
esac
rm -f "$REPO_ROOT/foreign.txt"
_t8_before_blob="$(python3 -c "import json;print(json.load(open('$_t8_manifest'))['before']['artifacts'][0]['blob'])")"
_t8_after_status="$(python3 -c "import json;print(json.load(open('$_t8_manifest'))['after']['status'])")"
case "$_t8_after_status" in
  *tracked.txt*) _ok "the after-snapshot's porcelain status shows the real uncommitted change" ;;
  *) _fail "the after-snapshot did not observe the change made while the lease was held: [$_t8_after_status]" ;;
esac
[ -n "$_t8_before_blob" ] && _ok "the before-manifest recorded a real git blob hash for the declared artifact" \
  || _fail "the before-manifest's blob hash is empty"

# --- Phase 10 direct-finalization shape (spec Step 5's own JSON example):
# dispatch_id null, authority orchestrator, phase "10" -- not just a role
# dispatch's phase read off an ambient variable.
rm -f "$LEASE_FILE"
acquire_write_lease orchestrator-finalization orchestrator "" 10 "." >/dev/null
assert_eq 10 "$(jq -r '.phase' "$LEASE_FILE")" \
  "acquire_write_lease's Phase 10 finalization shape records phase:\"10\" exactly as spec Step 5 shows"
assert_eq null "$(jq -r '.dispatch_id' "$LEASE_FILE")" \
  "Phase 10's lease has a JSON null dispatch_id, never an empty string"
release_write_lease orchestrator-finalization >/dev/null

# =============================================================================
# Task 11: stable findings and review convergence
# =============================================================================
T11_FEATURE_FOLDER="$FEATURE_FOLDER"
T11_ORCHESTRATION_DIR="$ORCHESTRATION_DIR"

if declare -F ingest_findings >/dev/null && declare -F validate_artifact >/dev/null; then
  bootstrap_runtime >/dev/null 2>&1
  T11_DIR="$BUILD/t11"; rm -rf "$T11_DIR"; mkdir -p "$T11_DIR"
  FEATURE_FOLDER="$T11_DIR"
  ORCHESTRATION_DIR="$T11_DIR/.orchestration"
  mkdir -p "$ORCHESTRATION_DIR"

  # doc-v1/doc-v2/doc-v3: the shared Task 11 location-stability fixtures
  # (v2 inserts paragraphs before an unchanged section; v3 repeats a sibling
  # heading) -- see tests/lib/v2_fixtures.sh for the exact shape.
  write_finding_location_fixtures "$T11_DIR"
  _t11_line_v1="$FINDING_FIXTURE_LINE_V1"
  _t11_line_v2="$FINDING_FIXTURE_LINE_V2"
  _t11_line_o1="$FINDING_FIXTURE_LINE_O1"
  _t11_line_o2="$FINDING_FIXTURE_LINE_O2"
  [ -n "$_t11_line_v1" ] && [ -n "$_t11_line_v2" ] && [ "$_t11_line_v1" != "$_t11_line_v2" ] \
    && _ok "T11 fixture: doc-v2's insertion actually shifted the flagged line number" \
    || _fail "T11 fixture setup is broken: v1/v2 flagged line numbers did not differ ($_t11_line_v1 vs $_t11_line_v2)"

  _t11_mk_status() {
    # Usage: _t11_mk_status STATUS_PATH FINDINGS_JSONL_PATH PHASE ITER
    printf 'verdict: CHANGES_REQUESTED\nreason: findings present\nblockers: 0\nmajors: 1\nminors: 0\nfindings: %s\nphase: %s\niteration: %s\n' \
      "$2" "$3" "$4" > "$1"
  }
  _t11_status_pass() {
    # Usage: _t11_status_pass STATUS_PATH FINDINGS_JSONL_PATH PHASE ITER
    printf 'verdict: PASS\nreason: null\nblockers: 0\nmajors: 0\nminors: 0\nfindings: %s\nphase: %s\niteration: %s\n' \
      "$2" "$3" "$4" > "$1"
  }
  _t11_attempt_dir() {
    # Usage: _t11_attempt_dir PHASE_NAME ITER LABEL
    # $PHASE_DIR/$ITERATION/attempts/<label> -- matches the REAL convention
    # (code review fix, round 4: the retired "iteration-NN" shape must not
    # survive anywhere, including this fixture helper).
    local d="$T11_DIR/$1-review/$2/attempts/$3"
    mkdir -p "$d"
    printf '%s\n' "$d"
  }

  # ---- Assertions 1 and 4 (Step 1): unchanged AST node after an earlier
  # insertion keeps its finding_id; the evidence line still moves. ----------
  _t11_d1="$(_t11_attempt_dir 3-spec 01 v1)"
  jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
    {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
     phase:"3", iteration:"01", severity:"major", artifact_path:$p,
     artifact_revision:"rev1", location:"Details", line:$line,
     issue_key:"unclear-detail", summary:"s", evidence:"e",
     required_change:"c", provenance:"unknown", related_finding_ids:[]}' \
    > "$_t11_d1/claude-findings.jsonl"
  _t11_mk_status "$_t11_d1/STATUS.md" "$_t11_d1/claude-findings.jsonl" 3 01
  ingest_findings spec-reviewer-claude "$_t11_d1/STATUS.md" "$_t11_d1/claude-findings.jsonl" >/dev/null
  _t11_cat1="$T11_DIR/3-spec-review/01/findings-catalog.jsonl"
  _t11_id_v1="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat1")"
  _t11_line_stored_v1="$(jq -r 'select(.source_finding_id=="F1") | .line' "$_t11_cat1")"

  _t11_d2="$(_t11_attempt_dir 3-spec 02 v2)"
  jq -cn --arg p "$T11_DIR/doc-v2.md" --argjson line "$_t11_line_v2" '
    {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
     phase:"3", iteration:"02", severity:"major", artifact_path:$p,
     artifact_revision:"rev2", location:"Details", line:$line,
     issue_key:"unclear-detail", summary:"s", evidence:"e",
     required_change:"c", provenance:"unknown", related_finding_ids:[]}' \
    > "$_t11_d2/claude-findings.jsonl"
  _t11_mk_status "$_t11_d2/STATUS.md" "$_t11_d2/claude-findings.jsonl" 3 02
  ingest_findings spec-reviewer-claude "$_t11_d2/STATUS.md" "$_t11_d2/claude-findings.jsonl" >/dev/null
  _t11_cat2="$T11_DIR/3-spec-review/02/findings-catalog.jsonl"
  _t11_id_v2="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat2")"
  _t11_line_stored_v2="$(jq -r 'select(.source_finding_id=="F1") | .line' "$_t11_cat2")"

  assert_eq "$_t11_id_v1" "$_t11_id_v2" \
    "Step1#1/#4: an unchanged AST node keeps its finding_id after earlier-inserted paragraphs shift its line number"
  [ "$_t11_line_stored_v1" != "$_t11_line_stored_v2" ] \
    && _ok "Step1#4: the evidence line DID change even though the finding_id did not" \
    || _fail "Step1#4: evidence line should differ between v1 and v2"

  # ---- Assertion 2 (Step 1): same issue under repeated sibling heading #1
  # vs #2 gets a DIFFERENT finding_id. ---------------------------------------
  _t11_d3="$(_t11_attempt_dir 3-spec 03 v3)"
  { jq -cn --arg p "$T11_DIR/doc-v3.md" --argjson line "$_t11_line_o1" \
      '{source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
        phase:"3", iteration:"03", severity:"major", artifact_path:$p,
        artifact_revision:"rev3", location:"Details", line:$line,
        issue_key:"same-issue", summary:"s", evidence:"e", required_change:"c",
        provenance:"unknown", related_finding_ids:[]}'
    jq -cn --arg p "$T11_DIR/doc-v3.md" --argjson line "$_t11_line_o2" \
      '{source_finding_id:"F2", reviewer_role:"spec-reviewer-claude", vendor:"claude",
        phase:"3", iteration:"03", severity:"major", artifact_path:$p,
        artifact_revision:"rev3", location:"Details", line:$line,
        issue_key:"same-issue", summary:"s", evidence:"e", required_change:"c",
        provenance:"unknown", related_finding_ids:[]}'
  } > "$_t11_d3/claude-findings.jsonl"
  _t11_mk_status "$_t11_d3/STATUS.md" "$_t11_d3/claude-findings.jsonl" 3 03
  ingest_findings spec-reviewer-claude "$_t11_d3/STATUS.md" "$_t11_d3/claude-findings.jsonl" >/dev/null
  _t11_cat3="$T11_DIR/3-spec-review/03/findings-catalog.jsonl"
  _t11_id_o1="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat3")"
  _t11_id_o2="$(jq -r 'select(.source_finding_id=="F2") | .finding_id' "$_t11_cat3")"
  [ -n "$_t11_id_o1" ] && [ -n "$_t11_id_o2" ] && [ "$_t11_id_o1" != "$_t11_id_o2" ] \
    && _ok "Step1#2: the same issue under sibling heading occurrence #1 vs #2 gets a DIFFERENT finding_id" \
    || _fail "Step1#2: repeated-sibling-heading disambiguation is broken ($_t11_id_o1 vs $_t11_id_o2)"

  # ---- Assertion 3 (Step 1): a changed issue key at the SAME node gets a
  # DIFFERENT finding_id. ----------------------------------------------------
  _t11_d4="$(_t11_attempt_dir 3-spec 04 v4)"
  { jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" \
      '{source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
        phase:"3", iteration:"04", severity:"major", artifact_path:$p,
        artifact_revision:"rev1", location:"Details", line:$line,
        issue_key:"issue-a", summary:"s", evidence:"e", required_change:"c",
        provenance:"unknown", related_finding_ids:[]}'
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" \
      '{source_finding_id:"F2", reviewer_role:"spec-reviewer-claude", vendor:"claude",
        phase:"3", iteration:"04", severity:"major", artifact_path:$p,
        artifact_revision:"rev1", location:"Details", line:$line,
        issue_key:"issue-b", summary:"s", evidence:"e", required_change:"c",
        provenance:"unknown", related_finding_ids:[]}'
  } > "$_t11_d4/claude-findings.jsonl"
  _t11_mk_status "$_t11_d4/STATUS.md" "$_t11_d4/claude-findings.jsonl" 3 04
  ingest_findings spec-reviewer-claude "$_t11_d4/STATUS.md" "$_t11_d4/claude-findings.jsonl" >/dev/null
  _t11_cat4="$T11_DIR/3-spec-review/04/findings-catalog.jsonl"
  _t11_id_ka="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat4")"
  _t11_id_kb="$(jq -r 'select(.source_finding_id=="F2") | .finding_id' "$_t11_cat4")"
  [ -n "$_t11_id_ka" ] && [ -n "$_t11_id_kb" ] && [ "$_t11_id_ka" != "$_t11_id_kb" ] \
    && _ok "Step1#3: a changed issue key at the same node gets a DIFFERENT finding_id" \
    || _fail "Step1#3: issue-key change did not change the finding_id"

  # ---- Step 6: a model-supplied canonical finding_id that DISAGREES with
  # the deterministic hash is rejected, never silently trusted. -------------
  _t11_d5="$(_t11_attempt_dir 3-spec 05 badid)"
  jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
    {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
     phase:"3", iteration:"05", severity:"major", artifact_path:$p,
     artifact_revision:"rev1", location:"Details", line:$line,
     issue_key:"unclear-detail", summary:"s", evidence:"e", required_change:"c",
     provenance:"unknown", related_finding_ids:[], finding_id:"not-the-real-hash"}' \
    > "$_t11_d5/claude-findings.jsonl"
  _t11_mk_status "$_t11_d5/STATUS.md" "$_t11_d5/claude-findings.jsonl" 3 05
  rc=0
  ingest_findings spec-reviewer-claude "$_t11_d5/STATUS.md" "$_t11_d5/claude-findings.jsonl" \
    >/dev/null 2>"$BUILD/t11-badid.err" || rc=$?
  assert_rc 1 "$rc" "ingest_findings rejects a model-supplied finding_id that disagrees with the computed hash"
  assert_contains "INGEST_FINDINGS_ID_MISMATCH" "$BUILD/t11-badid.err" "mismatch failure names itself"

  # ---- Step 6: a canonical-ID collision with CONFLICTING content is
  # rejected (never guessed) and routed to EVENT_CORRECTED. -----------------
  _t11_d6="$(_t11_attempt_dir 3-spec 06 coll)"
  jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
    {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
     phase:"3", iteration:"06", severity:"major", artifact_path:$p,
     artifact_revision:"rev1", location:"Details", line:$line,
     issue_key:"unclear-detail", summary:"original summary", evidence:"e",
     required_change:"c", provenance:"unknown", related_finding_ids:[]}' \
    > "$_t11_d6/claude-findings.jsonl"
  _t11_mk_status "$_t11_d6/STATUS.md" "$_t11_d6/claude-findings.jsonl" 3 06
  ingest_findings spec-reviewer-claude "$_t11_d6/STATUS.md" "$_t11_d6/claude-findings.jsonl" >/dev/null
  _t11_d6b="$(_t11_attempt_dir 3-spec 06 collb)"
  jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
    {source_finding_id:"F1", reviewer_role:"spec-reviewer-codex", vendor:"codex",
     phase:"3", iteration:"06", severity:"blocker", artifact_path:$p,
     artifact_revision:"rev1", location:"Details", line:$line,
     issue_key:"unclear-detail", summary:"CONFLICTING summary", evidence:"e",
     required_change:"different change", provenance:"unknown", related_finding_ids:[]}' \
    > "$_t11_d6b/codex-findings.jsonl"
  _t11_mk_status "$_t11_d6b/STATUS.md" "$_t11_d6b/codex-findings.jsonl" 3 06
  RUN_LOG="$T11_DIR/RUN_LOG.md"; : > "$RUN_LOG"
  ingest_findings spec-reviewer-codex "$_t11_d6b/STATUS.md" "$_t11_d6b/codex-findings.jsonl" >/dev/null
  _t11_cat6="$T11_DIR/3-spec-review/06/findings-catalog.jsonl"
  # codex reported severity=blocker (rank 0), claude reported severity=major
  # (rank 1) for the SAME canonical finding_id -- the MORE severe
  # classification wins (never merely whichever arrived first), so the kept
  # entry is codex's, not claude's earlier one.
  assert_eq "CONFLICTING summary" "$(jq -r 'select(.finding_id!=null) | .summary' "$_t11_cat6" | head -1)" \
    "a conflicting-severity collision keeps the MORE SEVERE catalog entry, never a first-writer-wins guess"
  assert_present '^--- .*event=EVENT_CORRECTED' "$RUN_LOG" \
    "a canonical-ID collision with conflicting content is durably recorded as EVENT_CORRECTED"
  assert_present 'replacement_classification:.*finding_collision' "$RUN_LOG" \
    "the EVENT_CORRECTED record classifies itself as a finding_collision"

  # ---- Spec S16.5 / Step 9 proof: one reviewer's PASS cannot cancel the
  # other's blocker -- the union survives even when the SECOND reviewer to
  # ingest reports nothing at all. -------------------------------------------
  _t11_d7="$(_t11_attempt_dir 3-spec 07 blocker)"
  jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
    {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
     phase:"3", iteration:"07", severity:"blocker", artifact_path:$p,
     artifact_revision:"rev1", location:"Details", line:$line,
     issue_key:"real-bug", summary:"s", evidence:"e", required_change:"c",
     provenance:"unknown", related_finding_ids:[]}' \
    > "$_t11_d7/claude-findings.jsonl"
  _t11_mk_status "$_t11_d7/STATUS.md" "$_t11_d7/claude-findings.jsonl" 3 07
  _t11_out1="$(ingest_findings spec-reviewer-claude "$_t11_d7/STATUS.md" "$_t11_d7/claude-findings.jsonl")"
  _t11_d7b="$(_t11_attempt_dir 3-spec 07 pass)"
  : > "$_t11_d7b/codex-findings.jsonl"
  _t11_status_pass "$_t11_d7b/STATUS.md" "$_t11_d7b/codex-findings.jsonl" 3 07
  _t11_out2="$(ingest_findings spec-reviewer-codex "$_t11_d7b/STATUS.md" "$_t11_d7b/codex-findings.jsonl")"
  printf '%s\n' "$_t11_out2" | "$GREP_BIN" -qE '^blockers=[1-9]' \
    && _ok "S16.5/Step9: reviewer B's clean PASS never cancels reviewer A's open blocker in the shared catalog" \
    || _fail "S16.5/Step9: the union lost reviewer A's blocker after reviewer B reported PASS ($_t11_out2)"

  # ---- record_finding_disposition / dispositions_complete: the six-value
  # vocabulary, "no assigned finding may disappear", and "a fixer cannot
  # close its own findings" (spec S17.3 / S18.1). --------------------------
  if declare -F record_finding_disposition >/dev/null && declare -F dispositions_complete >/dev/null; then
    _t11_cat7="$T11_DIR/3-spec-review/07/findings-catalog.jsonl"
    _t11_fid7="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat7")"

    rc=0
    record_finding_disposition "$_t11_cat7" "$_t11_fid7" "not-a-real-disposition" \
      2>"$BUILD/t11-baddisp.err" || rc=$?
    assert_rc 1 "$rc" "record_finding_disposition rejects a disposition outside the six-value grammar"

    record_finding_disposition "$_t11_cat7" "$_t11_fid7" "fixed" "patched it" >/dev/null
    _t11_status_after_fix="$(jq -r --arg id "$_t11_fid7" 'select(.finding_id==$id) | .status' "$_t11_cat7")"
    assert_eq "fixed" "$_t11_status_after_fix" \
      "record_finding_disposition moves an assigned finding to 'fixed'"
    [ "$_t11_status_after_fix" != "verified" ] \
      && _ok "Step9 proof: a fixer's own disposition can NEVER produce status=verified (only a later reviewer round can)" \
      || _fail "Step9 proof VIOLATED: a fixer's own disposition produced 'verified'"

    dispositions_complete "$_t11_cat7" "$_t11_fid7" \
      && _ok "dispositions_complete: an assigned finding WITH a disposition is complete" \
      || _fail "dispositions_complete should report complete once every assigned ID has a disposition"

    rc=0
    dispositions_complete "$_t11_cat7" "$_t11_fid7" "not-a-real-finding-id" 2>"$BUILD/t11-missingdisp.err" || rc=$?
    assert_rc 1 "$rc" "dispositions_complete: an unknown/undispositioned assigned ID is reported missing"
    assert_contains "DISPOSITIONS_MISSING" "$BUILD/t11-missingdisp.err" "the missing-disposition failure names itself"

    # Only a FRESH reviewer round (never the fixer) can promote fixed ->
    # verified: re-ingest THIS SAME iteration with an empty (clean) round
    # from the SAME reviewer track and confirm the fixed finding is no
    # longer reported as open/reopened afterward.
    _t11_d7c="$T11_DIR/3-spec-review/07/attempts/reverify"
    mkdir -p "$_t11_d7c"
    : > "$_t11_d7c/claude-findings.jsonl"
    _t11_status_pass "$_t11_d7c/STATUS.md" "$_t11_d7c/claude-findings.jsonl" 3 07
    ingest_findings spec-reviewer-claude "$_t11_d7c/STATUS.md" "$_t11_d7c/claude-findings.jsonl" >/dev/null
    _t11_status_reverified="$(jq -r --arg id "$_t11_fid7" 'select(.finding_id==$id) | .status' "$_t11_cat7")"
    assert_eq "verified" "$_t11_status_reverified" \
      "a subsequent reviewer round silently not re-reporting a 'fixed' finding is what promotes it to 'verified' -- never the fixer itself"

    # Subsumption is explicit: a subsumed_by disposition records the winning ID.
    record_finding_disposition "$_t11_cat6" "$(jq -r '.finding_id' "$_t11_cat6" | head -1)" \
      "subsumed_by:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "split from F1" >/dev/null
    _t11_subsumed_disp="$(jq -r '.disposition' "$_t11_cat6" | head -1)"
    case "$_t11_subsumed_disp" in
      subsumed_by:*) _ok "Step9 proof: subsumption is explicit -- the winning finding_id is recorded in the disposition" ;;
      *) _fail "subsumed_by disposition was not recorded verbatim: [$_t11_subsumed_disp]" ;;
    esac

    # ---- CODE REVIEW FIX (Blocker 1): a re-reported, REWORDED finding
    # must never be silently dropped nor promoted to verified. Fresh
    # reviewer subprocesses write their OWN summary/required_change prose
    # every round -- byte-identical text across rounds is the unlikely
    # case, so this is the normal path, not an edge case. -------------------
    _t11_d9="$(_t11_attempt_dir 3-spec 09 rewordA)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"09", severity:"blocker", artifact_path:$p,
       artifact_revision:"revA", location:"Details", line:$line,
       issue_key:"unclear-detail", summary:"round-1 wording", evidence:"e",
       required_change:"c", provenance:"unknown", related_finding_ids:[]}'       > "$_t11_d9/claude-findings.jsonl"
    _t11_mk_status "$_t11_d9/STATUS.md" "$_t11_d9/claude-findings.jsonl" 3 09
    _t11_out9a="$(ingest_findings spec-reviewer-claude "$_t11_d9/STATUS.md" "$_t11_d9/claude-findings.jsonl")"
    printf '%s\n' "$_t11_out9a" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "reworded-blocker regression: round 1 ingest shows blockers=1" \
      || _fail "reworded-blocker regression fixture setup broken: [$_t11_out9a]"
    _t11_cat9="$T11_DIR/3-spec-review/09/findings-catalog.jsonl"
    _t11_fid9="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat9")"
    record_finding_disposition "$_t11_cat9" "$_t11_fid9" fixed "patched" >/dev/null

    _t11_d9b="$(_t11_attempt_dir 3-spec 09 rewordB)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"09", severity:"blocker", artifact_path:$p,
       artifact_revision:"revB", location:"Details", line:$line,
       issue_key:"unclear-detail", summary:"round-2 wording, completely reworded", evidence:"e2",
       required_change:"a different phrasing of the same required fix", provenance:"unknown",
       related_finding_ids:[]}' \
      > "$_t11_d9b/claude-findings.jsonl"
    _t11_mk_status "$_t11_d9b/STATUS.md" "$_t11_d9b/claude-findings.jsonl" 3 09
    _t11_out9b="$(ingest_findings spec-reviewer-claude "$_t11_d9b/STATUS.md" "$_t11_d9b/claude-findings.jsonl")"
    printf '%s\n' "$_t11_out9b" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "Blocker1 regression: a reworded re-report of a 'fixed' blocker stays an open blocker (never silently verified)" \
      || _fail "Blocker1 REGRESSION: reworded re-report was dropped/verified, got: [$_t11_out9b]"
    _t11_status9="$(jq -r --arg id "$_t11_fid9" 'select(.finding_id==$id) | .status' "$_t11_cat9")"
    assert_eq "reopened" "$_t11_status9" \
      "the reworded re-report's status is 'reopened' (fix_regression), never 'verified'"

    # ---- CODE REVIEW FIX (Blocker 2): blocked/already_satisfied/
    # subsumed_by must map onto the mandated status vocabulary and never
    # permanently remove a finding from the gate counts (only
    # accepted_risk/deferred -- an explicit, typed decision -- may). -------
    _t11_d10="$(_t11_attempt_dir 3-spec 10 blk)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"10", severity:"blocker", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"needs-decision", summary:"s", evidence:"e", required_change:"c",
       provenance:"unknown", related_finding_ids:[]}' > "$_t11_d10/claude-findings.jsonl"
    _t11_mk_status "$_t11_d10/STATUS.md" "$_t11_d10/claude-findings.jsonl" 3 10
    ingest_findings spec-reviewer-claude "$_t11_d10/STATUS.md" "$_t11_d10/claude-findings.jsonl" >/dev/null
    _t11_cat10="$T11_DIR/3-spec-review/10/findings-catalog.jsonl"
    _t11_fid10="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat10")"
    record_finding_disposition "$_t11_cat10" "$_t11_fid10" blocked "missing authority" >/dev/null
    _t11_status10="$(jq -r --arg id "$_t11_fid10" 'select(.finding_id==$id) | .status' "$_t11_cat10")"
    assert_eq "open" "$_t11_status10" \
      "Blocker2 regression: a 'blocked' disposition on a blocker keeps status=open (never silently closes the gate)"
    case " $(select_finding_batch "$_t11_cat10") " in
      *" $_t11_fid10 "*) _ok "Blocker2 regression: a 'blocked' finding is STILL in the fixer batch (still blocking)" ;;
      *) _fail "Blocker2 REGRESSION: a 'blocked' finding vanished from select_finding_batch" ;;
    esac

    _t11_d11="$(_t11_attempt_dir 3-spec 11 minor)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"11", severity:"blocker", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"already-fine", summary:"s", evidence:"e", required_change:"c",
       provenance:"unknown", related_finding_ids:[]}' > "$_t11_d11/claude-findings.jsonl"
    _t11_mk_status "$_t11_d11/STATUS.md" "$_t11_d11/claude-findings.jsonl" 3 11
    ingest_findings spec-reviewer-claude "$_t11_d11/STATUS.md" "$_t11_d11/claude-findings.jsonl" >/dev/null
    _t11_cat11="$T11_DIR/3-spec-review/11/findings-catalog.jsonl"
    _t11_fid11="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat11")"
    record_finding_disposition "$_t11_cat11" "$_t11_fid11" already_satisfied "already correct" >/dev/null
    _t11_status11="$(jq -r --arg id "$_t11_fid11" 'select(.finding_id==$id) | .status' "$_t11_cat11")"
    assert_eq "fixed" "$_t11_status11" \
      "Blocker2 regression: 'already_satisfied' maps to status=fixed -- same fixer-cannot-verify-itself rule as an actual fix"

    _t11_d12="$(_t11_attempt_dir 3-spec 12 sub)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"12", severity:"major", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"dup-of-other", summary:"s", evidence:"e", required_change:"c",
       provenance:"unknown", related_finding_ids:[]}' > "$_t11_d12/claude-findings.jsonl"
    _t11_mk_status "$_t11_d12/STATUS.md" "$_t11_d12/claude-findings.jsonl" 3 12
    ingest_findings spec-reviewer-claude "$_t11_d12/STATUS.md" "$_t11_d12/claude-findings.jsonl" >/dev/null
    _t11_cat12="$T11_DIR/3-spec-review/12/findings-catalog.jsonl"
    _t11_fid12="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat12")"
    record_finding_disposition "$_t11_cat12" "$_t11_fid12" \
      "subsumed_by:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
      "merged into the other finding" >/dev/null
    _t11_status12="$(jq -r --arg id "$_t11_fid12" 'select(.finding_id==$id) | .status' "$_t11_cat12")"
    assert_eq "superseded" "$_t11_status12" \
      "Blocker2 regression: 'subsumed_by' maps to the mandated status=superseded (spec S17.2), never a bespoke token"

    # ---- CODE REVIEW FIX (Major 6): one reviewer's MAJOR must never
    # silently cancel the OTHER reviewer's BLOCKER at the SAME canonical
    # finding -- the more severe classification always wins, and the
    # disagreement is still durably recorded (EVENT_CORRECTED). -----------
    _t11_d13a="$(_t11_attempt_dir 3-spec 13 sevA)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"13", severity:"major", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"disputed-severity", summary:"claude thinks this is a major", evidence:"e",
       required_change:"c", provenance:"unknown", related_finding_ids:[]}' > "$_t11_d13a/claude-findings.jsonl"
    _t11_mk_status "$_t11_d13a/STATUS.md" "$_t11_d13a/claude-findings.jsonl" 3 13
    ingest_findings spec-reviewer-claude "$_t11_d13a/STATUS.md" "$_t11_d13a/claude-findings.jsonl" >/dev/null

    : > "$T11_DIR/RUN_LOG.md"
    _t11_d13b="$(_t11_attempt_dir 3-spec 13 sevB)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-codex", vendor:"codex",
       phase:"3", iteration:"13", severity:"blocker", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"disputed-severity", summary:"codex thinks this is a blocker", evidence:"e2",
       required_change:"c2", provenance:"unknown", related_finding_ids:[]}' > "$_t11_d13b/codex-findings.jsonl"
    _t11_mk_status "$_t11_d13b/STATUS.md" "$_t11_d13b/codex-findings.jsonl" 3 13
    _t11_out13b="$(ingest_findings spec-reviewer-codex "$_t11_d13b/STATUS.md" "$_t11_d13b/codex-findings.jsonl")"
    printf '%s\n' "$_t11_out13b" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "Major6 regression: the MORE severe classification (blocker) wins over the earlier major, never dropped" \
      || _fail "Major6 REGRESSION: a blocker was cancelled by an earlier major, got: [$_t11_out13b]"
    assert_present '^--- .*event=EVENT_CORRECTED' "$T11_DIR/RUN_LOG.md" \
      "Major6 regression: the severity disagreement is still durably recorded as EVENT_CORRECTED"

    # ---- CODE REVIEW FIX (Major A -- new regression from the Blocker-6
    # fix): a SEVERITY DOWNGRADE re-report must still reopen a fixed/
    # verified finding -- an earlier version of the severity-conflict fix
    # `continue`d past the reopen block whenever prior was more severe,
    # letting a fixer's stale "fixed" claim survive a contradicting review
    # entirely (the same failure class as Blocker 1, reached via severity
    # instead of wording). ---------------------------------------------
    _t11_d15="$(_t11_attempt_dir 3-spec 15 downgradeA)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"15", severity:"blocker", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"downgrade-case", summary:"round1", evidence:"e", required_change:"c",
       provenance:"unknown", related_finding_ids:[]}' > "$_t11_d15/claude-findings.jsonl"
    _t11_mk_status "$_t11_d15/STATUS.md" "$_t11_d15/claude-findings.jsonl" 3 15
    _t11_out15a="$(ingest_findings spec-reviewer-claude "$_t11_d15/STATUS.md" "$_t11_d15/claude-findings.jsonl")"
    printf '%s\n' "$_t11_out15a" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "downgrade regression: round 1 ingest shows blockers=1" \
      || _fail "downgrade regression fixture setup broken: [$_t11_out15a]"
    _t11_cat15="$T11_DIR/3-spec-review/15/findings-catalog.jsonl"
    _t11_fid15="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat15")"
    record_finding_disposition "$_t11_cat15" "$_t11_fid15" fixed "patched" >/dev/null

    _t11_d15b="$(_t11_attempt_dir 3-spec 15 downgradeB)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"15", severity:"major", artifact_path:$p,
       artifact_revision:"r2", location:"Details", line:$line,
       issue_key:"downgrade-case", summary:"round2, downgraded to major", evidence:"e2",
       required_change:"c2", provenance:"unknown", related_finding_ids:[]}' > "$_t11_d15b/claude-findings.jsonl"
    _t11_mk_status "$_t11_d15b/STATUS.md" "$_t11_d15b/claude-findings.jsonl" 3 15
    _t11_out15b="$(ingest_findings spec-reviewer-claude "$_t11_d15b/STATUS.md" "$_t11_d15b/claude-findings.jsonl")"
    printf '%s\n' "$_t11_out15b" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "MajorA regression: a severity-downgraded re-report of a 'fixed' blocker still reopens (stays blockers=1)" \
      || _fail "MajorA REGRESSION: a severity-downgraded re-report let a fixed blocker vanish, got: [$_t11_out15b]"
    _t11_status15="$(jq -r --arg id "$_t11_fid15" 'select(.finding_id==$id) | .status' "$_t11_cat15")"
    assert_eq "reopened" "$_t11_status15" \
      "the downgraded re-report's status is 'reopened', never left at 'fixed'"
    _t11_sev15="$(jq -r --arg id "$_t11_fid15" 'select(.finding_id==$id) | .severity' "$_t11_cat15")"
    assert_eq "blocker" "$_t11_sev15" \
      "the historically more-severe classification (blocker) is kept, not silently downgraded to major"

    # ---- CODE REVIEW FIX (round 4, item 1 -- P4): a finding already
    # PROMOTED to 'verified' (by an earlier round's silence) must still
    # reopen when a LATER round re-reports it -- mutating the reopen
    # check's tuple from `("fixed", "verified")` to `("fixed",)` alone
    # leaves a re-reported 'verified' finding stuck at 'verified' and
    # invisible to the gate. Continues the _t11_cat9/_t11_fid9 fixture. --
    record_finding_disposition "$_t11_cat9" "$_t11_fid9" fixed "patched again" >/dev/null
    _t11_d17_silent="$(_t11_attempt_dir 3-spec 09 p4silent)"
    : > "$_t11_d17_silent/claude-findings.jsonl"
    _t11_status_pass "$_t11_d17_silent/STATUS.md" "$_t11_d17_silent/claude-findings.jsonl" 3 09
    ingest_findings spec-reviewer-claude "$_t11_d17_silent/STATUS.md" "$_t11_d17_silent/claude-findings.jsonl" >/dev/null
    assert_eq "verified" "$(jq -r --arg id "$_t11_fid9" 'select(.finding_id==$id) | .status' "$_t11_cat9")" \
      "P4 fixture setup: silence after a second 'fixed' disposition promotes to verified"
    _t11_d17="$(_t11_attempt_dir 3-spec 09 p4reopen)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"09", severity:"blocker", artifact_path:$p,
       artifact_revision:"r3", location:"Details", line:$line,
       issue_key:"unclear-detail", summary:"round-4 wording, still broken", evidence:"e4",
       required_change:"c4", provenance:"unknown", related_finding_ids:[]}' > "$_t11_d17/claude-findings.jsonl"
    _t11_mk_status "$_t11_d17/STATUS.md" "$_t11_d17/claude-findings.jsonl" 3 09
    _t11_out17="$(ingest_findings spec-reviewer-claude "$_t11_d17/STATUS.md" "$_t11_d17/claude-findings.jsonl")"
    printf '%s\n' "$_t11_out17" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "P4 regression: a re-reported 'verified' finding reopens (blockers=1)" \
      || _fail "P4 REGRESSION: a re-reported 'verified' finding stayed invisible, got: [$_t11_out17]"
    assert_eq "reopened" "$(jq -r --arg id "$_t11_fid9" 'select(.finding_id==$id) | .status' "$_t11_cat9")" \
      "P4 regression: status is 'reopened', never left at 'verified'"

    # ---- CODE REVIEW FIX (round 4, item 1 -- P5): a finding disposed
    # `deferred`/`accepted_risk`/`subsumed_by` (status
    # deferred/accepted_risk/superseded) must reopen when re-reported --
    # this is the exact mechanism the iteration-3+ relaxed gate depends on
    # ("a major triggers another round only until it carries an explicit
    # disposition"); deleting the reopen mapping for these three statuses
    # makes a still-broken deferred major permanently invisible. Continues
    # the _t11_cat15/_t11_fid15 fixture. ---------------------------------
    record_finding_disposition "$_t11_cat15" "$_t11_fid15" "deferred:followup-1" "deferred to a followup" >/dev/null
    assert_eq "deferred" "$(jq -r --arg id "$_t11_fid15" 'select(.finding_id==$id) | .status' "$_t11_cat15")" \
      "P5 fixture setup: the deferred disposition is recorded"
    _t11_d18="$(_t11_attempt_dir 3-spec 15 p5reopen)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"15", severity:"blocker", artifact_path:$p,
       artifact_revision:"r4", location:"Details", line:$line,
       issue_key:"downgrade-case", summary:"round3, still broken despite deferral", evidence:"e3",
       required_change:"c3", provenance:"unknown", related_finding_ids:[]}' > "$_t11_d18/claude-findings.jsonl"
    _t11_mk_status "$_t11_d18/STATUS.md" "$_t11_d18/claude-findings.jsonl" 3 15
    _t11_out18="$(ingest_findings spec-reviewer-claude "$_t11_d18/STATUS.md" "$_t11_d18/claude-findings.jsonl")"
    printf '%s\n' "$_t11_out18" | "$GREP_BIN" -qE '^blockers=1$' \
      && _ok "P5 regression: a re-reported 'deferred' finding reopens (blockers=1)" \
      || _fail "P5 REGRESSION: a re-reported 'deferred' finding stayed invisible, got: [$_t11_out18]"
    assert_eq "reopened" "$(jq -r --arg id "$_t11_fid15" 'select(.finding_id==$id) | .status' "$_t11_cat15")" \
      "P5 regression: status is 'reopened', never left at 'deferred'"

    # ---- CODE REVIEW FIX (round 4, item 1 -- P7 adjacent): the promotion
    # loop's own condition must never promote anything but a literal
    # 'fixed' status -- a still-broken 'reopened' finding that a later
    # round is silent about must NOT be swept up into 'verified' by that
    # silence (only a genuine 'fixed' disposition, followed by silence,
    # earns promotion). NOTE: the literal `seen_this_round` guard itself
    # (spec_ 18.1's belt-and-suspenders line "if fid in seen_this_round:
    # continue") is PROVEN unreachable dead code given the reopen block
    # above: mutation-tested directly (removing just that guard) against
    # this entire suite and got 0 failures, because no per-record path can
    # ever leave a freshly-processed entry's status=='fixed' (it is always
    # rewritten to reopened/open/deferred/accepted_risk/superseded first).
    # This assertion instead pins the promotion CONDITION itself, which is
    # the only currently-reachable half of that same safety property.
    _t11_d19="$(_t11_attempt_dir 3-spec 09 p7silent)"
    : > "$_t11_d19/claude-findings.jsonl"
    _t11_status_pass "$_t11_d19/STATUS.md" "$_t11_d19/claude-findings.jsonl" 3 09
    ingest_findings spec-reviewer-claude "$_t11_d19/STATUS.md" "$_t11_d19/claude-findings.jsonl" >/dev/null
    assert_eq "reopened" "$(jq -r --arg id "$_t11_fid9" 'select(.finding_id==$id) | .status' "$_t11_cat9")" \
      "P7-adjacent regression: a still-'reopened' finding is NOT promoted to verified by mere silence"

    # ---- CODE REVIEW FIX (Medium C): same ID + same severity + genuinely
    # different content must still fire EVENT_CORRECTED (audit signal),
    # even though the merge always keeps the latest-ingested record
    # (never silently loses the SIGNAL, only ever the OLD content). ------
    _t11_d16a="$(_t11_attempt_dir 3-spec 16 contentA)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
       phase:"3", iteration:"16", severity:"blocker", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"same-node-diff-content", summary:"SQL injection in the query builder",
       evidence:"e", required_change:"parameterize the query", provenance:"unknown",
       related_finding_ids:[]}' > "$_t11_d16a/claude-findings.jsonl"
    _t11_mk_status "$_t11_d16a/STATUS.md" "$_t11_d16a/claude-findings.jsonl" 3 16
    ingest_findings spec-reviewer-claude "$_t11_d16a/STATUS.md" "$_t11_d16a/claude-findings.jsonl" >/dev/null

    : > "$T11_DIR/RUN_LOG.md"
    _t11_d16b="$(_t11_attempt_dir 3-spec 16 contentB)"
    jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" '
      {source_finding_id:"F1", reviewer_role:"spec-reviewer-codex", vendor:"codex",
       phase:"3", iteration:"16", severity:"blocker", artifact_path:$p,
       artifact_revision:"r", location:"Details", line:$line,
       issue_key:"same-node-diff-content", summary:"completely unrelated: missing auth check",
       evidence:"e2", required_change:"add an auth guard", provenance:"unknown",
       related_finding_ids:[]}' > "$_t11_d16b/codex-findings.jsonl"
    _t11_mk_status "$_t11_d16b/STATUS.md" "$_t11_d16b/codex-findings.jsonl" 3 16
    ingest_findings spec-reviewer-codex "$_t11_d16b/STATUS.md" "$_t11_d16b/codex-findings.jsonl" >/dev/null
    assert_present '^--- .*event=EVENT_CORRECTED' "$T11_DIR/RUN_LOG.md" \
      "MediumC regression: same ID/same severity but genuinely different content still fires EVENT_CORRECTED"

    # ---- CODE REVIEW FIX (round 4, item 3): an ORDINARY recurring finding
    # -- same severity, realistically reworded prose each round (fresh
    # reviewer subprocesses; NOT a topic change) -- must fire ZERO
    # EVENT_CORRECTED across many rounds. Measured before this fix: one
    # finding re-reported across four ordinary rounds emitted 3
    # EVENT_CORRECTED events, burying the genuine same-node conflicts the
    # signal exists to flag. -------------------------------------------
    : > "$T11_DIR/RUN_LOG.md"
    _t11_reword_summaries=(
      "The heading text under Details is ambiguous and does not specify which detail is required, leaving the reader unable to determine the exact requirement."
      "The heading text under Details remains ambiguous; it still does not specify which detail is required, so the reader cannot determine the exact requirement."
      "Still true this round: the Details heading is ambiguous and fails to specify which detail is required, so a reader still cannot determine the exact requirement."
      "Unresolved again: the Details heading stays ambiguous about which detail is required, and the reader still cannot pin down the exact requirement."
    )
    # Same $ITERATION for all four rounds -- ingest_findings' catalog is
    # per-iteration (spec S17.2), so "recurring across rounds" within one
    # gate iteration (repeat re-verification calls, same convention every
    # other T11 fixture in this file already uses) is what persists a
    # prior entry for ingest_findings to compare against.
    for _t11_idx in 0 1 2 3; do
      _t11_dOrd="$(_t11_attempt_dir 3-spec 20 "ordinary$_t11_idx")"
      jq -cn --arg p "$T11_DIR/doc-v1.md" --argjson line "$_t11_line_v1" \
        --arg summary "${_t11_reword_summaries[$_t11_idx]}" '
        {source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
         phase:"3", iteration:"20", severity:"major", artifact_path:$p,
         artifact_revision:"r", location:"Details", line:$line,
         issue_key:"ordinary-recurring", summary:$summary, evidence:"e",
         required_change:"clarify which specific detail the section requires",
         provenance:"unknown", related_finding_ids:[]}' \
        > "$_t11_dOrd/claude-findings.jsonl"
      _t11_mk_status "$_t11_dOrd/STATUS.md" "$_t11_dOrd/claude-findings.jsonl" 3 20
      ingest_findings spec-reviewer-claude "$_t11_dOrd/STATUS.md" "$_t11_dOrd/claude-findings.jsonl" >/dev/null
    done
    _t11_ordinary_corrections="$("$GREP_BIN" -c '^--- .*event=EVENT_CORRECTED' "$T11_DIR/RUN_LOG.md" || true)"
    assert_eq 0 "${_t11_ordinary_corrections:-0}" \
      "item3 regression: four ordinary rounds of the SAME recurring finding (realistic reword each time) fire ZERO EVENT_CORRECTED"
  else
    _fail "record_finding_disposition/dispositions_complete are not defined"
  fi

  # ---- CODE REVIEW FIX (Major 5): an explicit {#anchor} must NOT collapse
  # the per-line node locator -- two DIFFERENT findings under the SAME
  # anchored section, same issue_key, must still get DIFFERENT finding_ids
  # (spec S17.2's disambiguator), never silently merge into one entry via
  # EVENT_CORRECTED. -----------------------------------------------------
  cat > "$T11_DIR/doc-v4.md" <<'EOF'
# Root

## Section {#mysection}

First flagged line here.

Second flagged line here.
EOF
  _t11_line_anchor1="$("$GREP_BIN" -n 'First flagged line here' "$T11_DIR/doc-v4.md" | cut -d: -f1)"
  _t11_line_anchor2="$("$GREP_BIN" -n 'Second flagged line here' "$T11_DIR/doc-v4.md" | cut -d: -f1)"
  _t11_d14="$(_t11_attempt_dir 3-spec 14 anchor)"
  { jq -cn --arg p "$T11_DIR/doc-v4.md" --argjson line "$_t11_line_anchor1"       '{source_finding_id:"F1", reviewer_role:"spec-reviewer-claude", vendor:"claude",
        phase:"3", iteration:"14", severity:"major", artifact_path:$p,
        artifact_revision:"r", location:"Section", line:$line,
        issue_key:"dup-anchor-issue", summary:"s1", evidence:"e1", required_change:"c1",
        provenance:"unknown", related_finding_ids:[]}'
    jq -cn --arg p "$T11_DIR/doc-v4.md" --argjson line "$_t11_line_anchor2"       '{source_finding_id:"F2", reviewer_role:"spec-reviewer-claude", vendor:"claude",
        phase:"3", iteration:"14", severity:"major", artifact_path:$p,
        artifact_revision:"r", location:"Section", line:$line,
        issue_key:"dup-anchor-issue", summary:"s2", evidence:"e2", required_change:"c2",
        provenance:"unknown", related_finding_ids:[]}'
  } > "$_t11_d14/claude-findings.jsonl"
  _t11_mk_status "$_t11_d14/STATUS.md" "$_t11_d14/claude-findings.jsonl" 3 14
  ingest_findings spec-reviewer-claude "$_t11_d14/STATUS.md" "$_t11_d14/claude-findings.jsonl" >/dev/null
  _t11_cat14="$T11_DIR/3-spec-review/14/findings-catalog.jsonl"
  _t11_id_anchor1="$(jq -r 'select(.source_finding_id=="F1") | .finding_id' "$_t11_cat14")"
  _t11_id_anchor2="$(jq -r 'select(.source_finding_id=="F2") | .finding_id' "$_t11_cat14")"
  [ -n "$_t11_id_anchor1" ] && [ -n "$_t11_id_anchor2" ] && [ "$_t11_id_anchor1" != "$_t11_id_anchor2" ]     && _ok "Major5 regression: two distinct findings under the SAME {#anchor} section get DIFFERENT finding_ids"     || _fail "Major5 REGRESSION: an explicit anchor collapsed two distinct findings onto one finding_id ($_t11_id_anchor1 vs $_t11_id_anchor2)"

  # ---- select_finding_batch: bounded, blockers-first ordering. -------------
  if declare -F select_finding_batch >/dev/null; then
    _t11_batch="$(select_finding_batch "$_t11_cat4")"
    case " $_t11_batch " in
      *" $_t11_id_ka "*) _ok "select_finding_batch includes an open major finding" ;;
      *) _fail "select_finding_batch did not include the open major finding: [$_t11_batch]" ;;
    esac
  fi

  # ---- Convergence signals / divergence detection (spec S18.3). -----------
  if declare -F record_convergence_signals >/dev/null && declare -F divergence_check >/dev/null; then
    PHASE_DIR="$T11_DIR/conv-test"; mkdir -p "$PHASE_DIR"
    # Deletion can produce NEGATIVE growth.
    record_convergence_signals 3 "01" 1000 400 0 0 3 0 0 3 >/dev/null
    _t11_g1="$(tail -n1 "$PHASE_DIR/convergence.jsonl" | jq -r '.growth_pct')"
    [ "$_t11_g1" -lt 0 ] 2>/dev/null \
      && _ok "Step9 proof: deletion (bytes shrink) produces a NEGATIVE growth_pct" \
      || _fail "growth_pct should be negative for a shrinking artifact, got: $_t11_g1"

    # Two consecutive growing rounds (over threshold, non-decreasing open
    # blockers+majors) trigger divergence rule 3.
    rm -f "$PHASE_DIR/convergence.jsonl"
    record_convergence_signals 3 "01" 1000 1300 2 0 0 0 0 5 >/dev/null
    record_convergence_signals 3 "02" 1300 1700 2 0 0 0 0 5 >/dev/null
    _t11_div="$(divergence_check 3 "02" "$T11_DIR/no-such-catalog.jsonl")"
    case "$_t11_div" in
      yes:growth_without_reduction) _ok "Step9 proof: two growing rounds without reducing open blockers+majors trigger consolidation (divergence rule 3)" ;;
      *) _fail "divergence_check should report growth_without_reduction, got: [$_t11_div]" ;;
    esac

    # A fix-induced blocker that persists (still open, one iteration after
    # first appearing as a fix regression) is caught by rule 2.
    _t11_fixregress_cat="$T11_DIR/fixregress-catalog.jsonl"
    jq -cn '{finding_id:"x1", severity:"blocker", status:"reopened",
             provenance:"fix_regression", origin_iteration:"01", recur_count:0}' \
      > "$_t11_fixregress_cat"
    _t11_div2="$(divergence_check 3 "02" "$_t11_fixregress_cat")"
    case "$_t11_div2" in
      yes:fix_regression_persists) _ok "Step9 proof: a fix-induced blocker that persists across a round is caught (divergence rule 2)" ;;
      *) _fail "divergence_check should report fix_regression_persists, got: [$_t11_div2]" ;;
    esac

    # A finding fixed then reopened twice is caught by rule 1.
    _t11_recur_cat="$T11_DIR/recur-catalog.jsonl"
    jq -cn '{finding_id:"x2", severity:"major", status:"reopened",
             provenance:"fix_regression", origin_iteration:"01", recur_count:2}' \
      > "$_t11_recur_cat"
    _t11_div3="$(divergence_check 3 "03" "$_t11_recur_cat")"
    case "$_t11_div3" in
      yes:finding_recurred_twice) _ok "a finding fixed then recurring twice is caught (divergence rule 1)" ;;
      *) _fail "divergence_check should report finding_recurred_twice, got: [$_t11_div3]" ;;
    esac

    # Two consecutive rounds where the fixer reopens MORE blockers/majors
    # than reviewers verify resolved trigger divergence rule 4 -- growth
    # kept flat/negative so this isolates rule 4 from rule 3.
    PHASE_DIR="$T11_DIR/conv-test-r4"; mkdir -p "$PHASE_DIR"
    record_convergence_signals 3 "01" 1000 900 0 0 1 3 0 5 >/dev/null
    record_convergence_signals 3 "02" 900 850 0 0 1 4 0 6 >/dev/null
    _t11_div4="$(divergence_check 3 "02" "$T11_DIR/no-such-catalog-r4.jsonl")"
    case "$_t11_div4" in
      yes:fixer_reopens_more_than_resolved) _ok "Step9 proof: the fixer reopening more than it resolves for two consecutive rounds is caught (divergence rule 4)" ;;
      *) _fail "divergence_check should report fixer_reopens_more_than_resolved, got: [$_t11_div4]" ;;
    esac
  else
    _fail "record_convergence_signals/divergence_check are not defined"
  fi

  # ---- validate_artifact: structural manifest gate (spec S17.1). ----------
  # Uses role_attempt_dir's OWN derivation (phase/iteration decoded from the
  # dispatch_id string, never ambient $PHASE_DIR/$ITERATION) -- deliberately
  # setting ambient PHASE_DIR/ITERATION to a DIFFERENT phase (5-plan-review)
  # than the producer's real one (4-plan-writing) below, proving
  # validate_artifact ignores ambient state for this lookup (the exact
  # cross-phase bug this fixture would have masked otherwise).
  if declare -F validate_artifact >/dev/null; then
    PHASE_DIR="$T11_DIR/5-plan-review"; ITERATION="01"
    _t11_pw_dir="$FEATURE_FOLDER/4-plan-writing/00/attempts/p04-i00-plan-writer-a01"
    mkdir -p "$_t11_pw_dir"
    PLAN_PATH="$T11_DIR/plan.md"
    cat > "$PLAN_PATH" <<'EOF'
# Goal

Ship the thing end to end, with enough real prose here that the manifest's
minimum non-whitespace byte count is comfortably exceeded by a wide margin,
covering the goal, the approach, and the acceptance bar for this fixture.

# File Structure and Responsibilities

| Path | Action | Responsibility |
|---|---|---|
| foo.py | Modify | Add the new behavior under test |
| tests/test_foo.py | Modify | Cover the new behavior |
EOF
    printf '{"schema_version":2,"plan_path":"%s","completed_at":"1970-01-01T00:00:00Z"}\n' \
      "$PLAN_PATH" > "$_t11_pw_dir/artifact-complete.json"
    printf 'verdict: DONE\nreason: null\nartifact_revision: %s\n' \
      "$(sha256sum "$PLAN_PATH" | awk '{print $1}')" > "$_t11_pw_dir/STATUS.md"
    validate_artifact plan-writer p04-i00-plan-writer-a01 >/dev/null \
      && _ok "validate_artifact accepts a manifest-passing plan (headings present, size ok, revision matches, marker present)" \
      || _fail "validate_artifact rejected a genuinely valid plan"

    # Satisfy every OTHER manifest check (headings present, marker present)
    # so this negative case genuinely isolates the byte-count gate -- a tiny
    # file that ALSO fails headings/marker would still correctly return 1,
    # but would prove nothing about the size check specifically.
    rc=0
    printf '# Goal\n# File Structure and Responsibilities\n' > "$T11_DIR/plan-tiny.md"
    _t11_pw_dir2="$FEATURE_FOLDER/4-plan-writing/00/attempts/p04-i00-plan-writer-a02"
    mkdir -p "$_t11_pw_dir2"
    PLAN_PATH="$T11_DIR/plan-tiny.md"
    printf '{"schema_version":2,"plan_path":"%s","completed_at":"1970-01-01T00:00:00Z"}\n' \
      "$PLAN_PATH" > "$_t11_pw_dir2/artifact-complete.json"
    printf 'verdict: DONE\nreason: null\nartifact_revision: %s\n' \
      "$(sha256sum "$PLAN_PATH" | awk '{print $1}')" > "$_t11_pw_dir2/STATUS.md"
    validate_artifact plan-writer p04-i00-plan-writer-a02 >"$BUILD/t11-va-tiny.out" 2>"$BUILD/t11-va-tiny.err" || rc=$?
    assert_rc 1 "$rc" "validate_artifact rejects a plan below the manifest's minimum byte count"
    assert_contains "VALIDATE_ARTIFACT_TOO_SMALL" "$BUILD/t11-va-tiny.err" \
      "the size rejection specifically names itself (headings and marker both pass here)"

    rc=0
    PLAN_PATH="$T11_DIR/plan-nostatus.md"
    printf '# Goal\n\nFile Structure and Responsibilities present too.\n' > "$PLAN_PATH"
    validate_artifact plan-writer p04-i00-nonexistent-a01 >/dev/null 2>"$BUILD/t11-va-nostatus.err" || rc=$?
    assert_rc 1 "$rc" "validate_artifact refuses without a matching successful STATUS -- size/marker alone never authorizes review"
    assert_contains "VALIDATE_ARTIFACT_NO_STATUS" "$BUILD/t11-va-nostatus.err" "the missing-STATUS refusal names itself"

    # ---- CODE REVIEW FIX (Minor 11a): "## Non-Goals" must NOT satisfy a
    # required "Goal" heading -- the check is heading-anchored, never a
    # bare substring match anywhere in the file. -----------------------
    rc=0
    printf '# Non-Goals\n\nWe are explicitly not doing X, Y, or Z in this iteration -- those are out of scope on purpose and documented here so nobody re-proposes them later without a fresh discussion.\n\n# File Structure and Responsibilities\n\n| Path | Action |\n|---|---|\n| foo.py | Modify |\n' \
      > "$T11_DIR/plan-nongoal.md"
    _t11_pw_dir3="$FEATURE_FOLDER/4-plan-writing/00/attempts/p04-i00-plan-writer-a03"
    mkdir -p "$_t11_pw_dir3"
    PLAN_PATH="$T11_DIR/plan-nongoal.md"
    printf '{"schema_version":2,"plan_path":"%s","completed_at":"1970-01-01T00:00:00Z"}
'       "$PLAN_PATH" > "$_t11_pw_dir3/artifact-complete.json"
    printf 'verdict: DONE
reason: null
artifact_revision: %s
'       "$(sha256sum "$PLAN_PATH" | awk '{print $1}')" > "$_t11_pw_dir3/STATUS.md"
    validate_artifact plan-writer p04-i00-plan-writer-a03 >/dev/null 2>"$BUILD/t11-va-nongoal.err" || rc=$?
    assert_rc 1 "$rc" "Minor11a regression: '## Non-Goals' does NOT satisfy a required 'Goal' heading"
    assert_contains "VALIDATE_ARTIFACT_MISSING_HEADING:Goal" "$BUILD/t11-va-nongoal.err"       "the heading-anchored rejection specifically names the missing 'Goal' heading"
  fi
else
  _fail "ingest_findings/validate_artifact are not defined"
fi

FEATURE_FOLDER="$T11_FEATURE_FOLDER"
ORCHESTRATION_DIR="$T11_ORCHESTRATION_DIR"

# =============================================================================
# Task 12: executable plans and explicit verification results
# =============================================================================
T12_FEATURE_FOLDER="$FEATURE_FOLDER"
T12_ORCHESTRATION_DIR="$ORCHESTRATION_DIR"

if declare -F validate_plan_tasks >/dev/null; then
  T12_DIR="$BUILD/t12"; rm -rf "$T12_DIR"; mkdir -p "$T12_DIR"

  # ---- Step 1 fixtures: one plan defect at a time, exercised one at a time --
  _t12_expect_fail() {
    # Usage: _t12_expect_fail DEFECT SUBSTRING
    local defect="$1" substr="$2" plan out rc
    plan="$T12_DIR/plan-$defect.md"
    write_plan_task_fixture "$plan" "$defect"
    rc=0
    out="$(validate_plan_tasks "$plan" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | "$GREP_BIN" -qi -- "$substr"; then
      _ok "T12: validate_plan_tasks rejects '$defect' ($substr)"
    else
      _fail "T12: validate_plan_tasks did not reject '$defect' as expected (rc=$rc)"
      note "$out"
    fi
  }

  T12_PLAN_VALID="$T12_DIR/plan-valid.md"
  write_plan_task_fixture "$T12_PLAN_VALID" valid
  if validate_plan_tasks "$T12_PLAN_VALID" >"$T12_DIR/valid.out" 2>&1; then
    _ok "T12: validate_plan_tasks accepts a structurally complete plan"
  else
    _fail "T12: validate_plan_tasks rejected the valid baseline plan"
    note "$(cat "$T12_DIR/valid.out")"
  fi

  _t12_expect_fail duplicate_id                     "duplicate task_id"
  _t12_expect_fail missing_objective                "missing objective"
  _t12_expect_fail missing_files                    "missing files"
  _t12_expect_fail missing_prerequisite_field       "missing prerequisites"
  _t12_expect_fail missing_actor                    "missing actor"
  _t12_expect_fail bad_actor                        "not in"
  _t12_expect_fail unavailable_credential           "not available"
  _t12_expect_fail secret_credential                "secret material"
  _t12_expect_fail undeclared_side_effect           "undeclared side effect"
  _t12_expect_fail ambiguous_verification           "ambiguous"
  _t12_expect_fail missing_environment              "missing environment"
  _t12_expect_fail missing_expected_result          "missing expected_result"
  _t12_expect_fail missing_handoff                  "requires non-empty handoff"
  _t12_expect_fail cyclic_dependency                "cycle detected"
  _t12_expect_fail post_implementation_only_review  "post-implementation-only review"
  _t12_expect_fail unreachable_prerequisite         "unreachable"
  _t12_expect_fail forward_reference                "forward reference"
  _t12_expect_fail self_reference                   "cycle detected"

  # Code review fix (blocker 4): the credential-availability check must
  # apply ONLY to actor=implementer. An owner-actor task naming a credential
  # the orchestrator does not hold is the handoff case this schema exists
  # to express, and must be ACCEPTED, not rejected.
  T12_PLAN_OWNERCRED="$T12_DIR/plan-owner_credential_unavailable_is_ok.md"
  write_plan_task_fixture "$T12_PLAN_OWNERCRED" owner_credential_unavailable_is_ok
  if validate_plan_tasks "$T12_PLAN_OWNERCRED" >"$T12_DIR/ownercred.out" 2>&1; then
    _ok "T12: validate_plan_tasks accepts an owner-actor task naming a credential the orchestrator does not hold"
  else
    _fail "T12: validate_plan_tasks wrongly rejected an owner-actor handoff credential"
    note "$(cat "$T12_DIR/ownercred.out")"
  fi

  # Code review fix (major 5): the destructive-side-effect heuristic must
  # NOT false-positive on ordinary "delete a temp file" / "test a deployment
  # script" plans that name no real destructive scope.
  T12_PLAN_DELTMP="$T12_DIR/plan-delete_temp_file_is_ok.md"
  write_plan_task_fixture "$T12_PLAN_DELTMP" delete_temp_file_is_ok
  if validate_plan_tasks "$T12_PLAN_DELTMP" >"$T12_DIR/deltmp.out" 2>&1; then
    _ok "T12: validate_plan_tasks accepts deleting a temp/scratch file (no destructive scope named)"
  else
    _fail "T12: validate_plan_tasks wrongly flagged deleting a temp file as an undeclared side effect"
    note "$(cat "$T12_DIR/deltmp.out")"
  fi

  T12_PLAN_DEPLOYTEST="$T12_DIR/plan-deploy_test_only_is_ok.md"
  write_plan_task_fixture "$T12_PLAN_DEPLOYTEST" deploy_test_only_is_ok
  if validate_plan_tasks "$T12_PLAN_DEPLOYTEST" >"$T12_DIR/deploytest.out" 2>&1; then
    _ok "T12: validate_plan_tasks accepts testing a deployment script (no production/database scope named)"
  else
    _fail "T12: validate_plan_tasks wrongly flagged a deployment-script test as an undeclared side effect"
    note "$(cat "$T12_DIR/deploytest.out")"
  fi
else
  _fail "validate_plan_tasks is not defined"
fi

# ---- Step 5 fixtures: verification records in every allowed state, plus
# the invalid state SKIPPED, plus an empty result, plus policy-invalid
# EXCLUDED, plus an uncontrolled performance PASS -----------------------------
if declare -F append_verification_record >/dev/null && declare -F validate_verification_records >/dev/null; then
  T12_VR_B="$T12_DIR/verification-records-b.jsonl"
T12_VR="$T12_DIR/verification-records.jsonl"; rm -f "$T12_VR"

  append_verification_record "$T12_VR" v-pass  "pytest tests/test_widget.py" local PASS 0 \
    "$T12_DIR/ev-pass.log" "" "" ""
  append_verification_record "$T12_VR" v-fail  "pytest tests/test_widget.py" local FAIL 1 \
    "$T12_DIR/ev-fail.log" "" "assertion failed on line 12" ""
  append_verification_record "$T12_VR" v-excl  "pytest tests/test_legacy.py" local EXCLUDED 1 \
    "$T12_DIR/ev-excl.log" "failed identically at the implementation baseline" \
    "pre-existing failure, unrelated to this change" ""
  append_verification_record "$T12_VR" v-notrun "manual UAT in staging" staging NOT_RUN "" \
    "" "" "requires actor=owner; staging access not available to implementer" fu-01

  if validate_verification_records "$T12_VR" >"$T12_DIR/vr.out" 2>&1; then
    _ok "T12: validate_verification_records accepts PASS/FAIL/EXCLUDED/NOT_RUN"
  else
    _fail "T12: validate_verification_records rejected legal records"
    note "$(cat "$T12_DIR/vr.out")"
  fi

  rc=0
  append_verification_record "$T12_VR" v-skip "whatever" local SKIPPED "" "" "" "" "" \
    2>"$T12_DIR/skip.err" || rc=$?
  assert_rc 1 "$rc" "T12: append_verification_record refuses the illegal result SKIPPED"
  assert_contains SKIPPED "$T12_DIR/skip.err" "T12: SKIPPED rejection names the offending value"

  # An empty result is never PASS.
  T12_VR_EMPTY="$T12_DIR/verification-records-empty.jsonl"
  printf '{"verification_id":"v-empty","command":"x","environment":"local","result":"","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n' \
    > "$T12_VR_EMPTY"
  if validate_verification_records "$T12_VR_EMPTY" >/dev/null 2>&1; then
    _fail "T12: validate_verification_records accepted an empty result as PASS"
  else
    _ok "T12: validate_verification_records rejects an empty result"
  fi

  # EXCLUDED without policy-valid evidence must be rejected -- it cannot
  # hide a new regression behind a bare, unexplained exclusion.
  T12_VR_BADEXCL="$T12_DIR/verification-records-badexcl.jsonl"
  printf '{"verification_id":"v-bx","command":"x","environment":"local","result":"EXCLUDED","exit_code":1,"evidence_path":null,"baseline_comparison":null,"reason":"meh","followup_id":null}\n' \
    > "$T12_VR_BADEXCL"
  if validate_verification_records "$T12_VR_BADEXCL" >/dev/null 2>&1; then
    _fail "T12: validate_verification_records accepted an EXCLUDED record with no policy-valid evidence"
  else
    _ok "T12: validate_verification_records rejects EXCLUDED without pre-existing/environment-bound/actor-bound/outside-capability evidence"

# Step 5's load-bearing clause is "EXCLUDED cannot hide a new regression". An
# evidence_path alone is a claim -- nothing in it distinguishes pre-existing
# from new. Only a baseline showing the check already failed this way BEFORE
# the change can establish that, so a pre-existing/outside-capability
# exclusion must carry one. Actor- and environment-bound exclusions are exempt:
# no baseline can exist for a check this actor/environment cannot run at all.
: > "$T12_VR_B"
append_verification_record "$T12_VR_B" v-nb "pytest tests/test_legacy.py" local EXCLUDED 1 \
  "$T12_DIR/ev-excl.log" "" "pre-existing failure" "" >/dev/null 2>&1 || true
t12_nb_rc=0; t12_nb_out="$(validate_verification_records "$T12_VR_B" 2>&1)" || t12_nb_rc=$?
assert_rc 1 "$t12_nb_rc" "T12: EXCLUDED as pre-existing without a baseline_comparison is refused"
case "$t12_nb_out" in
  *baseline_comparison*) _ok "T12: the refusal names the missing baseline_comparison" ;;
  *) _fail "T12: the refusal names the missing baseline_comparison"; note "got: $t12_nb_out" ;;
esac

: > "$T12_VR_B"
append_verification_record "$T12_VR_B" v-ab "pytest tests/test_gpu.py" local EXCLUDED 1 \
  "$T12_DIR/ev-excl.log" "" "actor-bound: the owner must run this" "" >/dev/null 2>&1 || true
t12_ab_rc=0; validate_verification_records "$T12_VR_B" >/dev/null 2>&1 || t12_ab_rc=$?
assert_rc 0 "$t12_ab_rc" "T12: an actor-bound EXCLUDED needs no baseline (none can exist)"
  fi

  # Code review fix (medium 9): a reason KEYWORD alone is a claim, not
  # evidence -- a policy-valid reason string with a NULL evidence_path must
  # ALSO be rejected, isolating this check from the keyword check above.
  T12_VR_NOEVID="$T12_DIR/verification-records-noevid.jsonl"
  printf '{"verification_id":"v-ne","command":"pytest tests/new_feature.py","environment":"local","result":"EXCLUDED","exit_code":1,"evidence_path":null,"baseline_comparison":null,"reason":"pre-existing failure, unrelated to this change","followup_id":null}\n' \
    > "$T12_VR_NOEVID"
  if validate_verification_records "$T12_VR_NOEVID" >/dev/null 2>&1; then
    _fail "T12: validate_verification_records accepted an EXCLUDED record with a valid reason keyword but NO evidence_path"
  else
    _ok "T12: validate_verification_records rejects EXCLUDED with no evidence_path even when the reason keyword is policy-valid"
  fi

  # A performance verdict without a declared controlled environment and
  # comparable baseline is advisory/inconclusive, never an authoritative PASS.
  T12_VR_PERF="$T12_DIR/verification-records-perf.jsonl"
  printf '{"verification_id":"v-perf","command":"run the benchmark suite","environment":"workstation","result":"PASS","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n' \
    > "$T12_VR_PERF"
  if validate_verification_records "$T12_VR_PERF" >/dev/null 2>&1; then
    _fail "T12: validate_verification_records accepted an uncontrolled performance PASS"
  else
    _ok "T12: validate_verification_records rejects a performance PASS without a controlled baseline"
  fi

  # Code review fix (low 10): a named benchmark TOOL (not just the bare
  # word "benchmark") without a controlled baseline must also be caught.
  T12_VR_PERF2="$T12_DIR/verification-records-perf2.jsonl"
  printf '{"verification_id":"v-perf2","command":"hyperfine ./bin/app --warmup 3","environment":"workstation","result":"PASS","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n' \
    > "$T12_VR_PERF2"
  if validate_verification_records "$T12_VR_PERF2" >/dev/null 2>&1; then
    _fail "T12: validate_verification_records accepted an uncontrolled 'hyperfine' PASS"
  else
    _ok "T12: validate_verification_records recognizes a named benchmark tool (hyperfine), not just the word 'benchmark'"
  fi

  # And the negative: ordinary prose containing "above"/"table" etc. must
  # NOT be misdetected as a performance command by the widened tool list.
  T12_VR_NOTPERF="$T12_DIR/verification-records-notperf.jsonl"
  printf '{"verification_id":"v-notperf","command":"Run the above migration against the users table","environment":"local","result":"PASS","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n' \
    > "$T12_VR_NOTPERF"
  if validate_verification_records "$T12_VR_NOTPERF" >/dev/null 2>&1; then
    _ok "T12: ordinary prose ('above', 'table') is not misdetected as a performance command"
  else
    _fail "T12: the widened PERF_RE false-positived on ordinary prose"
  fi

  # Code review fix (low 11): Mode B APPENDS a fresh outcome under the SAME
  # verification_id after a debugger re-run -- an old, STRUCTURALLY INVALID
  # pre-debug attempt (e.g. an empty result) sitting alongside a new, valid
  # PASS for the identical check must not permanently reject the file. This
  # is the ONLY scenario that actually discriminates dedup from "validate
  # every line independently": a later invalid line fails either way, so
  # only "earlier invalid, later valid" tells them apart.
  T12_VR_DEDUP="$T12_DIR/verification-records-dedup.jsonl"
  {
    printf '{"verification_id":"v-dup","command":"pytest tests/test_widget.py","environment":"local","result":"","exit_code":1,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n'
    printf '{"verification_id":"v-dup","command":"pytest tests/test_widget.py","environment":"local","result":"PASS","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n'
  } > "$T12_VR_DEDUP"
  if validate_verification_records "$T12_VR_DEDUP" >"$T12_DIR/dedup.out" 2>&1; then
    _ok "T12: validate_verification_records evaluates the LATEST record per verification_id (post-debug PASS supersedes a structurally-invalid pre-debug attempt)"
  else
    _fail "T12: validate_verification_records wrongly failed on a superseded pre-debug record sharing an ID with a later valid PASS"
    note "$(cat "$T12_DIR/dedup.out")"
  fi

  # Same rescue pattern through a DIFFERENT rule (EXCLUDED-without-evidence,
  # not just an empty result) -- proves dedup applies uniformly, not only
  # to the one rule the first fixture happened to exercise.
  T12_VR_DEDUP2="$T12_DIR/verification-records-dedup2.jsonl"
  {
    printf '{"verification_id":"v-dup2","command":"pytest tests/test_widget.py","environment":"local","result":"EXCLUDED","exit_code":1,"evidence_path":null,"baseline_comparison":null,"reason":"meh","followup_id":null}\n'
    printf '{"verification_id":"v-dup2","command":"pytest tests/test_widget.py","environment":"local","result":"PASS","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n'
  } > "$T12_VR_DEDUP2"
  if validate_verification_records "$T12_VR_DEDUP2" >"$T12_DIR/dedup2.out" 2>&1; then
    _ok "T12: validate_verification_records supersedes a pre-debug policy-invalid EXCLUDED with a later valid PASS (dedup applies uniformly, not to one rule only)"
  else
    _fail "T12: validate_verification_records wrongly failed on a superseded policy-invalid EXCLUDED sharing an ID with a later valid PASS"
    note "$(cat "$T12_DIR/dedup2.out")"
  fi

  # And the genuinely reverse direction: a LATER invalid record must still
  # be caught even though an EARLIER line for the same ID was valid --
  # proving this is "last wins," not "any valid record anywhere wins."
  T12_VR_DEDUP3="$T12_DIR/verification-records-dedup3.jsonl"
  {
    printf '{"verification_id":"v-dup3","command":"pytest tests/test_widget.py","environment":"local","result":"PASS","exit_code":0,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n'
    printf '{"verification_id":"v-dup3","command":"pytest tests/test_widget.py","environment":"local","result":"","exit_code":1,"evidence_path":null,"baseline_comparison":null,"reason":null,"followup_id":null}\n'
  } > "$T12_VR_DEDUP3"
  if validate_verification_records "$T12_VR_DEDUP3" >/dev/null 2>&1; then
    _fail "T12: validate_verification_records ignored a later (empty-result) record in favor of an earlier PASS"
  else
    _ok "T12: validate_verification_records genuinely uses LAST-wins, not first-valid-wins"
  fi
else
  _fail "append_verification_record / validate_verification_records are not defined"
fi

# ---- Step 6: plan acceptance gate + review-window closure ------------------
if declare -F plan_review_window_closed >/dev/null && declare -F plan_ready_for_implementation >/dev/null; then
  T12_PR="$BUILD/t12-planready"; rm -rf "$T12_PR"; mkdir -p "$T12_PR/5-plan-review/01"
  FEATURE_FOLDER="$T12_PR"
  : > "$T12_PR/RUN_LOG.md"

  if plan_review_window_closed; then
    _fail "T12: plan_review_window_closed is true before Phase 6 ever started"
  else
    _ok "T12: plan_review_window_closed is false before Phase 6 starts"
  fi

  rc=0
  plan_ready_for_implementation >/dev/null 2>&1 || rc=$?
  assert_rc 1 "$rc" "T12: plan_ready_for_implementation refuses with no plan-review summarizer status"

  printf 'verdict: DONE\nreason: null\n' > "$T12_PR/5-plan-review/summarizer-status.md"
  printf '{"finding_id":"f1","severity":"blocker","status":"open"}\n' > "$T12_PR/5-plan-review/01/findings-catalog.jsonl"
  rc=0
  plan_ready_for_implementation >/dev/null 2>&1 || rc=$?
  assert_rc 1 "$rc" "T12: plan_ready_for_implementation refuses with an open blocking finding"

  printf '{"finding_id":"f1","severity":"blocker","status":"fixed"}\n' > "$T12_PR/5-plan-review/01/findings-catalog.jsonl"
  if plan_ready_for_implementation >"$T12_DIR/pr-ok.out" 2>&1; then
    _ok "T12: plan_ready_for_implementation passes on an accepted verdict with zero open blockers"
  else
    _fail "T12: plan_ready_for_implementation still refuses after the blocker was fixed"
    note "$(cat "$T12_DIR/pr-ok.out")"
  fi

  # Code review fix (blocker 2): "open" alone undercounts -- a REOPENED
  # blocker (a fixer's 'fixed' disposition re-reported by a later reviewer,
  # the single most dangerous class) must refuse readiness exactly like
  # 'open' does.
  printf '{"finding_id":"f1","severity":"blocker","status":"reopened"}\n' > "$T12_PR/5-plan-review/01/findings-catalog.jsonl"
  rc=0
  plan_ready_for_implementation >/dev/null 2>&1 || rc=$?
  assert_rc 1 "$rc" "T12: plan_ready_for_implementation refuses on a REOPENED blocker, not just 'open'"

  # Code review fix (blocker 2): a malformed/corrupt catalog must fail
  # CLOSED (refuse), never silently count as zero open blockers.
  printf 'not json at all\n' > "$T12_PR/5-plan-review/01/findings-catalog.jsonl"
  rc=0
  plan_ready_for_implementation >/dev/null 2>&1 || rc=$?
  assert_rc 1 "$rc" "T12: plan_ready_for_implementation fails CLOSED on a malformed findings catalog (never treats a jq error as zero blockers)"

  # Restore a clean catalog so the ONE test below this (readiness/window
  # closure) is unaffected by the malformed-catalog fixture just written.
  printf '{"finding_id":"f1","severity":"blocker","status":"fixed"}\n' > "$T12_PR/5-plan-review/01/findings-catalog.jsonl"

  printf -- '--- 2026-01-01T00:00:00Z  event=IMPLEMENTATION_BASELINE\nbase_sha: deadbeef\nuncommitted_changes: no\n\n' \
    >> "$T12_PR/RUN_LOG.md"
  if plan_review_window_closed; then
    _ok "T12: plan_review_window_closed is true once Phase 6's baseline event is durable"
  else
    _fail "T12: plan_review_window_closed did not observe the IMPLEMENTATION_BASELINE event"
  fi
else
  _fail "plan_review_window_closed / plan_ready_for_implementation are not defined"
fi

FEATURE_FOLDER="$T12_FEATURE_FOLDER"
ORCHESTRATION_DIR="$T12_ORCHESTRATION_DIR"

finish
