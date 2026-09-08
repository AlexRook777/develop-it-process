# Live-run findings — first real run of the packs-split process (schema v2)

Date: 2026-09-07
Run: `2026-09-07-ubersuggest-dfs-metering-design.md` → target `ubersuggest-backend`
Process at run start: `d65cfea` (P00 stages 1–2 landed; 236 KB resident core)

This is the first execution of the process after the P00 phase-pack split. Every
item below was found by *running* it, not by reading it — each one had passed the
full offline suite (12/0/1) immediately beforehand. Fixes were applied in-session
and the suite re-run to green after each.

---

## F01 — No dispatch could deliver its prompt (blocked the entire run)

**Where:** `runtime/cookbook.sh`, `_launch_vendor_subprocess`.

**Symptom:** every vendor dispatch behaved as if given an empty prompt. Claude
answered *"I'm ready to help. What would you like to work on?"* (rc=0, one turn,
no tool use); codex exited rc=1 with `No prompt provided via stdin.`

**Cause:** the helper backgrounds the vendor command (`timeout … "$@" 1>out 2>err &`).
Bash redirects a background job's stdin to `/dev/null` in a non-interactive shell
unless the command carries an explicit stdin redirection, so `invoke_vendor`'s
`< "$prompt_file"` was silently discarded.

**Fix:** explicit `0<&0` on the backgrounded command.

**Why the suite missed it:** the fake CLIs in `tests/fakebin/` never read stdin, so
an empty prompt is indistinguishable from a correct one offline.

## F02 — An orchestration bug was classified as a vendor outage

**Where:** `runtime/cookbook.sh`, `classify_attempt`.

**Symptom:** F01's local CLI usage error classified as `UNKNOWN_VENDOR_ERROR`,
whose recovery row (RM10) forbids any automatic retry — so a self-inflicted defect
presented as an un-retryable vendor failure.

**Cause:** the document's own "Distinguish orchestration bugs from vendor failures"
rule existed as prose only; the classifier had no signature for it.

**Fix:** mechanized it — `unexpected argument|unrecognized argument|unknown option|^Usage:|required arguments were not provided|no prompt provided via stdin`
now classifies as `PRELAUNCH_FAILED` (RM01, correct-once-and-retry), evaluated
ahead of the vendor-liveness signatures.

## F03 — Two render keys nothing ever assigned

**Where:** `runtime/cookbook.sh`, `bootstrap_runtime`.

**Symptom:** every dispatch failed prelaunch with
`RENDER_VARIABLE_UNRESOLVED:ROLE_CONTRACTS_PATH,STATUS_PUBLISHER_PATH`.

**Cause:** both are in `render_keys()` and are used by every appendix's
publish-status call, but no code path set them. Only the offline checks did, by
hand, per check — which is exactly why the gap survived.

**Fix:** `bootstrap_runtime` fills them from `$RUNTIME_DIR`, *non-clobbering*
(`[ -n "${VAR:-}" ] ||`) so a test's fixture registry still wins.

## F04 — A mid-run process edit bricked every later phase

**Where:** `runtime/cookbook.sh`, `_bootstrap_verify_manifest` / `bootstrap_runtime`.

**Symptom:** after any edit to the process file set, every subsequent phase died
with `RUNTIME_MANIFEST_INVALID` until an operator manually removed the runtime
directory. Hit three times in one session.

**Cause:** one predicate conflated two conditions — *stale* (the recorded
process-fileset/extractor digest no longer matches: the process changed) and
*corrupt* (the generated files no longer match their own recorded hashes).

**Fix:** the verifier takes an optional second argument that skips only the two
identity comparisons. Stale-but-intact now quarantines the old runtime (evidence
kept) and regenerates, emitting `BOOTSTRAP_STALE_REGENERATED`; genuinely corrupt
still fails closed.

## F05 — The "cheap liveness probe" was the most expensive step in a gate

**Where:** `runtime/cookbook.sh`, `_vendor_headroom_probe`.

**Symptom:** `VENDOR_HEADROOM_REFUSED:spec-reviewer-codex:codex` aborted a
reviewer dispatch. The probe transcript showed the vendor had answered correctly
(`Pong!`, `turn.completed`) after spending **51k input tokens** and outrunning the
probe's own 30 s deadline.

**Cause:** three compounding choices — the probe prompt was the bare word `ping`,
handed to a reasoning model *with a writable workspace* (`-s workspace-write`) at
the role's own `high` effort. That is a task, not a greeting, so the model explored
the repo. The verdict logic then treated its own deadline as a vendor refusal.

