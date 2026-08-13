# Develop-It Process Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revise the single normative `develop-it-prompt.md` so every future run uses the reviewed schema-v2 orchestration protocol, with deterministic offline verification and no changes to historical feature artifacts.

**Architecture:** Keep the prompt as the normative and distributable source, with shell/Python runtime helpers embedded in lint-marked Markdown blocks and extracted atomically into each new feature folder. Extend the existing Markdown-driven test harness so it validates the prompt's registries, executes the embedded helpers against fake CLIs, and proves recovery, convergence, reconciliation, documentation, finalization, and readiness behavior before the process documentation is updated.

**Tech Stack:** Markdown, Bash 4+, Python 3 standard library, Git, existing fake `claude`/`codex` command-line fixtures, existing `tests/run.sh` offline harness.

**Spec:** `docs/superpowers/specs/2026-08-13-develop-it-process-improvements-design.md`

## Global Constraints

- Execute Tasks 1 through 16 in strict numerical order. Start Task N+1 only after Task N's focused tests and the full offline suite pass.
- Change the process repository only. Do not edit, migrate, backfill, rename, or delete anything under `/home/oleks/repos/prism/docs/superpowers/specs/`.
- Treat `develop-it-prompt.md` as the normative source. Generated runtime files are disposable derivatives and are never committed.
- Apply schema v2 only to future runs. No compatibility reader or migration path for historical v1 artifacts is required.
- Preserve supported environments: Bash 4+, GNU coreutils, Python 3 standard library, Git, Claude CLI, and Codex CLI. Add no package dependency.
- Keep generated runtime, leases, snapshots, locks, and pending proposition metadata below `$FEATURE_FOLDER/.orchestration/`; keep `RUN_LOG.md` and transcripts at the feature-folder root, attempt artifacts below their phase directory, and durable SDD custody below `$FEATURE_FOLDER/6-implementation/sdd/`.
- Never push, create a pull request, merge, delete branches, or alter global Git configuration. Phase 10 may create one local commit only after acquiring its orchestrator finalization lease.
- The parent orchestrator is the sole writer of `$FEATURE_FOLDER/RUN_LOG.md`; subprocesses return results through attempt-scoped files.
- A mutating role may run only while it owns the single write lease. Read-only roles may run concurrently only when their contracts and lease state permit it.
- Preserve the reviewed policy constants exactly: schema `2`; prelaunch correction `1`; publication retry `1`; transient retry `1`; continuation `3`; review iterations `10`; document fixer batch `8`; documentation fixes `2`; artifact warning `10%`; divergence rounds `2`; long-role headroom `60` minutes.
- Preserve all recovery-matrix IDs `RM01` through `RM12`, all requirement IDs `R01` through `R24`, and all 30 acceptance criteria.
- For Markdown findings, derive stable location identity from AST heading breadcrumb, repeated-sibling occurrence, block kind, and anchor/content fingerprint. Line numbers are diagnostic evidence only.
- A final fixer pass is never accepted without a subsequent reviewer verdict.
- Every task uses red/green tests, records exact command output in the implementation session, and ends with its own local commit.

## File Structure and Responsibilities

| Path | Action | Responsibility |
|---|---|---|
| `develop-it-prompt.md` | Modify | Normative schema-v2 process, registries, embedded runtime, role appendices, phase algorithms, and audit/readiness contracts. |
| `tests/lib/extract.py` | Modify | Parse named Markdown registries and lint-marked runtime blocks into deterministic TSV/script test inputs. |
| `tests/lib/assert.sh` | Modify | Shared shell assertions plus schema-v2 fixture initialization and contract-loading helpers. |
| `tests/lib/verdicts.py` | Modify | Compare role verdict declarations in the consolidated registry and appendices. |
| `tests/lib/v2_fixtures.sh` | Create | Build isolated schema-v2 status, checkpoint, lease, event, and repository fixtures for offline tests. |
| `tests/fakebin/claude` | Modify | Deterministic Claude attempt simulator with argv, cwd, environment, delay, exit, and publication modes. |
| `tests/fakebin/codex` | Modify | Deterministic Codex attempt simulator with the same observable modes. |
| `tests/check_01_lint.sh` | Modify | Enforce marked executable blocks and shell/Python syntax for every extracted runtime file. |
| `tests/check_02_markers.sh` | Modify | Enforce one complete appendix contract per executable role and prohibit retired role markers. |
| `tests/check_03_varcoverage.sh` | Modify | Enforce definition/use coverage for new runtime, attempt, lease, and checkpoint variables. |
| `tests/check_04_table.sh` | Modify | Validate every consolidated role-contract field and reject unknown roles/values. |
| `tests/check_05_contract.sh` | Modify | Validate global invariants, phase order, IDs, paths, and absence of superseded behavior. |
| `tests/check_06_cookbook.sh` | Modify | Unit-test extracted registries and embedded runtime helpers. |
| `tests/check_07_fakecli.sh` | Modify | Integration-test actual fake CLI launches, publication, timing, and attempt isolation. |
| `tests/check_08_launcher.sh` | Modify only if an assertion changes | Preserve launcher boundary: export inputs, optional tests, interactive handoff; no orchestration logic. |
| `tests/check_09_recovery.sh` | Create | Table-driven coverage of every `RM01`–`RM12` recovery row and each relevant mutation-state branch. |
| `tests/check_10_process_v2.sh` | Create | End-to-end offline assertions for extraction, dispatch, phases, checkpoints, convergence, docs, finalization, and audit. |
| `tests/check_11_reconciliation.sh` | Create | Event-stream and final-proposition reconciliation, contradiction, and readiness tests. |
| `tests/run.sh` | Modify | Classify only `check_90_*` as opt-in live checks; run `check_09_*` offline. |
| `README.md` | Modify in Task 16 | User-facing schema-v2 phase summary and invocation behavior. |
| `RUNBOOK.md` | Modify in Task 16 | Operational recovery, lease, finalization, audit, and readiness guidance. |

`develop-it.sh` is intentionally not in the modification set. Its launcher-only responsibility already matches the specification; `tests/check_08_launcher.sh` must continue proving that boundary.

## Interfaces Used Across Tasks

The following names are fixed for the whole implementation. Later tasks must consume them exactly.

```text
tests/lib/extract.py commands:
  roles       -> tab-separated full role-contract rows
  policies    -> policy_name<TAB>value
  events      -> event_type<TAB>required_fields<TAB>proposition_required
  recovery    -> matrix_id<TAB>classification<TAB>mutation_state<TAB>action
  cookbook    -> concatenated lint-marked cookbook blocks
  publisher   -> generated publish-status Python source
  snippets    -> syntax-checkable lint-marked snippets
  unmarked    -> executable-looking unmarked blocks

embedded runtime functions:
  policy_value NAME
  role_contract_field ROLE FIELD
  event_required_fields EVENT_TYPE
  recovery_action CLASSIFICATION MUTATION_STATE
  bootstrap_runtime
  allocate_attempt PHASE ITERATION ROLE
  invoke_vendor ROLE PROMPT_FILE STDOUT_FILE STDERR_FILE
  classify_attempt ROLE EXIT_CODE STDOUT_FILE STDERR_FILE STATUS_FILE
  inspect_mutation_state ROLE
  record_event EVENT_TYPE KEY=VALUE...
  acquire_write_lease OWNER AUTHORITY DISPATCH_ID DECLARED_PATH...
  release_write_lease OWNER
  dispatch_attempt PHASE ITERATION ROLE
  dispatch_parallel PHASE ITERATION ROLE...
  ingest_findings ROLE STATUS_FILE OUTPUT_JSONL
  reconcile_propositions
  audit_run_state

attempt identity:
  logical_dispatch_id=p<phase-token>-i<two-digit-iteration>-<role>
  dispatch_id=<logical_dispatch_id>-a<two-digit-attempt>
  phase token for Phase -1 is m1; every other phase token is two digits
  non-iterative phases use iteration 00

generated runtime:
  $FEATURE_FOLDER/.orchestration/runtime/develop-it-runtime.sh
  $FEATURE_FOLDER/.orchestration/runtime/role-contracts.tsv
  $FEATURE_FOLDER/.orchestration/runtime/policy.tsv
  $FEATURE_FOLDER/.orchestration/runtime/publish-status
  $FEATURE_FOLDER/.orchestration/runtime/manifest.sha256
```

---

### Task 1: Establish Schema-v2 Contract Fixtures

**Files:**
- Modify: `develop-it-prompt.md` (Inputs, Process Schema, Global Invariants, and new Process Policy Registry)
- Modify: `tests/lib/extract.py`
- Modify: `tests/lib/assert.sh`
- Create: `tests/lib/v2_fixtures.sh`
- Create: `tests/check_10_process_v2.sh`
- Modify: `tests/run.sh`
- Test: `tests/check_00_selftest.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: current `PROCESS_DOC`, `BUILD`, `extract.py`, and assertion conventions.
- Produces: `extract.py policies`, `extract.py recovery`, `extract.py events`; `init_v2_fixture`; the fixed schema/version/policy contract used by all later tasks.

- [ ] **Step 1: Add a failing schema-v2 contract check**

Create `tests/check_10_process_v2.sh` with these first assertions:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/assert.sh"

assert_contains '| process_schema_version | 2 |' "$PROCESS_DOC" "schema v2 policy"
assert_contains '| prelaunch_correction_cap | 1 |' "$PROCESS_DOC" "prelaunch cap"
assert_contains '| publication_retry_cap | 1 |' "$PROCESS_DOC" "publication cap"
assert_contains '| transient_retry_cap | 1 |' "$PROCESS_DOC" "transient cap"
assert_contains '| continuation_cap | 3 |' "$PROCESS_DOC" "continuation cap"
assert_contains '| review_iteration_cap | 10 |' "$PROCESS_DOC" "review cap"
assert_contains '| document_fixer_batch_size | 8 |' "$PROCESS_DOC" "batch cap"
assert_contains '| documentation_fix_cap | 2 |' "$PROCESS_DOC" "documentation cap"
assert_contains '| artifact_growth_warning_pct | 10 |' "$PROCESS_DOC" "growth threshold"
assert_contains '| divergent_round_cap | 2 |' "$PROCESS_DOC" "divergence cap"
assert_contains '| long_role_headroom_threshold_minutes | 60 |' "$PROCESS_DOC" "long-role threshold"

python3 "$REPO_TOP/tests/lib/extract.py" policies > "$BUILD/policies.tsv"
assert_line_count 12 "$BUILD/policies.tsv" "policy header plus 11 rows"
finish
```

- [ ] **Step 2: Run the focused check and observe the missing registry**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit with a failed `schema v2 policy` assertion.

- [ ] **Step 3: Add generic named-table extraction**

Extend `tests/lib/extract.py` with a strict heading-to-columns map and expose the three new commands:

```python
TABLE_SPECS = {
    "policies": ("Process Policy Registry", ("policy", "value", "meaning")),
    "events": ("Event Contract Registry", ("event_type", "required_fields", "proposition_required")),
    "recovery": (
        "Recovery Matrix",
        ("matrix_id", "classification", "mutation_state", "action"),
    ),
}

def normalized_header(cell: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", cell.strip().lower()).strip("_")

def section_after_heading(text: str, heading: str) -> str:
    pattern = re.compile(rf"^(?P<level>#+)\s+{re.escape(heading)}\s*$", re.MULTILINE)
    match = pattern.search(text)
    if match is None:
        raise SystemExit(f"missing heading: {heading}")
    level = len(match.group("level"))
    tail = text[match.end():]
    next_heading = re.search(rf"^#{{1,{level}}}\s+", tail, re.MULTILINE)
    return tail if next_heading is None else tail[:next_heading.start()]

def markdown_rows(section: str) -> list[list[str]]:
    rows = []
    for raw in section.splitlines():
        if not raw.startswith("|"):
            if rows:
                break
            continue
        rows.append([cell.strip().strip("`") for cell in raw.strip().strip("|").split("|")])
    if len(rows) < 3:
        raise SystemExit("table has no data rows")
    if any(set(cell) - set("-: ") for cell in rows[1]):
        raise SystemExit("table separator is malformed")
    return rows

