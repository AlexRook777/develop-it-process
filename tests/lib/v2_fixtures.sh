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
