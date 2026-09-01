<!-- PACK: phases/7-code-review.md — sole normative source for Phase 7 (code-review); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 7 — Code review gate (delegated, two reviewers, severity-gated)

Same shape as Phase 3 (`phases/3-spec-review.md`), applied to the implementation diff and behavior.

### Step 7.0 — Per-phase preflight

Before iter 01's first reviewer dispatch (the gate's first work dispatch — see "Terminology gloss" in Resumability), run the per-phase preflight:

1. `mkdir -p <feature-folder>/7-code-review/preflight`.
2. Reset `codex_available = true` for the phase.
3. If `codex_disabled_by_user = true` (run-scoped flag from Phase 1; reconstitute by scanning RUN_LOG per the rule in "Run-scoped user opt-out"):
   - Dispatch `preflight-claude` only, via `dispatch_attempt 7 00 preflight-claude`.
   - Append one `event=CODEX_SKIPPED_BY_USER_CONSENT` entry to `RUN_LOG.md` with `phase: 7`, `phase_name: code-review`, `iteration: 00`, `role: preflight-codex`, `vendor: codex` (see RUN_LOG additions for the full block shape).
   - Set `codex_available = false`.
4. Otherwise, dispatch `preflight-claude` and `preflight-codex` **fully in parallel** via `dispatch_parallel 7 00 preflight-claude preflight-codex` (the "Reviewer parallelization" cookbook pattern). Each subprocess publishes its own STATUS to its own attempt-scoped path under `$FEATURE_FOLDER/7-code-review/00/attempts/` — `dispatch_attempt` mints a distinct attempt id per role, so the two parallel writes never collide.
5. After **both** probes return (or only the claude probe in the opt-out case), copy each STATUS file from its real attempt-scoped path to the phase-local readable alias:

   <!-- lint: snippet -->
   ```bash
   copy_preflight_alias 7 "$FEATURE_FOLDER/7-code-review/preflight"
   ```

   (`copy_preflight_alias`, cookbook — P21/Task 11.)

   Either copy is a no-op if the corresponding source is absent (see "File policy for non-READY paths" in Step 1.0).

6. `dispatch_parallel`/`dispatch_attempt` already appended each probe's own RUN_LOG dispatch entry (`phase: 7`, `phase_name: code-review`, `iteration: 00`, `role: preflight-claude` or `preflight-codex`, `vendor: claude` or `codex`, `status_path:` its REAL attempt-scoped path) — read the verdict from the copied alias `7-code-review/preflight/<vendor>-check-status.md` (or `verdict: none` if the probe was skipped via consent or failed without producing STATUS).
7. Branch on the verdicts: same procedure as Step 3.0 item 7 (the canonical per-phase preflight verdict branch, `phases/3-spec-review.md` — P21/Task 11), substituting `phase: 7`, `phase_name: code-review`, `Phase 7`, and `p07-i00-preflight-*` throughout, PLUS this Phase-7-only delta (spec §16.5) — a one-vendor Phase 7 additionally requires an explicit, durable acceptance of the degraded coverage that the other two gates do not. (Requires `phases/3-spec-review.md`, Read it now if not already read this turn.)
   - **On EITHER degradation path that lands on `codex_available = false`** — the codex-probe-failure bullet (Modes 0/1/2/3/4/5, after the re-probe rule) OR the codex-`MISSING_SKILLS`/`UNCERTAIN`-confirmed bullet (after its own re-probe rule) — append, before proceeding to step 1 of the iteration loop: `record_event DEGRADED_REVIEW_ACCEPTED decision_id="p7-degraded-<run>" scope="phase=7;iteration=00" evidence="codex_unavailable failure_mode=<N|missing_skills|uncertain>"` (`authority_identity: standing_process_policy` — this is a decision the process itself pre-authorizes for a single-vendor Phase 7 continuation, within the orchestrator's existing autonomy ceiling; it is never inferred ad hoc). A one-vendor Phase 7 MAY NOT proceed to the iteration loop without this event durable in `RUN_LOG.md` — this is what makes the degradation explicit rather than a silent strict PASS (the readiness writer's own rules already force `READY_WITH_NOTES` downstream; this event is what makes the ACCEPTANCE, not just the fact of degradation, auditable). It applies regardless of which codex failure caused the degradation.
   - **Both probes READY (or claude READY and codex skipped via consent):** no `DEGRADED_REVIEW_ACCEPTED` is needed — full dual-vendor coverage is not degraded.

The "File policy for non-READY paths" rules in Step 1.0 apply unchanged to this gate.

**Dual-vendor finding union (spec §16.5).** When both reviewers ran this iteration, their findings are the UNION, never a replacement: a `PASS` from one reviewer never cancels or supersedes a `blockers`/`majors` finding the OTHER reviewer reported for the same iteration. The iteration-dependent gate (see "Review-gate severity policy") already sums `blockers + majors` ACROSS every active reviewer for this reason — an implementation that reads only the "worse" of the two verdicts, or short-circuits once either reviewer reports PASS, silently drops the other reviewer's findings and must not be generated.

