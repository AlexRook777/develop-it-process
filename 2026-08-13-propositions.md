# Consolidated Develop-It process improvements

Date: 2026-08-13

Target process: [`develop-it-prompt.md`](develop-it-prompt.md)

## Executive recommendation

The strongest evidence is not for adding more review phases first. It is for making dispatch execution, publication, recovery, and review convergence trustworthy. Several real runs lost hours of completed work, suppressed a healthy second reviewer, reused stale STATUS files, or treated a transport interruption as a substantive role failure. Those defects can produce either false success or unnecessary human intervention.

Apply the recommendations in this order:

1. **Safety hotfixes:** R01-R04 and R22. These are localized changes that close wrong-repository execution, silent background-task termination, stale STATUS acceptance, fragile STATUS publication, and a concrete context7 policy bug.
2. **Dispatch and recovery foundation:** R05-R09. Introduce resumable progress, a coherent failure state machine, one dispatch/logging implementation, a role-contract registry, and evidence-based preflight behavior.
3. **Review-loop correctness:** R10-R16 and R21. Detect divergence, verify final fixes, improve fixer behavior, represent owner decisions, protect mutating phases, make plans executable, bound Phase 7 fixes, and reject structurally incomplete artifacts before expensive review.
4. **Maintainability and auditability:** R17-R20, R23, and R24. Stop copying cookbook code, automate event/proposition reconciliation, add durable documentation/handoff, route optional skills, reorder free gates, and fix process-file identity.

The current prompt already incorporates many earlier propositions. Those are listed under **Already incorporated or intentionally retained** and should not be implemented again.

## Scope and method

I read the complete current process prompt (4,351 lines) and all six proposition files (137 entries):

| ID | Run | Entries | Original proposition file |
|---|---|---:|---|
| S1 | Raw event v3 date columns | 10 | [S1](../prism/docs/superpowers/specs/2026-07-30-raw-event-v3-date-columns-artifacts/process-improvement-proposition.md) |
| S2 | Monthly bills | 26 | [S2](../prism/docs/superpowers/specs/2026-08-03-monthly-bills-artifacts/process-improvement-proposition.md) |
| S3 | Prism user auth | 15 | [S3](../prism/docs/superpowers/specs/2026-08-05-prism-user-auth-artifacts/process-improvement-proposition.md) |
| S4 | Events viewer | 18 | [S4](../prism/docs/superpowers/specs/2026-08-07-events-viewer-artifacts/process-improvement-proposition.md) |
| S5 | Allocation engine | 45 | [S5](../prism/docs/superpowers/specs/2026-08-10-allocation-engine-artifacts/process-improvement-proposition.md) |
| S6 | Allocation UX | 23 | [S6](../prism/docs/superpowers/specs/2026-08-13-allocation-ux-artifacts/process-improvement-proposition.md) |

### Counting rule

`Proposed by` is the number of **distinct proposition files** containing substantive evidence for the consolidated improvement. Repeated incidents within one run strengthen the evidence but count once, preventing a noisy run from dominating the ranking. The supporting source IDs are always listed next to the count.

### Rating definitions

Criticality:

- **Critical:** can cause false success, missed correctness review, work loss/corruption, or execution in the wrong repository.
- **High:** repeatedly halts or substantially wastes long/expensive runs, or leaves important process state unauditable.
- **Medium:** materially improves cost, handoff quality, maintainability, or diagnosis without closing an immediate correctness hole.
- **Low:** localized usability or telemetry accuracy improvement.

Ease of implementation:

- **Easy:** localized prompt/helper/test change with no new cross-phase schema.
- **Moderate:** coordinated changes to several prompt sections, helpers, appendices, and tests.
- **Hard:** new durable state, role/phase, or cross-phase protocol requiring migration and end-to-end coverage.

## Prioritized list

| ID | Consolidated improvement | Criticality | Ease | Proposed by |
|---|---|---|---|---:|
| R01 | Pin every Claude subprocess to the target repository | Critical | Easy | 3 (S2, S4, S5) |
| R02 | Make `claude -p` safe for long and nested work | Critical | Moderate | 4 (S2, S3, S4, S5) |
| R03 | Make dispatch attempts and STATUS files attempt-scoped | Critical | Moderate | 4 (S2, S4, S5, S6) |
| R04 | Prescribe and verify STATUS publication | Critical | Easy | 3 (S2, S3, S4) |
| R05 | Add durable checkpoints and explicit continuation modes | Critical | Hard | 5 (S2, S3, S4, S5, S6) |
| R06 | Replace the conflicting failure rules with one bounded recovery state machine | Critical | Moderate | 4 (S3, S4, S5, S6) |
| R07 | Unify dispatch, timing, logging, and failed-attempt instrumentation | Critical | Hard | 5 (S2, S3, S4, S5, S6) |
| R08 | Publish a machine-readable role contract registry | High | Moderate | 3 (S2, S5, S6) |
| R09 | Make preflight evidence-based and preserve proven dual-vendor coverage | Critical | Moderate | 4 (S2, S3, S4, S5) |
| R10 | Detect review-loop divergence using provenance, recurrence, and growth | High | Hard | 3 (S2, S3, S5) |
| R11 | Eliminate unreviewed final fix passes | Critical | Moderate | 3 (S2, S3, S5) |
| R12 | Make fixer behavior convergent, bounded, and document-aware | High | Moderate | 3 (S2, S5, S6) |
| R13 | Represent decisions, accepted risk, corrections, and post-HALT resumes explicitly | High | Hard | 6 (S1-S6) |
| R14 | Give every mutating dispatch an exclusive write lease and reversible snapshot | High | Hard | 3 (S2, S3, S5) |
| R15 | Make plan executability and verification exclusions first-class | High | Moderate | 2 (S2, S5) |
| R16 | Use a dedicated, findings-bounded Phase 7 implementation fixer | High | Moderate | 1 (S5) |
| R17 | Stop hand-copying the runtime cookbook; source one tested implementation | High | Moderate | 3 (S2, S4, S6) |
| R18 | Automate RUN_LOG/proposition reconciliation | High | Moderate | 2 (S4, S6) |
| R19 | Add a documentation and human-handoff phase with durable follow-ups | Medium | Hard | 1 (S2) |
| R20 | Discover and route optional, task-relevant skills | Medium | Hard | 1 (S3) |
| R21 | Sanity-check artifacts and gate discharge windows before expensive downstream work | High | Moderate | 2 (S3, S5) |
| R22 | Let observed context7 degradation override the Phase 1 reachability result | High | Easy | 1 (S6) |
| R23 | Run every free preflight gate before paid model probes | Medium | Easy | 2 (S3, S4) |
| R24 | Treat an untracked process prompt as dirty/unknown, never clean | Medium | Easy | 1 (S2) |

## Detailed recommended changes

### R01 — Pin every Claude subprocess to the target repository

**Current gap.** `codex_invoke` uses `-C "$REPO_ROOT"`, but `claude_invoke` inherits the orchestrator's working directory. The launcher deliberately starts the orchestrator in the process repository. Real Claude fixers and reviewers therefore sometimes treated a valid target-repository request as an out-of-repo or stray prompt; other roles silently tolerated the mismatch. This is nondeterministic and especially dangerous for code review, where the baseline SHA belongs to the target repository.

**Concrete change.** Modify `claude_invoke` so the `timeout ... claude ...` command runs inside a subshell whose working directory is exactly `$REPO_ROOT`:

1. Validate `$REPO_ROOT` before invoking.
2. Execute `(cd "$REPO_ROOT" && timeout ... claude ...)`, keeping transcript redirections outside or inside the subshell consistently.
3. Preserve `--add-dir` only for additional paths; it is not a substitute for the current working directory.
4. Add the effective CWD to every dispatch block, or at minimum make a canary subprocess report `pwd` and compare it with `$REPO_ROOT`.
5. Treat a model refusal in stdout `.result` that says the task is in the wrong repository as an orchestration error, not a vendor failure.

**Acceptance coverage.** A fake Claude role should assert `pwd == REPO_ROOT`; a code reviewer should be able to resolve a baseline SHA that exists only in the target repository; the process repository must remain unchanged.

**Proposed by:** **3** distinct files — S2 (2026-08-04 06:59), S4 (2026-08-07 09:00), S5 (2026-08-10 14:26).

### R02 — Make `claude -p` safe for long and nested work

**Current gap.** The prompt assigns the implementer 300 minutes, but `claude -p` has repeatedly terminated nested/background work after 600 seconds. A second failure shape occurs when a role starts work in the background and ends/yields its print-mode turn to wait: the parent session exits successfully, its children are killed, no STATUS appears, and most planned work never runs. One run also demonstrated that signalling a live `timeout` wrapper causes Bash `wait` to return on STOP and the harness to reap the entire process tree.

**Concrete change.** Define a transport contract shared by `claude_invoke` and every long-running appendix:

1. Export `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` for roles whose timeout exceeds 600 seconds or which spawn subagents; applying it to every Claude subprocess is simpler if verified safe.
2. Add a standard prompt preamble: under `claude -p`, long shell commands must remain in the foreground; a role must not yield/end its turn while a background child is pending; nested agents must be awaited synchronously before the parent writes STATUS or returns.
3. Add a pre-dispatch assertion that the effective nested/background ceiling is unlimited or at least the role timeout.
4. Treat `Background tasks still running after 600s; terminating`, a success envelope with no STATUS, and implausibly short completion for a long role as transport/non-run diagnoses, not successful role execution.
5. State that the only supported way to change a deadline is the role timeout before dispatch. Never send STOP/CONT/TERM to the live wrapper to extend it.
6. Keep the normal success rule: exit code alone is never success; a fresh, valid STATUS for the current attempt is required.

