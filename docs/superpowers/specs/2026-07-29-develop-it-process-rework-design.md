# develop-it-process rework: environment correctness and model reassignment

**Date:** 2026-07-29
**Target:** `develop-it-process.md` (3097 lines) in this repository
**Status:** design approved, pending implementation plan

## 1. Problem

`develop-it-process.md` is an LLM orchestration prompt that drives `claude` and `codex`
CLI subprocesses through a 12-phase SDLC pipeline. It was authored and tuned against a
different machine (a GCP host, user `worker`, repo `GCP`) where the process file lived
*inside* the target project repository.

Two independent problems now block it:

1. **It does not run correctly on this machine.** The defects catalogued in §6–§8 were
   each empirically verified, and only three of them relate to models. The document's own
   instruction at line 320 — "Use these helpers verbatim" — converts each latent bug in
   the cookbook into a guaranteed runtime bug.
2. **The model assignments are a generation stale** and do not match the intended
   division of labour.

The document also carries internal contradictions (three conflicting write-allow-lists,
three-way timeout disagreements, wrong phase numbers, a self-contradicting appendix)
that would mislead any future reader.

### Verification method

Every environment claim in this spec was confirmed by execution on the target machine,
not inferred. Claims marked *verified* were reproduced directly. This matters because
the document's current state is itself the product of careful reading that missed these
defects.

## 2. Goals

- The document runs correctly on this machine, in this two-repository layout.
- Model assignments match the intended division of labour and are enforced by a
  mechanism rather than asserted in prose.
- Internal contradictions are resolved so the document is maintainable.
- The two bug classes that proved hardest to catch by reading are prevented
  mechanically, by runnable checks.

## 3. Non-goals

- No change to the pipeline's phase structure, gate semantics, or the
  iteration-dependent severity policy. These are sound.
- No change to the delegation contract: the orchestrator never reads artifacts and never
  reviews. Its *write* list is corrected and unified in §8.1 — the narrow three-file list
  quoted in the current document is one of the three contradictory versions §8.4 resolves,
  and it already excludes the transcript writes line 21 permits.
- No support for a non-Linux host. The document targets this machine.
- No backward compatibility with feature folders from prior runs. None exist in this
  repository, so the renames in §8.3 are free.

## 4. Target environment

Confirmed by execution:

| Component | Value | Consequence |
|---|---|---|
| OS | Ubuntu 26.04, kernel 7.0.0-27 | — |
| Shell | bash 5.3.9 | `EPOCHREALTIME`, `exec {fd}>`, arrays, procsub all available |
| coreutils | **uutils 0.8.0** for `date`, `sha256sum`, `cut`, `tr`, `tail`, `mkdir`, `timeout` | `date +%s%3N` is **not** honoured (§6.5) |
| `awk` | mawk 1.3.4 (not gawk) | range patterns and `-F:` verified working |
| `grep` | shell-function shim in a Claude Code session; `/usr/bin/grep` is GNU 3.12 | must be pinned (§6.6) |
| `mv` | GNU coreutils 9.7 | — |
| `claude` | 2.1.220 at `/home/oleks/.local/bin/claude` | `--model`, `-p`, `--output-format=json`, `--dangerously-skip-permissions`, `--agents` all present |
| `codex` | 0.146.0 at `/usr/local/bin/codex` | `--json`, `--skip-git-repo-check`, `-s`, `-C`, `--add-dir` present on `exec`; `-a` is **global only** |
| `python3` | `/usr/bin/python3` | required by `render_prompt` |
| `jq`, `git`, `gh`, `uv`, `npm` | present | `pytest` is **not** installed standalone |
| Superpowers | 6.2.0 for both `claude` and `codex` | all 8 required skills present |
| `~/.codex/config.toml` | `model = "gpt-5.6-sol"`, `model_reasoning_effort = "high"` | aligns with §5 |

Available codex models for this account: `gpt-5.6-sol`, `gpt-5.6-luna`, `gpt-5.6-terra`,
`gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`.

### 4.1 Verified CLI facts that must not be "fixed"

- `codex -a never exec …` parses; `codex exec -a never …` does **not**. The document's
  existing warning at line 55 and 468 is correct and stays.
- `timeout` (uutils) still returns 124 on expiry, so the document's Mode-2 detection at
  lines 1367 and 1420 works.
- mawk handles the appendix-extraction range pattern at line 383 correctly.

## 5. Design: model assignment layer

### 5.1 Root cause

`$CLAUDE_MODEL` is referenced at lines 445 and 852 and **assigned nowhere in the
document**. It is absent from the orchestration-variables block at lines 326–351. Per-role
model choice therefore exists only as prose ("dispatch a `claude` Opus subprocess"), which
nothing enforces. This is why the assignments drifted silently.

### 5.2 Single source of truth

Add three cookbook lookups keyed by role name, and nothing else that states the same facts:

| Function | Returns | Applies to |
|---|---|---|
| `role_model <role>` | concrete model id | all dispatched roles, **both vendors** |
| `role_effort <role>` | `medium` \| `high` | codex roles only; empty for claude |
| `role_timeout <role>` | `<minutes>` (see §8.2) | all dispatched roles |

Every dispatch site resolves before invoking, and **both vendors are bound explicitly**:

```bash
CLAUDE_MODEL="$(role_model "$role")"   # → claude --model "$CLAUDE_MODEL"
CODEX_MODEL="$(role_model "$role")"    # → codex -m "$CODEX_MODEL" -a never …
```

Binding Codex is not optional. Effort and `--json` alone leave the model determined by
`~/.codex/config.toml`, i.e. by ambient state outside this document — the same class of
defect as the unassigned `$CLAUDE_MODEL`. `codex` accepts `-m/--model` both globally and on
`exec` (verified in 0.146.0); it is passed as a **global** option before `exec`, alongside
`-a never`, per the ordering constraint at line 55.

This also requires rewriting line 143's advice that "the safest invocation is to omit `-m`
entirely and let `~/.codex/config.toml` supply the model." That guidance exists to avoid the
ChatGPT-auth HTTP 400, but it trades one failure mode for unpinned models. The forbidden-id
prohibition (`*-codex-max`, `o*`) is what actually prevents the 400 and stays; the
omit-`-m` advice goes.

The role table in the document becomes documentation *of* these functions. §9 check 6
asserts table and function agree, so they cannot drift.

### 5.3 Role assignments

