# shellcheck shell=bash
# Schema-v2 fixture initialization for tests/check_10_process_v2.sh and later
# schema-v2 checks. Builds on init_fixture_env (tests/lib/assert.sh), adding
# the .orchestration/ directory contract that schema-v2 runtime state lives
# under.

init_v2_fixture() {
  init_fixture_env
  export ORCHESTRATION_DIR="$FEATURE_FOLDER/.orchestration"
  export RUNTIME_DIR="$ORCHESTRATION_DIR/runtime"
  export SDD_DIR="$FEATURE_FOLDER/6-implementation/sdd"
  export RUN_LOG="$FEATURE_FOLDER/RUN_LOG.md"
  export LEASE_FILE="$ORCHESTRATION_DIR/write-lease.json"
  export TRANSCRIPTS_DIR="$FEATURE_FOLDER/transcripts"
  mkdir -p "$ORCHESTRATION_DIR/snapshots" "$SDD_DIR" "$TRANSCRIPTS_DIR" "$REPO_ROOT"
  : > "$RUN_LOG"
}

# ---- build_minimal_path (Task 10) -------------------------------------------
# Builds a scratch bin directory that mirrors every REAL binary already on
# the CALLER's current PATH (so it must run BEFORE PATH is overridden) --
# not just canary_preflight's own hard-required list, since the cookbook's
# OTHER helpers (record_event, dirty_tree_check, bootstrap_runtime, ...) rely
# on ordinary coreutils (`dirname`, `basename`, `ln`, `mktemp`, ...) that list
# never names -- while symlinking `claude`/`codex` to the fakebin stubs
# instead of the real binaries so a real launch is observable. Any tool named
# in EXCLUDE is left out entirely -- `command -v` for that name then finds
# nothing anywhere, simulating a genuinely missing binary (Step 1's gate-2
# failure injection) WITHOUT ever invoking the fake CLI, which a "claude
# --help fails" injection could not guarantee (the --help call itself would
# already be one invocation).
#
# Usage: build_minimal_path DEST_DIR [EXCLUDE...]
build_minimal_path() {
  local dest="$1"; shift
  local exclude=" $* "
  mkdir -p "$dest"
  local dir tool
  local -a _bmp_dirs
  # shellcheck disable=SC2153  # PATH is the real, un-overridden caller PATH
  IFS=: read -r -a _bmp_dirs <<< "$PATH"
  for dir in "${_bmp_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for tool in "$dir"/*; do
      [ -f "$tool" ] && [ -x "$tool" ] || continue
      tool="${tool##*/}"
      [ -e "$dest/$tool" ] && continue   # first PATH hit wins, like real PATH resolution
      case "$exclude" in *" $tool "*) continue ;; esac
      ln -sf "$(command -v "$tool")" "$dest/$tool" 2>/dev/null
    done
  done
  case "$exclude" in *" claude "*) : ;; *) ln -sf "$_TESTS_DIR/fakebin/claude" "$dest/claude" ;; esac
  case "$exclude" in *" codex "*) : ;; *) ln -sf "$_TESTS_DIR/fakebin/codex" "$dest/codex" ;; esac
}

# ---- run_fake_attempt (Task 5) ----------------------------------------------
# A private role-contracts copy for run_fake_attempt's own two fixture roles
# (preflight-claude / preflight-codex), with their timeout_minutes shrunk to a
# few seconds. Reusing the REAL registry's 5-minute preflight timeout would
# make a single MODE=timeout exercise cost real minutes, and this function is
# meant to be swept across every FAKE_MODE cheaply -- by check_07_fakecli.sh
# here, and by the Task 7 recovery suite later. Cached under $BUILD so
# repeated calls in one check don't re-invoke the extractor.
_run_fake_attempt_role_contracts() {
  local path="$BUILD/fake-attempt-roles.tsv"
  if [ ! -f "$path" ]; then
    python3 "$REPO_TOP/tests/lib/extract.py" roles > "$path.tmp"
    awk -F'\t' -v OFS='\t' '
      NR==1 { for (i=1;i<=NF;i++) if ($i=="timeout_minutes") tcol=i; print; next }
      { if (($1=="preflight-claude" || $1=="preflight-codex") && tcol) $tcol="0.05"; print }
    ' "$path.tmp" > "$path"
    rm -f "$path.tmp"
  fi
  printf '%s\n' "$path"
}