**Acceptance coverage.** Use a fake nested task that runs longer than the old ceiling, verify the parent remains alive, verify all children are reaped normally, and verify that a role which exits without STATUS cannot satisfy completion even with rc=0.

**Proposed by:** **4** distinct files — S2 (2026-08-03 22:43), S3 (2026-08-05 16:58), S4 (2026-08-07 15:58 and 18:39), S5 (2026-08-11 17:54; 2026-08-12 02:03 and 14:04).

### R03 — Make dispatch attempts and STATUS files attempt-scoped

**Current gap.** `dispatch_id` depends only on phase, iteration, and role. Retrying the same role in the same iteration therefore overwrites transcripts. Fixed STATUS paths can also retain a prior `DONE`; if a later re-dispatch dies without publishing, `post_dispatch` sees the old file and can falsely report success. Split fixer passes collide in exactly the same way.

**Concrete change.** Introduce a monotonically increasing attempt/pass dimension:

1. Change the identity to `(phase, iteration, role, attempt)` and render IDs such as `5-iter01-plan-fixer-attempt03`.
2. Allocate the next attempt from RUN_LOG before launch. A render/prelaunch failure gets its own `DISPATCH_NOT_LAUNCHED` record but does not consume a launched-attempt identity unless that convention is chosen consistently.
3. Give each attempt a unique transcript path and unique STATUS path. For review fixers, include a pass/subset label when work is intentionally split by reviewer or finding batch.
4. Require STATUS to contain its `dispatch_id`/attempt ID. Validation must compare it with the dispatch being completed.
5. Where compatibility requires a canonical latest-status path, publish it only after the attempt-specific STATUS validates; never use it as evidence that the current attempt succeeded.
6. As an interim defense, move any existing fixed-path STATUS to a historical location before dispatch. Do not delete it without preserving the audit trail.
7. Update resume and retry detection to reason over attempts rather than infer retries from adjacent same-role blocks.

**Acceptance coverage.** Simulate attempt 1 `DONE`, attempt 2 failing before STATUS, two split fixer passes, and resume after each. No attempt may read another attempt's STATUS or overwrite its transcript.

**Proposed by:** **4** distinct files — S2 (2026-08-04 07:40), S4 (repeated same-iteration resume evidence), S5 (2026-08-10 15:15 and 2026-08-11 13:40), S6 (multi-attempt retry-wrapper evidence).

### R04 — Prescribe and verify STATUS publication

**Current gap.** Appendices say “write `.tmp` and rename” but leave shell mechanics to the model. Real probes repeatedly generated a conditional final `printf` whose false status prevented `mv`, malformed quoting, or a second identical failed write. The role then claimed success while only a `.tmp` file existed. The two-command Codex micro budget leaves almost no recovery room.

**Concrete change.** Replace every informal atomic-write instruction with one canonical, copyable protocol:

1. Emit every schema key unconditionally; use `reason: null` or an empty-list representation instead of a conditional final line.
2. Write the temporary file, validate it locally, execute `mv` as a separate unconditional statement, then `stat`/re-read the final path and confirm a non-empty legal `verdict:`.
3. Exit non-zero if publication verification fails. A final response may claim success only after the final path is verified.
4. For preflight-codex, either raise the command budget enough to write and verify safely or supply a helper it calls once. Do not weaken atomicity merely to fit an artificial command cap.
5. Classify “final file absent, sibling `.tmp` present” as `publication_lost`. The orchestrator never promotes the `.tmp`, but may retry one cheap non-mutating probe because there is evidence the role reached publication.
6. Specify stale `.tmp` handling: retain/rename it as attempt diagnostics or clean it before the next attempt; never let it count as STATUS.

**Acceptance coverage.** Test READY with empty reason, failed rename, malformed temp content, stale temp, and read-back failure. The success path must leave only a valid final STATUS; all other paths must fail loudly.

**Proposed by:** **3** distinct files — S2 (2026-08-03 19:51; 2026-08-04 06:56), S3 (2026-08-05 05:22 and 06:03), S4 (2026-08-07 13:53).

### R05 — Add durable checkpoints and explicit continuation modes

**Current gap.** Long roles publish terminal STATUS last. A spend ceiling, timeout, connection drop, or harness interruption can leave hours of useful work and many commits but no orchestrator-readable progress. The current implementer has Modes A/B/C, but no first-class resume/continuation mode. Plan writers and document fixers similarly treat large artifacts as all-or-nothing. Skill-owned SDD state can live in a gitignored directory outside the feature artifacts and may disappear.

**Concrete change.** Add durable, role-owned progress artifacts without weakening terminal STATUS:

1. `implementer-progress.md` or structured JSONL under `6-implementation/`, appended after every completed task with task ID, commit SHA, task/report paths, review outcome, verification state, and next task.
2. Store SDD briefs, task reports, review diffs, and `progress.md` directly under `$FEATURE_FOLDER/6-implementation/sdd/` when configurable. Otherwise mirror them after every task—not only at the end—and record the original working directory in STATUS.
3. Add **Mode D — continuation/resume** to the implementer with inputs for the last durable task, existing commits, dirty work-in-progress, declared foreign commits, and the prior failed attempt. It must verify durable state, avoid redoing completed tasks, reconcile the partial task, and continue.
4. Treat a clean-tree timeout after committed tasks as `INCOMPLETE/CONTINUABLE`, not `FAILED`. Redispatch until `DONE`, with a configurable continuation-attempt cap.
5. Make plan-writer checkpoint by completed top-level section and write an `artifact_complete` marker immediately after the plan is structurally complete, before optional summary prose/STATUS.
6. Make spec/plan fixers checkpoint after each finding or bounded batch, recording addressed finding IDs and the next unaddressed ID. Large reviewers may append partial findings, but their terminal verdict remains valid only after full review.
7. Preserve terminal STATUS as write-once-per-attempt and authoritative for completion. Progress proves resumability, not success.

**Acceptance coverage.** Interrupt each long mutating role at several checkpoints, including dirty and clean states; resume must neither duplicate commits nor discard finished work. Removing the external skill directory must not destroy the run record.

**Proposed by:** **5** distinct files — S2, S3, S4, S5, and S6. This is the most broadly repeated unimplemented recommendation.

### R06 — Replace the conflicting failure rules with one bounded recovery state machine

**Current gap.** The prompt contains contradictory rules: Mode 1 says every Claude failure HALTs, the “never do” list implies one retry may be possible, and ORPHANED recovery permits non-mutating redispatch. `dispatch_state` also collapses a classified failed dispatch and a genuinely unobserved orphan into `UNFINISHED`. Failure-mode selection order is not explicit, and render failures can be misreported as vendor failures.

**Concrete change.** Define one ordered classifier and recovery matrix:

1. Classify in order: `PRELAUNCH_FAILED` (appendix/render/input/CWD validation; CLI never invoked), `TIMED_OUT` (rc=124), `VENDOR_OR_TRANSPORT_ERROR` (rc!=0 with extracted signature), `EXITED_NO_STATUS` (rc=0 and fresh STATUS absent), `MALFORMED_STATUS`, then `COMPLETED`.
2. Refine vendor errors into spend ceiling, throttle, transient transport (`connection lost`, `stalled mid-stream`, overload/5xx), permanent auth/config, and unknown. Keep the existing conservative 5b spend-ceiling behavior.
3. Record whether the artifact/tree changed during the attempt and whether durable checkpoints exist.
4. Recovery policy:
   - prelaunch error: fix orchestration; no vendor-failure event; bounded retry after validation;
   - non-mutating transient/no-STATUS: one automatic redispatch;
   - mutating transient with no detected side effects: one automatic redispatch;
   - mutating transient with checkpoints or clean committed units: continuation mode;
   - mutating transient with uncheckpointed partial edits: halt for reconciliation/integrity check;
   - spend ceiling/permanent auth: halt or vendor degradation exactly once at run scope.
5. Budget retries by cause and attempt, not a vague same-role counter. Add a total cap per role/iteration so repeated authorized retries cannot loop forever.
6. Separate `FAILED_OBSERVED` from `ORPHANED_UNOBSERVED` in resume state. A completed dispatch block plus a failure event must not be treated as an orphan merely because STATUS is absent.
7. Use a read-only integrity-check role after an interrupted mutation when the orchestrator cannot inspect the artifact itself.

**Acceptance coverage.** Table-driven tests must cover all classifier precedence combinations, mutating/non-mutating roles, partial/clean trees, checkpoint presence, retry caps, and run-scoped ceilings.

**Proposed by:** **4** distinct files — S3, S4, S5, and S6.

### R07 — Unify dispatch, timing, logging, and failed-attempt instrumentation

**Current gap.** `dispatch_role` and `dispatch_reviewers_parallel` have asymmetric responsibilities. One logs completion itself; the other leaves completion logging to callers. The parallel helper does not measure per-child duration. Real runs produced zero Codex duration, duplicate dispatch blocks, missing vendor-failure events for failed parallel children, and failure events for retries that never launched.

**Concrete change.** Make one dispatch engine own the full lifecycle for both single and parallel work:

1. Render and validate all prompts and inputs before any `DISPATCH_STARTED` event or vendor call.
2. Allocate attempt IDs, snapshot/retire the target STATUS, log start, time each child independently, invoke, validate the current attempt's STATUS, classify, log exactly one completion block, and emit exactly one failure event per failed launched attempt.
3. Parallel dispatch should compose two calls to the same per-child primitive; concurrency changes only scheduling, never logging semantics.
4. Export `CLAUDE_WALL_MS` and `CODEX_WALL_MS` (or return structured results) so Codex duration is never silently zero.
5. Give prelaunch failures a distinct result/event (`DISPATCH_NOT_LAUNCHED`) and exit code. Retry wrappers must never label them `CLAUDE_FAILED`/`CODEX_UNAVAILABLE`.
6. Instrument every retry attempt, including the retry itself. A wrapper invocation is not the unit of accounting; a launched child is.
7. Add a turn-start/idle reconciliation: if the gate is unsatisfied and the last recorded state owes a dispatch, execute it. Never tell the user a dispatch is running before `DISPATCH_STARTED` exists.
8. Add a duplicate detector keyed by attempt ID and fail the readiness audit if more than one completion exists for one attempt.

**Acceptance coverage.** Run fake single/parallel success, one-child failure, render failure, retry failure, missing STATUS, and duplicate caller logging. Counts, timings, and events must match launched processes exactly.

**Proposed by:** **5** distinct files — S2, S3, S4, S5, and S6.

### R08 — Publish a machine-readable role contract registry

**Current gap.** Inputs and STATUS paths are scattered across phase prose and appendix bodies. `render_prompt` discovers missing inputs only by failing; optional inputs must currently be set to empty strings but this is not represented as a contract. The orchestrator has repeatedly guessed STATUS paths, omitted `PLAN_PATH`, `CONTEXT7_POLICY`, `FINDINGS_PATHS`, `DEBUGGER_STATUS_PATH`, or `ITERATION`, and then misclassified the result.

**Concrete change.** Add one role registry (a cookbook function or generated table) containing, for every role:

- vendor, model key, timeout, effort, mutability, and whether it may spawn children;
- required render keys;
- optional render keys and their explicit default (normally empty string);
- canonical attempt-scoped STATUS-path template and other required outputs;
- legal verdicts and required STATUS fields;
- phase/iteration applicability and whether the role is long-running.

Implement helpers such as `role_required_keys`, `role_optional_defaults`, `role_status_path`, and `role_outputs`. `dispatch_role` should populate optional defaults, reject missing required keys before logging start, and derive the STATUS path rather than accept a hand-built one. `init_orchestration_vars` should reconstruct durable values such as `PLAN_PATH` from the validated Phase 4 STATUS when a later phase needs them; if it cannot, the error should name the missing upstream artifact. The dirty-tree diagnostic should print which allow-list inputs were active/inactive, so an unset `PLAN_PATH` cannot masquerade as user dirt.

Generate or test the appendix/render-key coverage from this registry so the appendix is not a second authoritative list. If full generation is too large initially, add `render_prompt --check <role>` to list required and optional keys without dispatching.

**Acceptance coverage.** Every appendix variable must appear in exactly one role contract; every role's output path must match its appendix; a fresh Phase 6 shell must recover `PLAN_PATH`; intentionally empty optional inputs must render without manual caller knowledge.

**Proposed by:** **3** distinct files — S2 (optional inputs and guessed paths), S5 (input manifest and lost `PLAN_PATH`), S6 (unset iteration/prelaunch failures).

### R09 — Make preflight evidence-based and preserve proven dual-vendor coverage

**Current gap.** A cheap, nondeterministic preflight can veto a vendor that already completed substantive work in the same run. Real Codex probes reported missing skills that existed, or failed only to publish STATUS, causing later review gates to lose the second opinion. In one run, the omitted Codex code reviewer subsequently found serious financial-data-loss defects that the single Claude reviewer missed. The current prompt still permits a per-phase failed probe to reduce a review gate to one vendor.

**Concrete change.** Strengthen both the probe and its policy:

1. `MISSING_SKILLS` must include evidence: skill name, probed paths/plugin roots, and whether the path was absent or unreadable. Probe by skill name across installed plugin marketplaces rather than one hard-coded Superpowers root.
2. Re-probe once when a per-phase `MISSING_SKILLS` contradicts a prior READY result in the same run, or when the missing skill is independently visible through a deterministic filesystem check.
3. Apply R04's self-verifying publication protocol. Treat a sibling `.tmp` as publication loss worthy of one cheap retry, without reading/promoting it.
4. Track `vendor_proven=true` after a successful non-preflight dispatch. A later preflight publication/self-failure must be advisory when direct evidence shows the vendor can perform the upcoming role. Permanent auth, model rejection, and spend ceiling remain authoritative.
5. For Phase 7 especially, require two-vendor substantive review unless the user explicitly accepts degraded coverage. A single-vendor result can never be called a strict PASS; mark summaries written under partial coverage provisional.
6. A PASS from one reviewer never cancels findings from another. Gate counts are the union/sum of all active reviewer findings.
7. Readiness must state which phases/iterations and how many blockers/majors were single-reviewed—not just `partial_review: true`.
8. Immediately before roles expected to run longer than one hour, perform a minimal vendor readiness/headroom check after all free gates. A detected spend ceiling prevents launching doomed long work; a successful canary proves only current liveness, not that enough budget exists to finish the role.

**Acceptance coverage.** Test a false MISSING_SKILLS followed by READY, publication-lost `.tmp`, prior successful reviewer plus failed probe, true auth failure, long-role spend ceiling detected before launch, and Phase 7 single-vendor pass. Only genuine capability loss may remove proven coverage without an explicit degradation decision.

**Proposed by:** **4** distinct files — S2, S3, S4, and S5.

### R10 — Detect review-loop divergence using provenance, recurrence, and growth

**Current gap.** The current review policy uses severity counts and a hard iteration cap. It cannot tell newly surfaced coverage from recurring unfixed findings or—most importantly—defects introduced by the previous fixer. The allocation-engine run showed negative marginal yield: most genuine defects appeared in round 1, seven of nine blockers targeted fix-added text, and the spec grew from roughly 45 KB to 378 KB before post-run consolidation reduced it to 194 KB.

**Concrete change.** Extend reviewer/fixer STATUS and gate state:

1. Give every finding a stable ID/fingerprint using artifact, location/symbol/section, normalized issue, and origin reviewer.
2. Require `provenance: original | fix-added:<iteration>` and `relationship: new | recurring | regression | duplicate/subsumed`.
3. Record artifact bytes/lines before and after every fix, changed sections/files, finding counts by category, recurring count, fix-added count, and per-round cost.
4. Add convergence rules evaluated after each review round:
   - halt `DIVERGING` when blockers target fix-added text in two consecutive rounds;
   - halt/route to owner when blockers+majors fail to fall for two rounds while the artifact grows materially;
   - escalate when one section/mechanism is changed in three consecutive rounds;
   - distinguish coverage expansion (mostly new findings in untouched areas) from failed convergence (recurring/regression findings).
5. For coverage expansion, offer decomposition or one targeted coverage pass. For divergence, stop adding fixes and dispatch a condensation/simplification or owner-decision step.
6. Keep a hard cap as a final safety bound, but do not make it the only stopping mechanism. Consider a default spec-review cap near three after the provenance rules are in place; validate with more runs before changing every gate's cap.
7. Make later reviews diff-aware: prioritize changed sections and their dependency/ripple surface while retaining permission to report regressions elsewhere. This makes later rounds cheaper without exempting unchanged content.

**Acceptance coverage.** Feed synthetic histories representing true convergence, newly surfaced coverage, flat counts with growth, and fix-induced regressions. The gate must choose different actions for each and preserve the complete finding history.

**Proposed by:** **3** distinct files — S2 (new versus recurring and fix-induced regression), S3 (flat counts, plan growth, diff-aware review), S5 (post-run divergence analysis and growth evidence).

### R11 — Eliminate unreviewed final fix passes

**Current gap.** At iteration 3+, the current prompt applies majors in one final fixer pass and deliberately does not re-dispatch reviewers. This is the most dangerous moment to skip verification: real final fix passes repeatedly changed the same path that prior fix rounds had already regressed. Owner-approved gate closure without re-review also left the readiness report unable to distinguish “fixed and verified” from “fixed but unchecked.”

**Concrete change.** Replace the unconditional no-re-review rule with a bounded verification rule:

1. Every final fix pass produces a precise change surface (files/sections/symbols and finding IDs).
2. Run one **verification-only re-review** over the fixed findings and their dependency/ripple surface. It may report regressions/blockers, but it does not restart broad discovery by default.
3. Require both active vendors for verification when both participated in the finding, when they converged independently, or when the fix touches correctness/safety/state-machine/concurrency behavior.
4. If verification finds a blocker or a regression caused by the final fix, the gate cannot pass. Route through the divergence policy rather than silently applying a third unreviewed rewrite.
5. If an owner closes the gate without verification, record `verified: false`, `unverified_fix_rounds: N`, the accepted findings, and the decision event. Readiness must cap at `READY_WITH_NOTES` or `NOT_READY` according to risk.
6. Enforce the discharge window: Phase 5 must be verified or explicitly overridden **before** Phase 6 begins. Never attempt to re-review a plan after implementation has consumed its anchors; classify that artifact `STALE` and state that the old gate can no longer be discharged.

**Acceptance coverage.** Test strict pass, relaxed final fix verified clean, final-fix regression, dual-vendor convergence, owner override without verification, and attempted post-implementation plan review.

**Proposed by:** **3** distinct files — S2 (unverified relaxed fixes and regressions), S3 (owner-closed Phase 5 and impossible post-implementation remedy), S5 (explicit unverified-fix evidence).

### R12 — Make fixer behavior convergent, bounded, and document-aware

