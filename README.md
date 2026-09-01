# develop-it-process

`develop-it-prompt.md` is the orchestration prompt. An orchestrating agent
reads it and drives `claude` and `codex` CLI subprocesses through a phased
spec -> plan -> implement -> review pipeline. **This repository — not the
lone document — is the source of truth**, and it splits cleanly in two:

- `develop-it-prompt.md` holds everything the orchestrator reasons from —
  the phase procedures, the role-contract/policy/event registries (as
  Markdown tables it alone authors), the role appendices, and a compact
  per-section FUNCTION INDEX of every shell helper it may call.
- `runtime/` holds the executable logic those index entries name:
  `runtime/cookbook.sh` (every shell helper — `render_prompt`, `role_model`,
  `dirty_tree_check`, and the rest — definitions-only, directly authored and
  reviewed here) and `runtime/publish-status` (the STATUS publisher program).

Every phase shell `source`s `runtime/cookbook.sh`, and its
`bootstrap_runtime` materializes a per-run copy — verbatim `runtime/` files
plus the registries extracted from the document's tables — into
`$FEATURE_FOLDER/.orchestration/runtime/`, covered by a `manifest.sha256`
keyed to the whole process file set (document + `runtime/` sources), so a
mid-run edit to any of them invalidates the run's materialized runtime
rather than silently drifting. `./tests/run.sh` stages the same files into
`tests/.build/` to unit-test them offline; both copies are disposable
derivatives, never committed (see "Recovery and resume" below).

## The pipeline

This is schema v2: every run's `RUN_LOG.md`, STATUS files, checkpoints, and
event records follow the reviewed schema-v2 contracts below. It applies only
to newly created runs — a historical feature folder written by an older
version of this prompt is left exactly as it is; there is no compatibility
reader or migration path for it (see "Artifacts" below).

The phases run in this order:

- **Phase −1 (folder `1-preflight/`) — Preflight.** Zero-token gates: local
  CLI canary (are `claude`/`codex`/`jq`/`git`/... on PATH), the target repo's
  dirty-tree check, process-identity/gitignore validation, generated-runtime
  materialization and verification, then a Superpowers skill probe and a model
  probe per vendor that verifies every pinned model id is accepted before any
  billable work starts. A missing/unavailable Codex at this phase HALTs
  (Mode 0) or degrades only after explicit recorded user consent (Modes 1–5)
  — it never silently falls back.
- **Phase 2 — Context discovery.** A read-only subagent surveys the repo and
  available skills.
- **Phase 3 — Spec review gate.**
- **Phase 4 — Plan writing.**
- **Phase 5 — Plan review gate.**
- **Phase 6 — Implementation**, by a single supervising subagent, with
  resumable checkpoints (see "Recovery and resume" below).
- **Phase 7 — Code review gate.**
- **Phase 8 — All tests**, a test-run/fix loop.
- **Phase 9 — Documentation and handoff.** Writes `uat.md`,
  `planned-vs-realized.md`, and `documentation-validation.md`, all reviewed
  against a structural contract before the run is allowed to proceed.
- **Phase 10 — Local git finalization.** A direct orchestrator operation —
  no subagent is dispatched. It commits locally at most once, under the
  orchestrator's own write lease, and **never pushes, opens a pull request,
  merges, or touches a remote**; `push_performed` is recorded `no` on every
  outcome. Pushing, merging, and opening a PR are separately scoped owner
  actions outside this process run — see `RUNBOOK.md`'s "Finalization
  BLOCKED|FAILED" operator check.
- **Phase 11 — Readiness and completion.** A deterministic reconciliation
  audit runs first (no vendor call), then `readiness-writer` composes
  `final-readiness-report.md`.

Every review gate (Phases 3, 5, 7) is **cross-vendor**: a Claude reviewer and a
Codex reviewer run independently in parallel, and the gate's decision is driven
by their severity counts (blockers/majors/minors), not by a bare pass/fail
string. Each gate is severity-gated and iterates — re-dispatching a fixer
subagent and re-reviewing — until it passes or hits its `review_iteration_cap`
(10). A fixer's own claim of `DONE` is never accepted as final: every fix
round is re-reviewed by a fresh reviewer dispatch before the gate can pass, at
every iteration including the cap — there is no "final fix pass" that skips
re-review.

### Attempt identity and STATUS

Every dispatched subprocess writes exactly one attempt-scoped STATUS file —
`<phase-dir>/<iteration>/attempts/<dispatch-id>/STATUS.md` — via a generated
publisher program that is the sole sanctioned writer; no role appendix writes
or renames a STATUS file itself. `dispatch_id` has the fixed shape
`p<phase-token>-i<NN>-<role>-a<NN>`, unique per attempt, so a retried or
resumed attempt never collides with or silently overwrites a prior one's
evidence. The parent orchestrator is `RUN_LOG.md`'s sole writer; subprocesses
never touch it directly — they return results through their own attempt-scoped
files, which the orchestrator reads and durably records.