def named_markdown_table(text: str, heading: str, columns: tuple[str, ...]) -> list[list[str]]:
    section = section_after_heading(text, heading)
    rows = markdown_rows(section)
    actual = tuple(normalized_header(cell) for cell in rows[0])
    if actual != columns:
        raise SystemExit(f"{heading}: expected columns {columns}, got {actual}")
    for row in rows[2:]:
        if len(row) != len(columns) or any("\t" in cell or "\n" in cell for cell in row):
            raise SystemExit(f"{heading}: invalid row {row}")
    return [list(columns), *rows[2:]]
```

Reject duplicate keys before emitting header plus data rows as TSV to stdout and the matching file below `$BUILD`.

- [ ] **Step 4: Add reusable schema-v2 fixture initialization**

First extend `tests/lib/assert.sh` with the exact helpers used by schema-v2 checks:

```bash
assert_contains() { local s=$1 f=$2 m=$3; grep -Fq -- "$s" "$f" && _ok "$m" || _fail "$m"; }
assert_line_count() { local n=$1 f=$2 m=$3; assert_eq "$n" "$(wc -l < "$f" | tr -d ' ')" "$m"; }
assert_exists() { local p=$1 m=$2; [ -e "$p" ] && _ok "$m" || _fail "$m"; }
assert_not_exists() { local p=$1 m=$2; [ ! -e "$p" ] && _ok "$m" || _fail "$m"; }
assert_glob_count() {
  local expected=$1 pattern=$2 m=$3 actual
  actual=$(compgen -G "$pattern" | wc -l | tr -d ' ')
  assert_eq "$expected" "$actual" "$m"
}
```

Create `tests/lib/v2_fixtures.sh` with this public entry point and directory contract:

```bash
init_v2_fixture() {
  init_fixture_env
  export ORCHESTRATION_DIR="$FEATURE_FOLDER/.orchestration"
  export RUNTIME_DIR="$ORCHESTRATION_DIR/runtime"
  export SDD_DIR="$FEATURE_FOLDER/6-implementation/sdd"
  export RUN_LOG="$FEATURE_FOLDER/RUN_LOG.md"
  export LEASE_FILE="$ORCHESTRATION_DIR/write-lease.json"
  export TRANSCRIPTS_DIR="$FEATURE_FOLDER/transcripts"
  mkdir -p "$ORCHESTRATION_DIR/snapshots" "$SDD_DIR" "$TRANSCRIPTS_DIR" "$REPO_ROOT"
  : > "$RUN_LOG"
}
```

Source this library from `tests/check_10_process_v2.sh` and assert all paths remain under `$FEATURE_FOLDER` except `$REPO_ROOT`.

- [ ] **Step 5: Add the normative schema and policy registry**

In `develop-it-prompt.md`, state that schema v2 applies to newly created runs only and add this exact registry:

```markdown
| policy | value | meaning |
|---|---:|---|
| process_schema_version | 2 | Schema for new RUN_LOG, STATUS, checkpoint, and event records |
| prelaunch_correction_cap | 1 | Automatic correction after an input/render/prelaunch defect |
| publication_retry_cap | 1 | Cheap retry after proven STATUS publication loss |
| transient_retry_cap | 1 | Fresh redispatch when a transient attempt produced no mutation |
| continuation_cap | 3 | Continuations after durable partial progress for one logical role invocation |
| review_iteration_cap | 10 | Hard cap for a review gate |
| document_fixer_batch_size | 8 | Maximum assigned findings in one document-fixer batch |
| documentation_fix_cap | 2 | Maximum documentation self-correction rounds |
| artifact_growth_warning_pct | 10 | Per-fix net growth contributing to divergence detection |
| divergent_round_cap | 2 | Consecutive divergent rounds before automatic fixing stops |
| long_role_headroom_threshold_minutes | 60 | Timeout threshold requiring a just-in-time vendor liveness/headroom probe |
```

Define `policy_value NAME` to require exactly one registry row, print only its value, and fail with `POLICY_UNKNOWN:<name>` or `POLICY_DUPLICATE:<name>`.

- [ ] **Step 6: Make offline/live test selection unambiguous**

Change `tests/run.sh` so only `check_90_*` is skipped without `--live`:

```bash
case "$name" in
  check_90_*) is_live=1 ;;
  *)          is_live=0 ;;
esac
```

This guarantees `check_09_recovery.sh`, when created, is part of the normal offline suite.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_00_selftest.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; `check_90_live_models.sh` is the only skipped check.

- [ ] **Step 8: Commit the contract baseline**

```bash
git add develop-it-prompt.md tests/lib/extract.py tests/lib/assert.sh tests/lib/v2_fixtures.sh tests/check_10_process_v2.sh tests/run.sh
git commit -m "test: establish process schema v2 contracts"
```

### Task 2: Consolidate Role and Policy Registries

**Files:**
- Modify: `develop-it-prompt.md` (Models and Reasoning Effort, Skill Selection, Role Model Lookup, every role appendix header)
- Modify: `tests/lib/extract.py`
- Modify: `tests/lib/assert.sh`
- Modify: `tests/lib/verdicts.py`
- Modify: `tests/check_02_markers.sh`
- Modify: `tests/check_03_varcoverage.sh`
- Modify: `tests/check_04_table.sh`
- Modify: `tests/check_06_cookbook.sh`
- Test: `tests/check_02_markers.sh`, `tests/check_04_table.sh`, `tests/check_06_cookbook.sh`

**Interfaces:**
- Consumes: named-table extraction and schema-v2 policy lookup from Task 1.
- Produces: the registry-derived helpers named in §6.2, `render_prompt --check ROLE`, and `init_orchestration_vars`, backed by one 16-column role registry; generated `role-contracts.tsv`; no `finishing-branch` role.

- [ ] **Step 1: Make the role-table test require the complete contract**

Change `tests/check_04_table.sh` to require this header, reject duplicate roles, and reject empty required fields:

```text
role vendor model effort timeout_minutes mutates long_running may_spawn_children required_inputs optional_inputs status_template outputs verdicts required_status_fields checkpoint_kind phases
```

Add these column-aware helpers to `tests/lib/assert.sh`:

```bash
tsv_column() { awk -F '\t' -v name="$2" 'NR==1 { for(i=1;i<=NF;i++) if($i==name){print i; exit} }' "$1"; }
tsv_value() {
  local file=$1 key_column=$2 key=$3 value_column=$4 kc vc
  kc=$(tsv_column "$file" "$key_column"); vc=$(tsv_column "$file" "$value_column")
  awk -F '\t' -v kc="$kc" -v key="$key" -v vc="$vc" '$kc==key { print $vc }' "$file"
}
assert_tsv_key() { local f=$1 c=$2 k=$3; [ -n "$(tsv_value "$f" "$c" "$k" "$c")" ] && _ok "$k exists" || _fail "$k exists"; }
assert_tsv_missing_key() { local f=$1 c=$2 k=$3; [ -z "$(tsv_value "$f" "$c" "$k" "$c")" ] && _ok "$k absent" || _fail "$k absent"; }
assert_tsv_field() { local f=$1 k=$2 c=$3 v=$4; assert_eq "$v" "$(tsv_value "$f" role "$k" "$c")" "$k $c"; }
```

Assert these deltas and counts explicitly:

```bash
assert_tsv_key "$BUILD/roles.tsv" role implementation-fixer
assert_tsv_key "$BUILD/roles.tsv" role documentation-writer
assert_tsv_missing_key "$BUILD/roles.tsv" role finishing-branch
assert_tsv_field "$BUILD/roles.tsv" impl-worker status_template none
assert_tsv_field "$BUILD/roles.tsv" impl-worker phases child
assert_eq 25 "$(tail -n +2 "$BUILD/roles.tsv" | wc -l | tr -d ' ')" "25 registry rows including child-only impl-worker"
assert_eq 24 "$(awk -F '\t' 'NR>1 && $16 != "child" {n++} END {print n+0}' "$BUILD/roles.tsv")" "24 top-level dispatched roles"
```

- [ ] **Step 2: Run the role checks and observe the legacy schema**

Run: `bash tests/check_04_table.sh && bash tests/check_02_markers.sh`

Expected: non-zero exit because the existing role table has only model-selection columns and still contains `finishing-branch`.

- [ ] **Step 3: Replace split declarations with one full registry**

In `develop-it-prompt.md`, create one row for every top-level dispatched role using the exact header from Step 1. Preserve each existing vendor/model/effort/timeout assignment, remove `finishing-branch`, and add the two new top-level roles with these pinned assignments and contracts:

```markdown
| implementation-fixer | claude | claude-opus-5 | — | 60 | yes | yes | no | accepted_plan;reviewed_revision;finding_ids;write_lease | run_log;relevant_artifacts | `$PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/STATUS.md` | changed_paths;progress.jsonl | DONE;PARTIAL;BLOCKED | common_v2;changed_paths;finding_dispositions | implementation | 7 |
| documentation-writer | claude | claude-sonnet-5 | — | 60 | yes | yes | no | final_diff;accepted_spec;accepted_plan;implementation_summary;test_summary;review_summary;decisions;exclusions;followups;write_lease | docs_inventory;run_log | `$PHASE_DIR/$ITERATION/attempts/$DISPATCH_ID/STATUS.md` | uat.md;planned-vs-realized.md;documentation-validation.md;progress.jsonl | DONE;PARTIAL;BLOCKED | common_v2;changed_paths;documentation_validation | document | 9 |
```

Keep `impl-worker` in the same registry as an explicitly child-only contract with `status_template=none`, `phases=child`, and `may_spawn_children=no`; it reports through its parent implementer's child-checkpoint protocol and never receives a top-level dispatch ID. All other rows use semicolon-delimited multi-value cells and checkpoint kind `none`, `review`, `document`, or `implementation`.

- [ ] **Step 4: Generate and query the registry**

Update `extract.py roles` to emit all 16 columns in source order. Replace per-field shell case statements with:

```bash
role_contract_field() {
  local role=$1 field=$2
  awk -F '\t' -v role="$role" -v field="$field" '
    NR==1 { for (i=1; i<=NF; i++) col[$i]=i; next }
    $1==role { count++; value=$col[field] }
    END {
      if (!(field in col)) exit 42
      if (count != 1) exit 43
      print value
    }
  ' "$ROLE_CONTRACTS_PATH"
}
```

Map exit `42` to `ROLE_FIELD_UNKNOWN` and `43` to `ROLE_UNKNOWN_OR_DUPLICATE` at the caller. Provide the complete §6.2 wrapper surface—`role_vendor`, `role_model`, `role_effort`, `role_timeout`, `role_mutates`, `role_may_spawn_children`, `role_required_inputs`, `role_optional_defaults`, `role_status_path`, `role_outputs`, `role_verdicts`, `role_required_status_fields`, `role_checkpoint_kind`, and `role_phases`—as thin calls to this lookup. Materialize `long_running=yes` when timeout or child behavior meets the registry rule, and reject drift between the materialized value and its inputs.

- [ ] **Step 5: Validate rendering and reconstruct durable inputs**

Implement `render_prompt --check ROLE` to print missing required inputs, populated `KEY=default` optional inputs, resolved output/STATUS paths, unsupported phase, and unresolved appendix variables without invoking a vendor. Implement `init_orchestration_vars` to reconstruct the accepted spec path/revision, plan path/revision, implementation baseline/final SHA, applicable optional skills, active finding paths, debugger/reverification inputs, continuation/checkpoint paths, declared foreign changes/commits, context7 policy, and vendor availability/proven state from validated upstream STATUS/events at the start of every phase shell. A missing durable input returns `PRELAUNCH_FAILED:<contract-name>` and is never reclassified as dirty-tree or vendor failure.

- [ ] **Step 6: Align appendix and verdict validation**

Update every executable role appendix to declare `Inputs`, `Outputs`, `Allowed verdicts`, `Required status fields`, `Checkpoint kind`, and `Phases` exactly as its table row. Add complete appendices for `implementation-fixer` and `documentation-writer`; delete the `finishing-branch` appendix. Update `tests/lib/verdicts.py` to compare normalized semicolon-delimited sets and report both the registry and appendix values on drift.

- [ ] **Step 7: Extend focused negative tests**

In `tests/check_06_cookbook.sh`, generate temporary prompt copies with one duplicate role, one unknown role field, one empty required field, one appendix verdict mismatch, one missing render input, one illegal phase, one unresolved appendix variable, and one absent upstream contract during reconstruction. Assert respective failures:

```text
ROLE_UNKNOWN_OR_DUPLICATE
ROLE_FIELD_UNKNOWN
ROLE_CONTRACT_EMPTY
VERDICT_SCHEMA_DRIFT
RENDER_REQUIRED_INPUT_MISSING
ROLE_PHASE_UNSUPPORTED
RENDER_VARIABLE_UNRESOLVED
PRELAUNCH_FAILED
```

- [ ] **Step 8: Run focused and full verification**

Run:

```bash
bash tests/check_02_markers.sh
bash tests/check_03_varcoverage.sh
bash tests/check_04_table.sh
bash tests/check_06_cookbook.sh
bash tests/run.sh
```

Expected: all commands pass and no extracted contract contains `finishing-branch`.

- [ ] **Step 9: Commit the registry consolidation**

```bash
git add develop-it-prompt.md tests/lib/extract.py tests/lib/assert.sh tests/lib/verdicts.py tests/check_02_markers.sh tests/check_03_varcoverage.sh tests/check_04_table.sh tests/check_06_cookbook.sh
git commit -m "refactor: consolidate orchestration role contracts"
```

### Task 3: Extract the Embedded Runtime Atomically

**Files:**
- Modify: `develop-it-prompt.md` (Phase -1, Runtime Cookbook, Runtime Extraction Contract)
- Modify: `tests/check_01_lint.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_01_lint.sh`, `tests/check_06_cookbook.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: the registries and lookup functions from Tasks 1–2.
- Produces: `bootstrap_runtime`; an all-or-nothing runtime directory containing the five specified files and a verified SHA-256 manifest.