| Role | Vendor | Pinned model | Effort |
|---|---|---|---|
| Orchestrator | (running LLM) | — | — |
| `context-discovery` | claude | `claude-sonnet-5` | — |
| `spec-fixer` | claude | `claude-fable-5` | — |
| `plan-writer` | claude | `claude-fable-5` | — |
| `plan-fixer` | claude | `claude-fable-5` | — |
| `spec-reviewer-claude` | claude | `claude-opus-5` | — |
| `plan-reviewer-claude` | claude | `claude-opus-5` | — |
| `code-reviewer-claude` | claude | `claude-opus-5` | — |
| `debugger` | claude | `claude-opus-5` | — |
| `implementer` (supervisor) | claude | `claude-opus-5` | — |
| **implementer sub-subagents** | claude via `--agents` | `claude-sonnet-5` | — |
| `all-tests-runner` | claude | `claude-sonnet-5` | — |
| `test-fixer` | claude | `claude-sonnet-5` | — |
| `finishing-branch` | claude | `claude-sonnet-5` | — |
| `summarizer-spec` | claude | `claude-sonnet-5` | — |
| `summarizer-plan` | claude | `claude-sonnet-5` | — |
| `summarizer-implementation` | claude | `claude-sonnet-5` | — |
| `summarizer-code-review` | claude | `claude-sonnet-5` | — |
| `summarizer-all-tests` | claude | `claude-sonnet-5` | — |
| `readiness-writer` | claude | `claude-sonnet-5` | — |
| `preflight-claude` | claude | `claude-sonnet-5` | — |
| `preflight-codex` | codex | `gpt-5.6-sol` | `medium` |
| `spec-reviewer-codex` | codex | `gpt-5.6-sol` | **`high`** |
| `plan-reviewer-codex` | codex | `gpt-5.6-sol` | **`high`** |
| `code-reviewer-codex` | codex | `gpt-5.6-sol` | **`high`** |

The sub-subagent row is new; the current table has no row for it, and the current
document has no mechanism to set it.

### 5.4 Rationale for the high-effort reviewers

The purpose of the review gates is to catch problems before implementation, so all three
Codex reviewers run at `high`. `preflight-codex` stays at `medium`: its entire task is a
directory-existence check, where reasoning effort buys nothing.

