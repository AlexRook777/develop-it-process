#!/usr/bin/env bash
# Runner for develop-it-process checks.
#   ./tests/run.sh          tier 1 only (offline, deterministic, free)
#   ./tests/run.sh --live   tier 1 + tier 2 (live model probe; billable)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

LIVE=no
[ "${1:-}" = "--live" ] && LIVE=yes

pass=0 fail=0 skipped=0 failed_names=()

for check in check_*.sh; do
  is_live=0
  case "$check" in
    check_90_*) is_live=1 ;;
    *)          is_live=0 ;;
  esac
  if [ "$is_live" -eq 1 ] && [ "$LIVE" != yes ]; then
    printf '\n== %s\n  SKIP tier 2; pass --live to run\n' "$check"
    skipped=$((skipped + 1)); continue
  fi
  printf '\n== %s\n' "$check"
  bash "$check"
  case "$?" in
    0)  pass=$((pass + 1)) ;;
    77) skipped=$((skipped + 1)) ;;
    *)  fail=$((fail + 1)); failed_names+=("$check") ;;
  esac
done

printf '\n----------------------------------------\n'
printf 'passed: %d  failed: %d  skipped: %d\n' "$pass" "$fail" "$skipped"
if [ "$skipped" -gt 0 ]; then
  printf 'NOTE: skipped checks are NOT successes.\n'
fi
if [ "$fail" -gt 0 ]; then
  printf 'failed: %s\n' "${failed_names[*]}"
  exit 1
fi
exit 0