- [ ] **Step 1: Add failing extraction and interruption cases**

Add cases to `tests/check_10_process_v2.sh` which set `BOOTSTRAP_FAIL_AFTER=2`, run `bootstrap_runtime`, and assert:

```bash
assert_not_exists "$RUNTIME_DIR"
assert_glob_count 1 "$ORCHESTRATION_DIR/.runtime.tmp.*" "one interrupted staging directory"
assert_glob_count 0 "$ORCHESTRATION_DIR/.runtime.tmp.*/manifest.sha256" "manifest is written last"
```

Then create an orphan temporary directory, rerun bootstrap successfully, and assert the orphan is renamed below `$ORCHESTRATION_DIR/quarantine/`, the manifest records the current process-document SHA-256, and its runtime file entries validate with `sha256sum -c`.

- [ ] **Step 2: Run the extraction checks and observe missing behavior**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit because `bootstrap_runtime` and atomic staging do not exist.

- [ ] **Step 3: Mark every runtime block and lint every generated file**

Keep the existing Bash cookbook markers and add one explicit publisher marker:

````markdown
<!-- lint: cookbook -->
```bash
# definitions contributing to develop-it-runtime.sh
```

<!-- lint: publisher -->
```python
# complete publish-status program
```
````

Extend extraction with:

```python
MARKER = re.compile(r"^[ \t]*<!--\s*lint:\s*(cookbook|snippet|publisher)\s*-->\s*$")
FENCE_OPEN = re.compile(r"^([ \t]*)```(bash|python)[ \t]*$")

def cmd_publisher() -> int:
    matches = [(line, body) for kind, language, line, body in blocks()
               if kind == "publisher" and language == "python"]
    if len(matches) != 1:
        raise SystemExit(f"expected one publisher block, found {len(matches)}")
    source = "\n".join(matches[0][1]) + "\n"
    (BUILD / "publish-status").write_text(source)
    sys.stdout.write(source)
    return 0
```

Change `blocks()` to yield `(kind, language, start_line, body)`. `extract.py cookbook` concatenates only Bash cookbook blocks into `develop-it-runtime.sh`; `extract.py publisher` emits the one complete program. Teach `tests/check_01_lint.sh` to run `bash -n` on the cookbook output and `python3 -m py_compile` on publisher output. Reject zero/multiple publisher blocks and executable-looking unmarked Bash/Python blocks.

- [ ] **Step 4: Implement staged runtime construction**

Implement `bootstrap_runtime` with these exact state transitions:

```bash
tmp="$ORCHESTRATION_DIR/.runtime.tmp.$BOOTSTRAP_ATTEMPT"
final="$ORCHESTRATION_DIR/runtime"
quarantine="$ORCHESTRATION_DIR/quarantine"

# quarantine any pre-existing .runtime.tmp.* entry; never source it
# fail if $final exists but its manifest does not verify
# create $tmp with umask 077 and O_EXCL-equivalent mkdir semantics
# write develop-it-runtime.sh, role-contracts.tsv, policy.tsv, publish-status
# chmod 700 shell/Python entry points and 600 registries
# fsync every file, then write process-document SHA plus file hashes to manifest.sha256 last
# fsync $tmp, rename $tmp to $final without merging, fsync $ORCHESTRATION_DIR
```

Use Python's `os.open(..., O_CREAT | O_EXCL, 0o600)` and `os.fsync` for files. Perform the directory publication with Linux `renameat2(..., RENAME_NOREPLACE)` through Python standard-library `ctypes`; `EEXIST` is a race result, never permission to merge or replace. If another bootstrap wins, validate the winner against the current process SHA and extracted hashes, quarantine the losing staging directory, and return `BOOTSTRAP_RACE_LOST_VALID`; if the winner is invalid, return `RUNTIME_MANIFEST_INVALID` and HALT.

- [ ] **Step 5: Verify manifest and source only final runtime**

After rename, compare the manifest's `process_document_sha256` record to `sha256sum "$PROCESS_PATH"`, validate only the four generated-file entries with `sha256sum -c`, and then source:

```bash
(cd "$RUNTIME_DIR" && sha256sum -c manifest.sha256)
source "$RUNTIME_DIR/develop-it-runtime.sh"
```

Abort Phase -1 on missing files, extra manifest entries, checksum mismatch, wrong permissions, or any attempt to source a sibling temporary directory.

- [ ] **Step 6: Cover fresh, idempotent, interrupted, corrupt, and collision paths**

Add six named cases in `tests/check_06_cookbook.sh`; expected outcomes are `BOOTSTRAP_OK`, `BOOTSTRAP_REUSED`, `BOOTSTRAP_INTERRUPTED`, `RUNTIME_MANIFEST_INVALID`, `BOOTSTRAP_RACE_LOST_VALID`, and `BOOTSTRAP_RACE_LOST_INVALID`. Assert an interrupted extraction never leaves a usable `runtime/` directory.

Also assert the sourced runtime has no top-level phase action, every phase snippet sources the verified final runtime, local declaration and dependent assignment are separate statements, no helper relies on a pipeline/subshell to preserve result globals, no publication ends with conditional `&&`, no runtime block enables `set -e`, and no phase block copies a runtime helper body.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_01_lint.sh
bash tests/check_06_cookbook.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; every generated file has a manifest entry and all interruption cases preserve atomicity.

- [ ] **Step 8: Commit atomic runtime extraction**

```bash
git add develop-it-prompt.md tests/check_01_lint.sh tests/check_06_cookbook.sh tests/check_10_process_v2.sh
git commit -m "feat: extract orchestration runtime atomically"
```

### Task 4: Add Attempt Identity and Canonical STATUS Publication

**Files:**
- Modify: `develop-it-prompt.md` (Dispatch Identity, STATUS v2, every top-level role appendix)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/check_03_varcoverage.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: immutable runtime bundle and full role registry.
- Produces: `allocate_attempt`; attempt-scoped paths; generated `publish-status`; common STATUS-v2 validation and `PUBLICATION_LOST` diagnostics.

- [ ] **Step 1: Add failing identity and publication tests**

Add assertions for these exact allocations:

```text
allocate_attempt -1 0 preflight-claude -> logical=pm1-i00-preflight-claude, dispatch=pm1-i00-preflight-claude-a01
allocate_attempt 5 2 plan-fixer -> logical=p05-i02-plan-fixer, dispatch=p05-i02-plan-fixer-a01
second attempt of the same logical dispatch -> p05-i02-plan-fixer-a02
```

Add publisher cases for valid `reason: null`, allowed `x_` extension, duplicate key, unnamespaced unknown key, missing common/role-specific field, wrong dispatch ID, missing/extra output index, path outside allowed roots, invalid verdict, failed temporary creation/write, existing final STATUS, rename failure, sibling temp without final, and final reread mismatch.

- [ ] **Step 2: Run focused checks and observe v1 identity failures**

Run: `bash tests/check_06_cookbook.sh && bash tests/check_07_fakecli.sh`

Expected: non-zero exit because attempt numbers and STATUS-v2 common fields are absent.

- [ ] **Step 3: Implement collision-safe attempt allocation**

Render the attempt directory from the role's registry template below `$PHASE_DIR/<iteration-or-round>/attempts/$DISPATCH_ID/` and create it atomically. `allocate_attempt PHASE ITERATION ROLE` must set:

```bash
PHASE_TOKEN=$([ "$1" = -1 ] && printf m1 || printf '%02d' "$1")
LOGICAL_DISPATCH_ID="p${PHASE_TOKEN}-i$(printf '%02d' "$2")-$3"
ATTEMPT=$(next_unused_attempt "$LOGICAL_DISPATCH_ID")
DISPATCH_ID="$LOGICAL_DISPATCH_ID-a$(printf '%02d' "$ATTEMPT")"
ATTEMPT_DIR="$(role_attempt_dir "$3" "$DISPATCH_ID")"
STATUS_PATH="$ATTEMPT_DIR/STATUS.md"
STDOUT_PATH="$FEATURE_FOLDER/transcripts/$DISPATCH_ID.stdout"
STDERR_PATH="$FEATURE_FOLDER/transcripts/$DISPATCH_ID.stderr"
SNAPSHOT_DIR="$ORCHESTRATION_DIR/snapshots/$DISPATCH_ID"
```

A prelaunch failure consumes its allocated attempt and records `launched: false`. Derive the next two-digit attempt monotonically from all prior `RUN_LOG.md` records for the logical dispatch while holding the parent writer lock; never use clock/PID identity, overwrite, or reuse an attempt directory. Review/fixer attempts may add `batch_id`, but it never replaces attempt identity.

- [ ] **Step 4: Generate the canonical publisher**

Expose this CLI from `runtime/publish-status`:

```text
publish-status --contracts ROLE_CONTRACTS --role ROLE --dispatch-id ID \
  --logical-dispatch-id LOGICAL_ID --phase PHASE --iteration N --attempt N \
  --status STATUS_PATH --allowed-root FEATURE_FOLDER < role-fields.txt