# Usage: run_fake_attempt VENDOR MODE MUTATION EXIT_CODE
#   VENDOR    claude|codex
#   MODE      any FAKE_MODE value fakebin/{claude,codex} support
#   MUTATION  none|clean-checkpointed|dirty-checkpointed|dirty-uncheckpointed|unknown
#             -- recorded into the results ledger and exported to the fake CLI,
#             which itself ignores it; wiring it into a REAL dirty-tree fixture
#             is inspect_mutation_state's job (Task 7 seam, not this function's).
#   EXIT_CODE the fake CLI's requested exit code -- wired straight through as
#             FAKE_EXIT_CODE for every mode except "timeout" (moot there: the
#             process is killed by the wrapper, never exits on its own). The
#             ledger records this REQUESTED value next to the OBSERVED rc so a
#             caller can compare them, not just trust one of the two.
#
# Sets the global FAKE_ATTEMPT_STATUS_PATH to the STATUS file path this call
# exported to the fake CLI (command-scoped, like invoke_vendor's own
# DISPATCH_ID/ATTEMPT plumbing) -- read it directly after calling, the same
# way callers read dispatch_state's $DISPATCH_STATE global; a subshell would
# discard it. Resets ONLY its own attempt-local scratch directory (never
# $FEATURE_FOLDER/RUN_LOG.md or the caller's $ROLE_CONTRACTS_PATH), invokes
# the real `invoke_vendor` cookbook helper end to end against the fakebin
# stubs, and appends one row to $BUILD/fake-attempt-results.tsv. classify_attempt
# does not exist yet (a later task), so "observed_rc" stands in for the
# eventual classification column -- callers reason about it the same way.
#
# check_07_fakecli.sh exercises every FAKE_MODE through this one function; the
# Task 7 recovery suite calls it too, rather than re-deriving its own mode
# conditions.
run_fake_attempt() {
  local vendor="$1" mode="$2" mutation="$3" exit_code="$4"
  local role dir prompt out err rc results_tsv
  local ROLE_CONTRACTS_PATH

  case "$vendor" in
    claude) role=preflight-claude ;;
    codex)  role=preflight-codex ;;
    *) echo "RUN_FAKE_ATTEMPT_UNKNOWN_VENDOR:$vendor" >&2; return 1 ;;
  esac
  ROLE_CONTRACTS_PATH="$(_run_fake_attempt_role_contracts)"

  mkdir -p "$BUILD/fake-attempts"
  dir="$(mktemp -d "$BUILD/fake-attempts/${vendor}-${mode}-XXXXXX")"
  prompt="$dir/prompt.txt"; out="$dir/stdout.json"; err="$dir/stderr.txt"
  printf 'fake attempt prompt\n' > "$prompt"
  # shellcheck disable=SC2034  # consumed by the caller after run_fake_attempt returns
  FAKE_ATTEMPT_STATUS_PATH="$dir/STATUS.md"

  rc=0
  FAKE_MODE="$mode" FAKE_EXIT_CODE="$exit_code" FAKE_MUTATION="$mutation" \
    FAKE_ARGV_LOG="$dir/argv.log" FAKE_LOG="$dir/fake.tsv" \
    STATUS_PATH="$FAKE_ATTEMPT_STATUS_PATH" \
    invoke_vendor "$role" "$prompt" "$out" "$err"
  rc=$?

  results_tsv="$BUILD/fake-attempt-results.tsv"
  [ -f "$results_tsv" ] \
    || printf 'vendor\tmode\tmutation\texit_code\tobserved_rc\tstdout_path\tstderr_path\tstatus_path\n' > "$results_tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$vendor" "$mode" "$mutation" "$exit_code" "$rc" "$out" "$err" "$FAKE_ATTEMPT_STATUS_PATH" >> "$results_tsv"

  return "$rc"
}

