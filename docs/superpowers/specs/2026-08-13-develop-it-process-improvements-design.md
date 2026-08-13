# Develop-It process reliability and convergence design

- Date: 2026-08-13
- Status: Draft for user review
- Target: [`develop-it-prompt.md`](../../../develop-it-prompt.md)
- Source backlog: [`2026-08-13-propositions.md`](../../../2026-08-13-propositions.md)

## 1. Purpose

This specification defines one integrated update to the Develop-It orchestration process. It incorporates all 24 recommendations R01–R24 from the consolidated backlog into a coherent set of contracts for future runs.

The update has four goals:

1. A dispatch cannot execute in the wrong repository, disappear without an attributable outcome, reuse stale STATUS, or report success from exit code alone.
2. Interrupted long-running work is recoverable from durable checkpoints without duplicating completed work or silently accepting uncheckpointed mutations.
3. Review loops converge toward a smaller, verified result; every final mutation is reviewed, every accepted exception is explicit, and artifact growth or fix-induced regressions can stop the loop.
4. The process remains auditable: role contracts, events, decisions, follow-ups, coverage degradation, and final readiness can be reconstructed from durable state.

The implementation is one process revision delivered task by task in one development iteration. It is not a multi-release migration.

## 2. Scope

### 2.1 In scope

- Rewrite the relevant sections of `develop-it-prompt.md` around one shared contract model.
- Update deterministic tests and fixtures in this repository where the new prompt contract requires them.
- Define the artifacts produced by future runs, including attempt-scoped STATUS files, checkpoints, event identifiers, documentation/handoff outputs, and readiness evidence.
- Add the documentation/handoff phase and renumber the later phases.
- Preserve the prompt as the normative source for orchestration behavior and extracted runtime code.

### 2.2 Out of scope

- Modifying, moving, backfilling, or normalizing any existing artifact folder under the Prism repository.
- Rewriting any of the six original proposition files.
- Resuming an old artifact folder under the new schema.
- Adding a database, service, daemon, package dependency, or separately maintained orchestration framework.
- Changing product repositories merely to adopt this process revision.
- Automatically pushing, opening pull requests, merging, deploying to production, rotating broad credentials, or rewriting shared history.

### 2.3 Existing artifacts are immutable

The six source artifact folders are evidence only. The implementation MUST NOT edit them.

The new prompt SHALL declare `process_schema_version: 2`. Every newly created `RUN_LOG.md` SHALL record that version and the existing process-file identity fields. When the prompt is pointed at an existing feature folder whose RUN_LOG is absent, malformed, or carries another schema version, it MUST HALT without writing to that folder and instruct the operator to resume with the process version recorded by that run. No converter is provided.

This version gate protects old evidence; it is not a migration mechanism.

## 3. Design principles and invariants

The following rules are normative and apply across every phase and appendix:

1. **One normative prompt.** Human-readable policy, the machine-readable role registry, and fenced runtime sources live in `develop-it-prompt.md`. Generated files are derived and hash-verified; they are never a second maintained source.
2. **One contract per role.** Vendor, model, effort, timeout, mutability, inputs, outputs, verdicts, STATUS fields, checkpoint policy, and child-process policy come from the role registry.
3. **One lifecycle per attempt.** Sequential and parallel dispatches use the same per-child engine and the same event/state semantics.
4. **Attempt-scoped evidence.** A retry or continuation never overwrites another attempt's transcript, STATUS, snapshot, or timing.
5. **STATUS proves completion.** A process exit, transcript claim, checkpoint, commit, or artifact size cannot substitute for a fresh, valid STATUS whose `dispatch_id` matches the current attempt.
6. **Checkpoints prove progress only.** They authorize safe continuation but never satisfy a phase gate.
7. **Observed state beats narrated intent.** The process logs a launch before telling the operator it is running and derives completion from durable evidence.
8. **No unreviewed mutation closes a review gate.** Every fixer pass has a review-back edge. A cap may halt or accept documented risk, but cannot apply a last fix and silently advance.
9. **Explicit authority.** A prescribed retry, owner decision, accepted risk, phase acceptance, correction, or post-HALT resume is represented by a typed event.
10. **Exclusive mutation.** Only one role owns the target repository or mutable artifact set at a time, under a durable write lease and pre-attempt snapshot.
11. **Artifact custody.** A phase's artifact directory contains or references all durable work needed to understand and continue that phase.
12. **Free gates first.** No paid model call occurs before every deterministic zero-token gate passes.
13. **Historical sources remain read-only.** The process may cite source propositions, but this revision never rewrites prior runs.

## 4. Conceptual architecture

The single prompt remains one document but is organized into four layers.

### 4.1 Contract layer

The contract layer defines:

- the process schema and policy constants;
- the role registry;
- input, output, STATUS, checkpoint, and finding schemas;
- event and decision vocabularies;
- artifact path templates;
- phase transition predicates.

No phase appendix may redefine these contracts locally.

### 4.2 Execution layer

The execution layer supplies pure/tested helpers for:

- process identity and runtime extraction;
- role lookup and input validation;
- attempt allocation and path rendering;
- Claude/Codex invocation;
- STATUS publication and validation;
- timing, transcript, and usage capture;
- failure classification and bounded recovery;
- write leases, snapshots, and integrity checks;
- RUN_LOG/event emission and reconciliation.

### 4.3 Phase layer

The phase layer sequences preflight, context discovery, review/fix loops, plan writing, implementation, code review, tests, documentation/handoff, git finalization, and readiness. A phase supplies role inputs and consumes typed results; it does not implement its own dispatch protocol.

### 4.4 Assurance layer

The assurance layer provides structural artifact validation, review convergence analysis, gate-discharge checks, final-fix re-review, proposition reconciliation, readiness classification, and offline tests.

## 5. Process policy constants

The prompt SHALL contain one machine-readable policy table. Runtime helpers and prose MUST reference names from this table rather than repeat numeric values.

| Constant | Initial value | Meaning |
|---|---:|---|
| `process_schema_version` | 2 | Schema for new RUN_LOG, STATUS, checkpoint, and event records |
| `prelaunch_correction_cap` | 1 | Automatic correction after an input/render/prelaunch defect |
| `publication_retry_cap` | 1 | Cheap retry after proven STATUS publication loss |
| `transient_retry_cap` | 1 | Fresh re-dispatch when a transient attempt produced no mutation |
| `continuation_cap` | 3 | Continuations after durable partial progress for one logical role invocation |
| `review_iteration_cap` | 10 | Existing hard cap for a review gate |
| `document_fixer_batch_size` | 8 | Maximum assigned findings in one document-fixer batch |
| `documentation_fix_cap` | 2 | Maximum documentation self-correction rounds |
| `artifact_growth_warning_pct` | 10 | Per-fix-pass net growth that contributes to divergence detection |
| `divergent_round_cap` | 2 | Consecutive divergent rounds before automatic fixing stops |
| `long_role_headroom_threshold_minutes` | 60 | Roles at or above this registry timeout receive a just-in-time vendor check |

Changing a constant requires changing the table and its contract tests. Literal copies elsewhere in the prompt are forbidden, except examples explicitly labeled non-normative.

## 6. Role contract registry

### 6.1 Registry is the source of truth

Replace the existing model-only lookup split with one parseable role-contract table. It MUST contain one row for every top-level dispatched role, including new roles introduced by this design.

Each row SHALL define:

| Field | Requirement |
|---|---|
| `role` | Stable role slug |
| `vendor` | `claude` or `codex` |
| `model` | Pinned model ID |
| `effort` | Pinned effort or explicit empty value |
| `timeout_minutes` | Only normative role timeout |
| `mutates` | `yes` or `no`; unknown roles default to rejection, not mutation guessing |
| `long_running` | Derived from timeout/child behavior and materialized for tests |
| `may_spawn_children` | `yes` or `no` |
| `required_inputs` | Semicolon-delimited render keys |
| `optional_inputs` | Semicolon-delimited `KEY=default` entries |
| `status_template` | Attempt-scoped path template |
| `outputs` | Required/optional role-owned outputs |
| `verdicts` | Complete legal verdict enum |
| `required_status_fields` | Common fields plus role-specific fields |
| `checkpoint_kind` | `none`, `review`, `document`, or `implementation` |
| `phases` | Legal phase numbers |

The current top-level roles remain, and the registry adds exactly two top-level roles:

- `implementation-fixer`, replacing reuse of the full implementer in Phase 7;
- `documentation-writer` for the new documentation/handoff phase.

The documentation phase uses deterministic structural validation and writer self-correction; no separate documentation-review model is added in this revision.

### 6.2 Registry-derived helpers

