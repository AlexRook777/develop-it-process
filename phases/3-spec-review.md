<!-- PACK: phases/3-spec-review.md — sole normative source for Phase 3 (spec-review); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 3 — Spec review gate (delegated, two reviewers, severity-gated)

### Step 3.0 — Per-phase preflight

Before iter 01's first reviewer dispatch (the gate's **first work dispatch**, defined as the first dispatch of that gate's iteration loop across the entire run as a whole), run the per-phase preflight:

1. `mkdir -p <feature-folder>/3-spec-review/preflight`.
2. Reset `codex_available = true` for the phase.
3. If `codex_disabled_by_user = true` (run-scoped flag from Phase 1; reconstitute by scanning RUN_LOG per the rule in "Run-scoped user opt-out"):
   - Dispatch `preflight-claude` only, via `dispatch_attempt 3 00 preflight-claude`.
   - Append one `event=CODEX_SKIPPED_BY_USER_CONSENT` entry to `RUN_LOG.md` with `phase: 3`, `phase_name: spec-review`, `iteration: 00`, `role: preflight-codex`, `vendor: codex` (see RUN_LOG additions for the full block shape).
   - Set `codex_available = false`.
4. Otherwise, dispatch `preflight-claude` and `preflight-codex` **fully in parallel** via `dispatch_parallel 3 00 preflight-claude preflight-codex` (the "Reviewer parallelization" cookbook pattern). Each subprocess publishes its own STATUS to its own attempt-scoped path under `$FEATURE_FOLDER/3-spec-review/00/attempts/` — `dispatch_attempt` mints a distinct attempt id per role, so the two parallel writes never collide.
5. After **both** probes return (or only the claude probe in the opt-out case), copy each STATUS file from its real attempt-scoped path to the phase-local readable alias:

   <!-- lint: snippet -->
   ```bash
   copy_preflight_alias 3 "$FEATURE_FOLDER/3-spec-review/preflight"
   ```

   (`copy_preflight_alias`, cookbook — P21/Task 11.)

   Either copy is a no-op if the corresponding source is absent (see "File policy for non-READY paths" below). Order of the two copies is irrelevant. Do not read any STATUS verdict until both copies (or their no-op equivalents) complete.

