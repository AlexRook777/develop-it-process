#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/assert.sh"

assert_contains '| process_schema_version | 2 |' "$PROCESS_DOC" "schema v2 policy"
assert_contains '| prelaunch_correction_cap | 1 |' "$PROCESS_DOC" "prelaunch cap"
assert_contains '| publication_retry_cap | 1 |' "$PROCESS_DOC" "publication cap"
assert_contains '| transient_retry_cap | 1 |' "$PROCESS_DOC" "transient cap"
assert_contains '| continuation_cap | 3 |' "$PROCESS_DOC" "continuation cap"
assert_contains '| review_iteration_cap | 10 |' "$PROCESS_DOC" "review cap"
assert_contains '| document_fixer_batch_size | 8 |' "$PROCESS_DOC" "batch cap"
assert_contains '| documentation_fix_cap | 2 |' "$PROCESS_DOC" "documentation cap"
assert_contains '| artifact_growth_warning_pct | 10 |' "$PROCESS_DOC" "growth threshold"
assert_contains '| divergent_round_cap | 2 |' "$PROCESS_DOC" "divergence cap"
assert_contains '| long_role_headroom_threshold_minutes | 60 |' "$PROCESS_DOC" "long-role threshold"

# extract.py writes $BUILD/policies.tsv itself; redirecting stdout onto the same
# path would splice two independent writes at offset 0.
python3 "$REPO_TOP/tests/lib/extract.py" policies > /dev/null
assert_line_count 12 "$BUILD/policies.tsv" "policy header plus 11 rows"

# shellcheck source=lib/v2_fixtures.sh
source "$REPO_TOP/tests/lib/v2_fixtures.sh"
load_cookbook || finish
init_v2_fixture

for p in "$ORCHESTRATION_DIR" "$RUNTIME_DIR" "$SDD_DIR" "$RUN_LOG" "$LEASE_FILE" "$TRANSCRIPTS_DIR"; do
  case "$p" in
    "$FEATURE_FOLDER"|"$FEATURE_FOLDER"/*) _ok "fixture path under \$FEATURE_FOLDER: $p" ;;
    *) _fail "fixture path escapes \$FEATURE_FOLDER: $p" ;;
  esac
done
case "$REPO_ROOT" in
  "$FEATURE_FOLDER"|"$FEATURE_FOLDER"/*) _fail "\$REPO_ROOT must not be under \$FEATURE_FOLDER: $REPO_ROOT" ;;
  *) _ok "\$REPO_ROOT stays outside \$FEATURE_FOLDER" ;;
esac

# policy_value reads the generated registry, not the Markdown table. Task 3's
# bootstrap_runtime materializes it for real; here we stage it by hand so the
# helper is covered by behaviour rather than by grep.
mkdir -p "$RUNTIME_DIR"
cp "$BUILD/policies.tsv" "$RUNTIME_DIR/policy.tsv"
assert_eq 10 "$(policy_value review_iteration_cap)" "policy_value prints only the value"

rc=0; out=$(policy_value no_such_policy 2>"$BUILD/policy.err") || rc=$?
assert_rc 1 "$rc" "unknown policy fails"
assert_eq "" "$out" "unknown policy prints nothing on stdout"
assert_contains 'POLICY_UNKNOWN:no_such_policy' "$BUILD/policy.err" "unknown policy names itself"

printf 'review_iteration_cap\t99\tdup\n' >> "$RUNTIME_DIR/policy.tsv"
rc=0; policy_value review_iteration_cap 2>"$BUILD/policy.err" >/dev/null || rc=$?
assert_rc 1 "$rc" "duplicate policy fails"
assert_contains 'POLICY_DUPLICATE:review_iteration_cap' "$BUILD/policy.err" "duplicate policy names itself"

rm -f "$RUNTIME_DIR/policy.tsv"
rc=0; policy_value review_iteration_cap 2>"$BUILD/policy.err" >/dev/null || rc=$?
assert_rc 1 "$rc" "missing registry fails without killing the shell"
assert_contains 'POLICY_REGISTRY_MISSING' "$BUILD/policy.err" "missing registry is typed"

# Spec 6.3: reconstruction must run at the start of EVERY phase shell. The
# helper being correct is worthless if the normative per-phase bootstrap never
# names it -- that regression already happened once.
assert_present '^init_orchestration_vars [0-9-]+ \|\| exit 1$' "$PROCESS_DOC" \
  "the per-phase bootstrap snippet calls init_orchestration_vars <phase>"
# assert_absent pipes into head; under `set -euo pipefail` a no-match grep would
# abort this script instead of passing. Count instead.
stale=$(grep -c '^CONTEXT7_POLICY=' "$PROCESS_DOC" || true)
assert_eq 0 "$stale" "no phase block reconstructs only the context7 policy"

# --- Task 3 Step 1: bootstrap_runtime extracts atomically -------------------
# The substantive red signal (not a "command not found" artifact): the helper
# itself must be a defined function before any behavioural assertion below
# means anything.
if declare -F bootstrap_runtime >/dev/null; then
  _ok "bootstrap_runtime is defined"
else
  _fail "bootstrap_runtime is not defined"
fi

rm -rf "$ORCHESTRATION_DIR"
mkdir -p "$ORCHESTRATION_DIR"

rc=0
BOOTSTRAP_FAIL_AFTER=2 bootstrap_runtime >"$BUILD/bootstrap1.out" 2>"$BUILD/bootstrap1.err" || rc=$?
assert_rc 1 "$rc" "bootstrap_runtime aborts when BOOTSTRAP_FAIL_AFTER=2 fires"
assert_contains 'BOOTSTRAP_INTERRUPTED' "$BUILD/bootstrap1.err" "interruption names itself"
assert_not_exists "$RUNTIME_DIR" "interrupted bootstrap leaves no final runtime/"
assert_glob_count 1 "$ORCHESTRATION_DIR/.runtime.tmp.*" "one interrupted staging directory"
assert_glob_count 0 "$ORCHESTRATION_DIR/.runtime.tmp.*/manifest.sha256" "manifest is written last"

# A second, clean bootstrap must quarantine that orphan and still succeed --
# never complete or source the orphan's unknown partial contents. The orphan
# sweep is age-gated (a FRESH staging dir may belong to a concurrent live
# bootstrap -- see check_06's dedicated concurrency-safety case), so force
# the freshness window to zero here: this orphan really is stale (the prior
# call already returned before this one starts), we just don't want to sleep
# 300s in a test to prove it.
rc=0
BOOTSTRAP_ORPHAN_AGE_SECONDS=0 bootstrap_runtime >"$BUILD/bootstrap2.out" 2>"$BUILD/bootstrap2.err" || rc=$?
assert_rc 0 "$rc" "a clean rerun succeeds despite the orphaned staging directory"
assert_glob_count 0 "$ORCHESTRATION_DIR/.runtime.tmp.*" "the orphan no longer sits beside runtime/"
assert_glob_count 1 "$ORCHESTRATION_DIR/quarantine/.runtime.tmp.*" \
  "the orphan was quarantined, not deleted or merged"
assert_exists "$RUNTIME_DIR/manifest.sha256" "the rerun produced a final manifest"

doc_sha="$(sha256sum "$PROCESS_DOC" | cut -d' ' -f1)"
assert_contains "process_document_sha256=$doc_sha" "$RUNTIME_DIR/manifest.sha256" \
  "manifest records the current process-document SHA-256"

rc=0
( cd "$RUNTIME_DIR" && sha256sum -c manifest.sha256 ) >/dev/null 2>"$BUILD/manifest-check.err" || rc=$?
assert_rc 0 "$rc" "the four generated-file entries validate with sha256sum -c"