All role behavior SHALL be obtained through registry-backed helpers:

- `role_vendor`
- `role_model`
- `role_effort`
- `role_timeout`
- `role_mutates`
- `role_may_spawn_children`
- `role_required_inputs`
- `role_optional_defaults`
- `role_status_path`
- `role_outputs`
- `role_verdicts`
- `role_required_status_fields`
- `role_checkpoint_kind`
- `role_phases`

An unknown role, duplicate role, missing field, unsupported phase, or inconsistent contract MUST fail validation before an attempt is logged as launched.

`render_prompt --check <role>` SHALL report missing required inputs, populated optional defaults, resolved output/STATUS paths, and unresolved appendix variables without invoking a vendor.

### 6.3 Durable input reconstruction

Every phase starts in a new shell. `init_orchestration_vars` MUST reconstruct durable inputs from validated upstream STATUS/events rather than assume shell variables survived.

At minimum it reconstructs:

- the approved spec path and revision;
- `PLAN_PATH` and plan revision;
- implementation baseline and final SHA;
- applicable optional skills;
- active findings paths;
- debugger/reverification inputs;
- continuation/checkpoint paths;
- declared foreign commits/changes;
- context7 policy;
- vendor availability/proven state.

If reconstruction fails, the error names the absent upstream contract and becomes `PRELAUNCH_FAILED`; it cannot masquerade as a dirty-tree or vendor error.

## 7. Runtime extraction and shell ownership

### 7.1 Generated runtime

The fenced `lint: cookbook` sources in the prompt remain normative. Phase -1 SHALL extract them and the parsed role/policy registries into a run-local runtime directory under the new run's feature folder:

```text
$FEATURE_FOLDER/.orchestration/runtime/
  develop-it-runtime.sh
  role-contracts.tsv
  policy.tsv
  publish-status
  manifest.sha256
```

The runtime directory is process-owned, not a product artifact. Each phase:

1. derives the runtime path;
2. checks `manifest.sha256` against the current process-file SHA and extracted content;
3. re-extracts atomically if the runtime is absent before any run work exists;
4. HALTs on a hash mismatch after work has started rather than source altered code;
5. sources only `develop-it-runtime.sh`, whose top level contains definitions and validated registry loading but no phase action.

Existing feature folders are never given this directory because the schema-version gate runs before folder mutation.

### 7.2 Shell rules

The runtime and phase snippets MUST preserve the current guardrails and add these enforced rules:

- split a `local` declaration from any assignment that references the new local;
- never use a conditional `&&` expression as the final publication statement;
- never rely on a pipeline or command substitution to preserve global result variables;
- never use `set -e`; use explicit return-code handling under `set -uo pipefail`;
- never hand-copy runtime helper definitions into phase blocks;
- every helper called by a phase is loaded from the verified runtime;
- only the dispatch engine writes lifecycle RUN_LOG blocks.

## 8. Attempt identity and artifact paths

### 8.1 Attempt identity

Every invocation, including a prelaunch failure, receives a unique attempt identity before render validation:

```text
logical_dispatch_id = p<phase-token>-i<iteration>-<role>
dispatch_id         = <logical_dispatch_id>-a<attempt>
```

Rules:

- Phase `-1` uses phase token `m1`; other phases use two digits.
- Non-iterative phases use iteration `00`; test rounds use their round as iteration.
- Attempt is a two-digit, monotonically increasing value derived from all prior RUN_LOG records for the logical dispatch.
- Review-fixer batches additionally carry `batch_id`, but `batch_id` never replaces `attempt`.
- A prelaunch failure consumes its attempt number and records `launched: false`; the following correction uses the next number.
- Attempt allocation is serialized by the RUN_LOG writer and cannot use clock time or PID.

Example: `p05-i02-plan-fixer-a03`.

### 8.2 Attempt-scoped paths

The registry renders a unique STATUS path for every attempt. A representative layout is:

```text
$PHASE_DIR/<iteration-or-round>/attempts/<dispatch_id>/
  STATUS.md
  progress.jsonl
  artifact-complete.json
```

Transcripts use:

```text
$FEATURE_FOLDER/transcripts/<dispatch_id>.stdout
$FEATURE_FOLDER/transcripts/<dispatch_id>.stderr
```

Snapshots use:

```text
$FEATURE_FOLDER/.orchestration/snapshots/<dispatch_id>/
```

No later attempt moves, deletes, or overwrites these paths. Downstream phases obtain the accepted STATUS/output paths from a `PHASE_ACCEPTED` event, not from a mutable `latest` file. This new-run-only design needs no compatibility alias.

## 9. STATUS contract and publication

### 9.1 Common STATUS v2 fields

Every STATUS is a flat, line-oriented UTF-8 document with exactly one `key: value` record per scalar field. Common required fields are:

```text
schema_version: 2
dispatch_id: <current dispatch_id>
logical_dispatch_id: <logical id>
role: <registry role>
phase: <phase number>
iteration: <two-digit iteration or round>
attempt: <two-digit attempt>
verdict: <registry legal verdict>
reason: <text or null>
published_at: <UTC ISO-8601>
artifact_revision: <sha256/git-sha/null>
output_count: <non-negative integer>
output_01: <absolute path; repeated through output_NN when count > 0>
checkpoint_path: <absolute path or null>
```

The registry appends role-specific required fields. `output_01` through `output_NN` are required exactly when `output_count` is non-zero; no delimiter-based path list is used. Unknown fields are allowed only when namespaced as `x_<name>`; missing common/role fields, duplicate keys, a wrong dispatch identity, an illegal verdict, a non-absolute output path, or a path outside the allowed roots makes STATUS malformed.

### 9.2 Canonical publisher

Appendices MUST NOT invent their own atomic-write shell. Every role receives `STATUS_PUBLISHER_PATH` and calls the generated `publish-status` utility once with the final content on stdin.

The publisher SHALL:

1. reject an existing final path for the current attempt;
2. write a sibling attempt-unique temporary path under a restrictive umask;
3. validate common fields and the role registry contract;
4. flush and `fsync` the temporary file, then close it;
5. rename it to the final STATUS path as an unconditional separate operation;
6. `fsync` the containing directory, then re-read and revalidate the final path;
7. exit non-zero unless the final path is valid and non-empty.

The role may report success to the vendor response only after the publisher exits zero. This one-command interface removes the artificial conflict with Codex micro/scoped command budgets.

### 9.3 Publication loss

If the process exits without final STATUS but an attempt-specific temporary file exists, classification is `PUBLICATION_LOST`. The orchestrator:

- never reads it as a verdict;
- never promotes it;
- preserves it in the attempt directory as diagnostics;
- may authorize one cheap retry for a non-mutating role under `publication_retry_cap`;
- treats a second publication loss as terminal for that logical dispatch.

## 10. Checkpoint contracts

### 10.1 Common checkpoint format

Durable progress is append-only JSONL at the attempt's `progress.jsonl`. Each record contains:

```json
{
  "schema_version": 2,
  "dispatch_id": "p06-i00-implementer-a02",
  "sequence": 7,
  "role": "implementer",
  "unit_type": "task",
  "unit_id": "task-07",
  "state": "completed",
  "artifact_path": "/absolute/path",
  "artifact_sha256": "<sha256>",
  "commit_sha": "<git-sha>",
  "finding_ids": [],
  "verification": "PASS",
  "next_unit": "task-08",
  "timestamp": "UTC-ISO-8601"
}
```

Records are sequence-monotonic and validated before append. A malformed or discontinuous checkpoint is evidence of partial state but cannot authorize automatic continuation until an integrity check resolves it.

### 10.2 Role-specific checkpoint rules

- **Implementer:** append after every committed task and its review. Record task/report/diff paths, commit SHA, verification, next task, and SDD working directory.
- **Plan writer:** append after every completed top-level section. When all required sections pass structural validation, atomically publish `artifact-complete.json` before optional summary prose and terminal STATUS.
- **Spec/plan fixers:** receive at most `document_fixer_batch_size` finding IDs and append after every disposition. Record the next unresolved ID and post-edit artifact hash.
- **Long reviewers:** may append partial finding records after coherent sections. A partial record is not a verdict; complete coverage plus terminal STATUS is required.
- **Implementation fixer:** append after every finding-specific commit and verification.

### 10.3 SDD custody

The implementer SHALL configure the SDD skill root as:

```text
$FEATURE_FOLDER/6-implementation/sdd/
```

If the installed skill cannot accept a root, the implementer mirrors each completed task's brief, report, progress update, and review diff immediately after that task. Mirroring only at terminal STATUS is forbidden. STATUS records both the original and durable SDD paths.

