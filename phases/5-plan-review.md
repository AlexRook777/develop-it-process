<!-- PACK: phases/5-plan-review.md — sole normative source for Phase 5 (plan-review); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 5 — Plan review gate (delegated, two reviewers, severity-gated)

Same shape as Phase 3 (`phases/3-spec-review.md`), applied to the plan.

**Review-window check (spec §19.1/§20.5-§20.6), before ANY other Phase 5 work — including a resumed or re-entered Phase 5.** Call `plan_review_stale_gate` (cookbook) — never reconstruct this check by hand. It prints `stale` or `open` and never dispatches a reviewer itself on either path. On `stale`: the plan's pre-implementation review window is closed (Phase 6 already captured its implementation baseline this run); the function has already recorded `event=PLAN_REVIEW_STALE` at zero vendor cost — report the `STALE` outcome to the user and do not proceed to Step 5.0. On `open`, continue below.

### Step 5.0 — Per-phase preflight

Before iter 01's first reviewer dispatch (the gate's first work dispatch — see "Terminology gloss" in Resumability), run the per-phase preflight:

1. `mkdir -p <feature-folder>/5-plan-review/preflight`.
2. Reset `codex_available = true` for the phase.
3. If `codex_disabled_by_user = true` (run-scoped flag from Phase 1; reconstitute by scanning RUN_LOG per the rule in "Run-scoped user opt-out"):
   - Dispatch `preflight-claude` only, via `dispatch_attempt 5 00 preflight-claude`.
   - Append one `event=CODEX_SKIPPED_BY_USER_CONSENT` entry to `RUN_LOG.md` with `phase: 5`, `phase_name: plan-review`, `iteration: 00`, `role: preflight-codex`, `vendor: codex` (see RUN_LOG additions for the full block shape).
   - Set `codex_available = false`.
4. Otherwise, dispatch `preflight-claude` and `preflight-codex` **fully in parallel** via `dispatch_parallel 5 00 preflight-claude preflight-codex` (the "Reviewer parallelization" cookbook pattern). Each subprocess publishes its own STATUS to its own attempt-scoped path under `$FEATURE_FOLDER/5-plan-review/00/attempts/` — `dispatch_attempt` mints a distinct attempt id per role, so the two parallel writes never collide.
5. After **both** probes return (or only the claude probe in the opt-out case), copy each STATUS file from its real attempt-scoped path to the phase-local readable alias:

   <!-- lint: snippet -->
   ```bash
   copy_preflight_alias 5 "$FEATURE_FOLDER/5-plan-review/preflight"
   ```

   (`copy_preflight_alias`, cookbook — P21/Task 11.)

   Either copy is a no-op if the corresponding source is absent (see "File policy for non-READY paths" in Step 1.0). Order of the two copies is irrelevant. Do not read any STATUS verdict until both copies (or their no-op equivalents) complete.

6. `dispatch_parallel`/`dispatch_attempt` already appended each probe's own RUN_LOG dispatch entry (`phase: 5`, `phase_name: plan-review`, `iteration: 00`, `role: preflight-claude` or `preflight-codex`, `vendor: claude` or `codex`, `status_path:` its REAL attempt-scoped path) — read the verdict from the copied alias `5-plan-review/preflight/<vendor>-check-status.md` (or `verdict: none` if the probe was skipped via consent or failed without producing STATUS).
7. Branch on the verdicts: same procedure as Step 3.0 item 7 (the canonical per-phase preflight verdict branch, `phases/3-spec-review.md` — P21/Task 11), substituting `phase: 5`, `phase_name: plan-review`, `Phase 5` (for the sticky-within-phase `codex_available` rule and the "remainder of Phase N only" wording), and `p05-i00-preflight-*` throughout. No `DEGRADED_REVIEW_ACCEPTED` delta here — that is Phase 7 only.

The "File policy for non-READY paths" rules in Step 1.0 apply unchanged to this gate.

### Step 5.1 — Iteration loop (same convergence procedure as Step 3.1, `phases/3-spec-review.md`, substituting `$PLAN_PATH`/`plan-writer`/`plan-fixer`/`plan-reviewer-*`)

For each iteration N (start at 1, hard cap `review_iteration_cap`):