# --- Task 4 Step 6: every top-level appendix publishes through the ONE
# generated publisher, exactly once, and no appendix hand-rolls its own
# atomic-write shell or a role-local STATUS validator any more. -------------
appendix_pub_report="$(python3 - "$PROCESS_DOC" <<'PY'
import re
text = open(__import__("sys").argv[1]).read()
bodies = re.findall(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", text, re.S)
bad = []
for role, body in bodies:
    n = body.count("$STATUS_PUBLISHER_PATH")
    if n != 1:
        bad.append(f"{role}:{n}")
print(",".join(bad))
print(len(bodies))
PY
)"
appendix_pub_bad="$(printf '%s\n' "$appendix_pub_report" | sed -n 1p)"
appendix_pub_count="$(printf '%s\n' "$appendix_pub_report" | sed -n 2p)"
assert_eq "" "$appendix_pub_bad" \
  "every appendix calls \$STATUS_PUBLISHER_PATH exactly once (offenders: role:count)"
assert_eq 24 "$appendix_pub_count" "24 top-level role appendices were scanned"

# The retired v1 phrasing ("write STATUS ... atomically (write .tmp then
# rename)") must be gone from every appendix -- a hand-rolled atomic-write
# shell is exactly what Step 6 replaces with the one-command publisher.
retired_phrase=$(grep -c 'write `\.tmp` then rename' "$PROCESS_DOC" || true)
assert_eq 0 "$retired_phrase" "no appendix still instructs its own .tmp-then-rename STATUS write"

# No appendix may hand-write its own STATUS file directly (a role-local
# writer/validator). Two shapes are retired, both checked:
#   (a) a REAL shell command (line starts with cat/mv, not prose ABOUT
#       cat/mv inside backticks) targeting a STATUS path;
#   (b) a PROSE directive naming a write verb (write/rewrite/overwrite,
#       singular or plural) alongside a *-status.md / STATUS.md filename on
#       the same line -- e.g. "ATOMICALLY rewrite `implementer-status.md`",
#       which a plain `cat >`/`mv` grep does not catch at all. Matching is
#       restricted to `.md` filenames (never the bare word STATUS/status, a
#       common field/section name) so this cannot fire on the publisher's own
#       "do not hand-write your own validator" sentence or on read-only prose
#       like "the STATUS file" / "publish STATUS".
direct_status_write=$(grep -cE '^[[:space:]]*(cat[[:space:]]*>|mv[[:space:]])[^`]*STATUS' "$PROCESS_DOC" || true)
prose_status_write=$(python3 "$REPO_TOP/tests/lib/scan_status_write_prose.py" "$PROCESS_DOC")
assert_eq 0 "$direct_status_write" "no appendix writes or renames a STATUS file directly (cat >/mv)"
assert_eq 0 "$prose_status_write" "no appendix prose instructs writing/rewriting a *-status.md file directly"

# impl-worker is the one documented exception (status_template=none, child-only
# contract) -- it must have no top-level appendix at all.
implworker_appendix=$(grep -c -- '<!-- BEGIN: impl-worker -->' "$PROCESS_DOC" || true)
assert_eq 0 "$implworker_appendix" "impl-worker has no appendix (status_template=none, child-only)"

# Every dispatched role's STATUS path template names an attempt ID.
# NOTE: bash `read` collapses consecutive tab delimiters (tab is IFS
# "whitespace" to bash regardless of what IFS is set to), which would
# silently misalign columns for a row with an empty cell (e.g. `effort`) --
# use awk -F '\t', the same tool tsv_column/tsv_value already rely on, which
# does not collapse.
python3 "$REPO_TOP/tests/lib/extract.py" roles > "$BUILD/roles-t4.tsv"
status_paths_missing_attempt="$(awk -F '\t' '
  NR==1 { for (i=1;i<=NF;i++) col[$i]=i; next }
  {
    st = $col["status_template"]
    if (st == "none") next
    if (index(st, "$DISPATCH_ID") == 0) print $col["role"]
  }
' "$BUILD/roles-t4.tsv" | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "" "$status_paths_missing_attempt" \
  "every dispatched role's STATUS path names \$DISPATCH_ID (an attempt ID)"

# Every appendix's declared output_count/output_NN lines must agree with its
# own registry row's `outputs` cell -- Task 4 code review fix #3: all 24
# appendices previously hardcoded output_count: 0, so the publisher's
# contiguity/absolute-path/realpath-containment validation (the core safety
# property Step 4 built) was never exercised by a single real role.
output_decl_problems="$(python3 "$REPO_TOP/tests/lib/check_output_declarations.py" "$PROCESS_DOC" "$BUILD/roles-t4.tsv" || true)"
assert_eq "" "$output_decl_problems" \
  "every appendix's output_count/output_NN agrees with its registry outputs cell"

# Code review fix #1: Step 6 must not silently drop an appendix's non-STATUS
# role contract (verdict rules, findings-file format, progress.jsonl
# durability notes, etc.) while converting its STATUS write to one-command
# publication -- an earlier pass replaced whole `## Output` sections and lost
# ~54 lines of contract this way.
appendix_content_missing="$(python3 "$REPO_TOP/tests/lib/check_appendix_content.py" "$PROCESS_DOC" || true)"
assert_eq "" "$appendix_content_missing" \
  "every restored appendix still carries its non-STATUS role contract (verdict rules / findings format / progress.jsonl notes)"

# --- Task 6: dispatch_attempt/dispatch_parallel end to end, inside the real
# schema-v2 fixture layout (ORCHESTRATION_DIR/RUNTIME_DIR/RUN_LOG as
# init_v2_fixture provisions them, not check_07's own hand-rolled paths).
# check_07_fakecli.sh already exhaustively covers classification and fan-out
# edge cases against a synthetic registry; this only proves the same engine
# also works end to end against the REAL runtime bootstrap_runtime just
# produced above (role-contracts.tsv/policy.tsv extracted from THIS process
# document, not a hand-built fixture copy). `set -euo pipefail` is active in
# this file, so every call that may legitimately return non-zero is guarded.
# unset FAKE_ARGV_LOG/FAKE_MODE/FAKE_DELAY*: when this whole suite runs NESTED
# inside develop-it.sh's own launcher pre-check gate (check_08_launcher.sh),
# those vars may already be exported from the OUTER (unrelated) launcher
# test -- inheriting FAKE_ARGV_LOG here would leak this file's own fakebin
# invocations into that outer test's argv log and produce a false failure.
unset FAKE_ARGV_LOG FAKE_MODE FAKE_DELAY FAKE_DELAY_SECONDS FAKE_RC FAKE_EXIT_CODE
export PATH="$REPO_TOP/tests/fakebin:$PATH"
FEATURE_FOLDER_OUTSIDE_REPO=""
RESOLVED_MODELS="$(resolved_models_block)"
CONTEXT7_POLICY="disabled"
ROLE_CONTRACTS_PATH="$RUNTIME_DIR/role-contracts.tsv"
STATUS_PUBLISHER_PATH="$RUNTIME_DIR/publish-status"

: > "$RUN_LOG"
rc=0
FAKE_MODE=complete dispatch_attempt 3 01 summarizer-spec || rc=$?
assert_rc 0 "$rc" "dispatch_attempt succeeds end to end inside the v2 fixture layout"
assert_present 'event=DISPATCH_STARTED' "$RUN_LOG" \
  "the v2 fixture's own \$RUN_LOG (not a hand-built path) gained a DISPATCH_STARTED block"
assert_present 'event=DISPATCH_COMPLETED' "$RUN_LOG" \
  "the v2 fixture's own \$RUN_LOG gained a DISPATCH_COMPLETED block"
completed_id="$("$GREP_BIN" -oE 'p03-i01-summarizer-spec-a[0-9]{2}' "$RUN_LOG" | head -1)"
[ -n "$completed_id" ] || _fail "could not recover the completed attempt's dispatch_id"
rc=0
dispatch_is_running "$completed_id" || rc=$?
assert_rc 1 "$rc" "turn-start reconciliation: a completed attempt is no longer 'running' in the real fixture"

