# develop-it-process

`develop-it-process.md` is a single self-contained orchestration prompt. An
orchestrating agent reads it and drives `claude` and `codex` CLI subprocesses
through a phased spec -> plan -> implement -> review pipeline. The document is
the single source of truth: there is no framework code and no runtime. The
shell helpers the orchestrator calls (`render_prompt`, `role_model`,
`dirty_tree_check`, and the rest) live inside the document itself, in fenced
`bash` blocks, and are extracted into real files only at test time.

## The pipeline

The phases run in this order:

- **Phase -1 — Preflight.** CLI canary (are `claude`/`codex`/`jq`/`git`/... on
  PATH), Superpowers skill probe, and a model probe that verifies every pinned
  model id is accepted before any billable work starts.
- **Phase 2 — Context discovery.** A read-only subagent surveys the repo and
  available skills.
- **Phase 3 — Spec review gate.**
- **Phase 4 — Plan writing.**
- **Phase 5 — Plan review gate.**
- **Phase 6 — Implementation**, by a single supervising subagent.
- **Phase 7 — Code review gate.**
- **Phase 8 — All tests**, a test-run/fix loop.
- **Phase 9 — Git finalization.**
- **Phase 10 — Final readiness report.**

Every review gate (Phases 3, 5, 7) is **cross-vendor**: a Claude reviewer and a
Codex reviewer run independently in parallel, and the gate's decision is driven
by their severity counts (blockers/majors/minors), not by a bare pass/fail
string. Each gate is severity-gated and iterates — re-dispatching a fixer
subagent and re-reviewing — until it passes or hits its iteration cap (10).

## How to use it

This repository orchestrates *other* projects, so its own root and the target
project's root are never the same path. Set both explicitly, plus the feature
folder for this run:

```bash
export PROCESS_PATH="$PWD/develop-it-process.md"
export REPO_ROOT="/path/to/the/target/project"
export FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/<date>-<slug>-artifacts"
```

Then hand `develop-it-process.md` to an orchestrating agent (a Claude Code
session) and let it drive the phases. `RUNBOOK.md` is the step-by-step version of
this — environment checks, the exact launch command, the kickoff prompt, resume,
and how to override a cap for one run. Each phase runs as one bash invocation;
per-phase STATUS files are the branch points the orchestrator reads between
phases. Some roles (the plan writer, the implementer, and any re-dispatch of
either) have a timeout that exceeds a single Bash tool call — those are issued
with `run_in_background: true` so the harness keeps them running across turns.

## Models

Model, reasoning effort, and timeout are pinned per role in the Models table in
`develop-it-process.md`, and implemented by the `role_model` / `role_effort` /
`role_timeout` helpers. `tests/check_04_table.sh` asserts the table and the
functions agree for every row, so they cannot drift apart. There is no
fallback: a rejected model id halts the run rather than silently substituting
another model.

## Artifacts

A run leaves everything under the per-feature artifacts folder
(`docs/superpowers/specs/<date>-<slug>-artifacts/`): `RUN_LOG.md` is the
durable, append-only event log used for resume and auditing; each phase has a
numbered subfolder holding its STATUS files and findings; and
`final-readiness-report.md` is the human-facing summary written at Phase 10,
covering reviewer verdicts, implementation and verification results, the git
result, and any residual minor findings.

## Tests

```bash
./tests/run.sh          # tier 1: offline, deterministic, free
./tests/run.sh --live   # adds the live model probe (billable)
```

Exit codes follow the standard convention: 0 PASS, 1 FAIL, 77 SKIP. A SKIP is
never counted as a pass — `run.sh` reports skipped checks separately from
passing ones. `shellcheck` is a test-time prerequisite (it lints the extracted
cookbook helpers); without it, `check_01_lint.sh` still runs its syntax checks
and reports SKIP rather than a false PASS.

## Requirements

bash 5.3+, python3, jq, git, and the `claude` CLI. The `codex` CLI is optional:
its absence degrades review gates to Claude-only through an explicit
user-consent path (or halts at the initial preflight, where a missing Codex
binary is treated as an environment defect to fix rather than a mode to
silently work around) — it never degrades without being recorded.