```

The publisher validates that stdin already contains the common fields in canonical order:

```text
schema_version, dispatch_id, logical_dispatch_id, role, phase, iteration,
attempt, verdict, reason, published_at, artifact_revision, output_count,
output_01..output_NN, checkpoint_path
```

Validate UTF-8, one `key: value` record per line, unique keys, exact IDs, RFC3339 UTC `published_at`, integer counters, allowed verdicts, contiguous output indexes, declared output paths, and containment beneath the registry's allowed roots after `realpath` resolution. Permit extra fields only when their key begins with `x_`.

- [ ] **Step 5: Implement durable publication and lost-publication evidence**

Write `$STATUS_PATH.tmp.$DISPATCH_ID` with exclusive creation, fsync it, `os.replace` it onto STATUS, fsync the parent directory, and reread/validate the final STATUS. On any rename or reread failure, preserve the temp file and return:

```text
classification=PUBLICATION_LOST
tmp_path=<path>
tmp_size_bytes=<decimal bytes>
tmp_sha256=<lowercase sha256>
tmp_header_preview=<first 12 records and at most 512 bytes>
```

Before logging `tmp_header_preview`, replace values for keys matching `token|secret|credential|password|authorization|cookie` case-insensitively with `[REDACTED]`. Treat the preview as diagnostic only, never as authoritative STATUS.

- [ ] **Step 6: Convert every top-level appendix to one-command publication**

Each appendix must write role-specific fields to stdout or a private in-memory pipe and execute the exact publisher once. Remove direct `cat > STATUS`, `mv STATUS.tmp STATUS`, and role-local STATUS validators. `impl-worker` remains exempt because its registry contract is child-only with `status_template=none`.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_03_varcoverage.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; secrets never appear in publication-loss previews; all STATUS paths include an attempt ID.

- [ ] **Step 8: Commit attempt-scoped publication**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/check_03_varcoverage.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "feat: add attempt scoped status publication"
```

### Task 5: Normalize Vendor Invocation and Time Budgets

**Files:**
- Modify: `develop-it-prompt.md` (CLI Invocation, Long-Running Dispatch, Vendor Arguments)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/fakebin/claude`
- Modify: `tests/fakebin/codex`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_07_fakecli.sh`

**Interfaces:**
- Consumes: `role_contract_field`, allocated attempt paths, and attempt-specific prompt files.
- Produces: `invoke_vendor ROLE PROMPT_FILE STDOUT_FILE STDERR_FILE`; deterministic fake modes; normalized process exit and timeout evidence.

- [ ] **Step 1: Add failing cwd, argv, environment, and budget assertions**

For one Claude and one Codex role, assert the fake CLI records:

```text
Claude cwd == $REPO_ROOT
Claude env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS == 0
Claude invocation uses print/foreground behavior and awaits child completion
Codex argv contains -C $REPO_ROOT
both vendors receive exactly the registry model and effort
stdout and stderr are separate attempt-scoped files
```

Add boundary cases for role timeouts of 59 and 60 minutes: only the 60-minute role receives a just-in-time minimal liveness/headroom probe before its substantive launch.

- [ ] **Step 2: Run fake integrations and observe current invocation drift**

Run: `bash tests/check_07_fakecli.sh`

Expected: non-zero exit on Claude cwd/environment and long-role headroom assertions.

- [ ] **Step 3: Give both fake CLIs the same deterministic control surface**

Support these environment inputs in both `tests/fakebin/claude` and `tests/fakebin/codex`:

```text
FAKE_MODE=complete|exit-no-status|malformed-status|publication-lost|timeout|transient|permanent|unknown|spend-ceiling|orchestration-refusal
FAKE_EXIT_CODE=<integer>
FAKE_DELAY_SECONDS=<decimal>
FAKE_IGNORE_TERM=0|1
FAKE_STDOUT=<text>
FAKE_STDERR=<text>
FAKE_STATUS_SOURCE=<path>
FAKE_MUTATION=none|clean-checkpointed|dirty-checkpointed|dirty-uncheckpointed|unknown
FAKE_LOG=<path>
```

Record one sanitized TSV line containing vendor, pid, cwd, argv, model, effort, dispatch ID, logical dispatch ID, attempt, and selected mode. Never record environment variables unrelated to this fixed allowlist.

Add `run_fake_attempt VENDOR MODE MUTATION EXIT_CODE` to `tests/lib/v2_fixtures.sh`; it resets only attempt-local files, exports the fixed fake controls, invokes the real extracted dispatch helper, and appends the observed classification/mutation/result paths to `$BUILD/fake-attempt-results.tsv`. `check_07_fakecli.sh` exercises every mode through this function, and Task 7's recovery suite must call the same function rather than duplicate mode conditions.

- [ ] **Step 4: Implement one registry-driven invocation function**

`invoke_vendor` reads `vendor`, `model`, `effort`, `timeout_minutes`, and `long_running` through `role_contract_field`. It must reject unknown vendors before launch, preserve Codex `-C "$REPO_ROOT"`, and invoke Claude from `$REPO_ROOT` with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` and foreground print semantics. Both branches redirect to the supplied stdout/stderr files and return the actual exit code without classifying it.

- [ ] **Step 5: Enforce run-deadline and role-timeout rules before launch**

Immediately before a role whose `timeout_minutes` is at least `long_role_headroom_threshold_minutes`, run one paid minimal liveness/headroom probe for that role's vendor after all free gates pass. A quota/spend refusal suppresses the substantive launch and records the run-scoped vendor event; a successful probe proves only current liveness and must not claim enough budget to finish the role. Apply the registry timeout with GNU `timeout --kill-after="$grace" "$deadline"`; on expiry, await the wrapper and all children so none is orphaned. Never send STOP/CONT/TERM to extend a live timeout wrapper.

- [ ] **Step 6: Add exact negative cases**

Test unknown vendor, missing CLI binary, model mismatch, long-role spend refusal, successful liveness probe followed by launch, TERM-respecting timeout, TERM-ignoring timeout, and stdout containing status-like text without a STATUS file. Assert that only the STATUS file can establish completion.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/run.sh
```

Expected: all offline checks pass; no fake process remains after either timeout path.

- [ ] **Step 8: Commit normalized vendor invocation**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/fakebin/claude tests/fakebin/codex tests/check_06_cookbook.sh tests/check_07_fakecli.sh
git commit -m "refactor: normalize vendor invocation contracts"
```

### Task 6: Replace Dispatch Paths with One Attempt Engine

**Files:**
- Modify: `develop-it-prompt.md` (Dispatch Helpers, Parallel Dispatch, Run Log Ownership)
- Modify: `tests/check_03_varcoverage.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: attempt allocation, STATUS publication, registry lookup, and normalized invocation.
- Produces: `dispatch_attempt` and `dispatch_parallel`; sole-writer event/result ingestion; one lifecycle for sequential and concurrent roles.

- [ ] **Step 1: Add a lifecycle-order integration test**

In `tests/check_07_fakecli.sh`, assert every launched attempt records this durable order for a single dispatch ID:

```text
DISPATCH_STARTED
DISPATCH_COMPLETED
ATTEMPT_FAILED (only for a classified launched failure, referencing DISPATCH_COMPLETED)
```

Also assert a prelaunch failure emits exactly one `DISPATCH_NOT_LAUNCHED` and no start/completion. Dispatch two read-only roles concurrently and assert their attempt directories are disjoint while their parent-ingested `RUN_LOG.md` records are complete blocks.

- [ ] **Step 2: Run the test and observe divergent dispatch paths**

Run: `bash tests/check_07_fakecli.sh`

Expected: non-zero exit because sequential, parallel, and long-running helpers do not share one lifecycle.

- [ ] **Step 3: Implement `dispatch_attempt` as the only launcher**

Use this exact control flow:

```text
allocate attempt -> validate inputs and budget -> validate/acquire lease if mutating
-> write immutable rendered prompt -> invoke vendor -> await process
-> validate authoritative STATUS -> inspect repository mutation
-> classify result -> write attempt result -> release owned lease
```

Before launch, validate target CWD, phase applicability, context7 policy, output roots, optional defaults, and fully in-memory rendering. `DISPATCH_STARTED` includes attempt/contract identity, expected STATUS, effective CWD, and lease/snapshot references. Completion captures monotonic start/end/duration, exit code, usage, vendor envelope, transcripts, mutation/checkpoint state, and current STATUS validation. The function returns a normalized result through exported `DISPATCH_RESULT_CLASSIFICATION`, `DISPATCH_RESULT_VERDICT`, `DISPATCH_RESULT_REASON`, `DISPATCH_RESULT_STATUS_PATH`, and `DISPATCH_RESULT_MUTATION_STATE`. It does not append to `RUN_LOG.md` from a child process, and the helper that writes `DISPATCH_COMPLETED` owns that record exclusively.

- [ ] **Step 4: Implement `dispatch_parallel` as fan-out plus parent ingestion**

`dispatch_parallel PHASE ITERATION ROLE...` schedules independent `dispatch_attempt` calls, each returning an attempt-scoped result file. The parent waits for every PID, validates and ingests every result under `$ORCHESTRATION_DIR/log.lock`, and calculates `group_wall_ms=max(end)-min(start)` while preserving each non-zero monotonic child duration. Reject duplicate roles; if two mutating roles compete, the exclusive lease makes the second a typed prelaunch failure rather than permitting overlapping mutation.

- [ ] **Step 5: Remove obsolete launch helpers**

Delete or inline all independent sequential, long-running, and parallel launch implementations. Keep vendor-specific argument assembly only inside `invoke_vendor`; keep recovery decisions out of both invocation and dispatch.

- [ ] **Step 6: Reconcile durable state at every orchestrator turn**

At turn start, reconstruct the active phase and dispatch state. If its gate is unsatisfied, no child is live, and durable state proves an action is owed, execute that action before narrating future work. A user-facing claim that a role “is running” requires a matching `DISPATCH_STARTED`; otherwise append a process-deviation proposition and correct the state.

- [ ] **Step 7: Test partial fan-out failures**

Cover one completed child plus one timeout, one missing result file, one malformed result file, and two mutating attempts competing for the lease. Assert every started PID is awaited, no caller duplicates `DISPATCH_COMPLETED`, and the parent emits one result record per requested role.

- [ ] **Step 8: Run focused and full verification**

Run:

```bash
bash tests/check_03_varcoverage.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass and `rg 'dispatch_(sequential|long_running)|launch_role_direct' develop-it-prompt.md` finds no obsolete path.

- [ ] **Step 9: Commit the unified dispatch engine**

```bash
git add develop-it-prompt.md tests/check_03_varcoverage.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "refactor: unify orchestration dispatch lifecycle"
```

### Task 7: Implement Ordered Classification, Recovery, and Resume

**Files:**
- Modify: `develop-it-prompt.md` (Failure Classification, Recovery Matrix, Resume Classification)
- Modify: `tests/fakebin/claude`
- Modify: `tests/fakebin/codex`
- Create: `tests/check_09_recovery.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_07_fakecli.sh`, `tests/check_09_recovery.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: normalized dispatch result and mutation inspection.
- Produces: `classify_attempt`, `inspect_mutation_state`, `recovery_action`; resume states; full deterministic coverage of `RM01`–`RM12`.

- [ ] **Step 1: Create a table-driven recovery check that proves matrix coverage**

Create `tests/check_09_recovery.sh`. Extract matrix IDs from the prompt, execute one named fake-CLI case per row, and compare sorted IDs:

```bash
expected=$(python3 "$REPO_TOP/tests/lib/extract.py" recovery | tail -n +2 | cut -f1 | sort)
actual=$(printf '%s\n' "${executed_matrix_ids[@]}" | sort)
assert_eq "$expected" "$actual" "every recovery row must execute"
assert_eq 12 "$(printf '%s\n' "$actual" | sed '/^$/d' | wc -l)" "RM01-RM12"
```

For rows whose action depends on mutation state, execute all declared states, not only one representative.

- [ ] **Step 2: Run the new check and observe missing classifier/recovery behavior**

Run: `bash tests/check_09_recovery.sh`

Expected: non-zero exit because the recovery registry and functions are not executable yet.

- [ ] **Step 3: Implement the ordered classifier without overlapping branches**

Evaluate in this exact order and stop at the first match:

```text
PRELAUNCH_FAILED
TIMED_OUT
SPEND_CEILING
PERMANENT_VENDOR_ERROR
TRANSIENT_TRANSPORT_ERROR
UNKNOWN_VENDOR_ERROR
EXITED_NO_STATUS
PUBLICATION_LOST
MALFORMED_STATUS
COMPLETED
```

