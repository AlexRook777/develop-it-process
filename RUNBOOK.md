# Runbook — starting a develop-it run

How to drive `develop-it-process.md` against a target project, end to end.
`README.md` describes what the pipeline *is*; this file is the operational
checklist for launching one.

The worked example throughout is the `prism` project. Only `SPEC_PATH` changes
between runs — everything else derives from it.

---

## Step 0 — Verify the environment (once per machine)

```bash
command -v claude codex jq git python3 shellcheck realpath
bash --version | head -1                        # need 5.3+
ls ~/.claude/plugins/data/superpowers-*         # superpowers for claude
ls ~/.codex/plugins/cache/superpowers-*/*/*/skills 2>/dev/null \
  || find ~/.codex/plugins/cache -maxdepth 5 -name writing-plans   # for codex
```

All of `claude`, `timeout`, `awk`, `sed`, `jq`, `git`, `date`, `sha256sum`,
`cut`, `mkdir`, `mv`, `tail`, `tr`, `grep`, `realpath`, `env`, `python3` are
hard-required — `canary_preflight` halts on any of them. `codex` is optional but
its absence at Phase 1 is a HALT (Mode 0), not a degradation.

Both CLIs need the Superpowers skills reachable. For Codex they may live under
`~/.codex/plugins/cache/<marketplace>/…/skills` rather than `~/.codex/skills`;
an empty `~/.codex/skills` is not by itself a problem. If the Phase 1 probe
reports `MISSING_SKILLS` the run HALTs with an install hint.

Codex also needs the target repo trusted, or `--skip-git-repo-check` handles it
(the cookbook always passes it). Verify the model in `~/.codex/config.toml`
matches the Models table.

---

## Step 1 — Pick the spec

The spec must already be written. The filename drives the artifacts folder name:

```
spec:    docs/superpowers/specs/<YYYY-MM-DD>-<slug>-design.md
folder:  docs/superpowers/specs/<YYYY-MM-DD>-<slug>-artifacts/
```

A spec that does not match `<date>-<slug>-design.md` makes the orchestrator
dispatch a one-shot subagent to propose a folder name and then HALT for your
confirmation — so prefer the convention.

---

## Step 2 — Terminal: set the run parameters

```bash
cd /home/oleks/repos/develop-it-process

export PROCESS_PATH="$PWD/develop-it-process.md"
export REPO_ROOT="/home/oleks/repos/prism"
export SPEC_PATH="$REPO_ROOT/docs/superpowers/specs/2026-07-30-raw-event-v3-date-columns-design.md"
export FEATURE_FOLDER="${SPEC_PATH%-design.md}-artifacts"
export CODEX_CONSENT=n      # pre-answers the "continue claude-only?" prompt

printf '%s\n' "$PROCESS_PATH" "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_FOLDER"
```

- `FEATURE_FOLDER` must end in `-artifacts`.
- `SPEC_PATH` matters beyond the appendices: `dirty_tree_check` allow-lists it,
  so the spec-fixer's in-place edits don't trip the Phase 6 baseline gate.
- `PROCESS_REPO_ROOT` and `REPO_ROOT` must be different repositories —
  `validate_roots` halts otherwise.
- `CODEX_CONSENT` is consulted only if the Codex probe fails. Leave it unset and
  answer interactively if you prefer; with stdin not a TTY and the var unset, the
  run HALTs rather than degrading silently.

---

## Step 3 — Pre-run hygiene

```bash
git -C "$REPO_ROOT" status --short      # must print nothing
./tests/run.sh                          # process-doc health: offline, free
```

A dirty target tree HALTs at the top of Phase 1 and again at Phase 6. The
orchestrator will not auto-stash and does not accept "proceed anyway".

Two optional calls that are yours to make:

```bash
# 1. Put the work on its own branch — Phase 9 commits to whatever is checked out:
git -C "$REPO_ROOT" switch -c feat/<slug>

# 2. Silence the Phase 1 warning about untracked artifacts. The run works either
#    way: dirty_tree_check allow-lists FEATURE_FOLDER at runtime.
echo 'docs/superpowers/specs/*-artifacts/' >> "$REPO_ROOT/.gitignore"
```

---

