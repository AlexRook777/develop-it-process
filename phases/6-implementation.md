<!-- PACK: phases/6-implementation.md — sole normative source for Phase 6 (implementation); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 6 — Implementation (delegated, single supervising subagent)

**Plan acceptance gate (spec §19.1/§20.5-§20.6), before ANY other Phase 6 work — even the zero-cost Codex outcome scan below.** Call `plan_ready_for_implementation` (cookbook). Implementation may start only from a plan revision whose latest plan-review verdict is accepted and whose open blocking finding count is zero; on failure, surface the printed reason and HALT — do not proceed to Step 6.−1. Once this gate passes and Step 6.0's `capture_implementation_baseline` durably records `event=IMPLEMENTATION_BASELINE`, the plan's pre-implementation review window is closed for the remainder of this run (`plan_review_window_closed` reads that same event; see Phase 5's review-window check, `phases/5-plan-review.md`).

### Step 6.−1 — Per-phase preflight

Before Step 6.0 (the gate's first work dispatch is the implementer dispatch in Step 6.1; this preflight precedes the baseline capture in Step 6.0 so the user is warned upfront if Claude is gone before sinking time into the long implementer run):

**P09: Phase 6 no longer dispatches `preflight-codex` at all.** The prior design ran the full paid probe here even though "Codex is not dispatched downstream in Phase 6" made its verdict "informational only — the probe runs only to give the user early warning of a vendor outage." A full paid subprocess dispatch buying nothing but a warning line is exactly the cost this step now avoids: the same warning comes free from `RUN_LOG.md`, which already durably records Phase 3's and Phase 5's own codex preflight outcomes.

1. `mkdir -p <feature-folder>/6-implementation/preflight`.
2. Dispatch `preflight-claude` only, via `dispatch_attempt 6 00 preflight-claude`. There is no codex branch here, and no `codex_disabled_by_user` check — Phase 6 dispatches no codex subprocess regardless of that run-scoped flag.
3. After the probe returns, copy its STATUS file from its real attempt-scoped path to the phase-local readable alias:

   <!-- lint: snippet -->
   ```bash
   logical="p06-i00-preflight-claude"
   latest="$(_latest_attempt_id "$logical" 2>/dev/null)" || latest=""
   if [ -n "$latest" ]; then
     src="$(role_attempt_dir preflight-claude "$latest")/STATUS.md"
     if [ -f "$src" ]; then
       cp "$src" "$FEATURE_FOLDER/6-implementation/preflight/claude-check-status.md"
     fi
   fi
   # `cp`, never `mv` -- same durable-record rationale as every other
   # per-phase preflight alias copy in this process.
   ```

   There is no `codex-check-status.md` alias for Phase 6 — do not create one.

4. `dispatch_attempt` already appended the claude probe's own RUN_LOG dispatch entry (`phase: 6`, `phase_name: implementation`, `iteration: 00`, `role: preflight-claude`, `vendor: claude`, `status_path:` its REAL attempt-scoped path) — read the verdict from the copied alias `6-implementation/preflight/claude-check-status.md`.
5. Branch on the claude verdict:
   - **Claude probe fails (any mode):** HALT unconditionally (same rule as every gate). No user prompt; claude is required for every phase.
   - **Claude probe reports `verdict=MISSING_SKILLS`:** see the missing-skill re-probe branch below (spec §16.3) — do NOT fall through to step 6 until that branch resolves.
   - **Claude probe `READY`:** continue to step 6.
6. **Missing-skill re-probe (spec §16.3), claude only — Phase 6 dispatches no codex probe to apply this to.** If the claude STATUS reports `verdict=MISSING_SKILLS`, do NOT immediately HALT. Call `skills_reprobe_needed` (cookbook) with the same three conditions Phase 1 Step 1.1 step 5 uses: (a) `yes` iff an earlier phase in THIS run already recorded `READY` for claude; (b) `yes` iff a deterministic filesystem check shows the named skill directory/`SKILL.md` actually exists under a checked plugin root; (c) `yes` iff the STATUS file (or its sibling `.tmp.*`) shows the attempt reached publication but lost its final STATUS. On `true`, re-dispatch `preflight-claude` once more (same `dispatch_attempt` mechanism, a fresh attempt) and use the re-probe's verdict in place of the first. A second consecutive `MISSING_SKILLS` (from the re-probe, or when re-probe was not indicated) is accepted as real: print which skills are missing (`required_skills_missing` plus `x_plugin_roots_checked`) plus the Phase 1 install hint, and HALT — claude is required for every phase, exactly as at Phase 1. Both probe attempts stay in `RUN_LOG.md` with their raw outputs so a flake remains auditable.
7. **Zero-cost codex early warning (no dispatch, informational only, never blocks).** Call `latest_codex_outcome 5` (cookbook); if it prints `none`, call `latest_codex_outcome 3` instead. Surface a one-line advisory to the dispatch event stream from whichever call returned something other than `none`: `Codex last known status (phase <N>): <READY | UNAVAILABLE mode=<M> | SKIPPED>`, or `Codex last known status: no prior phase recorded it` if both calls print `none`. This writes NOTHING to `RUN_LOG.md` — no new event, no STATUS file, no `(phase=6, vendor=codex)` verdict — and never prompts, blocks, or HALTs.
8. Proceed to Step 6.0.

The "File policy for non-READY paths" rules from Step 1.0 apply, restricted to the claude probe — Phase 6 has no codex probe for that policy to describe.

### Step 6.0 — Capture implementation baseline

Before dispatching the implementer, record the repository baseline so Phase 7 reviewers and the git finalizer have a stable diff scope. Read-only git is allowed for you; you are NOT making commits here.

The order of operations matters: the working-tree cleanliness check runs BEFORE the `IMPLEMENTATION_BASELINE` event is written, so a dirty halt never leaves a stale baseline in `RUN_LOG.md`.

Cookbook functions (authored in `runtime/cookbook.sh`):

- `capture_implementation_baseline` — Step 6.0: record IMPLEMENTATION_BASE_SHA (plus the pre-implementation allow-list state) durably in RUN_LOG.md before Phase 6 dispatches.

Call `capture_implementation_baseline` here. On a non-zero return, HALT and surface the offender list — already printed to stderr by `dirty_tree_check` — to the user. Pre-existing uncommitted changes outside the implementation slice would pollute the Phase 6 diff scope and the Phase 10 staging scope (the finalizer cannot reliably distinguish "implementer-produced uncommitted changes" from "user's pre-existing uncommitted changes" without external knowledge). The user must resolve before proceeding by committing or stashing. The orchestrator does NOT auto-stash and does NOT accept "proceed anyway" — re-run this step after the working tree is clean of out-of-scope changes.

Files INSIDE `$FEATURE_FOLDER` (RUN_LOG, STATUS files, transcripts) are expected to be untracked. They are excluded from the dirty check via `dirty_tree_check`'s allow-list. If `.gitignore` does not yet ignore the `*-artifacts/` pattern, the user was warned in Phase 1; the runtime exclusion above keeps the run unblocked regardless.

The `event=IMPLEMENTATION_BASELINE` entry is a **multi-line block** matching the RUN_LOG grammar (a `--- <timestamp>  event=...` header line followed by `key: value` fields and a trailing blank line) — not the previous single-line form, which the summarizers and the readiness writer could not parse. On a dirty-tree halt, only the advisory `event=IMPLEMENTATION_BASELINE_BLOCKED` block is written (see schema above) — the consumable `event=IMPLEMENTATION_BASELINE` event is never written on that path, so a blocked attempt can never be mistaken for a consumable baseline. Downstream consumers must read the LATEST `event=IMPLEMENTATION_BASELINE` entry in `RUN_LOG.md` (in case a prior failed/aborted run left one or the user resumes), ignoring any `IMPLEMENTATION_BASELINE_BLOCKED` entries.

If `IMPLEMENTATION_BASE_SHA=non-git`, Phase 10 will record `outcome=BLOCKED` (reason=not-a-git-repo) and perform no commit; the code reviewers inspect the working tree directly. Pass `non-git` as the input value to downstream subagents that expect this variable. The baseline event is still written with `base_sha=non-git, uncommitted_changes=no` so consumers have a single source.

### Step 6.1 — Dispatch implementer

Dispatch one `claude` subprocess for role `implementer`. Inputs: `$FEATURE_FOLDER`,
`$PLAN_PATH`, `$SPEC_PATH`, `$IMPLEMENTATION_BASE_SHA`, `$MODE`. `$MODE` was
already resolved to `A` (fresh) or `D` (continuation) by this phase's own
top-of-block `reconstruct_checkpoint_state 6` call (see "Checkpoint
contract and resumable continuation", core document) — never set it again here. `_dispatch_prelaunch` rejects any
value outside `A|B|D` before a single token is spent (`DISPATCH_INVALID_MODE`);
Mode C no longer exists as a value this contract can express. The subagent loads
`superpowers:subagent-driven-development` and runs the full per-task implementation
loop internally (it dispatches its own sub-subagents per plan task as the skill
prescribes). Per-task logs go under `6-implementation/subagent-logs/`. This role's
timeout (from the Models table via `role_timeout`; the implementer may take this long
on large features) exceeds a single Bash tool call, so issue the dispatch as **one
Bash tool call with `run_in_background: true`**; your next turn begins when it
finishes.

For Phase 6, the dispatch also pins the sub-subagent model at the CLI. Write it
exactly as follows — the model must be **generated** from `role_model`, never
written as a literal, or it becomes a fourth place the assignment can drift:

<!-- lint: snippet -->
```bash
# Phase 6: --agents pins the sub-subagent model in the harness, so the pin holds
# even if the supervisor disregards its instructions.
agents_json="$(jq -nc --arg m "$(role_model impl-worker)" \
  '{"impl-worker":{description:"Implementation sub-subagent",
                   prompt:"Follow the task instructions you are given.",
                   model:$m}}')"

# dispatch_attempt renders internally and takes no stdin. Issue this call with
# run_in_background: true -- the implementer's timeout (see the Models table,
# via role_timeout) cannot fit in a foreground Bash call. EXTRA_VENDOR_ARGS is
# the ambient hook invoke_vendor reads for this one claude-only case -- unset
# it again afterward so it never leaks into an unrelated later dispatch.
EXTRA_VENDOR_ARGS=(--agents "$agents_json")
dispatch_attempt 6 00 implementer
unset EXTRA_VENDOR_ARGS
```

Outputs (written by the implementer at the end):
- `<feature-folder>/6-implementation/implementation-summary.md` — task count, commits, verification result, any DONE_WITH_CONCERNS notes.
- `<feature-folder>/6-implementation/verification-records.jsonl` — one `append_verification_record` line per plan-declared verification command (spec §19.2).
- `<feature-folder>/6-implementation/implementer-status.md` — STATUS with `verdict ∈ {DONE, DONE_WITH_EXCLUSIONS, FAILED, NEEDS_DEBUG, BLOCKED}` and `verification ∈ {PASS, FAIL, PARTIAL}`.

You read only `implementer-status.md`. On `DONE` or `DONE_WITH_EXCLUSIONS` with `verification=PASS`, do NOT proceed on the implementer's word alone: call `validate_verification_records "$(status_field "$FEATURE_FOLDER/6-implementation/implementer-status.md" x_verification_records_path)"` (cookbook, spec §19.2) — the zero-token enforcement of every per-record rule the STATUS itself cannot self-certify (empty-is-never-PASS, EXCLUDED exclusion_class/evidence, NOT_RUN reason/followup_id, performance baseline). Only when that ALSO succeeds, proceed to Phase 7. A failure here is Mode 4 (malformed evidence) regardless of what the STATUS claimed — HALT and surface the printed errors; a `DONE_WITH_EXCLUSIONS` verdict whose own `EXCLUDED` records are not policy-valid must never reach Phase 7. `DONE_WITH_EXCLUSIONS` means every non-excluded required verification record passed and every `EXCLUDED` record's evidence was policy-valid; any `NOT_RUN` record is carried forward as handoff/readiness work, never silently dropped.

### Step 6.2 — Debugger pass and reconciliation (only if implementer reports NEEDS_DEBUG or verification != PASS)

debugger-status.md is ADVISORY: the canonical implementation status remains `implementer-status.md`. The orchestrator does NOT gate Phase 7 on `debugger-status.md` directly.

1. Dispatch one `claude` subprocess for role `debugger`. Inputs: `$FEATURE_FOLDER`, `$PLAN_PATH`, `$IMPLEMENTATION_SUMMARY_PATH`, `$IMPLEMENTATION_BASE_SHA`. The debugger loads `superpowers:systematic-debugging`. It edits source/tests as needed and writes `<feature-folder>/6-implementation/debugger-status.md`. This role's timeout comes from the Models table via `role_timeout`.
2. On debugger `verdict=DONE`:
   - **Re-dispatch the implementer** (role `implementer`), setting `MODE=B` (overriding whatever the phase preamble left it at — post-debug re-verification is never a continuation, regardless of what `$CONTINUATION_PATH` says) and additionally passing `$DEBUGGER_STATUS_PATH=<feature-folder>/6-implementation/debugger-status.md`. The implementer re-runs the plan's verification (it does NOT re-do task work), appends the post-debug verification result to `implementation-summary.md`, and atomically rewrites `implementer-status.md`. This is still the `implementer` role, so its timeout (from the Models table via `role_timeout`) exceeds a single Bash tool call — issue this re-dispatch as **one Bash tool call with `run_in_background: true`** as well.
   - Read the rewritten `implementer-status.md`. Proceed to Phase 7 only when `verdict` is `DONE` or `DONE_WITH_EXCLUSIONS`, `verification=PASS`, AND `validate_verification_records "$(status_field "$FEATURE_FOLDER/6-implementation/implementer-status.md" x_verification_records_path)"` (cookbook) also succeeds — the same zero-token gate Step 6.1 applies, re-run here because Mode B rewrote this same evidence file.
   - If the re-run still reports `verification != PASS`, loop back to Step 6.2 step 1 (debugger). Cap at 3 debugger→re-verify iterations; on cap, HALT.
3. On debugger `verdict=BLOCKED`, HALT.

On `BLOCKED` directly from the implementer in Step 6.1, HALT.

### Step 6.3 — Dispatch summarizer-implementation

After the implementer reports `DONE` or `DONE_WITH_EXCLUSIONS` with `verification=PASS` (Step 6.1 or, after debugger reconciliation, Step 6.2), dispatch one `claude` subprocess for role `summarizer-implementation`. Inputs: `$FEATURE_FOLDER`. The subagent reads phase=6 dispatches from `RUN_LOG.md` and appends a `## Usage` section to `6-implementation/implementation-summary.md` (the file already exists; the summarizer appends, does not rewrite). Outputs: `<feature-folder>/6-implementation/summarizer-status.md`. This role's timeout comes from the Models table via `role_timeout`.

Proceed to Phase 7 only after the summarizer reports `DONE`. If the summarizer fails (Mode 1/2/3/4/5), HALT — the readiness report depends on this `## Usage` section.

### Seam classification gate (P01)

Phase 7's own zero-token dispatch gate for the `seam-verifier` role (spec-adjacent P01, same "gate records its own skip evidence" shape `plan_review_stale_gate` (cookbook) already uses): decides whether THIS iteration's diff touches an integration seam — a deploy manifest, a migration directory, an env/config file, or a third-party client wrapper — named by the `seam_globs` Process Policy Registry value (a `;`-separated list of shell glob patterns, matched with `case`, never a hand-rolled regex). A diff touching no seam-classified file skips the `seam-verifier` dispatch entirely: zero added cost on a pure in-repo change.

The check is re-run fresh every iteration against the SAME cumulative diff scope the two code reviewers already use (`$IMPLEMENTATION_BASE_SHA` through this round's `$REVIEWED_REVISION`, never just the latest fixer round's own incremental change) — Step 7.1 never lets the two reviewers skip a re-review or carry forward a prior verdict once dispatched, and the seam-verifier dispatch DECISION mirrors that same rule: recomputed from scratch every iteration, never a carried-forward prior verdict.

Cookbook functions (authored in `runtime/cookbook.sh`):

- `seam_verifier_dispatch_files PHASE ITERATION FILE [FILE ...]` — print the subset of the given changed files matching a `seam_globs` pattern: this iteration's `$SEAM_FILES` input for the seam-verifier dispatch gate (P01).

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: implementer -->
# Role: implementer

You are the implementation supervisor for this feature, invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder;plan_path;spec_path;implementation_base_sha;context7_policy;mode`
- Optional inputs: `debugger_status_path;continuation_path;continuation_prior_classification;declared_foreign_changes`
- Outputs: `implementation_summary;status`
- Allowed verdicts: `DONE;DONE_WITH_EXCLUSIONS;FAILED;NEEDS_DEBUG;BLOCKED`
- Required status fields: `common_v2;verification`
- Checkpoint kind: `implementation`
- Phases: `6`

## Inputs

- `$FEATURE_FOLDER`
- `$PLAN_PATH` — absolute path to the approved plan
- `$SPEC_PATH` — absolute path to the approved spec (for cross-reference only)
- `$IMPLEMENTATION_BASE_SHA` — git SHA captured before any implementer dispatch (or the literal `non-git` if outside a git repo)
- `$MODE` — `A`, `B`, or `D` (see Behavior). This is what SELECTS your behavior below — never infer it yourself from which optional input happens to be set. The orchestrator resolves it before every dispatch and `_dispatch_prelaunch` rejects any other value (`DISPATCH_INVALID_MODE`) before you are ever launched, so you can trust it is exactly one of the three.
- `$DEBUGGER_STATUS_PATH` — absolute path to `debugger-status.md` (set only when `$MODE=B`)
- `$CONTEXT7_POLICY` — `required` or `best-effort` (see below)
- `$CONTINUATION_PATH` — absolute path to a prior, still-partial attempt's own `progress.jsonl` (set only when `$MODE=D`; empty otherwise)
- `$CONTINUATION_PRIOR_CLASSIFICATION` — the prior attempt's own outcome classification (e.g. `TIMED_OUT`, `PUBLICATION_LOST`, `DIRTY_CHECKPOINTED`; set only when `$MODE=D`) — spec §20.6's "prior classification". `PUBLICATION_LOST` in particular means the prior attempt likely completed its work but its STATUS never made it to disk; weight your own re-verification accordingly rather than assuming a `TIMED_OUT`-style genuine mid-task cutoff.
- `$DECLARED_FOREIGN_CHANGES` — space-separated pre-existing dirty paths the current write lease already declared as not yours (optional; only meaningful alongside `$CONTINUATION_PATH`)

## SDD custody

Configure the SDD skill root as `$FEATURE_FOLDER/6-implementation/sdd/`. If the installed skill cannot accept a root, mirror each completed task's brief, report, progress update, and review diff into that same directory IMMEDIATELY after that task — never only at terminal STATUS. Record both paths as `x_sdd_original_path`/`x_sdd_durable_path` in STATUS (see below).

## Required skills

Load `superpowers:subagent-driven-development` and follow it exactly. You run its full per-task loop internally — extracting tasks, dispatching one implementation subagent per task, dispatching spec compliance and code quality reviewer subagents per task, looping on review issues, then dispatching the final code-reviewer.

Additional skills the subagents you dispatch must load:
- `superpowers:test-driven-development`
- `superpowers:verification-before-completion`
- `superpowers:requesting-code-review`
- `superpowers:receiving-code-review`
- `context7` — `context7` policy for this run: **$CONTEXT7_POLICY**.
  - `required` — implementation sub-subagents MUST consult `context7` BEFORE
    writing or modifying code that touches any external library, framework,
    SDK, API, CLI tool, or cloud service. Always `resolve-library-id` first,
    then `get-library-docs`.
  - `best-effort` — `context7` was unreachable at preflight. Sub-subagents
    should attempt it; if it fails, proceed using the plan's cited APIs and
    record in the implementation summary which APIs could not be verified
    against current documentation.

  The plan should already cite the relevant APIs (the plan-writer used
  `context7` too); the sub-subagent re-verifies any API not already covered or
  any usage that drifts from the plan. Skip `context7` only for pure
  refactoring of internal code, business-logic-only changes, or general
  programming work that does not touch external dependencies.

If the plan requires browser/UI QA, also load `dogfood` (or the closest available browser-QA skill) for the verification step.

## Sub-subagent dispatch

Every sub-subagent you dispatch — implementation workers, spec-compliance
reviewers, and code-quality reviewers alike — MUST be spawned with
`subagent_type: impl-worker`. This is what lets the orchestrator's `--agents`
flag (see the Phase 6 dispatch cookbook snippet) pin every one of your
sub-subagents to the model named for the `impl-worker` role in the Models
table, regardless of which per-task job (implementation / spec-compliance
review / code-quality review) you are conceptually assigning it. Record the
agent type each task actually used in `implementation-summary.md` (see
Output) so any drift from `impl-worker` is auditable.

**Child-worker boundary.** You are the ONLY role that may spawn `impl-worker`
children, and only because your own registry row says `may_spawn_children=
yes` — `impl-worker`'s own row says `may_spawn_children=no`, so a child may
never itself spawn a grandchild; it does its one task and returns. A child
never acquires the repository-wide write lease (`.orchestration/write-
lease.json`) independently — you hold the single write lease for this entire
Phase 6 dispatch, and every child's edits land as part of your own mutation,
never a separate lease of its own.
When you dispatch more than one `impl-worker` concurrently, give each a
disjoint set of files/paths to touch — never assign two concurrently-running
children overlapping paths, or their writes race. A child's own result is
hash-addressed: its report/diff gets a real file under
`6-implementation/subagent-logs/` (or the SDD durable root) and you record
that file's `sha256sum` as `artifact_sha256` in the `checkpoint_append` call
you make for its task (see Mode A step 5, below) — that hash, not prose, is
what proves the checkpoint matches what the child actually produced.

## Behavior

Three explicit modes, selected by `$MODE` — never inferred, never mutually
guessed from which optional input happens to be set. `$MODE=C` does not
exist: the old third mode (Phase 7 code-review fixing) used to live here but
is retired. Phase 7 dispatches the bounded `implementation-fixer` role
instead — see its own appendix, below — which never re-runs the plan's task
loop or re-derives scope from the plan, per spec §17.3/§18.4. If you are ever
asked (through a finding-ids input, or any other input naming specific review
findings) to repair a code-review finding, that is outside your role
contract entirely — `_dispatch_prelaunch` rejects it as `ROLE_SCOPE_
VIOLATION` before you would ever be launched to do it.

### Mode A — Fresh implementation (`$MODE=A`)

1. Read `$PLAN_PATH`.
2. Execute the plan task-by-task using `subagent-driven-development`. Commit per task per the plan's TDD shape.
3. Run every command the plan's `## Task Contract` block declares under `verification` (spec §19.2). For EACH command, call `append_verification_record` -- the generated runtime's own writer (never hand-write the JSON line yourself) -- to `$FEATURE_FOLDER/6-implementation/verification-records.jsonl` (truncate/start this file fresh in Mode A; Mode B appends to it instead, see below):

   <!-- lint: snippet -->
   ```bash
   source "$RUNTIME_DIR/develop-it-runtime.sh"
   append_verification_record "$FEATURE_FOLDER/6-implementation/verification-records.jsonl" \
     "<verification_id, e.g. task-03-cmd-01>" "<the exact command>" "<environment>" \
     "<PASS|FAIL|EXCLUDED|NOT_RUN>" "<exit code, or empty>" "<evidence path, or empty>" \
     "<baseline comparison, or empty>" "<reason, required for EXCLUDED/NOT_RUN>" \
     "<followup_id, required (non-null) for NOT_RUN, else empty>" \
     "<exclusion_class, required for EXCLUDED: pre_existing|environment_bound|actor_bound|outside_capability, else empty>"
   ```

   An empty result is never `PASS`. A genuine `FAIL` is left as `FAIL` -- do not
   convert it into `EXCLUDED`/`NOT_RUN` to avoid a debugger pass. `EXCLUDED`
   requires a typed `exclusion_class` (`pre_existing`, `environment_bound`,
   `actor_bound`, or `outside_capability`) plus evidence -- never a free-text
   `reason` alone, and never used to hide a new regression. `NOT_RUN` names
   the blocking actor/prerequisite in `reason`, sets a non-null `followup_id`
   linking it to tracked handoff work, and becomes handoff/readiness work,
   not a silent pass. A
   performance command (benchmark/latency/throughput) may only assert
   `PASS`/`FAIL` under a declared `environment=controlled` with a non-null
   `baseline_comparison`; otherwise record it `NOT_RUN` (advisory/inconclusive)
   instead. A command declared `environment=exclusive` (P16) — e.g. one that
   hits the same shared test DB P03 already serializes Phase 8 around — takes
   the P03 test lease (`acquire_test_lease implementer 6` /
   `release_test_lease implementer`, cookbook) around that one command's run
   only; never run it while another exclusive command holds the lease.
4. Apply no-secret checks when the feature touches credentials, config, notebooks, examples, generated artifacts, or deployment files. Record the no-secret check result in the summary.
5. Track per-task progress in `$FEATURE_FOLDER/6-implementation/subagent-logs/` (one file per task). After every committed task AND its review, call `checkpoint_append` -- the generated runtime's own checkpoint writer (never hand-write the JSON line yourself):

   <!-- lint: snippet -->
   ```bash
   source "$RUNTIME_DIR/develop-it-runtime.sh"
   checkpoint_append "$PHASE_DIR/00/attempts/$DISPATCH_ID/progress.jsonl" "$DISPATCH_ID" implementer \
     sequence="<next integer, starting at 1>" unit_type=task unit_id="<task id>" \
     state=completed artifact_path="<absolute path to that task's report/diff>" \
     artifact_sha256="<sha256 of that report>" commit_sha="<the task's own commit SHA>" \
     verification="<PASS|FAIL>" next_unit="<next task id, or the literal word null>"
   ```
6. Write the summary and publish STATUS (see "Publish STATUS" below).

### Mode B — Post-debug re-verification (`$MODE=B`)

You are being re-dispatched after the debugger has applied fixes. Your job is ONLY to re-validate, not to do new task work.

1. Read `$DEBUGGER_STATUS_PATH`. Note the debugger's reported root cause and fix summary.
2. Run the plan's verification commands in full and APPEND one new `append_verification_record` call per command to the SAME `$FEATURE_FOLDER/6-implementation/verification-records.jsonl` Mode A wrote (never truncate it here -- this is the post-debug re-verification, not a fresh run). Reuse the SAME `verification_id` Mode A used for each command -- `validate_verification_records` evaluates only the LATEST record per `verification_id`, so a fresh outcome under the same ID is how a post-debug PASS supersedes the pre-debug FAIL; a newly-invented ID for the same check would leave the old FAIL sitting alongside the new PASS as two unrelated, permanently-failing entries. Run no-secret checks if applicable.
3. APPEND a new section to `$FEATURE_FOLDER/6-implementation/implementation-summary.md` headed "Post-debug verification (timestamp)" with: debugger root cause, debugger fix summary, the verification commands run, their results, any DONE_WITH_CONCERNS notes.
4. Set the verdict for the post-debug state: `DONE` if every verification record now passes with no `EXCLUDED` records at all, `DONE_WITH_EXCLUSIONS` if every non-excluded required record passes and every `EXCLUDED` record's evidence is policy-valid (spec §19.2, same rule as Mode A); otherwise `NEEDS_DEBUG` (orchestrator will loop) or `BLOCKED`. Publish it in the one "Publish STATUS" step below — never write or rename the STATUS file yourself.

### Mode D — Continuation (`$MODE=D`)

You are a fresh dispatch resuming a PRIOR implementer attempt (same logical
dispatch, same phase, same iteration) that never reached a terminal verdict —
most commonly a clean `TIMED_OUT` after some tasks were already committed and
checkpointed (RM06's `CLEAN_CHECKPOINTED`), which is `INCOMPLETE_CONTINUABLE`,
not a failure. This dispatch counts against `continuation_cap` (`policy_value
continuation_cap`); the orchestrator has already confirmed you are still
within it before dispatching you.

1. Read `$CONTINUATION_PRIOR_CLASSIFICATION` first — it tells you WHAT KIND of interruption you are resuming from before you look at anything else. `PUBLICATION_LOST` means the prior attempt's own work likely finished but its STATUS write never landed: expect the checkpoint to show every task already `completed`, with only STATUS publication remaining. `TIMED_OUT`/`DIRTY_CHECKPOINTED` mean a genuine mid-task cutoff: expect a real dirty partial task per step 2.
2. Read `$CONTINUATION_PATH` — the prior attempt's own `progress.jsonl`. Verify its completed task/commit records against the real tree (`git log`/`git show` each `commit_sha`, confirm each `artifact_path`'s `artifact_sha256` still matches) before trusting any of it.
3. Reconcile AT MOST the one dirty (`state: partial`) task, if any, using `$DECLARED_FOREIGN_CHANGES` to recognize which currently-dirty paths are pre-existing and not yours. Never re-run or re-commit a task the checkpoint already marks `completed` — that would duplicate committed work.
4. Continue the plan task-by-task from the checkpoint's own `next_unit`, exactly like Mode A steps 1–5 (same `append_verification_record`/`checkpoint_append` calls, same `## Task Contract` verification), but never repeating a task this attempt's own history already completed.
5. If every plan task was already `completed` at the point you resumed (only verification remained outstanding), skip straight to running the plan's verification commands, same as Mode A step 3.
6. Write the summary (APPEND a "Continuation (timestamp)" section naming which attempt you resumed, its prior classification, and what you reconciled) and publish STATUS (see "Publish STATUS" below) with the SAME verdict rules as Mode A.

Write the human-facing summary FIRST:

```
Path: $FEATURE_FOLDER/6-implementation/implementation-summary.md
```

Contents:
- Tasks attempted / passed / failed.
- Commits made (SHAs).
- Verification commands run and their results.
- No-secret check result.
- Browser-QA result (if applicable).
- Agent type used per task (implementation worker, spec-compliance reviewer,
  code-quality reviewer) — every one MUST read `impl-worker`; flag any task
  where it does not, so a drift from `subagent_type: impl-worker` is auditable.
- Any DONE_WITH_CONCERNS notes.
- Outstanding follow-ups (if any).

Then publish STATUS.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=implementer phase=6 iteration=00 verdicts='DONE | DONE_WITH_EXCLUSIONS | FAILED | NEEDS_DEBUG | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to implementation-summary.md>
checkpoint_path: $PHASE_DIR/00/attempts/$DISPATCH_ID/progress.jsonl
verification: PASS | FAIL | PARTIAL
x_verification_records_path: $FEATURE_FOLDER/6-implementation/verification-records.jsonl
x_tasks_completed: <int> / <total>
x_completed_task_ids: [task-01, task-02, ...]
x_commit_shas: [sha1, sha2, ...]
x_baseline_sha: $IMPLEMENTATION_BASE_SHA
x_final_sha: <git rev-parse HEAD after your last commit, or the literal word null if you made none>
x_declared_foreign_changes: [<pre-existing dirty path this attempt did not touch>, ...] (or the literal word null if none)
x_remaining_handoffs: [<follow-up id or short description>, ...] (or the literal word null if none)
x_sdd_original_path: <the SDD skill's own working directory, or the literal word null>
x_sdd_durable_path: $FEATURE_FOLDER/6-implementation/sdd/
<!-- INCLUDE-END -->

Verdict rules (spec §19.2):
- `DONE` requires `verification=PASS` and all plan tasks completed, with no `EXCLUDED` records at all.
- `DONE_WITH_EXCLUSIONS` requires every non-excluded required verification record to be `PASS` and every `EXCLUDED` record to carry a policy-valid `exclusion_class` (pre_existing/environment_bound/actor_bound/outside_capability) plus its supporting evidence -- report `verification=PASS` alongside it. Never use this verdict to hide a genuine `FAIL`; a single `FAIL` still requires `NEEDS_DEBUG`. Any `NOT_RUN` record remains visible as handoff/readiness work in the summary and does not, by itself, block this verdict.
- `NEEDS_DEBUG` if verification failed and you believe a debugger pass can resolve it.
- `FAILED` if a task failed for a reason that needs human attention.
- `BLOCKED` if a task requires user input or an unavailable resource.

Exit 0 only after the publisher exits 0.
<!-- END: implementer -->

<!-- BEGIN: debugger -->
# Role: debugger

You are a debugger invoked as a fresh subprocess when the implementer reports `NEEDS_DEBUG` or verification failure. You have no shared context.

## Role contract

- Required inputs: `feature_folder;plan_path;implementation_summary_path;implementation_base_sha;context7_policy`
- Optional inputs: `none`
- Outputs: `status`
- Allowed verdicts: `DONE;BLOCKED`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `6`

## Status semantics

Your debugger-status.md is ADVISORY. The canonical implementation status is `implementer-status.md`, which is rewritten by a subsequent implementer re-dispatch (Mode B) that re-runs verification. The orchestrator does NOT gate Phase 7 on your status file — it gates on the rewritten `implementer-status.md`.

## Inputs

- `$FEATURE_FOLDER`
- `$PLAN_PATH`
- `$IMPLEMENTATION_SUMMARY_PATH` — absolute path to `6-implementation/implementation-summary.md`
- `$IMPLEMENTATION_BASE_SHA` — git SHA captured before any implementer dispatch (or `non-git`)
- `$CONTEXT7_POLICY` — `required` or `best-effort` (see below)

## Required skills

- Load `superpowers:systematic-debugging`. Follow it strictly.
- `context7` policy for this run: **$CONTEXT7_POLICY**.
  - `required` — you MUST call `resolve-library-id` then `get-library-docs`
    whenever the failure signature points at an external library, framework,
    SDK, API, CLI tool, or cloud service, before forming a hypothesis based on
    training-data recall. Library APIs change between versions; do not debug
    against an outdated mental model.
  - `best-effort` — `context7` was unreachable at preflight. Attempt it when
    the failure signature points at an external dependency; if it fails,
    proceed on your best understanding and record in your summary that you
    could not verify against current documentation.

## Behavior

1. Read the implementation summary to identify the failure signature.
2. Read the plan's verification section and `verification-records.jsonl` (spec §19.2) to understand what should pass. You consume only genuine `FAIL` records — never touch a record already `EXCLUDED` or `NOT_RUN`, and never mutate a deployed environment or invent evidence to convert one of those into `PASS` instead of fixing the actual code.
3. If the failure touches an external library / framework / SDK, consult `context7` for the relevant API to confirm correct usage in the version the project pins.
4. Apply systematic debugging: hypothesis → minimal repro → root cause → fix.
5. Re-run the plan's verification commands to spot-check your fix (you may not have full coverage; the canonical re-verification is performed by the implementer re-dispatch after you). If your fix targets a performance finding, remeasure under the SAME controlled conditions as the original measurement — a performance fix that is not remeasured under matching conditions is not verified.
6. If the fix changes source/tests, commit per the project's git policy and the plan's TDD shape.

You may use `$IMPLEMENTATION_BASE_SHA` to constrain `git log`/`git diff` scope to commits the implementer made (e.g. `git log $IMPLEMENTATION_BASE_SHA..HEAD`).

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=debugger phase=6 iteration=00 verdicts='DONE | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: null
x_verification_spot_check: PASS | FAIL | UNKNOWN
x_root_cause: <one line>
x_fix_summary: <one line>
x_new_commits: [sha, ...]
<!-- INCLUDE-END -->

`verdict=DONE` does not promise verification passes — it promises a fix was applied. The implementer re-dispatch is the canonical verification authority.

Exit 0 only after the publisher exits 0.
<!-- END: debugger -->

<!-- BEGIN: summarizer-implementation -->
# Role: summarizer-implementation

You are a phase summarizer invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `run_log`
- Outputs: `summary;status`
- Allowed verdicts: `DONE`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `6`

## Inputs

- `$FEATURE_FOLDER`
- `$FEATURE_FOLDER/RUN_LOG.md`
- `$FEATURE_FOLDER/6-implementation/implementation-summary.md` (already written by the implementer; you APPEND a `## Usage` section to it)

## Behavior

1. Read `$FEATURE_FOLDER/RUN_LOG.md`. Filter dispatch entries (NOT event entries) where `phase=6`.
2. For each entry, read `vendor`, `role`, `iteration`, `model`, `duration_ms`, `tokens_input_new`, `tokens_input_cached`, `tokens_cache_write`, `tokens_output`, `tokens_reasoning`, `cost_usd`, `usage_status`.
3. Entries with `usage_status=unavailable` are skipped from the per-role detail table but counted in a footnote.
4. Compute:
   - Phase total (sum across all entries).
   - Per-vendor subtotal (sum split by `vendor`).
   - Per-role × iteration detail (one row per entry).
   - `cost_usd` sum across only rows whose value is numeric (claude rows); rows with `n/a` excluded from the cost sum but counted in dispatch counts.
5. APPEND a new section to `$FEATURE_FOLDER/6-implementation/implementation-summary.md` headed `## Usage` containing three markdown tables in this order:
   - **Phase total** (one row) — columns: `Phase`, `Dispatches`, `Tokens In (new)`, `Cached`, `Cache Write`, `Out`, `Reasoning`, `Cost USD`, `Duration`.
   - **Per-vendor subtotal** (one row per vendor used) — same columns except `Phase` replaced by `Vendor`.
   - **Per-role × iteration detail** (one row per dispatch) — columns: `Iter`, `Role`, `Vendor`, `In (new)`, `Cached`, `Cache W`, `Out`, `Reasoning`, `Cost`, `Dur`.
   - Numeric columns use thousands separators; cost as `$0.81` or `n/a`; durations as `mm Xs` or `Xs`.
   - If any rows were skipped due to `usage_status=unavailable`, append after the detail table: `_Skipped N dispatches with unavailable telemetry._`

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=summarizer-implementation phase=6 iteration=00 verdicts=DONE reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the summary file you wrote>
checkpoint_path: null
x_dispatches: <int>
x_skipped_unavailable: <int>
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: summarizer-implementation -->