### 10.4 Continuation input

A continuation receives:

- prior dispatch ID and classification;
- validated checkpoint path and last sequence;
- completed unit IDs and commits;
- current HEAD/tree state;
- dirty partial unit, if any;
- snapshot/lease paths;
- declared foreign changes;
- remaining work and continuation budget.

The role verifies this input before mutation, reconciles one dirty partial unit, never repeats a completed unit, and emits new checkpoints under the new dispatch ID.

## 11. Write leases, snapshots, and integrity

### 11.1 Exclusive lease

Before a mutating attempt launches, the dispatch engine atomically creates:

```text
$FEATURE_FOLDER/.orchestration/write-lease.json
```

The lease contains schema version, dispatch ID, role, phase, acquired time, baseline HEAD, declared write paths, declared foreign paths/commits, and snapshot manifest path.

Only one lease may exist. A second mutating attempt is `PRELAUNCH_FAILED`; read-only roles may run concurrently only when their inputs are immutable revisions.

While a lease exists:

- the orchestrator MUST NOT edit or commit in the target repository;
- no other mutating role may launch;
- the owning role checks input hashes before each commit/publication boundary;
- unexpected changes yield `ARTIFACT_INTEGRITY_BLOCKED` with exact paths and hashes;
- other-writer work is preserved, never reverted or overwritten.

### 11.2 Snapshot

Before launch, the engine records:

- HEAD and porcelain-v1-z tree state;
- hashes/blob IDs for declared mutable artifacts;
- copies of mutable non-git artifacts needed to restore only this attempt;
- process identity and active allow-list;
- known foreign changes.

Snapshots are diagnostics and scoped rollback inputs. The orchestrator never performs an automatic rollback. A fixer may restore only files owned by its failed attempt after an explicit `RECOVERY_AUTHORIZED` event and integrity validation.

### 11.3 Lease release

The engine releases the lease only after it logs the classified attempt outcome and final tree/artifact state. An interrupted run leaves the lease durable. Resume logic distinguishes:

- live/active owner;
- observed failed owner;
- orphaned unobserved owner;
- completed owner whose release record was lost.

Ambiguous lease ownership HALTs for integrity reconciliation; it never launches a second writer.

## 12. Vendor invocation and transport contract

### 12.1 Claude working directory

`claude_invoke` MUST validate `REPO_ROOT` and execute Claude from exactly that directory:

```bash
(
  cd "$REPO_ROOT" || exit 1
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    timeout --kill-after="$grace" "$deadline" \
    claude ...
)
```

The real implementation derives deadline/grace from the registry and policy; the snippet is illustrative. `--add-dir` remains for additional permitted paths and is not treated as CWD.

Every dispatch completion record carries `effective_cwd`. A fake-CLI contract test asserts it equals `REPO_ROOT`. A stdout `.result` refusal about an out-of-repository task is classified as `ORCHESTRATION_REFUSAL`, not vendor outage.

### 12.2 Claude print-mode rules

Every Claude appendix receives a common transport preamble:

- the role runs under non-interactive `claude -p`;
- long commands stay in the foreground;
- child agents and background processes must be awaited synchronously;
- the role must not yield/end its turn while a child is pending;
- all children are reaped before STATUS publication;
- the only supported deadline change occurs before dispatch through the registry;
- STOP/CONT/TERM MUST NOT be sent to the live timeout wrapper to extend a deadline.

`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` applies to every Claude subprocess after an offline fake-CLI test proves the environment reaches the child. Before launch, the engine asserts that a child-spawning role has an unlimited wait ceiling.

The signatures `Background tasks still running after 600s; terminating`, an implausibly short success envelope with no STATUS for a long role, and a response that says it is waiting for background work are transport/non-run evidence.

### 12.3 Codex invocation

Codex retains the current global-option ordering, pinned model, explicit `-C "$REPO_ROOT"`, workspace permissions, JSONL output, and add-directory rules. It uses the same attempt engine, status publisher, registry validation, and lifecycle events as Claude.

### 12.4 Long-role headroom check

Immediately before a role whose timeout meets `long_role_headroom_threshold_minutes`, run one minimal vendor liveness/headroom probe after all free gates. A spend/quota refusal prevents the long launch and records the appropriate run-scoped vendor event. A successful probe proves only current liveness; it MUST NOT claim enough remaining budget to finish the role.

## 13. Unified dispatch engine

### 13.1 Lifecycle

`dispatch_attempt` owns a complete per-child lifecycle:

1. Load and validate the role contract.
2. Allocate `dispatch_id` and all attempt-scoped paths.
3. Populate optional defaults and validate required inputs with `render_prompt --check`.
4. Validate vendor invocation, target CWD, context7 policy, output roots, and phase applicability.
5. Render the prompt fully in memory. No event claims launch before these steps pass.
6. For mutating roles, acquire the write lease and snapshot state immediately before launch.
7. On a prelaunch defect, emit exactly one `DISPATCH_NOT_LAUNCHED` event and return a typed result.
8. Emit `DISPATCH_STARTED` with attempt identity, contract identity, expected STATUS, CWD, and snapshot/lease references.
9. Invoke and time the child with monotonic timing.
10. Capture stdout/stderr, exit code, usage, vendor envelope, and final mutation/checkpoint state.
11. Validate only the current attempt's STATUS.
12. Classify the result using Section 14.
13. Emit exactly one `DISPATCH_COMPLETED` record and, for a failed launched attempt, exactly one typed failure event referencing it.
14. Release or preserve the write lease according to the classified state.
15. Return a structured result to the phase controller.

If lease/snapshot preparation fails after acquiring a lease, prelaunch cleanup records the reason and releases the lease only when its ownership is unambiguous. An active conflicting lease waits for its owner; a stale or ambiguous lease HALTs for integrity reconciliation and does not consume the ordinary correction retry.

The helper that emits a completion owns it exclusively. Callers MUST NOT add a second completion block.

### 13.2 Parallel dispatch

`dispatch_parallel` schedules independent calls to the same `dispatch_attempt` primitive. Parallelism changes only scheduling:

- each child receives its own dispatch ID, paths, monotonic start/end, exit code, usage, completion, and failure event;
- child outcomes are logged independently even if its peer succeeds;
- the group returns only after both child results have been collected or classified;
- `group_wall_ms` is max(end) minus min(start), never the sum of child durations;
- per-child durations are mandatory and cannot default to zero;
- mutating children cannot run in parallel because the lease rejects the second launch.

### 13.3 Turn-start reconciliation

At the beginning of every orchestrator turn, a deterministic helper reconstructs the active phase. If its gate is unsatisfied, no child is live, and durable state says a dispatch is owed, the orchestrator executes the owed action before narrating future work.

A user-facing statement that a dispatch “is running” requires a matching `DISPATCH_STARTED`. Narration that lacks durable evidence is an orchestration defect and is recorded as a process proposition.

## 14. Failure classification and bounded recovery

### 14.1 Ordered classifier

Classification precedence is normative. The first matching row wins:

| Order | Classification | Predicate |
|---:|---|---|
| 1 | `PRELAUNCH_FAILED` | Contract/input/render/CWD/lease/snapshot validation failed; vendor was not invoked |
| 2 | `TIMED_OUT` | Invocation exit code is the timeout code |
| 3 | `SPEND_CEILING` | Extracted vendor envelope matches quota/spend exhaustion |
| 4 | `PERMANENT_VENDOR_ERROR` | Auth, invalid configuration/model, permission, or other non-transient vendor refusal |
| 5 | `TRANSIENT_TRANSPORT_ERROR` | Connection loss, stream stall, overload/5xx, throttle eligible for retry, or known background-wait termination |
| 6 | `UNKNOWN_VENDOR_ERROR` | Non-zero result with extracted vendor error not covered above |
| 7 | `EXITED_NO_STATUS` | Process exited without a fresh final STATUS and no sibling temporary file exists |
| 8 | `PUBLICATION_LOST` | Final STATUS absent and attempt-specific temporary publication exists |
| 9 | `MALFORMED_STATUS` | Final STATUS exists but fails schema, identity, path, or role validation |
| 10 | `COMPLETED` | Final STATUS is fresh, valid, and belongs to the attempt |

An orchestration refusal embedded in a success envelope is evaluated before ordinary vendor liveness and maps to `PRELAUNCH_FAILED`/orchestration correction when caused by CWD or inputs.

### 14.2 Mutation state

Every failed mutating attempt also receives one mutation state:

