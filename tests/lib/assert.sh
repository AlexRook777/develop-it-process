# shellcheck shell=bash
# Assertion helpers for develop-it-process checks.
# Exit codes: 0 PASS, 1 FAIL, 77 SKIP.

GREP_BIN="${GREP_BIN:-/usr/bin/grep}"
_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_TOP="$(cd "$_TESTS_DIR/.." && pwd)"
PROCESS_DOC="${PROCESS_DOC:-$REPO_TOP/develop-it-prompt.md}"
BUILD="${BUILD:-$_TESTS_DIR/.build}"
mkdir -p "$BUILD"

# Task 12 (P00 stage 2): the process document is a SET -- the core document
# plus the per-phase packs phases/*.md. PROCESS_FULL is the concatenation,
# core first then the packs in NUMERIC phase order (so `^## Phase N —`
# headings appear in phase order and range-slicing checks keep working).
# Checks that assert on phase-step or appendix CONTENT read $PROCESS_FULL;
# checks about the core document's own resident text keep using $PROCESS_DOC.
PROCESS_FULL="$BUILD/process-full.md"
{
  cat "$PROCESS_DOC"
  for _pk in 1 2 3 4 5 6 7 8 9 10 11; do
    cat "$REPO_TOP/phases/$_pk-"*.md 2>/dev/null
  done
} > "$PROCESS_FULL"

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

assert_contains() { local s=$1 f=$2 m=$3; grep -Fq -- "$s" "$f" && _ok "$m" || _fail "$m"; }
assert_line_count() { local n=$1 f=$2 m=$3; assert_eq "$n" "$(wc -l < "$f" | tr -d ' ')" "$m"; }
assert_exists() { local p=$1 m=$2; [ -e "$p" ] && _ok "$m" || _fail "$m"; }
assert_not_exists() { local p=$1 m=$2; [ ! -e "$p" ] && _ok "$m" || _fail "$m"; }
assert_glob_count() {
  local expected=$1 pattern=$2 m=$3 actual
  # `compgen -G` exits 1 on zero matches; under pipefail that makes it the
  # pipeline's (and this assignment's) exit status even though `wc -l` still
  # correctly captured "0" -- guard with `|| actual=0` so a legitimate
  # zero-match case is recorded as a FAIL by assert_eq, not an aborted script.
  actual=$(compgen -G "$pattern" | wc -l | tr -d ' ') || actual=0
  assert_eq "$expected" "$actual" "$m"
}

# ---- TSV column-aware helpers (role-contract registry, Task 2) -------------
tsv_column() { awk -F '\t' -v name="$2" 'NR==1 { for(i=1;i<=NF;i++) if($i==name){print i; exit} }' "$1"; }
tsv_value() {
  local file=$1 key_column=$2 key=$3 value_column=$4 kc vc
  kc=$(tsv_column "$file" "$key_column"); vc=$(tsv_column "$file" "$value_column")
  awk -F '\t' -v kc="$kc" -v key="$key" -v vc="$vc" '$kc==key { print $vc }' "$file"
}
assert_tsv_key() { local f=$1 c=$2 k=$3; [ -n "$(tsv_value "$f" "$c" "$k" "$c")" ] && _ok "$k exists" || _fail "$k exists"; }
assert_tsv_missing_key() { local f=$1 c=$2 k=$3; [ -z "$(tsv_value "$f" "$c" "$k" "$c")" ] && _ok "$k absent" || _fail "$k absent"; }
assert_tsv_field() { local f=$1 k=$2 c=$3 v=$4; assert_eq "$v" "$(tsv_value "$f" role "$k" "$c")" "$k $c"; }

skip() { printf '  SKIP %s\n' "$*"; exit 77; }

finish() {
  if [ "$_FAILURES" -eq 0 ]; then printf '  -- all assertions passed\n'; exit 0; fi
  printf '  -- %d assertion(s) failed\n' "$_FAILURES"
  exit 1
}

# Source the staged cookbook (a verbatim copy of runtime/cookbook.sh) and
# initialise orchestration variables with throwaway fixture values. Never rely on the cookbook initialising itself: it
# is definitions-only by design, so a top-level ${VAR:?} cannot abort this shell.
load_cookbook() {
  python3 "$_TESTS_DIR/lib/extract.py" cookbook >/dev/null 2>&1 || {
    _fail "cookbook not stageable"; return 1; }
  # shellcheck source=/dev/null
  source "$BUILD/cookbook.sh" || { _fail "cookbook.sh failed to source"; return 1; }
  return 0
}