This deliberately reverses a cost optimisation the document records at line 474 ("This
removes a hidden global config that previously caused iterative review gates to run at
maximum cost"). The exposure — high effort across up to 10 iterations on 3 gates — is
accepted. It is bounded by the existing iteration-dependent gate, which relaxes after
iteration 2 so most gates converge in 1–2 rounds. Line 474's justification text must be
rewritten rather than deleted, so a future reader understands the tradeoff was made
knowingly.

### 5.5 Effort is decoupled from mode

Lines 882–891 currently bundle four independent concerns under "cheap vs deep": reasoning
effort, filesystem allow-list, command budget, and findings cap. Only effort is about cost.
Effort moves to the role table (§5.3); the remaining three stay as mode properties, because
they enforce *scope discipline* independent of how hard the model thinks — a spec reviewer
should not wander the source tree regardless of its effort setting.

Modes are renamed, because with effort uniformly high "cheap" is actively misleading:

| Old name | New name | Allow-list | Cmd budget |
|---|---|---|---|
| Cheap (micro) | `micro` | skill directory listing only | 2 |
| Cheap (spec) | `scoped` | `$SPEC_PATH` | 4 |
| Cheap (plan) | `scoped` | `$SPEC_PATH` + `$PLAN_PATH` | 4 |
| Deep | `diff-aware` | spec + plan + `git diff $IMPLEMENTATION_BASE_SHA...HEAD` scope | 20 |

`codex_invoke` gains a third form so `preflight-codex` is not forced to share the
reviewers' effort.

### 5.6 Findings caps

Currently 5 BLOCKER/MAJOR + 5 MINOR, ≤150 words each, at lines 889–891, 2053, 2266, 2604.
A high-effort reviewer that finds 12 real problems would report 5 and silently drop 7,
making the cap — not the effort — the binding constraint on problem-catching.

- `spec-reviewer-codex`, `plan-reviewer-codex`: **uncapped** blockers and majors; minors
  capped at 10 per reviewer per gate iteration.
- `code-reviewer-codex`: keeps 5 + 5. Its 20-command diff sweep can generate long tails
  of low-value findings, and every uncapped major re-triggers the fix→re-review loop
  through iteration 2.
- ≤150 words per finding everywhere.

Note: the Claude-side reviewer appendices have **no findings cap at all** (verified by
inspecting `spec-reviewer-claude`, `plan-reviewer-claude`, `code-reviewer-claude`). Lifting
the spec/plan Codex cap therefore removes an asymmetry rather than introducing one.

### 5.7 Model-resolution policy

Lines 137–143 and their duplicate at line 1917 are rewritten around pinned ids.

- The role table names **exact ids**, not classes. The "latest available; today: …"
  indirection is removed: it is prose that nothing enforces, and it is precisely how the
  ids went stale.
- Line 140 currently reads "The implementer must remain on a Sonnet-class Claude model."
  This directly contradicts the new assignment and must be **rewritten, not
  re-versioned** — the supervisor moves to Opus and only sub-subagents stay Sonnet.
- **All model fallback chains are removed.** This is a strict-pinning design: a rejected id
  HALTs (§5.8). Retaining a chain would contradict both the HALT rule and §8.4's
  no-model-failover rule, and a silent fallback is exactly how the current ids went stale
  without anyone noticing. The old chain (`gpt-5.5` → `gpt-5.4` → `gpt-5.3-codex` →
  `gpt-5.2`) is deleted rather than updated; its last two entries do not exist for this
  account anyway.
- The forbidden-models prohibition (`*-codex-max`, `o*`) stays; it is auth-related, not
  version-related, and it is what prevents the ChatGPT-account HTTP 400. Add that
  `gpt-5.6-luna` and `gpt-5.6-terra` are available but deliberately unused.
- Changing a pinned model is therefore an **edit to this document**, not a runtime decision.
  That is the intended cost: it makes model changes reviewable.
- A fourth resolution entry for Fable is added; the policy currently has three.

### 5.8 Preflight model probe

Phase −1 gains a model-resolution check: one minimal-cost call per distinct pinned id
(`claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`, `gpt-5.6-sol`). A rejected id HALTs
with a remediation message naming the role and the id.

This is a **runtime gate inside the orchestration**, distinct from §9's tier-2 test that
probes the same ids. The gate protects a real run from starting on an unavailable model; the
test protects the document from claiming an id that no longer exists. Both make live calls,
which is why the test is opt-in while the gate is not.

This converts rot from silent drift into a loud, actionable failure, and settles
empirically whether the accepted literal is `claude-opus-5` or a context-window variant
such as `claude-opus-5[1m]` — the document does not need to guess.

### 5.9 `resolved_models:` becomes role-keyed

Lines 1928–1931 define a class-keyed map (`opus:` / `sonnet:` / `gpt55:`). With Fable
added, roles are no longer 1:1 with classes, so a class-keyed map cannot answer "which
model was dispatched for role X" — which breaks the drift-detection read at line 644 and
the write instruction at line 170. The map becomes role-keyed. The `gpt55:` key name,
which embeds a version, disappears.

### 5.10 Sub-subagent model pinning

The `implementer` appendix (lines 2331–2400) delegates all sub-subagent spawning to
`superpowers:subagent-driven-development`, which inherits the session model. With the
supervisor on Opus 5, inheritance would silently promote every sub-subagent to Opus 5.

Fix: the implementer dispatch passes an `--agents` definition declaring an `impl-worker`
agent type with a pinned model, and the appendix requires every sub-subagent to be spawned
with that type. The pin is enforced by the CLI, so it holds even if the supervisor
disregards its instructions.

**`impl-worker` is a role key in `role_model`, and the JSON is generated from it** — never
written as a literal:

```bash
agents_json="$(jq -nc --arg m "$(role_model impl-worker)" \
  '{"impl-worker":{description:"…",prompt:"…",model:$m}}')"
```

A hardcoded `"model":"claude-sonnet-5"` would be a fourth independent statement of the
assignment, able to drift from the table, from `role_model`, and from `resolved_models:`
alike. Generating it means §9 check 6 covers the sub-subagent pin as a side effect of
covering the role table.

Injection points: lines 2345–2354 (the sentence governing sub-subagent spawning), 2365
(Mode A), 2383 (Mode C), plus the orchestrator-side mirrors at lines 156, 181, 1213.

## 6. Design: two-repository model and environment portability

### 6.1 The conflation

The document has no concept of two repositories. It was written for a layout where the
process file lived inside the target repo. Here it lives in its own repo and orchestrates
other projects.

- Line 328: `PROCESS_PATH="${PROCESS_PATH:-/home/worker/repos/GCP/develop-it-process.md}"`
  — a `:-` default pointing at nothing. Consequence is worse than a crash: `extract_appendix`
  emits nothing and `render_prompt`'s `open(process).read()` raises an uncaught
  `FileNotFoundError`, so appendices render empty or as a Python traceback.
- Line 23 documents a *different* default (bare relative `develop-it-process.md`),
  contradicting line 328.

**Fix:** `PROCESS_PATH="${PROCESS_PATH:?must be set}"` — fail loud. Remove the second
documented default.

### 6.2 Two explicit roots

Add `PROCESS_REPO_ROOT`, derived as
`git -C "$(dirname "$PROCESS_PATH")" rev-parse --show-toplevel`.

`REPO_ROOT` keeps its name (it has many call sites) but is redefined as **the target
project repo** and becomes `REPO_ROOT="${REPO_ROOT:?must be set to the target project
repo}"` — set explicitly, never derived from cwd. The current line 329 derives it from cwd
via a bare `git rev-parse --show-toplevel`; a run launched from this repo would silently
orchestrate *this* repo — including `codex exec -C`, the all-tests scope, and the Phase 6
baseline.

`PROCESS_REPO_ROOT` and `REPO_ROOT` must not be equal; the canary asserts this and HALTs
if they are, since that means the orchestrator would review its own process file as if it
were the feature under development.

#### Validation, not just non-emptiness

`${VAR:?}` checks only that a value is set. Each root and path gets real validation, in
this order, each failure a HALT with the offending value named:

| Check | Applies to | Mechanism |
|---|---|---|
| exists, is a regular file, is readable | `PROCESS_PATH` | `[ -f ] && [ -r ]` |
| canonicalized (symlinks, `..`, trailing `/` resolved) | all paths and both roots | `realpath -e` (*verified present*) |
| is a git work-tree root | both roots | `git -C <root> rev-parse --show-toplevel` equals the canonicalized root |
| `PROCESS_PATH` lies inside `PROCESS_REPO_ROOT` | — | subtree test below |
| `FEATURE_FOLDER` under `REPO_ROOT`? | — | subtree test; result selects whether `--add-dir` is needed (§6.4) |
| roots differ | — | canonicalized string inequality |

Canonicalization must happen **before** any comparison. Comparing a symlinked or
non-normalized path against a canonical one produces false negatives, which in an
allow-list means a file is silently reported as an offender.

#### Allow-list matching semantics

The NUL parser (§7.2) compares repo-relative porcelain paths against the allow-list. Three
rules the previous draft left implicit:

1. **Entries outside the target repo are skipped, not converted.** `$PROCESS_PATH` lives in
   the other repository by design, so it can never appear in `$REPO_ROOT`'s porcelain
   output. It is dropped from the allow-list with a one-line note rather than being
   relativized into a meaningless path. This is the dead-weight entry the current document
   carries at line 735.
2. **Files match exactly; directories match boundary-aware.** A directory entry `d` matches
   a path `p` only when `p = d` or `p` begins with `d/`. A bare prefix test would let
   `docs/superpowers/specs/foo-artifacts` also allow
   `docs/superpowers/specs/foo-artifacts-backup`, silently widening the gate.
3. **Renames are checked on both paths.** For an `R`/`C` entry, *both* the new and the old
   path must be in the allow-list. Checking only the new path hides an out-of-scope
   deletion: renaming an unrelated tracked file *into* the allow-listed feature folder
   would pass the gate while having removed something outside it.

### 6.3 Provenance correctness

All three provenance sites get `-C "$PROCESS_REPO_ROOT"`:

- Line 344 `PROCESS_GIT_HEAD` — labelled "git HEAD of process file" at line 77 but records
  cwd's repo HEAD.
- Line 661 `git_sha` in `log_dispatch` — every `develop_it_git_sha` in `RUN_LOG.md` records
  the target project's HEAD.
- Line 663 — *verified*: `git diff --quiet HEAD -- <path outside repo>` exits 128, so the
  `&&` fails and `develop_it_dirty` is a constant `yes` carrying zero information.

Lines 84 and 1497 specify `git show HEAD:$PROCESS_PATH`. `HEAD:<path>` requires a
**repo-relative** path and fails on an absolute one; this must become a relative path
computed against `$PROCESS_REPO_ROOT`.

Net effect today: of the three provenance fields, only `develop_it_file_sha256` works. The
reproducibility guarantee stated at line 84 is void.

### 6.4 Codex sandbox and the feature folder

Lines 456, 463, 487, 493 use `codex exec -C "$REPO_ROOT" -s workspace-write`. Codex
reviewers must write findings and STATUS into `$FEATURE_FOLDER` (lines 2021, 2231, 2559).
If `$FEATURE_FOLDER` is not under `$REPO_ROOT`, the write falls outside the sandbox, no
STATUS file appears, and the document misclassifies this as a vendor Mode-3 failure —
attributing an orchestration bug to Codex.

Fix: `codex exec` accepts `--add-dir` (verified present in 0.146.0). Add
`--add-dir "$FEATURE_FOLDER"` when the folder is not under `$REPO_ROOT`, plus a preflight
assertion recording which case applies.

### 6.5 Millisecond timing

Lines 636–638 use `date +%s%3N`. *Verified*: uutils `date` 0.8.0 ignores the `%3N` width
and emits full nanoseconds (19 digits, e.g. `1785322391603105325`), so
`wall_ms=$((t1 - t0))` is roughly 10⁶ times too large. Every `duration_ms` in
`RUN_LOG.md`, every Duration column in the five summaries (lines 2799, 2861, 2909), and the
readiness rollup at line 3078 are wrong.

Fix: bash's `EPOCHREALTIME`. *Verified*: `us="${EPOCHREALTIME/[.,]/}"; ms=$((us/1000))`
yields a correct 13-digit millisecond value. This uses no external binary, so it is immune
to which coreutils implementation is installed.

Compounding bug: line 636 uses `local` outside a function. *Verified*: `bash: local: can
only be used in a function`. The assignment never happens, so `$wall_ms` is empty even
before the unit error. The timing snippet must be wrapped in a function.

### 6.6 Binary checks

`canary_preflight` (line 513) hard-requires only `claude timeout awk sed jq`. Add the nine
used-but-unchecked binaries: `git`, `date`, `sha256sum`, `cut`, `mkdir`, `mv`, `tail`,
`tr`, `grep`. `git` is the most serious omission — it is used at 12 sites.

Promote `python3` from warn-only (line 519) to hard-required. Line 336 already hard-exits
without it and `render_prompt` cannot function, so the warning is inconsistent with the
document's own behaviour.

Pin `grep` via a `GREP_BIN="${GREP_BIN:-/usr/bin/grep}"` variable. *Verified*: in a Claude
Code session `grep` is a shell function shimming ugrep, which does not exist in subprocess
shells and errors differently on the same regex — including on the empty-alternation input
`dirty_tree_check` produces today.

### 6.7 Leaked environment specifics

Remove or relabel content inherited from the originating project: the
`frontend/src/features/canvas` example (line 2577), `Google ADK, httpx, click` (line 181),
the `cli_log.md` reference (line 105). `start-all-tests.sh` (lines 160, 1306, 2648, 3070)
stays as an optional convention but is explicitly marked project-specific.

Test-discovery guidance at line 2649 must use `uv run pytest`; `pytest` is not installed
standalone here. Line 2577 tells the Codex deep reviewer to use `rg`, which in this shell
exists only as a shim function and will not exist in a `codex` subprocess shell.

## 7. Design: cookbook correctness

Nine fixes required for a run to complete. Each was verified.

### 7.1 Parallel-dispatch failure detection is inert

Line 873 `wait "$claude_pid"`. *Verified*: the subshell's last command is `echo "$?" > …`,
so `wait` returns 0 unconditionally and Modes 1/2/5 cannot be detected. Every parallel
reviewer dispatch reports success. Compounding this, nothing in the document ever **reads**
the `.rc` files written at lines 855 and 867.

Fix: the subshell ends with `exit "$rc"`; the parent captures `wait "$pid"; rc=$?`. The
`.rc` files gain a documented reader via §9.

Line 874 `[ -n "$codex_pid" ] && wait "$codex_pid"` is the function's last statement, so it
returns 1 whenever Codex is absent — the exact degraded mode the document spends ~500 lines
designing. See §7.4.

Line 861 tests `[ "$codex_available" = "true" ]`, but `codex_available` is prose-only
elsewhere and never initialised in any shell snippet — under `set -u` this aborts, otherwise
it is always empty and Codex is never dispatched from this helper. It must be initialised
and exported.

Lines 851 and 863 build appendix names as `"${phase}-reviewer-claude"`. The Phase 7
appendix is `code-reviewer-claude` (line 2481); no value of `$phase` produces all three
names, so Phase 7 renders an empty prompt and `render_prompt` raises `ValueError` from
`text.index`. Fix: pass explicit appendix names.

Lines 850–868 redirect into `$FEATURE_FOLDER/transcripts/` with no preceding `mkdir -p`;
if absent, bash fails the redirect and the subshell dies before the CLI runs.

### 7.2 `dirty_tree_check` is a silent no-op

Lines 735–744 build an ERE allow-list by joining `$PROCESS_PATH`, `$SPEC_PATH`, and
`$FEATURE_FOLDER` with `|`. Line 909 mandates that at Phase 1 only `$PROCESS_PATH` is set,
so the other two contribute **empty alternatives**: `^(/path||)`.

*Verified*: `/usr/bin/grep -Ev '^(foo||)'` matches every line and prints nothing (rc=1);
ugrep instead aborts with `error: empty (sub)expression` (rc=2). Both are swallowed by
`|| true`, leaving `offenders` empty. **The clean-tree gate never fires**, on the documented
happy path. Line 757's reasoning that this is "fine" is incorrect.

Two further bugs in the same helper:

- The allow-list holds **absolute** paths (appendices declare them absolute at lines 1825,
  1948, 2093, 2131) while `git status --porcelain` emits **repo-relative** paths, anchored
  with `^`. Even when fully populated the allow-list can never match.
- Line 743 `awk '{print $2}'`. *Verified*: a rename emits `R  a.txt -> b.txt` so `$2`
  yields the **old** path and `-> new` is discarded; a path containing a space is
  git-quoted so `$2` yields the fragment `"sub/file`.

Fix: `git -C "$REPO_ROOT" status --porcelain=v1 -z`, NUL-parsed, allow-list as an array of
repo-relative paths compared by prefix in shell rather than injected into a regex. Empty
entries are skipped explicitly. This resolves all four bugs together.

**Parsing detail the implementation must honour.** *Verified*: with `-z`, a rename emits
`R  <new>` NUL `<old>` NUL — **two** NUL-delimited fields for one entry. A naive NUL-split
treats `<old>` as a separate entry. The parser must consume an extra field whenever the
status code begins with `R` or `C`.

Line 748 `printf '  %s\n' $offenders` is unquoted: it word-splits on spaces inside
filenames and glob-expands each path.

### 7.3 Phase 6 baseline gate HALTs unconditionally

Lines 1179–1183 use `grep -Fvxf <(printf '%s\n' "${EXCLUDED_PATHS[@]}")`. `-x` demands a
full-line exact match of absolute paths against relative porcelain output, so **nothing is
ever excluded**. Every dirty file is an offender and Phase 6 HALTs at line 1187 on the spec
and plan the code is explicitly trying to allow — a hard stop before the implementer runs.
Line 1205's claim that feature-folder files are excluded is false for the same reason.

Fix: same `-z` repo-relative treatment as §7.2, sharing one helper.

### 7.4 Trailing `[ -f … ] && cmd`

Lines 960–962, 1015–1017, 1089–1091, 1143–1145, 1261–1263 all end their block with
`[ -f … ] && mv …`. *Verified*: `bash -c 'set -e; [ -f /nonexistent ] && …'` exits 1. Each
fires on the codex-absent path that line 965 explicitly documents as supported, so all five
preflight gates read as failed phases precisely when Codex is legitimately skipped.

Fix: `if [ -f … ]; then … fi` at all five sites, plus line 874.

### 7.5 `codex_invoke` omits `--json`

Lines 454, 461, 485, 491 have no `--json`, while `parse_usage`'s codex branch (lines
599–612) requires JSONL and the canary at line 536 hard-requires the flag. Following the
canonical helper verbatim produces `usage_status=unavailable` on every Codex dispatch,
violating the completion criterion at line 1807. Only the two ad-hoc snippets at lines 58
and 864 get it right — and line 864 in turn drops `-c model_reasoning_effort`,
contradicting lines 168 and 474.

