<!-- PACK: phases/1-preflight.md — sole normative source for Phase −1/1 (preflight); Read this file end to end before executing any step of this phase; cite this header line as evidence of the load -->

## Phase −1 — Preflight skill availability check

Goal: confirm the environment is sound (binaries, CLI syntax, working tree) AND that both worker CLIs can load every Superpowers skill this orchestration depends on. If any preflight step fails, HALT with a clear remediation message — Phase 2 does not start.

### Step 1.0 — CLI canary + clean-tree gate (before any subprocess dispatch)

These checks are free (no token spend) and catch environmental issues that previously consumed real dispatch attempts. Run them BEFORE creating the feature folder or invoking skill probes.

**Every halting gate in Step 1.0 is logged, and creates `$FEATURE_FOLDER` in
order to log it -- with exactly ONE exception, named below.** This resolves an
ambiguity the gates would otherwise carry: they run before the feature folder
exists, yet several of them prescribe a RUN_LOG write. The rule is uniform for
gates 2 (local CLI canaries), 3 (target dirty-tree gate), 5 (runtime +
registries), the Mode-0 codex check, and the paid model-ID probe: a gate that
HALTs first creates `$FEATURE_FOLDER` (and `RUN_LOG.md` inside it), then
appends its entry, then STOPs. Use the gate's own event tag where one exists
(`CODEX_UNAVAILABLE` for the Mode-0 codex check, `MODEL_REJECTED` for the paid
model-ID probe) and `event=HALT` for the gates that have none (gates 2, 3, and
5). Do not skip the folder to avoid the write, and do not invent an event tag
outside the legal set in Resumability.

**The one exception is gate 1's existing-run-log validation
(`validate_existing_run_log`).** A HALT there (`RUN_LOG_SCHEMA_V1_OR_UNKNOWN`,
`RUN_LOG_SCHEMA_MALFORMED`, or `RUN_LOG_IDENTITY_MISMATCH`) writes ZERO bytes
to `RUN_LOG.md` and creates no new folder — see gate 1's own description
below for why: the log at that path cannot yet be trusted, so this is not a
case the uniform rule was ever meant to cover.

This is implementable at every gate because `$FEATURE_FOLDER` is a pure string
transform of the spec path (see "Naming convention") and `init_orchestration_vars`
already requires it to be set at step 1 — only the *directory* is missing, never
the path. The one exception is the unnamed-spec case in "Naming convention",
where the folder name is not yet known because a subagent must propose it: there,
HALT without the RUN_LOG write rather than inventing a folder to log into.

This is resume-safe: a `RUN_LOG.md` containing only pre-dispatch event entries
has no `DISPATCH_STARTED` records, so `dispatch_is_running` is false and every
role is `NEVER_LAUNCHED` — the retry is a genuine fresh Phase 1, not a resume. The cost
is one empty folder after a failed gate; the benefit is that no HALT in this
process is silent.

**Gate order is the load-bearing invariant (spec §16.1): no paid model probe
and no vendor subprocess of any kind may start until all five zero-token
gates below have each emitted their success event, IN ORDER.** Open this
step's shell like every other phase block —
`source "$(dirname "$PROCESS_PATH")/runtime/cookbook.sh"` first (see "Shell
policy") — then call `preflight_zero_token_gates` (see cookbook) to run them:

1. **Gate 1 — paths + new-run schema eligibility.** Initialises the
   orchestration variables (`PROCESS_PATH`, `REPO_ROOT`, `PROCESS_REPO_ROOT`,
   `PYTHON_BIN`, `PROCESS_FILE_SHA256`, `PROCESS_GIT_HEAD`, `PROCESS_DIRTY`)
   via `init_orchestration_vars`, THEN calls `validate_existing_run_log` (see
   "Preflight zero-token gate sequence" cookbook section) to decide whether
   an existing `$FEATURE_FOLDER/RUN_LOG.md` is safe to resume into. On
   `RUN_LOG_SCHEMA_V1_OR_UNKNOWN`, `RUN_LOG_SCHEMA_MALFORMED`, or
   `RUN_LOG_IDENTITY_MISMATCH`: HALT immediately, surfacing the printed
   instruction to use this run's recorded process version (or start a new
   feature folder) to the user. **Do NOT create `$FEATURE_FOLDER` or write
   anything to `RUN_LOG.md` on this specific HALT** — the log at that path
   cannot yet be trusted, so appending to it (even an `event=HALT`) would be
   writing into evidence this gate cannot vouch for; this is the one HALT in
   Step 1.0 that writes zero bytes. On success (`NEW_RUN_ELIGIBLE` for a
   fresh folder, `RESUME_ELIGIBLE` for a matching schema-v2 log), the gate
   creates `$FEATURE_FOLDER` and appends `event=PATHS_AND_NEW_RUN_SCHEMA_
   ELIGIBLE`.
