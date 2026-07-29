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

finish
