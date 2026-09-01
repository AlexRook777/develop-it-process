<!-- PACK: phases/8-all-tests.md — sole normative source for Phase 8 (all-tests); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase 8 — All tests (delegated, test→fix loop)

Runs after the Phase 7 code-review gate passes. Non-gated phase: no per-phase preflight, claude-only (Codex is never dispatched here). Runs in non-git working directories too — tests do not require a repository.

### Step 8.1 — Test rounds

For each round N (start at 1, hard cap at 4 — the initial run plus at most 3 fix→re-run rounds), `$PHASE_DIR/$ITERATION` is `8-all-tests/NN` (`$ROUND`, never `round-NN`):

1. `mkdir -p <feature-folder>/8-all-tests/NN`.
2. Dispatch one `claude` subprocess for role `all-tests-runner` (`dispatch_attempt 8 $ROUND all-tests-runner`). Inputs: `$FEATURE_FOLDER`, `$REPO_ROOT`, `$ROUND=NN`. This role's timeout comes from the Models table via `role_timeout`. Its real STATUS: `runner_status="$(role_attempt_dir all-tests-runner "$(_latest_attempt_id p08-i$ROUND-all-tests-runner)")/STATUS.md"`. **All test commands run in the foreground under print-mode rules (spec §12.2) — never backgrounded.** The runner:
   - Runs every command the accepted plan's `## Task Contract` blocks declared under `verification` (spec §19.2) PLUS the repository's authoritative full suite (below). For EACH command, calls `append_verification_record` (cookbook) to append to `8-all-tests/NN/verification-records.jsonl` — fresh in round 1, appended to in later rounds (the same Mode A/Mode B convention the implementer's own `verification-records.jsonl` already uses) — one record per command, never a single phase-level rollup standing in for per-command evidence.
   - `start-all-tests.sh` is a project-specific convention, not a universal one; fall through to discovery when it is absent. If `$REPO_ROOT/start-all-tests.sh` exists, runs it (the canonical full-suite entry point for repos that define one).
   - Otherwise discovers every test suite present in the repo (`uv run pytest` for Python suites — plain `pytest` is not installed standalone in this environment, `package.json` test scripts, etc.) and runs each.
   - If neither the script nor any test suite exists AND the plan declared no verification commands of its own, reports `verdict=SKIPPED, reason=no-tests-found`.
   - Writes the detailed per-round report `8-all-tests/NN/test-report.md`, rewrites the cumulative `8-all-tests/all-test-summary.md`, then publishes STATUS LAST.
3. Read only the runner's own STATUS.md. `dispatch_attempt` already appended the RUN_LOG dispatch entry (`phase: 8`, `phase_name: all-tests`, `iteration: NN`, `role: all-tests-runner`).
4. Call `validate_verification_records "8-all-tests/NN/verification-records.jsonl"` (cookbook, spec §19.2) — the zero-token enforcement of every per-record rule (empty-is-never-PASS, EXCLUDED exclusion_class/evidence, NOT_RUN reason/followup_id, controlled performance baseline) the runner's own STATUS cannot self-certify. A validation failure is Mode 4 (malformed evidence) regardless of what the runner claimed. `EXCLUDED` and `NOT_RUN` records are policy-valid evidence, never silently promoted to `PASS` — both flow through to Phase 9/Phase 11 exactly as recorded, never becoming PASS by exhausting the fix cap below.
5. Branch on the runner's verdict:
   - **`PASS` or `SKIPPED`** → proceed to Step 8.2.
   - **A `FAIL`:** before dispatching anything, reproduce it in isolation (P10) — a deterministic, no-vendor-call step the orchestrator runs directly, exactly like the audit calls in Phase 11 (`phases/11-readiness.md`): `acquire_test_lease orchestrator-test-repro 8` (cookbook, spec-adjacent P03 — a held lease means wait-with-timeout, then HALT naming the lease path; never run concurrently with it), re-run ONLY the command(s) whose record in `8-all-tests/NN/verification-records.jsonl` this round shows `result=FAIL` — once, serialized — then `release_test_lease orchestrator-test-repro`.
     - **Reproduces (the re-run command still fails):** a genuine defect. With fix rounds used < 3, dispatch one `claude` subprocess for role `test-fixer` (`dispatch_attempt 8 $ROUND test-fixer` — `mutates=yes`, so this dispatch automatically acquires the single write lease and its before/after mutation snapshot before launch; `test-fixer` never runs without holding it). Inputs: `$FEATURE_FOLDER`, `$PLAN_PATH`, `$ROUND=NN`, `$TEST_REPORT_PATH` (= `8-all-tests/NN/test-report.md`), `$IMPLEMENTATION_BASE_SHA`. This role's timeout comes from the Models table via `role_timeout`. On `verdict=DONE`, increment N and loop from step 1 — this is the review-back rule: the fixer's own `DONE` claim is never trusted on its own word; the NEXT round's runner, re-verifying every command from scratch under the same lease/snapshot/checkpoint discipline, is the canonical re-verification authority (the fixer's own appendix already states this). On `verdict=BLOCKED`, stop the fix loop early — do NOT HALT; proceed to Step 8.2 with the round's failures as residual. With fix rounds exhausted (3 used): do NOT HALT. Proceed to Step 8.2 — the final test verdict is `FAILED`, and `all-test-summary.md` MUST carry the detailed residual-failure record (failing test names, error excerpts, suspected causes, and what each fix round attempted).
     - **Does not reproduce (every re-run command now passes):** flaky, not a defect — never dispatch `test-fixer` for it and never spend a fix round on it. Append a `## Flake check (round NN)` note to `8-all-tests/NN/test-report.md` naming the command(s), `result=flaky`, and the isolated re-run's outcome (this note is prose in the round report, not a `verification-records.jsonl` entry — `flaky` is not a legal verification `result`, spec §19.2). Treat the round as PASS-with-note: proceed directly to Step 8.2 without incrementing the fix-round count. `summarizer-all-tests` already folds any detail present in a round's `test-report.md` into `all-test-summary.md` (see its own appendix, step 2) — the exact file `readiness-writer` reads — so this note is surfaced to readiness without any further change. A round with both a reproducing and a non-reproducing failure takes both branches: record the flaky note for the non-reproducing command(s) AND the reproduces-branch above for the rest.