2. **Gate 2 — local CLI canaries.** Runs `canary_preflight`: `claude`,
   `timeout`, `awk`, `sed`, `jq`, `git`, `date`, `sha256sum`, `cut`, `mkdir`,
   `mv`, `tail`, `tr`, `grep`, `realpath`, `env` are on PATH (hard-required);
   `codex` is optional (its absence sets `codex_present=no` and drives the
   failover policy ("Vendor failover policy", core document), not a halt at this gate); `python3` is on PATH
   (hard-required — `render_prompt` cannot function without it); `claude
   --help` and `codex exec --help` succeed. On halt: append an `event=HALT`
   entry naming the missing binary or the failing syntax check (per the
   logging rule above), surface the same to the user, and STOP — do not
   proceed to gate 3, do not run any probe. On success, appends
   `event=LOCAL_CLI_CANARIES_PASSED` with `codex_present`.
3. **Gate 3 — target dirty-tree gate.** Runs `dirty_tree_check`. On halt:
   append an `event=HALT` entry listing the offending paths (per the logging
   rule above), then list them to the user and ask them to commit or stash
   before re-running. On success, appends `event=TARGET_DIRTY_TREE_GATE_
   PASSED`.
4. **Gate 4 — process identity + gitignore.** Process identity was already
   resolved by gate 1's `init_orchestration_vars` (`$PROCESS_DIRTY` is one of
   `no|yes|untracked|unknown`, the last always paired with `$PROCESS_DIRTY_
   REASON` — see the "Process-fileset identity" section of
   `runtime/cookbook.sh`). This gate
   additionally runs `verify_gitignore_guard`: confirms that
   `docs/superpowers/specs/*-artifacts/` (or the equivalent pattern matching
   the eventual `$FEATURE_FOLDER`) is either listed in `.gitignore` OR that
   the orchestrator's runtime dirty-check allow-list already covers it (it
   does). If neither holds, emit a one-line warning recommending the
   `.gitignore` addition; do NOT halt — this gate never fails. Appends
   `event=PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED` with `develop_it_dirty`
   and `develop_it_dirty_reason` (empty unless `develop_it_dirty=unknown`).