- `NO_SIDE_EFFECTS`: HEAD, tree, owned artifacts, and checkpoints equal the snapshot;
- `CLEAN_CHECKPOINTED`: completed committed/checkpointed units exist and the tree is clean;
- `DIRTY_CHECKPOINTED`: durable completed units plus one identifiable partial unit exist;
- `DIRTY_UNCHECKPOINTED`: owned paths changed without a valid continuation boundary;
- `INTEGRITY_UNKNOWN`: state cannot be compared reliably or foreign changes are unexplained.

Read-only roles always use `NO_SIDE_EFFECTS` unless they violated their contract, which becomes `INTEGRITY_UNKNOWN` and a process defect.

### 14.3 Recovery matrix

| Classification/state | Automatic response |
|---|---|
| `PRELAUNCH_FAILED`, correctable contract/input/render/CWD defect | Emit `ORCHESTRATION_CORRECTION`; correct once up to `prelaunch_correction_cap`; never emit a vendor-failure event |
| `PRELAUNCH_FAILED`, active lease owner | Wait for/classify the owner; do not spend the correction budget and do not launch another writer |
| `PRELAUNCH_FAILED`, stale/ambiguous lease or snapshot integrity failure | HALT for integrity reconciliation; no automatic correction |
| `PUBLICATION_LOST`, non-mutating | Retry once up to `publication_retry_cap`; never promote `.tmp` |
| `TRANSIENT_TRANSPORT_ERROR` or `EXITED_NO_STATUS`, `NO_SIDE_EFFECTS` | Fresh retry once up to `transient_retry_cap` |
| `TIMED_OUT`/transient/no-STATUS, `CLEAN_CHECKPOINTED` | Dispatch continuation up to `continuation_cap` |
| Same, `DIRTY_CHECKPOINTED` | Run integrity reconciliation, then continuation if the partial unit is isolated |
| Any failure, `DIRTY_UNCHECKPOINTED` or `INTEGRITY_UNKNOWN` | HALT with exact paths/state; no second writer launches |
| `SPEND_CEILING` | Emit one run-scoped vendor-unavailable event; suppress later calls to that vendor; halt or use an explicitly accepted degraded path |
| `PERMANENT_VENDOR_ERROR`/`UNKNOWN_VENDOR_ERROR` | No automatic retry; halt or use the documented vendor-degradation decision |
| `MALFORMED_STATUS` | Non-mutating: one correction retry; mutating: reconcile mutation first, then continue/retry only if safe |
| `COMPLETED` | Branch only on validated role verdict; release lease after final state is recorded |

Retry budgets are keyed by logical dispatch and cause. A continuation is related to the prior attempt but consumes its own attempt ID. When a cap is reached, emit `RECOVERY_CAP_REACHED` and follow the role/phase's explicit halt or owner-decision path.

### 14.4 Resume states

`dispatch_state` exposes these durable states:

- `NOT_STARTED`: no attempt record;
- `PRELAUNCH_FAILED`: `DISPATCH_NOT_LAUNCHED` exists;
- `RUNNING_OBSERVED`: start exists and the child is known live;
- `ORPHANED_UNOBSERVED`: start exists, no completion exists, and no child is live;
- `FAILED_OBSERVED`: completion/failure exists without valid terminal STATUS;
- `COMPLETED_VALID`: completion and matching valid STATUS exist;
- `COMPLETED_UNACCEPTED`: role completed, but its phase has not emitted acceptance.

An observed classified failure is never called orphaned merely because STATUS is absent. Resume first processes an existing lease and the ordered recovery matrix, then allocates a new attempt if authorized.

## 15. RUN_LOG events, decisions, and corrections

### 15.1 Common event envelope

Every lifecycle or decision event has:

```text
event_id: <stable unique ID>
event: <typed event name>
timestamp: <UTC ISO-8601>
process_schema_version: 2
phase: <phase>
iteration: <iteration>
dispatch_id: <dispatch ID or null>
caused_by_event_id: <event ID or null>
authority: <process|owner|role|system>
reason: <non-empty text>
```

Event IDs are allocated monotonically from RUN_LOG and are the reconciliation key. Timestamp proximity is not identity. The parent dispatch engine is the sole RUN_LOG writer: child processes return structured results and never append lifecycle events. Parallel start/completion records are serialized by the parent under `$FEATURE_FOLDER/.orchestration/log.lock`, so event-ID allocation and append form one atomic operation.

### 15.2 Required event types

The event vocabulary includes:

- `DISPATCH_NOT_LAUNCHED`
- `DISPATCH_STARTED`
- `DISPATCH_COMPLETED`
- `ATTEMPT_FAILED`
- `RECOVERY_AUTHORIZED`
- `RECOVERY_CAP_REACHED`
- `ORCHESTRATION_CORRECTION`
- `HALT`
- `OWNER_DECISION`
- `RISK_ACCEPTED`
- `PHASE_ACCEPTED`
- `EVENT_CORRECTED`
- `VENDOR_UNAVAILABLE`
- `DEGRADED_REVIEW_ACCEPTED`
- `CONTEXT7_UNAVAILABLE`
- `CONTEXT7_RESTORED`
- `WRITE_LEASE_ACQUIRED`
- `WRITE_LEASE_RELEASED`
- `ARTIFACT_INTEGRITY_BLOCKED`
- `ITERATION_CAP_REACHED`
- `ITERATION_CAP_OVERRIDE`

The prompt SHALL define required extra fields per event in a parseable event-contract table.

### 15.3 Decision and acceptance records

`OWNER_DECISION`, `RISK_ACCEPTED`, and `PHASE_ACCEPTED` include:

- decision ID and authority identity (`operator`, `standing_process_policy`, or named owner input);
- exact scope/finding IDs;
- artifact path and revision being accepted;
- evidence considered;
- alternatives rejected;
- residual risk;
- expiry/applicability (`this attempt`, `this phase`, or `this run`);
- whether independent re-review verified the result;
- follow-up ID when work remains.

The orchestrator may make only decisions already granted by the process and within the existing autonomy ceiling. It cannot infer authority for production changes, publication, destructive history operations, broad credential actions, or destruction of user work.

### 15.4 Corrections are append-only

RUN_LOG remains append-only except for immediate repair of a syntactically malformed block that the writer has not yet acknowledged as emitted. Once a valid event is durable, later evidence corrects it by appending `EVENT_CORRECTED` with the original event ID, replacement classification, evidence, and effect on downstream state.

Consumers use the latest valid correction chain and retain the original for audit.

### 15.5 Context7 precedence

`context7_policy` reconstructs state in this order:

1. Find the latest valid `CONTEXT7_UNAVAILABLE` or `CONTEXT7_RESTORED` event.
2. If the latest event is unavailable, return `best-effort` even if Phase 1 was reachable.
3. If the latest event is restored, return `required` only when the restoration event cites a successful deterministic probe.
4. With no later event, derive policy from Phase 1 STATUS.
5. Missing server, transient failure, and quota exhaustion remain distinct reasons.

The role discovering degradation records it in STATUS; the orchestrator emits the event once. Downstream roles never rely on an in-memory variable from a prior phase.

## 16. Preflight and capability policy

### 16.1 Gate order

Phase -1/Phase 1 performs work in this order:

1. Derive and validate process/target paths and new-run schema eligibility.
2. Run local CLI/binary canaries.
3. Run the target dirty-tree gate.
4. Validate process identity and artifact gitignore rules.
5. Initialize and verify the run-local runtime.
6. Run paid minimal model-ID probes once per distinct model.
7. Run dispatched required/optional skill and MCP capability probes.

Steps 1–5 are labeled zero-token. If any halts, steps 6–7 receive zero calls. `develop-it.sh` may print a convenience dirty-tree advisory but does not duplicate the authoritative allow-list or gate decision.

### 16.2 Process identity

Identity resolution runs only against `PROCESS_REPO_ROOT`:

1. Resolve `PROCESS_PATH_REL`.
2. Call `git ls-files --error-unmatch` before diffing.
3. Record `develop_it_dirty: no|yes` for tracked files.
4. Record `develop_it_dirty: untracked` for all untracked files, including ignored-untracked.
5. Record `develop_it_dirty: unknown` only for non-git/unreadable identity and include a reason.
6. Always record SHA-256 independently of Git state.

RUN_LOG, STATUS validation, summaries, fixtures, and tests accept all four typed states.

### 16.3 Evidence-based capability

Preflight STATUS records required and optional skill results separately. A `MISSING_SKILLS` verdict contains each skill name, plugin roots/paths checked, and absent/unreadable evidence.

The process re-probes once when:

- a per-phase missing claim contradicts a prior READY in the run;
- deterministic filesystem evidence shows the skill exists;
- an attempt reached `.tmp` publication but lost final STATUS.