## Step 4 — Terminal: launch the orchestrator session

From the same shell (so the exports are inherited), in **this** repo — never
from the target repo:

```bash
claude --model opus --add-dir "$REPO_ROOT" --dangerously-skip-permissions
```

- `--add-dir` so the orchestrator reaches the target repo without per-path prompts.
- `--dangerously-skip-permissions` is what makes an unattended multi-hour run
  possible. Drop it to approve each bash block, and expect to babysit. The
  dispatched subprocesses pass the flag to themselves regardless — without it
  they exit rc=0 and never write their STATUS file.
- Opus for the orchestrator: it makes every gate, severity, and HALT decision.

---

## Step 5 — The kickoff prompt

Generate a ready-to-paste copy with the real paths filled in (run this in the
shell from Step 2, *before* launching `claude`):

```bash
cat <<EOF > /tmp/kickoff.txt
You are the orchestrator for the develop-it SDLC pipeline.

Read $PROCESS_PATH in full — the whole file including all appendices — before
doing anything. It is your complete instruction set. Do not summarize it, do not
turn it into your own plan, and do not invent phase procedures.

Run parameters. Export these at the top of EVERY bash block — shell state does
not survive a phase boundary:

  export PROCESS_PATH=$PROCESS_PATH
  export REPO_ROOT=$REPO_ROOT
  export SPEC_PATH=$SPEC_PATH
  export FEATURE_FOLDER=$FEATURE_FOLDER
  export CODEX_CONSENT=$CODEX_CONSENT

Execute the pipeline end to end, starting at Phase -1 Step 1.0 (CLI canary +
dirty-tree gate + model probe). Hold to the document's rules, in particular:

- One phase per bash invocation. Never bundle two numbered phases into one block.
- Paste the cookbook helpers at the top of each block. set -uo pipefail, never
  set -e. Call init_orchestration_vars, and re-derive CONTEXT7_POLICY every block.
- Dispatch plan-writer, implementer, and any re-dispatch of either with
  run_in_background: true — their timeouts exceed one Bash call.
- You are a strict orchestrator. You never read the spec, the plan, source,
  tests, reviewer findings, or transcripts — only STATUS files and the per-phase
  summaries they reference. You never review, fix, or write code, and you are
  never a reviewer in your own context. Run the Anti-leak self-check at every
  phase boundary.
- Log every dispatch with log_dispatch, including the nine usage-telemetry fields.
- HALT and surface to me on any BLOCKED verdict, HALT condition, or iteration cap.

Between phases, report to me in one short block: phase, verdict, severity counts
(blockers/majors/minors), and what you are dispatching next.

Before Phase -1, print the five run parameters back to me and wait for my
confirmation.
EOF

cat /tmp/kickoff.txt
```

The heredoc is unquoted so `$PROCESS_PATH` and friends expand. If you edit the
prompt text, keep it free of backticks and of any other `$NAME` you don't want
substituted.

---

## Step 6 — What happens, and where you're in the loop

Phases run `-1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10`.

Gates 3 (spec), 5 (plan), 7 (code) each dispatch a Claude and a Codex reviewer in
parallel and loop fix→re-review:

| Iteration | Gate blocks on | Notes |
|---|---|---|
| 1–2 | `blockers + majors > 0` | strict tier |
| 3–10 | `blockers > 0` only | majors left at the passing iteration get one **final fix pass**, no re-review, and are recorded as *deferred majors* |
| 10 (cap) | `blockers > 0` → HALT | majors-only residue is not a HALT |

Any gate passing at iteration ≥ 3 forces the final verdict to
`READY_WITH_NOTES`, never a silent `READY`.

Expect to answer, at most:

- **Confirmation** of the five parameters before Phase −1.
- **A codex-consent prompt** if the Codex probe fails in modes 1–5 (Mode 0,
  binary missing, HALTs unconditionally). Pre-answered by `CODEX_CONSENT`.
- **A dirty-tree HALT** if anything in the target repo changed mid-run.
- **A HALT** at an iteration cap or on a `BLOCKED` fixer.

Budget real wall-clock: `plan-writer` has a 120-minute timeout and `implementer`
300 minutes. Keep the session open; those are issued as background bash calls, so
the orchestrator's next turn begins when they finish.

