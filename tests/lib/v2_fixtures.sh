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