Fix: `--json` and explicit effort in all forms; `codex_invoke` becomes the only invocation
path.

### 7.6 `render_prompt`

- Lines 413–423 omit `$ROUND` and `$TEST_REPORT_PATH`, both required by `all-tests-runner`
  (line 2643) and `test-fixer` (lines 2687–2688). Those appendices render with the literal
  strings `$ROUND` and `$TEST_REPORT_PATH` in the prompt.
- Line 409 `text.index(end)` searches from position 0 rather than from `start`.
- No `try/except`: a missing or misnamed marker raises `ValueError`, python exits 1, and the
  **traceback becomes the prompt** piped into the CLI. Must raise a legible error naming the
  appendix.
- Line 426's bare `str.replace` has no word boundary. Safe for today's names but silently
  wrong if a `$ITERATION` / `$ITERATION_CAP` style pair is ever added; add a boundary-aware
  substitution.

### 7.7 `parse_usage`

- Lines 603–611: if no `turn.completed` record exists, `last` is `null` and every
  `$u.x // 0` yields 0, so the helper reports `usage_status=ok` with all zeros instead of
  `unavailable`. Silent misreporting.
- Line 716 passes a hardcoded `claude-opus-4-8` as `parse_usage`'s 4th argument — the id
  reported when the transcript JSON carries no model field. It becomes
  `"$(role_model "$role")"`. Note this is telemetry attribution, unrelated to model
  selection; strict pinning (§5.7) does not apply to it.