# A prelaunch failure (unknown role) still leaves the real $RUN_LOG in a
# recoverable state: exactly one DISPATCH_NOT_LAUNCHED, nothing else added.
before_lines=$(wc -l < "$RUN_LOG")
rc=0
dispatch_attempt 3 02 no-such-role 2>/dev/null || rc=$?
assert_rc 1 "$rc" "dispatch_attempt fails closed for an unknown role"
assert_eq PRELAUNCH_FAILED "${DISPATCH_RESULT_CLASSIFICATION:-}" \
  "an unknown role is a typed PRELAUNCH_FAILED, not a shell crash under set -euo pipefail"
after_lines=$(wc -l < "$RUN_LOG")
[ "$after_lines" -gt "$before_lines" ] \
  && _ok "the prelaunch failure still appended durable evidence to \$RUN_LOG" \
  || _fail "the prelaunch failure left no durable RUN_LOG evidence"

# --- Task 8 Step 7: every RUN_LOG.md block written above (ATTEMPT_ALLOCATED,
# DISPATCH_STARTED, DISPATCH_COMPLETED, DISPATCH_NOT_LAUNCHED) carries the
# full common envelope, and event_id is strictly increasing across the whole
# file -- checked end to end against the REAL runtime this file already
# bootstrapped above, not a hand-built fixture. ---
rc=0
python3 - "$RUN_LOG" <<'PY' || rc=$?
import sys
text = open(sys.argv[1]).read()
blocks = [b for b in text.split("\n\n") if b.strip()]
required = ("event_id", "process_schema_version", "phase", "iteration",
            "dispatch_id", "caused_by_event_id", "authority", "reason")
ids = []
bad = []
for b in blocks:
    header = b.splitlines()[0]
    fields = {}
    for line in b.splitlines()[1:]:
        if ":" not in line:
            bad.append(f"non key:value line in block {header!r}: {line!r}")
            continue
        k, v = line.split(":", 1)
        fields[k.strip()] = v.strip()
    for req in required:
        if req not in fields:
            bad.append(f"block {header!r} missing common field {req!r}")
    if not fields.get("reason"):
        bad.append(f"block {header!r} has an empty reason")
    if "event_id" in fields:
        try:
            ids.append(int(fields["event_id"]))
        except ValueError:
            bad.append(f"block {header!r} has a non-integer event_id: {fields['event_id']!r}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
if len(ids) != len(set(ids)) or ids != sorted(ids):
    print(f"event_id sequence is not strictly increasing/unique: {ids}")
    sys.exit(1)
PY
assert_rc 0 "$rc" "every RUN_LOG.md block carries the full common envelope, and event_id is strictly monotonic"

# --- Task 8 Step 7: non-owner mutation/release stops safely, no rollback. --
# acquire_write_lease/release_write_lease live in the SAME runtime just
# bootstrapped above -- exercised directly here (rather than through a full
# mutating dispatch, which this file's minimal fixture does not set up
# render_keys() for) because the property under test is the lease API's own
# ownership check, not the dispatch lifecycle around it.
rc=0
acquire_write_lease debugger role p06-i50-debugger-a01 6 "." || rc=$?
assert_rc 0 "$rc" "acquire_write_lease succeeds for a fresh lease against the real runtime"
_pre_release_lease_sha="$(sha256sum "$LEASE_FILE" | cut -d' ' -f1)"
rc=0
release_write_lease not-the-owner 2>/dev/null || rc=$?
assert_rc 1 "$rc" "a non-owner release attempt is refused, never silently accepted"
assert_eq "$_pre_release_lease_sha" "$(sha256sum "$LEASE_FILE" | cut -d' ' -f1)" \
  "the lease file is byte-identical after a refused non-owner release -- no rollback, no partial write"
rc=0
release_write_lease debugger || rc=$?
assert_rc 0 "$rc" "the real owner's release succeeds once the non-owner attempt is safely refused"
assert_not_exists "$LEASE_FILE" "the real owner's release actually removed the lease"

# ============================================================================
# Task 9 Step 1/2: resumable role checkpoints (spec §10). Every case below
# was RED before checkpoint_append/checkpoint_resume_state/checkpoint_
# partial_isolated existed (undefined-function failures); this is the GREEN
# behavioral proof.
# ============================================================================

T9_ATTEMPT_DIR="$FEATURE_FOLDER/6-implementation/00/attempts/p06-i00-implementer-a01"
mkdir -p "$T9_ATTEMPT_DIR"
T9_PROGRESS="$T9_ATTEMPT_DIR/progress.jsonl"
T9_DISPATCH_ID="p06-i00-implementer-a01"

T9_ARTIFACT="$FEATURE_FOLDER/6-implementation/task-01-report.md"
mkdir -p "$(dirname "$T9_ARTIFACT")"
printf 'report v1\n' > "$T9_ARTIFACT"
T9_SHA="$(sha256sum "$T9_ARTIFACT" | cut -d' ' -f1)"
( cd "$REPO_ROOT" && printf 'x\n' > t9-committed.txt && git add t9-committed.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "t9 commit" ) >/dev/null
T9_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# --- fixture: valid -- two sequential records, one trailing partial unit ---
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "$T9_ARTIFACT" "$T9_SHA" "$T9_COMMIT" task-02
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 2 partial task-02 "" "" "" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq VALID "$CHECKPOINT_STATE" \
  "T9 valid: two sequential records with real artifact/commit evidence and one trailing partial unit is VALID"
assert_eq 2 "$CHECKPOINT_LAST_SEQUENCE" "T9 valid: last sequence is 2"
assert_eq task-02 "$CHECKPOINT_DIRTY_UNIT" "T9 valid: the trailing partial record is the one dirty unit"
case "$CHECKPOINT_COMPLETED_UNITS" in
  *task-01*) _ok "T9 valid: completed units include task-01" ;;
  *) _fail "T9 valid: completed units missing task-01: [$CHECKPOINT_COMPLETED_UNITS]" ;;
esac

# --- fixture: truncated final record -- the valid prefix survives as
# evidence, but the file as a whole cannot authorize continuation. ----------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "$T9_ARTIFACT" "$T9_SHA" "$T9_COMMIT" task-02
printf '{"schema_version":2,"dispatch_id":"%s","sequence":2,"state":"pa' "$T9_DISPATCH_ID" >> "$T9_PROGRESS"
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 truncated: a truncated final record blocks the whole file, not just itself"
assert_eq 1 "$CHECKPOINT_LAST_SEQUENCE" \
  "T9 truncated: the valid prefix (sequence 1) is preserved as partial-state evidence"
case "$CHECKPOINT_BAD_REASON" in
  MALFORMED_RECORD_AT_LINE_2*) _ok "T9 truncated: bad reason names the malformed line" ;;
  *) _fail "T9 truncated: bad reason does not name the malformed line: [$CHECKPOINT_BAD_REASON]" ;;
esac

# --- fixture: duplicate sequence --------------------------------------------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "$T9_ARTIFACT" "$T9_SHA" "$T9_COMMIT" task-02
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-02 "" "" "" task-03
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 duplicate sequence: a repeated sequence number needs reconciliation"
assert_eq 1 "$CHECKPOINT_LAST_SEQUENCE" \
  "T9 duplicate sequence: the valid prefix stops at the first good record"
case "$CHECKPOINT_BAD_REASON" in
  SEQUENCE_NOT_INCREASING*) _ok "T9 duplicate sequence: bad reason names the non-increasing sequence" ;;
  *) _fail "T9 duplicate sequence: bad reason wrong: [$CHECKPOINT_BAD_REASON]" ;;
esac

# --- fixture: wrong dispatch id ----------------------------------------------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "$T9_ARTIFACT" "$T9_SHA" "$T9_COMMIT" task-02
write_fake_checkpoint "$T9_PROGRESS" "p06-i00-implementer-a99" 2 partial task-02 "" "" "" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 wrong dispatch id: a record naming a different attempt needs reconciliation"
case "$CHECKPOINT_BAD_REASON" in
  WRONG_DISPATCH_ID*) _ok "T9 wrong dispatch id: bad reason names the mismatch" ;;
  *) _fail "T9 wrong dispatch id: bad reason wrong: [$CHECKPOINT_BAD_REASON]" ;;
esac

