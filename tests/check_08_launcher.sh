#!/usr/bin/env bash
# Check 8: develop-it.sh derives every run parameter from the one design-file
# argument, runs the pre-launch checks, and hands the right argv, environment and
# prompt to an INTERACTIVE claude.
#
# The launcher ends in `exec claude`, so there is no dry-run mode to assert
# against — instead tests/fakebin goes first on PATH and FAKE_ARGV_LOG /
# FAKE_ENV_LOG capture what actually reached the CLI. That exercises the real
# launch path end to end and costs nothing.
#
# The launcher deliberately carries no process rules: resume detection, the
# branch name and codex consent all belong to the document, so there is nothing
# about them to assert here.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

LAUNCHER="$REPO_TOP/develop-it.sh"

# When this variable is already set we are running inside the suite the launcher
# itself started. The pre-launch-gate assertions below re-enter the launcher, so
# they run at the top level only — otherwise the recursion never bottoms out.
NESTED="${DEVELOP_IT_SKIP_TESTS:-}"

[ -x "$LAUNCHER" ] || { _fail "develop-it.sh is missing or not executable at repo root"; finish; }
_ok "develop-it.sh is at the repo root and executable"

if command -v shellcheck >/dev/null 2>&1; then
  if sc_out="$(shellcheck "$LAUNCHER" 2>&1)"; then _ok "shellcheck is clean"
  else _fail "shellcheck reported issues"; printf '%s\n' "$sc_out" | head -20; fi
else
  note "shellcheck not installed; skipping that assertion only"
fi

# --- a throwaway target repo with a conforming spec --------------------------
FIX="$(mktemp -d)"
GATE_PROBE="$REPO_TOP/tests/check_88_gatefail_probe.sh"
trap 'rm -rf "$FIX"; rm -f "$GATE_PROBE"' EXIT
SPECS="$FIX/proj/docs/superpowers/specs"
mkdir -p "$SPECS"
git -C "$FIX/proj" init -q
SPEC="$SPECS/2026-08-01-widget-design.md"
printf '# design\n' > "$SPEC"
git -C "$FIX/proj" add -A
git -C "$FIX/proj" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null

# Run the launcher with the fake claude first on PATH; capture argv, env, prompt.
# The pre-launch checks are skipped for these: they are asserted on their own
# below, and re-running the whole suite per launch would cost minutes.
ARGV_LOG="$FIX/argv.log"
ENV_LOG="$FIX/env.log"
launch() {
  : > "$ARGV_LOG"
  : > "$ENV_LOG"
  # </dev/null is required, not cosmetic: the launcher ends in `exec claude`
  # and the fake claude drains stdin, so inheriting a caller's stdin that never
  # reaches EOF (a pty, or any harness keeping the pipe open) hangs this check
  # indefinitely. The pty assertion below guards its own call site the same
  # way; this one was simply missed.
  PATH="$REPO_TOP/tests/fakebin:$PATH" FAKE_ARGV_LOG="$ARGV_LOG" FAKE_ENV_LOG="$ENV_LOG" \
    DEVELOP_IT_SKIP_TESTS=1 "$LAUNCHER" "$@" >/dev/null 2>"$FIX/err.txt" </dev/null
}

launch "$SPEC"
rc=$?
assert_rc 0 $rc "the launcher runs to exec on a conforming spec"
[ -s "$ARGV_LOG" ] || { _fail "the launcher never invoked claude"; cat "$FIX/err.txt"; finish; }
argv="$(cat "$ARGV_LOG")"

# --- argv: interactive, bypassed, target repo reachable ----------------------
case "$argv" in
  *" -p "*|*" --print "*) _fail "launcher used print mode; the TUI would never appear" ;;
  *) _ok "the prompt is positional, not -p (interactive TUI)" ;;
esac
case "$argv" in
  *--dangerously-skip-permissions*) _ok "permissions are bypassed for an unattended run" ;;
  *) _fail "--dangerously-skip-permissions missing from argv" ;;
esac
case "$argv" in
  *"--add-dir $FIX/proj"*) _ok "the target repo is passed via --add-dir" ;;
  *) _fail "--add-dir REPO_ROOT missing from argv" ;;