Use exit code plus sanitized stdout/stderr signatures only for vendor classifications. Before ordinary vendor liveness matching, map a success-envelope refusal caused by wrong repository/CWD/input to `ORCHESTRATION_REFUSAL`, then to `PRELAUNCH_FAILED` plus the bounded orchestration-correction path. A valid STATUS is still required for `COMPLETED`.

- [ ] **Step 4: Implement all stable recovery rows**

Encode these outcomes exactly:

```text
RM01 correctable prelaunch -> correct once, allocate a new attempt
RM02 active lease owner -> wait/observe owner; do not steal
RM03 stale or ambiguous lease -> stop for human decision
RM04 publication lost, non-mutating -> one publication retry; never promote temp
RM05 transient or no-status, NO_SIDE_EFFECTS -> one transient retry
RM06 timeout/transient/no-status, CLEAN_CHECKPOINTED -> continue within cap
RM07 same, DIRTY_CHECKPOINTED -> reconcile integrity, then continue only if the partial unit is isolated
RM08 any failure, DIRTY_UNCHECKPOINTED or INTEGRITY_UNKNOWN -> HALT with exact paths/state
RM09 spend ceiling -> emit one run-scoped vendor-unavailable event, suppress vendor, then HALT or explicitly accept degraded coverage
RM10 permanent or unknown vendor -> no retry; HALT or use the documented degradation decision
RM11 malformed STATUS -> non-mutating correction retry once; mutating reconciliation before any safe continuation/retry
RM12 completed -> branch on validated verdict; record final state before lease release
```

Every retry allocates a new attempt ID. Enforce caps with policy lookup, not numeric literals.

- [ ] **Step 5: Add resume-state classification**

Classify each logical dispatch as exactly one of:

```text
NOT_STARTED, PRELAUNCH_FAILED, RUNNING_OBSERVED, ORPHANED_UNOBSERVED,
FAILED_OBSERVED, COMPLETED_VALID, COMPLETED_UNACCEPTED
```

Resume from durable STATUS, event, lease, PID-observation, repository, and checkpoint evidence. Never infer completion from stdout, a temp STATUS, or a success exit code alone.

- [ ] **Step 6: Exercise every fake mode and mutation branch**

Ensure `tests/check_07_fakecli.sh` and `tests/check_09_recovery.sh` collectively run all fake modes from Task 5 and `NO_SIDE_EFFECTS`, `CLEAN_CHECKPOINTED`, `DIRTY_CHECKPOINTED`, `DIRTY_UNCHECKPOINTED`, and `INTEGRITY_UNKNOWN`. Cover timeout with missing STATUS, spend signatures under zero/non-zero wrappers, valid stale versus malformed current STATUS, observed failed versus orphaned unobserved state, every cap, and run-scoped vendor suppression. Assert exact RM ID, retry count, next attempt number, and terminal/continuation/degradation result.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_07_fakecli.sh
bash tests/check_09_recovery.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all 12 matrix IDs execute; no case selects more than one row; all offline checks pass.

- [ ] **Step 8: Commit deterministic recovery**

```bash
git add develop-it-prompt.md tests/fakebin/claude tests/fakebin/codex tests/check_07_fakecli.sh tests/check_09_recovery.sh tests/check_10_process_v2.sh
git commit -m "feat: add deterministic recovery and resume"
```

### Task 8: Add Events, Decisions, Snapshots, and Write Leases

**Files:**
- Modify: `develop-it-prompt.md` (Event Contract Registry, Decision Log, Snapshot Protocol, Write Lease Protocol)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: sole-parent ingestion and recovery decisions.
- Produces: `record_event`, `acquire_write_lease`, `release_write_lease`; append-only typed `RUN_LOG.md` events/decisions/corrections; before/after Git and artifact snapshots.

- [ ] **Step 1: Add failing registry, event, and lease tests**

Assert every event block has:

```text
event_id,event,timestamp,process_schema_version,phase,iteration,
dispatch_id,caused_by_event_id,authority,reason
```

Require registry rows for all spec-declared event types, including `GIT_FINALIZATION_RESULT`. Test lease acquisition, same-owner release, non-owner release, active collision, observed failed owner, orphaned unobserved owner, completed owner with lost release record, stale/ambiguous lease, malformed lease, and an unauthorized mutation while no lease exists.

- [ ] **Step 2: Run focused checks and observe missing durable contracts**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit because events and leases are not yet schema-v2 records.

- [ ] **Step 3: Add the event registry and canonical writer**

Define each required event type and its additional fields in `Event Contract Registry`: `DISPATCH_NOT_LAUNCHED`, `DISPATCH_STARTED`, `DISPATCH_COMPLETED`, `ATTEMPT_FAILED`, `RECOVERY_AUTHORIZED`, `RECOVERY_CAP_REACHED`, `ORCHESTRATION_CORRECTION`, `HALT`, `OWNER_DECISION`, `RISK_ACCEPTED`, `PHASE_ACCEPTED`, `EVENT_CORRECTED`, `VENDOR_UNAVAILABLE`, `DEGRADED_REVIEW_ACCEPTED`, `CONTEXT7_UNAVAILABLE`, `CONTEXT7_RESTORED`, `WRITE_LEASE_ACQUIRED`, `WRITE_LEASE_RELEASED`, `ARTIFACT_INTEGRITY_BLOCKED`, `GIT_FINALIZATION_RESULT`, `ITERATION_CAP_REACHED`, `ITERATION_CAP_OVERRIDE`, and `PROCESS_DEVIATION`. Give the table a `proposition_required=yes|no` column. Set it to `yes` for `ATTEMPT_FAILED`, `RECOVERY_AUTHORIZED`, `RECOVERY_CAP_REACHED`, `ORCHESTRATION_CORRECTION`, `HALT`, `EVENT_CORRECTED`, `VENDOR_UNAVAILABLE`, `DEGRADED_REVIEW_ACCEPTED`, `ARTIFACT_INTEGRITY_BLOCKED`, `ITERATION_CAP_REACHED`, `ITERATION_CAP_OVERRIDE`, and `PROCESS_DEVIATION`; all other listed rows are `no`. `record_event EVENT_TYPE KEY=VALUE...` assigns a monotonically increasing `event_id` from `RUN_LOG.md`, validates the common and event-specific fields, takes `$ORCHESTRATION_DIR/log.lock`, appends exactly one fixed-order YAML-ish event block, flushes/fsyncs, and releases the lock.

- [ ] **Step 4: Add append-only decision records**

For every retry, continuation, correction, escalation, acceptance, exclusion, and finalization choice, append a typed decision containing decision ID, authority identity (`operator`, `standing_process_policy`, or named owner input), causal event IDs, exact scope/finding IDs, artifact revision, evidence, alternatives rejected, residual risk, applicability/expiry, independent-rereview flag, and follow-up ID. Correct a durable event only by appending `EVENT_CORRECTED` with the original event ID, replacement classification, evidence, and downstream effect; no existing block is edited.

- [ ] **Step 5: Implement exclusive write leases**

`acquire_write_lease OWNER AUTHORITY DISPATCH_ID DECLARED_PATH...` writes `$ORCHESTRATION_DIR/write-lease.json` atomically with:

```json
{"schema_version":2,"dispatch_id":null,"lease_owner":"orchestrator-finalization","authority":"orchestrator","phase":"10","acquired_at":"<UTC>","baseline_head":"<sha>","declared_write_paths":["<repo-relative>"],"declared_foreign_paths":["<repo-relative>"],"declared_foreign_commits":["<sha>"],"snapshot_manifest_path":"<absolute path>"}
```

For a dispatched role, `dispatch_id` is its string ID, `authority` is `role`, and `lease_owner` is its role. Use exclusive creation, verify repository containment for every declared path, and refuse active, malformed, stale, or ambiguous existing leases. `release_write_lease OWNER` removes only an exact, valid owner match after the classified outcome and final state are durable; an interruption leaves the lease for resume classification. Ambiguous ownership emits `ARTIFACT_INTEGRITY_BLOCKED` and never launches a second writer.

- [ ] **Step 6: Capture mutation snapshots and enforce authority**

Before and after each mutating attempt, record HEAD, `git status --porcelain=v1 -z`, hashes/blob IDs for declared artifacts, copies of mutable non-Git artifacts needed for explicitly authorized scoped recovery, process identity, allow-list, and known foreign changes. Classify failures as `NO_SIDE_EFFECTS`, `CLEAN_CHECKPOINTED`, `DIRTY_CHECKPOINTED`, `DIRTY_UNCHECKPOINTED`, or `INTEGRITY_UNKNOWN`; emit `ARTIFACT_INTEGRITY_BLOCKED` on unexplained changes. Snapshots are diagnostic/authorized scoped-recovery inputs only—never automatic rollback. Read-only roles must produce `NO_SIDE_EFFECTS` or a process defect.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; every `RUN_LOG.md` block parses and event IDs are monotonic; non-owner mutation/release cases stop safely without rollback.

- [ ] **Step 8: Commit durable state and lease controls**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "feat: add durable events and write leases"
```

### Task 9: Make Progress Checkpoints Durable and Resumable

**Files:**
- Modify: `develop-it-prompt.md` (Checkpoint Contract, Resume Protocol, reviewer/planner/implementer/fixer appendices)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: attempt IDs, events, repository snapshots, leases, and resume-state classification.
- Produces: role-specific append-only JSONL checkpoints; validated continuation inputs; bounded continuation accounting.

- [ ] **Step 1: Add failing checkpoint contract cases**

Create fixtures for a valid checkpoint, truncated final JSONL record, duplicate sequence, wrong dispatch ID, path outside `$FEATURE_FOLDER`, stale artifact revision, and checkpoint claiming a repository change absent from its Git snapshot. Assert only the fully validated sequence can authorize continuation; a malformed/discontinuous suffix remains partial-state evidence and requires integrity reconciliation before even its valid prefix is used.

- [ ] **Step 2: Run focused checks and observe missing checkpoint validation**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit because current progress files lack schema-v2 identity and prefix validation.

- [ ] **Step 3: Define the common checkpoint envelope**

Store progress at the current attempt's `$PHASE_DIR/<iteration-or-round>/attempts/$DISPATCH_ID/progress.jsonl`. Every record uses this exact common schema:

```json
{"schema_version":2,"dispatch_id":"p06-i00-implementer-a02","sequence":7,"role":"implementer","unit_type":"task","unit_id":"task-07","state":"completed","artifact_path":"/absolute/path","artifact_sha256":"<sha256>","commit_sha":"<git-sha>","finding_ids":[],"verification":"PASS","next_unit":"task-08","timestamp":"<UTC-ISO-8601>"}
```

Append with one validated `O_APPEND` write under a per-file lock, flush/fsync, and never rewrite earlier records.

- [ ] **Step 4: Specify role-specific checkpoint payloads**

Require:

```text
implementer: append after every committed task and review; include task/report/diff paths, commit, verification, next task, and SDD working directory
plan writer: append per completed top-level section and atomically publish artifact-complete.json after structural completion but before terminal STATUS
spec/plan fixer: append after each assigned finding disposition and record next unresolved ID plus post-edit artifact hash
long reviewer: append coherent partial finding groups, which never count as a verdict without complete coverage and terminal STATUS
implementation-fixer: append after each finding-specific commit and verification
documentation-writer: append per completed documentation output and self-correction round
```

Each appendix must publish `checkpoint_path` in STATUS when a checkpoint exists, or an empty value when none exists.

- [ ] **Step 5: Validate resumable prefixes and continuation identity**

On resume, parse complete JSONL lines in order, require strictly increasing sequence, then validate artifact hashes, commits, current HEAD/tree, snapshot/lease, declared foreign changes, completed units, at most one dirty partial unit, remaining work, and continuation budget. A continuation gets a new attempt ID, receives the prior dispatch/classification and last sequence, never repeats a completed unit, and writes new checkpoint records under its own attempt directory.

Configure the SDD skill root as `$FEATURE_FOLDER/6-implementation/sdd/`. If the installed skill cannot accept a root, mirror each completed task's brief, report, progress update, and review diff immediately after that task; terminal-only mirroring is invalid. STATUS records both original and durable SDD paths.

- [ ] **Step 6: Enforce the global continuation cap**

Count continuation decisions per logical dispatch. Permit at most `policy_value continuation_cap` continuations, including same-role dirty checkpoint continuation. On exhaustion emit `CONTINUATION_CAP_REACHED` and stop for human direction; never silently restart from scratch.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; corrupted suffixes cannot invalidate a prior durable prefix or authorize unrecorded work.

- [ ] **Step 8: Commit durable checkpoints**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "feat: add resumable role checkpoints"
```