A successful substantive dispatch records `vendor_proven: true` with role and event ID. A later probe self/publication failure cannot revoke proven capability. Auth failure, model rejection, or run-scoped spend ceiling can.

### 16.4 Optional skills

Skill discovery is marketplace-agnostic. Preflight emits:

- `required_skills_present`
- `required_skills_missing`
- `optional_skills_present`
- `optional_skills_absent`

Optional absence never halts. Context discovery emits work types/project capabilities and computes `applicable_optional_skills = installed ∩ relevant` with reasons. The plan writer receives that set; implementation passes only task-relevant skills to workers and records actual usage per task.

### 16.5 Dual-vendor coverage

When both vendors are proven, every substantive review gate uses both. Findings are the union; one PASS never cancels another reviewer's finding.

A genuine capability loss produces degraded coverage with exact phase/iteration/count impact. It cannot be reported as strict PASS. Phase 7 requires a `DEGRADED_REVIEW_ACCEPTED` decision to proceed with one substantive reviewer. Phase 3/5 may finish provisionally under their existing relaxed severity rule, but readiness is at least `READY_WITH_NOTES` and lists unreviewed blocker/major exposure.

## 17. Artifact and finding contracts

### 17.1 Structural artifact manifest

Each producer role declares a structural manifest in the registry:

- expected output path;
- minimum non-whitespace size;
- required top-level headings or machine fields;
- allowed/forbidden truncation markers;
- canonical revision calculation;
- whether an `artifact-complete.json` marker is required.

`validate_artifact <role> <dispatch-id>` runs before an expensive downstream review. It verifies the producer has a matching successful STATUS or a typed `PHASE_ACCEPTED`, every required output exists inside an allowed root, the manifest passes, referenced summaries exist, and the revision equals the accepted event.

Size alone never proves completeness. A failed writer that left a large artifact cannot enter review without an explicit accepted partial-artifact decision.

### 17.2 Finding record

Reviewer findings use a parseable block or JSONL record with:

```text
finding_id
reviewer_role
vendor
phase
iteration
severity: blocker|major|minor
artifact_path
artifact_revision
location
summary
evidence
required_change
origin_iteration
provenance: preexisting|new_coverage|fix_regression|unknown
related_finding_ids
status: open|fixed|verified|accepted_risk|deferred|superseded
```

Each reviewer emits a vendor-local source ID plus a required normalized location and issue key. A deterministic ingestion helper assigns the canonical `finding_id` from artifact kind, normalized location, and normalized issue key; models do not invent the canonical hash themselves. Re-reviewers receive the prior canonical catalog and reuse its location/issue key when the same issue recurs. `related_finding_ids` records splits, merges, and supersession. The summarizer rejects canonical-ID collisions with conflicting content and sends them to an explicit classification correction rather than guessing.

### 17.3 Fixer disposition

Every fixer receives an explicit list of finding IDs and returns one disposition per ID:

- `fixed` with changed paths/sections and post-edit revision;
- `subsumed_by:<finding_id>`;
- `already_satisfied` with evidence;
- `blocked` with exact missing authority/input;
- `accepted_risk:<decision_id>`;
- `deferred:<followup_id>`.

No assigned finding may disappear. `DONE` requires all assigned IDs to have a disposition and the fixer to run its scoped self-verification/ripple check. `PARTIAL` is continuable progress, never gate success.

## 18. Review convergence and fixer behavior

### 18.1 Gate loop

Phases 3, 5, and 7 use one review-gate controller:

1. Validate producer STATUS, artifact manifest, accepted revision, and review window.
2. Dispatch all active reviewers against the same immutable revision.
3. Validate both reviewer STATUS files and findings.
4. Union findings and calculate blockers/majors/minors by stable finding ID.
5. If the gate passes, emit `PHASE_ACCEPTED` for the reviewed revision.
6. If it fails, select an allowed bounded fixer, allocate batches, and acquire a write lease.
7. Validate every fixer disposition and resulting artifact revision.
8. Re-run structural validation and dispatch a full review of the new revision, prioritizing the diff while retaining whole-artifact regression coverage.
9. Repeat until accepted, explicitly dispositioned, divergent, blocked, or capped.

The existing severity policy remains:

- iterations 1–2 require `blockers=0` and `majors=0` across active reviewers;
- iteration 3 onward requires `blockers=0`, with remaining majors recorded as deferred/accepted only through explicit dispositions;
- the hard iteration cap remains `review_iteration_cap`.

### 18.2 No unreviewed final fix

Every mutation, including a relaxed-tier or cap-adjacent fixer, advances to another reviewer iteration. At the cap the controller may:

- accept the last **reviewed** revision under the documented severity/decision rules;
- HALT with unresolved findings;
- accept risk through a typed owner/process decision.

It MUST NOT invoke a fixer after the last available review, patch the artifact itself, or call an unreviewed revision accepted.

### 18.3 Convergence signals

After each review/fix cycle, record:

- artifact byte/section count before and after;
- `growth_pct`;
- new, recurring, resolved, reopened, and fix-regression finding counts;
- net open blocker/major count;
- changed sections/paths;
- per-reviewer cost and wall time.

A round is divergent when any of these is true:

1. a finding fixed in the preceding pass recurs twice;
2. a fix-induced blocker appears in two consecutive reviewer rounds;
3. artifact growth exceeds `artifact_growth_warning_pct` for two consecutive fixer passes while open blocker+major count does not fall;
4. the fixer reopens more blocker/major findings than it verifies as resolved in two consecutive rounds.

After `divergent_round_cap`, automatic additive fixing stops. The controller assigns one consolidation pass whose priority is deletion, replacement, contradiction removal, and provenance repair. That pass is still bounded and re-reviewed. If divergence persists, HALT or require an explicit risk/phase decision; it cannot return to an unlimited additive loop.

### 18.4 Document-aware fixing

Spec and plan fixers MUST:

- edit in place while preserving a snapshot/diff history;
- prefer simplifying/replacing/deleting redundant text over appending another rule;
- honor document boundaries and avoid unrelated implementation/process expansion;
- process at most `document_fixer_batch_size` findings per batch;
- checkpoint each disposition;
- mark subsumed findings explicitly;
- inspect adjacent sections, references, tables, and acceptance criteria for ripple effects;
- report net size and changed sections;
- never claim full completion from a partial batch.

## 19. Plan executability and verification model

### 19.1 Executable task contract

Every implementation-plan task SHALL declare:

- stable task ID and objective;
- exact target files/sections;
- prerequisites/dependencies;
- actor: `implementer`, `owner`, `CI`, or `deployed_environment`;
- required capability/credential without including secret material;
- external/destructive side effects;
- implementation steps;
- verification commands and expected results;
- verification environment;
- rollback/cleanup where applicable;
- optional task-relevant skills;
- handoff/follow-up behavior when the declared actor is not the implementer.

Plan reviewers treat a missing actor, unreachable prerequisite, unavailable credential, unexecutable verification, or post-implementation-only review remedy as a finding. Owner/deployment work becomes an explicit handoff item rather than a surprise implementer failure.

### 19.2 Verification results

Replace the single verification scalar as the only evidence with per-command results:

```text
verification_id
command
environment
result: PASS|FAIL|EXCLUDED|NOT_RUN
exit_code
evidence_path
baseline_comparison
reason
followup_id
```

Rules:

- `FAIL` enters debugging/fixing.
- `EXCLUDED` is allowed only with evidence that the command is pre-existing, environment-bound, actor-bound, or outside the change's capability. It cannot hide a new regression.
- `NOT_RUN` requires a named actor/prerequisite and becomes handoff/readiness work.
- Overall implementation may be `DONE_WITH_EXCLUSIONS` only when all non-excluded required checks pass and exclusions are policy-valid.
- The debugger consumes only genuine failures; it does not mutate deployed environments to satisfy an exclusion.

Wall-clock performance assertions are enforced only in a declared controlled environment. A loaded or incomparable workstation result is advisory/inconclusive. Any code fix claiming a performance change must remeasure under the same controlled conditions.

## 20. Phase sequence and behavior

The new sequence for fresh schema-v2 runs is:

| Phase | Name | Primary result |
|---:|---|---|
| -1 | Bootstrap and free gates | Valid new-run roots/runtime or HALT |
| 1 | Capability preflight | Evidence-based vendor/skill/MCP state |
| 2 | Context discovery | Project context and applicable optional skills |
| 3 | Spec review gate | Accepted reviewed spec revision |
| 4 | Plan writing | Structurally complete executable plan |
| 5 | Plan review gate | Accepted reviewed plan revision |
| 6 | Implementation | Completed tasks, durable progress, verification results |
| 7 | Code review gate | Accepted reviewed implementation revision |
| 8 | All tests | Final test verdict and evidence |
| 9 | Documentation and handoff | Updated durable docs, UAT, follow-ups |
| 10 | Git finalization | Local-only finalization STATUS |
| 11 | Readiness | Audited final readiness report |