# --- fixture: path outside $FEATURE_FOLDER -----------------------------------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "/etc/passwd" "" "" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 outside feature folder: an artifact_path escaping \$FEATURE_FOLDER needs reconciliation"
case "$CHECKPOINT_BAD_REASON" in
  ARTIFACT_PATH_OUTSIDE_FEATURE_FOLDER*) _ok "T9 outside feature folder: bad reason names the escape" ;;
  *) _fail "T9 outside feature folder: bad reason wrong: [$CHECKPOINT_BAD_REASON]" ;;
esac

# --- fixture: stale artifact revision ----------------------------------------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "$T9_ARTIFACT" "0000000000000000000000000000000000000000000000000000000000000000" "" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 stale artifact: a wrong sha256 against the real file needs reconciliation"
case "$CHECKPOINT_BAD_REASON" in
  STALE_ARTIFACT_REVISION*) _ok "T9 stale artifact: bad reason names the stale revision" ;;
  *) _fail "T9 stale artifact: bad reason wrong: [$CHECKPOINT_BAD_REASON]" ;;
esac

# --- fixture: checkpoint claiming a repository change absent from its Git
# snapshot (a commit_sha that does not exist in the repo at all). -----------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "" "" "0000000000000000000000000000000000000000" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 absent commit: a commit_sha absent from the repo's own history needs reconciliation"
case "$CHECKPOINT_BAD_REASON" in
  COMMIT_NOT_IN_REPO*) _ok "T9 absent commit: bad reason names the missing commit" ;;
  *) _fail "T9 absent commit: bad reason wrong: [$CHECKPOINT_BAD_REASON]" ;;
esac

# --- checkpoint_append: strictly-increasing sequence, append-only, never
# rewrites an earlier record. ------------------------------------------------
rm -f "$T9_PROGRESS"
rc=0
checkpoint_append "$T9_PROGRESS" "$T9_DISPATCH_ID" implementer \
  sequence=1 unit_type=task unit_id=task-01 state=completed \
  artifact_path="$T9_ARTIFACT" artifact_sha256="$T9_SHA" commit_sha="$T9_COMMIT" \
  verification=PASS next_unit=task-02 || rc=$?
assert_rc 0 "$rc" "checkpoint_append succeeds for a well-formed first record"
assert_eq 1 "$(wc -l < "$T9_PROGRESS" | tr -d ' ')" "checkpoint_append wrote exactly one line"
_t9_first_line="$(head -1 "$T9_PROGRESS")"
rc=0
checkpoint_append "$T9_PROGRESS" "$T9_DISPATCH_ID" implementer \
  sequence=1 unit_type=task unit_id=task-02 state=completed \
  artifact_path="" artifact_sha256="" commit_sha="" verification=PASS next_unit=task-03 \
  2>"$BUILD/t9-append.err" || rc=$?
assert_rc 1 "$rc" "checkpoint_append refuses a non-increasing sequence"
assert_contains "CHECKPOINT_SEQUENCE_NOT_INCREASING" "$BUILD/t9-append.err" "the refusal names itself"
assert_eq 1 "$(wc -l < "$T9_PROGRESS" | tr -d ' ')" "the refused append never touched the file (still one line)"
rc=0
checkpoint_append "$T9_PROGRESS" "$T9_DISPATCH_ID" implementer \
  sequence=2 unit_type=task unit_id=task-02 state=partial \
  artifact_path="" artifact_sha256="" commit_sha="" verification=PASS next_unit=task-02 || rc=$?
assert_rc 0 "$rc" "checkpoint_append succeeds for the next strictly-increasing sequence"
assert_eq 2 "$(wc -l < "$T9_PROGRESS" | tr -d ' ')" "checkpoint_append appended a second line"
assert_eq "$_t9_first_line" "$(head -1 "$T9_PROGRESS")" \
  "checkpoint_append never rewrites an earlier record -- the first line is byte-identical"

# --- Blocker 3 (round 2) fix: a CONTINUATION's own lease acquisition must
# NOT whitelist the DYING attempt's own uncheckpointed mutation as
# "foreign" (round 1 fix), but must NOT discard genuinely pre-existing
# foreign dirt either (round 1's own over-correction, which capped every
# continuation at 1 on a non-pristine tree) -- carrying attempt 1's own
# durable declaration FORWARD satisfies both, across multiple
# continuations (2 AND 3), not just the first one. ------------------------
: > "$RUN_LOG"
rm -f "$LEASE_FILE"
T9_PRERUN_FOREIGN="$FEATURE_FOLDER/6-implementation/human-edited-before-run.txt"
printf 'unrelated human dirt, present before this run started
' > "$T9_PRERUN_FOREIGN"

allocate_attempt 6 05 implementer >/dev/null   # a01 -- sees the real pre-run dirt
T9_A01_DISPATCH="$DISPATCH_ID"
acquire_write_lease implementer role "$T9_A01_DISPATCH" 6 "." >/dev/null
T9_A01_FOREIGN="$(jq -c '.declared_foreign_paths' "$LEASE_FILE")"
case "$T9_A01_FOREIGN" in
  *human-edited-before-run.txt*) _ok "T9 carry-forward setup: a01 legitimately declared the real pre-run dirt" ;;
  *) _fail "T9 carry-forward setup: a01 never declared the pre-run dirt: [$T9_A01_FOREIGN]" ;;
esac
T9_UNCHECKPOINTED_1="$FEATURE_FOLDER/6-implementation/a01-uncheckpointed.py"
printf 'a01 mutated this, never checkpointed it
' > "$T9_UNCHECKPOINTED_1"
release_write_lease implementer >/dev/null
# a01 "dies": no checkpoint record at all names $T9_UNCHECKPOINTED_1.

allocate_attempt 6 05 implementer >/dev/null   # a02 -- continuation 1
T9_A02_DISPATCH="$DISPATCH_ID"
acquire_write_lease implementer role "$T9_A02_DISPATCH" 6 "." >/dev/null
T9_A02_FOREIGN="$(jq -c '.declared_foreign_paths' "$LEASE_FILE")"
assert_eq "$T9_A01_FOREIGN" "$T9_A02_FOREIGN" \
  "T9 carry-forward: continuation 2 (a02) carries a01's OWN declaration forward byte-for-byte"
case "$T9_A02_FOREIGN" in
  *a01-uncheckpointed*) _fail "T9 carry-forward: a01's own uncheckpointed mutation leaked into a02's declaration: [$T9_A02_FOREIGN]" ;;
  *) _ok "T9 carry-forward: a01's own uncheckpointed mutation is NOT laundered into a02's declaration" ;;
esac
T9_UNCHECKPOINTED_2="$FEATURE_FOLDER/6-implementation/a02-uncheckpointed.py"
printf 'a02 mutated this too, never checkpointed it
' > "$T9_UNCHECKPOINTED_2"
release_write_lease implementer >/dev/null
# a02 "dies" too: no checkpoint record names $T9_UNCHECKPOINTED_2 either.

allocate_attempt 6 05 implementer >/dev/null   # a03 -- continuation 2 (continuation_cap=3 permits this)
T9_A03_DISPATCH="$DISPATCH_ID"
acquire_write_lease implementer role "$T9_A03_DISPATCH" 6 "." >/dev/null
T9_A03_FOREIGN="$(jq -c '.declared_foreign_paths' "$LEASE_FILE")"
assert_eq "$T9_A01_FOREIGN" "$T9_A03_FOREIGN" \
  "T9 carry-forward: continuation 3 (a03) STILL carries a01's original declaration -- continuation_cap is not silently capped at 1 by this isolation heuristic"
case "$T9_A03_FOREIGN" in
  *a01-uncheckpointed*|*a02-uncheckpointed*)
    _fail "T9 carry-forward: a prior dying attempt's own uncheckpointed mutation leaked into a03's declaration: [$T9_A03_FOREIGN]" ;;
  *) _ok "T9 carry-forward: neither prior dying attempt's own uncheckpointed mutation leaked into a03's declaration" ;;
esac