### Task 10: Require Proven Preflight and Context Evidence

**Files:**
- Modify: `develop-it-prompt.md` (Phase -1, Capability Discovery, Process Identity, Context Policy)
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_05_contract.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: atomic bootstrap, vendor invocation, events, and attempt classification.
- Produces: ordered zero-token gates; typed process identity in `RUN_LOG.md`; capability/vendor/context evidence; hard prerequisites for paid/model dispatch.

- [ ] **Step 1: Add failing free-gate order tests**

Assert no fake CLI process starts until all these gates have emitted successful evidence in order:

```text
PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE
LOCAL_CLI_CANARIES_PASSED
TARGET_DIRTY_TREE_GATE_PASSED
PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED
RUNTIME_AND_REGISTRIES_VERIFIED
```

Inject failure at each gate and assert fake invocation log remains empty. Point the prompt at existing folders with absent, malformed, v1, and mismatched-identity `RUN_LOG.md`; assert it writes zero bytes there and instructs use of the recorded process version. After all five fresh-run gates pass, assert minimal model-ID probes occur before dispatched skill/MCP capability probes.

- [ ] **Step 2: Run the preflight checks and observe premature launch paths**

Run: `bash tests/check_07_fakecli.sh && bash tests/check_10_process_v2.sh`

Expected: non-zero exit because free-gate evidence is not yet an enforced ordered prerequisite.

- [ ] **Step 3: Write immutable process identity**

Resolve identity only against `PROCESS_REPO_ROOT`: derive `PROCESS_PATH_REL`, use `git ls-files --error-unmatch` before diffing, compute the process SHA-256 independently of Git, and record `develop_it_dirty: no|yes|untracked|unknown` with a reason for `unknown` (`untracked` includes ignored-untracked). Record schema version, process path/hash, Git identity, repository root, feature folder, and runtime manifest identity in the first durable `RUN_LOG.md` blocks. Add fixtures for all four dirty states. On an existing feature folder, validate its recorded schema and identity before any write; absent/malformed/non-v2 `RUN_LOG.md` HALTs and tells the operator to use that run's recorded process version.

- [ ] **Step 4: Enforce all free gates before probes or agents**

Implement Phase -1 as the exact five-step zero-token sequence from Step 1. Each gate writes success/failure evidence. A correctable input error may use `prelaunch_correction_cap=1`; all other failures stop. Only after all five pass may Phase 1 run one paid minimal model-ID probe per distinct model and then the dispatched required/optional skill and MCP probes.

- [ ] **Step 5: Record capability and skill evidence**

Phase 1 records `required_skills_present`, `required_skills_missing`, `optional_skills_present`, and `optional_skills_absent`, including plugin roots/paths checked for missing requirements. Re-probe once when a per-phase missing claim contradicts prior READY, filesystem evidence proves presence, or publication was lost. A substantive success records `vendor_proven: true` with role/event ID; later cheap probe/publication failure cannot revoke it, while auth failure, model rejection, or spend ceiling can.

- [ ] **Step 6: Make external context optional and evidence-based**

Make discovery marketplace-agnostic. Phase 2 computes `applicable_optional_skills = installed ∩ relevant` with work types/project capabilities and reasons; the plan writer receives the set and implementation passes only task-relevant skills while recording actual use. Reconstruct context7 from the latest valid `CONTEXT7_UNAVAILABLE|CONTEXT7_RESTORED` event, falling back to Phase 1 STATUS only when no later event exists. Missing server, transient failure, and quota exhaustion remain distinct. When both vendors are proven, Phases 3, 5, and 7 use both and union findings; degraded coverage is explicit, never strict PASS, and one-vendor Phase 7 requires `DEGRADED_REVIEW_ACCEPTED`.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass and every injected free-gate failure produces zero vendor processes.

- [ ] **Step 8: Commit preflight evidence gates**

```bash
git add develop-it-prompt.md tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "feat: require preflight and context evidence"
```

### Task 11: Stabilize Findings and Review Convergence

**Files:**
- Modify: `develop-it-prompt.md` (Finding Schema, Finding Ingestion, Review Convergence, reviewer/fixer appendices)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: validated reviewer STATUS/output, artifact revisions, checkpoints, and bounded dispatch.
- Produces: `ingest_findings`; stable canonical finding IDs; convergence ledger; bounded fixer batches with mandatory rereview.

- [ ] **Step 1: Add line-drift and duplicate-heading fixtures**

In `tests/lib/v2_fixtures.sh`, generate two Markdown documents where the second adds paragraphs before an unchanged finding, and a third containing repeated sibling headings. Assert:

```text
unchanged AST node after earlier insertion -> same finding_id
same issue under repeated sibling heading #1 and #2 -> different finding_id
changed issue key at same node -> different finding_id
line_number changes -> same finding_id, different evidence line
```

- [ ] **Step 2: Run the finding tests and observe location instability**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit because canonical document locations are not yet heading/AST based.

- [ ] **Step 3: Gate review with structural artifact manifests**

For each producer role declare expected output path, minimum non-whitespace size, required headings/machine fields, allowed/forbidden truncation markers, revision calculation, and whether `artifact-complete.json` is required. Implement `validate_artifact ROLE DISPATCH_ID` to require matching successful STATUS or typed `PHASE_ACCEPTED`, allowed-root outputs, a passing manifest, existing referenced summaries, and the exact accepted revision. Size or marker alone never authorizes expensive review.

- [ ] **Step 4: Define the canonical finding and disposition records**

Require these reviewer fields:

```text
finding_id,source_finding_id,reviewer_role,vendor,phase,iteration,severity,
artifact_path,artifact_revision,location,normalized_location,
normalized_issue_key,summary,evidence,required_change,origin_iteration,
provenance,related_finding_ids,status
```

Allow severity `blocker|major|minor`, provenance `preexisting|new_coverage|fix_regression|unknown`, and status `open|fixed|verified|accepted_risk|deferred|superseded`. Preserve each vendor-local source ID plus normalized location/issue key for deterministic ingestion. Every fixer-assigned ID returns exactly one of `fixed`, `subsumed_by:<finding_id>`, `already_satisfied`, `blocked`, `accepted_risk:<decision_id>`, or `deferred:<followup_id>` with the evidence/revision required by §17.3.

- [ ] **Step 5: Derive stable Markdown locations from document structure**

For Markdown artifacts, compute `normalized_location` as:

```text
heading breadcrumb of normalized heading text
+ 1-based occurrence for repeated sibling headings
+ block kind within the section
+ stable anchor when present, otherwise normalized-content fingerprint
```

Do not include source line or byte offset. Preserve current line number, column, and excerpt only in `evidence`. For code, use repository-relative path plus symbol/AST node; use line number only when no structural symbol exists and flag that location as weak.

- [ ] **Step 6: Canonicalize IDs and ingest reviewer output**

`ingest_findings ROLE STATUS_FILE OUTPUT_JSONL` validates every record, computes:

```text
finding_id = sha256(artifact_kind + "\0" + normalized_location + "\0" + normalized_issue_key)
```

and rejects model-supplied canonical IDs that differ. Normalize Unicode, whitespace, case rules, heading escapes, and issue keys before hashing; preserve the reviewer/vendor source ID separately. Reject canonical-ID collisions with conflicting content and route them to `EVENT_CORRECTED` rather than guessing. Re-reviewers receive the prior catalog and reuse normalized location/issue keys for recurring issues; `related_finding_ids` records split, merge, and supersession.

- [ ] **Step 7: Implement bounded convergence and fixer batching**

Dispatch all proven reviewers against the same immutable revision, union by canonical finding ID, and group at most `policy_value document_fixer_batch_size` findings per document-fixer dispatch. Iterations 1–2 require zero blockers and majors; iteration 3 onward requires zero blockers with remaining majors explicitly deferred/accepted. After every fixer completion, structurally validate the new revision and dispatch a full review before acceptance. Stop or require a typed decision at `review_iteration_cap`; the cap never authorizes an unreviewed revision.

- [ ] **Step 8: Record divergence and require consolidation**

After every review/fix cycle record artifact bytes/sections, growth percentage, new/recurring/resolved/reopened/fix-regression counts, net open blocker/major count, changed sections/paths, and reviewer cost/wall time. Mark divergence when: a just-fixed finding recurs twice; a fix-induced blocker appears in two consecutive reviews; growth exceeds `artifact_growth_warning_pct` for two consecutive fixer passes without reducing open blockers+majors; or for two consecutive rounds the fixer reopens more blockers/majors than reviewers verify resolved. At `policy_value divergent_round_cap`, stop additive fixing and run one bounded consolidation pass prioritizing deletion, replacement, contradiction removal, and provenance repair; re-review it, then HALT or require an explicit decision if divergence remains.

- [ ] **Step 9: Test unreviewed final fixes, provenance, and coverage degradation**

Add cases proving: a fixer cannot close its own findings; every assigned finding has a disposition; a shifted paragraph keeps its ID; subsumption is explicit; one reviewer's PASS cannot cancel the other's blocker; one-vendor Phase 7 requires degraded-review acceptance; a fix-induced blocker recurs; two growing rounds trigger consolidation; deletion can produce negative growth; the tenth review is allowed but an eleventh is not; and the last successful gate action is reviewer acceptance, never fixer STATUS.

- [ ] **Step 10: Run focused and full verification**

Run:

```bash
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; inserting earlier Markdown content does not change the unchanged finding's ID.

- [ ] **Step 11: Commit stable review convergence**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "feat: stabilize findings and review convergence"
```

### Task 12: Make Plans Executable and Verification Results Explicit

**Files:**
- Modify: `develop-it-prompt.md` (Plan Contract, Verification Contract, plan-writer/plan-reviewer/tester appendices)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_06_cookbook.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: stable findings, artifact revision, role checkpoints, and review convergence.
- Produces: atomic plan tasks with stable IDs and explicit verification records using `PASS|FAIL|EXCLUDED|NOT_RUN`.

- [ ] **Step 1: Add failing plan and verification fixtures**

Test plans with duplicate task IDs, missing objective/files/prerequisite/actor, unavailable credential, undeclared side effect, ambiguous verification command, absent environment/expected result, missing actor handoff, cyclic dependencies, and a post-implementation-only review remedy. Test verification records in every allowed state plus invalid state `SKIPPED`.

- [ ] **Step 2: Run focused checks and observe under-specified plan acceptance**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit because current plans do not carry all executable task fields or four-state verification results.

- [ ] **Step 3: Define the executable plan-task schema**

Each task must declare:

```text
stable task_id and objective; exact target files/sections; prerequisites/dependencies;
actor=implementer|owner|CI|deployed_environment; required capability/credential name;
external/destructive side effects; implementation steps; verification commands;
expected results; verification environment; rollback/cleanup; optional task-relevant skills;
handoff/follow-up behavior when actor is not implementer
```

Do not include secret material. Task IDs are stable within a plan revision, dependencies reference reachable prior tasks and form a DAG, and owner/CI/deployed-environment work becomes an explicit handoff rather than an implementer failure.

- [ ] **Step 4: Strengthen plan-writer and plan-reviewer contracts**

The plan writer must split tasks at reviewer-meaningful boundaries, name exact files/interfaces, provide deterministic commands/environments/results, declare exclusions and side effects, route only task-relevant installed skills, and define non-implementer handoffs. The plan reviewer validates actors, prerequisite reachability, credential availability without reading secrets, command executability/safety, exclusions, review-window freshness, optional-skill routing, and handoffs; it returns stable findings through Task 11's protocol.

