#!/usr/bin/env bash
# Usage: sideeffects.sh <file-to-source>
# Prints one line per top-level command the file executes. Silence means the file
# is definitions-only. Exits 9 if the file cannot be sourced at all.
#
# functrace is REQUIRED: without it the DEBUG trap does not fire for commands
# inside the sourced file. Verified: with functrace the trap reports `umask 000`
# and `touch ...` but NOT `f() { :; }` -- function definitions are invisible to
# it, which is exactly the discrimination this check needs.
target="$1"
# The probe's own statements would also be traced, so every line of this script
# that runs while the trap is armed is in the ignore list. Patterns are
# SINGLE-quoted: $BASH_COMMAND holds the literal text `source "$target"`, not the
# resolved path.
set -o functrace
trap 'case "$BASH_COMMAND" in
        '\''source "$target"'\''|'\''trap - DEBUG'\''|'\''exit 0'\'') ;;
        *) printf "%s\n" "$BASH_COMMAND" ;;
      esac' DEBUG
# shellcheck source=/dev/null
source "$target"
trap - DEBUG
exit 0