### 20.1 Phases -1 and 1 — bootstrap/preflight

Apply Section 16's order. In addition:

- fail before writing a mismatched existing artifact folder;
- validate the role/event/policy registries and extracted runtime;
- prove Claude and Codex effective CWD with fake/local canary behavior where possible;
- record model probes as paid minimal calls;
- retain run-scoped spend/auth/model-rejection evidence;
- publish preflight STATUS through the canonical publisher;
- never downgrade a proven vendor because a later cheap probe failed to publish.

### 20.2 Phase 2 — context discovery

Context discovery remains read-only and additionally returns:

- project work types/capabilities;
- installed optional skills and relevance reasons;
- controlled verification environments available in the repository/CI;
- documentation/UAT conventions;
- likely mutable documentation paths for Phase 9.

It must not prescribe an optional skill solely because it is installed.

### 20.3 Phase 3 — spec review

Phase 3 uses the shared gate/finding contracts. Spec fixers operate in bounded batches with checkpoints, snapshots, size accounting, provenance, and mandatory re-review. The accepted event pins the exact spec revision consumed by Phase 4.

### 20.4 Phase 4 — plan writing

The plan writer:

- consumes the accepted spec revision and task-relevant skills;
- writes top-level sections incrementally;
- emits checkpoints after each section;
- satisfies the executable task contract in Section 19;
- publishes `artifact-complete.json` after structural completion;
- publishes terminal STATUS afterward.

An interrupted writer continues from validated section checkpoints. Review cannot start from artifact size or marker alone; matching terminal STATUS or explicit phase acceptance is still required.

### 20.5 Phase 5 — plan review

Phase 5 validates executable actors, prerequisites, commands, exclusions, review-window freshness, optional skill routing, and required handoffs. It uses the shared convergence loop.

The gate must be reviewed clean or explicitly accepted before Phase 6. Once implementation starts, the plan's pre-implementation review window is closed. Readiness must mark later plan review `STALE` rather than dispatch a reviewer against consumed anchors.

### 20.6 Phase 6 — implementation

The implementer supports three explicit modes:

- **Mode A — fresh:** begin from accepted plan and implementation baseline.
- **Mode B — post-debug re-verification:** consume debugger STATUS and re-run affected/full checks.
- **Mode D — continuation:** consume validated checkpoints, prior classification, tree state, and remaining work.

The old implementer Mode C is removed rather than retained as an unused compatibility path. The separate `implementation-fixer` owns all Phase 7 review fixes.

Mode D verifies completed commits/tasks, reconciles at most one partial dirty task, and continues without repeating completed work. A clean timeout after committed tasks is `INCOMPLETE_CONTINUABLE`, not terminal failure. The controller may continue up to `continuation_cap`.

The implementation STATUS includes per-command verification results, exclusions, completed task IDs, progress/SDD paths, baseline/final SHAs, declared foreign changes, and remaining handoffs.

### 20.7 Phase 7 — code review

Phase 7 always reviews the accepted implementation revision with all proven vendors. If a fix is needed, it dispatches `implementation-fixer`, never the full plan implementer.

The implementation fixer:

- accepts only enumerated finding IDs and the reviewed baseline/final diff;
- changes only files needed for those findings;
- commits finding-specific changes;
- runs scoped tests plus required ripple checks;
- remeasures measurement-based findings;
- checkpoints each finding;
- stops after the assigned set;
- publishes a new implementation revision for mandatory re-review.

Any unrelated opportunity becomes a follow-up rather than code in the fix pass.

### 20.8 Phase 8 — all tests

All test commands remain foregrounded under print-mode rules. The test runner publishes per-command evidence. Test fixers receive only genuine failed checks and follow the same lease, snapshot, bounded scope, checkpoint, and review-back principles.

`EXCLUDED` and `NOT_RUN` results route to handoff/readiness rather than being silently counted as PASS. Final test verdict is derived from the result set and policy-valid exclusions.

### 20.9 Phase 9 — documentation and handoff

Phase 9 runs after implementation/code review/tests are stable and before git finalization. It owns:

```text
$FEATURE_FOLDER/9-documentation/
  attempts/<dispatch-id>/STATUS.md
  uat.md
  planned-vs-realized.md
  documentation-validation.md
$FEATURE_FOLDER/followups.jsonl
```

`followups.jsonl` has one writer: the orchestrator's typed follow-up helper. Roles return follow-up candidates in validated STATUS/role-owned outputs; the orchestrator converts them into canonical records after dispatch classification. Each item has ID, origin phase/finding, description, actor, prerequisite, risk, status, and evidence/disposition.

The documentation writer consumes the final diff, accepted spec/plan revisions, implementation/test/review summaries, decisions, exclusions, and follow-ups. Under a write lease it:

1. appends an auditable planned-versus-realized record rather than rewriting history;
2. updates README/architecture/progress/operational docs only when the final change made them stale;
3. writes UAT prerequisites, actions, expected results, smoke checks, rollback/cleanup, and a clearly separated “Not yet executed” section;
4. validates local commands syntactically/non-destructively and records what could not be executed;
5. checks all referenced paths/findings/follow-ups;
6. self-corrects structural validation failures up to `documentation_fix_cap`;
7. publishes terminal STATUS through the shared publisher.

Documentation work does not edit historical run artifacts or source proposition files.

### 20.10 Phase 10 — git finalization

Git finalization moves after documentation so the final local commit can include all intended product documentation changes. It may stage and commit according to project policy. It MUST NOT push, open a pull request, merge, publish, deploy, or rewrite shared history without an explicit separately scoped owner action.

It validates that no write lease remains, all accepted outputs are represented, and unexplained dirty paths are blocked.

### 20.11 Phase 11 — readiness

Readiness consumes only validated STATUS, summaries, events, accepted revisions, checkpoint summaries, verification records, follow-ups, and deterministic audit results. It does not infer success from transcripts.

The final report includes:

- process schema/version/hash and typed dirty identity;
- every phase's accepted dispatch ID and artifact revision;
- review iteration/provenance/growth/convergence history;
- dual-vendor coverage by phase/iteration and exact degraded exposure;
- decisions, accepted risks, corrections, and unverified acceptances;
- implementation tasks/commits and continuation history;
- PASS/FAIL/EXCLUDED/NOT_RUN verification matrix;
- documentation/UAT status;
- follow-ups grouped by actor;
- transient/recovery/cap statistics;
- artifact/proposition reconciliation result;
- git finalization result and explicit publication status;
- one of `READY`, `READY_WITH_NOTES`, or `NOT_READY` under deterministic rules.

`READY` requires strict reviewed gates, no unaccepted coverage degradation, all required verification PASS, no unresolved integrity event, complete documentation/handoff, a clean reconciliation audit, and no residual risk/follow-up that policy marks blocking.

## 21. Proposition and event reconciliation

### 21.1 Metadata-only audit

The orchestrator continues to avoid reading proposition bodies during the run. Before readiness, a deterministic helper is explicitly authorized to read only proposition headers/metadata and RUN_LOG event envelopes.

Mandatory proposition headers include `event_id`, phase, kind, and trigger. The helper matches exact event IDs, not timestamp windows.

When `record_event` emits an event requiring a proposition, it also writes a complete metadata record to process-owned `$FEATURE_FOLDER/.orchestration/pending-propositions.jsonl`. The orchestrator immediately uses that record to append one full proposition entry through `append_proposition`; the helper validates the header/event relation before writing. The pending record contains no unfinished body and cannot affect current-run gates. A fulfilled entry is marked by a separate append-only fulfillment record.

### 21.2 Audit rules

The audit SHALL report failure for:

- a mandatory RUN_LOG event without exactly one proposition header;
- a mandatory proposition trigger with no real event;
- duplicate proposition coverage for one event;
- a proposition that claims a launched vendor failure for `DISPATCH_NOT_LAUNCHED`;
- a retry/continuation without `RECOVERY_AUTHORIZED` and a causal attempt;
- an event correction not reflected in the final classification;
- duplicate/missing completion blocks per dispatch ID;
- a phase acceptance whose artifact revision differs from its successful attempt.

The event helper MUST generate the mandatory header metadata when the event occurs. The orchestrator supplies contextual body/recommendation prose through `append_proposition` without reusing that prose for current gate decisions.

