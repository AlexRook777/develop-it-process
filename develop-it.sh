#!/usr/bin/env bash
# develop-it.sh — prepare a terminal session and hand it to the orchestrator.
#
#   ./develop-it.sh /path/to/<YYYY-MM-DD>-<slug>-design.md
#
# Three things happen here and nothing else:
#   1. the run parameters are derived from that one path and exported,
#   2. the process repo's own checks are run as part of preparing the env,
#   3. claude is exec'd, permissions bypassed, with develop-it-prompt.md itself
#      as the orchestrator's prompt.
#
# This script writes no prompt of its own — not a summary, not a kickoff, not a
# restatement of any rule. develop-it-prompt.md is the tuned prompt and is
# passed verbatim; the only thing this script knows that the document cannot is
# the per-run values, and those travel in the environment.
set -uo pipefail

die() { printf 'develop-it: %s\n' "$1" >&2; exit 1; }

if [ $# -ne 1 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
  printf 'Usage: ./develop-it.sh <path-to-design-file>\n\n' >&2
  printf 'Launches the orchestrator as an interactive Claude Code session.\n' >&2
  printf 'The design file must end in -design.md and live in the target repo.\n' >&2
  printf 'Set DEVELOP_IT_SKIP_TESTS=1 to skip the pre-launch checks.\n' >&2
  exit 1
fi

# This repo (the process repo). realpath first, so a symlink onto PATH still
# resolves to the repository rather than the symlink's directory.
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || die "cannot resolve own path"
PROCESS_REPO_ROOT="$(git -C "$(dirname "$SELF")" rev-parse --show-toplevel 2>/dev/null)" \
  || die "this script must live inside the develop-it-process repository"
PROCESS_PATH="$PROCESS_REPO_ROOT/develop-it-prompt.md"
[ -f "$PROCESS_PATH" ] || die "process file not found at $PROCESS_PATH"
command -v claude >/dev/null 2>&1 || die "the 'claude' CLI is not on PATH"

# The run parameters, all derived from the one argument.
[ -f "$1" ] || die "no such file: $1"
SPEC_PATH="$(realpath "$1")" || die "cannot resolve $1"
case "$SPEC_PATH" in
  *-design.md) ;;
  *) die "spec filename must end in '-design.md' (got $(basename "$SPEC_PATH"))" ;;
esac
FEATURE_FOLDER="${SPEC_PATH%-design.md}-artifacts"
REPO_ROOT="$(git -C "$(dirname "$SPEC_PATH")" rev-parse --show-toplevel 2>/dev/null)" \
  || die "the spec is not inside a git repository: $SPEC_PATH"
[ "$REPO_ROOT" != "$PROCESS_REPO_ROOT" ] \
  || die "the spec and the process file must be in different repositories: $REPO_ROOT"

# Preparing the environment includes proving the process file set (the
# document plus the runtime/ sources) still passes its own checks — a broken
# cookbook helper fails here rather than mid-run.
# Exported before the suite runs: tests/check_08_launcher.sh invokes this script,
# and without the flag that check would re-enter this step forever.
if [ -z "${DEVELOP_IT_SKIP_TESTS:-}" ]; then
  export DEVELOP_IT_SKIP_TESTS=1
  "$PROCESS_REPO_ROOT/tests/run.sh" >&2 \
    || die "pre-launch checks failed; fix them, or re-run with DEVELOP_IT_SKIP_TESTS=1"
fi

# The run parameters travel in the environment, which is the only channel this
# script needs: every bash block the orchestrator runs inherits them, and the
# document's own init_orchestration_vars reads them from there. That is why no
# prompt text here has to name them.
export PROCESS_PATH REPO_ROOT SPEC_PATH FEATURE_FOLDER

# Run from the process repo, never the target: the target's own CLAUDE.md would
# otherwise sit in front of the orchestrator's instruction set. --add-dir is how
# it reaches the target.
cd "$PROCESS_REPO_ROOT" || die "cannot cd to $PROCESS_REPO_ROOT"

# The document is the prompt, verbatim (the shell helpers it indexes live in
# runtime/, sourced by each phase shell — they are not part of the prompt).
# It goes in as a system-prompt file, not as the positional argument: at
# hundreds of KB it is well past the kernel's 128 KB ceiling on a single argv
# element, and the system prompt is also the one place a multi-hour run cannot
# lose it to context compaction. The positional argument is only the trigger
# that submits the first turn — the same as typing "Begin" into the TUI
# yourself.
#
# exec, and no -p: this hands the terminal to an interactive session with the
# first turn already submitted. -p would print once and exit.
exec claude \
  --model opus \
  --add-dir "$REPO_ROOT" \
  --dangerously-skip-permissions \
  --append-system-prompt-file "$PROCESS_PATH" \
  Begin.