**Current gap.** Fixers are instructed only to address findings. They can answer a process/form problem by adding more normative machinery, preserve long correction chains in the artifact, or introduce contradictions in referenced sections. Large all-at-once fix passes then fail mid-stream. The process has no explicit rule that a design spec describes the system rather than gating its own acceptance.

**Concrete change.** Amend the spec-fixer and plan-fixer contracts:

1. Classify incoming findings before editing:
   - **content:** wrong/missing/contradictory system rule—fix in the artifact;
   - **process/form:** scope too broad, missing external evidence, artifact not self-contained, delivery/acceptance sequencing—return `PARTIAL/BLOCKED_FOR_DECISION` to the owner/orchestrator;
   - **duplicate/subsumed:** record the mapping and do not edit twice.
2. A spec specifies the system, not its own acceptance. Plans own sequencing/rollback; UAT owns pass/fail evidence. Reviewers must flag self-gating spec language as a process finding.
3. Prefer deletion, consolidation, and simplification over adding another gate/check/order rule. Rewrite normative text in present tense and in one place. Put fix history in iteration artifacts, not in the normative spec/plan. Preserve a correction note only when it prevents a likely future mistake and fits briefly.
4. After each change, re-read every section that references the changed rule and report `ripple_checked` plus the checked locations.
5. Batch work by bounded finding count/section size and checkpoint after each batch (R05). For very large artifacts, operate on addressed sections with enough surrounding contract to validate consistency.
6. Add a `PARTIAL` verdict containing addressed IDs and unresolved decision IDs. Completed fixes are not discarded merely because one item needs authority.
7. If a section is repaired repeatedly, stop and ask whether the mechanism should exist; optionally dispatch a condensation role whose mandate is removal, followed by verification that no normative rule was lost.

**Acceptance coverage.** Review/fix fixtures should include a process finding, duplicate finding, cross-reference ripple, superseded correction chain, and repeated overgrown mechanism. Output must become smaller or no larger unless growth is justified.

**Proposed by:** **3** distinct files — S2, S5, and S6.

### R13 — Represent decisions, accepted risk, corrections, and post-HALT resumes explicitly

**Current gap.** User-authorized post-HALT redispatch looks structurally identical to an illegal automatic retry. Owner approvals and accepted risks are often written as ad hoc prose, and fixer appendices have no declared input for the ruling. The event grammar cannot represent general phase acceptance, correction of a bad append-only field, or a blocker that has been dispositioned. `BLOCKED` also conflates missing authority with missing capability.

**Concrete change.** Add a small, explicit decision protocol:

1. New RUN_LOG events with stable IDs:
   - `OWNER_DECISION`/`ORCHESTRATOR_DECISION` — scope, decision, authority, affected findings/artifacts, allowed blast radius;
   - `RESUME_AFTER_HALT` — halting event/attempt, chosen recovery, partial-work disposition, new attempt;
   - `FINDING_DISPOSITIONED` — finding ID, accept/defer/reject, justification, owner, verification effect;
   - `PHASE_ACCEPTED_BY_OWNER` — unmet completion artifact/criterion and reason;
   - `CORRECTION` — event ID, corrected field, previous value, new value, reason.
2. Add `$OWNER_DECISIONS_PATH` or a structured rendered variable to fixers/reviewers. Do not overload `$FINDINGS_PATHS` with prose. Reviewers receive active dispositions so they do not re-litigate them, but summaries retain the accepted risk.
3. Split `BLOCKED` into at least `AUTHORITY_REQUIRED`, `CAPABILITY_BLOCKED`, and `ARTIFACT_INTEGRITY_BLOCKED`, or add a required `blocker_class`. Solo mode may resolve only explicitly granted authority cases; production, destructive history operations, broad credential changes, and user work at risk remain hard stops.
4. Gate calculations use undispositioned findings, while readiness reports both raw and dispositioned counts. Approval never masquerades as clean reviewer verification.
5. A fixer `PARTIAL` result names exactly what decision, owner, and artifacts would unblock it.
6. Keep authorized-retry caps explicit even in solo mode. Standing authority removes latency, not safety bounds.

**Acceptance coverage.** Exercise automatic retry, user resume, solo authority decision, accepted-risk blocker, phase acceptance, correction of an append-only misclassification, and a true capability block. Each must be machine-distinguishable.

**Proposed by:** **6** distinct files — all sources S1-S6 contain direct evidence for explicit authorization/resume/disposition state.

### R14 — Give every mutating dispatch an exclusive write lease and reversible snapshot

**Current gap.** The process checks the dirty tree at Phase 1 and Phase 6, but assumes it remains the only writer afterward. A human/editor changed documentation during a documentation pass, and an orchestrator-side commit appeared inside an active implementation range. The subagents correctly stopped because they could not distinguish authorized foreign changes from corruption.

**Concrete change.** Introduce phase-level write ownership:

1. Immediately before every mutating dispatch, capture target paths (when knowable), tree status, HEAD, and hashes/blob IDs of artifacts it will edit.
2. Declare in the prompt that while the attempt holds the lease, the orchestrator must not write/commit in the target repository and parallel roles must not overlap write sets.
3. Before each write/commit and before STATUS publication, the mutating role verifies that files it read have not changed unexpectedly. On mismatch, preserve the other writer's work and return `ARTIFACT_INTEGRITY_BLOCKED` with exact paths.
4. Snapshot each mutable spec/plan before a fixer attempt so “rollback this attempt” restores the pre-attempt artifact, not the pre-run commit and all earlier valid fixes.
5. Add `DECLARED_FOREIGN_COMMITS`/declared external changes to continuation inputs. The role may ignore only explicitly declared SHAs/paths with reasons.
6. Re-run a scoped dirty-tree/lease check before the documentation phase and git finalization, not only before implementation.

**Acceptance coverage.** Simulate unrelated human edit, overlapping edit, orchestrator commit during implementation, declared foreign commit, and rollback of one fixer attempt. No other writer's changes may be clobbered.

**Proposed by:** **3** distinct files — S2 (concurrent documentation writer), S3 (orchestrator commit during implementation), and S5 (per-attempt snapshots and dirty allow-lists).

### R15 — Make plan executability and verification exclusions first-class

**Current gap.** Plans can pass review while containing tasks the implementer cannot execute: deployment, credentials, owner actions, or tests that only run against a live stage. The implementer then reports incomplete work or `verification=PARTIAL`, which the current process sends into a debugger loop even when the failing check is pre-existing, environment-bound, or not applicable locally. Wall-clock tests on uncontrolled developer machines can also produce false process blockers.

**Concrete change.** Extend plan review and implementation STATUS:

1. Every plan task declares `actor/capability` (`implementer`, `owner`, `CI`, `deployed-environment`), prerequisites, destructive/external side effects, and where its verification can run.
2. Plan reviewers verify every task is executable by its declared actor. Human-gated tasks become explicit handoff/UAT items rather than surprise incomplete tasks.
3. Replace one `verification` scalar with per-command results: `PASS`, `FAIL`, `EXCLUDED`, or `NOT_RUN`, plus evidence and scope. Overall success may include documented exclusions only when policy permits.
4. A verification exclusion must identify the command, why it is outside the change's capability/scope, baseline comparison or environment evidence, and the handoff needed. It cannot hide a new branch regression.
5. Measurement-based findings require a remeasurement before escalation and record host/CI conditions. Enforce wall-clock bounds only on controlled hardware; otherwise make them advisory/skip-with-reason.
6. The debugger loop consumes only genuine `FAIL` results. `EXCLUDED` routes to readiness/handoff, not mutation of a deployed environment.

**Acceptance coverage.** Include a deploy-only acceptance task, missing credential, pre-existing deployed-stage failure, genuine local regression, and loaded-host performance miss that passes on controlled rerun.

**Proposed by:** **2** distinct files — S2 (process-executable plan tasks) and S5 (verification exclusions and environmental timing evidence).

### R16 — Use a dedicated, findings-bounded Phase 7 implementation fixer

**Current gap.** Phase 7 reuses the full Phase 6 implementer. Despite Mode C, a real fix dispatch continued from two review findings into substantial unrelated feature work, expanding the diff under review and creating unreviewed scope. The shared fixed STATUS path also compounds R03.

**Concrete change.** Add `code-fixer` as a separate role, or tighten Mode C until it is contractually equivalent:

1. Inputs are only the current attempt, baseline, plan/spec for constraints, and exact finding IDs/paths.
2. Address only listed BLOCKER/MAJOR findings and the minimal tests required for them. No backlog, opportunistic refactor, plan continuation, fixture redesign, or unrelated cleanup.
3. Record one commit (or tightly grouped commits) per finding and a finding-to-commit map.
4. Run targeted tests plus the required regression/full verification subset, publish a change surface, and stop.
5. Return `PARTIAL/BLOCKED` for findings needing decisions; never continue into unrelated plan tasks.
6. Give it an attempt-scoped STATUS under the Phase 7 iteration, leaving Phase 6's terminal implementer STATUS immutable.

**Acceptance coverage.** Seed an unrelated tempting cleanup beside two findings; the role must modify only the findings' necessary surface and Phase 7 reviewers must see an exact bounded diff.

**Proposed by:** **1** distinct file — S5 (2026-08-12 12:25).

### R17 — Stop hand-copying the runtime cookbook; source one tested implementation

**Current gap.** The prompt requires the entire roughly 450-line cookbook to be pasted into every phase Bash block even though the repository tests already extract it. Real runs repeatedly mistranscribed helpers or recreated Bash bugs (`local iter="$1" dir="...$iter"` under `set -u`). Every phase starts as a new hand-written program, so tested helper text and executed helper text can diverge.

**Concrete change.** Keep the prompt as the normative source but make runtime execution single-source:

1. Have `develop-it.sh` or a deterministic checked-in build step extract all `lint: cookbook` blocks to a versioned/generated `develop-it-runtime.sh` after tests validate it.
2. Export its absolute path and SHA-256. Each phase sources that file and verifies its hash against the process version recorded at run start.
3. The generated runtime contains definitions only; no top-level side effects. Phase blocks define only phase-specific variables/actions.
4. If committing a generated helper is undesirable, create it once in a controlled temporary location at launch, read-only for the run, rather than reconstructing it in every model-generated block.
5. Until this is implemented, relax “paste the whole cookbook” to “include every helper called plus its dependency closure verbatim,” and add lint-generated dependency bundles per phase. This is a transitional option, not the preferred end state.
6. Add an explicit Bash pitfalls section enforced by shellcheck/tests: split `local` declaration from dependent assignment; never make conditional `&&` the final statement; do not use command substitution/pipelines when global result variables must survive; never `set -e`.

**Acceptance coverage.** Tests compare the runtime hash/text with prompt cookbook blocks, source it in a pristine shell, execute every helper contract, and ensure phase snippets no longer contain copied helper definitions.

**Proposed by:** **3** distinct files — S2 (cookbook size and transcription defect), S4 and S6 (repeated `local`/`set -u` failures).

### R18 — Automate RUN_LOG/proposition reconciliation

**Current gap.** Completion requires a strict 1:1 match between RUN_LOG failure/retry events and proposition entries, but the orchestrator is forbidden to read the proposition it is writing. Real retry wrappers omitted required entries and also generated entries for attempts that never launched. The count is precise enough to automate but unsafe to enforce by model memory.

**Concrete change.** Add a deterministic post-run audit tool or delegated audit role:

1. Parse RUN_LOG blocks into attempt/event records; derive launched attempts, failures, structural retries, HALTs, cap events, and corrections using the new attempt IDs.
2. Parse only proposition headers/metadata needed for reconciliation (`timestamp`, phase, trigger, attempt/event ID). Keep proposition body non-influential.
3. Match by stable event/attempt ID, not a ±60-second heuristic. Require exactly one proposition entry for every mandatory event and no mandatory-tag entry without a real event.
4. Run the checker before readiness finalization, with explicit authority to read metadata from both files. It reports discrepancies; it does not let proposition content change gate verdicts.
5. Prefer generating mandatory proposition entry headers from the same event-emission helper, leaving only context/recommendation prose to the orchestrator. This prevents missing tags while preserving the observation function.
6. Reconcile continuation attempts even when they use a new attempt/iteration number; “retry” becomes an explicit relationship, not an adjacency guess.

**Acceptance coverage.** Test missing entry, duplicate entry, false entry for a prelaunch failure, authorized resume, non-mutating automatic retry, cap+override as two events, and extra uncounted deviation entries.

**Proposed by:** **2** distinct files — S4 (unverifiable completion criterion) and S6 (missing/false retry and failure entries; request for tooling).

### R19 — Add a documentation and human-handoff phase with durable follow-ups

**Current gap.** The current pipeline ends with git finalization and readiness. There is no phase that reconciles intended versus realized behavior, updates durable high-level docs, or consistently produces a UAT guide. Follow-ups discovered mid-run have no sanctioned artifact and may survive only in conversation. Deferred final-fix items remain in run artifacts rather than the canonical documentation.

**Concrete change.** Insert a documentation phase after tests/git stabilization and before readiness (renumber readiness accordingly):

1. Add an orchestrator-writable or role-owned `followups.md` created during the run. Entries contain origin phase, item, owner/actor, prerequisite, risk, and status. Readiness and documentation consume it.
2. Dispatch a mutating `doc-writer` with the final diff/baseline, spec, plan, implementation/test/review summaries, dispositions, and follow-ups.
3. Update the spec and plan by **appending an auditable planned-versus-realized record**, findings, and deltas. Do not rewrite original decisions to pretend the implementation always matched them.
4. Refresh relevant README, architecture, progress/roadmap, and operational docs only where the change made them stale.
5. Produce a UAT document following project conventions: prerequisites, step-by-step actions, expected results, smoke checks, rollback/cleanup, and a clear `Not yet executed` section for owner/deployment/credential-gated steps.
6. Use R14's write lease/hash checks because documentation is especially likely to overlap human editing.
7. Give outputs their own review/validation, at least for UAT commands and expected results, then let readiness cite these final durable artifacts.

**Acceptance coverage.** A feature with deferred majors, a human deploy step, an unexecuted acceptance test, and concurrent doc edit must produce a truthful UAT/handoff without erasing planned-versus-realized drift.

**Proposed by:** **1** distinct file — S2 (2026-08-04 07:55, 12:41, and 13:06).

### R20 — Discover and route optional, task-relevant skills

**Current gap.** Preflight maintains a fixed all-required roster. A skill from another marketplace, such as frontend design, cannot be represented as useful-but-optional; adding it would create a new global HALT condition. Context discovery already learns both installed skills and project shape but does not connect them to planning or implementation.

**Concrete change.** Add conditional skill routing:

1. Split preflight output into `required_skills_*` and `optional_skills_present/absent`; optional absence never halts.
2. Discover skills marketplace-agnostically by registered name/metadata across installed plugin roots.
3. Have context discovery emit project capabilities/work types (frontend, data visualization, domain modeling, infrastructure, etc.) and `applicable_optional_skills = installed ∩ relevant` with reasons.
4. Pass applicable skills to the plan writer so only relevant tasks cite them, and to the implementer so only the subagents working those tasks load them.
5. Record skill usage per task and note relevant-but-unavailable optional skills in readiness as advice, not failure.
6. Keep backend-only or otherwise irrelevant work unchanged; this is targeted routing, not global prompt expansion.

**Acceptance coverage.** Test a React repo with frontend skill in a non-Superpowers marketplace, a backend-only repo, an absent optional skill, and an absent required skill.

**Proposed by:** **1** distinct file — S3 (2026-08-05 12:41).

### R21 — Sanity-check artifacts and gate discharge windows before expensive downstream work

**Current gap.** A plan writer can leave a large but structurally truncated plan and no STATUS; the current process can still spend full reviewer passes on it. Conversely, readiness once prescribed a post-implementation plan review even though executing the plan had consumed its textual anchors, making success impossible.

**Concrete change.** Add phase transition preconditions:

1. Before every review gate, require the producer attempt to have a fresh valid success STATUS (or an explicit `PHASE_ACCEPTED_BY_OWNER` decision) and the artifact to exist, be non-trivial, end cleanly, contain required top-level sections, and have no obvious truncation/TODO markers.
2. Use a cheap structural validator, not an Opus reviewer, for this sanity check. If the producer failed after writing an artifact, do not infer completeness from size.
3. Before Phase 6, require the Phase 5 gate to be verified clean or explicitly accepted. Record whether fixes were reviewed.
4. Readiness remedies must be achievable from current state. It should verify prerequisites before saying “run one more review.”
5. Add a `STALE` outcome for artifacts whose validation window has passed (for example, an implementation plan after it has been executed and its anchors changed). Report the historical process gap; do not spend on a review that cannot pass.
6. Validate STATUS-referenced summary paths and required summarizer outputs before transitioning; Phase 8's summarizer must not be silently skipped.

**Acceptance coverage.** Test truncated plan/no STATUS, complete artifact with lost terminal STATUS and explicit owner acceptance, missing summary, active Phase 5 blocker, and post-implementation plan-review request.

**Proposed by:** **2** distinct files — S3 and S5.

### R22 — Let observed context7 degradation override the Phase 1 reachability result

**Current gap.** `context7_policy()` checks the Phase 1 STATUS first and immediately returns `required`; it checks `event=CONTEXT7_UNAVAILABLE` only when Phase 1 did not report reachable. A quota failure discovered later therefore cannot downgrade subsequent roles, even after the event is logged.

**Concrete change.** Invert precedence:

1. Scan RUN_LOG first for the latest `CONTEXT7_UNAVAILABLE` and any future `CONTEXT7_RESTORED` event.
2. If the latest applicable event says unavailable, return `best-effort` regardless of the earlier reachability probe.
3. Only when no later degradation exists should Phase 1 `context7: reachable` produce `required`.
4. Require any role discovering quota/unavailability to record it in STATUS; the orchestrator emits the event once and downstream phases reconstruct policy from durable state.
5. Distinguish missing server, transient error, and quota ceiling in readiness, without halting work that already has a best-effort policy.

**Acceptance coverage.** Phase 1 reachable followed by quota exceeded must yield best-effort in Phase 5; a later restored event must re-enable required mode only if restoration semantics are explicitly supported.

**Proposed by:** **1** distinct file — S6 (2026-08-13 15:04).

### R23 — Run every free preflight gate before paid model probes

**Current gap.** Step 1.0 still runs `probe_models` before the dirty-tree and gitignore gates while calling the group free even though model probes spend tokens. A dirty tree can therefore cause a predictable halt only after paid calls.

**Concrete change.** Reorder and label Step 1.0 explicitly:

1. Initialize orchestration variables and derive canonical paths without dispatching a model.
2. Run the local CLI canary, dirty-tree gate, process-path validation, and gitignore/advisory checks. These are the zero-token gates and retain their existing authoritative policies.
3. If any free gate halts, record it and make no model or dispatched skill/MCP probe.
4. Only after all free gates pass, call `probe_models`, once per distinct model ID, and label it “paid but minimal” rather than free.
5. Run dispatched skill/MCP capability probes after model liveness is known, preserving their existing evidence in preflight STATUS.
6. The launcher may print a non-authoritative dirty-tree advisory for convenience, but it must not duplicate the feature-slice allow-list or decide whether the run can proceed.