- Line 718 references `$STATUS`, which is **undefined anywhere in the document**. Under
  `set -u` the canonical usage example aborts. Define it.
- Line 602 `jq -s` slurps an entire JSONL transcript into memory; a 90-minute deep review
  can be large. Use a streaming form.
- Lines 574 and 644 explain the "never take the alphabetically first key" rule using
  haiku-vs-opus. With `fable` in play (`f` < `h` < `o` < `s`) the example needs updating,
  though the rule itself stands.

### 7.8 `validate_status`

- Lines 807, 814, 823, 831 use `\S`, a PCRE/GNU extension that is undefined in POSIX ERE.
- Lines 809 and 818 use `xargs` as a trim idiom: it interprets quotes and backslashes and
  dies on an unmatched quote in a `reason:` line. Replace with bash parameter expansion.
- `-F:` truncates any value containing a colon (`reason: cannot read /a:b`), and
  `awk '{print $2}'` truncates multi-word verdicts.
- Line 779 `[ "$rc" -ne 0 ]` with an empty `$rc` is `[: -ne: unary operator expected`.

### 7.9 Shell policy, xtrace, and helper persistence

The document prescribes `set -x` (lines 357–369) and never states an errexit policy, yet
helpers signal failure by return code (lines 524, 751, 782) and by `exit` (lines 339, 1194).

Decision: **`set -uo pipefail`, not `set -e`.** The orchestrator's entire model is
"branch on verdict", which requires inspecting return codes rather than dying on them.
State this once, explicitly.

- Lines 365–366 `export BASH_XTRACEFD`. *Verified*: fd 10 is not close-on-exec and the
  variable is exported, so every child bash inherits it and writes its own xtrace into
  `full_log.md`; the variable also leaks into the `claude`/`codex` subprocess environment.
  Do not export; close the fd at block end.
- Line 374: for Phase −1, xtrace goes to stderr — the same stream the Mode-1 classifier
  greps for `Usage:` / `unexpected argument` (lines 1374–1382). Orchestrator xtrace can be
  misread as a CLI usage error. Redirect Phase −1 xtrace to a temp file.
- **Bash functions do not persist across invocations.** Given the one-phase-per-invocation
  rule at line 90, every cookbook helper must be re-defined in every phase block. The
  document never says this. Provide the cookbook as a single paste-able block and state the
  requirement.
- Line 1774 `printf '%s' "$ENTRY" >>` emits no trailing newline, so the next append
  concatenates onto the same line and defeats the `grep '^## '` mining rule at line 1765.
  Use `printf '%s\n'`.
- Line 709's unlocked multi-line append to `RUN_LOG.md` is mitigated by line 878's
  serialisation but not enforced; make the ordering requirement explicit.
- Lines 48–49 use `|` as the sed delimiter while substituting paths, and `&` is
  sed-special in the replacement. The example also writes `$ITER` where the rest of the
  document uses `$ITERATION`. Since `render_prompt` is now the only substitution path, this
  example should be removed rather than fixed.

## 8. Design: long dispatch, contradictions, renames

### 8.1 Long-dispatch mechanism

The implementer (300–600 min), plan-writer (120 min) and deep Codex review (90 min) cannot
complete inside one Claude Code Bash call (hard cap 600 000 ms), yet line 90 forbids
splitting a phase.

