# P00 stage 3 — per-phase suborchestration (design note)

Status: **design only** (Task 12's second deliverable). No stage-3 code exists;
nothing in this note is normative for the current process. Stage 2 (this
commit) split the resident prompt into a core document plus on-demand
`phases/*.md` packs. Stage 3 is the next step on the same axis: stop having the
top-level orchestrator execute a phase's steps at all, and instead dispatch a
**phase orchestrator** subprocess per phase, whose entire working context is
that phase's pack plus the shared contracts.

## Dispatch shape

One `claude -p` subprocess per phase (the same non-interactive print-mode shape
every current role dispatch uses — dispatched via the existing
`dispatch_attempt` machinery, with a new registry row per phase-orchestrator
role, e.g. `phase-orchestrator-3`):

- **System prompt:** the phase's own pack (`phases/<N>-*.md`) concatenated with
  the shared-contract slice of the core document (orchestration contract,
  review-gate severity policy, registries, cookbook function index, shared
  blocks, failure handling & recovery matrix, RUN_LOG grammar). This is the
  same content the top-level orchestrator holds today — minus the ten packs the
  phase does not need. Assembly is mechanical (core minus the roadmap stubs,
  plus one pack) and can be a cookbook helper (`assemble_phase_prompt N`), so
  there is still exactly one authored source for every rule.
- **Inputs:** the same durable inputs the phase reconstructs today
  (`init_orchestration_vars N` already derives them from disk, never from an
  inherited shell) — this is what makes the phase orchestrator dispatchable at
  all: nothing it needs lives only in the top-level session's memory.
- **Outputs:** the phase's ordinary durable artifacts (attempt STATUS files,
  findings, summaries) plus one phase-level STATUS for the top level to branch
  on, published through the same `publish-status` program as every role.
- The top-level orchestrator shrinks to: sequence phases, read phase STATUS,
  branch per the verdict table, own the user conversation, and HALT surfacing.

## Write-lease handoff and RUN_LOG single-writer preservation

The single-writer invariant survives by making it **per scope, per interval**:

- The phase orchestrator acquires the write lease for its phase at dispatch
  (`lease_owner: phase-orchestrator-<N>-<dispatch_id>`) and is, for the life of
  that dispatch, the SOLE writer of `RUN_LOG.md` and the other orchestration
  artifacts — exactly the writes the top level performs today during that
  phase, no new write class.
- The top-level orchestrator writes ONLY between phases: it never appends to
  `RUN_LOG.md` while a phase orchestrator holds the lease. Its own inter-phase
  writes (phase-transition events, HALT records for a phase that died) happen
  after it has observed the lease released (or expired — below).
- Role subprocesses remain non-writers of `RUN_LOG.md`, unchanged: they return
  results through attempt-scoped files that the *phase* orchestrator ingests.
- Lease release is the phase orchestrator's last durable act before publishing
  its phase STATUS; the existing `acquire_write_lease`/`release_write_lease`
  JSON lease and snapshot machinery is reused as-is.

## Recovery semantics

A phase orchestrator's death is the same problem class as a role's death, one
level up, and gets the same treatment:

- **Phase orchestrator dies mid-phase:** the top level observes a completed
  subprocess with no valid phase STATUS (or a timeout). It re-dispatches the
  phase orchestrator, which — like every phase shell today — re-derives ALL
  state from disk: `RUN_LOG.md` classification of prior dispatches, per-phase
  preflight re-run for gated phases, checkpoint reconstruction for checkpointed
  roles. Nothing is resumed from the dead process's memory.
- **Stale lease:** a dead phase orchestrator may leave the lease held. The
  existing RM02/RM03 lease semantics apply unchanged: an ambiguous or
  stale-looking lease is a HALT for the operator, never an automatic reclaim.
  The re-dispatched phase orchestrator therefore starts with the same
  turn-start reconciliation the current process runs.
- **Bounded retries:** phase-orchestrator re-dispatch gets its own cap (one
  automatic re-dispatch, mirroring `transient_retry_cap`); past it, HALT to the
  user with the phase's durable paths.

## What the offline suite CANNOT verify — live-pilot checklist

The current tests prove marker discovery, render identity, registries, lease
mechanics, and recovery classification offline. They cannot prove any of the
following, so a live pilot must check these FIRST:

1. **Prompt-assembly fidelity in a real session** — that a `claude -p` phase
   orchestrator given pack+contracts actually executes the gate loop (the
   offline suite never executes orchestrator prose at all).
2. **Nested dispatch behavior** — a phase orchestrator dispatching roles via
   `dispatch_attempt` from inside a `claude -p` session (timeouts,
   `run_in_background` semantics one level down, transcript capture).
3. **Lease handoff under real timing** — top level observing release/expiry
   without polling races.
4. **Death-and-redispatch** — kill a phase orchestrator mid-gate and confirm
   the re-dispatch reconstructs from disk and does not double-append RUN_LOG
   blocks.
5. **Cost/latency delta** — stage 3 pays one extra model session per phase;
   the resident-context saving must be measured against it.

## Recommended pilot

One cheap feature (a README-sized change) through **Phases 3–5 only** in a
sandbox repo (a throwaway clone, never Prism — its integration suite is not
parallel-safe and its artifacts must stay untouched): Phase 3 and 5 exercise
the full gate loop (parallel reviewers, fixer, summarizer, severity gate) and
Phase 4 exercises a long-running background dispatch, while stopping before
Phase 6 keeps the pilot away from real mutations. Run it twice: once clean,
once with a deliberate `kill` of the Phase 5 orchestrator mid-iteration to
exercise checklist items 3–4. Only after both runs pass inspection should
stage-3 wiring be proposed for the remaining phases.