**Acceptance coverage.** With a dirty target tree, fake model CLIs must receive zero calls. With a clean tree, model probes run once per distinct model ID.

**Proposed by:** **2** distinct files — S3 and S4.

### R24 — Treat an untracked process prompt as dirty/unknown, never clean

**Current gap.** `process_identity` uses `git diff --quiet HEAD -- <path>`. Git reports no diff for an untracked file, so an untracked process prompt is logged as `develop_it_dirty: no` even though HEAD cannot reproduce it.

**Concrete change.** Make process identity a typed sequence:

1. Resolve the process repository and repository-relative prompt path as today; never run the tracking check against the target repository by accident.
2. Run `git ls-files --error-unmatch -- "$PROCESS_PATH_REL"` before `git diff`.
3. If tracked, retain `develop_it_dirty: no|yes` from the HEAD comparison. If untracked—including ignored-untracked—record `develop_it_dirty: untracked`; do not translate Git's empty diff into `no`.
4. Keep `develop_it_dirty: unknown` only for a non-git process path or an identity check that cannot be completed reliably, and include a diagnostic reason in the surrounding record.
5. Update the RUN_LOG grammar, validators, summaries, fixtures, and process-identity tests to accept and preserve the typed state.
6. Continue recording SHA-256 independently of Git state so an untracked or modified prompt remains exactly identifiable and reproducible from the logged file content.

**Acceptance coverage.** Test tracked-clean, tracked-modified, untracked, ignored-untracked, and non-git process prompts.

**Proposed by:** **1** distinct file — S2 (2026-08-03 14:38 process identity entry).

## Already incorporated or intentionally retained

These source proposals should not create duplicate work because the current prompt already contains the material behavior or the observed behavior was explicitly correct:

- **Pre-folder HALTs create the feature folder and log an event.** Implemented in Phase -1 Step 1.0. Source: S1.
- **Phase 1 relocates STATUS before logging its canonical path.** Implemented in Step 1.1/1.2. Source: S1.
- **Long-dispatch selection compares role timeout with the host foreground limit instead of naming three roles.** Implemented in `Long dispatch`. Sources: S1/S4.
- **Failure diagnosis reads stdout JSON `.result`/`is_error` as well as stderr.** Implemented by `vendor_error_text`/`post_dispatch`. Source: S1.
- **Spend ceilings are Mode 5b, run-scoped, non-retryable, and suppress later vendor dispatches.** Implemented in `Mode 5 has two shapes`. Sources: S1/S3.
- **The process is autonomous/solo and should not re-confirm rules already decided by the document.** Implemented in the orchestration contract. Sources: S2/S3/S4. R13 is still needed for machine-readable decisions and safe authority limits.
- **Background dispatches escape the foreground Bash-call ceiling.** Recorded in current `Long dispatch`; no extra process protocol is needed. Source: S4.
- **Dispatch success requires a valid STATUS, not rc=0 alone.** Implemented in `dispatch_state`/`validate_status`; R03-R07 strengthen freshness and classification. Sources: S3/S5.
- **The git finalizer must not push.** Explicitly implemented in the finishing-branch appendix. Source: S5.
- **The Phase 8 summarizer is explicit and required.** Present in Step 8.2 and completion criteria. The old missed-summarizer incident remains useful evidence for R21. Source: S2.
- **The documented relaxed threshold is not a user decision point below the cap.** Current autonomy language and gate rules prescribe progression. Source: S2/S3.
- **Correct HALTs and non-mutating redispatch behavior remain valid where no safer continuation evidence exists.** “None” entries in S1 are retained as positive coverage, not discarded.

The following proposal is **not recommended as a separate process change**: duplicating the authoritative dirty-tree gate in `develop-it.sh`. A lightweight advisory is harmless, but the launcher and RUNBOOK deliberately avoid a second policy implementation. R23 obtains the main benefit—no paid probes before a dirty-tree halt—without creating policy drift. Source: S3 (2026-08-05 05:12).

## Exhaustive source coverage

This appendix prevents consolidation from erasing source detail. Every one of the 137 dated proposition entries appears once below. The entry text is a compact restatement of the observed issue and proposed direction; the cited original remains authoritative for its full evidence, commands, and wording.

Disposition keys:

- **Rxx:** represented by the detailed recommendation with that ID; multiple IDs mean the source entry contained separable concerns.
- **A:** already incorporated in the current prompt; retain and regression-test the behavior.
- **K:** observed behavior was correct or the source proposed no change; keep it as positive process coverage.
- **N:** not recommended as a separate change; the row states where its useful intent is retained.

### S1 — Raw event v3 date columns (10/10)

Original: [process-improvement-proposition.md](../prism/docs/superpowers/specs/2026-07-30-raw-event-v3-date-columns-artifacts/process-improvement-proposition.md)

| Entry | Source observation/proposition, without loss of disposition | Disposition |
|---|---|---|
| S1-01 (line 11) | A pre-folder Phase -1 HALT could not be logged because the feature folder did not yet exist; create the folder and RUN_LOG before logging the halt. | A |
| S1-02 (line 16) | Phase 1 initially logged a temporary STATUS path even though the file was later relocated; relocate first and log only the canonical feature-folder path. | A |
| S1-03 (line 21) | Long-dispatch eligibility was hard-coded to three role names; derive it from whether the role timeout exceeds the host foreground-call ceiling. | A |
| S1-04 (line 26) | A Claude spend-limit failure appeared in stdout JSON rather than stderr; parse `.result` and `is_error` when classifying vendor failure. | A |
| S1-05 (line 31) | The spend ceiling was correctly recognized as a conservative HALT rather than retried; no process change was proposed. | K |
| S1-06 (line 36) | The concrete friction behind S1-04 was that useful vendor diagnostics were hidden in the stdout envelope; make result extraction part of the shared error path. | A |
| S1-07 (line 41) | “Retry needs authorization” did not distinguish an already-prescribed retry from a genuinely new user decision; make that authority machine-readable. | R13 |
| S1-08 (line 46) | Re-dispatch after an ambiguous/interrupted run needed a durable event explaining why the second attempt was authorized and what evidence was reused. | R13 |
| S1-09 (line 51) | Claude spend exhaustion should be recorded once for the run and suppress subsequent Claude work, rather than repeatedly re-probing a known ceiling. | A |
| S1-10 (line 56) | Re-dispatching the non-mutating readiness role after an ambiguous result was judged safe and correct; retain it as positive recovery coverage for the bounded recovery rules. | K |

### S2 — Monthly bills (26/26)

Original: [process-improvement-proposition.md](../prism/docs/superpowers/specs/2026-08-03-monthly-bills-artifacts/process-improvement-proposition.md)

| Entry | Source observation/proposition, without loss of disposition | Disposition |
|---|---|---|
| S2-01 (line 11) | The process prompt, launcher, and RUNBOOK duplicated large runtime cookbook fragments that drifted; keep one tested implementation and generate or source consumers from it. | R17 |
| S2-02 (line 17) | Parallel dispatch durations were recorded as serial elapsed time, overstating wall-clock time; log attempt-level monotonic start/end timestamps and calculate parallel groups correctly. | R07 |
| S2-03 (line 23) | `git diff --quiet HEAD -- <process-file>` reports an untracked prompt as clean; distinguish tracked-clean, modified, untracked, and unknown identities. | R24 |
| S2-04 (line 29) | A one-character hand-transcription error malformed RUN_LOG telemetry; explicitly permit in-place repair of a just-written malformed block and remove the copied-helper root cause. | R07, R17 |
| S2-05 (line 35) | Review loops needed to distinguish recurring issues from genuinely new majors and stop growing artifacts rather than mechanically adding more text. | R10, R12 |
| S2-06 (line 41) | A missing-skill report halted without testing whether the skill was genuinely unavailable; require direct, role-capable evidence and a bounded reprobe. | R09 |
| S2-07 (line 47) | Preflight recorded `MISSING` from weak or contradictory evidence even though later work proved capability; make availability evidence typed, preserved, and challengeable. | R09 |
| S2-08 (line 53) | An orchestrator-authorized retry needed an explicit event rather than an implied exception to the “do not retry” rule. | R13 |
| S2-09 (line 59) | A documented quality threshold below the cap was already a prescribed transition, not a reason to ask the user again. | A |
| S2-10 (line 65) | The preflight micro-role could leave only a malformed `.tmp`; prescribe a safe atomic publication recipe and verify the final STATUS. | R04 |
| S2-11 (line 71) | Optional appendix variables and role-specific paths were passed inconsistently; declare all inputs in a single role contract rather than relying on ambient prose. | R08 |
| S2-12 (line 77) | Claude print-mode background children hit a hidden 600-second wait ceiling; configure the ceiling and forbid yielding while children remain. | R02 |
| S2-13 (line 83) | Long work should fail pre-dispatch if the effective nested/background ceiling is shorter than the role timeout. | R02 |
| S2-14 (line 89) | The implementer needed an explicit continuation mode that consumes durable completed-task evidence rather than restarting or HALTing after partial work. | R05 |
| S2-15 (line 95) | Plans could pass review while leaving commands, verification, or implementation order too vague to execute; make executability a formal gate. | R15 |
| S2-16 (line 101) | A failed Codex probe was treated as proven vendor unavailability without sufficient transport/result evidence; preserve evidence and avoid false solo mode. | R09 |
| S2-17 (line 109) | Claude inherited the process repository CWD and rejected or mishandled target-repository work; pin every Claude subprocess to `REPO_ROOT`. | R01 |
| S2-18 (line 115) | One real vendor failure caused asymmetrical provisional coverage to be accepted too readily; require proven failure and preserve the healthy vendor's full review role. | R09 |
| S2-19 (line 121) | A stale implementer STATUS could satisfy a later failed dispatch because status identity was not attempt-scoped. | R03 |
| S2-20 (line 127) | Useful deferred work and human-facing follow-ups were not durably handed off; add a structured follow-up artifact and final summary section. | R19 |
| S2-21 (line 133) | When both vendors are available, dual-vendor coverage is a required correctness property, not an optional optimization. | R09 |
| S2-22 (line 139) | The final fixer pass could introduce regressions and then escape review because the loop ended immediately after fixing. | R11 |
| S2-23 (line 145) | STATUS paths, schemas, and helper behavior were duplicated per role and could fail silently; publish them in a role registry and use one verified publisher. | R04, R08, R17 |
| S2-24 (line 151) | The run missed the Phase 8 summarizer even though completion expected its output; the current prompt now names the summarizer and requires its STATUS/output explicitly. | A |
| S2-25 (line 157) | Documentation was left implicit after implementation; add a documentation/handoff phase with scoped outputs and verification. | R19 |
| S2-26 (line 179) | A concurrent documentation writer could collide with other mutating roles; any such phase needs the same exclusive write lease, snapshots, and ownership rules. | R14, R19 |