Add `dispatch_detached` and `await_dispatch` helpers. `setsid` the CLI so it survives the
launching shell; the orchestrator polls in short, bounded Bash calls. This finally gives the
`.rc` files a reader (§7.1).

Restate the rule as **one *dispatch* per phase** — polling calls are not phase bundling.
Chosen over the harness-native background-Bash option because it works regardless of which
harness runs the orchestrator, and the document claims support for a Codex orchestrator at
line 147.

`timeout --kill-after=60s` so a CLI ignoring SIGTERM cannot hang a phase indefinitely.

#### Dispatch identity and control files

`dispatch_id` = `<phase>-iter<NN>-<role>`. It is **deterministic**, so a resuming
orchestrator can recompute it rather than having to discover it. All control files live
beside the transcript under `$FEATURE_FOLDER/transcripts/`:

| File | Written by | Content |
|---|---|---|
| `<id>.started` | launcher, **before** `setsid` | `dispatch_id`, ISO timestamp, `pid`, `pid_starttime`, `timeout_s`, resolved model |
| `<id>.pid` | launcher, after `setsid` | pid only, for cheap liveness checks |
| `<id>.rc` | wrapper, on exit | exit code, one integer |
| `<id>.json` / `.err` | the CLI | stdout / stderr |

**Atomic publication.** `.rc` and `.started` are written to `<name>.tmp` in the same
directory and `mv`'d into place — rename within a filesystem is atomic, so a poller never
observes a partial file. *Verified.* A poller that finds `.rc` must still validate it
matches `^[0-9]+$`; anything else is corruption, treated as failure.

**PID reuse.** A bare pid is not a safe liveness token across a crash — the pid may have
been recycled. `.started` records `pid_starttime`, field 22 of `/proc/<pid>/stat`
(*verified readable*). A pid is the same process only if it exists **and** its current
`starttime` equals the recorded value.

#### Resume decision table

An orchestrator resuming mid-phase reconstructs state from the control files plus
`RUN_LOG.md`. A `event=DISPATCH_STARTED` entry carrying `dispatch_id` is appended **before**
launch, so a crash between launch and completion still leaves a trace — the gap the reviewer
correctly identified, since resume logic at lines 1610–1619 reads only `RUN_LOG.md`.

| `.started` | `.rc` | Process check | State | Action |
|---|---|---|---|---|
| absent | absent | — | `NEVER_LAUNCHED` | dispatch fresh |
| present | absent | pid alive, starttime matches | `RUNNING` | resume polling; do **not** re-dispatch |
| present | absent | pid dead or starttime differs | `ORPHANED` | log `event=DISPATCH_ORPHANED`, re-dispatch |
| present | present, valid, `0` | — | `COMPLETED` | read STATUS, proceed |
| present | present, valid, `124` | — | `TIMED_OUT` | apply the existing Mode-2 policy |
| present | present, valid, other | — | `FAILED` | apply the existing failure-mode classifier |
| present | present, malformed | — | `CORRUPT` | treat as `FAILED`; surface the transcript path |
| absent | present | — | `INCONSISTENT` | HALT; indicates concurrent runs on one feature folder |

Re-dispatch after `ORPHANED` is safe only because every subagent writes its STATUS last and
atomically — the existing contract at line 65 — so a partially-written artifact from the
dead process cannot be mistaken for a completed one.

Required tests (§9 check 2): crash-and-resume for each of the eight rows, timeout escalation
to `--kill-after`, and PID-reuse rejection via a forged `pid_starttime`.

#### Write contract

`.started` / `.pid` / `.rc` and the transcript files must be added to the canonical
orchestrator write list. §3's non-goal above restates the narrow three-file list, which is
itself one of the three contradictory lists §8.4 resolves — line 21 already permits
capturing stdout/stderr under `transcripts/`. The single canonical list becomes:
`RUN_LOG.md`, `full_log.md`, `process-improvement-proposition.md`,
`transcripts/<id>.{json,err,rc,pid,started}`, and `mkdir -p`. Reading artifacts stays
forbidden; this widens only what the orchestrator may *write*.

### 8.2 Timeouts: one source of truth

Three-way disagreement today:

| Role | Cookbook code | Phase text | Timeout table |
|---|---|---|---|
| Reviewers | 20 min (445, 852, 864) | 40–60 min | 40–90 min |
| Plan writer | 20 min | **120 min** (1062) | **40 min** (1410) |
| Implementer | 20 min | **300 min** (1213) | **600 min** (1412) |

The cookbook value is what would actually run, silently capping every reviewer and the
implementer at 20 minutes.

A `$DISPATCH_TIMEOUT` variable alone would just relocate the ambiguity to its assignment
site. The resolution is an **executable `role_timeout()` lookup** (§5.2), with these
authoritative values. Where sources disagreed, the phase-text value wins: it is the most
specific statement of intent, whereas the 20-minute cookbook literals are an unvaried
copy-paste default and the table's 600 for the implementer is unexplained.

| Role | Minutes | Basis |
|---|---|---|
| `preflight-claude`, `preflight-codex` | 5 | unchanged (lines 933–934) |
| `context-discovery` | 15 | unchanged (line 992) |
| `spec-reviewer-claude`, `plan-reviewer-claude` | 40 | phase text |
| `spec-fixer`, `plan-fixer` | 40 | phase text |
| `spec-reviewer-codex`, `plan-reviewer-codex` | 60 | phase text 40, **raised** for `high` effort (§5.4) |
| `plan-writer` | 120 | phase text (line 1062), not the table's 40 |
| `implementer` | 300 | phase text (line 1213), not the table's 600 |
| `debugger` | 60 | unchanged (line 1225) |
| `code-reviewer-claude` | 60 | phase text |
| `code-reviewer-codex` | 120 | phase text 60, **raised** for `diff-aware` + `high` effort |
| `all-tests-runner`, `test-fixer` | 60 | unchanged |
| `finishing-branch` | 30 | unchanged (line 1330) |
| all 5 summarizers, `readiness-writer` | 20 | unchanged |

Grace period is uniform: `--kill-after=60s`. Every invocation form uses
`timeout --kill-after=60s "$(role_timeout "$role")m"`; no literal minute value survives
anywhere else in the document. §9 check 6 asserts the table matches `role_timeout` for all
24 roles, so this table cannot drift either.

The two raised values are the only intentional increases, and both follow from §5.4's
effort decision — high-effort reviewers are slower, so keeping the old ceilings would
convert the effort change into spurious Mode-2 timeouts.