Readiness is `NOT_READY` when this audit fails. Existing proposition files are outside this audit because schema-v2 never opens their old feature folders.

## 22. Testing strategy

All behavioral changes are developed against deterministic offline tests. Live vendor tests remain optional/billable and are not required to prove the prompt contract.

### 22.1 Registry and extraction tests

Extend the current table/extraction checks to prove:

- every dispatched role has exactly one complete registry row;
- prose, appendices, and phase calls name no unregistered top-level role;
- every appendix variable is declared required or optional by that role;
- every role's verdicts/required fields match its appendix;
- status/output templates remain inside allowed roots and contain attempt identity;
- the policy and role tables parse without lossy empty columns;
- extracted runtime/registries hash-match the prompt and source with no top-level phase action;
- phase snippets source the generated runtime and do not carry copied helper bodies.

### 22.2 STATUS publisher tests

Use temporary directories to cover:

- successful publication with `reason: null`;
- duplicate/missing/wrong identity fields;
- illegal role verdict and missing role-specific field;
- attempted output path outside allowed roots;
- failed temporary write, failed rename, and failed final re-read;
- sibling temporary file with no final file;
- refusal to overwrite an existing attempt STATUS;
- one-command use from the constrained Codex preflight role.

### 22.3 Dispatch and fake-CLI tests

Extend fake Claude/Codex to assert and simulate:

- Claude and Codex both observe `pwd == REPO_ROOT`;
- Claude receives `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`;
- nested/long foreground work outlives the former child ceiling and is reaped normally;
- an exited-zero role without STATUS is not successful;
- stdout-envelope orchestration refusal and spend ceiling classification;
- attempt 1 success followed by attempt 2 no-STATUS cannot reuse attempt 1 evidence;
- sequential and parallel calls produce one start/completion per launched child and correct monotonic duration;
- render/input failure produces no vendor invocation and one `DISPATCH_NOT_LAUNCHED`;
- caller-side duplicate completion is detected;
- no process sends a signal to extend a live timeout wrapper.

### 22.4 Failure-state table tests

Create a table-driven offline test for every precedence row and relevant mutation state. It includes:

- timeout plus missing STATUS;
- spend signature in stdout with non-zero/zero wrapper variants;
- transient transport with no side effects;
- clean and dirty checkpointed mutations;
- dirty uncheckpointed mutation;
- publication loss versus ordinary missing STATUS;
- malformed current STATUS versus valid stale STATUS;
- observed failed dispatch versus orphaned unobserved dispatch;
- each recovery cap and terminal event;
- run-scoped vendor suppression.

No classifier test may depend on free-form orchestrator interpretation.

### 22.5 Lease and continuation tests

Use disposable Git repositories to simulate:

- two mutating launches competing for one lease;
- unrelated human edit and overlapping edit;
- orchestrator commit while a role holds the lease;
- declared foreign commit;
- attempt-scoped snapshot restore input without automatic rollback;
- clean committed implementation timeout and continuation;
- one dirty partial task reconciliation;
- repeated continuation that neither duplicates commits nor skips remaining tasks;
- lost external SDD directory with durable per-task artifacts still present.

### 22.6 Review convergence tests

Fixture review/fixer records SHALL cover:

- stable recurring IDs versus newly surfaced findings;
- a finding subsumed by another;
- partial fixer disposition rejection;
- fix-induced blocker recurrence;
- two growing non-convergent rounds and consolidation response;
- condensation/deletion producing negative growth while preserving coverage;
- cap reached after review versus forbidden last unreviewed fix;
- one-vendor Phase 7 result requiring degraded-review acceptance;
- PASS from one reviewer with blockers from the other;
- stale plan review after implementation rejected without a vendor call.

### 22.7 Phase and readiness tests

Contract fixtures SHALL prove:

- dirty/untracked process identity states;
- all zero-token gates prevent model calls on halt;
- false `MISSING_SKILLS` reprobe and proven-vendor retention;
- optional skill routing for a relevant frontend project and no routing for an irrelevant backend-only task;
- later context7 unavailability overrides Phase 1 reachability;
- truncated plan/marker/no STATUS does not enter review;
- actor-bound plan task becomes handoff rather than implementer failure;
- valid verification exclusion bypasses debugger but appears in readiness;
- dedicated implementation fixer cannot add unrelated scope;
- documentation/UAT/follow-up outputs precede git finalization;
- finalizer remains local-only;
- exact event/proposition reconciliation by event ID;
- every readiness verdict boundary, including incomplete documentation, degraded coverage, integrity blocks, exclusions, and failed audit.

### 22.8 Repository test organization

The implementation may extend current checks and add focused scripts, with this target allocation:

| Test area | Existing/new test location |
|---|---|
| Prompt syntax/runtime purity | `tests/check_01_lint.sh`, `tests/check_06_cookbook.sh` |
| Marker/appendix/variable coverage | `tests/check_02_markers.sh`, `tests/check_03_varcoverage.sh` |
| Role/policy/event registries | `tests/check_04_table.sh` plus registry fixtures |
| Normative prompt contracts | `tests/check_05_contract.sh` |
| Invocation/dispatch/publication | `tests/check_07_fakecli.sh` and fakebin fixtures |
| Launcher boundary | `tests/check_08_launcher.sh` |
| Recovery state table | new `tests/check_09_recovery.sh` |
| Review/phase/readiness contracts | new `tests/check_10_process_v2.sh` |
| Event/proposition reconciliation | new `tests/check_11_reconciliation.sh` |

`tests/run.sh` remains the required offline completion command. `tests/run.sh --live` remains optional and billable.

## 23. Implementation work packages

All work packages belong to one implementation iteration. The sequence is contract-first so intermediate edits do not create competing definitions; the branch is complete only after every package and the full offline suite pass.

### Task 1 — Establish schema-v2 contract tests

Add failing fixtures/assertions for process schema, immutable old-run rejection, registry completeness, attempt identity, status publication, event envelope, and phase renumbering. Preserve useful current tests instead of replacing them with weaker string checks.

### Task 2 — Consolidate policy and role registries

Extend the Models/role source into the full contract registry, add the policy/event contract tables, derive all lookup helpers, and remove hand-maintained duplicates.

### Task 3 — Extract and verify the shared runtime

Implement run-local extraction, manifests, hashing, phase sourcing, and bootstrap/reconstruction behavior. Remove copied cookbook instructions from phase bodies while keeping the prompt normative.

### Task 4 — Introduce attempt-scoped identity and STATUS publication

Implement monotonic attempt allocation, attempt paths, STATUS v2, canonical publisher, current-attempt validation, and publication-loss handling. Update every appendix to use the publisher and common fields.

### Task 5 — Harden vendor invocation

Pin Claude CWD, preserve Codex CWD, apply print-mode child policy/env, add long-role headroom checks, record effective CWD, and prohibit live-wrapper signalling.

### Task 6 — Replace dispatch helpers with one lifecycle engine

Implement the single-child primitive, parallel composition, monotonic timing, exactly-once lifecycle logging, structured results, prelaunch events, duplicate detection, and turn-start owed-dispatch reconciliation.

### Task 7 — Implement failure classification and bounded recovery

Add the ordered classifier, mutation states, recovery matrix, budgets, observed/orphaned resume states, run-scoped vendor suppression, and cap events. Remove contradictory legacy Mode/ORPHANED prose.

### Task 8 — Add typed decisions, corrections, leases, and snapshots

Implement event contracts, accepted-risk/owner/phase decisions, append-only corrections, exclusive mutating ownership, integrity comparison, declared foreign changes, and scoped snapshots.

### Task 9 — Add checkpoints and continuation modes

Implement common progress JSONL, plan artifact-complete marker, document/reviewer checkpoints, implementer SDD custody, Mode D, and continuation validation/caps.

### Task 10 — Rebuild preflight around evidence

Reorder free/paid gates, add typed process identity, validate runtime/registries, make skill probes evidence-based and marketplace-agnostic, track proven vendors, preserve dual-review policy, and route applicable optional skills.

### Task 11 — Rebuild review gates around stable findings

Add finding/disposition schemas, diff/provenance/growth metrics, bounded document fixer batches, convergence/divergence handling, consolidation, artifact sanity, mandatory re-review, and reviewed-revision acceptance.

### Task 12 — Make plans and verification executable

Update plan-writer/reviewer appendices with actor/prerequisite/command/environment contracts, verification result records, exclusions, controlled performance measurements, reachability, and stale-review behavior.

### Task 13 — Split implementation continuation from code-review fixing

Update implementer modes/progress and introduce the bounded `implementation-fixer` role. Ensure Phase 7 fix/re-review closes over an exact finding set and revision.