# Every FIXTURE_ROOT this process has ever minted, cleaned up once at exit --
# init_fixture_env may be called many times in one test file (each mints a
# fresh mktemp -d), and a bare `trap ... EXIT` would overwrite itself on each
# call, silently leaking every FIXTURE_ROOT but the last. Accumulate instead.
_FIXTURE_ROOTS=()
_cleanup_fixture_roots() {
  local d
  for d in "${_FIXTURE_ROOTS[@]}"; do rm -rf "$d"; done
}

# Build a throwaway target repo and feature folder, then initialise.
# Usage: init_fixture_env [outside]   ("outside" puts the feature folder outside the repo)
init_fixture_env() {
  local where="${1:-inside}"
  FIXTURE_ROOT="$(mktemp -d)"
  _FIXTURE_ROOTS+=("$FIXTURE_ROOT")
  # Idempotent: registering the same EXIT trap on every call is harmless
  # (it just re-sets the identical handler), and guarantees the array above
  # is only ever read once, after every call has finished appending to it.
  trap _cleanup_fixture_roots EXIT
  REPO_ROOT="$FIXTURE_ROOT/target"
  mkdir -p "$REPO_ROOT"
  git -C "$REPO_ROOT" init -q
  ( cd "$REPO_ROOT" && : > seed && git add seed \
    && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null
  if [ "$where" = outside ]; then
    FEATURE_FOLDER="$FIXTURE_ROOT/outside-ff"
  else
    # A tracked placeholder under docs/superpowers/specs/ BEFORE the feature
    # folder exists: with nothing else tracked there, git collapses the
    # ENTIRE untracked "docs/" subtree into one "?? docs/" porcelain line
    # (dirty_tree_check's own allow-list only matches an offender that is
    # AT or UNDER an allow-listed path, never an ancestor of one) -- a real
    # repo always has other tracked content under its own docs tree by the
    # time a feature folder is created, so this mirrors that, not a special
    # case invented for the fixture.
    mkdir -p "$REPO_ROOT/docs/superpowers/specs"
    ( cd "$REPO_ROOT" && : > docs/superpowers/specs/.gitkeep \
      && git add docs/superpowers/specs/.gitkeep \
      && git -c user.email=t@t -c user.name=t commit -qm seed-docs ) >/dev/null
    FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/fixture-artifacts"
  fi
  mkdir -p "$FEATURE_FOLDER/transcripts"
  PROCESS_PATH="$PROCESS_DOC"
  init_orchestration_vars
}

# ---- Appendix contract-declaration drift (role appendix vs registry row) ---
# Usage: appendix_contract_value <process_doc> <role> <key>
# Extracts one appendix's declared value for a "- <key>: `value`" contract line.
appendix_contract_value() {
  local doc=$1 role=$2 key=$3 body
  body="$(python3 - "$doc" "$role" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(rf"<!-- BEGIN: {re.escape(sys.argv[2])} -->(.*?)<!-- END: {re.escape(sys.argv[2])} -->", text, re.S)
print(m.group(1) if m else "")
PY
)"
  printf '%s\n' "$body" | "$GREP_BIN" -m1 -E "^-\s*${key}:" \
    | sed -E "s/^-\s*${key}:\s*//; s/^\`//; s/\`\$//"
}

# Compare one appendix's declared value for <key> against the role-contract
# registry's <column> for that role, as normalized (deduped, sorted)
# semicolon-delimited SETS -- declaration ORDER is not part of the contract.
# Prints "<token>:<role> declares [...] but registry says [...]" and returns 1
# on drift; prints nothing and returns 0 when they agree.
#
# This is the ONE comparison both check_02_markers.sh's suite-wide contract
# check and check_06_cookbook.sh's negative-case tampering test drive, so a
# broken or deleted detector fails both -- not just a test that reimplements
# the same comparison in isolation and would keep passing after the real
# detector was deleted.
contract_drift() {
  local doc=$1 roles_tsv=$2 role=$3 key=$4 column=$5 token=$6
  local declared registry_val got want
  declared="$(appendix_contract_value "$doc" "$role" "$key")"
  registry_val="$(tsv_value "$roles_tsv" role "$role" "$column")"
  [ -n "$registry_val" ] || registry_val=none
  got="$(printf '%s' "$declared" | tr ';' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  want="$(printf '%s' "$registry_val" | tr ';' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] && return 0
  printf '%s:%s declares [%s] but registry says [%s]\n' "$token" "$role" "$got" "$want"
  return 1
}