esac
case "$argv" in
  *"--model opus"*) _ok "the orchestrator runs on opus" ;;
  *) _fail "--model opus missing from argv" ;;
esac

# --- the process document itself is the prompt -------------------------------
case "$argv" in
  *"--append-system-prompt-file $REPO_TOP/develop-it-prompt.md"*)
    _ok "the process document is passed verbatim as the system prompt" ;;
  *) _fail "--append-system-prompt-file PROCESS_PATH missing from argv" ;;
esac
# The launcher must author no prompt text of its own: the positional argument is
# a bare trigger, and everything the orchestrator is told comes from the
# document. Anything longer is a second copy of the document's rules.
words_after_flags="$(printf '%s' "$argv" | tr ' ' '\n' | tail -1)"
argv_lines="$(printf '%s\n' "$argv" | wc -l)"
if [ "$argv_lines" -eq 1 ] && [ "${#words_after_flags}" -le 12 ]; then
  _ok "the positional prompt is a bare trigger ('$words_after_flags')"
else
  _fail "the launcher is authoring prompt text; rules belong in the document"
  printf '%s\n' "$argv" | head -5
fi

# --- the derived parameters reach claude through the environment -------------
assert_present "^PROCESS_PATH=$REPO_TOP/develop-it-prompt\.md$" "$ENV_LOG" \
  "PROCESS_PATH is exported into claude's environment"
assert_present "^REPO_ROOT=$FIX/proj$" "$ENV_LOG" \
  "REPO_ROOT derived from the spec's git toplevel"
assert_present "^SPEC_PATH=$SPEC$" "$ENV_LOG" \
  "SPEC_PATH is the absolute spec path"
assert_present "^FEATURE_FOLDER=$SPECS/2026-08-01-widget-artifacts$" "$ENV_LOG" \
  "FEATURE_FOLDER derived by swapping -design.md for -artifacts"
# An inherited value would silently pre-answer the consent prompt Phase 1 asks.
if "$GREP_BIN" -q '^CODEX_CONSENT=' "$ENV_LOG"; then
  _fail "CODEX_CONSENT is exported, pre-answering the consent prompt"
else
  _ok "CODEX_CONSENT is left unset so the orchestrator asks"
fi

# A relative path must resolve to the same absolute parameters.
( cd "$SPECS" && launch ./2026-08-01-widget-design.md )
assert_present "^SPEC_PATH=$SPEC$" "$ENV_LOG" \
  "a relative spec path resolves to the same absolute path"

# --- refusals: derivation preconditions, not duplicated process gates --------
refuse() {
  : > "$ARGV_LOG"
  PATH="$REPO_TOP/tests/fakebin:$PATH" FAKE_ARGV_LOG="$ARGV_LOG" \
    DEVELOP_IT_SKIP_TESTS=1 "$LAUNCHER" "$@" >/dev/null 2>"$FIX/err.txt"
  local rc=$?
  REFUSE_ERR="$(cat "$FIX/err.txt")"
  [ ! -s "$ARGV_LOG" ] || _fail "claude was invoked despite a refusal: $*"
  return $rc
}

printf 'x\n' > "$FIX/proj/notes.md"
refuse "$FIX/proj/notes.md"; rc=$?
assert_rc 1 $rc "a spec not ending in -design.md is refused"
case "$REFUSE_ERR" in
  *-design.md*) _ok "the naming refusal names the required suffix" ;;
  *) _fail "naming refusal is unhelpful: $REFUSE_ERR" ;;
esac

refuse "$FIX/proj/nope-design.md"; rc=$?
assert_rc 1 $rc "a missing spec is refused"

self_spec="$REPO_TOP/2026-08-01-launcher-selftest-design.md"
printf '# x\n' > "$self_spec"
refuse "$self_spec"; rc=$?
rm -f "$self_spec"
assert_rc 1 $rc "a spec inside the process repo is refused"
case "$REFUSE_ERR" in
  *"different repositories"*) _ok "the same-repo refusal explains why" ;;
  *) _fail "same-repo refusal is unhelpful: $REFUSE_ERR" ;;