### Task 14 — Add documentation/handoff and renumber final phases

Implement `followups.jsonl`, documentation writer, UAT/planned-vs-realized/validation outputs, Phase 9 validation/fix cap, Phase 10 local-only finalization, and Phase 11 readiness inputs.

### Task 15 — Automate audit and readiness

Implement event-ID proposition reconciliation, phase/artifact acceptance audit, context7 event precedence, detailed coverage/decision/recovery reporting, and deterministic readiness boundaries.

### Task 16 — Remove obsolete contradictions and complete verification

Delete superseded helper/prose variants, update README/RUNBOOK phase descriptions as process documentation, run focused tests after each package, then run the full offline suite. Confirm no existing Prism artifact file changed.

## 24. Acceptance criteria

The design is implemented only when all criteria below hold.

### Dispatch correctness

1. Every Claude/Codex fake subprocess observes the target repository CWD.
2. Every launched child has one unique dispatch ID, transcript pair, STATUS path, start event, and completion record.
3. A stale STATUS can never satisfy a later attempt.
4. Every role uses the canonical publisher and a valid STATUS v2 is required for completion.
5. Parallel timing/logging equals real child launches with no duplicate or missing completions.
6. Print-mode long/nested work is foregrounded/awaited and is not killed by the old child ceiling.

### Recovery and mutation safety

7. Classifier precedence and recovery actions are deterministic under table tests.
8. Transient no-side-effect failures receive at most the configured retry.
9. Checkpointed work continues without duplicated tasks/commits; uncheckpointed or unknown mutation never auto-retries.
10. One durable write lease prevents overlapping writers and preserves unexpected external work.
11. Every recovery, acceptance, risk, correction, and post-HALT resume has a typed causal event.

### Review and artifact integrity

12. No producer artifact reaches expensive review without current STATUS/acceptance and structural validation.
13. Every fixer-assigned finding is dispositioned and every fixer revision is re-reviewed.
14. Stable finding provenance distinguishes recurring, new, resolved, reopened, and fix-induced issues.
15. Growth/non-convergence triggers consolidation and then a bounded stop; there is no unreviewed final fix.
16. Phase 7 uses the dedicated bounded implementation fixer.
17. A gate cannot report strict PASS when required vendor coverage was lost.

### Planning, implementation, and verification

18. Every plan task has an actor, prerequisites, executable verification, environment, and handoff behavior.
19. PASS/FAIL/EXCLUDED/NOT_RUN are preserved per command; only FAIL enters debugging.
20. Performance verdicts require comparable controlled measurements.
21. Implementer progress and SDD records remain durable after interruption or external skill-state loss.

### Process completeness

22. Free local gates prevent all paid calls when they halt.
23. Process identity distinguishes clean, modified, untracked, and unknown.
24. Optional skills are routed only when installed and task-relevant.
25. A later context7 degradation event overrides earlier reachability.
26. Documentation, UAT, planned-versus-realized state, and follow-ups exist before local git finalization.
27. Git finalization performs no push/publication operation.
28. RUN_LOG/proposition reconciliation is exact by event ID and blocks readiness on mismatch.
29. Readiness exposes coverage degradation, decisions, exclusions, continuations, residual risk, and follow-ups.
30. All deterministic offline tests pass, and the six historical Prism artifact folders have no changes.

## 25. Recommendation traceability

| Recommendation | Implemented by this specification |
|---|---|
| R01 — Claude target CWD | §§12.1, 22.3; Tasks 5–6; acceptance 1 |
| R02 — Safe long/nested Claude work | §§12.2, 20.6–20.8, 22.3; Tasks 5, 9; acceptance 6 |
| R03 — Attempt-scoped dispatch/STATUS | §§8, 13, 15; Tasks 4, 6; acceptance 2–3 |
| R04 — Prescribed STATUS publication | §9, §22.2; Task 4; acceptance 4 |
| R05 — Checkpoints and continuation | §10, §§20.4/20.6, §22.5; Task 9; acceptance 9/21 |
| R06 — Bounded recovery state machine | §14, §22.4; Task 7; acceptance 7–9 |
| R07 — Unified dispatch/timing/logging | §13, §§15.1–15.2; Task 6; acceptance 2/5 |
| R08 — Role contract registry | §6, §22.1; Task 2 |
| R09 — Evidence and dual-vendor coverage | §§16.3/16.5, §20.7; Task 10; acceptance 17 |
| R10 — Divergence/provenance/growth | §§17.2, 18.3; Task 11; acceptance 14–15 |
| R11 — No unreviewed final fix | §§18.1–18.2; Task 11; acceptance 13/15 |
| R12 — Bounded document-aware fixers | §§17.3, 18.4; Tasks 9/11; acceptance 13–15 |
| R13 — Decisions/risk/corrections/resume | §15; Task 8; acceptance 11 |
| R14 — Write lease and snapshot | §11, §22.5; Task 8; acceptance 10 |
| R15 — Executable plans/exclusions | §19, §§20.5–20.6; Task 12; acceptance 18–20 |
| R16 — Dedicated Phase 7 fixer | §§20.7, 23 Task 13; acceptance 16 |
| R17 — Single tested runtime | §7, §22.1; Task 3 |
| R18 — Automated reconciliation | §21, §22.7; Task 15; acceptance 28 |
| R19 — Documentation/handoff | §§20.9–20.11; Task 14; acceptance 26/29 |
| R20 — Optional skill routing | §§16.4, 20.2; Task 10; acceptance 24 |
| R21 — Artifact sanity/gate windows | §§17.1, 20.4–20.5; Tasks 11–12; acceptance 12 |
| R22 — Context7 event precedence | §15.5; Task 15; acceptance 25 |
| R23 — Free gates before probes | §16.1; Task 10; acceptance 22 |
| R24 — Untracked process identity | §16.2; Task 10; acceptance 23 |

Every R01–R24 item has exactly one row. The detailed source counts and all 137 original observation dispositions remain in the linked source backlog.

## 26. Risks and mitigations

| Risk | Mitigation |
|---|---|
| The prompt becomes larger while trying to reduce duplication | Put normative data in parseable tables, source one generated runtime, and delete superseded local variants in Task 16 |
| Registry table becomes hard to maintain | Parse/lint every row, enforce appendix/input/output coverage, and reject unknown roles |
| Attempt/event schemas add logging volume | Keep flat envelopes, store detailed progress in JSONL, and summarize by stable IDs |
| Automatic continuation hides a bad mutation | Require lease/snapshot comparison and valid checkpoints; unknown/uncheckpointed state always halts |
| Stable finding IDs are assigned inconsistently | Generate canonical IDs in deterministic ingestion, preserve reviewer/vendor source IDs, and reject conflicting collisions |
| Documentation phase creates late code/doc churn | Restrict it to final-diff-stale documentation, use a lease, validate outputs, and run it before one final local commit |
| New schema is accidentally applied to an old run | Enforce schema/process identity before any existing-folder write and provide no backfill path |
| Runtime extraction becomes a second implementation | Treat prompt blocks as source, verify hashes every phase, and forbid manual edits to generated files |

## 27. Explicitly rejected alternatives

1. **No artifact migration.** Existing run artifacts are not converted or edited.
2. **No phased release waves.** Tasks are sequenced for correctness but land as one integrated process revision.
3. **No override appendix layered on contradictory old behavior.** Superseded rules are removed.
4. **No separately maintained runtime framework.** Runtime files are generated from the prompt.
5. **No launcher-owned duplicate dirty-tree policy.** The launcher may advise; the prompt remains authoritative.
6. **No automatic rollback of user/foreign work.** Snapshots support diagnosis and explicitly authorized scoped recovery only.
7. **No transcript-as-verdict fallback.** Missing/malformed STATUS remains a failed attempt even when prose says success.
8. **No full implementer for Phase 7 fixes.** The bounded implementation fixer owns that work.
9. **No post-implementation plan re-review.** The review window closes when implementation starts; late requests are classified stale.

## 28. Completion definition

The implementation is complete when:

- `develop-it-prompt.md` contains one internally consistent schema-v2 contract and no superseded contradictory path;
- all 16 work packages are represented by passing deterministic tests;
- `tests/run.sh` reports no failures;
- every acceptance criterion in §24 has direct test or inspection evidence;
- every R01–R24 row in §25 points to implemented prompt text and verification;
- README/RUNBOOK accurately describe the new phase sequence without becoming alternate policy sources;
- Git diff confirms no file under any existing Prism artifact folder was modified.

No deployment or data migration step follows this work. The revised prompt applies to new runs after merge; old runs continue under their recorded process version.
