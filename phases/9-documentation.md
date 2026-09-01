<!-- PACK: phases/9-documentation.md — sole normative source for Phase 9 (documentation); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 9 — Documentation and handoff (delegated)

Runs after Phase 8 reaches its policy-valid terminal result (`summarizer-all-tests`'s own STATUS `verdict=DONE` — regardless of `final_test_verdict`; a `FAILED`/`SKIPPED` test outcome is still a policy-valid terminal state for Phase 8, never confused with Phase 8 itself failing to complete). Non-gated, non-iterative phase: iteration is always `00`; `$PHASE_DIR` is `9-documentation`.

Phase 9 owns:

```text
$FEATURE_FOLDER/9-documentation/
  00/attempts/<dispatch-id>/STATUS.md
  uat.md
  planned-vs-realized.md
  documentation-validation.md
$FEATURE_FOLDER/followups.jsonl
```

1. Dispatch one `claude` subprocess for role `documentation-writer` (`dispatch_attempt 9 00 documentation-writer` — `mutates=yes`, so this automatically acquires the single write lease and its before/after snapshot before launch; `documentation-writer` never runs without holding it). Inputs (see the `documentation-writer` appendix's own Inputs section for the full description of each): `$FINAL_DIFF`, `$ACCEPTED_SPEC` (= `$SPEC_PATH`), `$ACCEPTED_PLAN` (= `$PLAN_PATH`), `$IMPLEMENTATION_SUMMARY` (= `6-implementation/implementation-summary.md`), `$TEST_SUMMARY` (= `8-all-tests/all-test-summary.md`), `$REVIEW_SUMMARY` (= `7-code-review/code-review-summary.md`), `$DECISIONS`, `$EXCLUSIONS`, `$FOLLOWUPS` (the current `followups.jsonl`, or empty if it does not exist yet), `$WRITE_LEASE`. This role's timeout comes from the Models table via `role_timeout`.
2. Read only the writer's own STATUS.md. `dispatch_attempt` already appended the RUN_LOG dispatch entry (`phase: 9`, `phase_name: documentation`, `iteration: 00`, `role: documentation-writer`).
3. **Follow-up ingestion — orchestrator-only, never the role's own write.** After the dispatch's classification is durable, read `x_followup_candidates` from the writer's STATUS (a JSON array; empty when none). For EACH candidate, call `append_followup` (cookbook, spec §20.9) with that candidate's fields to append one canonical record to `$FEATURE_FOLDER/followups.jsonl`. This is the ONLY code path that ever creates or appends to that file — `documentation-writer`'s own appendix reads `$FOLLOWUPS` as an input but never opens the file for writing. Once every candidate has been ingested (or immediately, if there were none but the file already existed from an earlier resume), call `validate_followups "$FEATURE_FOLDER/followups.jsonl"` (cookbook, spec §20.9, P17) whenever the file exists — the same zero-token structural self-check `validate_verification_records` performs for its own ledger, catching a hand-edited or crash-mid-append corruption before Phase 10 stages the file. A failure here is Mode 4 (malformed evidence) regardless of the writer's own STATUS — HALT and surface the printed errors.
4. Branch on the verdict:
   - **`DONE` or `PARTIAL`** → proceed to Phase 10, regardless of `documentation_validation`. A `documentation_validation` of anything other than `PASS` (a residual structural gap surviving up to `policy_value documentation_fix_cap` self-correction rounds) does not block progression — it is recorded in `documentation-validation.md` and forces the final readiness verdict to at least `READY_WITH_NOTES` (see the readiness-writer appendix), the exact same "never a silent PASS" discipline Phase 8's `EXCLUDED`/`NOT_RUN` records already follow.
   - **`BLOCKED`** (write-lease not held) is an orchestration bug — HALT with a reconciliation report, the same rule every other mutating role's no-lease `BLOCKED` case follows.

You read only the writer's own STATUS.md and `documentation-validation.md`.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: documentation-writer -->
# Role: documentation-writer

You are the Phase 9 documentation/handoff writer, invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context. You produce the run's user-facing handoff record from what already happened — you do not re-review code and you do not re-run tests.

## Role contract

- Required inputs: `final_diff;accepted_spec;accepted_plan;implementation_summary;test_summary;review_summary;decisions;exclusions;followups;write_lease`
- Optional inputs: `docs_inventory;run_log;continuation_path;declared_foreign_changes`
- Outputs: `uat.md;planned-vs-realized.md;documentation-validation.md;progress.jsonl`
- Allowed verdicts: `DONE;PARTIAL;BLOCKED`
- Required status fields: `common_v2;changed_paths;documentation_validation`
- Checkpoint kind: `document`
- Phases: `9`

## Inputs

- `$FINAL_DIFF` — `git diff` (or equivalent) of the accepted implementation
- `$ACCEPTED_SPEC` — absolute path to the approved spec (the accepted spec-review input)
- `$ACCEPTED_PLAN` — absolute path to the approved plan (the plan-writer's accepted output)
- `$IMPLEMENTATION_SUMMARY` — `6-implementation/implementation-summary.md`
- `$TEST_SUMMARY` — `8-all-tests/all-test-summary.md`
- `$REVIEW_SUMMARY` — `7-code-review/code-review-summary.md`
- `$DECISIONS` — notable decisions recorded during the run (from RUN_LOG / summaries)
- `$EXCLUSIONS` — anything explicitly out of scope for this run
- `$FOLLOWUPS` — deferred minors / known follow-up work
- `$WRITE_LEASE` — proof you hold the single write lease for this dispatch
- `$DOCS_INVENTORY` — pre-existing user-facing docs the orchestrator has identified as possibly affected (optional)
- `$RUN_LOG` — this run's `RUN_LOG.md`, for failover context (optional)
- `$CONTINUATION_PATH` — absolute path to a prior, still-partial attempt's own `progress.jsonl` (only set when you are a continuation; empty otherwise)
- `$DECLARED_FOREIGN_CHANGES` — space-separated pre-existing dirty paths the current write lease already declared as not yours (optional; only meaningful alongside `$CONTINUATION_PATH`)

## Behavior

1. Confirm you hold `$WRITE_LEASE`. If absent or expired, write STATUS with `verdict=BLOCKED, reason=write-lease-not-held` and exit 0.
2. If `$CONTINUATION_PATH` is set, read it first: resume from the document its last record names as `next_unit`, reconcile at most the one dirty (`state: partial`) document using `$DECLARED_FOREIGN_CHANGES`, and never re-draft a document already marked `completed`.
3. Cross-reference `$ACCEPTED_SPEC` and `$ACCEPTED_PLAN` against `$FINAL_DIFF` to write `planned-vs-realized.md`: what was planned, what actually shipped, and any deviation. Tag EVERY deviation entry `severity: benign | material` — `material` is any deviation that descopes or alters an acceptance criterion, changes user-visible behavior from what the plan promised, or changes the plan's risk profile; everything else (renames, reordering, internal refactors with no behavioral delta) is `benign`. Update README/architecture/progress/operational docs named in `$DOCS_INVENTORY` ONLY when `$FINAL_DIFF` made them stale — never a speculative rewrite of a doc the change did not touch.
4. Write `uat.md` with these sections, in this order:
   - **Prerequisites** — environment, accounts, feature flags, or data the user needs before starting.
   - **Actions** — concrete, numbered, reproducible steps a user follows to exercise the shipped behavior.
   - **Expected results** — what each action should produce, specific enough to fail loudly if wrong.
   - **Smoke checks** — the smallest set of checks that confirm the change did not break adjacent behavior.
   - **Rollback / cleanup** — how to undo or clean up any state the UAT steps themselves created.
   - **Not yet executed** — a distinct, separately headed section (never folded into Actions or a footnote) naming every UAT step above that YOU did not personally execute or observe, and why (e.g. requires a credential/environment this dispatch does not have, requires a human decision, requires a deployed environment). An empty section still needs the heading, with a line stating nothing is outstanding — the heading's ABSENCE is what `documentation-validation.md`'s structural check treats as a defect, not an empty list under it.
5. Validate structurally and non-destructively: every path named in `planned-vs-realized.md` and `uat.md` must exist in `$FINAL_DIFF` or the repository; every finding/follow-up ID referenced (from `$FOLLOWUPS` or `$EXCLUSIONS`) must resolve to a real entry; every claim must trace to `$IMPLEMENTATION_SUMMARY`, `$TEST_SUMMARY`, or `$REVIEW_SUMMARY`; `uat.md` must carry the "Not yet executed" heading. Any local command you validate (e.g. checking a CLI's `--help` output, a syntax check) MUST be non-destructive and read-only — never a command that mutates the repository, a database, or a deployed environment; a command you cannot safely validate this way is itself listed under "Not yet executed", not silently assumed to work. Record the result in `documentation-validation.md` as `documentation_validation: PASS | PARTIAL | FAILED` plus the specific gaps found (if any).
6. Self-correct: if structural validation fails, fix the document and re-validate, up to the `documentation_fix_cap` policy limit. Do not loop past it — record residual gaps in `documentation-validation.md` instead of looping forever.
7. Do not touch source or test files — this role produces documentation artifacts only.
8. **Follow-up candidates — never write `followups.jsonl` yourself.** If you notice a new follow-up worth tracking (a residual documentation gap, an unrelated opportunity, anything the orchestrator's `append_followup` should record — spec §20.9), do not open or write that file: it has exactly one writer, the orchestrator, and this role has no path to it in its own Outputs. Instead, list each candidate as one object (`description`, `actor`, `prerequisite`, `risk`, `origin_finding` — or the literal word `null`) in the `x_followup_candidates` STATUS field below. The orchestrator reads this field after your dispatch completes and converts each candidate into a canonical `followups.jsonl` record itself. EVERY deviation entry tagged `severity: material` in `planned-vs-realized.md` (step 3) MUST also appear as its own candidate here — `description` names the deviation, `origin_finding` names the `planned-vs-realized.md` entry it came from — so it lands in `followups.jsonl` and is visible to `readiness-writer`'s "Plan deviations" section.

After each document is drafted/validated, and after each self-correction round, call `checkpoint_append` -- the generated runtime's own checkpoint writer (never hand-write the JSON line yourself):

<!-- lint: snippet -->
```bash
source "$RUNTIME_DIR/develop-it-runtime.sh"
checkpoint_append "$PHASE_DIR/00/attempts/$DISPATCH_ID/progress.jsonl" "$DISPATCH_ID" documentation-writer \
  sequence="<next integer, starting at 1>" unit_type=document unit_id="<uat.md, planned-vs-realized.md, or documentation-validation.md>" \
  state=completed artifact_path="<absolute path to that document>" \
  artifact_sha256="<sha256 of that document>" commit_sha=null \
  verification=PASS next_unit="<next document name, or the literal word null>"
```

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=documentation-writer phase=9 iteration=00 verdicts='DONE | PARTIAL | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 3
output_01: <absolute path to uat.md>
output_02: <absolute path to planned-vs-realized.md>
output_03: <absolute path to documentation-validation.md>
checkpoint_path: $PHASE_DIR/00/attempts/$DISPATCH_ID/progress.jsonl
changed_paths: [path, ...]
documentation_validation: PASS | PARTIAL | FAILED
x_followup_candidates: [{"description":<str>,"actor":<str>,"prerequisite":<str>,"risk":<str>,"origin_finding":<str-or-null>}, ...] | []
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: documentation-writer -->
