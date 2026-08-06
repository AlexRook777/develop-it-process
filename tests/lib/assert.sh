# shellcheck shell=bash
# Assertion helpers for develop-it-process checks.
# Exit codes: 0 PASS, 1 FAIL, 77 SKIP.

GREP_BIN="${GREP_BIN:-/usr/bin/grep}"
_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_TOP="$(cd "$_TESTS_DIR/.." && pwd)"
PROCESS_DOC="${PROCESS_DOC:-$REPO_TOP/develop-it-prompt.md}"
BUILD="${BUILD:-$_TESTS_DIR/.build}"
mkdir -p "$BUILD"

_FAILURES=0

note() { printf '    %s\n' "$*"; }

_ok()   { printf '  ok   %s\n' "$*"; }
_fail() { printf '  FAIL %s\n' "$*"; _FAILURES=$((_FAILURES + 1)); }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then _ok "$msg"
  else _fail "$msg"; note "expected: [$expected]"; note "actual:   [$actual]"; fi
}

assert_rc() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" -eq "$actual" ]; then _ok "$msg"
  else _fail "$msg (expected rc=$expected, got rc=$actual)"; fi
}

assert_present() {
  local pattern="$1" file="$2" msg="$3"
  if "$GREP_BIN" -qE -- "$pattern" "$file"; then _ok "$msg"
  else _fail "$msg"; note "pattern not found: $pattern"; note "in: $file"; fi
}

assert_absent() {
  local pattern="$1" file="$2" msg="$3"
  local hits
  hits="$("$GREP_BIN" -nE -- "$pattern" "$file" | head -5)"
  if [ -z "$hits" ]; then _ok "$msg"
  else _fail "$msg"; note "pattern should be absent: $pattern"; printf '    %s\n' "$hits"; fi
}

skip() { printf '  SKIP %s\n' "$*"; exit 77; }

finish() {
  if [ "$_FAILURES" -eq 0 ]; then printf '  -- all assertions passed\n'; exit 0; fi
  printf '  -- %d assertion(s) failed\n' "$_FAILURES"
  exit 1
}

# Source the extracted cookbook and initialise orchestration variables with
# throwaway fixture values. Never rely on the cookbook initialising itself: it
# is definitions-only by design, so a top-level ${VAR:?} cannot abort this shell.
load_cookbook() {
  python3 "$_TESTS_DIR/lib/extract.py" cookbook >/dev/null 2>&1 || {
    _fail "cookbook not extractable"; return 1; }
  # shellcheck source=/dev/null
  source "$BUILD/cookbook.sh" || { _fail "cookbook.sh failed to source"; return 1; }
  return 0
}

# Build a throwaway target repo and feature folder, then initialise.
# Usage: init_fixture_env [outside]   ("outside" puts the feature folder outside the repo)
init_fixture_env() {
  local where="${1:-inside}"
  FIXTURE_ROOT="$(mktemp -d)"
  REPO_ROOT="$FIXTURE_ROOT/target"
  mkdir -p "$REPO_ROOT"
  git -C "$REPO_ROOT" init -q
  ( cd "$REPO_ROOT" && : > seed && git add seed \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
  if [ "$where" = outside ]; then
    FEATURE_FOLDER="$FIXTURE_ROOT/outside-ff"
  else
    FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/fixture-artifacts"
  fi
  mkdir -p "$FEATURE_FOLDER/transcripts"
  PROCESS_PATH="$PROCESS_DOC"
  init_orchestration_vars
}