esac

refuse; rc=$?
assert_rc 1 $rc "no argument prints usage and exits non-zero"

# --- the launcher must NOT duplicate the process document's own gates --------
# Phase 1 Step 1.0 owns the canary, the dirty-tree gate, and the gitignore
# guard. A second copy here would be a drift risk, so a dirty target tree must
# reach the orchestrator rather than being blocked at launch.
printf 'junk\n' > "$FIX/proj/unrelated.py"
launch "$SPEC"; rc=$?
assert_rc 0 $rc "a dirty target tree does not block the launch (Phase 1 owns that gate)"
rm -f "$FIX/proj/unrelated.py"

# --- the launch must not block on an interactive terminal --------------------
# develop-it.sh is run by hand and runs this suite as its pre-launch gate, so
# every process it starts inherits the operator's TTY on stdin. A stub that
# drains stdin blocks there forever: the gate never returns, and the operator
# sees the checks stop mid-suite with no claude and no error. Only a pty
# reproduces it — with a pipe or /dev/null on stdin the read hits EOF at once.
if command -v script >/dev/null 2>&1; then
  TTY_PROBE="$FIX/tty-probe.sh"
  cat > "$TTY_PROBE" <<PROBE
#!/usr/bin/env bash
PATH="$REPO_TOP/tests/fakebin:\$PATH" FAKE_ARGV_LOG="$FIX/tty-argv.log" \\
  DEVELOP_IT_SKIP_TESTS=1 "$LAUNCHER" "$SPEC" >/dev/null 2>&1
PROBE
  chmod +x "$TTY_PROBE"
  : > "$FIX/tty-argv.log"
  # script gives the launcher a real pty; the sleep keeps that pty from seeing
  # EOF, which is what a waiting operator's terminal looks like.
  timeout 20 script -qec "$TTY_PROBE" /dev/null 0< <(sleep 22) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    _fail "the launch hangs when stdin is a terminal; the pre-launch gate never returns"
  else
    _ok "the launch completes with an interactive terminal on stdin"
  fi
  [ -s "$FIX/tty-argv.log" ] && _ok "claude was still reached under a pty" \
    || _fail "the pty launch never reached claude"
else
  note "util-linux script not installed; skipping the pty assertion only"
fi

# --- the pre-launch check gate is real ---------------------------------------
# Drop a failing check into the suite the launcher runs, then launch WITHOUT the
# skip flag: the launcher must refuse and must never reach claude. The launcher
# exports DEVELOP_IT_SKIP_TESTS before running the suite, so the copy of this
# check inside that nested run takes the NESTED branch and stops the recursion.
if [ -n "$NESTED" ]; then
  note "nested inside a launcher-run suite; skipping the pre-launch-gate assertions"
else
  printf '#!/usr/bin/env bash\nexit 1\n' > "$GATE_PROBE"
  chmod +x "$GATE_PROBE"
  : > "$ARGV_LOG"
  # env -u: this block's own comment says "launch WITHOUT the skip flag", but
  # an inherited DEVELOP_IT_SKIP_TESTS made the launcher skip its checks, so
  # the assertion below tested nothing and the launch reached the fake claude.
  PATH="$REPO_TOP/tests/fakebin:$PATH" FAKE_ARGV_LOG="$ARGV_LOG" \
    env -u DEVELOP_IT_SKIP_TESTS "$LAUNCHER" "$SPEC" >/dev/null 2>"$FIX/err.txt" </dev/null
  rc=$?
  rm -f "$GATE_PROBE"
  assert_rc 1 $rc "a failing check blocks the launch"
  [ ! -s "$ARGV_LOG" ] && _ok "claude is never reached when the checks fail" \
    || _fail "claude was launched despite failing checks"
  case "$(cat "$FIX/err.txt")" in
    *"pre-launch checks failed"*) _ok "the refusal says which gate stopped the run" ;;
    *) _fail "the pre-launch refusal is unhelpful: $(tail -1 "$FIX/err.txt")" ;;
  esac
fi

finish
