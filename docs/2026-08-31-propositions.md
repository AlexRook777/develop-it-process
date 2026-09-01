# Develop-It process improvement propositions

Date: 2026-08-31
Target process: [`develop-it-prompt.md`](../develop-it-prompt.md) (schema v2, 12,574 lines)
Method: full-document analysis by five parallel investigation agents (contract & phases; runtime cookbook in two halves; contracts & failure handling; role appendices), plus observed weaknesses from real runs. The previous consolidated round (R01–R24, 2026-08-13) is implemented; every proposition below is net-new. The SDLC phase structure (−1 → 11) is kept intact throughout.

Ratings: Criticality **Critical/High/Medium/Low** (same definitions as the R-series), Effort **Easy/Moderate/Hard**.

> **Execution status (2026-09-01):** ALL propositions executed on branch `improvements-2026-08-31` (df481ce..a669397, 33 commits, offline suite green 12/0/1 at every task boundary; never pushed). Each proposition's Status line below names its commit. P00: stages 1–2 implemented (resident core 861KB → 236KB, −73%); stage 3 delivered as `docs/p00-stage-3-suborchestration-design.md` — it changes live dispatch behavior the offline suite cannot verify, so it needs the pilot run the note specifies before coding. Every task was implemented by a fresh subagent, reviewed by an independent reviewer, and fix-looped until clean; a final whole-branch review judged the branch mergeable.

---

## P00 — Split the monolith: phase packs loaded on demand, cookbook out of context, per-phase suborchestration

**Status:** ✅ stages 1–2 implemented (bc6ea39, 2e16b12): resident core 861KB→236KB (−73%), cookbook+publisher in runtime/, 11 phase packs loaded on demand. Stage 3 delivered as a design note (docs/p00-stage-3-suborchestration-design.md) — it changes live dispatch behavior the offline suite cannot verify, so it needs the pilot run the note specifies before coding

**Criticality:** High (owner-raised: prompt size) · **Effort:** Hard — but stageable, and each stage pays for itself

**Problem.** `develop-it-prompt.md` is 777KB / 12,574 lines and is passed *verbatim* as the orchestrating session's system prompt. The orchestrator therefore carries, on every single turn of every run: ~7,500 lines of bash cookbook it never executes in-context (Phase −1 extracts it to real files and every dispatch *calls* those files), 24 role appendices of which at most 2–3 matter per phase, and the full text of contracts for phases that already finished. This is the single largest token cost in the system, it grows with every improvement round, and it dilutes the orchestrator's attention across 95% irrelevant text.

**Key enabler already in place.** Schema v2 made every phase context-independent by design: fresh shell per phase, `init_orchestration_vars` re-derives every durable input from validated STATUS/events on disk, never from memory ("Durable input reconstruction", lines 771–834), and "One phase per bash invocation" (line 130) already forbids cross-phase bundling. Nothing in the process depends on the orchestrator *remembering* — everything is on disk. The monolith is a packaging choice, not an architectural requirement.

**Proposed change — three stages, each independently shippable:**