- [ ] **Step 5: Define verification records**

For each declared command write:

```text
verification_id,command,environment,result,exit_code,evidence_path,
baseline_comparison,reason,followup_id
```

Allowed `result` values are only `PASS`, `FAIL`, `EXCLUDED`, `NOT_RUN`. `FAIL` alone enters debugging. `EXCLUDED` needs evidence that the check is pre-existing, environment-bound, actor-bound, or outside the change's capability and cannot hide a new regression. `NOT_RUN` names its actor/prerequisite and becomes handoff/readiness work. An empty result is never PASS. Performance verdicts require a declared controlled environment and comparable baseline; otherwise they are advisory/inconclusive, and a claimed performance fix must remeasure under the same conditions.

- [ ] **Step 6: Gate implementation and phase completion on accepted plans**

Implementation may start only from a plan revision whose latest plan-review verdict is accepted and whose open blocking finding count is zero. Once Phase 6 starts, the plan's pre-implementation review window closes; later plan-review requests are marked `STALE` without a vendor call. Implementation can be `DONE_WITH_EXCLUSIONS` only when every non-excluded required check passes and exclusions are policy-valid; `NOT_RUN` remains visible as handoff/readiness work.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; invalid `SKIPPED` and missing requirement coverage are rejected.

- [ ] **Step 8: Commit executable plan contracts**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_10_process_v2.sh
git commit -m "feat: require executable plans and verification evidence"
```

### Task 13: Separate Implementation Continuation from Finding Repair

**Files:**
- Modify: `develop-it-prompt.md` (Phase 6, Phase 7, implementer/impl-worker/implementation-fixer/code-reviewer appendices)
- Modify: `tests/check_02_markers.sh`
- Modify: `tests/check_04_table.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_04_table.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: accepted executable plan, write leases, checkpoints, stable findings, and four-state verification records.
- Produces: explicit implementer modes `A`, `B`, and `D`; child-worker boundary; dedicated implementation-fixer loop; accepted code-review state.

- [ ] **Step 1: Add failing role-boundary tests**

Assert:

```text
Mode A = fresh implementation from accepted plan and baseline
Mode B = post-debug re-verification from debugger STATUS
Mode D = continuation from validated checkpoints, prior classification, tree state, and remaining work
Mode C is absent
implementation-fixer is the only role that repairs code-review findings
code-reviewer never mutates
impl-worker never publishes top-level STATUS
```

Add a fake attempt where the implementer tries to repair a code-review finding and expect `ROLE_SCOPE_VIOLATION`.

- [ ] **Step 2: Run focused checks and observe the overloaded implementer contract**

Run: `bash tests/check_04_table.sh && bash tests/check_10_process_v2.sh`

Expected: non-zero exit because current implementation/fix responsibilities are not separated.

- [ ] **Step 3: Define implementer modes and dispatch inputs**

Require a `mode=A|B|D` input in each implementer prompt:

```text
A consumes accepted plan + implementation baseline
B consumes debugger STATUS + affected/full verification set + current implementation revision
D consumes validated checkpoints + prior classification + current tree state + remaining work
```

Reject any other mode before launch. Mode B re-runs verification and does not redo task work. Mode D verifies completed tasks/commits, reconciles at most one dirty partial task, never repeats completed work, and counts against `continuation_cap`; a clean timeout after committed tasks becomes `INCOMPLETE_CONTINUABLE`. Implementation STATUS includes all per-command results/exclusions, completed task IDs, original/durable progress and SDD paths, baseline/final SHAs, declared foreign changes, and remaining handoffs.

- [ ] **Step 4: Constrain child-worker behavior**

Only the parent implementer may spawn `impl-worker`, and only if its role contract says `may_spawn_children=yes`. The child receives a disjoint declared-path set, cannot spawn children, cannot own the repository-wide write lease independently, and returns a hash-addressed child result to the parent. The parent remains responsible for top-level STATUS, per-task checkpoint/mirror custody, review, validation, and integration.

- [ ] **Step 5: Implement the dedicated repair loop**

After implementation completes, Phase 7 dispatches all proven read-only code reviewers against the same accepted implementation revision, ingests stable findings, and if blocking findings exist dispatches `implementation-fixer` with only enumerated open finding IDs and the reviewed baseline/final diff under the write lease. The fixer touches only finding-required declared paths, creates finding-specific commits, runs scoped plus ripple checks, remeasures measurement-based findings, checkpoints/dispositions every assigned ID, converts unrelated opportunities to follow-ups, publishes a new revision, and is always followed by fresh full code review. Apply `review_iteration_cap`, coverage-degradation, and divergence rules from Tasks 10–11.

- [ ] **Step 6: Prove ownership and convergence paths**

Test Mode A completion, Mode B post-debug re-verification without repeated task work, Mode D clean and dirty-partial continuation, durable SDD custody after external skill-state loss, child integration, fixer success followed by reviewer acceptance, fixer success followed by recurrent finding, undeclared changed path, child path overlap, and review-cap exhaustion.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_02_markers.sh
bash tests/check_04_table.sh
bash tests/check_05_contract.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; no implementation path uses Mode C or lets the primary implementer repair review findings.

- [ ] **Step 8: Commit implementation role separation**

```bash
git add develop-it-prompt.md tests/check_02_markers.sh tests/check_04_table.sh tests/check_05_contract.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "refactor: separate implementation and review repair"
```

### Task 14: Add Documentation, Handoff, and Orchestrator Finalization Phases