6. `dispatch_parallel`/`dispatch_attempt` already appended each probe's own RUN_LOG dispatch entry (`phase: 3`, `phase_name: spec-review`, `iteration: 00`, `role: preflight-claude` or `preflight-codex`, `vendor: claude` or `codex`, `status_path:` its REAL attempt-scoped path) — read the verdict from the copied alias `3-spec-review/preflight/<vendor>-check-status.md` (or `verdict: none` if the probe was skipped via consent or failed without producing STATUS).
7. Branch on the verdicts (P21/Task 11: this is the canonical per-phase preflight verdict branch — Phases 5 and 7 (`phases/5-plan-review.md`, `phases/7-code-review.md`) cite it rather than repeating it, substituting their own `phase`/`phase_name`/dispatch-prefix throughout and, for Phase 7 only, adding the `DEGRADED_REVIEW_ACCEPTED` delta after the codex-degradation bullets):
   - **Claude probe fails (any mode):** HALT unconditionally. No user prompt — claude is required for every phase. Surface stderr tail and remediation per the existing claude-failure path.
   - **Codex probe fails with any of Modes 0, 1, 2, 3, 4, or 5:** call `vendor_preflight_reprobe_once codex <N>` first (spec §16.3 -- a vendor already proven this run by an earlier substantive dispatch gets one re-probe before a cheap preflight wobble is allowed to degrade coverage; this is the real behavioural read of `vendor_proven`, not just a write-only record). On `yes`, re-dispatch `preflight-codex` ONE more time (same `dispatch_parallel` mechanism as the initial probe). If that re-probe comes back `READY`, proceed with `codex_available = true` as normal -- do NOT append `event=CODEX_UNAVAILABLE`, since codex was never actually unavailable this phase. Otherwise (the re-probe also failed, or `vendor_preflight_reprobe_once` said `no`): set `codex_available = false` for the remainder of Phase 3 only (the sticky-within-phase rule). Append `event=CODEX_UNAVAILABLE` with `phase: 3`, `phase_name: spec-review`, `iteration: 00`, `failure_mode: <N>` (the LATEST probe's mode), and the stderr tail. **Mode 0 here does NOT HALT** — the unconditional-Mode-0-HALT rule applies only at Phase 1; at a per-phase gate, a missing binary degrades to claude-only for the phase, matching every other vendor-side failure mid-run. Proceed to step 1 of the iteration loop with `codex_available = false`.
   - **Either probe (a successfully-completed dispatch — rc=0, STATUS parses) reports `verdict=MISSING_SKILLS` or `verdict=UNCERTAIN`** — a legal semantic verdict, distinct from the Modes 0–5 subprocess failures above (spec §16.3, generalizing Phase 1 Step 1.1 step 5's own re-probe to this gate — P02): call `skills_reprobe_needed` (cookbook) for that vendor with the same three conditions Phase 1 uses — (a) `yes` iff an earlier phase in THIS run already recorded `READY` for that vendor (scan `RUN_LOG.md`); (b) `yes` iff a deterministic filesystem check shows the named skill directory/`SKILL.md` actually exists under a checked plugin root; (c) `yes` iff the STATUS file (or its sibling `.tmp.*`) shows the attempt reached publication but lost its final STATUS. An `UNCERTAIN` verdict (P12 — the probe itself could not finish scanning every configured plugin root) additionally ALWAYS triggers the re-probe regardless of those three conditions; it is never treated as an absence claim. On `true` (or on any `UNCERTAIN`), re-dispatch that ONE vendor's preflight role once more (same `dispatch_parallel` mechanism as the initial probe, a fresh attempt) and use the re-probe's verdict in place of the first. A second consecutive `MISSING_SKILLS` is accepted as real; a second consecutive `UNCERTAIN` is accepted as "still can't tell" and handled exactly like `MISSING_SKILLS` below for control-flow purposes — it is NEVER promoted to a confirmed-`MISSING` claim:
     - **Claude confirmed `MISSING_SKILLS`, or claude still `UNCERTAIN` after the re-probe:** HALT — claude is required for every phase. For `MISSING_SKILLS`, print which skills are missing (`required_skills_missing` plus `x_plugin_roots_checked`) plus the Phase 1 install hint; for `UNCERTAIN`, print that claude's skill scan could not complete after one retry and surface `x_plugin_roots_checked` so the user can verify manually.
     - **Codex confirmed `MISSING_SKILLS`, or codex still `UNCERTAIN` after the re-probe:** treat exactly like a codex probe failure (the bullet above) — set `codex_available = false` for the remainder of Phase 3 only, and append `event=CODEX_UNAVAILABLE` with `phase: 3`, `phase_name: spec-review`, `iteration: 00`, `failure_mode:` the literal string `missing_skills` or `uncertain`, and the missing-skills/uncertain detail in place of a stderr tail. Do NOT HALT — codex degrades to claude-only for the phase like every other vendor-side per-phase failure. Proceed to step 1 of the iteration loop with `codex_available = false`.
     Both probe attempts (the original and the re-probe) stay in `RUN_LOG.md` with their raw outputs — the re-probe is a normal `dispatch_parallel`/`dispatch_attempt` call and gets its own `DISPATCH_STARTED`/`DISPATCH_COMPLETED` pair like any other attempt, so a flake remains auditable.
   - **Both probes READY (or claude READY and codex skipped via consent):** proceed to step 1 of the iteration loop. `codex_available` reflects the probe outcome (true if codex READY, false if skipped or failed).

### File policy for non-READY paths (applies to every per-phase preflight gate)

Per the design's "File policy for non-READY paths" section, the orchestrator's contract is:

- **Claude STATUS file missing for a phase that ran a claude probe** → orchestration bug; readiness writer reports `INVALID_ORCHESTRATION`. Claude failures HALT unconditionally, so on HALT the readiness writer does not run and a post-HALT absence is not observable as `INVALID_ORCHESTRATION`; the HALTed run is evidenced only by the RUN_LOG entry and the surfaced stderr.
- **Codex STATUS file missing because `codex_disabled_by_user = true`** → expected. No synthetic STATUS written. Evidence is the `CODEX_SKIPPED_BY_USER_CONSENT` event for the same `(phase, iteration)`. Downstream consumers treat the missing file as `SKIPPED`.
- **Codex STATUS file missing because the probe failed in any of Modes 0, 1, 2, 3, or 5** → expected; the subprocess commonly dies before any STATUS write. No synthetic STATUS written. Evidence is the `CODEX_UNAVAILABLE` event with the corresponding `failure_mode`. Downstream consumers treat the missing file as `FAILED` with that mode.
- **Codex STATUS file present but malformed (Mode 4 after the one allowed retry)** → expected; the move step still runs because the file exists. Downstream consumers treat it as `FAILED` (mode 4).
- **Codex STATUS file missing with no corresponding `CODEX_SKIPPED_BY_USER_CONSENT` or `CODEX_UNAVAILABLE` event for that `(phase, iteration)`** → orchestration bug; readiness writer reports `INVALID_ORCHESTRATION` and fails the readiness check.

### Step 3.1 — Iteration loop (spec §18.1–§18.3; the canonical gate-loop procedure — Phases 5 and 7 (`phases/5-plan-review.md`, `phases/7-code-review.md`) cite this one rather than repeating it)

For each iteration N (start at 1, hard cap `review_iteration_cap`):

1. `mkdir -p <feature-folder>/3-spec-review/NN` (`$PHASE_DIR/$ITERATION`, never `iteration-NN`). Before dispatching this round's reviewers, if a fixer produced this revision (N > 1), call `validate_artifact spec-fixer "$LAST_FIXER_DISPATCH_ID"` — a producer's revision never enters review on size or marker presence alone. Capture `bytes_before="$(wc -c < "$SPEC_PATH")"` for this round's convergence signal.
2. **Dispatch both reviewers in parallel using `dispatch_parallel`** (see "Reviewer parallelization" cookbook). This is **mandatory** — generating bash that dispatches only the Claude reviewer without a corresponding `CODEX_UNAVAILABLE` or `CODEX_SKIPPED_BY_USER_CONSENT` RUN_LOG event for this `(phase=3, iteration=NN)` is an **orchestration bug**. Do not proceed past this step until both subprocesses (or Claude-only when Codex was declared unavailable in Step 3.0) have completed.
   - **Claude subprocess (always dispatched):** dispatch one `claude` subprocess for role `spec-reviewer-claude`. Inputs: `$FEATURE_FOLDER`, `$ITERATION=NN`, `$SPEC_PATH`. Its real STATUS lives at its own attempt directory (never a phase-level alias): `claude_status="$(role_attempt_dir spec-reviewer-claude "$(_latest_attempt_id p03-i$ITERATION-spec-reviewer-claude)")/STATUS.md"`. Findings: `3-spec-review/$ITERATION/claude-findings.jsonl` (one canonical-schema JSON record per line — spec §17.2). This role's timeout comes from the Models table via `role_timeout`.
   - **Codex subprocess (dispatched if and only if `codex_available = true`):** dispatch one `codex` subprocess for role `spec-reviewer-codex`. Its real STATUS: `codex_status="$(role_attempt_dir spec-reviewer-codex "$(_latest_attempt_id p03-i$ITERATION-spec-reviewer-codex)")/STATUS.md"`. Findings: `3-spec-review/$ITERATION/codex-findings.jsonl`. Model, effort, and timeout are resolved per-role from the Models table by `dispatch_parallel`. If `codex_available = false`, the `CODEX_UNAVAILABLE` event was already appended in Step 3.0 — do not dispatch and do not log a new event here.
   Run both as background processes (`& rp=$!`) and wait for both before reading any verdict file.
3. Read only the verdict files, then ingest findings: `ingest_findings spec-reviewer-claude "$claude_status" "3-spec-review/$ITERATION/claude-findings.jsonl"`, and — only when `codex_available = true` — `ingest_findings spec-reviewer-codex "$codex_status" "3-spec-review/$ITERATION/codex-findings.jsonl"`. Both calls merge into the SAME `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (`ingest_findings` derives this from each STATUS_FILE's own attempt directory — `dirname` three levels up — so it lands here regardless of which reviewer's STATUS_FILE was passed; union — spec §16.5). Read `blockers`/`majors`/`minors` from the LAST call's own printed summary (the catalog is shared state; either call's summary reflects the union so far, but wait for both before deciding the gate).
4. Apply the iteration-dependent gate (see "Review-gate severity policy") against the catalog counts from step 3 — **iterations 1–2:** re-dispatch when `blockers + majors > 0`; **iterations 3 and up:** re-dispatch when `blockers > 0` OR any open major still lacks a disposition (`dispositions_complete` against the catalog's own open-major IDs returns nonzero):
   - Call `reconstruct_checkpoint_state 3 "$ITERATION"` first (spec-fixer is checkpointed, "Checkpoint contract and resumable continuation", core document) so `$CONTINUATION_PATH`/`$DECLARED_FOREIGN_CHANGES` reflect this exact iteration's own prior attempt, if any, before rendering the appendix.
   - `FINDING_IDS="$(select_finding_batch "$PHASE_DIR/$ITERATION/findings-catalog.jsonl")"` (bounded to `document_fixer_batch_size`, blockers first) — the SAME path the spec-fixer appendix itself reads (`$PHASE_DIR/$ITERATION/findings-catalog.jsonl`), never a phase-relative alias.
   - Dispatch one `claude` subprocess for role `spec-fixer`. Inputs: `$SPEC_PATH`, `$FINDING_IDS`. The fixer edits the canonical spec in place and calls `record_finding_disposition` for every assigned ID (spec §17.3's six-value vocabulary — never a bare "fixed the majors" with no per-ID record). This role's timeout comes from the Models table via `role_timeout`.
   - `dispositions_complete "$PHASE_DIR/$ITERATION/findings-catalog.jsonl" $FINDING_IDS` — a fixer returning `DONE` with an undispositioned assigned ID is an orchestration bug (spec §17.3's "no assigned finding may disappear"); treat it as `CLAUDE_FAILED`/Mode 4.
   - `unset FINDING_IDS` immediately afterward — this round's reviewers (re-dispatched at step 1 of the next loop) never declare `finding_ids` in their own contract; a stale non-empty `$FINDING_IDS` left over from this fixer dispatch would scope-reject them (`ROLE_SCOPE_VIOLATION`) before they ever launch.
   - Capture `bytes_after="$(wc -c < "$SPEC_PATH")"`, tally this round's new/recurring/resolved/reopened/fix-regression counts from the catalog, and call `record_convergence_signals 3 "$ITERATION" "$bytes_before" "$bytes_after" ...`.
   - Call `divergence_check 3 "$ITERATION" "$PHASE_DIR/$ITERATION/findings-catalog.jsonl"`. On `yes:<reason>`: `record_event DIVERGENCE_DETECTED phase_name=spec-review divergence_reason=<reason> ...`; if this is the `divergent_round_cap`-th consecutive divergent round, call `divergent_round_cap_hit_before spec-review` (cookbook, P08) BEFORE recording anything. On `yes` (this gate already recorded one `DIVERGENT_ROUND_CAP_REACHED` earlier this run with no gate pass in between — the second consecutive cap hit): `record_event DIVERGENT_ROUND_CAP_REACHED ...` and HALT immediately — do NOT dispatch a third consolidation batch — surfacing `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (and every prior iteration's own catalog under `$PHASE_DIR/`) plus `$SPEC_PATH` for human review; the registry's own `divergent_round_cap` meaning is "automatic fixing stops" and a second miss proves it hasn't. On `no` (the first cap hit this gate): `record_event DIVERGENT_ROUND_CAP_REACHED ...` and dispatch exactly ONE consolidation-priority `spec-fixer` batch — re-populate `FINDING_IDS="$(select_finding_batch ...)"` first, since it was unset above and `spec-fixer` requires it — (same dispatch mechanism, prioritizing deletion/replacement/contradiction-removal/provenance-repair per spec §18.3 over addressing new findings) instead of the ordinary batch above — it is still bounded and still followed by step 1's `validate_artifact` and a full re-review; do not silently return to unlimited additive fixing.
   - Increment N. Loop from step 1 — the reviewers ALWAYS run again against the fixer's new revision; there is no iteration, including the cap, at which a fixer's own STATUS substitutes for a subsequent reviewer verdict (spec §18.2).
5. When the gate passes — `blockers=0` and (iterations 1–2: `majors=0`) or (iterations 3+: every open major dispositioned):
   - Dispatch one `claude` subprocess for role `summarizer-spec`. Inputs: `$FEATURE_FOLDER`. Outputs: `3-spec-review/spec-review-summary.md` and `3-spec-review/summarizer-status.md`. The summarizer records any deferred/accepted-risk majors (read from the final catalog) in the summary file.
   - You read only `summarizer-status.md`. On `verdict=DONE`, proceed to Phase 4. **The last successful gate action before Phase 4 is this reviewer-verified acceptance — never a fixer's own STATUS** (spec §18.1's final proof).

If iteration cap (`review_iteration_cap`) trips with any active reviewer still reporting an open BLOCKER, HALT and surface to user with residual findings paths and the spec path (`event=ITERATION_CAP_REACHED`). A cap reached with `blockers=0` but every remaining major already dispositioned is NOT a HALT — it passes per the relaxed gate (and sets the readiness verdict to `READY_WITH_NOTES`). A cap reached with an UNDISPOSITIONED major HALTs exactly like a blocker — the cap never manufactures a disposition nobody recorded.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: spec-reviewer-claude -->
# Role: spec-reviewer-claude

You are a spec reviewer invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder;iteration;spec_path`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `3`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION` — current iteration number (e.g. `01`)
- `$SPEC_PATH` — absolute path to the spec under review

## Behavior

1. Read `$SPEC_PATH` in full.
2. Evaluate against these dimensions:
   - Completeness: are all stated goals covered? Are non-goals explicit?
   - Internal consistency: do sections contradict each other?
   - Ambiguity: could any requirement be interpreted two ways? Would an implementer have to guess?
   - Scope: is this focused enough for one implementation plan, or does it need decomposition?
   - Acceptance criteria: are they testable?
   - Constraints / risk: are dependencies, threats, and constraints surfaced?
3. Classify EVERY finding into exactly one severity using this ladder:
   - **BLOCKER** — correctness or safety defect. Gate cannot pass.
   - **MAJOR** — missing requirement, internal contradiction, ambiguity that would cause an implementer to guess, or late-surfacing risk.
   - **MINOR / NIT** — wording, formatting, optional enhancement, style.
   Do NOT label obvious correctness/coverage issues as MINOR. If the spec is acceptable for the next SDLC step but has nits, set `verdict=PASS` with `blockers=0, majors=0, minors=N`.
4. Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above for the exact field list and how `finding_id`/`normalized_location`/`normalized_issue_key` are derived; you supply everything EXCEPT those three, which `ingest_findings` computes deterministically — never invent or guess them yourself):

```
Path: $FEATURE_FOLDER/3-spec-review/$ITERATION/claude-findings.jsonl
```

One JSON object per line, each with: `source_finding_id` (your own short local ID, e.g. `F1`), `reviewer_role: "spec-reviewer-claude"`, `vendor: "claude"`, `phase: "3"`, `iteration: "$ITERATION"`, `severity: "blocker"|"major"|"minor"`, `artifact_path: "$SPEC_PATH"`, `artifact_revision` (the spec's current sha256 or git sha), `location` (a human excerpt: heading text or `"L<N>"`), `line` (the 1-based line number your finding concerns), `issue_key` (a short stable slug for the underlying issue, e.g. `"missing-non-goals"`), `summary`, `evidence` (the exact excerpt), `required_change`, `provenance: "unknown"` (the ingestion helper refines this against prior rounds), `related_finding_ids: []`.

Findings: `$FEATURE_FOLDER/3-spec-review/$ITERATION/claude-findings.jsonl` (written per step 4 above).

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=spec-reviewer-claude phase=3 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the findings.jsonl file you wrote>
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
blockers: <int>
majors: <int>
minors: <int>
findings: <path to the findings.jsonl file you wrote, or none>
<!-- INCLUDE-END -->

Verdict rule: `verdict=PASS` iff `blockers=0 AND majors=0`. Otherwise `CHANGES_REQUESTED`.

Exit 0 only after the publisher exits 0.
<!-- END: spec-reviewer-claude -->

<!-- BEGIN: spec-reviewer-codex -->
# Role: spec-reviewer-codex

You are a dispatched subprocess. Do NOT load, read, or invoke Superpowers skills.
Do NOT read ~/.codex/skills, ~/.claude/skills, .claude/skills, or any skill
directory. This appendix is your complete instruction set.

Independence means independent judgment over the supplied artifact, not
independent repository discovery.

You are a cross-vendor spec reviewer (the "second opinion") invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context with the primary reviewer; produce an independent assessment.

## Role contract

- Required inputs: `feature_folder;iteration;spec_path`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `3`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$SPEC_PATH`

## Mode

`scoped` mode (spec-only). Filesystem allow-list: `$SPEC_PATH` plus your own output files inside `$FEATURE_FOLDER/3-spec-review/$ITERATION/`. Command budget: max 4 shell or read commands per dispatch.

## Forbidden reads

You may NOT read any of the following, even if you believe it would improve the review:

- source files (`*.py`, `*.ts`, `*.tsx`, `*.js`, etc.) anywhere in the repo
- test files
- transcripts (`$FEATURE_FOLDER/transcripts/*`)
- `RUN_LOG.md`
- `2-context-discovery/status.md` (the orchestrator passes you everything you need)
- previous reviewer findings (your verdict must be independent)
- skill directories (`~/.codex/skills`, `~/.claude/skills`, `.claude/skills`, any path containing `/skills/`)
- `~/.codex/config.toml`
- arbitrary repo files via broad `rg` or `find`

If the spec references existing implementation that you cannot verify under this allow-list, surface that as a MAJOR finding ("spec references existing implementation X but reviewer cannot verify without code access; recommend spec author either inline the relevant detail or mark for code-aware review") instead of breaking the allow-list.

## Behavior

1. Read `$SPEC_PATH` in full (counts as 1 of your 4 commands).
2. Evaluate against these dimensions using the BLOCKER / MAJOR / MINOR severity ladder (same definitions as `spec-reviewer-claude`):
   - Completeness: are all stated goals covered? Are non-goals explicit?
   - Internal consistency: do sections contradict each other?
   - Ambiguity: could any requirement be interpreted two ways?
   - Scope: is this focused enough for one implementation plan?
   - Acceptance criteria: are they testable?
   - Constraints / risk: are dependencies, threats, and constraints surfaced?
3. Classify every finding into exactly one severity. Do NOT label obvious correctness/coverage issues as MINOR.

## Findings budget

Report every BLOCKER and MAJOR you find; cap MINOR findings at 10; keep each finding under 150 words.

Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above for the exact field list; you supply everything except `finding_id`/`normalized_location`/`normalized_issue_key`, which `ingest_findings` derives deterministically). Findings: `$FEATURE_FOLDER/3-spec-review/$ITERATION/codex-findings.jsonl`. Each object: <!-- INCLUDE-BEGIN: finding-record-schema reviewer_role=spec-reviewer-codex vendor=codex phase=3 artifact_path_spec='`artifact_path: "$SPEC_PATH"`' artifact_revision_spec='`artifact_revision`' line_spec='`line`' evidence_spec='`evidence`' -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=spec-reviewer-codex phase=3 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the findings file you wrote>
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
blockers: <int>
majors: <int>
minors: <int>
findings: <path to the findings file you wrote, or none>
<!-- INCLUDE-END -->

Verdict rule: `verdict=PASS` iff `blockers=0 AND majors=0`.

Exit 0 only after the publisher exits 0.
<!-- END: spec-reviewer-codex -->

<!-- BEGIN: spec-fixer -->
# Role: spec-fixer

You are a spec patcher invoked as a fresh subprocess. You have no shared context.

## Role contract

- Required inputs: `feature_folder;iteration;spec_path;finding_ids`
- Optional inputs: `continuation_path;declared_foreign_changes`
- Outputs: `status;progress.jsonl`
- Allowed verdicts: `DONE;BLOCKED`
- Required status fields: `common_v2;changed_paths;finding_dispositions`
- Checkpoint kind: `document-fixer`
- Phases: `3`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION` — the iteration whose findings you are addressing
- `$SPEC_PATH`
- `$FINDING_IDS` — the specific canonical finding identifiers assigned to you this iteration (a space-separated list, never the full findings catalog)
- `$CONTINUATION_PATH` — absolute path to a prior, still-partial attempt's own `progress.jsonl` (only set when you are a continuation; empty otherwise)
- `$DECLARED_FOREIGN_CHANGES` — space-separated pre-existing dirty paths the current write lease already declared as not yours (optional; only meaningful alongside `$CONTINUATION_PATH`)

You are assigned at most `document_fixer_batch_size` finding IDs at a time (see the `document_fixer_batch_size` policy) — never the unbounded full findings catalog across every iteration.

## Behavior

1. If `$CONTINUATION_PATH` is set, read it first: it is a prior attempt's own `progress.jsonl`. Resume from its last recorded `next_unit` — never re-patch a finding its records already mark disposed. Reconcile at most the one dirty (`state: partial`) finding, if any, using `$DECLARED_FOREIGN_CHANGES` to recognize which currently-dirty paths are pre-existing, not yours.
2. Read ONLY the findings named in `$FINDING_IDS` from `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (`jq --arg id ... 'select(.finding_id==$id)'`, one lookup per assigned ID) — never the full catalog, and never an out-of-batch finding (a later iteration's job).
3. Read `$SPEC_PATH`.
4. Patch the spec in place for every BLOCKER and MAJOR among your assigned IDs. Use Edit — prefer simplifying, replacing, or deleting redundant text over appending another rule (spec §18.4).
5. Address assigned MINOR findings only when the change is trivial and improves clarity; otherwise dispose them `already_satisfied` with a one-line reason (they are allowed to remain).
6. Where reviewers disagree on the same finding, prefer the more conservative reading (more explicit, more constrained, less ambiguous).
7. Where a finding requires a decision no one but the user can make, do NOT guess: dispose it `blocked` and set the overall verdict to `BLOCKED`.
8. Do not restructure spec text the finding did not flag. If fixing an assigned finding surfaces an UNRELATED opportunity (a real improvement the finding itself did not flag), do NOT fold it into this pass — note it in your human-facing summary as a follow-up for a human to triage later; only edits addressing an assigned finding ID belong in this pass (spec §17.3/§18.4).
9. Inspect adjacent sections, references, and acceptance criteria your edit may have made stale (ripple check), per spec §18.4.
10. For EVERY assigned finding ID, record exactly one disposition (spec §17.3's six-value vocabulary: `fixed`, `subsumed_by:<finding_id>`, `already_satisfied`, `blocked`, `accepted_risk:<decision_id>`, `deferred:<followup_id>`) by calling `record_finding_disposition` — the generated runtime's own disposition writer, never a hand-written status change:

<!-- lint: snippet -->
```bash
source "$RUNTIME_DIR/develop-it-runtime.sh"
record_finding_disposition "$PHASE_DIR/$ITERATION/findings-catalog.jsonl" "<finding id>" \
  "<fixed|subsumed_by:<finding_id>|already_satisfied|blocked|accepted_risk:<decision_id>|deferred:<followup_id>>" \
  "<one-line evidence>"
```

After every finding disposition, ALSO call `checkpoint_append` -- the generated runtime's own checkpoint writer (spec S10.1; never hand-write the JSON line yourself, the same "one sanctioned writer" discipline the STATUS publisher already enforces for STATUS):

<!-- lint: snippet -->
```bash
checkpoint_append "$PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl" "$DISPATCH_ID" spec-fixer \
  sequence="<next integer, starting at 1>" unit_type=finding unit_id="<finding id>" \
  state=completed artifact_path="$SPEC_PATH" \
  artifact_sha256="<sha256 of \$SPEC_PATH after this disposition>" commit_sha=null \
  verification=PASS next_unit="<next unresolved finding id in this batch, or the literal word null>"
```

`DONE` requires every ID in `$FINDING_IDS` to have a disposition (spec §17.3's "no assigned finding may disappear") — never claim full completion from a partial batch.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=spec-fixer phase=3 iteration='$ITERATION' verdicts='DONE | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
changed_paths: [path, ...]
finding_dispositions: [finding_id=<disposition>, ...]
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: spec-fixer -->

<!-- BEGIN: summarizer-spec -->
# Role: summarizer-spec

You are a gate summarizer invoked as a fresh subprocess. You have no shared context.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `run_log`
- Outputs: `summary;status`
- Allowed verdicts: `DONE`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `3`

## Inputs

- `$FEATURE_FOLDER`
- `$FEATURE_FOLDER/RUN_LOG.md` (you read this for failover context)

## Behavior

1. Enumerate this gate's iteration directories under `$FEATURE_FOLDER/3-spec-review/` — real iterations are two-digit numeric directories (`01`, `02`, ... — never the retired `iteration-*` glob), each holding `findings-catalog.jsonl` plus an `attempts/` subdirectory.
2. For each iteration, read `findings-catalog.jsonl` — the merged, canonical catalog `ingest_findings` wrote (spec §17.2) — for that iteration's severity counts and per-finding disposition/status. NEVER read the raw per-reviewer `*-findings.jsonl` files for counting: they are pre-union and double-count anything both reviewers reported, exactly the union the catalog already computes. For each reviewer's own verdict and codex-availability signal, read its attempt-scoped `STATUS.md` under `attempts/<dispatch-id>/` (locate the dispatch id from `RUN_LOG.md`'s own `DISPATCH_COMPLETED` entries naming this `phase`/`iteration`/`role`).
3. Read `$FEATURE_FOLDER/RUN_LOG.md`. Filter entries where `event=CODEX_UNAVAILABLE` AND `phase=3` (spec review). For each such entry, capture the `failure_mode=<n>` and the iteration number. These give you the reason Codex was unavailable.
4. Aggregate statistics:
   - Number of iterations run.
   - Total findings per severity (BLOCKER / MAJOR / MINOR) per iteration.
   - Net changes the spec-fixer made each iteration (read each finding's `.disposition`/`.status` from that iteration's own `findings-catalog.jsonl` — never a `spec-fixer-status.md` alias, which was never a real path).
   - Residual MINOR/NIT items at the final iteration.
   - `partial_review = true` if ANY iteration was Claude-only (codex verdict absent), else `false`.
   - `codex_unavailable_reason` if any CODEX_UNAVAILABLE event applies: format `mode=<n>;iteration=<NN>` (concatenate multiple events with `|` if needed). If no event but codex verdict is missing, use `mode=unknown`.
<!-- INCLUDE-BEGIN: summarizer-usage-aggregation phase=3 -->
<!-- INCLUDE-END -->
6. Write the summary file at `$FEATURE_FOLDER/3-spec-review/spec-review-summary.md` with:
   - Iteration count.
   - Findings counts table per iteration.
   - Deferred MAJOR list — MAJOR findings still open (from the final catalog) at the passing iteration, each carrying an explicit `deferred:<followup_id>` or `accepted_risk:<decision_id>` disposition (spec §17.3) — never a major that simply went unaddressed. Non-empty ONLY when the gate passed under the relaxed rule (final iteration ≥ 3, `blockers=0`, every open major dispositioned); empty for a strict pass (final iteration ≤ 2 with `majors=0`). For each deferred major, record its finding_id, source reviewer, location, disposition, and one-line summary so the readiness writer can surface it. These majors WERE re-reviewed — the fixer's dispositioning dispatch was followed by another full reviewer round per spec §18.2, same as every other iteration; note that in the list.
   - Residual MINOR/NIT list.
   - `partial_review` flag and `codex_unavailable_reason` (if any), with one sentence of human-readable context per mode (e.g. "mode=5a: Codex hit a rate limit in iteration 02"; for `mode_shape: 5b` say the account hit a spend ceiling and that no retry can clear it).
   - Final verdict (`PASS`) and final iteration number. Note whether the pass was strict (converged by iteration 2) or relaxed (final iteration ≥ 3); record deferred majors separately, only when present.
<!-- INCLUDE-BEGIN: summarizer-usage-table-format -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=summarizer-spec phase=3 iteration=00 verdicts=DONE reason='<one line, or the literal word null>' -->
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
<!-- END: summarizer-spec -->