---

## Step 7 — Where the output lands

```
<REPO_ROOT>/docs/superpowers/specs/<date>-<slug>-artifacts/
  final-readiness-report.md          <- read this first
  RUN_LOG.md                         <- append-only event log, used for resume
  full_log.md                        <- xtrace of every orchestrator bash command
  process-improvement-proposition.md
  1-preflight/phase-1/ … 10 numbered phase folders (STATUS + findings + summaries)
  transcripts/<dispatch-id>.{json,err}
```

The spec is edited in place at `SPEC_PATH` by the spec-fixer. The plan is written
to `<REPO_ROOT>/docs/superpowers/plans/<date>-<slug>.md`. Phase 9 commits the
implementation slice to the checked-out branch, per the target project's
`CLAUDE.md` git policy.

---

## Step 8 — If it dies partway

Relaunch `claude` the same way and paste the same prompt with the same
`FEATURE_FOLDER`. `RUN_LOG.md` is the state: the orchestrator classifies each
prior dispatch (never-launched / unfinished / complete), re-runs the per-phase
preflight if it lands inside a gated phase (3/5/6/7), and reconstitutes any
codex-consent flag. Non-mutating roles are safe to redispatch automatically;
mutating ones HALT for you to reconcile.

Resume does not re-prompt for codex consent — the original consent stands.

---

## Step 9 — After the run

```bash
cat "$FEATURE_FOLDER/final-readiness-report.md"
git -C "$REPO_ROOT" log --oneline -5
git -C "$REPO_ROOT" status --short
```

Verdict semantics:

- `READY` — strict pass at every gate.
- `READY_WITH_NOTES` — some gate passed at iteration ≥ 3, and/or deferred majors
  exist.
- `NOT_READY` — residual test failures after Phase 8's fix-round cap. The run
  still completes and records them in detail.

---

## Appendix — the caps, and how to change them for one run

| Cap | Value | Where |
|---|---|---|
| Review-gate fix→re-review iterations (Phases 3, 5, 7) | **10** | `develop-it-process.md` §Review-gate severity policy |
| Strict→relaxed threshold | after iteration **2** | same |
| Phase 8 test rounds | **4** (initial run + 3 fix rounds) | §Phase 8 Step 8.1 |
| Codex command budget per reviewer dispatch | 2 / 4 / 20 by mode | §Codex reviewer modes |

**These are prose in the orchestrator's instruction set, not parameters.**
`$ITERATION_CAP` is not in `render_keys()` — it appears once in the document, in
a comment, as an example of a name that must not be partially substituted. No
appendix receives it, no helper reads it, and no test in `tests/` asserts it.

So overriding a cap for a single run is a prompt instruction, not an edit — which
is also why it needs no revert. Append to the rules list in Step 5:

```
Deviation for this run, authorized by me: the review-gate iteration cap is <N>,
not the 10 in the document. It applies to all three gates (Phase 3 spec, Phase 5
plan, Phase 7 code). Nothing else about the severity policy changes — strict gate
at iterations 1-2, relaxed from iteration 3 (only blockers block; majors
remaining at the passing iteration get the single final fix pass and are recorded
as deferred majors). If any active reviewer still reports blockers > 0 at
iteration <N>, append event=ITERATION_CAP_REACHED carrying `cap: <N>`, then HALT
and surface the residual findings paths and the artifact path for my decision.

Record this cap change in process-improvement-proposition.md as a deviation entry
(trigger #6, per the Process self-observation section) so the audit trail
explains why the cap was <N> rather than 10.
```

Two things to know before you lower it:

- The relaxed threshold is pinned to **absolute** iteration numbers, not to a
  fraction of the cap. `cap=3` therefore yields exactly one relaxed iteration,
  and iteration 3 is both the first relaxed round and the cap. `cap=2` would
  remove the relaxed tier entirely and make every gate strict — usually not what
  you want.
- Log the deviation. Deviation entries are explicitly excluded from the
  completion criteria's 1:1 RUN_LOG↔proposition match, so recording one cannot
  break the completion check — but omitting it leaves a gate that stopped early
  with no explanation in the readiness report.