**Files:**
- Modify: `develop-it-prompt.md` (Phases 8–10, documentation-writer/tester/reviewer appendices, finalization contract)
- Modify: `tests/check_02_markers.sh`
- Modify: `tests/check_04_table.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Test: `tests/check_04_table.sh`, `tests/check_07_fakecli.sh`, `tests/check_10_process_v2.sh`

**Interfaces:**
- Consumes: accepted implementation/code review, explicit verification results, events, snapshots, and lease APIs.
- Produces: Phase 8 all-tests gate; Phase 9 documentation/UAT/planned-vs-realized/validation/follow-up artifacts; `append_followup`; Phase 10 orchestrator-owned local Git finalization and `GIT_FINALIZATION_RESULT`.

- [ ] **Step 1: Add failing phase-order and authority tests**

Assert the normative tail is:

```text
Phase 8  All Tests
Phase 9  Documentation and Handoff
Phase 10 Local Git Finalization
Phase 11 Readiness and Completion
```

Test that Phase 9 cannot run before Phase 8 reaches its policy-valid terminal result, Phase 10 cannot run with an existing lease or invalid/incomplete documentation outputs, and no `finishing-branch` or documentation-review subprocess is launched.

- [ ] **Step 2: Run focused checks and observe legacy finalization behavior**

Run: `bash tests/check_10_process_v2.sh`

Expected: non-zero exit because documentation is not its own reviewed phase and finalization still references external role behavior.

- [ ] **Step 3: Implement the Phase 8 all-tests gate**

Execute every accepted-plan verification command plus the repository's authoritative full suite in the foreground. Record one verification result per command. Route only genuine `FAIL` results through the existing maximum of three all-tests fix rounds to `test-fixer`, operating under the lease/snapshot/checkpoint/review-back rules; `EXCLUDED` and `NOT_RUN` flow to handoff/readiness instead of becoming PASS. Preserve stdout/stderr evidence paths and derive the final test verdict from the complete result set.

- [ ] **Step 4: Implement Phase 9 documentation and handoff**

Create `$FEATURE_FOLDER/9-documentation/attempts/$DISPATCH_ID/STATUS.md`, `uat.md`, `planned-vs-realized.md`, and `documentation-validation.md`. Dispatch `documentation-writer` under a role write lease with final diff, accepted spec/plan revisions, implementation/test/review summaries, decisions, exclusions, follow-ups, and docs inventory. It appends planned-versus-realized history, updates only docs made stale by the final change, writes UAT prerequisites/actions/expected results/smoke checks/rollback/cleanup plus a distinct “Not yet executed” section, validates commands non-destructively, and checks all referenced paths/findings/follow-ups. Deterministic structural validation may return the same writer for at most `policy_value documentation_fix_cap` self-correction rounds; do not add a documentation-review model.

Create `$FEATURE_FOLDER/followups.jsonl` through orchestrator-only `append_followup`: roles return candidates, then the orchestrator validates and appends records containing ID, origin phase/finding, description, actor, prerequisite, risk, status, and evidence/disposition. Roles never write this file directly.

- [ ] **Step 5: Make Phase 10 a direct orchestrator operation**

Before staging, the orchestrator asserts no lease remains. It then directly calls:

```text
acquire_write_lease orchestrator-finalization orchestrator null <exact candidate staging paths>
```

The lease record must contain `authority: "orchestrator"`, `lease_owner: "orchestrator-finalization"`, and `dispatch_id: null`. Do not spawn a writer or finishing-branch agent. Stage only declared in-scope paths, inspect the staged diff, create one local commit if non-empty, record the resulting commit SHA, and release the lease after the post-commit snapshot.

- [ ] **Step 6: Emit explicit finalization outcomes**

Record `GIT_FINALIZATION_RESULT` with baseline/final HEAD, staged-path manifest, commit SHA or `null`, `push_performed: no`, and exactly one result:

```text
COMMITTED  -> staged in-scope diff committed locally; include commit_sha
NO_CHANGES -> no in-scope diff; no commit created
BLOCKED    -> lease, scope, dirty-tree ownership, or unresolved-review gate blocked action
FAILED     -> staging or commit command failed; include exit/evidence, do not retry blindly
```

Never push or configure a remote. Preserve unrelated user changes and reject any staged path not in the declared finalization set.

- [ ] **Step 7: Test documentation and finalization failure paths**

Cover documentation valid first pass, one and two structural self-corrections, cap exhaustion, UAT missing “Not yet executed”, broken finding/follow-up reference, direct role write to `followups.jsonl`, existing active lease, unexpected staged path, commit hook failure, empty diff, successful local commit, and assertions that fake CLI logs contain neither a documentation reviewer nor a finalization role invocation.

- [ ] **Step 8: Run focused and full verification**

Run:

```bash
bash tests/check_02_markers.sh
bash tests/check_04_table.sh
bash tests/check_05_contract.sh
bash tests/check_07_fakecli.sh
bash tests/check_10_process_v2.sh
bash tests/run.sh
```

Expected: all offline checks pass; Phase 10's successful commit is local and made only while the orchestrator finalization lease is active.

- [ ] **Step 9: Commit the documentation and finalization phases**

```bash
git add develop-it-prompt.md tests/check_02_markers.sh tests/check_04_table.sh tests/check_05_contract.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh
git commit -m "feat: add reviewed docs and local finalization"
```

### Task 15: Reconcile Propositions and Gate Final Readiness

**Files:**
- Modify: `develop-it-prompt.md` (Proposition Ledger, Audit Protocol, Phase 11 Readiness)
- Modify: `tests/lib/v2_fixtures.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_10_process_v2.sh`
- Create: `tests/check_11_reconciliation.sh`
- Test: `tests/check_10_process_v2.sh`, `tests/check_11_reconciliation.sh`

**Interfaces:**
- Consumes: append-only events/decisions, findings, STATUS records, checkpoints, verification, documentation acceptance, and Git finalization result.
- Produces: `append_proposition`, `reconcile_propositions`, and `audit_run_state`; exact event-ID-backed proposition coverage; final `READY|READY_WITH_NOTES|NOT_READY` readiness verdict.

- [ ] **Step 1: Create failing reconciliation fixtures**

Create `tests/check_11_reconciliation.sh` with fixtures for: exactly one proposition for a mandatory event, missing/duplicate proposition header, proposition without real trigger, `DISPATCH_NOT_LAUNCHED` mislabeled as launched vendor failure, unauthorized retry/continuation, stale correction classification, duplicate/missing completion block, accepted revision mismatch, missing documentation, remaining lease, degraded coverage, valid exclusion, Phase 10 `NO_CHANGES`, and Phase 10 `COMMITTED`.

- [ ] **Step 2: Run reconciliation and observe missing audit logic**

Run: `bash tests/check_11_reconciliation.sh`

Expected: non-zero exit because proposition results are not yet derived from durable event IDs.

- [ ] **Step 3: Define pending metadata and one-writer proposition append**

When an event requires a process-improvement proposition, `record_event` also appends complete header metadata to `$ORCHESTRATION_DIR/pending-propositions.jsonl`:

```text
event_id,phase,kind,trigger
```

The orchestrator alone calls `append_proposition` to validate this header/event relation and append the full entry, then appends a fulfillment record. The deterministic audit may read only proposition headers/metadata and `RUN_LOG.md` event envelopes, never proposition bodies. Pending metadata is non-authoritative for current gates.

- [ ] **Step 4: Implement event-ID reconciliation**

`reconcile_propositions` reads only the authorized metadata, matches exact event IDs rather than time windows, and fails on every §21.2 case: mandatory event without exactly one header, header without event, duplicate coverage, prelaunch mislabeled as vendor failure, retry/continuation without causal `RECOVERY_AUTHORIZED`, stale correction, duplicate/missing dispatch completion, or `PHASE_ACCEPTED` revision mismatch. It emits an append-only audit artifact and never infers state from proposition prose.

- [ ] **Step 5: Implement the final audit**

`audit_run_state` verifies:

```text
runtime manifest valid; process identity matches; all attempts classified;
no RUNNING_OBSERVED or ORPHANED_UNOBSERVED dispatch; no active lease;
every accepted output exists and matches its recorded revision/hash;
all blocking findings resolved by a later review; review caps respected;
required verification PASS or approved EXCLUDED; documentation accepted;
followups valid; mandatory events/propositions reconcile by exact event ID;
latest context7 event overrides earlier reachability; Phase 10 result valid;
RUN_LOG event/decision blocks, checkpoints, STATUS, propositions, and Git snapshots agree.
```

Any mismatch emits an audit finding with the conflicting record IDs and blocks readiness.

- [ ] **Step 6: Define Phase 11 terminal results**

Return only:

```text
READY            -> strict reviewed gates, no unaccepted degradation, all required verification PASS, no integrity issue, complete docs, clean audit, and no policy-blocking follow-up/risk
READY_WITH_NOTES -> audit is internally consistent but accepted degradation, valid exclusions/NOT_RUN handoffs, or non-blocking residual risks/follow-ups remain
NOT_READY        -> failed audit, unresolved blocking gate, invalid finalization, or policy-blocking risk/follow-up
```

Include process schema/hash and typed dirty identity; every accepted phase dispatch/revision; review provenance/growth/convergence; vendor coverage and exposure; decisions/risks/corrections/unverified acceptances; implementation tasks/commits/continuations; full verification matrix; documentation/UAT; follow-ups by actor; recovery/cap statistics; reconciliation; local Git finalization/publication status; runtime manifest; and zero-active-lease evidence.

- [ ] **Step 7: Run focused and full verification**

Run:

```bash
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_10_process_v2.sh
bash tests/check_11_reconciliation.sh
bash tests/run.sh
```

Expected: all offline checks pass; every contradictory/dangling fixture yields `NOT_READY` with exact record IDs, while accepted degradation/exclusions exercise the `READY_WITH_NOTES` boundary.

- [ ] **Step 8: Commit reconciliation and readiness audit**

```bash
git add develop-it-prompt.md tests/lib/v2_fixtures.sh tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_10_process_v2.sh tests/check_11_reconciliation.sh
git commit -m "feat: reconcile propositions and audit readiness"
```

### Task 16: Remove Superseded Behavior and Update Process Documentation

**Files:**
- Modify: `develop-it-prompt.md` (full consistency pass)
- Modify: `README.md`
- Modify: `RUNBOOK.md`
- Modify: `tests/check_01_lint.sh`
- Modify: `tests/check_02_markers.sh`
- Modify: `tests/check_03_varcoverage.sh`
- Modify: `tests/check_05_contract.sh`
- Modify: `tests/check_06_cookbook.sh`
- Modify: `tests/check_07_fakecli.sh`
- Modify: `tests/check_10_process_v2.sh`
- Modify: `tests/check_11_reconciliation.sh`
- Test: all checks through `tests/run.sh`

**Interfaces:**
- Consumes: the complete schema-v2 process from Tasks 1–15.
- Produces: one internally consistent normative prompt, matching user/runbook documentation, negative assertions for obsolete behavior, and a clean offline verification report.

- [ ] **Step 1: Add negative checks for every retired contract**

In `tests/check_05_contract.sh`, reject these obsolete concepts:

```text
finishing-branch role or appendix
implementer Mode C
direct role writes or moves to STATUS
line-number-based Markdown finding identity
unreviewed final fixer acceptance
unbounded retry/review language
subprocess writes to RUN_LOG.md
Phase 10 remote action, push, or pull-request creation
schema-v1 fallback or historical artifact migration
```

Scope patterns to normative sections/code blocks so historical rationale inside the spec is not scanned.

- [ ] **Step 2: Run the full suite and inventory all surviving contradictions**

Run:

```bash
bash tests/run.sh
rg -n 'finishing-branch|Mode C|STATUS\.tmp|line number.*finding|push|pull request|migration|backfill' develop-it-prompt.md README.md RUNBOOK.md
```

Expected before cleanup: at least one failing negative assertion or stale documentation hit; record every hit before editing it.

- [ ] **Step 3: Perform a section-by-section prompt consistency pass**

Read `develop-it-prompt.md` from Inputs through the final appendix. For every section, align phase numbers, role names, paths, caps, identity fields, verdicts, helper names, event names, and stop conditions with Tasks 1–15. Remove duplicate normative tables and obsolete helper definitions rather than leaving compatibility aliases.

- [ ] **Step 4: Update README phase and safety documentation**

Document schema v2, runtime extraction, phase order `-1, 1..11`, attempt-scoped status, bounded recovery, checkpoint continuation, reviewed documentation, orchestrator-only local finalization, no push, and the offline/live test split. State explicitly that existing Prism artifacts remain unchanged.

- [ ] **Step 5: Update RUNBOOK operational procedures**

Add exact operator checks for manifest failure, process-identity mismatch, stale/ambiguous lease, publication loss diagnostics, timeout with mutation state, malformed STATUS, checkpoint resume, review-cap exhaustion, documentation-cap exhaustion, finalization `BLOCKED|FAILED`, contradiction audit, and readiness failure. For each, identify the durable files to inspect and whether safe automatic recovery is allowed by `RM01`–`RM12`.

- [ ] **Step 6: Confirm the launcher remains launcher-only**

Run `bash tests/check_08_launcher.sh`. If it passes unchanged, do not edit `develop-it.sh`. If documentation assertions in the launcher test need schema-v2 wording, edit only the test expectation; do not move process orchestration into the launcher.

- [ ] **Step 7: Run syntax, focused, and complete verification**

Run:

```bash
bash -n develop-it.sh
python3 -m py_compile tests/lib/extract.py tests/lib/verdicts.py
bash tests/check_01_lint.sh
bash tests/check_02_markers.sh
bash tests/check_03_varcoverage.sh
bash tests/check_04_table.sh
bash tests/check_05_contract.sh
bash tests/check_06_cookbook.sh
bash tests/check_07_fakecli.sh
bash tests/check_08_launcher.sh
bash tests/check_09_recovery.sh
bash tests/check_10_process_v2.sh
bash tests/check_11_reconciliation.sh
bash tests/run.sh
```

Expected: every listed command exits 0; normal `tests/run.sh` reports all offline checks passed and only `check_90_live_models.sh` skipped.

- [ ] **Step 8: Verify scope and immutable historical artifacts**

Run:

```bash
git status --short
first_task_commit=$(git log --grep='^test: establish process schema v2 contracts$' --format='%H' -1)
test -n "$first_task_commit"
git diff --name-only "$first_task_commit^"..HEAD
git -C /home/oleks/repos/prism status --short -- docs/superpowers/specs
```

Expected: changes are limited to the process repository paths listed in this plan; the Prism command reports no changes caused by this implementation. Do not clean or alter pre-existing unrelated Prism changes if any are reported.

- [ ] **Step 9: Commit the final consistency and documentation pass**

```bash
git add develop-it-prompt.md README.md RUNBOOK.md tests/check_01_lint.sh tests/check_02_markers.sh tests/check_03_varcoverage.sh tests/check_05_contract.sh tests/check_06_cookbook.sh tests/check_07_fakecli.sh tests/check_10_process_v2.sh tests/check_11_reconciliation.sh
git commit -m "docs: finalize schema v2 process guidance"
```

- [ ] **Step 10: Produce the implementation handoff evidence**

Run:

```bash
git status --short
git log --oneline -16
bash tests/run.sh
```

Expected: the implementation paths are clean; at least 16 task commits are visible in order (plus any narrowly scoped correction commits created during task review); all offline checks pass with the optional live check skipped.

## Requirement and Review-Finding Coverage

| Source requirement | Implemented by |
|---|---|
| R01–R02: Claude CWD and safe long/nested work | Task 5 |
| R03–R04: attempt identity and canonical STATUS | Task 4 |
| R05–R07: checkpoints, recovery, unified dispatch | Tasks 6–9 |
| R08–R09: role registry and proven dual-vendor coverage | Tasks 2, 10 |
| R10–R12: convergence, rereview, bounded document fixing | Task 11 |
| R13–R14: decisions/corrections and write integrity | Task 8 |
| R15–R16: executable plans and dedicated implementation fixer | Tasks 12–13 |
| R17–R18: single extracted runtime and exact reconciliation | Tasks 3, 15 |
| R19–R20: documentation/handoff and optional-skill routing | Tasks 10, 14 |
| R21–R22: artifact sanity and context7 precedence | Tasks 11, 15 |
| R23–R24: zero-token gates and typed process identity | Task 10 |
| Acceptance criteria 1–30 and obsolete-contract removal | Task 16 plus the focused task checks |
| Review: heading/AST-based finding identity | Task 11, Steps 1 and 4–5 |
| Review: orchestrator finalization lease authority | Task 14, Steps 1 and 5–6 |
| Review: atomic `.runtime.tmp` replacement | Task 3, Steps 1 and 4–6 |
| Review: publication-loss size/header diagnostics | Task 4, Step 5 |
| Review: every recovery matrix row covered by fake CLI | Task 7, Steps 1 and 6 |

| Acceptance criteria | Verification tasks |
|---|---|
| 1–6: CWD, unique attempt evidence, stale isolation, publisher, parallel timing, foreground children | Tasks 4–6 |
| 7–11: deterministic recovery, bounded retries, continuation safety, lease integrity, causal events | Tasks 7–9 |
| 12–17: producer gates, fixer dispositions/rereview, provenance/convergence, dedicated fixer, vendor coverage | Tasks 10–13 |
| 18–21: executable actors/environments, four-state verification, controlled performance, durable SDD | Tasks 9, 12–13 |
| 22–25: zero-token gates, typed identity, optional-skill routing, latest context7 precedence | Tasks 10, 15 |
| 26–29: docs/UAT/follow-ups, local orchestrator finalization, reconciliation, readiness disclosure | Tasks 14–15 |
| 30: deterministic offline suite and unchanged Prism artifact folders | Task 16 |

## Final Implementation Invariants

- `develop-it-prompt.md` remains the sole normative implementation source; tests extract and execute it rather than maintaining a second production runtime.
- The integrated revision is installed section by section by the 16 tasks and becomes active as one schema-v2 process after Task 16; intermediate commits are development checkpoints, not separately supported process versions.
- No task changes historical generated artifacts or adds a data migration.
- Every new automatic action is bounded by a named policy value and produces durable evidence.
- Every accepted mutation has a lease, before/after snapshot, declared paths, verification evidence, and a later independent review where required.
- Phase 10 is the only local commit phase and runs directly under orchestrator authority; no process phase performs remote Git actions.