### 8.3 Renames

`claude-opus-verdict.md` → `claude-verdict.md` and `claude-opus-findings.md` →
`claude-findings.md`. Symmetric with the already-vendor-scoped `codex-verdict.md`, and it
stops the filename asserting a model.

All 22 occurrences across 19 lines must change in one commit: 250, 252 (folder diagram);
718, 1484 (RUN_LOG examples); 1044, 1110, 1282 (orchestrator contracts); 1968, 1984
(spec-reviewer-claude); 1992, 2201, 2521 (STATUS `findings:` field values, validated at
line 796); 2192, 2194 (plan-reviewer-claude); 2512, 2514 (code-reviewer-claude); 2777,
2837, 2939 (the three summarizers, which read the verdict files).

`readiness-writer` (lines 3037–3052) reads only summaries and is **not** a consumer —
verified. The rename is not backward compatible for in-flight feature folders, since the
resume logic at lines 1610–1619 reads `status_path` values from `RUN_LOG.md`; no such
folders exist in this repository.

### 8.4 Contradictions to resolve

- **`preflight-codex` contradicts itself.** Its preamble (line 1859) forbids reading
  `~/.codex/skills` or any skill directory; line 1881 makes its sole task "report LOADED if
  the skill's directory or SKILL.md file exists". Since Phase 1 is the harshest gate in the
  document (Mode 0 HALTs unconditionally at line 911; Modes 1–5 demand an interactive
  `[y/N]` at line 939), an untrustworthy verdict here is serious. Resolve by narrowing the
  preamble: it forbids *loading or executing* skills, and a directory **existence** check
  is explicitly permitted for this one appendix. Reword both sides.
- **`context7` is required by four roles and probed by nothing.** It is an MCP server, not
  a skill, so it is absent from both required-skill lists (lines 916–928) and from both
  preflight appendices, yet lines 2136, 2354, 2446 and 2694 require it. Add it to the
  canary; make absence a recorded warning that downgrades the requirement to best-effort
  rather than proceeding silently.
- **Three write-allow-lists** (lines 5, 23/26, 31, 1653) disagree on whether
  `process-improvement-proposition.md` is writable. State one list once and reference it.
- **Three transcript-naming schemes**: `<phase>-<iteration>-<role>.json` (299–300),
  `${phase}-iter${iter}-claude.json` (853), `preflight-iter00-claude.json` (933). Adopt
  one: `<phase>-iter<NN>-<vendor>.{json,err,rc,pid}`.
- **`IMPLEMENTATION_BASELINE` event is written single-line** (lines 1189–1200) while the
  grammar declared exhaustive at line 1467 and shown at 1540–1546 is a multi-line block.
  Block-parsing consumers at lines 2940 and 3052 cannot find `base_sha:`. Emit the
  multi-line form.
- **Wrong phase numbers**: lines 449, 460, 504, 889, 890, 891 label spec review as Phase 1
  (it is 3), plan review as Phase 3 (it is 5), and code review as Phase 6 (it is 7). The
  role table says "Phase-0 context discovery" (it is Phase 2) and "per Phase 4 run" for the
  implementer (it is Phase 6).
- **Row 165 is stale**: the implementation summarizer is marked `(folded)` with no model,
  but a live `summarizer-implementation` appendix exists at line 2884 and is dispatched at
  line 1236. Un-fold it.
- **Line 1632** forbids vendor failover but is silent on **model** failover. State
  explicitly that cross-class fallback (e.g. Fable → Opus) is not permitted; a rejected
  pinned id HALTs per §5.8.
- **Line 147** expects a possible Codex orchestrator, while line 1774 prescribes `Write` /
  `Bash` / `Glob` tool calls and lines 1642/1650 prescribe `Read` / `Edit` / `Write` —
  unimplementable for a Codex orchestrator. Resolve by stating that the orchestrator must
  provide those capabilities, describing them functionally rather than by Claude Code tool
  name.
- **Line 939's interactive `[y/N]` prompt** sits in an architecturally non-interactive
  pipeline, and line 941 makes EOF a HALT — so any headless run HALTs on a transient
  Phase-1 Codex hiccup. Add an explicit `CODEX_CONSENT` environment override for
  non-interactive runs.

## 9. Design: verification harness

The deliverable is a prompt, not code, so it ships with runnable checks. Inspection alone
has a demonstrated failure record on this exact document.

Two tiers, because they have different determinism and cost profiles. Only tier 1 is the
default runner.

#### Tier 1 — offline, deterministic, no network or credentials

1. **Extract-and-lint.** Not every fenced block is lintable: many are contextual snippets
   that reference `$FEATURE_FOLDER` and friends by design, so `shellcheck` would emit SC2154
   throughout and the signal would drown. Blocks are therefore **classified by a marker
   comment immediately above the fence**:
   - `<!-- lint: cookbook -->` — a complete, self-contained helper. Extracted into one
     canonical sourceable file and linted fully.
   - `<!-- lint: snippet -->` — illustrative. Gets `bash -n` (syntax) only, with a generated
     preamble declaring the orchestration variables so SC2154 is not raised.
   - Unmarked blocks fail the check. That forces a deliberate choice for every block and
     prevents a new block from silently escaping the linter.

   `shellcheck` is **absent on this machine** (verified; apt candidate `0.11.0-2`). It is a
   documented prerequisite (`apt-get install shellcheck`, minimum 0.10). When missing the
   runner reports the lint check as `SKIP` with the install command, never `PASS` — a skip
   must be visible in the summary and must not be counted as success.

2. **Cookbook unit tests** — `dirty_tree_check` against fixtures covering paths with spaces,
   renames, copies, unset allow-list vars, and out-of-target entries; the boundary-aware
   directory match from §6.2; `parse_usage` against fixture JSON including the missing
   `turn.completed` case; `EPOCHREALTIME` millisecond math; the §8.1 resume decision table,
   all eight rows, including forged `pid_starttime`.

3. **Marker integrity** — every `<!-- BEGIN: X -->` has a matching `END`, and every appendix
   name referenced in orchestrator text exists as a marker pair. Directly prevents the §7.1
   Phase-7 bug class.

4. **Variable coverage** — every `$VAR` appearing in any appendix body is present in
   `render_prompt`'s substitution list. Directly prevents the §7.6 missing-`$ROUND` bug
   class.