### Step 8.2 — Summarizer

Dispatch one `claude` subprocess for role `summarizer-all-tests`. Inputs: `$FEATURE_FOLDER`. The summarizer APPENDS the `## Usage` section to `8-all-tests/all-test-summary.md` (the runner already wrote the content) and writes its own STATUS carrying `final_test_verdict: PASS | FAILED | SKIPPED`. This role's timeout comes from the Models table via `role_timeout`.

You read only the summarizer's own STATUS.md. On `verdict=DONE`, proceed to Phase 9 — regardless of `final_test_verdict`. A `FAILED` final test verdict never halts the run; it is recorded in detail in `all-test-summary.md` and forces the final readiness verdict to `NOT_READY` (see the readiness-writer appendix).

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: all-tests-runner -->
# Role: all-tests-runner

You are a test runner invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder;repo_root;round`
- Optional inputs: `none`
- Outputs: `status;test_report`
- Allowed verdicts: `PASS;FAIL;SKIPPED`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `8`

## Inputs

- `$FEATURE_FOLDER`
- `$REPO_ROOT`
- `$ROUND` — two-digit round number (01–04)

## Behavior

**All test commands run in the foreground under print-mode rules (spec §12.2) — never backgrounded.**

1. **Probe and force serial mode (P03).** Before running anything, detect
   whether this suite is safe to run at whatever parallelism the project
   defaults to: read `policy_value test_suite_parallel_safe` (cookbook), and
   independently probe the repo itself for signals of a shared, non-isolated
   resource under an already-configured parallel runner — `pytest-xdist`/
   `-n auto` (or any `-n` > 1) with no per-worker suffix on
   `TEST_DATABASE_URL` (or an equivalent shared-resource env var), a Jest
   `maxWorkers` setting with no `--runInBand`, or any other multi-worker
   flag paired with that same single shared resource. Force serial
   execution — pass the project's own serial flag (e.g. `-p 1` /
   `--runInBand`) or drop the discovered parallel flag — whenever EITHER
   the policy value is `no` (the default) OR the probe finds one of these
   signals, regardless of the declared policy (the probe is a second,
   independent net, not a substitute for the declared policy). Record which
   of `policy` / `probe` / `neither` forced serial mode (and, for `probe`,
   which signal) — step 5 writes this into `test-report.md`.
2. Acquire the test-execution lease before running anything below
   (`acquire_test_lease all-tests-runner 8`, cookbook, spec-adjacent P03) —
   a lease already held by another runner/fixer/operator means
   wait-with-timeout, then HALT naming the lease path; never run
   concurrently with it. Release it (`release_test_lease all-tests-runner`)
   only after every command step 3 runs below has finished, success or
   failure alike.
3. Determine the execution mode. `start-all-tests.sh` is a project-specific convention; fall through to discovery when absent.
   - If `$REPO_ROOT/start-all-tests.sh` exists, the mode is `script`: run it from `$REPO_ROOT` (`bash start-all-tests.sh`), capturing stdout+stderr.
   - Otherwise the mode is `discovery`: enumerate every test suite present in the repo — e.g. Python suites (`uv run pytest`, honoring `pyproject.toml` / `pytest.ini` configuration — plain `pytest` is not installed standalone in this environment), JS/TS `package.json` `test` scripts (run per package), and any other runner the repo's config files declare. Run each suite, capturing output.
   - Also run every command the accepted plan's own `## Task Contract` blocks declared under `verification` (spec §19.2), even when it duplicates a suite already covered by the script/discovery mode above — the plan's own declared commands are first-class evidence, not merely covered by the repository-wide run.
   - If the script does not exist, no test suite is discovered, AND the plan declared no verification commands of its own, the round verdict is `SKIPPED` with `reason=no-tests-found`.
   - Every command run under step 1's forced serial mode carries the serial flag; a plan-declared `environment: exclusive` verification command (P16) additionally holds the SAME test lease this step already acquired — never released and re-acquired mid-round for it, since one lease per round already covers it.