1. `mkdir -p <feature-folder>/5-plan-review/NN` (`$PHASE_DIR/$ITERATION`, never `iteration-NN`). Before dispatching this round's reviewers, validate the producer's revision: iteration 1 calls `validate_artifact plan-writer "$(_latest_attempt_id p04-i00-plan-writer)"` (the Phase 4 dispatch — Phase 4 only proceeds to Phase 5 on a `DONE` verdict, so its latest attempt is its successful one); iteration N>1 calls `validate_artifact plan-fixer "$LAST_FIXER_DISPATCH_ID"`. Then call `validate_plan_tasks "$PLAN_PATH"` (cookbook, spec §19.1) — this is a zero-token structural gate over the plan's `## Task Contract` block, distinct from and in addition to `validate_artifact`'s own manifest check. On failure, do NOT dispatch this iteration's reviewers: surface the printed errors and HALT — an under-specified executable task contract must never reach a paid reviewer. Capture `bytes_before="$(wc -c < "$PLAN_PATH")"`.
2. **Dispatch both reviewers in parallel using `dispatch_parallel`** (see "Reviewer parallelization" cookbook). This is **mandatory** — generating bash that dispatches only the Claude reviewer without a corresponding `CODEX_UNAVAILABLE` or `CODEX_SKIPPED_BY_USER_CONSENT` RUN_LOG event for this `(phase=5, iteration=NN)` is an **orchestration bug**. Do not proceed past this step until both subprocesses (or Claude-only when Codex was declared unavailable in Step 5.0) have completed.
   - **Claude subprocess (always dispatched):** dispatch one `claude` subprocess for role `plan-reviewer-claude`. Inputs: `$FEATURE_FOLDER`, `$ITERATION=NN`, `$PLAN_PATH` (read from `4-plan-writing/plan-status.md`), `$SPEC_PATH`. Its real STATUS: `claude_status="$(role_attempt_dir plan-reviewer-claude "$(_latest_attempt_id p05-i$ITERATION-plan-reviewer-claude)")/STATUS.md"`. Findings: `5-plan-review/$ITERATION/claude-findings.jsonl`. This role's timeout comes from the Models table via `role_timeout`.
   - **Codex subprocess (dispatched if and only if `codex_available = true`):** dispatch one `codex` subprocess for role `plan-reviewer-codex`. Its real STATUS: `codex_status="$(role_attempt_dir plan-reviewer-codex "$(_latest_attempt_id p05-i$ITERATION-plan-reviewer-codex)")/STATUS.md"`. Findings: `5-plan-review/$ITERATION/codex-findings.jsonl`. Model, effort, and timeout are resolved per-role from the Models table by `dispatch_parallel`. If `codex_available = false`, the `CODEX_UNAVAILABLE` event was already appended in Step 5.0 — do not dispatch and do not log a new event here.
   Run both as background processes (`& rp=$!`) and wait for both before reading any verdict file.