5. **Fake-CLI integration** — stub `claude` and `codex` executables placed first on `PATH`,
   emitting canned JSON/JSONL with configurable exit code and delay. This exercises the
   riskiest new behavior without spending a token: detached dispatch, `--add-dir` selection,
   `timeout` escalation to `--kill-after`, parallel `.rc` collection under
   `dispatch_reviewers_parallel`, and crash-and-resume. Without this tier-1 check, none of
   §8.1 is covered by anything but inspection.

6. **Table/function agreement** — parse the §5.3 role table out of the document and assert
   it matches `role_model`, `role_effort`, and `role_timeout` for all 24 dispatched roles.
   Asserting against the *document* rather than a hand-maintained fixture is what makes the
   table and the functions a single source of truth instead of two that drift.

#### Tier 2 — live model probe, run on demand

Each pinned id in §5.3 is accepted by its CLI (§5.8). This is **excluded from the default
runner**: it needs valid credentials and network, and it is billable, so including it would
make ordinary runs nondeterministic and non-free. It is invoked explicitly
(`tests/run.sh --live`) and is the check that resolves the `claude-opus-5` literal question
in §11.

#### Canary additions

Tools introduced by this rework join `canary_preflight` alongside §6.6's list: `setsid`,
`realpath`, and `flock` (all verified present). `shellcheck` is a test-time prerequisite
only, not a runtime one, so it stays out of the canary.

Checks 3, 4 and 6 are the highest-value: each mechanically prevents a class of drift that
inspection demonstrably failed to catch on this document.

## 10. Success criteria

1. `tests/` runner passes: all five checks green.
2. `role_model` returns the §5.3 value for all 24 dispatched roles (the orchestrator row
   has no model); no dispatch site invokes a CLI without setting `$CLAUDE_MODEL` (or the
   codex equivalent) from it.
3. No occurrence of `claude-opus-4-8`, `claude-sonnet-4-6`, `gpt-5.5`, `gpt-5.4`,
   `gpt-5.3-codex`, or `gpt-5.2` anywhere except §4's environment inventory. Strict pinning
   (§5.7) leaves no fallback chain for them to live in. No occurrence of the word
   "fallback" applied to model selection.
4. No occurrence of `/home/worker`, `repos/GCP`, `claude-opus-verdict.md`, or
   `claude-opus-findings.md`.
5. Grep for each fixed defect confirms the pattern is gone: `date +%s%3N`,
   `local t0=`, trailing `] && mv`, `grep -Fvxf`, `awk '{print $2}'` on porcelain,
   `codex_invoke` without `--json`, `export BASH_XTRACEFD`, `\S` in a `grep -E`.
6. `$CLAUDE_MODEL`, `$STATUS`, `$codex_available`, `$ROUND`, `$TEST_REPORT_PATH` each have
   a definition or substitution entry.
7. Each timeout value appears in exactly one authoritative table.
8. **Fake-CLI end-to-end** (§9 check 5) runs a scratch target repo through Phase 2 `READY`
   *and* through the new machinery that a Phase-2 stop would never reach:
   - `develop_it_git_sha` matches **this** repo's HEAD, not the target's; `develop_it_dirty`
     varies correctly with a deliberate edit to the process file.
   - `duration_ms` is a plausible 13-digit value.
   - A detached dispatch is launched, polled, and collected; `.rc` is read.
   - A stub that ignores SIGTERM is killed by `--kill-after`, yielding rc 124 → `TIMED_OUT`.
   - The orchestrator is killed mid-dispatch and resumed: `RUNNING` resumes polling without
     re-dispatching, and `ORPHANED` re-dispatches exactly once.
   - Parallel reviewer dispatch reports a **failing** stub as failed — the §7.1 regression.
   - `--add-dir` is present when `$FEATURE_FOLDER` is outside `$REPO_ROOT` and absent when
     inside.
   - `role_timeout` and `role_model` values reach the actual argv (asserted by a stub that
     records its own arguments).
9. A live smoke run (tier 2) on one real dispatch confirms the pinned ids are accepted and
   that Codex received `-m` — verified from the recorded argv, not assumed.

## 11. Risks

- **Scale.** ~118 distinct lines change, ~40 of them semantic rather than mechanical. The
  §9 checks and the §10 grep criteria are the mitigation.
- **Renames are all-or-nothing.** §8.3's 22 occurrences must land in one commit or the
  summarizers silently read nothing.
- **Cost.** §5.4 raises reviewer effort deliberately. Watch the first real run's
  `RUN_LOG.md` token totals before trusting the setting on a large spec.
- **Unverifiable-until-run items.** The exact accepted form of `claude-opus-5` and whether
  `gpt-5.6-sol` honours the `medium`/`high` effort tokens are settled by §5.8's probe, not
  by this document.
- **The detach-and-poll rewrite touches the resumability contract** (lines 1610–1619),
  which reads `RUN_LOG.md` to locate the last completed step. §8.1's `DISPATCH_STARTED`
  event and eight-row decision table are the mitigation; the residual risk is a state the
  table does not enumerate, which is why all eight rows are tested rather than sampled.
- **Two live runs on one feature folder would corrupt state.** §8.1's `INCONSISTENT` row
  detects it after the fact but nothing prevents it. `flock` on the feature folder is
  available (verified present) and should be considered during planning; it is not specified
  here because single-operator use makes it low-probability.

## 12. Ordering constraints

Not a plan, but three sequencing facts the plan must respect:

1. **The §9 tier-1 harness lands first.** Checks 3, 4 and 6 must exist before the cookbook
   and appendix edits, so they catch regressions introduced by those edits rather than being
   written to match whatever the edits produced. Check 5's fake-CLI stubs must exist before
   §8.1, since detached dispatch has no other means of verification.
2. **The §8.3 renames are one atomic change.** All 22 occurrences, or the three summarizers
   silently read nothing.
3. **§5.2's three lookups precede every dispatch-site edit.** Dispatch sites are rewritten
   to call `role_model`, `role_effort` and `role_timeout`, so the functions must exist first;
   otherwise the edits have nothing to call and `$CLAUDE_MODEL` stays undefined, which is the
   original defect.
4. **§7.2's NUL parser precedes §7.3.** Both the dirty-tree gate and the Phase 6 baseline
   share one helper; writing them separately would reintroduce the divergence that let the
   same bug appear twice.
5. **`shellcheck` install precedes check 1 being meaningful.** Not a blocker for other work —
   the runner reports `SKIP` — but the lint check gives no signal until it is present.

Everything else is independent. §6 (environment), §7 (cookbook), §8.1–8.2 (dispatch), and
§8.4 (contradictions) touch largely disjoint line ranges and can proceed in any order.