### S3 — Prism user auth (15/15)

Original: [process-improvement-proposition.md](../prism/docs/superpowers/specs/2026-08-05-prism-user-auth-artifacts/process-improvement-proposition.md)

| Entry | Source observation/proposition, without loss of disposition | Disposition |
|---|---|---|
| S3-01 (line 11) | Moving the full dirty-tree gate into `develop-it.sh` would prevent paid work earlier but duplicate policy; retain only an optional advisory and reorder the authoritative process gates. | N; R23 keeps the cost-saving intent |
| S3-02 (line 17) | Free local gates should precede paid model probes so a predictable dirty-tree halt incurs no token cost. | R23 |
| S3-03 (line 23) | The tiny Codex probe budget encouraged unsafe hand-written `.tmp` publication; provide a canonical publisher or enough budget to write, validate, rename, and read back. | R04 |
| S3-04 (line 29) | Recurrent Codex STATUS publication loss forfeited whole phases of dual review; make the probe self-verifying, retry once when `.tmp` proves publication loss, and report the exact coverage forfeited. | R04, R09 |
| S3-05 (line 43) | Plan/spec review should be diff- and provenance-aware, detect recurrence and growth, and distinguish convergence from expanding scope. | R10 |
| S3-06 (line 55) | Future-tense “will run” dispatch records could survive as if work had launched, leaving idle/ambiguous state; use observed launched/finished events and detect an owed-but-idle dispatch. | R07 |
| S3-07 (line 69) | The autonomous process must not re-confirm decisions already prescribed by the process. | A |
| S3-08 (line 83) | Genuine owner approval, risk acceptance, or scope changes must be represented explicitly rather than inferred from prose. | R13 |
| S3-09 (line 95) | Skill-owned SDD artifacts could remain outside the feature folder and disappear; mirror or configure custody under `6-implementation` after every task. | R05 |
| S3-10 (line 111) | The process used only mandatory skills and ignored optional task-relevant capabilities; add discovery, relevance routing, and recorded usage/non-usage. | R20 |
| S3-11 (line 129) | Spend ceilings, interrupted work, and checkpoints are different states: the run-scoped vendor stop remains correct, while resumable local progress must survive it. | A for spend policy; R05 for checkpoints |
| S3-12 (line 141) | `rc=0` without a final STATUS exposed the hidden 600-second background ceiling; retain artifact-not-exit success, classify this non-run explicitly, checkpoint long roles, and dispatch them with a compatible ceiling. | R02, R04, R05, R06 |
| S3-13 (line 155) | Orchestrator commits and foreign commits during a mutating phase were not attributed safely; introduce write ownership, snapshots, and explicit accepted foreign state. | R13, R14 |
| S3-14 (line 169) | Solo/autonomous mode was already the intended operation and should not trigger routine user confirmation. | A |
| S3-15 (line 197) | Plan-review fixes must be re-reviewed before implementation consumes the plan's anchors; readiness remedies must be reachable from current state and stale post-implementation plan review must not be dispatched. | R11, R21 |

### S4 — Events viewer (18/18)

Original: [process-improvement-proposition.md](../prism/docs/superpowers/specs/2026-08-07-events-viewer-artifacts/process-improvement-proposition.md)

| Entry | Source observation/proposition, without loss of disposition | Disposition |
|---|---|---|
| S4-01 (line 11) | Cheap local/dirty gates should run before paid model probes. | R23 |
| S4-02 (line 17) | Parallel elapsed-time accounting and hand-entered timestamps were inaccurate; instrument every attempt and derive group timing. | R07 |
| S4-03 (line 23) | Claude ran from the wrong CWD and returned an orchestration refusal in stdout `.result`; set `REPO_ROOT` as CWD and classify the refusal correctly. | R01, R07 |
| S4-04 (line 29) | A shared helper should distinguish render/prelaunch bugs from actual CLI/vendor failures and must not emit a false vendor event. | R06, R07 |
| S4-05 (line 35) | Mutating roles need durable incremental progress so a transport interruption does not erase completed work. | R05 |
| S4-06 (line 41) | Retry eligibility should depend on ordered failure cause, mutation state, and attempt budget—not a blanket vendor-name rule. | R06 |
| S4-07 (line 46) | A same-role/same-iteration resume must remain a distinct attempt and emit a durable event showing that it was authorized after HALT rather than an illegal automatic retry. | R03, R13 |
| S4-08 (line 61) | `dispatch_state` conflated a known observed failure with an unobserved orphan; expose distinct attempt states and recoveries. | R06 |
| S4-09 (line 77) | The plan writer needed structural checkpoints and an artifact-complete marker before optional final prose/STATUS. | R05 |
| S4-10 (line 90) | The prompt inconsistently allowed redispatch for ORPHANED work but halted on equivalent transient no-artifact failures; unify them in one bounded matrix. | R06 |
| S4-11 (line 103) | Background Bash dispatch already escapes the foreground tool-call ceiling; retain that fact while fixing the separate Claude child ceiling. | A; R02 covers the remaining hazard |
| S4-12 (line 116) | Resuming an interrupted plan writer needs explicit authorization plus checkpoint inputs, not an ad hoc exception. | R05, R13 |
| S4-13 (line 128) | Autonomous execution/no routine reconfirmation was correct and should remain. | A |
| S4-14 (line 143) | Copied shell snippets differed in `set -u` safety and argument handling; source one tested runtime instead of repairing copies. | R17 |
| S4-15 (line 156) | The constrained preflight micro-role repeatedly failed STATUS publication; make the recipe unconditional, validated, and adequately budgeted because failure at review gates silently forfeits cross-vendor coverage. | R04, R09 |
| S4-16 (line 172) | The implementer must keep print-mode work foregrounded, await children, checkpoint finished tasks, and resume from durable progress after interruption. | R02, R05 |
| S4-17 (line 195) | Sending signals to a live timeout wrapper to extend execution woke `wait` and caused the harness to reap the tree; prohibit wrapper signalling and choose deadlines before launch. | R02 |
| S4-18 (line 212) | Proposition completion and RUN_LOG state could contradict each other, while continuation/retry terminology remained vague; reconcile records automatically and define one recovery vocabulary. | R05, R06, R18 |

### S5 — Allocation engine (45/45)

Original: [process-improvement-proposition.md](../prism/docs/superpowers/specs/2026-08-10-allocation-engine-artifacts/process-improvement-proposition.md)