3. Read only verdict files, then `ingest_findings plan-reviewer-claude "$claude_status" "5-plan-review/$ITERATION/claude-findings.jsonl"` and, when active, the codex counterpart — both merge into `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (derived from each STATUS_FILE's own attempt directory, never a phase-relative alias).
4. Apply the iteration-dependent gate against the catalog counts — **iterations 1–2:** re-dispatch when `blockers + majors > 0`; **iterations 3 and up:** re-dispatch when `blockers > 0` OR any open major still lacks a disposition:
   - Call `reconstruct_checkpoint_state 5 "$ITERATION"` first (plan-fixer is checkpointed, "Checkpoint contract and resumable continuation", core document) so `$CONTINUATION_PATH`/`$DECLARED_FOREIGN_CHANGES` reflect this exact iteration's own prior attempt, if any, before rendering the appendix.
   - `FINDING_IDS="$(select_finding_batch "$PHASE_DIR/$ITERATION/findings-catalog.jsonl")"` — the SAME path the plan-fixer appendix itself reads.
   - Dispatch one `claude` subprocess for role `plan-fixer`. Inputs: `$PLAN_PATH`, `$FINDING_IDS`. The fixer calls `record_finding_disposition` for every assigned ID. This role's timeout comes from the Models table via `role_timeout`.
   - `dispositions_complete "$PHASE_DIR/$ITERATION/findings-catalog.jsonl" $FINDING_IDS`; treat a gap as Mode 4.
   - `unset FINDING_IDS` immediately afterward — the next iteration's reviewers never declare `finding_ids` and would otherwise be scope-rejected by a stale value.
   - Capture `bytes_after`, tally this round's counts, and call `record_convergence_signals 5 "$ITERATION" ...`.
   - Call `divergence_check 5 "$ITERATION" "$PHASE_DIR/$ITERATION/findings-catalog.jsonl"` and apply the SAME divergence handling as Step 3.1 (`phases/3-spec-review.md`), substituting `plan-review`/`plan-fixer`/`$PLAN_PATH` (record the event(s); at `divergent_round_cap`, check `divergent_round_cap_hit_before plan-review` FIRST — on `yes`, HALT with the catalog paths instead of dispatching a third batch; on `no`, re-populate `FINDING_IDS` via `select_finding_batch` and dispatch one consolidation-priority `plan-fixer` batch instead of the ordinary one).
   - Increment N. Loop from step 1 — reviewers ALWAYS run again; no cap-adjacent fixer dispatch ever substitutes for the next reviewer round.
5. When the gate passes:
   - Dispatch one `claude` subprocess for role `summarizer-plan`. Outputs: `5-plan-review/plan-review-summary.md` and `5-plan-review/summarizer-status.md`. The summarizer records any deferred/accepted-risk majors (from the final catalog) in the summary file.
   - You read only `summarizer-status.md`. On `DONE`, proceed to Phase 6. The last successful gate action before Phase 6 is this reviewer-verified acceptance, never the fixer's own STATUS.

If iteration cap (`review_iteration_cap`) trips with any active reviewer still reporting an open BLOCKER, HALT and surface to user. A cap reached with `blockers=0` and every remaining major already dispositioned is NOT a HALT — it passes per the relaxed gate (and sets the readiness verdict to `READY_WITH_NOTES`). An undispositioned major at the cap HALTs like a blocker.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: plan-reviewer-claude -->
# Role: plan-reviewer-claude

You are a plan reviewer invoked as a fresh subprocess. You have no shared context.

## Role contract

- Required inputs: `feature_folder;iteration;plan_path;spec_path`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `5`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$PLAN_PATH` — absolute path to the plan
- `$SPEC_PATH` — absolute path to the approved spec (use only for spec-coverage cross-check)

## Behavior

1. Read `$PLAN_PATH` and `$SPEC_PATH`.
2. Evaluate against these dimensions:
   - Spec coverage: does every spec requirement map to one or more tasks?
   - Task granularity: are steps 2-5 minutes each, with exact paths, full code, exact commands?
   - TDD shape: does each task have failing-test → implement → passing-test → commit?
   - Type/method consistency across tasks (e.g. a function named `foo()` in Task 3 and `bar()` in Task 7 referring to the same thing is a bug).
   - Frequent-commits cadence.
   - DRY/YAGNI: any over-engineering or unnecessary scope creep?
   - Placeholders: any TBD, "implement later", "similar to Task N", references to undefined symbols?
   - Order: do dependencies between tasks reflect actual dependencies, and do they form a DAG (no cycles) over tasks that actually exist in the plan?
   - Executable task contract (spec §19.1): does every task declare a valid `actor` (`implementer`, `owner`, `CI`, or `deployed_environment`)? Is every `prerequisites` entry reachable (an existing task_id)? Is every named `credential` an env-var-style NAME, never a value — flag anything that looks like inline secret material? Is every `verification` command deterministic and actually executable (not "similar to Task N", not vague prose)? Are declared exclusions/side-effects consistent with the steps? Is the plan's review-window freshness still current (no stale anchors from a prior accepted revision)? Are optional skills routed only where task-relevant? Does every non-`implementer` task carry a concrete, non-null `handoff` rather than becoming a surprise implementer failure?
   - Post-implementation-only review remedy: flag any task whose only "verification" is deferring to code review or a later phase instead of an executable check now.
3. Severity ladder: BLOCKER / MAJOR / MINOR — same definitions as the spec reviewer.

Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above). Findings: `$FEATURE_FOLDER/5-plan-review/$ITERATION/claude-findings.jsonl`. Each object: <!-- INCLUDE-BEGIN: finding-record-schema reviewer_role=plan-reviewer-claude vendor=claude phase=5 artifact_path_spec='`artifact_path: "$PLAN_PATH"`' artifact_revision_spec='`artifact_revision`' line_spec='`line`' evidence_spec='`evidence`' -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=plan-reviewer-claude phase=5 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the findings file you wrote>
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
blockers: <int>
majors: <int>
minors: <int>
findings: <path to the findings file you wrote, or none>
<!-- INCLUDE-END -->