# a03 finally checkpoints and IS isolated despite the real pre-run dirt
# still sitting in the tree -- tolerated via the carried-forward
# declaration (the two prior dying attempts' own leftover mutations are
# cleaned up first: THAT reconciliation is a separate, already-covered
# scenario -- see "T9 not isolated", above).
rm -f "$T9_UNCHECKPOINTED_1" "$T9_UNCHECKPOINTED_2"
T9_A03_PROGRESS="$ATTEMPT_DIR/progress.jsonl"
T9_A03_ARTIFACT="$FEATURE_FOLDER/6-implementation/a03-in-flight.md"
printf 'a03 in flight
' > "$T9_A03_ARTIFACT"
write_fake_checkpoint "$T9_A03_PROGRESS" "$T9_A03_DISPATCH" 1 partial task-01 "$T9_A03_ARTIFACT" "" "" task-01
checkpoint_resume_state "$T9_A03_PROGRESS" "$T9_A03_DISPATCH"
rc=0
checkpoint_partial_isolated || rc=$?
assert_rc 0 "$rc" \
  "T9 carry-forward: a03 is isolated -- the real pre-run dirt is tolerated via the carried-forward declaration, proving continuation 2 (a03) is reachable on a non-pristine tree"
release_write_lease implementer >/dev/null
rm -f "$T9_PRERUN_FOREIGN" "$T9_A03_ARTIFACT"

# --- RM07 wired to a REAL isolation test, END TO END through
# recovery_action itself (code review fix -- previously checkpoint_resume_
# state had ZERO real call sites and the test poked $CHECKPOINT_DIRTY_UNIT
# into globals by hand before calling recovery_action, backwards from how
# resume-state actually has to run: BEFORE the isolation decision needs it,
# resolved from the real logical dispatch id, not primed by the test). ----
: > "$RUN_LOG"
rm -f "$LEASE_FILE"
allocate_attempt 6 02 implementer >/dev/null
T9_ISO_LOGICAL="$LOGICAL_DISPATCH_ID"
T9_ISO_DISPATCH="$DISPATCH_ID"
T9_ISO_PROGRESS="$ATTEMPT_DIR/progress.jsonl"
acquire_write_lease implementer role "$T9_ISO_DISPATCH" 6 "." >/dev/null
T9_ISO_ARTIFACT="$FEATURE_FOLDER/6-implementation/task-02-in-flight.md"
printf 'in flight\n' > "$T9_ISO_ARTIFACT"
write_fake_checkpoint "$T9_ISO_PROGRESS" "$T9_ISO_DISPATCH" 1 completed task-01 "" "" "" task-02
write_fake_checkpoint "$T9_ISO_PROGRESS" "$T9_ISO_DISPATCH" 2 partial task-02 "$T9_ISO_ARTIFACT" "" "" task-02

recovery_action TIMED_OUT DIRTY_CHECKPOINTED "$T9_ISO_LOGICAL" >/dev/null
assert_eq RM07 "$RECOVERY_MATRIX_ID" "T9 RM07 wired end-to-end: still RM07 regardless of isolation"
assert_eq VALID "$CHECKPOINT_STATE" \
  "T9 RM07 wired end-to-end: recovery_action itself ran checkpoint_resume_state against the real failed attempt (never a value the test poked in)"
assert_eq RECONCILE_THEN_CONTINUE_IF_ISOLATED "$RECOVERY_ACTION" \
  "T9 RM07 wired end-to-end: an isolated dirty checkpoint is authorized to reconcile-then-continue"
rc=0
recovery_retry_allowed "$T9_ISO_LOGICAL" "$RECOVERY_ACTION" || rc=$?
assert_rc 0 "$rc" "T9 RM07 wired end-to-end: the isolated case is actually authorized to continue"

# --- Blocker B fix: the plan's own fixed 2-argument call form
# (`recovery_action CLASSIFICATION MUTATION_STATE`) cannot decide isolation
# at all and must say so with a DISTINCT token, never silently report the
# SAME "not isolated" a genuinely-evaluated non-isolated case reports. -----
recovery_action TIMED_OUT DIRTY_CHECKPOINTED >/dev/null
assert_eq RM07 "$RECOVERY_MATRIX_ID" "T9 RM07 2-arg form: still RM07"
assert_eq RECONCILE_UNKNOWN_NO_LOGICAL_ID "$RECOVERY_ACTION" \
  "T9 RM07 2-arg form (the plan's fixed 'recovery_action CLASSIFICATION MUTATION_STATE' interface): a distinct token, not the same RECONCILE_BLOCKED_NOT_ISOLATED a real evaluation reports"
rc=0
recovery_retry_allowed "$T9_ISO_LOGICAL" "$RECOVERY_ACTION" || rc=$?
assert_rc 1 "$rc" "T9 RM07 2-arg form: RECONCILE_UNKNOWN_NO_LOGICAL_ID is never authorized to retry/continue either"
# The SAME real fixture, now with the logical id supplied, still correctly
# reports isolated -- proving the 2-arg case above is genuinely about the
# missing argument, not some other regression.
recovery_action TIMED_OUT DIRTY_CHECKPOINTED "$T9_ISO_LOGICAL" >/dev/null
assert_eq RECONCILE_THEN_CONTINUE_IF_ISOLATED "$RECOVERY_ACTION" \
  "T9 RM07 3-arg form: re-supplying the real logical id still correctly reports isolated"

T9_UNRELATED="$FEATURE_FOLDER/6-implementation/unrelated-stray.txt"
printf 'not mine either\n' > "$T9_UNRELATED"
recovery_action TIMED_OUT DIRTY_CHECKPOINTED "$T9_ISO_LOGICAL" >/dev/null
assert_eq RM07 "$RECOVERY_MATRIX_ID" "T9 RM07 wired end-to-end: still RM07 when NOT isolated"
assert_eq RECONCILE_BLOCKED_NOT_ISOLATED "$RECOVERY_ACTION" \
  "T9 RM07 wired end-to-end: a non-isolated dirty checkpoint is blocked, never optimistically continued"
rc=0
recovery_retry_allowed "$T9_ISO_LOGICAL" "$RECOVERY_ACTION" || rc=$?
assert_rc 1 "$rc" \
  "RECONCILE_BLOCKED_NOT_ISOLATED is never authorized to retry/continue (previously fell through to the uncapped *) return 0)"
rm -f "$T9_UNRELATED"
release_write_lease implementer >/dev/null

# --- Step 5's core requirement, made real: NEEDS_RECONCILIATION actually
# BLOCKS continuation. Executed counter-example from the review: prefix =
# one valid `partial task-01` record, suffix = garbage -- must NOT be
# byte-identical to a fully VALID checkpoint's authorization. -------------
: > "$RUN_LOG"
rm -f "$LEASE_FILE"
allocate_attempt 6 03 implementer >/dev/null
T9_BAD_LOGICAL="$LOGICAL_DISPATCH_ID"
T9_BAD_DISPATCH="$DISPATCH_ID"
T9_BAD_PROGRESS="$ATTEMPT_DIR/progress.jsonl"
acquire_write_lease implementer role "$T9_BAD_DISPATCH" 6 "." >/dev/null
write_fake_checkpoint "$T9_BAD_PROGRESS" "$T9_BAD_DISPATCH" 1 partial task-01 "" "" "" task-01
printf 'THIS IS NOT JSON\n' >> "$T9_BAD_PROGRESS"
recovery_action TIMED_OUT DIRTY_CHECKPOINTED "$T9_BAD_LOGICAL" >/dev/null
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 reconciliation gate: the fixture really is NEEDS_RECONCILIATION (valid partial prefix + malformed suffix)"
assert_eq RECONCILE_BLOCKED_NOT_ISOLATED "$RECOVERY_ACTION" \
  "T9 reconciliation gate: a malformed suffix after a valid partial prefix is BLOCKED, never authorized like a fully VALID checkpoint"
rc=0
recovery_retry_allowed "$T9_BAD_LOGICAL" "$RECOVERY_ACTION" || rc=$?
assert_rc 1 "$rc" "T9 reconciliation gate: never authorized to continue"
release_write_lease implementer >/dev/null