1. **Evict the cookbook from orchestrator context (biggest, cheapest win — ~60% of the file).** The orchestrator never runs cookbook bash inline; it sources the extracted runtime files. Move the fenced bash blocks into real files under `runtime/` in this repo (`cookbook.sh`, registries, publisher), and replace them in the prompt with a one-page *function index* (name, one-line purpose, arguments) so the orchestrator knows what to call without carrying implementations. `bootstrap_runtime` extracts from files instead of fences; `tests/run.sh` tests the files directly (simpler than today's extraction); the "document is the single source of truth" ethos becomes "the repo is the single source of truth", with `manifest.sha256` covering the set. Process-file identity (`PROCESS_FILE_SHA256`, `develop_it_dirty`, spec S16.2) generalizes from one file's bytes to the manifest hash — same four dirty states, computed over the file set.

2. **Phase packs as skills, loaded on demand.** Split the per-phase orchestration sections and their role appendices into per-phase files (`phases/3-spec-review.md` carrying Steps 3.0–3.N plus the spec-reviewer/spec-fixer/summarizer-spec appendices, etc.). Package them as Claude Code skills (`develop-it:phase-3`, …) or have the slim core instruct "before starting phase N, Read `phases/<N>-*.md`". The orchestrator's resident prompt shrinks to a core of roughly 1,500–2,000 lines: the orchestration contract, gate severity policy, the three registries, the phase sequence, failure-handling matrix, and the function index. Each phase's instructions enter context only while that phase runs — and the shared contracts (STATUS, finding-record, publish protocol) live in exactly one pack-independent file, which also delivers the deduplication propositions (P20–P22) structurally instead of textually.

3. **Per-phase suborchestration for the heavyweight phases.** For Phases 3/5/6/7/8 (the iterating ones), the top-level session stops driving the inner loop itself: it dispatches one *phase orchestrator* subprocess (`claude -p` with only that phase's pack + shared contracts as its system prompt) whose job is the whole gate — preflight probe, reviewer dispatches, fixer loops, summarizer — and which reports back through the same attempt-scoped STATUS/RUN_LOG machinery that already exists (the phase orchestrator takes the write lease exactly as roles do today). The top-level orchestrator degenerates to what it already almost is: a thin state machine that reads STATUS between phases, applies the recovery matrix, and talks to the user. Resume gets *easier*, not harder: a phase orchestrator that dies is re-dispatched and re-derives everything from disk, exactly like any role today.

**Trade-offs to accept explicitly.** Cross-references become cross-file (mitigate: a lint check that every `see §X` resolves); the "hand one file to an agent" simplicity is lost (mitigate: `develop-it.sh` already hides this — users run the launcher, not the file); RUN_LOG stays single-writer, so in stage 3 the write-lease handoff to phase orchestrators must be as strict as today's role leases (machinery exists).

**Benefit.** Order-of-magnitude cut in resident orchestrator context (≈12,500 → ≈2,000 lines), lower cost per turn on *every* run, sharper orchestrator attention, and future growth (new checks, new appendices) lands in phase packs instead of a file every session must swallow whole. Stage 1 alone removes ~60% of the bytes with no behavioral change.

---

## P01 — Add an integration-seam adversarial pass to the Phase 7 gate

**Status:** ✅ implemented (7f066a7)

**Criticality:** High · **Effort:** Moderate

**Problem.** Observed across real runs: the Phase 7 code review gate (lines 9303–9382) reliably catches in-repo correctness defects but systematically misses *integration seams* — deploy configuration, third-party state (queues, buckets, external APIs), cross-service wiring, migrations against real schemas. Both reviewers read the same static evidence (diff + spec + plan) and neither executes anything; the only nod to live verification anywhere near the gate is the soft, unenforced "implementer additionally loads `dogfood` (or equivalent) if the plan requires browser QA" hint at line 422, with no Phase 7 check that such evidence exists. A change that is internally consistent but wrong at its boundary passes the gate and only fails in UAT or production.

**Proposed change.** Keep the two static reviewers, and add one bounded *seam verifier* dispatch to Phase 7 that runs only when the diff touches seam-classified files (a small glob registry in the Process Policy Registry: deploy manifests, migration dirs, client wrappers for external services, env/config files). The seam verifier:
- receives ONLY the list of seam files touched plus the spec's integration claims, not the whole diff;
- must produce *live evidence* per seam: run the migration against a scratch DB, dry-run the deploy template validator, execute the client wrapper against a sandbox/mock endpoint, or explicitly record `UNVERIFIABLE:<reason>` — a prose argument is not evidence;
- publishes findings into the same severity-count stream as the two reviewers, so the existing gate arithmetic, fixer loop, and iteration cap apply unchanged.

Diffs touching no seam-classified file skip the dispatch entirely (zero added cost on pure in-repo changes).

**Benefit.** Closes the one defect class the gate demonstrably lets through, at marginal cost proportional to how often seams are actually touched. No new phase; the gate's decision logic is untouched.

## P02 — Extend the `MISSING_SKILLS` re-probe from Phase 1 to every per-phase preflight gate

**Status:** ✅ implemented (55f3872)

**Criticality:** High · **Effort:** Moderate

**Problem.** Phase 1's Step 1.1 (lines 8834–8851) already handles the observed Codex skill-probe false negative: on `verdict=MISSING_SKILLS` it calls `skills_reprobe_needed` (prior-READY contradiction, filesystem check, lost-publication check) and re-dispatches once before trusting the verdict. But the per-phase preflight gates only branch on three cases — Claude fails, Codex fails with a Mode 0–5 *vendor failure* (which does get `vendor_preflight_reprobe_once`, lines 9010–9013), or both `READY` (Step 3.0 step 7 at 9010–9013; Step 5.0 step 7 at 9109–9112; Step 6.−1 step 7 at 9182–9185; Step 7.0 step 7 at 9344–9347). A *successfully completed* probe that publishes the semantic verdict `MISSING_SKILLS` (legal per the Role Contract Registry, lines 277–278) has **no defined branch at all** at Phases 3/5/6/7 — the exact place the recurring false negative bites mid-run, where it silently degrades review coverage for the phase.

**Proposed change.** Two layers:
1. Add a fourth branch to Steps 3.0/5.0/6.−1/7.0 step 7 mirroring Phase 1: on `verdict=MISSING_SKILLS` from either vendor, call the same `skills_reprobe_needed` helper and re-dispatch that vendor's preflight once; only a second consecutive `MISSING_SKILLS` is trusted.
2. Generalize the rule at the STATUS contract layer (lines 9563–9580): `MISSING_SKILLS` is always retried exactly once before the orchestrator treats it as ground truth — the same retry-once idiom Mode 4 (malformed STATUS) already has (line ~9620) — so no future gate can forget the branch.

Both probe attempts stay in `RUN_LOG.md` with raw outputs so a flake remains auditable.

**Benefit.** Closes the one remaining path where the known false negative can degrade dual-vendor coverage mid-run; reuses two existing mechanisms (`skills_reprobe_needed`, retry-once) instead of inventing new machinery.

## P03 — Run-level exclusivity for non-parallel-safe test suites in Phase 8

**Status:** ✅ implemented (08bbd1c)

**Criticality:** High · **Effort:** Easy

**Problem.** Observed in the primary target project: the integration suite shares one test database and is not parallel-safe — two concurrent executions (a second develop-it run, an operator running tests by hand, or an over-eager fixer re-running tests while the test-runner loop is live) invent failures. Phase 8's test→fix loop then burns fix iterations "repairing" code that was never broken.

**Proposed change.** Two small rules:
1. **A test-execution lease.** Reuse the existing write-lease mechanism: the Phase 8 test-runner (and any role allowed to execute the suite, e.g. the implementer's verification steps) must hold a `test-lease` file under `.orchestration/` before invoking the suite, and release it after. A held lease means wait-with-timeout, then HALT with the lease path — never run concurrently.
2. **A per-project parallel-safety declaration** in the Process Policy Registry (`test_suite_parallel_safe: yes|no`, default `no`). When `no`, the test-runner must also pass the project's serial flag (e.g. `-p 1` / `--runInBand`) so the suite cannot self-parallelize onto the shared DB. The `all-tests-runner` appendix (Behavior, lines 11788–11806) currently says nothing about isolation or concurrency — add a probe step before running suites: detect parallel-execution config already present in the project (`pytest-xdist`/`-n auto`, jest `maxWorkers`, absence of `--runInBand`) and single-shared-resource signals (one `TEST_DATABASE_URL` with no per-worker suffix), force serial mode for such suites, and record which mode was forced in `test-report.md`.

**Benefit.** Removes an entire class of phantom Phase 8 failures and the wasted fixer iterations they trigger; reuses existing lease machinery rather than adding new state.

## P04 — Fix `vendor_proven`'s regressed RUN_LOG parser and consolidate all scanners onto one reader

**Status:** ✅ implemented (b734f1d)

**Criticality:** Critical · **Effort:** Moderate

**Problem.** `_run_log_events_json` (lines 4500–4548) was deliberately rewritten to split RUN_LOG blocks on the event *header line*, with an explicit comment (4507–4513) explaining why splitting on blank lines truncates any block whose multi-line `reason:` contains one. Yet `vendor_proven` (6845–6870) — the function that gates Phase 3/5/7 degradation decisions — hand-rolls its own parser and does exactly the discredited thing at line 6852: `blocks = text.split("\n\n")`. A `VENDOR_PROVEN`/`DISPATCH_COMPLETED` block with a wrapped `reason:` silently merges with the next block or shears off fields, corrupting the vendor-capability determination. Beyond that, at least three more functions each re-implement their own line-by-line RUN_LOG state machine with subtly different matching: `dispatch_is_running` (6220–6244, whose `*"$id")` is an unanchored suffix match), `context7_policy` (7215–7248), and `_validate_artifact_phase_accepted` (7439–7459). Five independent RUN_LOG grammars must currently be kept in sync by hand.

**Proposed change.** Delete `vendor_proven`'s bespoke parser and derive its answer from `_run_log_events_json | jq`. Then add one shared helper (e.g. `_run_log_latest_field EVENT_TYPE MATCH_FIELD=VALUE FIELD`) built on the same JSON stream, and rewrite the other three scanners on top of it.

**Benefit.** Removes a live, reachable parsing bug that regressed a fix already made once in the same file, and leaves exactly one RUN_LOG grammar to maintain and test.

## P05 — Wrap `probe_models` vendor calls in `timeout`

**Status:** ✅ implemented (e534b81)

**Criticality:** High · **Effort:** Easy

**Problem.** `canary_preflight` requires the `timeout` binary (6315–6317) precisely because vendor dispatches are wrapped in it — but `probe_models` (6356–6380) fires real network-hitting model calls to both vendors (`claude --model … -p` at 6369–6371, `codex … exec` at 6374–6376) with **no `timeout` prefix at all**. A hung network call or wedged vendor CLI blocks the entire run indefinitely at the very first paid-adjacent step, before the RUN_LOG machinery exists to record a HALT.

**Proposed change.** Wrap both invocations in `timeout` with the same ceiling/kill-after convention dispatch attempts use elsewhere; a timeout is reported as a model-probe failure (existing halt path), never a silent skip.

**Benefit.** Closes a real indefinite-hang vector present on every run.

## P06 — Store the write-lease acquisition epoch at write time; stop reparsing with GNU-only `date -d`

**Status:** ✅ implemented (e534b81)

**Criticality:** High · **Effort:** Easy

**Problem.** The startup-grace window (`WRITE_LEASE_STARTUP_GRACE_SECONDS`, lines 5296–5309) exists to fix a documented bug: a just-acquired lease being misclassified as `AMBIGUOUS_LEASE` → false `ARTIFACT_INTEGRITY_BLOCKED` HALT (comment at 5244–5258). But the grace check computes `acquired_epoch="$(date -u -d "$acquired_at" +%s 2>/dev/null)"` — `date -d` is GNU-specific; on any platform without it the parse silently fails, `age=-1`, and the code falls straight through to `AMBIGUOUS_LEASE` (5312) on **every** acquisition, reproducing the exact false-HALT bug the surrounding comment says was fixed.

**Proposed change.** Write a Unix-epoch field into `write-lease.json` at acquisition time (where `acquire_write_lease` already runs `date` once, lines 5484/5493) so read time never reparses a formatted timestamp; additionally assert the `date` capability in `canary_preflight` so a genuinely broken environment surfaces as an environment defect, not a misclassified lease.

**Benefit.** Removes a portability-triggered path back into a known false-positive-HALT bug class.

## P07 — `record_event` must not silently default the schema version

**Status:** ✅ implemented (e534b81)

**Criticality:** Medium · **Effort:** Easy

**Problem.** `policy_value`'s own doctrine (lines 381–383) is "fail loudly … rather than silently defaulting", and `invoke_vendor` cites that doctrine by name to justify its own validation. Yet `record_event` — the sole canonical writer of every RUN_LOG event — does `schema="$(policy_value process_schema_version 2>/dev/null)"; [ -n "$schema" ] || schema=2` (line 4328): if `RUNTIME_DIR`/`policy.tsv` is missing or corrupted it silently stamps `2` into every event.

**Proposed change.** Either fail loudly with a named token (`RECORD_EVENT_SCHEMA_LOOKUP_FAILED`), or — if the pre-bootstrap call sites (e.g. `ATTEMPT_ALLOCATED` at Phase −1) genuinely need the fallback — annotate the exception at line 4328 the way every other deliberate exception in the document is annotated.

**Benefit.** Removes a direct contradiction between stated policy and the single most central write path.

## P08 — Make `divergent_round_cap` mean what it says (or say what it does)

**Status:** ✅ implemented (9317d86)

**Criticality:** Medium · **Effort:** Easy–Moderate

**Problem.** The Process Policy Registry (line 370) defines `divergent_round_cap` as "Consecutive divergent rounds before automatic fixing **stops**." The actual procedure (line 9042 for Phase 3, mirrored at 9133/9375) never stops: at the cap it dispatches one consolidation-priority fixer batch and continues the ordinary loop. It is also unspecified whether the divergence counter resets after the consolidation pass, so a still-divergent run can trigger `DIVERGENT_ROUND_CAP_REACHED` → consolidation repeatedly up to `review_iteration_cap` — an unbounded consolidation-retry loop masquerading as "capped".

**Proposed change.** (a) Rewrite the policy's meaning text to describe the real behavior, and (b) add an actual stop condition: two consecutive `DIVERGENT_ROUND_CAP_REACHED` events on the same gate HALT with the findings catalog paths surfaced for human review, instead of a third consolidation dispatch.

**Benefit.** Removes a registry/behavior contradiction and bounds a genuinely unbounded loop.

## P09 — Drop the Phase 6 Codex preflight dispatch (it is paid and purely informational)

**Status:** ✅ implemented (55f3872)

**Criticality:** Medium (pure cost) · **Effort:** Easy

**Problem.** Step 6.−1 dispatches `preflight-codex` in parallel like every gate, but the text itself admits (line 9184): "Codex is not dispatched downstream in Phase 6, so the codex verdict is informational only — the probe runs only to give the user early warning." That is a full paid subprocess dispatch on every run that reaches Phase 6, buying only a warning line.

**Proposed change.** Remove the Codex dispatch from Step 6.−1 and derive the early warning at zero cost from `RUN_LOG.md`: surface the most recent Codex outcome (`CODEX_UNAVAILABLE` or a successful dispatch) from Phase 5/3.

**Benefit.** One fewer paid dispatch per run with zero coverage loss.

## P10 — Reproduce a test failure in isolation before dispatching `test-fixer`

**Status:** ✅ implemented (08bbd1c)

**Criticality:** High · **Effort:** Moderate

**Problem.** Step 8.1 (lines 9392–9403) treats any `FAIL` verdict as needing a `test-fixer` dispatch (up to 3 fix rounds). With a non-parallel-safe suite (see P03), a `FAIL` may be shared-DB interleaving rather than a code defect — and a fixer dispatched against a phantom failure wastes a round and risks "fixing" correct code. `test-fixer`'s own appendix has no reproducibility step either.

**Proposed change.** Before dispatching `test-fixer`, re-run only the failing test(s) once, serialized and isolated. Dispatch the fixer only if the failure reproduces; otherwise record it as `flaky` in `test-report.md` and treat the round as PASS-with-note — surfaced to the readiness writer, never silently dropped. Mirror the same rule inside `test-fixer` step 2 for failures it inherits mid-round.

**Benefit.** Saves fix-round budget and prevents spurious edits chasing infrastructure flakiness; pairs with P03 to address the shared-DB weakness end-to-end.

## P11 — Give the two vendor reviewers structurally distinct lenses, with an integration-surface dimension

**Status:** ✅ implemented (2049378)

**Criticality:** High · **Effort:** Moderate

**Problem.** The evaluation-dimension checklists of `code-reviewer-claude` (lines 11488–11495) and `code-reviewer-codex` (11615–11622) are byte-identical (same for the spec- and plan-reviewer pairs: 10487–10493 vs 10600–10606, 10869–10879 vs 10977–10987). Cross-vendor review currently means "two models, same checklist" — nominal independence, not lens diversity. And neither list contains anything about deploy config, env/secret templates, IaC manifests, migration ordering, feature flags, or third-party contract changes — which is *why* both reviewers miss integration seams at once (the weakness P01 attacks from the dispatch side).

**Proposed change.**
1. Add an eighth dimension to both code-reviewer lists: "Integration & deployment surfaces — env vars, config/secret templates, deploy/IaC manifests, DB migration ordering, feature-flag wiring, third-party API contract changes touched by the diff."
2. Make the lenses genuinely different: keep `code-reviewer-claude` as the correctness/spec/test-lens primary, and rewrite `code-reviewer-codex` to *lead* with the integration-surface dimension, with a mechanical trigger: a diff touching a config/deploy/migration/third-party-contract file with no corresponding entry in `verification-records.jsonl` is a MAJOR by default (the codex reviewer's diff-aware mode, lines 11572–11581, already has the file access to check this).
3. Add a seventh bullet to the phase-boundary self-check (lines 10026–10036), which today audits only orchestrator hygiene: "Did the dispatched review's declared scope include deploy/config files and cross-service integration points touched by this change, not only application source?"

**Benefit.** Converts reviewer redundancy into coverage; gives the integration-seam class a mechanical trigger (missing verification evidence) instead of relying on a reviewer noticing; text-only, no new machinery.

## P12 — Fix the Codex skill probe at the source: one-command scan plus an `UNCERTAIN` verdict

**Status:** ✅ implemented (55f3872)

**Criticality:** Medium · **Effort:** Easy–Moderate

**Problem.** `preflight-codex` is capped at "max 2 shell or read commands" (lines 10323–10325) yet must check 3 required skills across *multiple* plugin roots and "name every plugin root/path checked" (10333). A probe that exhausts its budget after the first root reports `MISSING` for skills that exist under an unchecked root — the likely mechanism behind the observed spurious `MISSING_SKILLS`. P02 recovers from this downstream; nothing reduces it at the source.

**Proposed change.** (a) Mandate the whole check as a single command (`find <root1> <root2> … -maxdepth 3 -iname 'SKILL.md' | grep …` for all three skills at once) so budget exhaustion can't truncate the scan. (b) Add a rule: if fewer than all configured roots were actually checked (budget, command failure, empty root list), report `UNCERTAIN` — never `MISSING` from a partial scan. The orchestrator treats `UNCERTAIN` as an automatic re-probe trigger (feeding the P02 branch), not as absence.

**Benefit.** Cuts the false-negative rate at its origin and gives the re-probe logic a typed signal instead of prose forensics.

## P13 — Material plan deviations must be able to change the readiness verdict

**Status:** ✅ implemented (2049378)

**Criticality:** High · **Effort:** Moderate

**Problem.** `documentation-writer` step 3 (line 12388) records "any material deviation" in `planned-vs-realized.md`, but `readiness-writer` (12476–12531) never reads that content — it links the file as an artifact and checks only structural presence. A run that silently descoped an acceptance criterion can still report `READY` as long as tests/reviews/doc structure pass: the one artifact recording the descope has no downstream reader with teeth.

**Proposed change.** (a) Tag each deviation entry `severity: benign|material`. (b) Every `material` deviation is also emitted as an `x_followup_candidate` in the writer's STATUS (mechanism exists, line 12399) so it lands in `followups.jsonl`. (c) `readiness-writer` gains a "Plan deviations" section, and any non-empty material list forces at least `READY_WITH_NOTES` — the same forcing pattern the Degradations section already uses (line 12525).

**Benefit.** Closes a false-success path using three mechanisms that already exist; no new artifacts.

## P14 — Copy the implementation-fixer's scope-creep clause into spec-fixer and plan-fixer

**Status:** ✅ implemented (e534b81)

**Criticality:** Medium · **Effort:** Easy

**Problem.** `implementation-fixer` step 5 (line 11705) forbids folding unrelated opportunities into a fix pass — they go to the human-facing summary as follow-ups. `spec-fixer` (10682–10712) and `plan-fixer` (11062–11069) have only a generic "ripple check", which licenses fixing *consequences* of an assigned edit but doesn't stop opportunistic rewrites of unrelated spec/plan text. Divergent review rounds (P08) are fed by exactly this kind of drift.

**Proposed change.** Add the identical clause to both fixers: only edits addressing an assigned finding ID belong in the pass; everything else is a named follow-up candidate.

**Benefit.** Three structurally parallel fixers get one consistent convergence rule; fewer new findings manufactured by fix passes.

## P15 — Harden verification-record semantics: typed exclusions, linked NOT_RUNs

**Status:** ✅ implemented (9317d86)

**Criticality:** Medium · **Effort:** Moderate

**Problem.** Two gaming vectors in the Verification Record Contract: (a) `EXCLUDED` legitimacy is substring-sniffing — the validator (8466–8467) accepts any `reason` containing one of four words (`EXCLUSION_MARKERS`, line 8410), so "outside the scope of this refactor" passes regardless of truth; (b) `NOT_RUN` "names its actor/prerequisite in `reason` and becomes handoff/readiness work" (8357) is enforced only as "reason non-empty" (8479–8480), and nothing requires the already-existing `followup_id` field (8350) to be populated — so a `NOT_RUN` can evaporate without tracked handoff work.

**Proposed change.** (a) Add a required enum `exclusion_class: pre_existing|environment_bound|actor_bound|outside_capability` and validate against it instead of keyword-sniffing prose (the upgrade path the file's own `x_measurement_kind` comment at 8411–8417 already sketches for the performance case). (b) Require `followup_id != null` whenever `result == NOT_RUN` — the ledger is exactly where that work is supposed to live.

**Benefit.** The two soft spots in the "cannot hide a new regression" rule (8356) become machine-checkable.

## P16 — Let a verification command declare `environment: exclusive`

**Status:** ✅ implemented (08bbd1c)

**Criticality:** Medium · **Effort:** Moderate

**Problem.** The `environment` field (line 8344) is only special-cased for `controlled` (performance). Nothing distinguishes a command that must run alone — e.g. the integration suite against the shared test DB — from one safe under `dispatch_parallel`, so the shared-DB constraint (P03) stays tribal knowledge invisible to the contract layer.

**Proposed change.** Recognize `environment: exclusive`; `validate_plan_tasks`/`validate_verification_records` refuse to co-schedule two exclusive commands, and dispatch routes them through the serial path (P03's test lease).

**Benefit.** Encodes the known constraint in the contract that defines "verified", instead of re-discovering it each run.

## P17 — Pair every append-only ledger with a validator (followups, proposition log)

**Status:** ✅ implemented (9317d86) — validate_proposition_log is offline/maintainer tooling: the Non-influence guarantee forbids a live Phase 11 read of the run\'s own proposition file

**Criticality:** Medium · **Effort:** Easy–Moderate

**Problem.** The Plan Task and Verification Record contracts both ship read-side validators (`validate_plan_tasks`, 8183–8330; `validate_verification_records`, 8376–8492). The Follow-up Ledger ships only write-time checks (`append_followup`, 8534–8571) — nothing re-validates `followups.jsonl` after a crash mid-append, hand-edit, or resume, and the five "required non-empty text" fields (8511–8531) are never re-checked. Similarly, `process-improvement-proposition.md` has documented format rules (10094+) and even references a `DUPLICATE_PROPOSITION_COVERAGE` condition (10087) for which no check is defined anywhere.

**Proposed change.** Add `validate_followups` mirroring `validate_verification_records` (all 8 fields, legal status, duplicate ids), called at the same phase-boundary self-check points; add a small `validate_proposition_log` (three required header fields; mandatory-kind entries carry a legal `trigger:` tag).

**Benefit.** Restores the file's own defense-in-depth pattern uniformly; corrupted ledgers get caught before readiness instead of never.

## P18 — Mechanize the "retry within iteration" trigger classification

**Status:** ✅ implemented (9317d86)

**Criticality:** Medium · **Effort:** Moderate

**Problem.** Sibling gates were deliberately turned into callable bash ("a REAL callable gate, not prose alone… a provable fact rather than a claim", 8590–8596), but Trigger #3 (10067–10083) remains a multi-paragraph prose recipe the LLM orchestrator must re-derive from RUN_LOG text on every dispatch — the exact hand-applied-rule shape the file elsewhere eliminates.

**Proposed change.** Add `is_retry_within_iteration PHASE ROLE ITERATION` scanning RUN_LOG (via the P04 shared reader) for a preceding failed dispatch with matching phase+role+iteration, returning yes/no like `plan_review_window_closed`. The automatic-vs-user-authorised distinction stays prose (genuine judgment).

**Benefit.** Cheaper, consistent failure classification; one less textual rule an orchestrator can misapply.

## P19 — Generate the Event Contract Registry like its two siblings

**Status:** ✅ implemented (5a9b68e)

**Criticality:** Medium · **Effort:** Hard

**Problem.** The Role Contract and Policy registries are Markdown tables extracted to TSV and looked up at runtime — the table *is* the data. The Event Contract Registry (4064–4109) is enforced by hand-written `case` statements (`event_required_fields`, 4176–4226; `_event_proposition_required`, 4236–4245) that a human must keep in sync, and the document admits it: "editing a cell here has zero runtime effect until this case statement is edited to match" (4169–4175).

**Proposed change.** Extend `tests/lib/extract.py` with an `events` command emitting `events.tsv`; `bootstrap_runtime` extracts it as a fifth generated file; rewrite the two case statements as thin TSV lookups shaped like `role_contract_field`/`policy_value`.

**Benefit.** Closes the file's one self-acknowledged single-source-of-truth gap with a pattern already proven twice.

## P20 — Template-factor the role appendices (~1,200 duplicated lines)

**Status:** ✅ implemented (2758a0a)

**Criticality:** Medium · **Effort:** Moderate

**Problem.** Three large duplication blocks in the appendices (all become *structural* rather than textual if P00 stage 2 lands, but are worth doing even standalone):
- The "Publish STATUS" footer — prose warning plus publisher heredoc — is repeated near-identically in all 24 appendices (e.g. 10254–10292, 10509–10546, 11316–11364, 12540–12571): ~800 lines differing only in role/phase/`x_*` fields already enumerated in each role's contract line.
- The five summarizer bodies (11932–12350) are ~90-line copies differing in phase constants and 1–2 fields; the usage-table spec is pasted verbatim three times.
- The canonical finding-record schema sentence is restated verbatim in all six reviewer appendices (10505, 10613, 10882, 10994, 11498, 11630) even though each already cross-references the cookbook's canonical definition.

**Proposed change.** One shared "Publish STATUS protocol" block with `{{ROLE}}/{{PHASE}}/{{EXTRA_FIELDS}}` placeholders (a natural extension of `render_prompt`, which already substitutes variables); one parameterized summarizer appendix; reviewer appendices reference the schema by name with only their three differing field values.

**Benefit.** ~1,200 lines removed; a publisher-protocol fix becomes one edit instead of 24 chances to miss one.

## P21 — Deduplicate the per-phase procedural prose (alias-copy ×5, verdict-branch ×3)

**Status:** ✅ implemented (2758a0a)

**Criticality:** Medium · **Effort:** Moderate

**Problem.** The ~20-line preflight-alias-copy snippet (with identical explanatory comments) appears five times (8888–8907, 8987–9005, 9086–9104, 9159–9177, 9320–9339). The per-phase preflight "Branch on the verdicts" logic is near-verbatim across Phases 3/5/7 (9010–9013, 9109–9112, 9344–9347), differing only in phase constants plus Phase 7's extra `DEGRADED_REVIEW_ACCEPTED` step; Phase 6 is a genuine documented exception.

**Proposed change.** Extract `copy_preflight_alias <phase-token> <dest-dir>` into the cookbook and replace five call sites; consolidate the verdict branch into one named "standard per-phase preflight verdict branch" procedure referenced by Phases 3/5/7, with Phase 7's extra step written as a delta. (Also the natural place to add P02's fourth branch exactly once.)

**Benefit.** >100 lines removed; the five copies can no longer drift — one was already the place a bug fix could silently miss four siblings.

## P22 — Consolidate duplicated cookbook plumbing (six small single-source fixes)

**Status:** ✅ implemented (items 1/2/6: e534b81; items 3/4/5: b012f73)

**Criticality:** Medium · **Effort:** Easy–Moderate (independent items)

**Problem/change pairs, each independently shippable:**
1. `bootstrap_runtime` step 2 (1237–1252) reimplements `_bootstrap_sweep_orphans` (1197–1207) inline byte-for-byte — and the inline copy leaks `orphan_age_threshold`/`now`/`orphan`/`orphan_age` as globals (its `local` at 1212 misses them). Replace with the helper call it already makes at 1229.
2. The 8-alternative spend-ceiling regex is a hand-duplicated literal in `_vendor_headroom_probe` (2297) and `classify_attempt` (3374), despite the comment at ~2295 requiring they mean the same thing. Factor into `_spend_ceiling_pattern()`.
3. The `timeout`/process-group launch-and-kill dance is written four times across `_vendor_headroom_probe` (2248–2303) and `invoke_vendor` (2321–2457); the empirically-discovered `--kill-after` cleanup quirk (2309–2320) must be re-applied correctly in each. Extract one `_launch_vendor_subprocess` helper.
4. The phase↔token mapping (`-1 ⟷ m1`, `N ⟷ %02d`) is implemented forward in `allocate_attempt` (1853) and inverted by hand in `role_attempt_dir` (1821–1825). Extract `_phase_to_token`/`_token_to_phase`.
5. The orchestration-bookkeeping path exclusion list is hand-copied between `_write_lease_foreign_paths_now` (5372–5382) and `checkpoint_partial_isolated` (6005–6016) — with a comment (5969–5973) admitting the duplication. Extract `_is_orchestration_bookkeeping_path` (a pure string predicate; it changes nothing about `_mutation_dirty`'s control flow).
6. Quarantine `mv`s in the bootstrap sweep paths (1179, 1183, 1205, 1251) are unchecked — a failed move continues silently in a function whose stated design goal is "every failure path names itself" (962). Add `|| echo "BOOTSTRAP_QUARANTINE_MV_FAILED:$orphan" >&2` (non-fatal, observable). Also: `porcelain_offenders` (5545–5579) uses a define-then-`unset -f` global function as a closure substitute — a latent reentrancy trap; inline it as a `case` against a pre-joined pattern.

**Benefit.** Each removes a documented or latent drift/silent-failure risk on correctness-critical paths; collectively ~150 lines smaller.

## P23 — Kill the O(n²) checkpoint write path and the per-record jq loops

**Status:** ✅ implemented (b012f73)

**Criticality:** Medium · **Effort:** Moderate

**Problem.** (a) `checkpoint_append` (5738–5814) calls `checkpoint_resume_state` (5831–5956) on every append, which re-validates *every prior record* — including `git cat-file`/`git merge-base` per commit-bearing record and `sha256sum` per artifact record. A 50-task implementation pays ~1,275 redundant git subprocess invocations by run end. (b) `reconcile_propositions` (4649–4842) and `audit_run_state` (4853–5187) spawn one or two `jq` processes *per event row* inside bash loops — O(events × rules) process spawns at the Phase 11 audit.

**Proposed change.** (a) A `progress.jsonl.cursor` sidecar recording the last validated `(sequence, state)`; the write path trusts it when the file is byte-appended since, falling back to the full scan when stale — resume-time validation keeps re-scanning from scratch, unchanged. (b) Rewrite each audit rule as a single jq program grouping by id and emitting all violations in one pass; bash iterates findings, not source data.

**Benefit.** Real wall-clock cuts on exactly the two longest-running moments (implementation, readiness audit) with no semantic change.

## P24 — Give the Phase 10 commit message a deterministic contract

**Status:** ✅ implemented (e534b81)

**Criticality:** Low · **Effort:** Easy

**Problem.** Phase 10 creates the run's sole target-repo-visible artifact with `git commit -m "<message per the plan's git rules / CLAUDE.md git policy>"` (line 9443) — free-form, while every other artifact in the document has a structural contract (manifest registry, 311–342).

**Proposed change.** The orchestrator composes the message deterministically (zero-token) from data in hand — feature slug, spec/plan paths, gate verdict summary, a fixed footer naming the feature folder — using the plan's convention only for the summary line.

**Benefit.** The one durable git-visible trace of a run becomes auditable and reproducible.

## P25 — Compress "intentionally unreachable" justification prose

**Status:** ✅ implemented (2758a0a)

**Criticality:** Low · **Effort:** Easy

**Problem.** Several multi-paragraph comments exist solely to explain why a correct-but-unreachable path won't be fixed now: `_write_lease_path_ok` (5216–5228), `_snapshot_capture`'s per-artifact branch (5560–5578), and the `declared_foreign_commits: []` rationale stated twice (5473–5476, 5570–5578) — ~50 lines of pure justification in one section.

**Proposed change.** One-line markers naming the gap and its reactivation trigger, with a single canonical explanation cross-referenced rather than restated.

**Benefit.** Smaller resident prompt without losing the information; a style rule that compounds across the file (and becomes moot for the cookbook under P00 stage 1).

---

## Minor flagged items (no separate proposition)

- Line 20: "one source of trueth" — typo, and the sentence's grammar is unclear; copyedit.
- Plan Task Contract `skills` field (8142) is schema-checked (`EMPTY_LIST_OK`, 8196) but no consumer was found in the contract/cookbook ranges — either render it into the implementer dispatch prompt ("consider using: …") or delete the field (one grep decides).
- Line 422's `dogfood` "(or equivalent)" hint is unenforceable as written — subsumed by P01/P11 if adopted; otherwise tighten or drop.

---

## Suggested implementation order

| Wave | Propositions | Rationale |
|---|---|---|
| 1 — Safety hotfixes (all Easy) | P05, P06, P07, P14, P24 + P22 items 1/2/6 | Hang vector, false-HALT path, silent defaults — small diffs, immediate payoff |
| 2 — Known-weakness closures | P02, P12 (skill-probe false negative); P03, P10, P16 (shared-DB tests); P01, P11 (integration seams); P13 (deviations gate readiness) | The three observed real-run failure classes plus the one unread-artifact false-success path |
| 3 — Correctness consolidation | P04 (RUN_LOG readers), P08, P15, P17, P18 | One grammar, machine-checkable contracts, bounded loops |
| 4 — Size & structure | P00 stage 1 (cookbook eviction), then P20/P21/P25 for whatever prose remains, then P00 stages 2–3; P19, P22 rest, P23 | Stage 1 alone removes ~60% of resident bytes; textual dedup follows structure, not the reverse |

Wave 4 note: if P00 is adopted early, P20/P21/P25 shrink to near-free byproducts of the split — do P00 stage 1 before investing heavily in textual deduplication.