Verdict: `PASS` iff `blockers=0 AND majors=0`.

Exit 0 only after the publisher exits 0.
<!-- END: plan-reviewer-claude -->

<!-- BEGIN: plan-reviewer-codex -->
# Role: plan-reviewer-codex

You are a dispatched subprocess. Do NOT load, read, or invoke Superpowers skills.
Do NOT read ~/.codex/skills, ~/.claude/skills, .claude/skills, or any skill
directory. This appendix is your complete instruction set.

Independence means independent judgment over the supplied artifact, not
independent repository discovery.

You are a cross-vendor plan reviewer invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context. You produce an independent assessment — do NOT attempt to read the primary reviewer's verdict or findings.

## Role contract

- Required inputs: `feature_folder;iteration;plan_path;spec_path`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `5`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$PLAN_PATH` — absolute path to the plan
- `$SPEC_PATH` — absolute path to the approved spec (use only for spec-coverage cross-check)

## Mode

`scoped` mode (plan + spec only). Filesystem allow-list: `$PLAN_PATH`, `$SPEC_PATH`, plus your own output files inside `$FEATURE_FOLDER/5-plan-review/$ITERATION/`. Command budget: max 4 shell or read commands per dispatch.

## Forbidden reads

You may NOT read any of the following, even if you believe it would improve the review:

- source files (`*.py`, `*.ts`, etc.) anywhere in the repo
- test files
- transcripts (`$FEATURE_FOLDER/transcripts/*`)
- `RUN_LOG.md`
- `2-context-discovery/status.md`
- `6-implementation/*` artifacts (these may not exist yet, but are forbidden in any case)
- previous reviewer findings
- skill directories
- `~/.codex/config.toml`
- arbitrary repo files via broad `rg` or `find`

The plan must be self-contained per `superpowers:writing-plans` "no placeholders" rule. The plan-writer already cited library APIs via `context7`. If the plan references implementation files that you cannot verify under this allow-list, surface that as a MAJOR ("plan references file X but reviewer cannot verify existence without code access; recommend plan-writer either include exact file path with confirmed existence or mark for code-aware review").

## Behavior

1. Read `$PLAN_PATH` and `$SPEC_PATH` (counts as 2 of your 4 commands).
2. Evaluate against these dimensions using the BLOCKER / MAJOR / MINOR severity ladder:
   - Spec coverage: does every spec requirement map to one or more tasks?
   - Task granularity: are steps 2-5 minutes each, with exact paths, full code, exact commands?
   - TDD shape: does each task have failing-test → implement → passing-test → commit?
   - Type/method consistency across tasks (e.g. a function named `foo()` in Task 3 and `bar()` in Task 7 referring to the same thing is a bug).
   - Frequent-commits cadence.
   - DRY/YAGNI: any over-engineering or unnecessary scope creep?
   - Placeholders: any TBD, "implement later", "similar to Task N", references to undefined symbols?
   - Order: do dependencies between tasks reflect actual dependencies, and do they form a DAG (no cycles) over tasks that actually exist in the plan?
   - Executable task contract (spec §19.1): does every task declare a valid `actor` (`implementer`, `owner`, `CI`, or `deployed_environment`)? Is every `prerequisites` entry reachable (an existing task_id)? Is every named `credential` an env-var-style NAME, never a value — flag anything that looks like inline secret material? Is every `verification` command deterministic and actually executable (not "similar to Task N", not vague prose)? Are declared exclusions/side-effects consistent with the steps? Is the plan's review-window freshness still current (no stale anchors from a prior accepted revision)? Are optional skills routed only where task-relevant? Does every non-`implementer` task carry a concrete, non-null `handoff` rather than becoming a surprise implementer failure?
   - Post-implementation-only review remedy: flag any task whose only "verification" is deferring to code review or a later phase instead of an executable check now.
3. Classify every finding into exactly one severity. Do NOT label obvious correctness/coverage issues as MINOR.

## Findings budget

Report every BLOCKER and MAJOR you find; cap MINOR findings at 10; keep each finding under 150 words.

Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above). Findings: `$FEATURE_FOLDER/5-plan-review/$ITERATION/codex-findings.jsonl`. Each object: <!-- INCLUDE-BEGIN: finding-record-schema reviewer_role=plan-reviewer-codex vendor=codex phase=5 artifact_path_spec='`artifact_path: "$PLAN_PATH"`' artifact_revision_spec='`artifact_revision`' line_spec='`line`' evidence_spec='`evidence`' -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=plan-reviewer-codex phase=5 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the findings file you wrote>
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
blockers: <int>
majors: <int>
minors: <int>
findings: <path to the findings file you wrote, or none>
<!-- INCLUDE-END -->

Verdict rule: `PASS` iff `blockers=0 AND majors=0`.

Exit 0 only after the publisher exits 0.
<!-- END: plan-reviewer-codex -->

<!-- BEGIN: plan-fixer -->
# Role: plan-fixer

You are a plan patcher invoked as a fresh subprocess. You have no shared context.

## Role contract

- Required inputs: `feature_folder;iteration;plan_path;finding_ids`
- Optional inputs: `continuation_path;declared_foreign_changes`
- Outputs: `status;progress.jsonl`
- Allowed verdicts: `DONE;BLOCKED`
- Required status fields: `common_v2;changed_paths;finding_dispositions`
- Checkpoint kind: `document-fixer`
- Phases: `5`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$PLAN_PATH`
- `$FINDING_IDS` — the specific canonical finding identifiers assigned to you this iteration (space-separated, never the full findings catalog)
- `$CONTINUATION_PATH` — absolute path to a prior, still-partial attempt's own `progress.jsonl` (only set when you are a continuation; empty otherwise)
- `$DECLARED_FOREIGN_CHANGES` — space-separated pre-existing dirty paths the current write lease already declared as not yours (optional; only meaningful alongside `$CONTINUATION_PATH`)

You are assigned at most `document_fixer_batch_size` finding IDs at a time.

## Behavior

1. If `$CONTINUATION_PATH` is set, read it first: resume from its last recorded `next_unit`, reconcile at most the one dirty (`state: partial`) finding using `$DECLARED_FOREIGN_CHANGES`, and never re-patch a finding its records already mark disposed.
2. Read ONLY the findings named in `$FINDING_IDS` from `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (`jq --arg id ... 'select(.finding_id==$id)'`), and `$PLAN_PATH`.
3. Patch the plan in place to address every BLOCKER and MAJOR among your assigned IDs — prefer simplifying, replacing, or deleting redundant text over appending another rule (spec §18.4).
4. Address assigned MINOR findings opportunistically; otherwise dispose them `already_satisfied`.
5. Where a finding requires user input, dispose it `blocked` and set `verdict=BLOCKED`.
6. Preserve the plan's overall structure (header, file structure section, task numbering, TDD shape) and the `## Task Contract` block's schema (spec §19.1) — a field fix belongs in that JSON block, not only in the prose task description.
7. Do not restructure plan text the finding did not flag. If fixing an assigned finding surfaces an UNRELATED opportunity (a real improvement the finding itself did not flag), do NOT fold it into this pass — note it in your human-facing summary as a follow-up for a human to triage later; only edits addressing an assigned finding ID belong in this pass (spec §17.3/§18.4).
8. Inspect adjacent sections/acceptance criteria for ripple effects.

For EVERY assigned finding ID, record exactly one disposition (spec §17.3's six-value vocabulary: `fixed`, `subsumed_by:<finding_id>`, `already_satisfied`, `blocked`, `accepted_risk:<decision_id>`, `deferred:<followup_id>`) by calling `record_finding_disposition` — the generated runtime's own disposition writer:

<!-- lint: snippet -->
```bash
source "$RUNTIME_DIR/develop-it-runtime.sh"
record_finding_disposition "$PHASE_DIR/$ITERATION/findings-catalog.jsonl" "<finding id>" \
  "<fixed|subsumed_by:<finding_id>|already_satisfied|blocked|accepted_risk:<decision_id>|deferred:<followup_id>>" \
  "<one-line evidence>"
```

After every finding disposition, ALSO call `checkpoint_append` -- the generated runtime's own checkpoint writer (spec S10.1; never hand-write the JSON line yourself):

<!-- lint: snippet -->
```bash
checkpoint_append "$PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl" "$DISPATCH_ID" plan-fixer \
  sequence="<next integer, starting at 1>" unit_type=finding unit_id="<finding id>" \
  state=completed artifact_path="$PLAN_PATH" \
  artifact_sha256="<sha256 of \$PLAN_PATH after this disposition>" commit_sha=null \
  verification=PASS next_unit="<next unresolved finding id in this batch, or the literal word null>"
```

`DONE` requires every ID in `$FINDING_IDS` to have a disposition — never claim full completion from a partial batch.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=plan-fixer phase=5 iteration='$ITERATION' verdicts='DONE | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
changed_paths: [path, ...]
finding_dispositions: [finding_id=<disposition>, ...]
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: plan-fixer -->

<!-- BEGIN: summarizer-plan -->
# Role: summarizer-plan

You are a gate summarizer invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `run_log`
- Outputs: `summary;status`
- Allowed verdicts: `DONE`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `5`

## Inputs

- `$FEATURE_FOLDER`
- `$FEATURE_FOLDER/RUN_LOG.md` (you read this for failover context)

## Behavior

1. Enumerate this gate's iteration directories under `$FEATURE_FOLDER/5-plan-review/` — real iterations are two-digit numeric directories (`01`, `02`, ... — never the retired `iteration-*` glob), each holding `findings-catalog.jsonl` plus an `attempts/` subdirectory.
2. For each iteration, read `findings-catalog.jsonl` — the merged, canonical catalog `ingest_findings` wrote (spec §17.2) — for that iteration's severity counts and per-finding disposition/status. NEVER read the raw per-reviewer `*-findings.jsonl` files for counting: they are pre-union and double-count anything both reviewers reported, exactly the union the catalog already computes. For each reviewer's own verdict and codex-availability signal, read its attempt-scoped `STATUS.md` under `attempts/<dispatch-id>/` (locate the dispatch id from `RUN_LOG.md`'s own `DISPATCH_COMPLETED` entries naming this `phase`/`iteration`/`role`).
3. Read `$FEATURE_FOLDER/RUN_LOG.md`. Filter entries where `event=CODEX_UNAVAILABLE` AND `phase=5` (plan review). Capture `failure_mode=<n>` and the iteration number from each such entry.
4. Aggregate statistics:
   - Number of iterations run.
   - Total findings per severity (BLOCKER / MAJOR / MINOR) per iteration.
   - Net changes the plan-fixer made each iteration (read each finding's `.disposition`/`.status` from that iteration's own `findings-catalog.jsonl` — never a `plan-fixer-status.md` alias, which was never a real path).
   - Residual MINOR/NIT items at the final iteration.
   - `partial_review = true` if any iteration was Claude-only.
   - `codex_unavailable_reason` derived from the CODEX_UNAVAILABLE events (same format as summarizer-spec).
<!-- INCLUDE-BEGIN: summarizer-usage-aggregation phase=5 -->
<!-- INCLUDE-END -->
6. Write the summary file at `$FEATURE_FOLDER/5-plan-review/plan-review-summary.md` with:
   - Iteration count.
   - Findings counts table per iteration.
   - Deferred MAJOR list — MAJOR findings still open (from the final catalog) at the passing iteration, each carrying an explicit `deferred:<followup_id>` or `accepted_risk:<decision_id>` disposition (spec §17.3). Non-empty ONLY when the gate passed under the relaxed rule (final iteration ≥ 3, `blockers=0`, every open major dispositioned); empty for a strict pass. For each deferred major, record its finding_id, source reviewer, location, disposition, and one-line summary. These majors WERE re-reviewed — the fixer's dispositioning dispatch was followed by another full reviewer round per spec §18.2; note that in the list.
   - Residual MINOR/NIT list.
   - `partial_review` flag and `codex_unavailable_reason` (if any), one human-readable sentence per mode.
   - Final verdict (`PASS`) and final iteration number. Note whether the pass was strict (converged by iteration 2) or relaxed (final iteration ≥ 3); record deferred majors separately, only when present.
<!-- INCLUDE-BEGIN: summarizer-usage-table-format -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=summarizer-plan phase=5 iteration=00 verdicts=DONE reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the summary file you wrote>
checkpoint_path: null
x_iterations: <int>
x_total_blockers: <int>
x_total_majors: <int>
x_deferred_majors: <int>
x_relaxed_pass: true | false
x_residual_minors: <int>
x_partial_review: true | false
x_codex_unavailable_reason: <mode=N;iteration=NN or empty>
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: summarizer-plan -->