# ---- write_fake_lease (Task 8) ----------------------------------------------
# Writes a well-formed write-lease.json by hand -- the fixture-side
# counterpart to acquire_write_lease's own JSON shape, for tests that need an
# EXISTING lease on disk without going through a real dispatch (RM02/RM03 in
# tests/check_09_recovery.sh, the OBSERVED_FAILED_OWNER case in
# tests/check_06_cookbook.sh). Every field acquire_write_lease itself writes
# is present, so a caller testing "does _write_lease_state read field X"
# starts from a genuinely complete record, not one that happens to omit it.
#
# Usage: write_fake_lease LEASE_FILE DISPATCH_ID [OWNER] [AUTHORITY]
write_fake_lease() {
  local file="$1" dispatch_id="$2" owner="${3:-debugger}" authority="${4:-role}"
  printf '{"schema_version":2,"dispatch_id":"%s","lease_owner":"%s","authority":"%s",' \
    "$dispatch_id" "$owner" "$authority" > "$file"
  printf '"phase":"6","acquired_at":"1970-01-01T00:00:00Z","baseline_head":"0000000000000000000000000000000000000000",' \
    >> "$file"
  printf '"declared_write_paths":["."],"declared_foreign_paths":[],"declared_foreign_commits":[],' \
    >> "$file"
  printf '"snapshot_manifest_path":"%s"}\n' "$(dirname "$file")/fake-lease-manifest.json" >> "$file"
}

# ---- write_fake_checkpoint (Task 9) -----------------------------------------
# Appends ONE well-formed common-schema-v2 checkpoint record (spec S10.1) to
# PROGRESS_PATH by hand -- the fixture-side counterpart to checkpoint_append's
# own JSON shape, for tests that build up a progress.jsonl line by line
# (valid multi-record files, then a deliberately corrupted line appended on
# top) without going through the real dispatch lifecycle. Every field
# checkpoint_resume_state itself reads is present, so a caller testing "does
# checkpoint_resume_state reject field X" starts from an otherwise-valid
# record.
#
# Usage: write_fake_checkpoint PROGRESS_PATH DISPATCH_ID SEQUENCE STATE UNIT_ID \
#          [ARTIFACT_PATH] [ARTIFACT_SHA256] [COMMIT_SHA] [NEXT_UNIT]
write_fake_checkpoint() {
  local path="$1" dispatch_id="$2" sequence="$3" state="$4" unit_id="$5"
  local artifact_path="${6:-}" artifact_sha256="${7:-}" commit_sha="${8:-}" next_unit="${9:-}"
  mkdir -p "$(dirname "$path")"
  jq -cn --argjson schema_version 2 --arg dispatch_id "$dispatch_id" \
    --argjson sequence "$sequence" --arg role test-role --arg unit_type task \
    --arg unit_id "$unit_id" --arg state "$state" --arg artifact_path "$artifact_path" \
    --arg artifact_sha256 "$artifact_sha256" --arg commit_sha "$commit_sha" \
    --argjson finding_ids '[]' --arg verification PASS --arg next_unit "$next_unit" \
    --arg timestamp "1970-01-01T00:00:00Z" \
    '{schema_version:$schema_version, dispatch_id:$dispatch_id, sequence:$sequence,
      role:$role, unit_type:$unit_type, unit_id:$unit_id, state:$state,
      artifact_path:$artifact_path, artifact_sha256:$artifact_sha256,
      commit_sha:$commit_sha, finding_ids:$finding_ids, verification:$verification,
      next_unit:$next_unit, timestamp:$timestamp}' >> "$path"
}