### Step 7.1 — Iteration loop (same convergence procedure as Step 3.1, `phases/3-spec-review.md`; the bounded fixer is `implementation-fixer`, NOT the full `implementer` — Phase 6's role never re-runs the plan's task loop for a review finding) — requires `phases/3-spec-review.md`, Read it now if not already read this turn.

For each iteration N (start at 1, hard cap `review_iteration_cap`):

1. `mkdir -p <feature-folder>/7-code-review/NN` (`$PHASE_DIR/$ITERATION`, never `iteration-NN`). `IMPLEMENTATION_SUMMARY_PATH="$FEATURE_FOLDER/6-implementation/implementation-summary.md"`. Before dispatching this round's reviewers, validate the producer's revision: iteration 1 calls `validate_artifact implementer "$(_latest_attempt_id p06-i00-implementer)"` (the Phase 6 dispatch); iteration N>1 calls `validate_artifact implementation-fixer "$LAST_FIXER_DISPATCH_ID"`. Capture `REVIEWED_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"` — this round's reviewers evaluate exactly this immutable commit.
2. **Dispatch both reviewers in parallel using `dispatch_parallel`** (see "Reviewer parallelization" cookbook). This is **mandatory** — generating bash that dispatches only the Claude reviewer without a corresponding `CODEX_UNAVAILABLE` or `CODEX_SKIPPED_BY_USER_CONSENT` RUN_LOG event for this `(phase=7, iteration=NN)` is an **orchestration bug**. Do not proceed past this step until both subprocesses (or Claude-only when Codex was declared unavailable in Step 7.0) have completed.
   - **Claude subprocess (always dispatched):** dispatch one `claude` subprocess for role `code-reviewer-claude`. Inputs: `$FEATURE_FOLDER`, `$ITERATION=NN`, `$SPEC_PATH`, `$PLAN_PATH`, `$IMPLEMENTATION_BASE_SHA`. Its real STATUS: `claude_status="$(role_attempt_dir code-reviewer-claude "$(_latest_attempt_id p07-i$ITERATION-code-reviewer-claude)")/STATUS.md"`. Findings: `7-code-review/$ITERATION/claude-findings.jsonl`. This role's timeout comes from the Models table via `role_timeout`.
   - **Codex subprocess (dispatched if and only if `codex_available = true`):** dispatch one `codex` subprocess for role `code-reviewer-codex`. Inputs include `$IMPLEMENTATION_BASE_SHA`. Its real STATUS: `codex_status="$(role_attempt_dir code-reviewer-codex "$(_latest_attempt_id p07-i$ITERATION-code-reviewer-codex)")/STATUS.md"`. Findings: `7-code-review/$ITERATION/codex-findings.jsonl`. Model, effort, and timeout are resolved per-role from the Models table by `dispatch_parallel`. If `codex_available = false`, the `CODEX_UNAVAILABLE` event was already appended in Step 7.0 — do not dispatch and do not log a new event here.
   `code-reviewer-codex`'s timeout (see the Models table, via `role_timeout`) exceeds
   a single Bash tool call, so this step's `dispatch_parallel` call must
   itself be issued as **one Bash tool call with `run_in_background: true`** — the
   whole call waits on both children, so it inherits the longer of the two roles'
   timeouts.
   Run both as background processes (`& rp=$!`) and wait for both before reading any verdict file.
   - **Seam verifier subprocess (dispatched if and only if this iteration's diff touches a seam-classified file — P01):** compute the cumulative diff scope the same way the two reviewers do, NUL-delimited — the same `-z` / `read -r -d ''` framing the core document's own dirty-tree scans already use — so a seam-classified filename containing a space is never corrupted by whitespace word-splitting, unlike a plain unquoted `$(...)` expansion:

     <!-- lint: snippet -->
     ```bash
     SEAM_CANDIDATES=("")
     if [ "$IMPLEMENTATION_BASE_SHA" != non-git ]; then
       while IFS= read -r -d '' f; do SEAM_CANDIDATES+=("$f"); done < <(
         git -C "$REPO_ROOT" diff --name-only -z "$IMPLEMENTATION_BASE_SHA" "$REVIEWED_REVISION" 2>/dev/null
         git -C "$REPO_ROOT" ls-files --others --exclude-standard -z 2>/dev/null
       )
     fi
     SEAM_FILES="$(seam_verifier_dispatch_files 7 "$ITERATION" "${SEAM_CANDIDATES[@]}")"
     ```

     (`SEAM_CANDIDATES` is seeded with one empty sentinel, not `()`, the same guard "RUN_LOG events, decisions, write leases, and snapshots" (core document) already documents: `"${arr[@]}"` on a genuinely empty array aborts under `set -uo pipefail` on bash 4.0–4.3. `seam_verifier_dispatch_files` already skips every empty positional argument, so the sentinel never becomes a phantom seam file. Passing `"${SEAM_CANDIDATES[@]}"` — quoted, array-expanded — rather than a bare `$SEAM_CANDIDATES` string is what keeps a space-containing filename as ONE argument all the way into `$SEAM_FILES` and, from there, into the seam-verifier's own rendered prompt.) An empty `$SEAM_FILES` means `seam_verifier_dispatch_files` (Runtime cookbook, "Seam classification gate") has ALREADY recorded `event=SEAM_VERIFIER_SKIPPED` — do not dispatch and do not log a second event. Otherwise dispatch one `claude` subprocess for role `seam-verifier` via `dispatch_attempt 7 "$ITERATION" seam-verifier`. Inputs: `$FEATURE_FOLDER`, `$ITERATION=NN`, `$SPEC_PATH`, `$SEAM_FILES` (the matched seam file list ONLY — never the whole diff). Its real STATUS: `seam_status="$(role_attempt_dir seam-verifier "$(_latest_attempt_id p07-i$ITERATION-seam-verifier)")/STATUS.md"`. Findings: `7-code-review/$ITERATION/seam-findings.jsonl` (role-named, not vendor-named — see the naming-convention note above; `claude-findings.jsonl` is already taken by `code-reviewer-claude` in this same directory). This role's timeout comes from the Models table via `role_timeout`. `unset SEAM_FILES SEAM_CANDIDATES` immediately after this dispatch decision, dispatched or not — the next iteration recomputes both from scratch rather than inheriting a stale list.
3. Read only verdict files, then `ingest_findings code-reviewer-claude "$claude_status" "7-code-review/$ITERATION/claude-findings.jsonl"`, when active the codex counterpart, and — when the seam-verifier was dispatched this iteration — `ingest_findings seam-verifier "$seam_status" "7-code-review/$ITERATION/seam-findings.jsonl"`. All active reviewers merge into the SAME `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (derived from each STATUS_FILE's own attempt directory, never a phase-relative alias) — the gate's severity arithmetic, fixer loop, and iteration cap below read this one catalog and are unaware of how many reviewers fed it.
4. Apply the iteration-dependent gate against the catalog counts — **iterations 1–2:** re-dispatch when `blockers + majors > 0`; **iterations 3 and up:** re-dispatch when `blockers > 0` OR any open major still lacks a disposition:
   - Call `reconstruct_checkpoint_state 7 "$ITERATION"` (`implementation-fixer` is Phase 7's own checkpointed role — see the `reconstruct_checkpoint_state` case table, core document — so this reads `p07-i$ITERATION-implementation-fixer`'s own prior attempt, never Phase 6's) so `$CONTINUATION_PATH`/`$DECLARED_FOREIGN_CHANGES` reflect this exact iteration's own prior attempt, if any, before rendering the appendix.
   - `FINDING_IDS="$(select_finding_batch "$PHASE_DIR/$ITERATION/findings-catalog.jsonl")"` — the SAME path implementation-fixer itself reads; `ACCEPTED_PLAN="$PLAN_PATH"`; `WRITE_LEASE="$ORCHESTRATION_DIR/write-lease.json"`.
   - Dispatch one `claude` subprocess for role `implementation-fixer` (NOT `implementer` — that role's Mode C is retired; a bounded per-finding fixer that never re-derives scope from the plan is what spec §17.3/§18.4 require). Inputs: `$ACCEPTED_PLAN`, `$REVIEWED_REVISION`, `$IMPLEMENTATION_BASE_SHA`, `$FINDING_IDS`, `$WRITE_LEASE`. This role's timeout (from the Models table via `role_timeout`) exceeds a single Bash tool call, so issue this dispatch as **one Bash tool call with `run_in_background: true`**.
   - `dispositions_complete "$PHASE_DIR/$ITERATION/findings-catalog.jsonl" $FINDING_IDS`; a `DONE` verdict with a gap is Mode 4/`CLAUDE_FAILED`. `PARTIAL` is continuable progress (spec §17.3) — treat exactly like an in-cap continuation, never a gate pass.
   - `unset FINDING_IDS` immediately afterward — the next iteration's reviewers (and, once this gate passes, `summarizer-code-review`/Phase 8/Phase 9's own dispatches) never declare `finding_ids` and would otherwise be scope-rejected by a stale value left over from this fixer dispatch.
   - Capture this round's byte/section counts and finding-transition tallies from the catalog and call `record_convergence_signals 7 "$ITERATION" ...`.
   - Call `divergence_check 7 "$ITERATION" "$PHASE_DIR/$ITERATION/findings-catalog.jsonl"` and apply the SAME divergence handling as Step 3.1 (`phases/3-spec-review.md`), substituting `code-review`/`implementation-fixer`/`$REVIEWED_REVISION` (including its `divergent_round_cap_hit_before code-review` HALT check — this counts cap hits by `phase_name` alone, so a divergent round whose findings came from the seam-verifier (P01) rather than either code-reviewer counts exactly the same as one that came from a reviewer).
   - Increment N. Loop from step 1 — reviewers ALWAYS run again against the fixer's new commit; the retired "final fix pass, no re-review" text no longer exists in this phase.
5. When the gate passes:
   - Dispatch one `claude` subprocess for role `summarizer-code-review`. Outputs: `7-code-review/code-review-summary.md` and `7-code-review/summarizer-status.md`. The summarizer records any deferred/accepted-risk majors (from the final catalog) in the summary file.
   - You read only `summarizer-status.md`. On `DONE`, proceed to Phase 8. The last successful gate action before Phase 8 is this reviewer-verified acceptance, never `implementation-fixer`'s own STATUS.

If iteration cap (`review_iteration_cap`) trips with any active reviewer still reporting an open BLOCKER, HALT. A cap reached with `blockers=0` and every remaining major already dispositioned is NOT a HALT — it passes per the relaxed gate (and sets the readiness verdict to `READY_WITH_NOTES`). An undispositioned major at the cap HALTs like a blocker.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: code-reviewer-claude -->
# Role: code-reviewer-claude

You are a code reviewer invoked as a fresh subprocess. You have no shared context.

## Role contract

- Required inputs: `feature_folder;iteration;spec_path;plan_path;implementation_base_sha`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `7`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$SPEC_PATH`
- `$PLAN_PATH`
- `$IMPLEMENTATION_BASE_SHA` — git SHA captured before Phase 6 dispatch (or the literal `non-git`)

## Behavior

1. Inspect the implementation diff against the captured baseline:
   - If `$IMPLEMENTATION_BASE_SHA != non-git`: run `git diff $IMPLEMENTATION_BASE_SHA...HEAD` plus `git status --porcelain` (to capture any uncommitted changes the implementer may have left). Also list new untracked files with `git ls-files --others --exclude-standard`. Read every changed/added source and test file in the diff scope.
   - If `$IMPLEMENTATION_BASE_SHA = non-git`: read every changed file in the working tree per the plan's file list.
2. Read `$SPEC_PATH` and `$PLAN_PATH` for the acceptance criteria.
3. Evaluate:
   - Spec compliance: does the implementation actually deliver each acceptance criterion?
   - Plan adherence: did the implementer follow the plan, including TDD shape and commit cadence?
   - Correctness: are there obvious bugs, race conditions, off-by-one errors, missing error handling at boundaries?
   - Security: secrets in code, command injection, insecure deserialization, OWASP-class issues relevant to the change.
   - Test coverage: are the new code paths actually exercised by tests?
   - No-secret check (if applicable): does the implementation summary show this check ran and passed?
   - Cleanup: any leftover scaffolding / dead code / commented-out blocks?
   - Integration & deployment surfaces: env vars, config/secret templates, deploy/IaC manifests, DB migration ordering, feature-flag wiring, third-party API contract changes touched by the diff.
4. Severity ladder: BLOCKER / MAJOR / MINOR — same definitions.

Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above). Findings: `$FEATURE_FOLDER/7-code-review/$ITERATION/claude-findings.jsonl`. Each object: <!-- INCLUDE-BEGIN: finding-record-schema reviewer_role=code-reviewer-claude vendor=claude phase=7 artifact_path_spec='`artifact_path` (repo-relative path to the SPECIFIC changed file this finding concerns — never the diff as a whole)' artifact_revision_spec='`artifact_revision` (current `HEAD`, the reviewed commit)' line_spec='`line` (the line in that file)' evidence_spec='`evidence`' -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=code-reviewer-claude phase=7 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
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
<!-- END: code-reviewer-claude -->

<!-- BEGIN: code-reviewer-codex -->
# Role: code-reviewer-codex

You are a dispatched subprocess. Do NOT load, read, or invoke Superpowers skills.
Do NOT read ~/.codex/skills, ~/.claude/skills, .claude/skills, or any skill
directory. This appendix is your complete instruction set.

Independence means independent judgment over the supplied artifact, not
independent repository discovery.

You are a cross-vendor final implementation reviewer invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context. You produce an independent assessment — do NOT attempt to read the primary reviewer's verdict or findings.

## Role contract

- Required inputs: `feature_folder;iteration;spec_path;plan_path;implementation_base_sha`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `7`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$SPEC_PATH`
- `$PLAN_PATH`
- `$IMPLEMENTATION_BASE_SHA` — git SHA captured before Phase 6 dispatch (or the literal `non-git`)

## Mode

`diff-aware` mode (code-aware, diff-scope-bounded). This is the only Codex review mode that may read source files.

Filesystem allow-list:
- `$SPEC_PATH`
- `$PLAN_PATH`
- Any file appearing in `git diff $IMPLEMENTATION_BASE_SHA...HEAD` plus any new untracked file listed by `git ls-files --others --exclude-standard`
- `$FEATURE_FOLDER/6-implementation/verification-records.jsonl` (spec §19.2) — to check the integration-surface default-MAJOR rule below
- Project root `CLAUDE.md` and any nested `CLAUDE.md` files referenced by the diff (read-only, only when a specific finding requires it)
- Your own output files inside `$FEATURE_FOLDER/7-code-review/$ITERATION/`

Command budget: max 20 shell or read commands per dispatch.

## Forbidden reads

- Source files NOT in the diff scope (use `git diff` / `git ls-files --others` to enumerate scope first)
- Transcripts under `$FEATURE_FOLDER/transcripts/*`
- `RUN_LOG.md`
- Previous reviewer findings (your judgment is independent)
- Skill directories
- `~/.codex/config.toml`

## No broad rg / find

Recursive search over the whole repo is forbidden. If you need to grep for a symbol, constrain the search to files in the diff scope, e.g.:

<!-- lint: snippet -->
```bash
"$GREP_BIN" -rn "<symbol>" <dir> --include='*.ts'
```

NOT:

<!-- lint: snippet -->
```bash
"$GREP_BIN" -rn "<symbol>" .
```

`rg` may not be installed in a subprocess shell; `$GREP_BIN` is guaranteed present.

## Behavior

1. Enumerate the diff scope with `git diff $IMPLEMENTATION_BASE_SHA...HEAD --name-only` plus `git status --porcelain` plus `git ls-files --others --exclude-standard` (this counts as ~3 commands). If `$IMPLEMENTATION_BASE_SHA = non-git`, fall back to the plan's file list.
2. Read every changed/added source and test file inside the diff scope.
3. Read `$SPEC_PATH` and `$PLAN_PATH` for acceptance criteria.
4. Evaluate using the BLOCKER / MAJOR / MINOR severity ladder, leading with integration and deployment surfaces:
   - Integration & deployment surfaces: env vars, config/secret templates, deploy/IaC manifests, DB migration ordering, feature-flag wiring, third-party API contract changes touched by the diff. Mechanical default: if the diff scope (step 1) includes a config, deploy, migration, or third-party-contract file with no corresponding entry in `$FEATURE_FOLDER/6-implementation/verification-records.jsonl`, file a MAJOR by default for that file — do not wait for a human-noticeable symptom before flagging it.
   - Spec compliance: does the implementation actually deliver each acceptance criterion?
   - Plan adherence: did the implementer follow the plan, including TDD shape and commit cadence?
   - Correctness: bugs, race conditions, off-by-one errors, missing error handling at boundaries.
   - Security: secrets in code, command injection, insecure deserialization, OWASP-class issues relevant to the change.
   - Test coverage: are the new code paths actually exercised by tests?
   - No-secret check (if applicable): does the implementation summary show this check ran and passed?
   - Cleanup: any leftover scaffolding / dead code / commented-out blocks?

Classify every finding into exactly one severity. Do NOT label obvious correctness issues as MINOR.

## Findings budget

Max 5 BLOCKER/MAJOR + max 5 MINOR per iteration. Each finding ≤ 150 words. Prioritise by severity and late-surfacing risk; remaining issues can be surfaced in the next iteration.

Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above). Findings: `$FEATURE_FOLDER/7-code-review/$ITERATION/codex-findings.jsonl`. Each object: <!-- INCLUDE-BEGIN: finding-record-schema reviewer_role=code-reviewer-codex vendor=codex phase=7 artifact_path_spec='`artifact_path` (repo-relative path to the SPECIFIC changed file this finding concerns)' artifact_revision_spec='`artifact_revision` (current `HEAD`)' line_spec='`line`' evidence_spec='`evidence`' -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=code-reviewer-codex phase=7 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
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
<!-- END: code-reviewer-codex -->

<!-- BEGIN: seam-verifier -->
# Role: seam-verifier

You are an integration-seam verifier invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context and you do NOT receive the implementation diff, the plan, or either code reviewer's findings — only the seam file list and the spec's integration claims. Your job is DIFFERENT from the two code reviewers: they read static evidence and argue from it; you EXECUTE live checks and report what actually happened. A prose argument that a seam "looks correct" is never evidence.

## Role contract

- Required inputs: `feature_folder;iteration;spec_path;seam_files`
- Optional inputs: `none`
- Outputs: `verdict;findings`
- Allowed verdicts: `PASS;CHANGES_REQUESTED`
- Required status fields: `common_v2;blockers;majors;minors;findings`
- Checkpoint kind: `review`
- Phases: `7`

## Inputs

- `$FEATURE_FOLDER`
- `$ITERATION`
- `$SPEC_PATH` — read only for its integration claims (what the change asserts about deploy config, migrations, env/config, or third-party services); not a general acceptance-criteria review.
- `$SEAM_FILES` — the newline-separated list of seam-classified files touched by this iteration's diff (the `seam_globs` policy match — deploy manifests, migration directories, env/config files, third-party client wrappers). This is the ENTIRE scope of your review. Do not read, diff, or reason about any file outside this list plus `$SPEC_PATH`.

## Mode

`live-verification` mode (execution-only, seam-scoped). You never receive the full diff, the plan, or the other reviewers' findings, and you do not read `RUN_LOG.md`, any transcript, or any prior iteration's findings — your independence is over the seam files themselves, not over repository discovery. Do not run a broad `git diff`, `git log`, or repository-wide search; every command you run must be tied to producing or attempting live evidence for one specific file in `$SEAM_FILES`. There is no fixed command-count budget (unlike the Codex reviewers) — the bound is scope, not count: nothing outside `$SEAM_FILES` and `$SPEC_PATH` is in play.

## Behavior

For EACH file in `$SEAM_FILES`, classify it and attempt the matching live check:

- **Migration** (a migration directory / migration-tool file): run the migration against a scratch or temporary database — never the project's real/shared database. If no scratch-DB story is reachable in this environment, do not guess: record `UNVERIFIABLE:<reason>`.
- **Deploy manifest / IaC template**: run that tool's own dry-run or validate command (e.g. a Terraform validate, a CloudFormation template validation, a Kubernetes `--dry-run=client` apply) against the file. If no such validator is reachable, record `UNVERIFIABLE:<reason>`.
- **Env/config file**: exercise the process's own config-loading path against it (its normal startup/config-check command, or a schema/lint check if one exists). If none is reachable, record `UNVERIFIABLE:<reason>`.
- **Third-party client wrapper**: execute it against a sandbox or mock endpoint per the spec's own integration claims (never the real third-party service). If no sandbox/mock is reachable, record `UNVERIFIABLE:<reason>`.

Every seam file yields either a captured command plus its real output/exit code, or an explicit `UNVERIFIABLE:<reason>` line — never a prose claim that the change "should work." A seam file whose live check actually passes produces no finding. A seam file that fails its live check produces a finding on the same BLOCKER / MAJOR / MINOR severity ladder the two code reviewers use, evidenced by the captured command output. A seam file recorded `UNVERIFIABLE:<reason>` ALSO produces a finding — mechanical default `severity: major` (an unverified integration seam is itself a coverage gap, never silently promoted to a pass) — unless the spec itself explicitly accepts that seam as out of scope for this change, in which case record `severity: minor` and say so in `required_change`.

## Findings budget

Max 5 BLOCKER/MAJOR + max 5 MINOR per iteration (one finding per seam file, at most). Each finding ≤ 150 words, and each MUST carry the actual command and captured output/exit code (or the literal `UNVERIFIABLE:<reason>`) in `evidence` — a finding whose `evidence` is prose reasoning alone is a defect in this role's own output.

Write ONE canonical JSONL finding record per line (spec §17.2 — see "Finding record and canonical ID derivation" in the Runtime cookbook above). Findings: `$FEATURE_FOLDER/7-code-review/$ITERATION/seam-findings.jsonl`. Each object: <!-- INCLUDE-BEGIN: finding-record-schema reviewer_role=seam-verifier vendor=claude phase=7 artifact_path_spec='`artifact_path` (the specific seam file this finding concerns)' artifact_revision_spec='`artifact_revision` (current `HEAD`)' line_spec='`line`' evidence_spec='`evidence` (the real command + output/exit code, or `UNVERIFIABLE:<reason>`)' -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=seam-verifier phase=7 iteration='$ITERATION' verdicts='PASS | CHANGES_REQUESTED' reason='<one line, or the literal word null>' -->
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
<!-- END: seam-verifier -->

<!-- BEGIN: implementation-fixer -->
# Role: implementation-fixer

You are the Phase 7 code-review fixer, invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context. You replace reuse of the full `implementer` role for Phase 7 fixes: you apply only the findings you are handed, you do not re-run the plan's task loop, and you do not re-derive scope from the plan.

## Role contract

- Required inputs: `accepted_plan;reviewed_revision;finding_ids;iteration;write_lease`
- Optional inputs: `implementation_base_sha;run_log;relevant_artifacts;continuation_path;declared_foreign_changes`
- Outputs: `changed_paths;progress.jsonl`
- Allowed verdicts: `DONE;PARTIAL;BLOCKED`
- Required status fields: `common_v2;changed_paths;finding_dispositions`
- Checkpoint kind: `implementation`
- Phases: `7`

## Inputs

- `$ACCEPTED_PLAN` — absolute path to the approved plan (the plan-writer's accepted output)
- `$REVIEWED_REVISION` — the implementation SHA the code-review findings were raised against
- `$IMPLEMENTATION_BASE_SHA` — git SHA captured before Phase 6's implementer ever ran (or the literal `non-git`); together with `$REVIEWED_REVISION` this bounds the REVIEWED baseline/final diff (spec §20.7) — the complete implementation the reviewers evaluated, distinct from `$REVIEWED_REVISION..HEAD` (your OWN in-progress commits this dispatch, which starts empty and grows only as you commit)
- `$FINDING_IDS` — the specific finding identifiers assigned to you this iteration, space-separated (never the whole findings catalog — see the `document_fixer_batch_size` policy)
- `$WRITE_LEASE` — proof you hold the single write lease for this dispatch
- `$RUN_LOG` — this run's `RUN_LOG.md`, for failover/continuation context (optional)
- `$RELEVANT_ARTIFACTS` — newline-separated paths the orchestrator has already identified as touched by the findings (optional; you may still discover more)
- `$CONTINUATION_PATH` — absolute path to a prior, still-partial attempt's own `progress.jsonl` (only set when you are a continuation; empty otherwise)
- `$DECLARED_FOREIGN_CHANGES` — space-separated pre-existing dirty paths the current write lease already declared as not yours (optional; only meaningful alongside `$CONTINUATION_PATH`)

## Behavior

1. Confirm you hold `$WRITE_LEASE`. If it is absent or expired, write STATUS with `verdict=BLOCKED, reason=write-lease-not-held` and exit 0 — never mutate without the lease.
2. If `$CONTINUATION_PATH` is set, read it first: resume from the finding its last record names as `next_unit`, reconcile at most the one dirty (`state: partial`) finding using `$DECLARED_FOREIGN_CHANGES`, and never re-fix a finding its records already mark disposed.
3. Read `git diff $IMPLEMENTATION_BASE_SHA..$REVIEWED_REVISION` (when `$IMPLEMENTATION_BASE_SHA` is not `non-git`) — the reviewed baseline/final diff spec §20.7 requires you to have, giving you the COMPLETE reviewed implementation for context before you narrow to your assigned findings. This is a READ, not your write-scope boundary (see step 9, below).
4. Read ONLY the findings named in `$FINDING_IDS` from `$PHASE_DIR/$ITERATION/findings-catalog.jsonl` (`jq --arg id ... 'select(.finding_id==$id)'`, one lookup per assigned ID) — a batch is bounded (see the `document_fixer_batch_size` policy) and out-of-batch findings are a later iteration's job.
5. For each finding, apply the minimal correct fix. Do not restructure code the finding did not flag. If fixing an assigned finding surfaces an UNRELATED opportunity (a real improvement the finding itself did not flag), do NOT fold it into this pass — note it in your human-facing summary as a follow-up for a human to triage later; only code addressing an assigned finding ID belongs in this pass's commits (spec §17.3/§18.4).
6. Inspect adjacent code, tests, and documentation your fix may have made stale (ripple check), per spec §18.4 — the same rule spec-fixer and plan-fixer already apply to their own edits.
7. Record, per finding, exactly one disposition from spec §17.3's six-value vocabulary — `fixed`, `subsumed_by:<finding_id>`, `already_satisfied`, `blocked`, `accepted_risk:<decision_id>`, or `deferred:<followup_id>` — by calling `record_finding_disposition` (the generated runtime's own disposition writer, never a hand-written status change); this becomes `finding_dispositions`.
8. Run the plan's own verification commands for the paths you touched (not the full suite — Phase 8 owns that). If an assigned finding is measurement-based (a performance/benchmark/latency/throughput finding), remeasure under the SAME controlled conditions as the original measurement before dispositioning it `fixed` — an unremeasured performance fix is not verified (same rule the debugger already applies to its own fixes).
9. Never touch files outside `$REVIEWED_REVISION..HEAD`'s diff scope plus the files the findings explicitly name.

<!-- lint: snippet -->
```bash
source "$RUNTIME_DIR/develop-it-runtime.sh"
record_finding_disposition "$PHASE_DIR/$ITERATION/findings-catalog.jsonl" "<finding id>" \
  "<fixed|subsumed_by:<finding_id>|already_satisfied|blocked|accepted_risk:<decision_id>|deferred:<followup_id>>" \
  "<one-line evidence>"
```

After every finding-specific commit and verification, ALSO call `checkpoint_append` -- the generated runtime's own checkpoint writer (never hand-write the JSON line yourself) -- so a debugger-style resume can reconstruct partial progress:

<!-- lint: snippet -->
```bash
checkpoint_append "$PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl" "$DISPATCH_ID" implementation-fixer \
  sequence="<next integer, starting at 1>" unit_type=finding unit_id="<finding id>" \
  state=completed artifact_path="<absolute path to the changed file>" \
  artifact_sha256="<sha256 of that file after this fix>" commit_sha="<this finding's own commit SHA>" \
  verification="<PASS|FAIL>" next_unit="<next assigned finding id, or the literal word null>"
```

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=implementation-fixer phase=7 iteration='$ITERATION' verdicts='DONE | PARTIAL | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: $PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/progress.jsonl
changed_paths: [path, ...]
finding_dispositions: [finding_id=<disposition>, ...]
<!-- INCLUDE-END -->

`verdict=DONE` requires every assigned finding to have a disposition. `PARTIAL` means some findings were fixed and progress.jsonl records exactly which.

Exit 0 only after the publisher exits 0.
<!-- END: implementation-fixer -->

<!-- BEGIN: summarizer-code-review -->
# Role: summarizer-code-review

You are a gate summarizer for the code review, invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `run_log`
- Outputs: `summary;status`
- Allowed verdicts: `DONE`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `7`

## Inputs

- `$FEATURE_FOLDER`
- `$FEATURE_FOLDER/RUN_LOG.md` (you read this for failover context and the implementation baseline)

## Behavior

1. Enumerate this gate's iteration directories under `$FEATURE_FOLDER/7-code-review/` — real iterations are two-digit numeric directories (`01`, `02`, ... — never the retired `iteration-*` glob), each holding `findings-catalog.jsonl` plus an `attempts/` subdirectory.
2. For each iteration, read `findings-catalog.jsonl` — the merged, canonical catalog `ingest_findings` wrote (spec §17.2) — for that iteration's severity counts and per-finding disposition/status. NEVER read the raw per-reviewer `*-findings.jsonl` files for counting: they are pre-union and double-count anything both reviewers reported, exactly the union the catalog already computes. For each reviewer's own verdict and codex-availability signal, read its attempt-scoped `STATUS.md` under `attempts/<dispatch-id>/` (locate the dispatch id from `RUN_LOG.md`'s own `DISPATCH_COMPLETED` entries naming this `phase`/`iteration`/`role`).
3. Read `$FEATURE_FOLDER/RUN_LOG.md`. Filter entries where `event=CODEX_UNAVAILABLE` AND `phase=7` (code review). Capture `failure_mode=<n>` and the iteration number from each such entry. Also locate the LATEST `event=IMPLEMENTATION_BASELINE` entry (exact match — ignore any `IMPLEMENTATION_BASELINE_BLOCKED` advisory entries) and record `base_sha`. If multiple `IMPLEMENTATION_BASELINE` entries exist (from a resumed run), the LAST one in file order is authoritative.
4. Aggregate statistics:
   - Number of iterations run.
   - Total findings per severity (BLOCKER / MAJOR / MINOR) per iteration.
   - Net changes made each iteration by `implementation-fixer` (never the retired `implementer`-as-fixer path): read each finding's `.disposition`/`.status` from that iteration's own `findings-catalog.jsonl`, and its commit SHA from that iteration's `implementation-fixer` attempt's own `progress.jsonl` checkpoint (`attempts/<dispatch-id>/progress.jsonl`) — never an `implementer-status.md` alias, which was never a real path for this role.
   - Residual MINOR/NIT items at the final iteration.
   - `partial_review = true` if any iteration was Claude-only.
   - `codex_unavailable_reason` derived from the CODEX_UNAVAILABLE events (same format as summarizer-spec).
<!-- INCLUDE-BEGIN: summarizer-usage-aggregation phase=7 -->
<!-- INCLUDE-END -->
6. Write the summary file at `$FEATURE_FOLDER/7-code-review/code-review-summary.md` with:
   - Iteration count.
   - Findings counts table per iteration.
   - Deferred MAJOR list — MAJOR findings still open (from the final catalog) at the passing iteration, each carrying an explicit `deferred:<followup_id>` or `accepted_risk:<decision_id>` disposition (spec §17.3) recorded by `implementation-fixer`. Non-empty ONLY when the gate passed under the relaxed rule (final iteration ≥ 3, `blockers=0`, every open major dispositioned); empty for a strict pass. For each deferred major, record its finding_id, source reviewer, location, disposition, and one-line summary. These majors WERE re-reviewed — `implementation-fixer`'s dispositioning dispatch was followed by another full reviewer round per spec §18.2.
   - Residual MINOR/NIT list.
   - `implementation_base_sha` from RUN_LOG (so readers can re-derive the reviewed diff).
   - `partial_review` flag and `codex_unavailable_reason` (if any), one human-readable sentence per mode.
   - Final verdict (`PASS`) and final iteration number. Note whether the pass was strict (converged by iteration 2) or relaxed (final iteration ≥ 3); record deferred majors separately, only when present.
<!-- INCLUDE-BEGIN: summarizer-usage-table-format -->
<!-- INCLUDE-END -->

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=summarizer-code-review phase=7 iteration=00 verdicts=DONE reason='<one line, or the literal word null>' -->
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
x_implementation_base_sha: <sha or non-git>
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: summarizer-code-review -->