# --- Step 6: the global continuation cap emits CONTINUATION_CAP_REACHED, a
# distinct event from the generic RECOVERY_CAP_REACHED, and denies a 4th
# continuation under continuation_cap=3. ------------------------------------
: > "$RUN_LOG"
T9_CONT_LOGICAL="p06-i60-implementer"
for n in 1 2 3 4; do
  record_event ATTEMPT_FAILED phase=6 iteration=60 \
    dispatch_id="${T9_CONT_LOGICAL}-a$(printf '%02d' "$n")" \
    reason=x phase_name=implementation role=implementer classification=TIMED_OUT >/dev/null
done
rc=0
recovery_retry_allowed "$T9_CONT_LOGICAL" CONTINUE_WITHIN_CAP || rc=$?
assert_rc 1 "$rc" "continuation_cap=3: a 4th continuation is denied"
assert_present 'event=CONTINUATION_CAP_REACHED' "$RUN_LOG" \
  "continuation-cap exhaustion is CONTINUATION_CAP_REACHED, never silently restarting from scratch"
_t9_generic_cap_count="$("$GREP_BIN" -c 'event=RECOVERY_CAP_REACHED' "$RUN_LOG" || true)"
assert_eq 0 "$_t9_generic_cap_count" \
  "a continuation-cap denial never ALSO emits the generic RECOVERY_CAP_REACHED"

# --- reconstruct_checkpoint_state: recovers a failed attempt's own
# validated checkpoint path for a real, non-iterative phase (6). ------------
: > "$RUN_LOG"
T9_RECON_ID="p06-i00-implementer-a01"
record_event DISPATCH_STARTED phase=6 iteration=00 dispatch_id="$T9_RECON_ID" \
  reason=x phase_name=implementation role=implementer vendor=claude \
  logical_dispatch_id=p06-i00-implementer model=m status_path=/dev/null cwd=/tmp \
  lease=none snapshot=none >/dev/null
record_event DISPATCH_COMPLETED phase=6 iteration=00 dispatch_id="$T9_RECON_ID" \
  reason=x phase_name=implementation role=implementer vendor=claude appendix=implementer \
  logical_dispatch_id=p06-i00-implementer develop_it_git_sha=x develop_it_file_sha256=x \
  develop_it_dirty=no status_path=/dev/null verdict="" classification=TIMED_OUT exit_code=1 \
  model=m start_ms=1 end_ms=2 duration_ms=1 stdout_path=/dev/null stderr_path=/dev/null \
  mutation_state=DIRTY_CHECKPOINTED checkpoint_kind=implementation tokens_input_new=0 \
  tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=0 \
  usage_status=ok >/dev/null
CONTINUATION_PATH=""; DECLARED_FOREIGN_CHANGES=""
reconstruct_checkpoint_state 6
assert_eq "$T9_PROGRESS" "$CONTINUATION_PATH" \
  "reconstruct_checkpoint_state recovers the failed attempt's own checkpoint path for phase 6"

# --- reconstruct_checkpoint_state: also reachable for an ITERATING phase
# (7) when called WITH that round's own $ITERATION -- code review fix: the
# document's only worked example previously called it with iteration
# defaulted to 00, which can never find anything for a role whose real
# dispatch_id always carries a real per-round iteration number. -----------
: > "$RUN_LOG"
T9_RECON7_ID="p07-i01-implementation-fixer-a01"
record_event DISPATCH_STARTED phase=7 iteration=01 dispatch_id="$T9_RECON7_ID" \
  reason=x phase_name=code-review role=implementation-fixer vendor=claude \
  logical_dispatch_id=p07-i01-implementation-fixer model=m status_path=/dev/null cwd=/tmp \
  lease=none snapshot=none >/dev/null
record_event DISPATCH_COMPLETED phase=7 iteration=01 dispatch_id="$T9_RECON7_ID" \
  reason=x phase_name=code-review role=implementation-fixer vendor=claude appendix=implementation-fixer \
  logical_dispatch_id=p07-i01-implementation-fixer develop_it_git_sha=x develop_it_file_sha256=x \
  develop_it_dirty=no status_path=/dev/null verdict="" classification=TIMED_OUT exit_code=1 \
  model=m start_ms=1 end_ms=2 duration_ms=1 stdout_path=/dev/null stderr_path=/dev/null \
  mutation_state=DIRTY_CHECKPOINTED checkpoint_kind=implementation tokens_input_new=0 \
  tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=0 \
  usage_status=ok >/dev/null
T9_RECON7_DIR="$(role_attempt_dir implementation-fixer "$T9_RECON7_ID")"
mkdir -p "$T9_RECON7_DIR"
T9_RECON7_PROGRESS="$T9_RECON7_DIR/progress.jsonl"
write_fake_checkpoint "$T9_RECON7_PROGRESS" "$T9_RECON7_ID" 1 partial finding-01 "" "" "" finding-01

CONTINUATION_PATH=""; DECLARED_FOREIGN_CHANGES=""
reconstruct_checkpoint_state 7
assert_eq "" "$CONTINUATION_PATH" \
  "reconstruct_checkpoint_state 7 with no iteration is a no-op for an ITERATING phase -- the default iteration (00) never matches a real p07-i01 attempt"

CONTINUATION_PATH=""; DECLARED_FOREIGN_CHANGES=""
reconstruct_checkpoint_state 7 01
assert_eq "$T9_RECON7_PROGRESS" "$CONTINUATION_PATH" \
  "reconstruct_checkpoint_state 7 01 recovers the failed attempt's own checkpoint path once called with the real iteration"

# --- checkpoint_append genuinely refuses to build on an existing malformed
# suffix (code review fix: the retired lenient scanner silently skipped a
# truncated line, so a NEW record landed on top of it undetected -- this is
# the exact executed counter-example from the review). ---------------------
rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 \
  "$T9_ARTIFACT" "$T9_SHA" "$T9_COMMIT" task-02
printf '{"schema_version":2,"dispatch_id":"%s","sequence":2,"state":"pa' "$T9_DISPATCH_ID" >> "$T9_PROGRESS"
_t9_before_bytes="$(wc -c < "$T9_PROGRESS")"
rc=0
checkpoint_append "$T9_PROGRESS" "$T9_DISPATCH_ID" implementer \
  sequence=2 unit_type=task unit_id=task-02 state=completed \
  artifact_path="" artifact_sha256="" commit_sha="" verification=PASS next_unit=task-03 \
  2>"$BUILD/t9-append-malformed.err" || rc=$?
assert_rc 1 "$rc" "checkpoint_append refuses to build on top of an existing malformed suffix"
assert_contains "CHECKPOINT_APPEND_NEEDS_RECONCILIATION" "$BUILD/t9-append-malformed.err" \
  "the refusal names itself"
assert_eq "$_t9_before_bytes" "$(wc -c < "$T9_PROGRESS")" \
  "the refused append left the file byte-for-byte unchanged"

# --- Step 3's "per-file lock": checkpoint_append must NOT contend with the
# SHARED $ORCHESTRATION_DIR/log.lock every record_event append already uses
# -- holding that global lock manually must never block a checkpoint_append
# call (code review fix: they were previously the literal same lock file).
rm -f "$T9_PROGRESS"
_run_log_lock_acquire || _fail "T9 lock setup: could not acquire the global log.lock"
_t9_lock_start_ms="$(now_ms)"
rc=0
checkpoint_append "$T9_PROGRESS" "$T9_DISPATCH_ID" implementer \
  sequence=1 unit_type=task unit_id=task-01 state=completed \
  artifact_path="" artifact_sha256="" commit_sha="" verification=PASS next_unit=task-02 || rc=$?
_t9_lock_elapsed_ms=$(( $(now_ms) - _t9_lock_start_ms ))
_run_log_lock_release
assert_rc 0 "$rc" "checkpoint_append succeeds while the SEPARATE global log.lock is held (a genuinely per-file lock, not a shared one)"
if [ "$_t9_lock_elapsed_ms" -lt 2000 ]; then
  _ok "checkpoint_append did not wait on the held global log.lock (${_t9_lock_elapsed_ms}ms)"
