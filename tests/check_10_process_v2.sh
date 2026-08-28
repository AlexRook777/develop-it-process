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

finish
