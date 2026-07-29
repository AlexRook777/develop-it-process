#!/usr/bin/env bash
# Tier 2: probe each pinned model id against its real CLI.
# Billable and network-dependent; runs only via `tests/run.sh --live`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

command -v claude >/dev/null 2>&1 || skip "claude CLI not on PATH"
command -v codex  >/dev/null 2>&1 || skip "codex CLI not on PATH"

load_cookbook || finish
init_fixture_env || { _fail "fixture env setup failed"; finish; }

if probe_models; then _ok "every pinned model id is accepted"
else _fail "at least one pinned model id was rejected (see stderr above)"; fi

finish