else
  _fail "checkpoint_append took ${_t9_lock_elapsed_ms}ms while the global log.lock was held -- looks like shared-lock contention"
fi

# --- nit fixes: whitespace-only file, a sequence GAP, and an unreachable
# (but real) commit object each get their own dedicated coverage. ----------
rm -f "$T9_PROGRESS"
printf '\n\n\n' > "$T9_PROGRESS"
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NO_CHECKPOINT "$CHECKPOINT_STATE" \
  "T9 whitespace-only: a file containing only blank lines is NO_CHECKPOINT, never a vacuous VALID with zero units"

rm -f "$T9_PROGRESS"
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 "" "" "" task-02
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 7 partial task-02 "" "" "" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 sequence gap: 1 then 7 is a discontinuous checkpoint, not merely 'increasing', and must be blocked too"
assert_eq 1 "$CHECKPOINT_LAST_SEQUENCE" "T9 sequence gap: the valid prefix stops at the first good record"

rm -f "$T9_PROGRESS"
( cd "$REPO_ROOT" && printf 'orphan\n' > t9-orphan.txt && git add t9-orphan.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "t9 orphan commit" ) >/dev/null
T9_ORPHAN_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
( cd "$REPO_ROOT" && git reset -q --hard "$T9_COMMIT" )
write_fake_checkpoint "$T9_PROGRESS" "$T9_DISPATCH_ID" 1 completed task-01 "" "" "$T9_ORPHAN_COMMIT" task-02
checkpoint_resume_state "$T9_PROGRESS" "$T9_DISPATCH_ID"
assert_eq NEEDS_RECONCILIATION "$CHECKPOINT_STATE" \
  "T9 unreachable commit: a real commit object that is not an ancestor of HEAD needs reconciliation"
case "$CHECKPOINT_BAD_REASON" in
  COMMIT_NOT_REACHABLE_FROM_HEAD*) _ok "T9 unreachable commit: bad reason names it" ;;
  *) _fail "T9 unreachable commit: bad reason wrong: [$CHECKPOINT_BAD_REASON]" ;;
esac

# =============================================================================
# Task 10: preflight_zero_token_gates -- the five zero-token gates (spec
# S16.1) must run in order, each writing its own success event, and NO paid
# probe or vendor dispatch may reach the fake CLI until all five succeed.
# Each sub-case below injects a failure at one gate and proves the run never
# got far enough to spend a token: FAKE_ARGV_LOG carries no `--model`/`-m`
# invocation (the load-bearing assertion -- a real dispatch or model-ID probe
# ALWAYS binds a model explicitly; canary_preflight's own `--help` syntax
# pings never do, so they alone appearing is still "zero tokens spent", per
# the gate order's own "zero-token" label -- see the cookbook section
# "Preflight zero-token gate sequence").
#
# Gate 4 (process identity + gitignore) never halts by design -- identity was
# already validated at gate 1, and the gitignore check is advisory-only (same
# "never halt" rule the pre-existing Phase 1 prose already gave it) -- so
# there is no failure injection for gate 4 here; its SUCCESS is proven by the
# full-success case below recording its event.
# =============================================================================
T10_WORK="$BUILD/t10-gates"; rm -rf "$T10_WORK"; mkdir -p "$T10_WORK"
T10_BIN_FULL="$T10_WORK/bin-full"
build_minimal_path "$T10_BIN_FULL"

_t10_new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  ( cd "$repo" && : > seed && git add seed \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
  mkdir -p "$repo/docs/superpowers/specs"
  ( cd "$repo" && : > docs/superpowers/specs/.gitkeep \
    && git add docs/superpowers/specs/.gitkeep \
    && git -c user.email=t@t -c user.name=t commit -qm seed-docs ) >/dev/null
}

# A dispatch-style invocation ALWAYS binds a model explicitly (`--model X` for
# claude, `-m X` for codex -- see "Both vendors are bound explicitly").
# canary_preflight's own `--help` pings never carry either flag.
_t10_dispatch_calls() { "$GREP_BIN" -cE -- '--model |(^| )-m ' "$1" 2>/dev/null || true; }

# ---- Gate 1 failure: invalid paths (REPO_ROOT does not exist) -------------
T10_REPO1="$T10_WORK/g1-repo"; _t10_new_repo "$T10_REPO1"
T10_ARGV1="$T10_WORK/g1-argv.log"; : > "$T10_ARGV1"
g1_rc=0
(
  unset ORCHESTRATION_DIR RUNTIME_DIR   # a genuinely bare Phase -1 first shell -- init_v2_fixture above exports both from an unrelated folder
  PATH="$T10_BIN_FULL"; FAKE_ARGV_LOG="$T10_ARGV1"
  export PATH FAKE_ARGV_LOG
  PROCESS_PATH="$PROCESS_DOC"
  REPO_ROOT="$T10_WORK/does-not-exist"
  FEATURE_FOLDER="$T10_REPO1/docs/superpowers/specs/g1-artifacts"
  preflight_zero_token_gates
) >"$T10_WORK/g1.out" 2>"$T10_WORK/g1.err" || g1_rc=$?
assert_rc 1 "$g1_rc" "gate1 failure (bad REPO_ROOT): preflight_zero_token_gates fails"
assert_line_count 0 "$T10_ARGV1" "gate1 failure: FAKE_ARGV_LOG is completely empty (gate 2 never ran)"
# Code review round 2 fix (finding 5): a bad-paths gate-1 failure IS one of
# the uniform-rule HALT gates (distinct from validate_existing_run_log's own
# zero-write exception) -- _preflight_halt creates the folder and durably
# records event=HALT.
assert_present 'event=HALT' "$T10_REPO1/docs/superpowers/specs/g1-artifacts/RUN_LOG.md" \
  "gate1 failure: a bad-paths failure durably records event=HALT (the uniform rule, not the existing-run-log exception)"
assert_eq 0 "$("$GREP_BIN" -c 'event=PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE' "$T10_REPO1/docs/superpowers/specs/g1-artifacts/RUN_LOG.md" || true)" \
  "gate1 failure: gate 1's own SUCCESS event is NOT durable"

# ---- Gate 2 failure: a hard-required binary (jq) is missing ---------------
T10_REPO2="$T10_WORK/g2-repo"; _t10_new_repo "$T10_REPO2"
T10_BIN_NOJQ="$T10_WORK/bin-no-jq"; build_minimal_path "$T10_BIN_NOJQ" jq
T10_ARGV2="$T10_WORK/g2-argv.log"; : > "$T10_ARGV2"
g2_rc=0
(
  unset ORCHESTRATION_DIR RUNTIME_DIR
  PATH="$T10_BIN_NOJQ"; FAKE_ARGV_LOG="$T10_ARGV2"
  export PATH FAKE_ARGV_LOG
  PROCESS_PATH="$PROCESS_DOC"
  REPO_ROOT="$T10_REPO2"
  FEATURE_FOLDER="$T10_REPO2/docs/superpowers/specs/g2-artifacts"
  preflight_zero_token_gates
) >"$T10_WORK/g2.out" 2>"$T10_WORK/g2.err" || g2_rc=$?
assert_rc 1 "$g2_rc" "gate2 failure (missing jq): preflight_zero_token_gates fails"
assert_line_count 0 "$T10_ARGV2" \
  "gate2 failure: FAKE_ARGV_LOG is completely empty (canary_preflight's own binary check fails before any exec)"
T10_LOG2="$T10_REPO2/docs/superpowers/specs/g2-artifacts/RUN_LOG.md"
assert_present 'event=PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE' "$T10_LOG2" \
  "gate2 failure: gate 1's success event IS durable"
assert_eq 0 "$("$GREP_BIN" -c 'event=LOCAL_CLI_CANARIES_PASSED' "$T10_LOG2" || true)" \
  "gate2 failure: gate 2's own success event is NOT durable"
assert_present 'event=HALT' "$T10_LOG2" \
  "gate2 failure: durably records event=HALT (not just an unenforced stderr message)"