5. **Gate 5 — runtime + registries.** Calls `bootstrap_runtime` (see "Runtime
   extraction contract", core document) to materialize `$FEATURE_FOLDER/
   .orchestration/runtime/` — this is the run's first bootstrap, so it always
   materializes fresh (`BOOTSTRAP_OK`) on a genuinely new run, or verifies and
   reuses (`BOOTSTRAP_REUSED`) on a resume. On any non-zero return, HALT:
   append an `event=HALT` entry naming the token printed on stderr
   (`RUNTIME_MANIFEST_INVALID:...`, `BOOTSTRAP_RACE_LOST_INVALID:...`, or
   `BOOTSTRAP_IO_ERROR:...`), then STOP before any subprocess dispatch. On
   success, `preflight_zero_token_gates` immediately `source`s
   `$RUNTIME_DIR/develop-it-runtime.sh` — every helper referenced from here
   on (`dispatch_parallel`, `validate_status`, `context7_policy`, ...) comes
   from that sourced file — and appends `event=RUNTIME_AND_REGISTRIES_
   VERIFIED` with `bootstrap_result`.

**Only after all five gates above have succeeded** may the run spend a
single token:

6. **Mode 0 codex check (zero-token; evaluated here, not re-run).** If
   gate 2's `canary_preflight` reported `codex_present=no` (Mode 0 — binary
   missing, environmental), HALT unconditionally. Surface the remediation
   message ("Install the Codex CLI and re-run") and STOP. Do NOT prompt the
   user, do NOT continue in claude-only mode, do NOT proceed further. A
   missing Codex binary at Phase 1 is an environment defect that must be
   fixed before the run can proceed in any mode; the previous silent-degrade
   behavior masked broken setups. This matches the Phase 1 row of the
   Mode-specific response table (Mode 0 → HALT) and Step 1.1 step 6's Mode 0
   branch — Phase 1 Mode 0 is the only failure mode at Phase 1 that bypasses
   the user consent prompt, because there is no working Codex CLI to even
   produce a meaningful stderr tail for the user to consent on. Log
   `event=CODEX_UNAVAILABLE` with `phase: 1`, `phase_name: preflight`,
   `failure_mode: 0`, and `stderr_tail: <canary output>` to `RUN_LOG.md`
   immediately before STOP so the HALT is auditable.
7. **Paid minimal model-ID probe — the FIRST token this run ever spends.**
   Run `probe_models "$CODEX_PRESENT"` (the flag `preflight_zero_token_gates`
   set from gate 2), one minimal call per distinct pinned model id:

   <!-- lint: snippet -->
   ```bash
   probe_models "$CODEX_PRESENT"   # "yes" | "no"
   ```

   When it is `no`, every codex row is skipped and the Mode-0 branch above
   already handled the missing binary on its own terms. Every id it does
   probe must be accepted. On any rejection, HALT: print each `role=<role>
   model=<id>` line, noting that this process pins its models deliberately;
   there is no fallback path. Instruct the user to update the Models table.
   Log `event=MODEL_REJECTED` with the offending roles to `RUN_LOG.md` before
   stopping. This is a runtime gate; `tests/check_90_live_models.sh` performs
   the same probe as an opt-in test.

Only once step 7 accepts every pinned model id does Step 1.1 below dispatch
the first real subprocess (the skill/MCP capability probes).

### Required skills

Claude CLI must be able to load:
- `superpowers:writing-plans`
- `superpowers:subagent-driven-development`
- `superpowers:systematic-debugging`
- `superpowers:verification-before-completion`
- `superpowers:test-driven-development`
- `superpowers:requesting-code-review`
- `superpowers:receiving-code-review`

Codex CLI must be able to load:
- `superpowers:writing-plans` (read-only)
- `superpowers:subagent-driven-development` (read-only)
- `superpowers:verification-before-completion`

MCP servers that must be reachable:
- `context7` — required by `plan-writer`, `implementer`, `debugger` and
  `test-fixer`. It is an **MCP server, not a Superpowers skill**, so it is not
  covered by the skill probes above.

If `context7` is unreachable, do NOT halt. Log `event=CONTEXT7_UNAVAILABLE` and
downgrade the requirement to best-effort for this run. Silently proceeding — the
previous behaviour — hid the degradation from the final report.

### Step 1.1 — Skill probe flow

1. `$FEATURE_FOLDER` and `$FEATURE_FOLDER/.orchestration/runtime/` already exist — Step 1.0's `preflight_zero_token_gates` (gates 1 and 5) created and bootstrapped them, and already `source`d `$RUNTIME_DIR/develop-it-runtime.sh` — every helper referenced below (`dispatch_parallel`, `validate_status`, `context7_policy`, ...) comes from that sourced file. This step only needs to create the `1-preflight/` subfolder with `mkdir -p`.
2. **Dispatch both preflight subprocesses in parallel using `dispatch_parallel 1 00 preflight-claude preflight-codex`** (see "Reviewer parallelization", core document; preflight has no shared state between vendors, so this is safe as the very first dispatch of the run). This is the ONLY dispatch mechanism for Step 1.1 — there is no separate `dispatch_attempt` call for either preflight role. Each subprocess's STATUS is published, exactly like every other role in this document, to the attempt-scoped `1-preflight/00/attempts/<dispatch-id>/STATUS.md` `dispatch_attempt` itself computed and passed as `$PHASE_DIR/00/attempts/$DISPATCH_ID/STATUS.md` — never a hand-picked filename. There is no "canonical slot" any appendix writes to directly.
   - **Claude subprocess (always dispatched):** role `preflight-claude`. Transcript: `<feature-folder>/transcripts/<dispatch_id>.stdout` (stdout) and `<dispatch_id>.stderr` (stderr) — `allocate_attempt`'s naming form. This role's timeout comes from the Models table via `role_timeout`.
3. **Codex subprocess (dispatched if and only if `codex_available = true`):** role `preflight-codex`, dispatched by the SAME `dispatch_parallel` call named in step 2 — not a second, separate dispatch. Transcript: `<feature-folder>/transcripts/<dispatch_id>.stdout` (stdout) and `<dispatch_id>.stderr` (stderr). Model and effort are resolved per-role from the Models table, which is what puts preflight in `micro` mode per the "Codex reviewer modes" table.
4. Read only the two STATUS files, located via `role_attempt_dir preflight-<vendor> "$(_latest_attempt_id p01-i00-preflight-<vendor>)")/STATUS.md` for each vendor (the same attempt-lookup idiom every other phase's runner/writer STATUS already uses — see e.g. the all-tests-runner's own real-STATUS lookup). Validate each with `validate_status` (see cookbook). Each STATUS carries `required_skills_present`, `required_skills_missing`, `optional_skills_present`, and `optional_skills_absent` (spec §16.3/§16.4) — bracket-list values, same shape as the pre-existing `x_missing_skills`/`x_loaded_skills` fields — plus `x_plugin_roots_checked` naming every plugin root/path the probe inspected for an absent requirement. This is the durable capability evidence; downstream phases read the readable-alias copy Step 1.2 makes of it (below) rather than re-probing or re-resolving an attempt id themselves.
4a. Read the `context7` field from the claude preflight's STATUS (the same file just read in step 4). If it is `unreachable`, append one `event=CONTEXT7_UNAVAILABLE` entry to `RUN_LOG.md` (phase 1). Do NOT halt — this only affects `context7_policy()` (see cookbook) for the rest of the run. If it is `reachable`, no RUN_LOG entry is needed; `context7_policy()` reads the STATUS field directly.
5. **Missing-skill re-probe (spec §16.3).** If either STATUS reports
   `verdict=MISSING_SKILLS`, or the codex STATUS reports `verdict=UNCERTAIN`
   (P12 — codex-only; `preflight-claude` never publishes this verdict), do NOT
   immediately HALT. Call `skills_reprobe_
   needed` (see cookbook) with: (a) `yes` iff an earlier phase in THIS run
   already recorded `READY` for that vendor (scan `RUN_LOG.md` — a per-phase
   missing claim contradicting a prior READY is the known false-negative
   pattern observed with `preflight-codex`); (b) `yes` iff a deterministic
   filesystem check shows the named skill directory/`SKILL.md` actually
   exists under one of the checked plugin roots; (c) `yes` iff the STATUS
   file itself, or its sibling `.tmp.*`, shows the attempt reached publication
   but lost its final STATUS. An `UNCERTAIN` verdict additionally ALWAYS
   triggers the re-probe regardless of those three conditions — the probe's
   own scan was incomplete by definition, so it is never treated as evidence
   of absence. On `true` (or on any `UNCERTAIN`), re-dispatch that ONE vendor's
   preflight role once more (same `dispatch_parallel` mechanism, a fresh
   attempt) and use the re-probe's verdict in place of the first. A second
   consecutive `MISSING_SKILLS` (from the re-probe, or when re-probe was not
   indicated) is accepted as real; a second consecutive `UNCERTAIN` is
   accepted as "still can't tell" and handled identically to a confirmed
   `MISSING_SKILLS` from here on — it is NEVER promoted to a `MISSING` claim.
   Either way: print to the user which CLI's skills could not be confirmed
   (from `required_skills_missing` plus `x_plugin_roots_checked` for
   `MISSING_SKILLS`, or the STATUS `reason:` plus `x_plugin_roots_checked` for
   a persistent `UNCERTAIN`), plus an install hint ("Install the Superpowers
   plugin (e.g. `claude plugin install superpowers`) and re-run this prompt
   against the same feature folder"). HALT.
6. If the `codex` check fails, apply the "Distinguish orchestration bugs from vendor failures" filter from Failure handling first. If the captured stderr indicates a local CLI usage error (`unexpected argument`, `Usage:`, `unknown option`), this is an orchestration bug, not a Codex outage — correct the invocation per the cookbook's "CLI invocation forms" and retry once. Otherwise branch on the failure mode:
   - **Mode 0 (binary missing — environmental):** HALT unconditionally. Surface the remediation message ("Install the Codex CLI and re-run") and STOP. Do NOT prompt the user. A missing binary is an environment defect that must be fixed before the run can proceed in any mode; silently degrading would mask a broken setup.
   - **Modes 1, 2, 3, 4 (after the one allowed Mode-4 retry), or 5:** prompt the user interactively: `Codex is unavailable (mode=<N>, stderr=<tail>). Continue in claude-only mode for this run? [y/N]`. A non-interactive run may pre-answer this prompt by setting `CODEX_CONSENT=y|n`. When `CODEX_CONSENT` is unset and stdin is not a TTY, HALT rather than reading EOF as "no" — a silent EOF-as-no would let an unattended run degrade without anyone actually consenting.
     - On `y` (interactive or `CODEX_CONSENT=y`): set the run-scoped flag `codex_disabled_by_user = true` (see "Run-scoped user opt-out: `codex_disabled_by_user`" below), set `codex_available = false`, append one `event=CODEX_DISABLED_BY_USER_CONSENT` entry to `RUN_LOG.md` (see the RUN_LOG additions under "Resumability", core document), and PROCEED to Step 1.2 (readable-alias copy, defined below) with Claude-only mode for the rest of the run. Step 1.2's conditional `[ -f … ]` guard handles the absent-codex STATUS case. After Step 1.2 completes, proceed to Phase 2.
     - On `N`, `CODEX_CONSENT=n`, or any non-`y` response: HALT and surface the same remediation as Mode 0.
     - On EOF with `CODEX_CONSENT` unset and stdin not a TTY: HALT and surface the same remediation as Mode 0 — do not treat the EOF itself as an answer.
7. If the `claude` check fails, HALT. Claude is required for every phase — there is no claude-less degraded mode and no user prompt.
8. If both report `READY`, call `vendor_proven_mark claude preflight-claude` and, if codex ran and is `READY`, `vendor_proven_mark codex preflight-codex` — this preflight probe is `micro`/cheap by design, so `vendor_proven_mark` here is a starting floor (spec §16.3 evidence), not the primary source of proof; the first SUBSTANTIVE per-phase dispatch that completes (reviewer, plan-writer, implementer, ...) re-marks it regardless. Run Step 1.2 (the readable-alias copy, defined immediately below) — its ordering relative to this call does not matter, since Step 1.2 only COPIES an already-durable attempt-scoped STATUS and never consumes or moves it. `dispatch_parallel`'s own `_dispatch_ingest_result` already appended each subprocess's RUN_LOG dispatch entry, carrying its REAL attempt-scoped `status_path` — Step 1.2 never appends a second, competing entry for the same dispatch. After Step 1.2 completes, proceed to Phase 2.

### Step 1.2 — Copy Phase 1 STATUS artifacts to their readable alias

Every dispatched role in this process, preflight included, publishes its
STATUS to exactly one place: the attempt-scoped path `dispatch_attempt`
computed (spec-v2's sole write target — see the canonical write list in the core document's orchestration contract).
There is no "canonical slot" filename any appendix writes directly, and
nothing here ever `mv`s a STATUS file: an attempt directory is durable
evidence in its own right (resume classification, `audit_run_state`, and a
future reconciliation all expect it to remain exactly as `dispatch_attempt`
left it). Step 1.2 exists for exactly one reason: a subprocess with no
cookbook access (notably `readiness-writer`, whose own appendix is handed a
literal path, not a shell it can run `_latest_attempt_id` in) needs a FIXED
name that does not depend on which attempt number a missing-skill re-probe
happened to land on. Step 1.2 makes ONE read-only-source COPY of the
already-published, already-validated attempt-scoped STATUS to that fixed
alias — it is never the canonical record, only a convenience for a reader
that cannot resolve an attempt id itself.

Step 1.2 runs on **every** Phase 1 completion path that proceeds onward to Phase 2:
- the dual-READY success path (step 8 above), AND
- the Mode 1–5 user-consent path (step 6 `y` branch — `codex_disabled_by_user = true`, claude `READY`).

It does NOT run on the HALT paths (Mode 0 codex failure, claude failure, `N`/EOF consent response) — those terminate the run before Phase 2.

At any point after step 8 completes (or after the consented-degradation branch in step 6 completes) and BEFORE Phase 2 begins or any per-phase preflight gate can run — ordering relative to step 8's `vendor_proven_mark` calls does not matter, since this copy neither consumes nor competes with anything — copy Phase 1's STATUS files to their alias:

<!-- lint: snippet -->
```bash
mkdir -p "$FEATURE_FOLDER/1-preflight/phase-1"
copy_preflight_alias 1 "$FEATURE_FOLDER/1-preflight/phase-1"
```

(`copy_preflight_alias`, cookbook — P21/Task 11 factored this five-times-repeated copy loop into the one function every per-phase preflight gate (Steps 3.0/5.0/6.−1/7.0, in their own packs) calls; see its own doc comment in runtime/cookbook.sh for the `continue`-not-HALT and `if`-not-`&&` rationale.)

The conditional guards above handle the consented-degradation case (codex STATUS file may not exist when `codex_disabled_by_user=true` was set above, or when codex Mode 0/1/2/3/5 killed the subprocess before any STATUS write — see "File policy for non-READY paths", `phases/3-spec-review.md`). No synthetic STATUS file is fabricated for absent codex outputs; the absence plus the corresponding `CODEX_DISABLED_BY_USER_CONSENT` or `CODEX_UNAVAILABLE` event in RUN_LOG is the canonical Phase 1 codex verdict.

Downstream consumers of Phase 1 verdicts (notably the readiness writer) read this alias from `1-preflight/phase-1/`. The real, canonical attempt-scoped STATUS this alias was copied from remains exactly where `dispatch_attempt` wrote it, untouched, for the life of the run.

### Run-scoped user opt-out: `codex_disabled_by_user`

If the user consented to a claude-only run at the Phase 1 prompt above, the orchestrator sets a run-scoped flag `codex_disabled_by_user = true`. This flag:

- Persists for the entire run, including across resumes. RUN_LOG is the canonical storage; there is no separate state file.
- Suppresses per-phase codex re-probes at Phases 3, 5, 7 (each per-phase preflight emits `CODEX_SKIPPED_BY_USER_CONSENT` instead of running the probe — see the per-phase preflight Step 0 in each gate's own pack). Phase 6 never dispatches `preflight-codex` at all (P09), regardless of this flag — see Step 6.−1.
- Forces `codex_available = false` at every gate.
- Is recorded in the RUN_LOG at the time of consent (`event=CODEX_DISABLED_BY_USER_CONSENT`) and re-asserted at each per-phase preflight entry (`event=CODEX_SKIPPED_BY_USER_CONSENT`).

**Resume reconstitution.** On resume, reconstitute the flag by scanning the current run's `RUN_LOG.md` (top-to-bottom) for entries whose first-line tag is exactly `event=CODEX_DISABLED_BY_USER_CONSENT`. The flag is `true` if at least one such entry exists and no later entry carries the tag `event=CODEX_RE_ENABLED_BY_USER` (re-enabling is out of scope; the tag is reserved). Match on the full first-line tag, NOT on `phase` / `phase_name`, since the event is unique per run. Resume does NOT re-prompt the user — the original consent stands. Clearing the flag mid-run is out of scope; the only way to clear it is to start a fresh `develop-it` run.

### Preflight cache

Phase 1 always runs in full on a fresh invocation. There is no cross-run preflight cache. Per-phase preflight (Phases 3, 5, 6, 7) handles per-gate re-probing — see the per-phase Step 0 in each gate's own pack. Within a single gate's iteration loop, the preflight verdict is reused for all iterations of that gate; it is NOT re-probed between iterations.

## Role appendices dispatched by this phase

Rendered on demand by `render_prompt` (runtime/cookbook.sh); shared `SHARED-BEGIN` blocks referenced via `INCLUDE-BEGIN` spans live in the core document (`develop-it-prompt.md`, "Appendices — subagent prompts") and are spliced in at render time. Appendix content is never written to disk except as an attempt's own immutable `prompt.txt`.

<!-- BEGIN: preflight-claude -->
# Role: preflight-claude

You are a one-shot preflight checker invoked by the develop-it orchestrator. You have no shared context. Your full instructions are below.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `none`
- Outputs: `check_status`
- Allowed verdicts: `READY;MISSING_SKILLS`
- Required status fields: `common_v2;context7;required_skills_present;required_skills_missing;optional_skills_present;optional_skills_absent`
- Checkpoint kind: `none`
- Phases: `1;3;5;6;7`

## Inputs (substituted by orchestrator)

- `$FEATURE_FOLDER` — absolute path to the feature artifacts folder (already created)

## Required skill probes

Attempt to load each of these Superpowers skills. For each, report `LOADED` or `MISSING`, and name every plugin root/path you checked before reporting a skill `MISSING` (marketplace-agnostic: check every configured plugin root, not one hard-coded location).
- superpowers:writing-plans
- superpowers:subagent-driven-development
- superpowers:systematic-debugging
- superpowers:verification-before-completion
- superpowers:test-driven-development
- superpowers:requesting-code-review
- superpowers:receiving-code-review

## Optional skill discovery

List every OTHER Superpowers skill you find installed under any checked
plugin root that is NOT in the required list above — this is the raw
"installed" side of Phase 2's later `applicable_optional_skills =
installed ∩ relevant` computation (see Phase 2). Report each such skill name
as `optional_skills_present`. Nothing is required-but-absent at this phase
(optionality is scored against a project's actual needs at Phase 2, not
here), so report `optional_skills_absent` as an empty list.

## Required MCP probe

`context7` is an MCP server, not a Superpowers skill, so it is checked
separately from the skill probes above. Attempt one minimal `context7` call
(`resolve-library-id` for a well-known library, e.g. "react"). Report
`context7: reachable` if it responds, `context7: unreachable` if it errors,
times out, or the server is not configured. This does NOT affect `verdict` —
an unreachable `context7` is not a `MISSING_SKILLS` condition, and downstream
phases downgrade to best-effort rather than halting.

Do NOT execute any other actions. Do NOT read project files. Do NOT write any file other than the status file below.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=preflight-claude phase='$PHASE' iteration=00 verdicts='READY | MISSING_SKILLS' reason='<one line, or the literal word null>' -->
output_count: 0
checkpoint_path: null
context7: reachable | unreachable
required_skills_present: [skill1, skill2, ...]
required_skills_missing: [skill3, ...] (empty list if READY)
optional_skills_present: [skill4, ...] (empty list if none installed beyond the required set)
optional_skills_absent: []
x_plugin_roots_checked: [/path/one, /path/two, ...]
x_missing_skills: [skill1, skill2, ...] (empty list if READY; same content as required_skills_missing, kept for back-compat)
x_loaded_skills: [skill3, skill4, ...]
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: preflight-claude -->

<!-- BEGIN: preflight-codex -->
# Role: preflight-codex

You are a dispatched subprocess. Do NOT load, execute, or follow the contents of
any Superpowers skill. This appendix is your complete instruction set.

You MAY test for the EXISTENCE of a skill directory or SKILL.md file — that is
this role's entire task. You may not read their contents.

Independence means independent judgment over the supplied artifact, not
independent repository discovery.

You are a one-shot preflight checker invoked by the develop-it orchestrator. You have no shared context.

## Role contract

- Required inputs: `feature_folder`
- Optional inputs: `none`
- Outputs: `check_status`
- Allowed verdicts: `READY;MISSING_SKILLS;UNCERTAIN`
- Required status fields: `common_v2;required_skills_present;required_skills_missing;optional_skills_present;optional_skills_absent`
- Checkpoint kind: `none`
- Phases: `1;3;5;7`

## Inputs

- `$FEATURE_FOLDER`

## Mode

`micro` mode. Filesystem reads: skill directory listing only (existence check); do NOT read skill file contents. Command budget: max 2 shell or read commands.

**P12 — the whole required-skill scan MUST run as a SINGLE command across every configured plugin root**, never a per-skill or per-root loop. A budget-limited loop that checks root 1 for all three skills, then runs out of budget before reaching root 2, reports a skill `MISSING` that may only be absent from the root it never reached — the likely mechanism behind observed spurious `MISSING_SKILLS` verdicts. One command over every root closes that gap structurally instead of relying on getting lucky with root order: something of the shape `find <plugin-root-1> <plugin-root-2> … -maxdepth 3 -iname 'SKILL.md' | grep -E 'writing-plans|subagent-driven-development|verification-before-completion'`, run once against every root named in this run's plugin configuration, not once per root.

This single command counts as (at most) one of the two budgeted shell/read commands; the other is reserved for the optional-skill discovery listing below. Never split the three required-skill checks across separate commands, even if the budget would technically allow it.

## Required skill probes

- `superpowers:writing-plans`
- `superpowers:subagent-driven-development`
- `superpowers:verification-before-completion`

For each, report `LOADED` if the single-command scan above found its directory or `SKILL.md` file under any configured plugin root, or `MISSING` if the scan covered every configured root and found none. Do NOT read the contents of `SKILL.md`. Do NOT load the skill. A path existence check is sufficient. Name every plugin root/path checked before reporting `MISSING` — this is the evidence a re-probe request (see Phase -1 Step 1.1 step 5) uses to tell a genuine absence from a stale listing.

**`UNCERTAIN` verdict (P12).** Report `verdict: UNCERTAIN` instead of `MISSING_SKILLS` — for the WHOLE probe, never per-skill — whenever the single-command scan did not actually cover every configured plugin root: the command budget was exhausted before it could run, the command itself failed or errored, or the configured-root list was empty/unresolvable. `MISSING` is reserved for a skill genuinely absent from a scan that covered every configured root; a partial scan can only ever produce `UNCERTAIN`, never `MISSING`, for the skills it didn't finish checking. Still name every root actually covered (or attempted) in `x_plugin_roots_checked`, and put the reason the scan was partial in `reason:` (e.g. `partial scan: command budget exhausted before root 2 of 3`). The orchestrator treats `UNCERTAIN` as an automatic re-probe trigger, never as evidence of absence (see Phase -1 Step 1.1 step 5 and each per-phase preflight gate's own branch).

## Optional skill discovery

List every OTHER installed Superpowers skill directory found under a
checked plugin root, beyond the required list above, as `optional_skills_
present` (existence check only — same `micro`-mode restriction). Report
`optional_skills_absent` as an empty list (see the parallel note in
`preflight-claude`'s appendix — optionality is scored at Phase 2, not here).

Do NOT execute any other actions. Do NOT read project files. Do NOT run broad `find` or `rg` over the repo. Do NOT write any file other than the status file below.

## Publish STATUS

<!-- INCLUDE-BEGIN: publish-status-protocol role=preflight-codex phase='$PHASE' iteration=00 verdicts='READY | MISSING_SKILLS | UNCERTAIN' reason='<one line, or the literal word null -- required for MISSING_SKILLS and UNCERTAIN: for UNCERTAIN, state which root(s) the single-command scan did not cover and why (budget exhausted / command failed / root list empty)>' -->
output_count: 0
checkpoint_path: null
required_skills_present: [skill1, skill2, ...]
required_skills_missing: [skill3, ...] (empty list if READY or UNCERTAIN -- UNCERTAIN means the scan could not confirm absence, never that a skill was found missing)
optional_skills_present: [skill4, ...] (empty list if none installed beyond the required set)
optional_skills_absent: []
x_plugin_roots_checked: [/path/one, /path/two, ...] (for UNCERTAIN: every root actually covered before the scan stopped, so the re-probe evidence check can tell what was and wasn't verified)
x_missing_skills: [skill1, skill2, ...] (empty list if READY or UNCERTAIN; same content as required_skills_missing, kept for back-compat)
x_loaded_skills: [skill3, skill4, ...]
<!-- INCLUDE-END -->

Exit 0 only after the publisher exits 0.
<!-- END: preflight-codex -->