4. For EACH command run in step 3 (the full-suite script/discovery run counts as one command; each plan-declared verification command counts as its own), call `append_verification_record` (cookbook, spec §19.2) to append one record to `$FEATURE_FOLDER/8-all-tests/$ROUND/verification-records.jsonl` — `result: PASS|FAIL|EXCLUDED|NOT_RUN` per that command's own outcome, never a single rollup standing in for every command; an `EXCLUDED` result sets a policy-valid `exclusion_class` (`pre_existing|environment_bound|actor_bound|outside_capability`) plus evidence, and a `NOT_RUN` result sets a non-null `followup_id` (spec §19.2, P15). Round 1 starts the file fresh; a later fix round APPENDS to the SAME file (never truncates it), reusing the SAME `verification_id` for a command re-run after a fix, so the latest record supersedes the earlier one (the same Mode A/Mode B convention the implementer's own verification records already use).
5. Do NOT fix anything. You only run tests and report — fixing belongs to the `test-fixer` role.
6. Write `$FEATURE_FOLDER/8-all-tests/$ROUND/test-report.md` — the detailed per-round report: execution mode, exact commands, per-suite pass/fail counts, every failing test's name, the relevant error excerpt (assertion/traceback tail, not the full log), and step 1's forced-serial-mode determination (`policy` / `probe` / `neither`, plus the triggering signal when `probe`).
7. Rewrite `$FEATURE_FOLDER/8-all-tests/all-test-summary.md` (full overwrite, cumulative across rounds — re-read earlier rounds' `test-report.md` and their attempt-scoped STATUS.md files) with:
   - Execution mode (`script` / `discovery`) and the commands used.
   - Per-round results table: round, suites run, total / passed / failed.
   - Current verdict after this round.
   - **Residual failures** section — present whenever this round has failures: failing test names, error excerpts, suspected causes, and what each prior fix round attempted. This section is the canonical detailed record when the phase ends `FAILED` after the fix cap.
   - Do NOT write a `## Usage` section — the summarizer appends it.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=all-tests-runner phase=8 iteration='$ROUND' verdicts='PASS | FAIL | SKIPPED' reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to $ROUND/test-report.md>
checkpoint_path: null
x_mode: script | discovery
x_suites_run: <int>
x_tests_total: <int>
x_tests_passed: <int>
x_tests_failed: <int>
x_verification_records_path: <absolute path to $ROUND/verification-records.jsonl>
x_serial_forced_by: policy | probe | neither
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: all-tests-runner -->

<!-- BEGIN: test-fixer -->
# Role: test-fixer

You are a test fixer invoked as a fresh subprocess when a Phase 8 all-tests round reports `FAIL`. You have no shared context.

## Role contract

- Required inputs: `feature_folder;plan_path;round;test_report_path;implementation_base_sha;context7_policy`
- Optional inputs: `none`
- Outputs: `status`
- Allowed verdicts: `DONE;BLOCKED`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `8`

## Inputs

- `$FEATURE_FOLDER`
- `$PLAN_PATH`
- `$ROUND` — the failing round number (your STATUS lands in that round's folder)
- `$TEST_REPORT_PATH` — absolute path to the failing round's `test-report.md`
- `$IMPLEMENTATION_BASE_SHA` — git SHA captured before any implementer dispatch (or `non-git`)
- `$CONTEXT7_POLICY` — `required` or `best-effort` (see below)

## Required skills

- Load `superpowers:systematic-debugging`. Follow it strictly.
- `context7` policy for this run: **$CONTEXT7_POLICY**.
  - `required` — you MUST call `resolve-library-id` then `get-library-docs`
    whenever the failure signature points at an external library, framework,
    SDK, API, CLI tool, or cloud service.
  - `best-effort` — `context7` was unreachable at preflight. Attempt it when
    relevant; if it fails, proceed using the plan's cited APIs and record in
    your summary which APIs you could not verify against current
    documentation.

## Behavior

1. Read `$TEST_REPORT_PATH` to identify the failing tests and their failure signatures.
2. **Reproduce before fixing (P10, mirrored from Phase 8 Step 8.1).** Phase 8 already re-ran `$TEST_REPORT_PATH`'s failures in isolation before dispatching you, so ordinarily every cluster here is genuine. Mirror the same check for any failure this attempt inherits or turns up mid-round that was NOT part of that pre-dispatch reproduction (e.g., a new failure surfaced by your own earlier fix's re-run, step 4 below): re-run just that cluster's failing command(s) once, serialized, holding the P03 test lease (`acquire_test_lease test-fixer 8` / `release_test_lease test-fixer`, cookbook — wait-with-timeout, then HALT naming the lease path on a held lease). A cluster that does not reproduce is flaky, not a defect — do not edit code for it; note it `flaky` in your STATUS `reason`/progress notes and leave it for the next round's runner, the canonical re-verification authority. Only a cluster that DOES reproduce proceeds to step 3.
3. Apply systematic debugging per failure cluster: hypothesis → minimal repro → root cause → fix. Fix the code when the code is wrong; fix the test ONLY when the test itself is defective against the spec/plan intent — never weaken, skip, or delete a test just to make it pass.
4. Re-run the failing tests to spot-check your fixes (the canonical re-verification is the next all-tests round), holding the SAME P03 test lease step 2 uses (`acquire_test_lease test-fixer 8` / `release_test_lease test-fixer`, cookbook) around this re-run — never run it lease-less just because step 2 already acquired and released one for a different cluster.
5. If the fix changes source/tests, commit per the project's git policy.
6. Where a failure requires a decision that cannot be made without user input, do NOT guess — set `verdict=BLOCKED`.

You may use `$IMPLEMENTATION_BASE_SHA` to constrain `git log`/`git diff` scope to commits made during this run.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=test-fixer phase=8 iteration='$ROUND' verdicts='DONE | BLOCKED' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: null
x_fixed_tests: <int>
x_root_causes: <one line per failure cluster, semicolon-separated>
x_fix_summary: <one line>
x_new_commits: [sha, ...]
<!-- INCLUDE-END -->

`verdict=DONE` does not promise the suite passes — it promises fixes were applied. The next all-tests round is the canonical verification authority.

Exit 0 only after the publisher exits 0.
<!-- END: test-fixer -->

<!-- BEGIN: summarizer-all-tests -->
# Role: summarizer-all-tests

You are a phase summarizer invoked as a fresh subprocess by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `run_log`
- Outputs: `summary;status`
- Allowed verdicts: `DONE`
- Required status fields: `common_v2`
- Checkpoint kind: `none`
- Phases: `8`

## Inputs

- `$FEATURE_FOLDER`
- `$FEATURE_FOLDER/RUN_LOG.md`
- `$FEATURE_FOLDER/8-all-tests/all-test-summary.md` (already written by the runner; you APPEND a `## Usage` section to it)

## Behavior

1. Read every round's own attempt-scoped STATUS (`8-all-tests/*/attempts/*-all-tests-runner-*/STATUS.md`, and `8-all-tests/*/attempts/*-test-fixer-*/STATUS.md` where present — never the retired `round-*/test-runner-status.md` alias). Determine: `final_test_verdict` (`PASS` if the last round passed; `SKIPPED` if the runner reported no tests; `FAILED` if failures remain after the fix loop ended — cap exhausted or fixer `BLOCKED`), rounds used, fix rounds dispatched, residual failure count.
2. Verify `all-test-summary.md` carries the **Residual failures** detail section whenever `final_test_verdict=FAILED`; if the runner's last write is missing detail that exists in the round reports, fold it in (edit the summary in place) — the summary must be self-sufficient for the readiness writer and the user. Likewise, fold in a **Flaky (non-blocking)** section (round, command, `result=flaky`) whenever any round's own `test-report.md` carries a `## Flake check` note (P10, spec-adjacent) — present regardless of `final_test_verdict`, since a flaky round is PASS-with-note, never a silent drop.
3. Read `$FEATURE_FOLDER/RUN_LOG.md`. Filter dispatch entries (NOT event entries) where `phase=8`. Compute the same Usage aggregation as `summarizer-implementation` (phase total, per-vendor subtotal, per-role × round detail; rows with `usage_status=unavailable` are skipped from the detail table but counted in a footnote).
4. APPEND the `## Usage` section to `$FEATURE_FOLDER/8-all-tests/all-test-summary.md` with the three standard tables (same columns and formatting rules as `summarizer-implementation`).

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=summarizer-all-tests phase=8 iteration=00 verdicts=DONE reason='<one line, or the literal word null>' -->
output_count: 1
output_01: <absolute path to the summary file you wrote>
checkpoint_path: null
x_final_test_verdict: PASS | FAILED | SKIPPED
x_rounds: <int>
x_fix_rounds: <int>
x_residual_failures: <int>
x_dispatches: <int>
x_skipped_unavailable: <int>
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: summarizer-all-tests -->