# ---- Gate 3 failure: target dirty tree ------------------------------------
T10_REPO3="$T10_WORK/g3-repo"; _t10_new_repo "$T10_REPO3"
( cd "$T10_REPO3" && printf 'dirty\n' >> seed )
T10_ARGV3="$T10_WORK/g3-argv.log"; : > "$T10_ARGV3"
g3_rc=0
(
  unset ORCHESTRATION_DIR RUNTIME_DIR
  PATH="$T10_BIN_FULL"; FAKE_ARGV_LOG="$T10_ARGV3"
  export PATH FAKE_ARGV_LOG
  PROCESS_PATH="$PROCESS_DOC"
  REPO_ROOT="$T10_REPO3"
  FEATURE_FOLDER="$T10_REPO3/docs/superpowers/specs/g3-artifacts"
  preflight_zero_token_gates
) >"$T10_WORK/g3.out" 2>"$T10_WORK/g3.err" || g3_rc=$?
assert_rc 1 "$g3_rc" "gate3 failure (dirty tree): preflight_zero_token_gates fails"
assert_eq 0 "$(_t10_dispatch_calls "$T10_ARGV3")" \
  "gate3 failure: zero MODEL-BOUND invocations reached the fake CLI (only canary's own --help pings may appear)"
T10_LOG3="$T10_REPO3/docs/superpowers/specs/g3-artifacts/RUN_LOG.md"
assert_present 'event=LOCAL_CLI_CANARIES_PASSED' "$T10_LOG3" "gate3 failure: gate 2's success event IS durable"
assert_eq 0 "$("$GREP_BIN" -c 'event=TARGET_DIRTY_TREE_GATE_PASSED' "$T10_LOG3" || true)" \
  "gate3 failure: gate 3's own success event is NOT durable"
assert_present 'event=HALT' "$T10_LOG3" \
  "gate3 failure: durably records event=HALT (not just an unenforced stderr message)"

# ---- Gate 5 failure: runtime bootstrap (missing extractor) ----------------
T10_REPO5="$T10_WORK/g5-repo"; _t10_new_repo "$T10_REPO5"
T10_ARGV5="$T10_WORK/g5-argv.log"; : > "$T10_ARGV5"
g5_rc=0
(
  unset ORCHESTRATION_DIR RUNTIME_DIR
  PATH="$T10_BIN_FULL"; FAKE_ARGV_LOG="$T10_ARGV5"
  export PATH FAKE_ARGV_LOG
  PROCESS_PATH="$PROCESS_DOC"
  REPO_ROOT="$T10_REPO5"
  FEATURE_FOLDER="$T10_REPO5/docs/superpowers/specs/g5-artifacts"
  PROCESS_REPO_ROOT="$T10_WORK/g5-fake-process-repo"   # no tests/lib/extract.py at all
  mkdir -p "$PROCESS_REPO_ROOT"
  git -C "$PROCESS_REPO_ROOT" init -q
  ( cd "$PROCESS_REPO_ROOT" && : > f && git add f \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
  # PROCESS_PATH must live inside THIS fake PROCESS_REPO_ROOT for gate 1 to
  # resolve it there instead of the real process repo.
  mkdir -p "$PROCESS_REPO_ROOT/docs"
  cp "$PROCESS_DOC" "$PROCESS_REPO_ROOT/docs/develop-it-prompt.md"
  ( cd "$PROCESS_REPO_ROOT" && git add docs/develop-it-prompt.md \
    && git -c user.email=t@t -c user.name=t commit -qm seed-doc ) >/dev/null
  PROCESS_PATH="$PROCESS_REPO_ROOT/docs/develop-it-prompt.md"
  preflight_zero_token_gates
) >"$T10_WORK/g5.out" 2>"$T10_WORK/g5.err" || g5_rc=$?
assert_rc 1 "$g5_rc" "gate5 failure (no extractor in PROCESS_REPO_ROOT): preflight_zero_token_gates fails"
assert_eq 0 "$(_t10_dispatch_calls "$T10_ARGV5")" \
  "gate5 failure: zero MODEL-BOUND invocations reached the fake CLI"
T10_LOG5="$T10_REPO5/docs/superpowers/specs/g5-artifacts/RUN_LOG.md"
assert_present 'event=PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED' "$T10_LOG5" \
  "gate5 failure: gate 4's success event IS durable"
assert_eq 0 "$("$GREP_BIN" -c 'event=RUNTIME_AND_REGISTRIES_VERIFIED' "$T10_LOG5" || true)" \
  "gate5 failure: gate 5's own success event is NOT durable"
assert_present 'event=HALT' "$T10_LOG5" \
  "gate5 failure: durably records event=HALT (not just an unenforced stderr message)"
assert_present 'reason:.*BOOTSTRAP_IO_ERROR' "$T10_LOG5" \
  "gate5 failure: the HALT reason carries bootstrap_runtime's own failure token, not a generic message"

# ---- Full success: all five gates pass, in order --------------------------
T10_REPOS="$T10_WORK/success-repo"; _t10_new_repo "$T10_REPOS"
T10_ARGVS="$T10_WORK/success-argv.log"; : > "$T10_ARGVS"
gs_rc=0; gs_out=""
# Code review round 2 fix (finding 2): print $RUNTIME_DIR from INSIDE the
# subshell, right after the gates run -- if bootstrap_runtime were still
# called inside its own `$(...)` (or any leaked/stale RUNTIME_DIR from
# init_v2_fixture's earlier, unrelated fixture folder survived), the
# `source "$RUNTIME_DIR/..."` line would use the WRONG path silently.
gs_out="$(
  unset ORCHESTRATION_DIR RUNTIME_DIR
  PATH="$T10_BIN_FULL"; FAKE_ARGV_LOG="$T10_ARGVS"
  export PATH FAKE_ARGV_LOG
  PROCESS_PATH="$PROCESS_DOC"
  REPO_ROOT="$T10_REPOS"
  FEATURE_FOLDER="$T10_REPOS/docs/superpowers/specs/success-artifacts"
  preflight_zero_token_gates
  printf 'RUNTIME_DIR_SEEN=%s\n' "$RUNTIME_DIR"
)" || gs_rc=$?
assert_rc 0 "$gs_rc" "all five gates pass: preflight_zero_token_gates succeeds"
case "$gs_out" in
  GATES_PASSED*) _ok "all five gates pass: prints the GATES_PASSED marker" ;;
  *) _fail "all five gates pass: unexpected output [$gs_out]" ;;
esac
gs_runtime_dir_seen="$(printf '%s\n' "$gs_out" | "$GREP_BIN" -oE 'RUNTIME_DIR_SEEN=.*' | cut -d= -f2- || true)"
assert_eq "$T10_REPOS/docs/superpowers/specs/success-artifacts/.orchestration/runtime" \
  "$gs_runtime_dir_seen" \
  "gate5 success: RUNTIME_DIR points at THIS run's own folder, never a stale/inherited one from an unrelated fixture"
T10_LOGS="$T10_REPOS/docs/superpowers/specs/success-artifacts/RUN_LOG.md"
gate_order="$("$GREP_BIN" -oE 'event=(PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE|LOCAL_CLI_CANARIES_PASSED|TARGET_DIRTY_TREE_GATE_PASSED|PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED|RUNTIME_AND_REGISTRIES_VERIFIED)' "$T10_LOGS" | tr '\n' ' ')"
assert_eq "event=PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE event=LOCAL_CLI_CANARIES_PASSED event=TARGET_DIRTY_TREE_GATE_PASSED event=PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED event=RUNTIME_AND_REGISTRIES_VERIFIED " \
  "$gate_order" "all five gate-success events are durable, in the exact prescribed order"
assert_eq 0 "$(_t10_dispatch_calls "$T10_ARGVS")" \
  "all five gates pass: still zero MODEL-BOUND invocations -- preflight_zero_token_gates itself never dispatches probe_models or a skill probe (that is Phase -1's own subsequent step)"

finish