**Fix:** prompt explicitly forbids work ("Reply with exactly one word: pong. Do not
read any file…"); `-s read-only` and `model_reasoning_effort=low` for the probe;
deadline 30 s → 60 s; ceiling-signature check moved *ahead* of the exit code; and a
deadline-killed probe that produced a completed turn now counts as live (it proved
exactly what the probe asks).

## F06 — `2-context-discovery/status.md` is read but never written

**Where:** `runtime/cookbook.sh`, `reconstruct_durable_inputs`.

**Symptom:** silent. `APPLICABLE_OPTIONAL_SKILLS` resolved empty for Phase 4
onward, with no error anywhere.

**Cause:** a pre-schema-v2 path. `context-discovery` publishes to its *attempt*
path only (`output_count: 0`), so the fixed filename never appears.

**Fix:** keep the fixed path as primary (an older run's alias still resolves), fall
back to the newest attempt's own STATUS by glob. Verified live: now resolves
`superpowers:finishing-a-development-branch;superpowers:using-git-worktrees`.

## F07 — `check_08_launcher` hangs on the caller's stdin

**Where:** `tests/check_08_launcher.sh`.

**Symptom:** the suite stalls indefinitely at `check_08` under any harness whose
stdin never reaches EOF.

**Cause:** `launch()` invokes the launcher with no stdin redirect; the launcher
ends in `exec claude`, and the fake claude drains stdin. The pty assertion below it
guards its own call site the same way — this one was missed. Separately, the
gate-fail block's comment promises "launch WITHOUT the skip flag" but never
stripped an inherited `DEVELOP_IT_SKIP_TESTS`, so the assertion tested nothing.

**Fix:** `</dev/null` on both call sites; `env -u DEVELOP_IT_SKIP_TESTS` on the
gate-fail launch.

## F08 — An interrupted suite leaves a phantom check that fails the next run

**Where:** `tests/run.sh`.

**Symptom:** `check_88_gatefail_probe.sh: No such file or directory`, reported as a
suite failure.

**Cause:** `check_08` plants `tests/check_88_gatefail_probe.sh` so `run.sh`'s glob
picks it up, and removes it in an EXIT trap. A SIGKILLed run skips the trap; the
next run globs the phantom, and `check_08` then deletes it underneath.

**Fix:** `[ -f "$check" ] || continue` — the glob is expanded once, up front, so
existence is re-checked at use.

## F09 — `develop-it.sh` treated "set but empty" as "run the suite"

**Where:** `develop-it.sh`.

Hardening only, not a live failure: `[ -z "${DEVELOP_IT_SKIP_TESTS:-}" ]` meant an
explicitly empty value re-enabled the pre-launch suite, and `check_08` re-invokes
the launcher — one extra nested full suite run (~2× runtime). Now tests set-ness
(`${VAR+x}`).

## F10 — The plan-writer manifest required headings the skill never produces

**Where:** Structural Artifact Manifest Registry (`develop-it-prompt.md`) and its
runtime mirror `_artifact_manifest_field`.

**Symptom:** `validate_artifact plan-writer` rejected a complete 24-task plan with
`VALIDATE_ARTIFACT_MISSING_HEADING:Goal`, blocking Phase 5 before any reviewer ran.

**Cause:** the row required the headings `Goal` and `File Structure and
Responsibilities`. `superpowers:writing-plans` prescribes neither: `Goal` is a
BOLD INLINE FIELD (`**Goal:**`) in the plan header, and the section is
`## File Structure`. The gate would therefore reject *every* plan the skill can
produce.

**Fix:** required headings are now `Global Constraints;File Structure` — both real
`##` sections the skill mandates. `check_06`'s fixture was updated, keeping its
heading-anchoring negative case (a heading that merely *contains* the required
text must not satisfy it).

## F11 — Phase 5 was missing from the durable-input map, and the plan alias is never written

**Where:** `reconstruct_durable_inputs` and `_reconstruct_accepted_plan`.

**Symptom:** `init_orchestration_vars 5` returned **0** with `$PLAN_PATH` and
`$SPEC_PATH` unset, so Phase 5's first dispatch failed render validation instead
of failing here with a named contract.

**Cause:** two independent bugs. The phase `case` listed 4, 6, 7, 8, 9 — no 5 —
even though all three Phase 5 roles declare `spec_path`/`plan_path` as required
inputs. And `_reconstruct_accepted_plan` reads `4-plan-writing/plan-status.md`,
another pre-schema-v2 alias nothing writes (plan-writer records the plan under
`output_01` in its attempt STATUS).

**Fix:** phase 5 added to the map; the plan path falls back to the newest
plan-writer attempt's own STATUS (`plan_path`, then `output_01`).

## F12 — A fixer that breaks its artifact's structure could only be retried blind

**Where:** the three document/implementation fixer contracts.

**Symptom:** `plan-fixer` broke the plan's `## Task Contract` block
(`task T24-finish-branch: missing files`). The retry-once policy re-dispatched it
with the identical inputs and it burned a full-length dispatch reproducing the
identical error, because nothing told it what had been rejected. The packs
prescribe HALT here, which for an autonomous run is a dead end.

**Fix:** new optional input `$VALIDATOR_ERRORS` carries the validator's own output
into the fixer, which must repair what it names *before* its assigned findings and
re-run the validator. On the next dispatch the fixer fixed it first try.

## F13 — The divergence valve goes blind exactly when the artifact is largest

**Where:** `divergence_check`.

**Symptom:** the plan grew 236 KB → 451 KB (+91%) over six rounds while every
round's fresh reviewers found new blockers in the newly added text, and
`divergence_check` returned `no` every single time.

**Cause:** `growth_without_reduction` requires **two consecutive** rounds above
`artifact_growth_warning_pct` (10). Per-round growth was 21, 9, 7, 5, 10 — never
two in a row — because a constant ~25–40 KB addition is a *shrinking percentage*
of a growing document. The valve is least sensitive precisely when each addition
costs the most. (Verified it was not simple thrash: `issue_key` recurrence across
iterations was zero, so the findings were genuinely new each round.)

**Fix:** an additional `cumulative_growth_without_reduction` condition compounds
every recorded round's growth and compares against a multiple of the same policy
threshold, with the same "open count is not falling" guard. It fires correctly on
this gate's ledger.

## F14 — The prescribed consolidation pass was unrepresentable

**Where:** the divergence handling in Phases 3/5/7 and the fixer contracts.

**Symptom:** on hitting `divergent_round_cap` the packs instruct the orchestrator
to dispatch "exactly ONE consolidation-priority fixer batch ... prioritizing
deletion/replacement/contradiction-removal over addressing new findings" — but no
role contract could carry that distinction, so the dispatch was byte-identical to
an ordinary additive batch, which is the one thing a diverging gate must not do
again.

**Fix:** new optional input `$CONSOLIDATION_PRIORITY`; when `yes` the fixer inverts
its priority (delete/merge/de-contradict, add nothing) and prefers one deletion
that closes several findings. The first real consolidation dispatch is what
produced the Phase 5 diagnosis below.

## F15 — A `BLOCKED` fixer leaves assigned findings undispositioned

**Where:** `plan-fixer` behavior, observed twice.

**Symptom:** the fixer returned `verdict: BLOCKED` with its two owner-input
findings left `open` and undispositioned — spec §17.3's "no assigned finding may
disappear". The packs define the DONE-with-gaps case as Mode 4 but say nothing
about BLOCKED-with-gaps.

**Handling this run:** treated as Mode 4 and retried once; the retry recorded both
as `blocked` correctly. Worth a pack rule so it is not left to judgment: a
`BLOCKED` verdict with any undispositioned assigned ID is the same orchestration
bug as a `DONE` one.

## F16 — A read-only role mutated the target repo, and the detection was never consumed

**Where:** role containment; `_dispatch_launch_attempt`'s `ARTIFACT_INTEGRITY_BLOCKED` emit.

**Symptom:** Phase 6's baseline gate refused to run: `working tree has changes
outside the orchestration slice: backend/e.py`. That file did not exist at Phase 1,
when the same gate passed.

**Cause:** `plan-reviewer-claude` — a role whose own appendix forbids writing
anything but its findings and STATUS — wrote `backend/e.py` (210 bytes, an import
block) into the target repo during `p05-i06-plan-reviewer-claude-a01`. The process
DID detect it and emitted `ARTIFACT_INTEGRITY_BLOCKED`, but **no phase step
consumes that event**, so the run continued for roughly fifty more minutes until a
different gate tripped over the file.

**Second-order defect:** the signal is sticky and misattributes. Once a stray file
exists, every LATER read-only dispatch's own pre/post comparison also reports
`INTEGRITY_UNKNOWN`, and the event records THAT role as `lease_owner`. Here the
following `summarizer-plan` and `preflight-claude` dispatches were both recorded as
integrity-blocked for a file neither touched — so `lease_owner` alone is not
attribution after the first occurrence.

**Fix:** the event now names the offending paths (via `porcelain_offenders`, the
same allow-list-aware reader `dirty_tree_check` uses, so orchestration artifacts
inside `$FEATURE_FOLDER` never appear). The stray file was quarantined — moved, not
deleted — to `.orchestration/quarantine/stray-repo-writes/`.

**Still open:** nothing branches on `ARTIFACT_INTEGRITY_BLOCKED`. A phase step
should surface it at the dispatch that caused it rather than letting a later,
unrelated gate discover the damage.

## F11b — Third and fourth instances of the dead-alias class, now fixed once

**Where:** `plan_ready_for_implementation`, `_reconstruct_implementation_baseline`.

**Symptom:** a plan-review gate that had genuinely closed reported "plan not ready:
no plan-review summarizer status"; separately, every phase needing the
implementation baseline failed prelaunch.

**Cause:** the same pattern as F06 and F11 — fixed phase-local aliases that schema
v2 stopped writing. `5-plan-review/summarizer-status.md` and
`6-implementation/implementer-status.md` are both never written; only the
summarizer's `*-summary.md` output lands at a fixed path.

**Fix:** one shared `_resolve_status_path <fixed-alias> <attempts-glob>` helper
(prefer the alias so an older run still resolves, else newest attempt), and all
four readers moved onto it. Four independent one-off patches would otherwise have
been four chances for a fifth instance.

## F17 — The implementation baseline silently resolved to `non-git`

**Where:** `_reconstruct_implementation_baseline`.

**Symptom:** would have been silent. `$IMPLEMENTATION_BASE_SHA` resolved to
`non-git` in a perfectly normal git repository.

**Cause:** the function read the SHA as
`status_field "$RUN_LOG.md" implementation_base_sha`, but the
`IMPLEMENTATION_BASELINE` event writes the field as **`base_sha`**. The lookup
returned empty and the `|| IMPLEMENTATION_BASE_SHA=non-git` fallback took over.
Downstream that strips the diff scope from both Phase 7 reviewers (they would
review nothing) and makes Phase 10 record `outcome=BLOCKED (not-a-git-repo)` and
commit nothing — in a git repo, with no error anywhere.

A third bug in the same six lines: `status_field` on `RUN_LOG.md` returns the
FIRST match, while the documented consumer rule is the LATEST
`IMPLEMENTATION_BASELINE` (a resumed run has more than one).

**Fix:** read `base_sha` through the shared `_run_log_latest_field` latest-event
reader; resolve the implementer STATUS through `_resolve_status_path`; and phase 6
was missing from the reconstruction map entirely (F11's sibling), so it now calls
the function in a new `tolerant` mode — the same phase-6 init runs both before
Step 6.0, which creates the baseline, and at Step 6.1, which requires it.

---

## Policy change (owner decision, same session)

**Relaxed tier simplified.** Previously, iteration ≥ 3 passed only when zero
blockers remained **and** every open MAJOR carried an explicit
`deferred:`/`accepted_risk:` disposition, with every fixer dispatch followed by a
mandatory reviewer round. In practice the fixer always chose `fixed`, each fix added
text, and each round's fresh reviewers found new majors in the new text — Phase 3
ran 5 iterations with the spec growing 36 KB → 90 KB (majors 13 → 10 → 8 → 5 → 8,
0 blockers throughout, one `DIVERGENCE_DETECTED(growth_without_reduction)`).

New rule: **at iteration ≥ 3, zero open blockers is the only pass requirement.**
Majors never block there; they get exactly ONE final bounded fixer batch which
closes the gate *without* re-review, and anything still open is recorded in the
gate summary and `followups.jsonl`. Blockers keep the full fix→re-review loop at
every iteration.

The accepted trade is explicit: this overrides spec §18.2's "no unreviewed final
fix", which the document previously asserted as an unconditional invariant. It is
now tier-scoped — strict tier keeps the guarantee, the relaxed tier's single
majors-only batch is the one authorized exception, and a BLOCKER never gets it.
`tests/check_05_contract.sh` T16 was re-pointed to pin both halves.

---

## Theme

Eight of the nine defects are in code the offline suite covers heavily (497
assertions in `check_06` alone) yet could not catch, because they live at the
boundary the fakes replace: **real stdin, real vendor latency, real process-file
churn, real subprocess exit semantics.** The suite's fakes never read stdin, never
take 30 seconds, and never see the process file set change mid-run. That boundary —
not the logic behind it — is where a first live run pays for itself, and it is the
same argument the P00 stage-3 note makes for a live pilot before coding
suborchestration.