### Recovery and resume

A failed or interrupted attempt is classified against a fixed twelve-row
recovery matrix (`RM01`–`RM12` in `develop-it-prompt.md`) keyed on failure
classification and repository mutation state, so retries are deterministic
and bounded — never open-ended. A role with `checkpoint_kind != none` records
durable progress as it works — this is most roles that dispatch in Phases 3
through 7 and 9, not just the implementer: both spec/plan/code reviewers
(every vendor), the spec/plan/implementation fixers, the plan-writer, the
implementer (and its `impl-worker` children), and documentation-writer. A
resumed attempt continues from its own last checkpoint rather than
restarting, up to the `continuation_cap` (3). Anything the matrix classifies
as requiring a human decision (an ambiguous lease, dirty-uncheckpointed state)
HALTs with the exact durable paths to inspect — it never guesses. See
`RUNBOOK.md` §Step 8's "Operator checklist" for the exact procedure for each
recovery case.

## How to use it

The short version — hand `./develop-it.sh` a design file and it does the rest:

```bash
./develop-it.sh /path/to/project/docs/superpowers/specs/<date>-<slug>-design.md
```

One argument, no flags. It derives every run parameter from that path and exports
them, runs `./tests/run.sh` as part of preparing the environment, and hands the
terminal to an interactive Claude Code session whose system prompt is
`develop-it-prompt.md` itself, passed verbatim. The launcher writes no prompt of
its own — every rule, including resume-vs-fresh, the branch, and the
codex-consent question, is the document's. See `RUNBOOK.md` §Quick start.

The long version, and what the launcher is doing under the hood:

This repository orchestrates *other* projects, so its own root and the target
project's root are never the same path. Set both explicitly, plus the feature
folder for this run:

```bash
export PROCESS_PATH="$PWD/develop-it-prompt.md"
export REPO_ROOT="/path/to/the/target/project"
export FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/<date>-<slug>-artifacts"
```

Then hand `develop-it-prompt.md` to an orchestrating agent (a Claude Code
session) and let it drive the phases. `RUNBOOK.md` is the step-by-step version of
this — environment checks, the exact launch command, the kickoff prompt, resume,
and how to override a cap for one run. Each phase runs as one bash invocation;
per-phase STATUS files are the branch points the orchestrator reads between
phases. Some roles (the plan writer, the implementer, and any re-dispatch of
either) have a timeout that exceeds a single Bash tool call — those are issued
with `run_in_background: true` so the harness keeps them running across turns.

## Models

Model, reasoning effort, and timeout are pinned per role in the Models table in
`develop-it-prompt.md`, and implemented by the `role_model` / `role_effort` /
`role_timeout` helpers. `tests/check_04_table.sh` asserts the table and the
functions agree for every row, so they cannot drift apart. There is no
fallback: a rejected model id halts the run rather than silently substituting
another model.

## Artifacts

A run leaves everything under the per-feature artifacts folder
(`docs/superpowers/specs/<date>-<slug>-artifacts/`): `RUN_LOG.md` is the
durable, append-only event log used for resume and auditing; each phase has a
numbered subfolder holding its own attempt-scoped STATUS files and findings;
and `final-readiness-report.md` is the human-facing summary written at
Phase 11, covering preflight/reviewer verdicts, implementation and
verification results, documentation/UAT status, the local git result, the
reconciliation audit, and any residual minor findings.

**Existing Prism artifacts are unchanged by this work.** Schema v2 applies
only to feature folders a run creates from now on. A feature folder written
by an older version of this prompt — including every one already under
`/home/oleks/repos/prism/docs/superpowers/specs/`, and that project's own
spec/plan/review artifact folders more generally — is left exactly as it is:
no task in this plan reads, edits, migrates, backfills, or deletes anything
there, and this process provides no compatibility reader for a schema-v1
`RUN_LOG.md` (an unrecognized or v1 log is a HALT, `RUN_LOG_SCHEMA_V1_OR_UNKNOWN`
— never a silent upgrade).

## Tests

```bash
./tests/run.sh          # tier 1: offline, deterministic, free
./tests/run.sh --live   # adds the live model probe (billable)
```

Exit codes follow the standard convention: 0 PASS, 1 FAIL, 77 SKIP. A SKIP is
never counted as a pass — `run.sh` reports skipped checks separately from
passing ones. `shellcheck` is a test-time prerequisite (it lints
`runtime/cookbook.sh`); without it, `check_01_lint.sh` still runs its syntax
checks and reports SKIP rather than a false PASS.

## Requirements

bash 5.3+, python3, jq, git, and the `claude` CLI. The `codex` CLI is optional:
its absence degrades review gates to Claude-only through an explicit
user-consent path (or halts at the initial preflight, where a missing Codex
binary is treated as an environment defect to fix rather than a mode to
silently work around) — it never degrades without being recorded.