| Entry | Source observation/proposition, without loss of disposition | Disposition |
|---|---|---|
| S5-01 (line 11) | A fixer could report `PARTIAL` after changing only part of the assigned findings; terminal success must require disposition and verification of every assigned finding. | R11, R12 |
| S5-02 (line 16) | `OWNER_DECISION` needs explicit decision inputs, approver/authority, affected findings, and accepted risk rather than free-form inference. | R13 |
| S5-03 (line 21) | Resuming after an owner decision or accepted risk needs a durable authorization flag/event consumed by the next attempt. | R13 |
| S5-04 (line 26) | Claude's effective CWD must be the target repository for all roles. | R01 |
| S5-05 (line 31) | A wrong-repository orchestration refusal was embedded in Claude stdout `.result`; CWD and vendor-envelope parsing must be checked together. | R01, R07 |
| S5-06 (line 36) | RUN_LOG should claim a launch only after inputs/appendix render successfully; prelaunch failure needs a distinct non-vendor record. | R06, R07 |
| S5-07 (line 41) | Transient stream stalls and connection loss should be classified separately from permanent vendor errors and may receive a bounded safe recovery. | R06 |
| S5-08 (line 46) | Attempt identity and retry caps must be explicit so same-role/same-iteration retries neither overwrite evidence nor loop indefinitely. | R03, R06 |
| S5-09 (line 51) | Before a mutating role, capture a reversible repository/artifact snapshot that identifies owned and pre-existing state. | R14 |
| S5-10 (line 56) | Large fixer assignments need work caps and deterministic finding batches; over-cap work should checkpoint and continue rather than produce a shallow all-at-once rewrite. | R05, R12 |
| S5-11 (line 61) | Add an artifact-integrity responsibility that checks internal consistency, traceability, and accidental loss after heavy edits, whether as a role or an explicit reviewer dimension. | R10, R12 |
| S5-12 (line 66) | Split fixer passes used the same iteration/role identity and overwrote transcripts; add attempt/pass/subset identity. | R03 |
| S5-13 (line 71) | When one finding or edit subsumes another, the fixer must mark the covered finding explicitly rather than silently skip half the assignment. | R12 |
| S5-14 (line 76) | Fixers should check ripple effects and adjacent sections/tests after each change, not only the exact cited line. | R11, R12 |
| S5-15 (line 81) | Repeated review tended to grow documents; require simplification, replacement, or deletion before additive text and measure structural growth. | R10, R12 |
| S5-16 (line 91) | Review loops need an explicit convergence/stop rule based on unresolved severity, recurrence, and divergence—not iteration count alone. | R10 |
| S5-17 (line 97) | Distinguish product/artifact findings from failures of the orchestration process so review provenance and the right fixer receive each issue. | R10 |
| S5-18 (line 103) | Spec fixers need a document-boundary contract: preserve required sections and source intent while avoiding unrelated process or implementation expansion. | R12 |
| S5-19 (line 109) | Rewriting artifacts in place erased provenance; retain revision/diff lineage sufficient to tell which reviewer introduced, repeated, or resolved a concern. | R10 |
| S5-20 (line 115) | A valid fixer may delete or condense redundant text; completion should reward coherence and coverage rather than net line growth. | R12 |
| S5-21 (line 120) | If later evidence shows divergence or unsafe accepted risk, it must be able to override an earlier provisional acceptance through an explicit correction path. | R10, R13 |
| S5-22 (line 125) | The plan writer should publish an artifact-complete marker after required structure is finished but before optional summary/terminal publication, enabling safe continuation. | R05, R21 |
| S5-23 (line 130) | Every phase acceptance should be a durable event naming the accepted artifact revision, gate evidence, and any residual risk. | R13 |
| S5-24 (line 135) | Before expensive review, sanity-check that an artifact exists, is non-trivial, contains required sections, and represents the expected revision/gate window. | R21 |
| S5-25 (line 140) | Fixed STATUS paths allowed stale success from an earlier attempt to satisfy a failed later attempt. | R03 |
| S5-26 (line 145) | A spec/plan fixer should checkpoint each finding or bounded section with addressed IDs and next work, not defer all state to terminal STATUS. | R05, R12 |
| S5-27 (line 150) | Fixer inputs and output artifacts need size/work bounds so review does not grow without limit or exceed a role's usable context. | R10, R12 |
| S5-28 (line 157) | Owner overrides must distinguish verified resolution, explicitly unverified acceptance, and deferred work; do not convert unverified claims into gate success. | R13 |
| S5-29 (line 162) | `PLAN_PATH` and other mutating-phase files need a declared dirty allow-list/ownership manifest so expected writes are not confused with foreign changes. | R14 |
| S5-30 (line 167) | Validate a role's complete input manifest before launch; a missing path/render failure must become `PRELAUNCH_FAILED`/`DISPATCH_NOT_LAUNCHED`, not vendor failure. | R06, R08 |
| S5-31 (line 172) | Implementation should publish task/commit/review/verification progress after every completed unit and resume from it. | R05 |
| S5-32 (line 177) | Claude's background-child wait ceiling must be compatible with the assigned role timeout. | R02 |
| S5-33 (line 182) | A clean-tree timeout after completed commits is continuable partial success, whereas dirty partial state needs reconciliation before continuation; neither is ordinary terminal failure. | R05, R06 |
| S5-34 (line 187) | Long document fixers should checkpoint after bounded finding batches and support continuation from the next unresolved ID. | R05, R12 |
| S5-35 (line 192) | Under `claude -p`, long work and nested agents must remain foregrounded and be awaited before the parent exits. | R02 |
| S5-36 (line 197) | Preflight should preserve enough model budget/headroom evidence to avoid declaring dual-vendor readiness and then immediately losing required coverage. | R09 |
| S5-37 (line 202) | Plans must list verification commands plus explicit exclusions, constraints, and substitutes when normal checks cannot run. | R15 |
| S5-38 (line 207) | Phase 7 needs a dedicated code fixer bounded to accepted findings, with its own status schema and review-back edge. | R16 |
| S5-39 (line 212) | Performance verification must specify a controlled environment or mark measurements inconclusive rather than silently accepting noisy/non-comparable results. | R15 |
| S5-40 (line 217) | Every blocker must be dispositioned as resolved, accepted risk, deferred follow-up, or owner decision, with evidence and authority. | R13, R15 |
| S5-41 (line 222) | All-tests and other long commands must remain foregrounded in print mode and be included in terminal verification evidence. | R02, R15 |
| S5-42 (line 227) | A fixer changing measured behavior must re-run the relevant measurement; assertions about likely improvement are not verification. | R11, R16 |
| S5-43 (line 232) | The finishing/finalizer path must never push; the current prompt explicitly enforces this. | A |
| S5-44 (line 237) | Transient stream failure after partial implementation needs checkpoints plus a bounded continuation path, not loss of all completed task evidence. | R05, R06 |
| S5-45 (line 242) | RUN_LOG writes need one owner/helper and attempt-aware schemas so concurrent/duplicated writers cannot produce contradictory history. | R07 |

### S6 — Allocation UX (23/23)

Original: [process-improvement-proposition.md](../prism/docs/superpowers/specs/2026-08-13-allocation-ux-artifacts/process-improvement-proposition.md)

| Entry | Source observation/proposition, without loss of disposition | Disposition |
|---|---|---|
| S6-01 (line 11) | Add an explicit transient-failure mode with a safe-retry predicate based on role mutation, checkpoint state, failure signature, and retry cap. | R06 |
| S6-02 (line 16) | Fixers should operate in bounded batches, publish incremental finding disposition, and continue from durable state. | R05, R12 |
| S6-03 (line 21) | Each process-authorized retry needs a durable authorization/cause event. | R13 |
| S6-04 (line 26) | Failure-mode rules require deterministic precedence, and later evidence must be able to emit an explicit correction rather than leave contradictory events. | R06, R13 |
| S6-05 (line 31) | Long reviewers should checkpoint partial findings incrementally while reserving terminal verdict for complete coverage. | R05 |
| S6-06 (line 36) | The process contradicted itself by permitting ORPHANED non-mutating redispatch but forbidding equivalent retries elsewhere; unify it in a cause- and state-based matrix. | R06 |
| S6-07 (line 41) | Plan writers should checkpoint completed top-level sections and publish an artifact-complete marker before terminal STATUS. | R05 |
| S6-08 (line 46) | Resumed plan writing needs explicit process authorization linked to the prior attempt and checkpoint. | R13 |
| S6-09 (line 51) | A later `CONTEXT7_UNAVAILABLE` event must override an earlier Phase 1 reachable result when deriving downstream policy. | R22 |
| S6-10 (line 56) | Plan-fixer transport failure needs attempt-aware classification and bounded recovery rather than being interpreted as content failure. | R03, R06 |
| S6-11 (line 61) | The resulting retry/continuation must carry an explicit authorization record. | R13 |
| S6-12 (line 66) | If one member of a parallel helper/reviewer group fails, log its attempt outcome independently rather than flattening the group into one ambiguous result. | R07 |
| S6-13 (line 71) | Every failed attempt—including same-role repeats—must get a unique event, transcript, STATUS identity, and timing record. | R03, R07 |
| S6-14 (line 76) | Add automated checks that reconcile dispatch blocks, STATUS files, proposition entries, phase completion, and correction events. | R18 |
| S6-15 (line 81) | Preserve partial progress from interrupted long roles and expose a continuation cursor rather than restarting from zero. | R05 |
| S6-16 (line 86) | Every automatic retry/continuation path needs an explicit cap and escalation outcome. | R06 |
| S6-17 (line 91) | A failed plan-fixer attempt must not reuse stale status or overwrite prior evidence; classify it by current attempt and recovery state. | R03, R06 |
| S6-18 (line 96) | Retrying that plan-fixer attempt is valid only when the bounded recovery matrix authorizes it and an event records why. | R06, R13 |
| S6-19 (line 101) | A subsequent failed attempt remains a distinct attempt with its own failure evidence; it cannot be folded into the previous record. | R03, R06, R07 |
| S6-20 (line 106) | Any further retry again consumes the declared retry budget and requires explicit authorization. | R06, R13 |
| S6-21 (line 111) | The final failed repeat must remain visible as its own attempt and trigger the cap's prescribed terminal/owner-decision outcome. | R03, R06, R13 |
| S6-22 (line 116) | Appendix/input/render failures—including unset role inputs—must be rejected from a declared input contract before vendor launch and recorded as `PRELAUNCH_FAILED`/`DISPATCH_NOT_LAUNCHED`, with no false vendor failure event. | R06, R07, R08 |
| S6-23 (line 121) | Copied runtime cookbook snippets diverged in `set -u` and other shell semantics; source and test one implementation. | R17 |

## Consolidation completeness statement

- Source inventory: **6 proposition files, 137 dated entries**.
- Coverage appendix: **137 source-local rows**—S1 10, S2 26, S3 15, S4 18, S5 45, S6 23.
- Recommended changes: **24 consolidated changes**. Counts in the matrix measure distinct supporting files, while this appendix preserves repeated evidence within a file.
- Existing/correct behavior is retained through **A/K** rather than restated as new work. One launcher-level variant is **N** because it would duplicate policy; R23 retains its cost-saving purpose.
- This report intentionally does not copy every command or quotation from the propositions. The linked original files remain the lossless evidence record; each entry above guarantees that every original observation has an explicit destination in the consolidated process backlog.
