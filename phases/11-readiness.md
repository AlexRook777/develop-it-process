<!-- PACK: phases/11-readiness.md — sole normative source for Phase 11 (readiness-report); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 11 — Readiness and completion (delegated)

Before dispatching, the orchestrator runs the deterministic audit directly (spec §21, no vendor call, no lease): call `reconcile_propositions`, then `audit_run_state` (cookbook). Both read only durable RUN_LOG event envelopes plus `pending-propositions.jsonl`'s own headers/fulfillment records — never `process-improvement-proposition.md`'s prose body — and append every violation they find to `$ORCHESTRATION_DIR/audit-findings.jsonl` (`{"check":..., "detail":..., "record_ids":[...]}`, append-only). This file's presence/emptiness, not its callers' exit codes, is what readiness-writer and the terminal-verdict rule below consume: an empty (or absent) `audit-findings.jsonl` is a clean audit; any line in it names a real, exact-event-ID-backed problem and unconditionally forces `NOT_READY`.

Dispatch one `claude` subprocess for role `readiness-writer` (`dispatch_attempt 11 00 readiness-writer`). Inputs: `$FEATURE_FOLDER`, `$SPEC_PATH`, `$PLAN_PATH`, `$ORCHESTRATION_DIR/audit-findings.jsonl`. The subagent reads every per-phase summary file inside the feature folder (preflight statuses, phase-2 status, spec-review summary, plan-review summary, implementation summary, code-review summary, all-test summary, `9-documentation/documentation-validation.md`, `followups.jsonl`, the deterministic audit's own `audit-findings.jsonl`, and the LATEST `event=GIT_FINALIZATION_RESULT` entry in `RUN_LOG.md` — never a `git-status.md` file, which no longer exists) and writes:

- `<feature-folder>/final-readiness-report.md` — the human-facing report covering: artifacts, reviewer verdicts (including `partial_review` flag if Codex was unavailable), implementation result, verification result, documentation/UAT status, git result, skipped optional steps, residual MINOR/NIT items, follow-ups (from `followups.jsonl`, grouped by actor), and overall readiness verdict.
- `<feature-folder>/readiness-status.md` — STATUS with `verdict=DONE` and `report_path=<absolute>`.

This role's timeout comes from the Models table via `role_timeout`.

You read only `readiness-status.md`. After it reports `DONE`:

Print to the user a concise message containing the following paths:
- `<feature-folder>/final-readiness-report.md`
- `<feature-folder>/3-spec-review/spec-review-summary.md`
- `<feature-folder>/5-plan-review/plan-review-summary.md`
- `<feature-folder>/6-implementation/implementation-summary.md`
- `<feature-folder>/7-code-review/code-review-summary.md`
- `<feature-folder>/8-all-tests/all-test-summary.md`
- `<feature-folder>/9-documentation/uat.md`
- `<feature-folder>/followups.jsonl` (if present)
- Canonical spec path and plan path
- Test summary (final test verdict + residual failures if any), documentation/UAT status, git summary, skipped optional steps, `partial_review` flag if any, overall readiness verdict.

That message is the user-facing end of a successful run.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: readiness-writer -->
# Role: readiness-writer

You are the final readiness reporter. You have no shared context.

## Role contract

- Required inputs: `feature_folder;spec_path;plan_path`
- Optional inputs: `none`
- Outputs: `report;status`
- Allowed verdicts: `DONE`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `11`

## Inputs

- `$FEATURE_FOLDER`
- `$SPEC_PATH`
- `$PLAN_PATH`
- `$FEATURE_FOLDER/.orchestration/audit-findings.jsonl` (the orchestrator's own deterministic `reconcile_propositions`/`audit_run_state` result, spec §21 — may be absent or empty; either means a clean audit)

## Behavior

1. Read the following files inside `$FEATURE_FOLDER`:
   - `1-preflight/phase-1/claude-check-status.md` (Phase 1 claude verdict; a copy of the attempt-scoped original made by Step 1.2)
   - `1-preflight/phase-1/codex-check-status.md` (Phase 1 codex verdict; may be absent if Codex failed at Phase 1 or `codex_disabled_by_user` was set there)
   - For each phase P in {3, 5, 7}, read both:
     - `<phase-dir>/preflight/claude-check-status.md`
     - `<phase-dir>/preflight/codex-check-status.md`
     where `<phase-dir>` ∈ {`3-spec-review`, `5-plan-review`, `7-code-review`} corresponding to phases {3, 5, 7}. The codex file may be absent per the file-policy rules (see step 2 of this appendix for the classification).
   - For phase 6, read only `6-implementation/preflight/claude-check-status.md`. Phase 6 never dispatches `preflight-codex` (P09) — there is no `6-implementation/preflight/codex-check-status.md` to read and none is expected; do not treat its absence as a file-policy case.
   - `2-context-discovery/status.md`
   - `3-spec-review/spec-review-summary.md` and `3-spec-review/summarizer-status.md` (for `codex_unavailable_reason`)
   - `5-plan-review/plan-review-summary.md` and `5-plan-review/summarizer-status.md`
   - `6-implementation/implementation-summary.md`
   - `6-implementation/implementer-status.md`
   - `7-code-review/code-review-summary.md` and `7-code-review/summarizer-status.md`
   - `8-all-tests/all-test-summary.md` and `8-all-tests/summarizer-status.md` (for `final_test_verdict`, rounds used, and residual failures)
   - `9-documentation/uat.md`, `9-documentation/planned-vs-realized.md`, and `9-documentation/documentation-validation.md` (for documentation/UAT status — read the LATEST `documentation-writer` STATUS's `documentation_validation` field for the validation classification), plus `followups.jsonl` (if present) grouped by `actor` for the report's follow-ups section. Also read every deviation entry in `planned-vs-realized.md` for its `severity: benign | material` tag — this feeds the "Plan deviations" section below.
   - `RUN_LOG.md` (for failure events, resume history, the LATEST `event=IMPLEMENTATION_BASELINE` — ignore any `IMPLEMENTATION_BASELINE_BLOCKED` advisory entries — every `event=CODEX_DISABLED_BY_USER_CONSENT`, `event=CODEX_SKIPPED_BY_USER_CONSENT`, and `event=CODEX_UNAVAILABLE` entry, indexed by `(phase, iteration)`, the LATEST `event=GIT_FINALIZATION_RESULT` entry (for `base_sha`/`final_sha`/`staged_paths`/`commit_sha`/`push_performed`/`outcome` — there is no `git-status.md` file; Phase 10 is a direct orchestrator operation whose only durable trace is this event), AND every dispatch entry's nine usage-telemetry fields for the `## Usage rollup` section).

   Also scan `RUN_LOG.md` for `event=CONTEXT7_UNAVAILABLE`,
   `event=DISPATCH_ORPHANED`, and `event=MODEL_REJECTED`. Each present event gets a
   line in a "## Degradations" section of the readiness report, naming the affected
   roles. A run with any degradation cannot be reported `READY` — use
   `READY_WITH_NOTES` at minimum.

   Also read `$FEATURE_FOLDER/.orchestration/audit-findings.jsonl` if it exists
   (spec §21 — the orchestrator's own `reconcile_propositions`/`audit_run_state`
   result, already durable BEFORE you were dispatched). Each line is one JSON
   object `{"check":..., "detail":..., "record_ids":[...]}`. You never re-derive
   this audit yourself — you only quote it.

2. **Classify each preflight verdict** before composing the report. For each `(phase ∈ {1, 3, 5, 7}, vendor ∈ {claude, codex})` pair, plus `(phase=6, vendor=claude)`:
   - **File present, `verdict: READY`** → `READY`.
   - **File present, any other verdict (e.g. `MISSING_SKILLS`, `UNCERTAIN`, `FAILED`)** → `FAILED`, with the in-file `reason:` / `failure_mode:` carried into the report.
   - **Claude file absent for a phase that ran a claude probe** → `INVALID_ORCHESTRATION`. Set the overall readiness verdict to `NOT_READY` with reason `invalid_orchestration: claude preflight STATUS missing for phase=<P>`. (Claude failures HALT the run, so on HALT the readiness writer does not execute and this branch is only reached when the orchestrator silently dropped a claude STATUS write — a bug.) This applies to Phase 6's claude probe exactly like every other phase.
   - **(Phase 1 only) Codex file absent AND there is an `event=CODEX_DISABLED_BY_USER_CONSENT` in RUN_LOG** → `SKIPPED` (consented degradation at Phase 1). Not a failure. This event is unique per run (no `(phase, iteration)` match required — match on the full first-line tag) and is the canonical Phase 1 user-consent signal; `CODEX_SKIPPED_BY_USER_CONSENT` is NOT logged at Phase 1, so do not look for it there.
   - **(Phases 3, 5, 7) Codex file absent AND there is a matching `event=CODEX_SKIPPED_BY_USER_CONSENT` for the same `(phase, iteration=00)` in RUN_LOG** → `SKIPPED`. Not a failure.
   - **(Phase 1 only) Codex file absent AND there is a matching `event=CODEX_UNAVAILABLE` for `phase: 1` BUT NO `event=CODEX_DISABLED_BY_USER_CONSENT` in RUN_LOG** → `INVALID_ORCHESTRATION`. Per the spec, Phase 1 requires Mode 0 to HALT and Modes 1–5 to proceed only after recorded user consent. Reaching the readiness writer with a Phase 1 codex `CODEX_UNAVAILABLE` and no consent event means the orchestrator violated the Phase 1 HALT-or-prompt rule (e.g., resumed past a HALT it should have honored). Set the overall readiness verdict to `NOT_READY` with reason `invalid_orchestration: Phase 1 codex CODEX_UNAVAILABLE without user consent — run should have HALTed`.
   - **(Phases 3, 5, 7) Codex file absent AND there is a matching `event=CODEX_UNAVAILABLE` for the same `(phase, iteration=00)`** → `FAILED` with `failure_mode` taken from the event. Per-phase Mode 0–5 failures at these gates are passable degradation per the spec (claude-only for the phase); no user consent is required at per-phase gates.
   - **(Phases 1, 3, 5, 7) Codex file absent AND no matching `CODEX_DISABLED_BY_USER_CONSENT` (Phase 1) or `CODEX_SKIPPED_BY_USER_CONSENT` (per-phase) or `CODEX_UNAVAILABLE` event** → `INVALID_ORCHESTRATION`. Set the overall readiness verdict to `NOT_READY` with reason `invalid_orchestration: codex preflight STATUS missing for phase=<P> with no corresponding event`.
   - **(Phase 6 only) There is no `(phase=6, vendor=codex)` pair to classify.** P09 removed Phase 6's codex dispatch entirely: no `6-implementation/preflight/codex-check-status.md` file exists for any run, and Step 6.−1 never appends a `CODEX_UNAVAILABLE` or `CODEX_SKIPPED_BY_USER_CONSENT` event for `(phase=6, iteration=00)`. That absence is normal, not `INVALID_ORCHESTRATION` — do not apply the catch-all rule above to Phase 6. Report Phase 6's codex status as Step 6.−1's own `latest_codex_outcome`-derived note (see step 3 below) instead of a classified verdict.

   The classification per `(phase, vendor)` is reported in the new "Preflight verdicts" section (see step 3 below).
3. Compose `$FEATURE_FOLDER/final-readiness-report.md` with these sections:
   - **Artifacts** — paths to canonical spec, canonical plan, all summary files, AND `<feature-folder>/process-improvement-proposition.md`. The proposition file is listed by path only — its content is NOT read for verdict purposes. If the file does not exist at Phase 11 (no mandatory triggers fired and no spontaneous entries were emitted), list it as `process-improvement-proposition.md (absent — no observations recorded)` so its absence is visible rather than silently omitted.
   - **Preflight verdicts** — per `(phase, vendor)` table for phases in {1, 3, 5, 7} (both vendors) plus phase 6 (claude only): each row reports `phase`, `vendor`, classification (`READY` / `SKIPPED` / `FAILED` / `INVALID_ORCHESTRATION`), and `failure_mode` (if `FAILED`) or skip-reason (if `SKIPPED`). Phase 1 rows are read from `1-preflight/phase-1/`; per-phase rows from `<phase-dir>/preflight/`. Any `INVALID_ORCHESTRATION` row forces the overall readiness verdict to `NOT_READY`. Phase 6 gets no `vendor=codex` row (P09 — no dispatch, no classification); add one note line beneath the table instead, sourced from Step 6.−1's own `latest_codex_outcome`-derived RUN_LOG scan (most recent outcome from Phase 5, falling back to Phase 3) — informational only, never a factor in the readiness verdict.
   - **Reviewer verdicts** — per-gate iteration counts, final verdicts, `partial_review` flag with per-gate `codex_unavailable_reason` if any.
   - **Implementation result** — task count, commits, `implementation_base_sha`, verification, no-secret check, browser-QA result if applicable. If a post-debug re-verification occurred, note it. Read `implementer-status.md`'s own `x_baseline_sha`/`x_final_sha` (cross-check `x_baseline_sha` against the LATEST `event=GIT_FINALIZATION_RESULT` entry's own `base_sha` field in `RUN_LOG.md` — a mismatch is itself a degradation worth a Degradations line) and `x_remaining_handoffs` (surfaced as its own bulleted list under this section when non-null — this is where a Mode D continuation's own leftover follow-ups become visible to the user, not silently dropped).
   - **Test results** — `final_test_verdict` (`PASS` / `FAILED` / `SKIPPED`), execution mode (`start-all-tests.sh` — a project-specific convention — vs discovered suites), rounds used, fix rounds dispatched, and — when `FAILED` — the residual-failure detail carried over from `all-test-summary.md` (failing test names, error excerpts, what each fix round attempted). Include the **Flaky (non-blocking)** section from `all-test-summary.md` whenever present (P10) — regardless of `final_test_verdict` — so a round the process treated as PASS-with-note stays visible rather than silently dropped.
   - **Documentation/UAT status** — `documentation_validation` (`PASS` / `PARTIAL` / `FAILED`) from `9-documentation/documentation-validation.md`, whether `uat.md` includes its required "Not yet executed" section, and a link to `uat.md`. A `documentation_validation` other than `PASS` forces the readiness verdict to at least `READY_WITH_NOTES`.
   - **Plan deviations** — one line per deviation entry in `planned-vs-realized.md`, quoting its `severity: benign | material` tag verbatim. Omit this section only when `planned-vs-realized.md` records no deviations at all. Any `material` entry present forces the readiness verdict to at least `READY_WITH_NOTES` — never a silent `READY` — the same forcing pattern the "Degradations" section below already uses.
   - **Follow-ups** — every record in `followups.jsonl` (if present), grouped by `actor`, each showing `id`, `description`, `status`, and `prerequisite`. Absent when the file does not exist.
   - **Git result** — the LATEST `event=GIT_FINALIZATION_RESULT` entry's `outcome` (`COMMITTED` / `NO_CHANGES` / `BLOCKED` / `FAILED`), `commit_sha` (or `null`), and `push_performed` (always `no` — Phase 10 never pushes). A `BLOCKED` or `FAILED` outcome is reported here, not silently treated as a successful finalization.
   - **Degradations** — one line per `event=CONTEXT7_UNAVAILABLE`, `event=DISPATCH_ORPHANED`, `event=MODEL_REJECTED`, or `event=DEGRADED_REVIEW_ACCEPTED` entry found in `RUN_LOG.md`, naming the affected roles (for `DEGRADED_REVIEW_ACCEPTED`, the `scope` field). Omit this section only when RUN_LOG contains none of these events. Any degradation present forces the readiness verdict to at least `READY_WITH_NOTES` — never a silent `READY`.
   - **Reconciliation audit** — one line per record in `audit-findings.jsonl` (spec §21), each quoting its own `check` code, `detail`, and `record_ids` verbatim — you never paraphrase away the exact record IDs. Omit this section only when the file is absent or empty. ANY line present forces the overall readiness verdict to `NOT_READY` (see the readiness-verdict rule below) — a non-empty reconciliation audit is never merely a note.
   - **Skipped optional steps** — list anything bypassed and why.
   - **Deferred MAJOR items** — total count + per-gate breakdown of MAJOR findings open when a gate passed under the relaxed rule (iterations 3 and up, `blockers=0`, every open major carrying an explicit `deferred:<followup_id>` or `accepted_risk:<decision_id>` disposition per spec §17.3); each WAS re-reviewed — the dispositioning fixer dispatch was followed by another full reviewer round per spec §18.2, never an unreviewed final fix. Read from each gate's summary file (the summarizer records deferred majors there). Present this section only when at least one gate carried deferred majors. NOTE: this section's presence is NOT the trigger for `READY_WITH_NOTES` — a relaxed-tier pass forces `READY_WITH_NOTES` on its own (see the readiness-verdict rule), so a clean relaxed pass produces `READY_WITH_NOTES` with this section absent.
   - **Residual MINOR/NIT items** — total count + per-gate breakdown.
   - **Run history** — number of resumes, vendor failover events from RUN_LOG, baseline SHA capture.
   - **Readiness verdict** — first: if `audit-findings.jsonl` carries any line at all, the verdict is unconditionally `NOT_READY` (spec §21.2/§20.11's "failed audit" gate) regardless of every other section below — quote each finding's own `record_ids` in the reason. Otherwise: `READY` if all gates passed strictly (`blockers=0, majors=0` per active reviewers, i.e. every gate converged by iteration 2), verification=PASS, the all-tests `final_test_verdict` is `PASS` or `SKIPPED`, every preflight verdict is `READY` or `SKIPPED`, the "Degradations" section is empty (no `CONTEXT7_UNAVAILABLE` / `DISPATCH_ORPHANED` / `MODEL_REJECTED` / `DEGRADED_REVIEW_ACCEPTED` events), AND the "Plan deviations" section carries no `material` entry — a run cannot be reported `READY` with any degradation or material deviation present, regardless of how the rest of the run went; `READY_WITH_NOTES` if EITHER (a) Codex was unavailable for one or more gates (`FAILED` codex preflight verdicts present, all claude preflights `READY`, every `SKIPPED` codex preflight backed by either `CODEX_DISABLED_BY_USER_CONSENT` (Phase 1) or `CODEX_SKIPPED_BY_USER_CONSENT` (Phases 3, 5, 7)), OR (b) one or more gates passed under the relaxed rule (final passing iteration ≥ 3, `blockers=0`) — whether or not deferred majors remain, OR (c) the "Degradations" section is non-empty and none of the `NOT_READY` conditions below apply, OR (d) the "Plan deviations" section lists at least one `material` entry and none of the `NOT_READY` conditions below apply; deferred majors, when present, are listed in the "Deferred MAJOR items" section, and the relaxed convergence is always visible in the "Reviewer verdicts" per-gate iteration counts; `NOT_READY` otherwise — specifically including a non-empty reconciliation audit (above), an all-tests `final_test_verdict` of `FAILED` (residual test failures after the fix cap — `NOT_READY` even when everything else passed; the "Test results" section carries the detail), any gate that HALTed with an active reviewer still reporting `blockers > 0`, any `INVALID_ORCHESTRATION` classification (e.g., Phase 1 codex `CODEX_UNAVAILABLE` without recorded user consent), any claude preflight that is not `READY`, or a git finalization `outcome` of `FAILED` (the intended local commit never landed). A `documentation_validation` other than `PASS`, or a git finalization `outcome` of `BLOCKED` (including the non-git and lease-conflict cases), do not by themselves force `NOT_READY` — they force at least `READY_WITH_NOTES`, per the Documentation/UAT status and Git result sections above.
   - **Usage rollup** — emit a final `## Usage rollup` section containing four parts in this order:
     1. **Grand total** (one row) — columns: `Dispatches`, `Tokens In (new)`, `Cached`, `Cache Write`, `Out`, `Reasoning`, `Cost USD`, `Duration`. Sum across every dispatch entry in `RUN_LOG.md`.
     2. **Per-phase table** — one row per phase that ran (use `phase_name` for the row label). Same columns as grand total, plus a leading `Phase` column. Include a final `TOTAL` row that matches the grand total.
     3. **Per-vendor grand total** — one row per vendor used. Columns: `Vendor`, `Dispatches`, `Tokens In (new)`, `Cached`, `Cache Write`, `Out`, `Reasoning`, `Cost USD`.
     4. **Top 5 most expensive dispatches** — sort all `usage_status=ok` rows by `cost_usd` descending (treating `n/a` as below any numeric value). For codex rows with `cost_usd=n/a`, rank them after all numeric rows by `tokens_output` descending. Columns: `#`, `Phase`, `Iter`, `Role`, `Vendor`, `Cost`, `Out`, `Cache W`.
     - Numeric columns use thousands separators. Cost as `$0.81` or `n/a`. Durations as `mm Xs` or `Xs`.
     - If any dispatch had `usage_status=unavailable`, append after the Top-5 table: `_Excluded N dispatches with unavailable telemetry from this rollup._`

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=readiness-writer phase=11 iteration=00 verdicts=DONE reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to final-readiness-report.md>
checkpoint_path: null
x_readiness: READY | READY_WITH_NOTES | NOT_READY
x_partial_review: true | false
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: readiness-writer -->
