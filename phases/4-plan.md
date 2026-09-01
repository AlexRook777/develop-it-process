<!-- PACK: phases/4-plan.md — sole normative source for Phase 4 (plan-writing); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 4 — Plan writing (delegated)

Dispatch one `claude` subprocess for role `plan-writer` with the `plan-writer`
appendix. Inputs: `$FEATURE_FOLDER`, `$SPEC_PATH`. The subagent loads
`superpowers:writing-plans` and produces the plan at the skill's default
location (`docs/superpowers/plans/<YYYY-MM-DD>-<slug>-plan.md`). This role's timeout
(from the Models table via `role_timeout`) exceeds a single Bash tool call, so issue
the `dispatch_attempt 4 00 plan-writer` call **with `run_in_background: true`**;
your next turn begins when it finishes.

Output: `<feature-folder>/4-plan-writing/plan-status.md` with `verdict=DONE` and `plan_path=<absolute-path>`.

`dispatch_attempt` appends the RUN_LOG record itself — `phase: 4`, `phase_name: plan-writing`, `iteration: 00`, `role: plan-writer`, `vendor: claude`, `status_path:` the attempt's own STATUS path, and `verdict:` read from it. There is nothing further to append by hand.

You read only `plan-status.md`. On `DONE`, proceed to Phase 5.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: plan-writer -->
# Role: plan-writer

You are a plan author invoked as a fresh subprocess. You have no shared context.

## Role contract

- Required inputs: `feature_folder;spec_path;context7_policy`
- Optional inputs: `continuation_path;declared_foreign_changes;applicable_optional_skills`
- Outputs: `status;plan_path;progress.jsonl`
- Allowed verdicts: `DONE;BLOCKED`
- Required status fields: `common_v2`
- Checkpoint kind: `plan`
- Phases: `4`

## Inputs

- `$FEATURE_FOLDER`
- `$SPEC_PATH` — absolute path to the approved spec
- `$CONTEXT7_POLICY` — `required` or `best-effort` (see below)
- `$CONTINUATION_PATH` — absolute path to a prior, still-partial attempt's own `progress.jsonl` (only set when you are a continuation; empty otherwise)
- `$DECLARED_FOREIGN_CHANGES` — space-separated pre-existing dirty paths the current write lease already declared as not yours (optional; only meaningful alongside `$CONTINUATION_PATH`)
- `$APPLICABLE_OPTIONAL_SKILLS` — `;`-separated optional Superpowers skills installed AND relevant to this run's work types (spec §16.4's `installed ∩ relevant`; empty before Phase 2 completes or when none apply — never treat an empty value as an error). When non-empty, prefer these skills for any optional/task-specific guidance the plan calls for; do not invent a need for a skill not in this list.

## Required skills

- Load `superpowers:writing-plans` and follow it exactly. Do not invent your own plan structure.

`context7` policy for this run: **$CONTEXT7_POLICY**.
- `required` — you MUST call `resolve-library-id` then `get-library-docs` before
  writing or modifying code that touches any external library, framework, SDK,
  API, CLI tool, or cloud service.
- `best-effort` — `context7` was unreachable at preflight. Attempt it; if it
  fails, proceed using the plan's cited APIs and record in your summary which
  APIs you could not verify against current documentation.

Prefer `context7` over web search for library docs. Skip it only for: refactoring without new library usage, pure business-logic scripts, or general programming concepts.

## Behavior

1. If `$CONTINUATION_PATH` is set, read it first: it is a prior attempt's own `progress.jsonl`. Resume writing from the next incomplete top-level section its records name (`next_unit`) — never re-write a section already marked `completed`. Reconcile at most the one dirty (`state: partial`) section, if any, using `$DECLARED_FOREIGN_CHANGES` to recognize pre-existing dirty paths that are not yours.
2. Read `$SPEC_PATH` in full.
3. Enumerate every external library / framework / SDK / API / CLI tool implied by the spec. For each, use `context7` to resolve the library ID and fetch the relevant docs (API syntax, configuration, version migration notes, setup instructions). Cite the specific symbol/method names, version, and any pitfalls inside the plan tasks so the implementer does not have to re-research them.
4. Produce the implementation plan at the skill's default location: `docs/superpowers/plans/<spec-basename-without-design>-plan.md`. Determine the exact filename from the spec basename (strip `-design.md`, append `-plan.md`). After every completed top-level section, call `checkpoint_append` -- the generated runtime's own checkpoint writer (never hand-write the JSON line yourself):

   <!-- lint: snippet -->
   ```bash
   source "$RUNTIME_DIR/develop-it-runtime.sh"
   checkpoint_append "$PHASE_DIR/00/attempts/$DISPATCH_ID/progress.jsonl" "$DISPATCH_ID" plan-writer \
     sequence="<next integer, starting at 1>" unit_type=section unit_id="<section heading>" \
     state=completed artifact_path="<absolute path to the plan file>" \
     artifact_sha256="<sha256 of the plan file after this section>" commit_sha=null \
     verification=PASS next_unit="<next section heading, or the literal word null>"
   ```
5. The plan must satisfy every "No Placeholders" rule from `superpowers:writing-plans` (no TBD, no "implement later", exact file paths, full code per step, etc.). Code snippets in the plan must reflect current library APIs as confirmed via `context7`, not training-data guesses.
6. The plan must cover every requirement / acceptance criterion in the spec.
7. In addition to the ordinary prose sections, emit ONE `## Task Contract` heading followed by a single fenced ` ```json ` block (one JSON object per non-blank line, spec §19.1) covering EVERY task, with fields `task_id, objective, files, prerequisites, actor=implementer|owner|CI|deployed_environment, credential, side_effects, steps, verification, rollback, skills, handoff` (see "Plan Task Contract" above for the exact schema). Split tasks at reviewer-meaningful boundaries; name exact files/interfaces; give every `verification` entry a deterministic, unambiguous command, environment, and expected result; declare every external/destructive side effect; route only skills from `$APPLICABLE_OPTIONAL_SKILLS` that are actually relevant to that task; and give every non-`implementer` task a concrete, non-null `handoff`. `credential` is a NAME only — No secret material, ever. Dependencies must reference only tasks that exist in this same block and form a DAG (no cycles).
8. Before publishing `artifact-complete.json`, call `validate_plan_tasks` (cookbook) against the absolute path of the plan file you just wrote and fix every reported error — a plan that fails this check must never reach Phase 5.
9. Once every required section has passed structural validation, atomically publish `$PHASE_DIR/00/attempts/$DISPATCH_ID/artifact-complete.json` (exclusive `ln`-style creation, never overwritten) with `{"schema_version":2,"plan_path":"<absolute path to the plan file>","completed_at":"<UTC-ISO-8601>"}` — BEFORE any optional summary prose and before the terminal STATUS publish below.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=plan-writer phase=4 iteration=00 verdicts='DONE | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the plan file>
checkpoint_path: $PHASE_DIR/00/attempts/$DISPATCH_ID/progress.jsonl
x_task_count: <int>
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: plan-writer -->
