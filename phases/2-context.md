<!-- PACK: phases/2-context.md — sole normative source for Phase 2 (context-discovery); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 2 — Context discovery (delegated)

Dispatch one `claude` subprocess for role `context-discovery`. The subagent:
- Lists available Superpowers skills in the environment (marketplace-agnostic — whatever plugin roots are actually configured, not a hard-coded location).
- Reads `CLAUDE.md` (and any nested `CLAUDE.md` files).
- Identifies project conventions relevant to the SDLC flow, AND this run's work types / project capabilities (e.g. "has a test suite", "touches a web frontend", "uses a specific framework") — from which it reports `relevant_skills` (+ `relevant_skills_reasons`, one reason per skill) in its own STATUS: the "relevant" side of spec §16.4's applicability computation. It does NOT compute the intersection itself — see below.
- Writes a short context summary file at `<feature-folder>/2-context-discovery/status.md` with `verdict=READY` plus the resolved skill names per phase.

**Optional-skill applicability (spec §16.4) is computed by the orchestrator,
not the subagent, and recomputed fresh in every later phase's shell** —
`reconstruct_durable_inputs` (see "Durable input reconstruction" in the core document's cookbook index) sets
`$APPLICABLE_OPTIONAL_SKILLS` from `installed ∩ relevant`: `OPTIONAL_SKILLS`
(Phase 1's `optional_skills_present` record) intersected with this phase's
own read of `2-context-discovery/status.md`'s `relevant_skills` field, via
the `applicable_optional_skills` cookbook helper. There is nothing to do at
Phase 2 itself beyond the dispatch above; the plan writer (Phase 4) is the
first real consumer — it receives `$APPLICABLE_OPTIONAL_SKILLS` as a
rendered appendix input (its own reasons are `relevant_skills_reasons` from
Phase 2's STATUS, carried unchanged: an "applicable" skill's reason IS the
"relevant" reason that survived the intersection). Implementation (Phase 6)
passes only the task-relevant subset of it to each worker, recording actual
usage per task in its own summary — an installed skill NOT called for by
this run's work types is never passed down, and a relevant skill NOT
installed is never treated as missing (optional absence never halts, per
spec §16.4).

Before rendering the appendix, resolve and export the role→model map so the
dispatched session can copy it verbatim instead of calling `role_model` itself
(it has no access to the orchestrator's shell functions):

<!-- lint: snippet -->
```bash
RESOLVED_MODELS="$(resolved_models_block)"
export RESOLVED_MODELS
```

Because `$RESOLVED_MODELS` is multi-line, this is exactly the case `sed`
substitution cannot handle — it is why `render_prompt` uses python3.

This role's timeout comes from the Models table via `role_timeout`.

You read only `2-context-discovery/status.md`. On `READY`, proceed to Phase 3. On any other verdict, HALT and surface to user.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: context-discovery -->
# Role: context-discovery

You are dispatched by the develop-it orchestrator to discover the project's environment, skills, and conventions. You have no shared context.

## Role contract

- Required inputs: `feature_folder;resolved_models`
- Optional inputs: `none`
- Outputs: `status`
- Allowed verdicts: `READY;BLOCKED`
- Required status fields: `common_v2;relevant_skills;relevant_skills_reasons`
- Checkpoint kind: `none`
- Phases: `2`

## Inputs

- `$FEATURE_FOLDER`

## Required skill

Use only read-only inspection. You do NOT load `subagent-driven-development` here; treat this prompt as your full instruction set.

## Tasks

1. Enumerate Superpowers skills available in the environment. Use the platform's skill-listing mechanism (marketplace-agnostic — whatever plugin roots are actually configured, not a hard-coded location).
2. Read the root `CLAUDE.md` and any nested `CLAUDE.md` files relevant to the SDLC flow. Summarize project conventions in one paragraph.
3. Inspect the input spec path (the orchestrator records this in `RUN_LOG.md` and the feature folder name encodes the slug — derive the spec path: take the feature folder name, strip `-artifacts`, append `-design.md`, prepend `docs/superpowers/specs/`). Confirm the spec exists. Do NOT read its body.
4. Identify this run's work types / project capabilities from what you observed above (e.g. "has a test suite", "touches a web frontend", "uses a specific framework") and, from those, list every OPTIONAL Superpowers skill from step 1's enumeration that is genuinely relevant to THIS run (spec §16.4's "relevant" side of `installed ∩ relevant` — the orchestrator computes the intersection itself once your STATUS is durable; you do not compute it). For each relevant skill, give a one-line reason naming the specific work type/capability that makes it relevant. Report the skill list as `relevant_skills` and the parallel one-line reasons (same order, same count) as `relevant_skills_reasons`. An empty list is legitimate and never blocks `READY` — optional-skill absence never halts (spec §16.4).
4. Copy the resolved role→model map below verbatim into your STATUS file under
   `resolved_models:`. It was produced by the orchestrator from the Models table.
   Do NOT re-derive, alias, or substitute ids, and do NOT consult
   `~/.codex/config.toml`. **Never** substitute any of `gpt-5.1-codex-max`,
   `gpt-5-codex-max`, `o3`, `o3-mini`, or any other `*-codex-max` / `o*` id for a
   codex role — those require an OpenAI API key and will 400 on a ChatGPT-account
   auth:

   $RESOLVED_MODELS

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=context-discovery phase=2 iteration=00 verdicts='READY | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: null
x_available_skills: [skill, ...]
x_project_conventions: <one paragraph>
x_resolved_models: <one role:model-id pair per line, exactly as supplied in $RESOLVED_MODELS>
x_spec_path: <absolute>
relevant_skills: [skill1, skill2, ...] (empty list if none are relevant)
relevant_skills_reasons: [reason1, reason2, ...] (same order and count as relevant_skills)
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: context-discovery -->
