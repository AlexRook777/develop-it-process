# develop-it-process Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `develop-it-process.md` run correctly on this machine, reassign its models (Fable authoring / Opus review+supervision / Sonnet mechanical / gpt-5.6-sol Codex review), and ship runnable checks that prevent the drift that broke it.

**Architecture:** The document is the single source of truth. Its shell helpers live in fenced blocks classified by a `<!-- lint: cookbook -->` marker; a test-time extractor pulls those blocks into one sourceable file, and the test suite exercises *that extracted code*. Document facts (the role table, appendix markers, variable lists) are parsed out of the markdown and asserted against the extracted functions, so a table and its implementation cannot disagree. Document-only edits are driven by grep-based contract assertions that fail before the edit and pass after.

**Tech Stack:** bash 5.3, python3 (extraction + parsing), jq, git, GNU coreutils where available (uutils elsewhere — see constraints), `shellcheck` as a test-time-only prerequisite. No test framework: `bats` is not installed and is not being added.

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include these.

- **Target:** Ubuntu 26.04, bash 5.3.9. No support for a non-Linux host.
- **coreutils is uutils 0.8.0** for `date`, `sha256sum`, `cut`, `tr`, `tail`, `mkdir`, `timeout`. `date +%s%3N` is **not** honoured — never use it. Use bash `EPOCHREALTIME`.
- **`awk` is mawk 1.3.4**, not gawk. No gawk extensions.
- **`grep` must be pinned** via `GREP_BIN="${GREP_BIN:-/usr/bin/grep}"`. A bare `grep` may resolve to a shell-function shim that does not exist in subprocess shells.
- **No POSIX-ERE extensions**: `\S`, `\d`, `\w` are forbidden in `grep -E` patterns.
- **`python3` is a hard requirement**, not warn-only.
- **Shell policy: `set -uo pipefail`. Never `set -e`** — helpers signal via return codes the orchestrator branches on.
- **No new runtime dependencies.** `setsid`, `realpath`, `flock`, `jq`, `git`, `python3` are all already present and verified.
- **Pinned model ids, no fallback chains:** `claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`, `gpt-5.6-sol`. A rejected id HALTs. The word "fallback" must never be applied to model selection.
- **Codex global-option ordering:** `-a`, `-c`, `-m` appear **before** `exec`. `codex exec -a never` does not parse.
- **Forbidden codex models:** never pass `*-codex-max`, `o3`, `o3-mini`, or any `o*` id.
- **`timeout` grace period is uniform:** `--kill-after=60s`.
- Test check exit codes: `0` = PASS, `1` = FAIL, `77` = SKIP. A SKIP is never counted as success.

**Reference paths used throughout:**
- Document under rework: `develop-it-process.md` (repo root)
- Spec: `docs/superpowers/specs/2026-07-29-develop-it-process-rework-design.md`

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `tests/run.sh` | Discovers and runs `tests/check_*.sh`; tallies PASS/FAIL/SKIP; `--live` opts into tier 2 |
| `tests/lib/assert.sh` | Assertion helpers and failure counter. Sourced by every check |
| `tests/lib/extract.py` | Parses the document; extracts `lint: cookbook` and `lint: snippet` blocks; emits the role table as TSV |
| `tests/check_01_lint.sh` | Tier 1 check 1 — `bash -n` all blocks, `shellcheck` the cookbook |
| `tests/check_02_markers.sh` | Tier 1 check 3 — marker balance; no constructed appendix names |
| `tests/check_03_varcoverage.sh` | Tier 1 check 4 — every `$VAR` in an appendix is substituted by `render_prompt` |
| `tests/check_04_table.sh` | Tier 1 check 6 — role table agrees with `role_model`/`role_effort`/`role_timeout` |
| `tests/check_05_contract.sh` | Regression guard — the §10 grep criteria. Grows one assertion per document task |
| `tests/check_06_cookbook.sh` | Tier 1 check 2 — unit tests of extracted cookbook helpers |
| `tests/check_07_fakecli.sh` | Tier 1 check 5 — fake-CLI integration: detached dispatch, timeout kill, resume, `--add-dir` |
| `tests/check_90_live_models.sh` | Tier 2 — live model probe. Skips unless `--live` |
| `tests/fakebin/claude` | Stub CLI: records argv, emits canned JSON, configurable rc/delay |
| `tests/fakebin/codex` | Stub CLI: records argv, emits canned JSONL, configurable rc/delay |
| `tests/fixtures/claude-usage.json` | Claude telemetry fixture |
| `tests/fixtures/codex-usage.jsonl` | Codex telemetry fixture with `turn.completed` |
| `tests/fixtures/codex-no-turn.jsonl` | Codex telemetry fixture **without** `turn.completed` |

**Modified:** `develop-it-process.md` — every task from 5 onward.

**Generated at test time, never committed:** `tests/.build/cookbook.sh`, `tests/.build/snippets/`, `tests/.build/roles.tsv`.

---

## Task 1: Test harness foundation

**Files:**
- Create: `tests/run.sh`, `tests/lib/assert.sh`, `tests/lib/extract.py`, `tests/.gitignore`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `tests/lib/assert.sh` exports `assert_eq <expected> <actual> <msg>`, `assert_present <pattern> <file> <msg>`, `assert_absent <pattern> <file> <msg>`, `assert_rc <expected> <actual> <msg>`, `note <msg>`, `finish` (exits 0 or 1 based on `_FAILURES`), and `skip <msg>` (exits 77). Variable `PROCESS_DOC` = absolute path to `develop-it-process.md`. Variable `BUILD` = `tests/.build`.
  - `tests/lib/extract.py` CLI: `extract.py cookbook` writes `$BUILD/cookbook.sh`; `extract.py snippets` writes `$BUILD/snippets/NNN.sh`; `extract.py roles` writes `$BUILD/roles.tsv` with columns `role`, `vendor`, `model`, `effort`, `timeout_min`; `extract.py unmarked` prints line numbers of `bash` fences lacking a lint marker.
  - `tests/run.sh` accepts `--live`.

- [ ] **Step 1: Write the failing test**

Create `tests/check_00_selftest.sh`:

```bash
#!/usr/bin/env bash
# Self-test: the harness itself works.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

assert_eq "a" "a" "assert_eq accepts equal values"
assert_present '^# Universal SDLC' "$PROCESS_DOC" "process doc is readable and looks right"
assert_absent 'ZZZ_NEVER_PRESENT_ZZZ' "$PROCESS_DOC" "assert_absent works"

# extract.py must produce a non-empty cookbook
python3 lib/extract.py cookbook || { note "extract.py cookbook failed"; _FAILURES=$((_FAILURES+1)); }
if [ -s "$BUILD/cookbook.sh" ]; then
  note "cookbook extracted ($(wc -l < "$BUILD/cookbook.sh") lines)"
else
  note "FAIL: $BUILD/cookbook.sh is empty or missing"
  _FAILURES=$((_FAILURES+1))
fi

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/check_00_selftest.sh`
Expected: FAIL — `lib/assert.sh: No such file or directory`

- [ ] **Step 3: Implement `tests/lib/assert.sh`**

```bash
# shellcheck shell=bash
# Assertion helpers for develop-it-process checks.
# Exit codes: 0 PASS, 1 FAIL, 77 SKIP.

GREP_BIN="${GREP_BIN:-/usr/bin/grep}"
_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_TOP="$(cd "$_TESTS_DIR/.." && pwd)"
PROCESS_DOC="${PROCESS_DOC:-$REPO_TOP/develop-it-process.md}"
BUILD="${BUILD:-$_TESTS_DIR/.build}"
mkdir -p "$BUILD"

_FAILURES=0

note() { printf '    %s\n' "$*"; }

_ok()   { printf '  ok   %s\n' "$*"; }
_fail() { printf '  FAIL %s\n' "$*"; _FAILURES=$((_FAILURES + 1)); }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then _ok "$msg"
  else _fail "$msg"; note "expected: [$expected]"; note "actual:   [$actual]"; fi
}

assert_rc() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" -eq "$actual" ]; then _ok "$msg"
  else _fail "$msg (expected rc=$expected, got rc=$actual)"; fi
}

assert_present() {
  local pattern="$1" file="$2" msg="$3"
  if "$GREP_BIN" -qE -- "$pattern" "$file"; then _ok "$msg"
  else _fail "$msg"; note "pattern not found: $pattern"; note "in: $file"; fi
}

assert_absent() {
  local pattern="$1" file="$2" msg="$3"
  local hits
  hits="$("$GREP_BIN" -nE -- "$pattern" "$file" | head -5)"
  if [ -z "$hits" ]; then _ok "$msg"
  else _fail "$msg"; note "pattern should be absent: $pattern"; printf '    %s\n' "$hits"; fi
}

skip() { printf '  SKIP %s\n' "$*"; exit 77; }

finish() {
  if [ "$_FAILURES" -eq 0 ]; then printf '  -- all assertions passed\n'; exit 0; fi
  printf '  -- %d assertion(s) failed\n' "$_FAILURES"
  exit 1
}
```

- [ ] **Step 4: Implement `tests/lib/extract.py`**

```python
#!/usr/bin/env python3
"""Extract lint-classified shell blocks and the role table from the process doc.

Block classification: a fenced ```bash block is classified by the nearest
preceding HTML comment of the form <!-- lint: cookbook --> or <!-- lint: snippet -->,
searching upward past blank lines only. Anything else is 'unmarked'.
"""
import os
import pathlib
import re
import sys

REPO_TOP = pathlib.Path(__file__).resolve().parents[2]
DOC = pathlib.Path(os.environ.get("PROCESS_DOC", REPO_TOP / "develop-it-process.md"))
BUILD = pathlib.Path(os.environ.get("BUILD", REPO_TOP / "tests" / ".build"))

MARKER = re.compile(r"^<!--\s*lint:\s*(cookbook|snippet)\s*-->\s*$")
FENCE_OPEN = re.compile(r"^```bash\s*$")
FENCE_CLOSE = re.compile(r"^```\s*$")

# Preamble for snippet blocks: they legitimately reference orchestration
# variables they do not define, so declare them to keep `bash -n` and
# shellcheck focused on real syntax errors rather than SC2154.
SNIPPET_PREAMBLE = """#!/usr/bin/env bash
# AUTO-GENERATED by tests/lib/extract.py -- do not edit.
set -uo pipefail
PROCESS_PATH=/dev/null; REPO_ROOT=/tmp; PROCESS_REPO_ROOT=/tmp
FEATURE_FOLDER=/tmp/ff; SPEC_PATH=/dev/null; PLAN_PATH=/dev/null
FINDINGS_PATHS=""; ITERATION=01; ROUND=01; TEST_REPORT_PATH=/dev/null
IMPLEMENTATION_BASE_SHA=deadbeef; IMPLEMENTATION_SUMMARY_PATH=/dev/null
DEBUGGER_STATUS_PATH=/dev/null; PYTHON_BIN=python3; GREP_BIN=/usr/bin/grep
CLAUDE_MODEL=claude-sonnet-5; CODEX_MODEL=gpt-5.6-sol; STATUS=/dev/null
codex_available=false; role=noop; out_json=/dev/null; wall_ms=0
"""


def blocks():
    """Yield (kind, start_line, [body_lines]) for every fenced bash block."""
    lines = DOC.read_text().splitlines()
    i = 0
    while i < len(lines):
        if FENCE_OPEN.match(lines[i]):
            # Walk upward past blank lines looking for a lint marker.
            kind = "unmarked"
            j = i - 1
            while j >= 0 and lines[j].strip() == "":
                j -= 1
            if j >= 0:
                m = MARKER.match(lines[j])
                if m:
                    kind = m.group(1)
            body, k = [], i + 1
            while k < len(lines) and not FENCE_CLOSE.match(lines[k]):
                body.append(lines[k])
                k += 1
            yield kind, i + 1, body
            i = k + 1
        else:
            i += 1


def cmd_cookbook():
    BUILD.mkdir(parents=True, exist_ok=True)
    out = ["#!/usr/bin/env bash",
           "# AUTO-GENERATED by tests/lib/extract.py -- do not edit.",
           "# shellcheck shell=bash"]
    found = 0
    for kind, line, body in blocks():
        if kind != "cookbook":
            continue
        found += 1
        out.append(f"# --- from {DOC.name}:{line} ---")
        out.extend(body)
    if not found:
        sys.stderr.write("extract.py: no 'lint: cookbook' blocks found\n")
        return 1
    (BUILD / "cookbook.sh").write_text("\n".join(out) + "\n")
    return 0


def cmd_snippets():
    d = BUILD / "snippets"
    d.mkdir(parents=True, exist_ok=True)
    for f in d.glob("*.sh"):
        f.unlink()
    for kind, line, body in blocks():
        if kind != "snippet":
            continue
        (d / f"{line:04d}.sh").write_text(SNIPPET_PREAMBLE + "\n".join(body) + "\n")
    return 0


def cmd_unmarked():
    rc = 0
    for kind, line, _ in blocks():
        if kind == "unmarked":
            print(line)
            rc = 1
    return rc


def cmd_roles():
    """Emit the role table as TSV: role, vendor, model, effort, timeout_min.

    The table is located by its header row, which must contain all five
    column names. Cells are stripped of backticks and surrounding space.
    An em-dash or empty cell becomes the empty string.
    """
    BUILD.mkdir(parents=True, exist_ok=True)
    rows, in_table = [], False
    for raw in DOC.read_text().splitlines():
        if not raw.startswith("|"):
            if in_table:
                break
            continue
        cells = [c.strip().strip("`").strip() for c in raw.strip().strip("|").split("|")]
        low = [c.lower() for c in cells]
        if not in_table:
            if {"role", "vendor", "model", "effort", "timeout"} <= set(
                w for c in low for w in c.split()
            ):
                in_table = True
            continue
        if set("".join(cells)) <= set("-: "):
            continue  # separator row
        if len(cells) < 5:
            continue
        role, vendor, model, effort, timeout = cells[:5]
        norm = lambda v: "" if v in {"—", "-", "n/a", ""} else v  # noqa: E731
        rows.append("\t".join([role, norm(vendor), norm(model),
                               norm(effort), norm(timeout)]))
    if not rows:
        sys.stderr.write("extract.py: role table not found\n")
        return 1
    (BUILD / "roles.tsv").write_text("\n".join(rows) + "\n")
    return 0


CMDS = {"cookbook": cmd_cookbook, "snippets": cmd_snippets,
        "roles": cmd_roles, "unmarked": cmd_unmarked}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in CMDS:
        sys.stderr.write(f"usage: extract.py {{{'|'.join(CMDS)}}}\n")
        sys.exit(2)
    sys.exit(CMDS[sys.argv[1]]())
```

- [ ] **Step 5: Implement `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Runner for develop-it-process checks.
#   ./tests/run.sh          tier 1 only (offline, deterministic, free)
#   ./tests/run.sh --live   tier 1 + tier 2 (live model probe; billable)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

LIVE=no
[ "${1:-}" = "--live" ] && LIVE=yes

pass=0 fail=0 skipped=0 failed_names=()

for check in check_*.sh; do
  case "$check" in
    check_9*) [ "$LIVE" = yes ] || { printf '\n== %s\n  SKIP tier 2; pass --live to run\n' "$check"
                                    skipped=$((skipped + 1)); continue; } ;;
  esac
  printf '\n== %s\n' "$check"
  bash "$check"
  case "$?" in
    0)  pass=$((pass + 1)) ;;
    77) skipped=$((skipped + 1)) ;;
    *)  fail=$((fail + 1)); failed_names+=("$check") ;;
  esac
done

printf '\n----------------------------------------\n'
printf 'passed: %d  failed: %d  skipped: %d\n' "$pass" "$fail" "$skipped"
if [ "$skipped" -gt 0 ]; then
  printf 'NOTE: skipped checks are NOT successes.\n'
fi
if [ "$fail" -gt 0 ]; then
  printf 'failed: %s\n' "${failed_names[*]}"
  exit 1
fi
exit 0
```

- [ ] **Step 6: Make scripts executable and ignore the build dir**

```bash
chmod +x tests/run.sh tests/lib/extract.py tests/check_00_selftest.sh
printf '.build/\n' > tests/.gitignore
```

- [ ] **Step 7: Run the self-test to verify it now fails only on the cookbook**

Run: `bash tests/check_00_selftest.sh`
Expected: the three assertions pass; `extract.py cookbook` FAILS with `no 'lint: cookbook' blocks found`, because no block in the document is marked yet. This is correct — Task 21 adds the markers.

To keep the suite green in the meantime, make the self-test tolerate an unmarked document by treating a missing cookbook as a skip:

```bash
# Replace the cookbook stanza in tests/check_00_selftest.sh with:
if python3 lib/extract.py cookbook 2>/dev/null && [ -s "$BUILD/cookbook.sh" ]; then
  note "cookbook extracted ($(wc -l < "$BUILD/cookbook.sh") lines)"
else
  note "cookbook not yet extractable (no lint markers) -- expected until Task 21"
fi
```

- [ ] **Step 8: Run the full runner**

Run: `bash tests/run.sh`
Expected: `passed: 1  failed: 0  skipped: 0`

- [ ] **Step 9: Commit**

```bash
git add tests/ .gitignore
git commit -m "test: add harness foundation (runner, assertions, block extractor)"
```

---

## Task 2: Marker integrity check

**Files:**
- Create: `tests/check_02_markers.sh`

**Interfaces:**
- Consumes: `tests/lib/assert.sh` (`PROCESS_DOC`, `assert_eq`, `finish`, `note`)
- Produces: nothing consumed by later tasks. This check must PASS on the current document for balance, and FAIL on the constructed-name rule until Task 13 fixes it.

**Context:** Real appendix markers sit at column 0 and match `^<!-- (BEGIN|END): [a-z0-9-]+ -->$`. Two lines inside helper code ([:383](../../../develop-it-process.md), [:406](../../../develop-it-process.md)) contain marker *template strings* and must not be counted — anchoring at column 0 excludes them. Verified: 23 balanced pairs.

- [ ] **Step 1: Write the failing test**

Create `tests/check_02_markers.sh`:

```bash
#!/usr/bin/env bash
# Check 3: appendix marker integrity.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

begins="$("$GREP_BIN" -oP '^<!-- BEGIN: \K[a-z0-9-]+(?= -->$)' "$PROCESS_DOC" | sort)"
ends="$("$GREP_BIN"   -oP '^<!-- END: \K[a-z0-9-]+(?= -->$)'   "$PROCESS_DOC" | sort)"

assert_eq "$begins" "$ends" "every BEGIN marker has a matching END marker"

# Duplicate names would make awk range extraction span two appendices.
dupes="$(printf '%s\n' "$begins" | uniq -d)"
assert_eq "" "$dupes" "no duplicate appendix names"

# Every appendix name referenced in prose must exist as a marker pair.
missing=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$begins" | "$GREP_BIN" -qxF "$name" || missing="$missing $name"
done < <("$GREP_BIN" -oP '(?<=`)(?:preflight|spec|plan|code|context|summarizer|readiness|all-tests|test|finishing)[a-z0-9-]*(?=` appendix)' "$PROCESS_DOC" | sort -u)
assert_eq "" "$missing" "every appendix name referenced in prose has a marker pair"

# The Phase-7 bug class: an appendix name assembled from a variable cannot be
# statically resolved, and no value of $phase yields 'code-reviewer-claude'.
constructed="$("$GREP_BIN" -nE '(render_prompt|extract_appendix) +"?\$\{' "$PROCESS_DOC")"
if [ -z "$constructed" ]; then
  _ok "no appendix name is constructed from a variable"
else
  _fail "appendix names must be literal, not interpolated"
  printf '    %s\n' "$constructed"
fi

finish
```

- [ ] **Step 2: Run it**

Run: `bash tests/check_02_markers.sh`
Expected: first three assertions PASS; the constructed-name assertion FAILS listing lines 851 and 863. Overall rc=1. This is the intended red state — Task 13 turns it green.

- [ ] **Step 3: Record the expected-red state**

Add to the top of the file, below the shebang comment:

```bash
# EXPECTED RED until Task 13 (parallel-dispatch appendix naming).
```

- [ ] **Step 4: Commit**

```bash
chmod +x tests/check_02_markers.sh
git add tests/check_02_markers.sh
git commit -m "test: add appendix marker integrity check (red: constructed names)"
```

---

## Task 3: Variable coverage check

**Files:**
- Create: `tests/check_03_varcoverage.sh`

**Interfaces:**
- Consumes: `tests/lib/assert.sh`
- Produces: nothing. Must FAIL until Task 14 adds `$ROUND` and `$TEST_REPORT_PATH` to `render_prompt`.

**Context:** `render_prompt`'s substitution list ([:413-423](../../../develop-it-process.md)) omits `$ROUND` and `$TEST_REPORT_PATH`, so the `all-tests-runner` and `test-fixer` appendices render with those literals intact.

- [ ] **Step 1: Write the failing test**

Create `tests/check_03_varcoverage.sh`:

```bash
#!/usr/bin/env bash
# Check 4: every $VAR used in an appendix body is substituted by render_prompt.
# EXPECTED RED until Task 14 (render_prompt hardening).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

# Variables that are documented placeholders, not substitution targets.
ALLOW_UNSUBSTITUTED="PROCESS_PATH REPO_ROOT PROCESS_REPO_ROOT"

# 1. Collect every $VAR appearing between BEGIN/END marker pairs.
used="$(python3 - "$PROCESS_DOC" <<'PY' | sort -u
import re, sys
text = open(sys.argv[1]).read()
bodies = re.findall(r"^<!-- BEGIN: [a-z0-9-]+ -->$(.*?)^<!-- END: [a-z0-9-]+ -->$",
                    text, re.S | re.M)
for b in bodies:
    for m in re.finditer(r"\$([A-Z][A-Z0-9_]{2,})", b):
        print(m.group(1))
PY
)"

# 2. Collect the substitution list from render_prompt's python body.
subst="$(python3 - "$PROCESS_DOC" <<'PY' | sort -u
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"for key in \[(.*?)\]:", text, re.S)
if m:
    for q in re.findall(r'"([A-Z][A-Z0-9_]*)"', m.group(1)):
        print(q)
PY
)"

if [ -z "$subst" ]; then
  _fail "could not locate render_prompt's substitution list"
  finish
fi

missing=""
while IFS= read -r v; do
  [ -n "$v" ] || continue
  case " $ALLOW_UNSUBSTITUTED " in *" $v "*) continue ;; esac
  printf '%s\n' "$subst" | "$GREP_BIN" -qxF "$v" || missing="$missing $v"
done <<< "$used"

assert_eq "" "$missing" "every appendix variable is in render_prompt's substitution list"
note "appendix vars found: $(printf '%s' "$used" | tr '\n' ' ')"
note "substituted:         $(printf '%s' "$subst" | tr '\n' ' ')"

finish
```

- [ ] **Step 2: Run it**

Run: `bash tests/check_03_varcoverage.sh`
Expected: FAIL — `missing` contains at least `ROUND` and `TEST_REPORT_PATH`.

- [ ] **Step 3: Commit**

```bash
chmod +x tests/check_03_varcoverage.sh
git add tests/check_03_varcoverage.sh
git commit -m "test: add appendix variable coverage check (red: ROUND, TEST_REPORT_PATH)"
```

---

## Task 4: Role table / function agreement check

**Files:**
- Create: `tests/check_04_table.sh`

**Interfaces:**
- Consumes: `tests/lib/assert.sh`, `tests/lib/extract.py roles`, `$BUILD/cookbook.sh`
- Produces: the contract Task 5 must satisfy — a role table whose first column is the **role key** (matching an appendix name, or `impl-worker`, or `orchestrator`), with columns `Role | Vendor | Model | Effort | Timeout`, and cookbook functions `role_model`, `role_effort`, `role_timeout` agreeing with it for every row.

- [ ] **Step 1: Write the failing test**

Create `tests/check_04_table.sh`:

```bash
#!/usr/bin/env bash
# Check 6: the role table and the role_* lookups are one source of truth.
# EXPECTED RED until Task 5 (role_* functions + table rewrite).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

python3 lib/extract.py roles 2>/dev/null || { _fail "role table not parseable"; finish; }
python3 lib/extract.py cookbook 2>/dev/null || { _fail "cookbook not extractable"; finish; }
# shellcheck source=/dev/null
source "$BUILD/cookbook.sh" || { _fail "cookbook.sh failed to source"; finish; }

for fn in role_model role_effort role_timeout; do
  if declare -F "$fn" >/dev/null; then _ok "$fn is defined"
  else _fail "$fn is not defined in the cookbook"; fi
done
[ "$_FAILURES" -eq 0 ] || finish

rows=0
while IFS=$'\t' read -r role vendor model effort timeout; do
  [ -n "$role" ] || continue
  case "$role" in orchestrator) continue ;; esac
  rows=$((rows + 1))
  assert_eq "$model"   "$(role_model   "$role")" "role_model $role"
  assert_eq "$effort"  "$(role_effort  "$role")" "role_effort $role"
  assert_eq "$timeout" "$(role_timeout "$role")" "role_timeout $role"
done < "$BUILD/roles.tsv"

assert_eq 24 "$rows" "role table covers all 24 dispatched roles"

# No stale ids, and no model may be named only in the table.
for m in claude-fable-5 claude-opus-5 claude-sonnet-5 gpt-5.6-sol; do
  "$GREP_BIN" -qF "$m" "$BUILD/roles.tsv" || _fail "table never assigns $m"
done

# An unknown role must be a loud error, not an empty string.
if role_model definitely-not-a-role >/dev/null 2>&1; then
  _fail "role_model accepts an unknown role"
else
  _ok "role_model rejects an unknown role"
fi

finish
```

- [ ] **Step 2: Run it**

Run: `bash tests/check_04_table.sh`
Expected: FAIL — `role table not parseable` (the current table has no Timeout column and its first cells are prose).

- [ ] **Step 3: Commit**

```bash
chmod +x tests/check_04_table.sh
git add tests/check_04_table.sh
git commit -m "test: add role table/function agreement check (red: no role_* yet)"
```

---

## Task 5: `role_model` / `role_effort` / `role_timeout` and the unified role table

**Files:**
- Modify: `develop-it-process.md` — role table at lines 145–166; add a cookbook block in the "Orchestration variables" area (after line 351); merge the timeout table from lines 1404–1418
- Test: `tests/check_04_table.sh` (from Task 4)

**Interfaces:**
- Consumes: the contract from Task 4
- Produces: `role_model <role>`, `role_effort <role>`, `role_timeout <role>` — each echoes a value and returns 0, or writes an error to stderr and returns 1 for an unknown role. `role_effort` echoes empty for claude roles. Every later task calls these instead of naming a model, effort, or timeout.

- [ ] **Step 1: Replace the role table**

In `develop-it-process.md`, replace the table at lines 145–166 with this. Column 1 is the **role key** — it matches an appendix name exactly, so tooling can join on it.

```markdown
| Role | Vendor | Model | Effort | Timeout (min) |
|---|---|---|---|---|
| `orchestrator` | — | — | — | — |
| `preflight-claude` | `claude` | `claude-sonnet-5` | — | 5 |
| `preflight-codex` | `codex` | `gpt-5.6-sol` | `medium` | 5 |
| `context-discovery` | `claude` | `claude-sonnet-5` | — | 15 |
| `spec-reviewer-claude` | `claude` | `claude-opus-5` | — | 40 |
| `spec-reviewer-codex` | `codex` | `gpt-5.6-sol` | `high` | 60 |
| `spec-fixer` | `claude` | `claude-fable-5` | — | 40 |
| `plan-writer` | `claude` | `claude-fable-5` | — | 120 |
| `plan-reviewer-claude` | `claude` | `claude-opus-5` | — | 40 |
| `plan-reviewer-codex` | `codex` | `gpt-5.6-sol` | `high` | 60 |
| `plan-fixer` | `claude` | `claude-fable-5` | — | 40 |
| `implementer` | `claude` | `claude-opus-5` | — | 300 |
| `impl-worker` | `claude` | `claude-sonnet-5` | — | 300 |
| `debugger` | `claude` | `claude-opus-5` | — | 60 |
| `code-reviewer-claude` | `claude` | `claude-opus-5` | — | 60 |
| `code-reviewer-codex` | `codex` | `gpt-5.6-sol` | `high` | 120 |
| `all-tests-runner` | `claude` | `claude-sonnet-5` | — | 60 |
| `test-fixer` | `claude` | `claude-sonnet-5` | — | 60 |
| `finishing-branch` | `claude` | `claude-sonnet-5` | — | 30 |
| `summarizer-spec` | `claude` | `claude-sonnet-5` | — | 20 |
| `summarizer-plan` | `claude` | `claude-sonnet-5` | — | 20 |
| `summarizer-implementation` | `claude` | `claude-sonnet-5` | — | 20 |
| `summarizer-code-review` | `claude` | `claude-sonnet-5` | — | 20 |
| `summarizer-all-tests` | `claude` | `claude-sonnet-5` | — | 20 |
| `readiness-writer` | `claude` | `claude-sonnet-5` | — | 20 |
```

Immediately below the table, add:

```markdown
This table is the only place a model, effort, or timeout is stated. The
`role_model` / `role_effort` / `role_timeout` helpers in the Runtime cookbook
implement it, and `tests/check_04_table.sh` asserts the two agree for every row —
they cannot drift. `impl-worker` is the pinned agent type used by the
implementer's sub-subagents; its timeout matches the implementer's because it
runs inside that dispatch.
```

- [ ] **Step 2: Add the cookbook block**

In the "Runtime cookbook & guardrails" section, immediately after the "Orchestration variables" block (line 351), insert this — the `<!-- lint: cookbook -->` marker is required:

````markdown
### Role → model / effort / timeout

<!-- lint: cookbook -->
```bash
# Single source of truth for per-role dispatch parameters. Mirrors the Models
# table exactly; tests/check_04_table.sh enforces the mirror.
# Fields: <model> <effort> <timeout_minutes>.  '-' means empty.
_role_row() {
  case "$1" in
    preflight-claude)          echo "claude-sonnet-5 - 5" ;;
    preflight-codex)           echo "gpt-5.6-sol medium 5" ;;
    context-discovery)         echo "claude-sonnet-5 - 15" ;;
    spec-reviewer-claude)      echo "claude-opus-5 - 40" ;;
    spec-reviewer-codex)       echo "gpt-5.6-sol high 60" ;;
    spec-fixer)                echo "claude-fable-5 - 40" ;;
    plan-writer)               echo "claude-fable-5 - 120" ;;
    plan-reviewer-claude)      echo "claude-opus-5 - 40" ;;
    plan-reviewer-codex)       echo "gpt-5.6-sol high 60" ;;
    plan-fixer)                echo "claude-fable-5 - 40" ;;
    implementer)               echo "claude-opus-5 - 300" ;;
    impl-worker)               echo "claude-sonnet-5 - 300" ;;
    debugger)                  echo "claude-opus-5 - 60" ;;
    code-reviewer-claude)      echo "claude-opus-5 - 60" ;;
    code-reviewer-codex)       echo "gpt-5.6-sol high 120" ;;
    all-tests-runner)          echo "claude-sonnet-5 - 60" ;;
    test-fixer)                echo "claude-sonnet-5 - 60" ;;
    finishing-branch)          echo "claude-sonnet-5 - 30" ;;
    summarizer-spec)           echo "claude-sonnet-5 - 20" ;;
    summarizer-plan)           echo "claude-sonnet-5 - 20" ;;
    summarizer-implementation) echo "claude-sonnet-5 - 20" ;;
    summarizer-code-review)    echo "claude-sonnet-5 - 20" ;;
    summarizer-all-tests)      echo "claude-sonnet-5 - 20" ;;
    readiness-writer)          echo "claude-sonnet-5 - 20" ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
}

_role_field() {
  local row field
  row="$(_role_row "$1")" || return 1
  field="$(printf '%s\n' "$row" | cut -d' ' -f"$2")"
  [ "$field" = "-" ] && field=""
  printf '%s\n' "$field"
}

role_model()   { _role_field "$1" 1; }
role_effort()  { _role_field "$1" 2; }
role_timeout() { _role_field "$1" 3; }
```
````

- [ ] **Step 3: Delete the superseded timeout table**

Remove the per-subprocess timeout table at lines 1404–1418 and replace the section body with:

```markdown
Timeouts are per-role and defined once, in the Models table. Resolve with
`role_timeout <role>`; every invocation wraps the CLI in
`timeout --kill-after=60s "$(role_timeout "$role")m"`. No literal minute value
appears anywhere else in this document.
```

- [ ] **Step 4: Run the check to verify it now passes**

Run: `bash tests/check_04_table.sh`
Expected: PASS — 24 rows, every `role_model`/`role_effort`/`role_timeout` matching, unknown role rejected.

- [ ] **Step 5: Verify the self-test still passes and the cookbook extracts**

Run: `bash tests/run.sh`
Expected: `check_00_selftest.sh` and `check_04_table.sh` pass; `check_02_markers.sh` and `check_03_varcoverage.sh` still red as documented.

- [ ] **Step 6: Commit**

```bash
git add develop-it-process.md
git commit -m "feat: unify role table and add role_model/role_effort/role_timeout

Column 1 is now the role key, so tooling can join the table to the helpers.
Merges the separate timeout table in; timeout values follow the spec's
phase-text-wins rule, with Codex reviewers raised for high effort."
```

---

## Task 6: Contract regression guard

**Files:**
- Create: `tests/check_05_contract.sh`

**Interfaces:**
- Consumes: `tests/lib/assert.sh`
- Produces: a file that every later document task appends one assertion to. This is how document-only edits get a red-then-green cycle.

- [ ] **Step 1: Write the failing test**

Create `tests/check_05_contract.sh` with the assertions that must hold once the rework lands. Several are red now, by design:

```bash
#!/usr/bin/env bash
# Document contract regressions. Each entry corresponds to a spec success
# criterion. Later tasks append to this file; nothing is ever removed.
# EXPECTED RED until the task named in each assertion message lands.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

D="$PROCESS_DOC"

# --- Task 5: stale model ids ---
assert_absent 'claude-opus-4-8'   "$D" "T5: no claude-opus-4-8"
assert_absent 'claude-sonnet-4-6' "$D" "T5: no claude-sonnet-4-6"

# --- Task 6: strict pinning ---
assert_absent 'gpt-5\.3-codex|gpt-5\.2'  "$D" "T6: no nonexistent codex ids"
assert_absent '[Ff]all ?back.*model|model.*[Ff]all ?back' "$D" \
  "T6: no model fallback language"
assert_present 'codex .*-m "\$CODEX_MODEL"' "$D" "T6: codex model is bound explicitly"

# --- Task 9: environment ---
assert_absent '/home/worker|repos/GCP' "$D" "T9: no foreign hardcoded paths"
assert_present 'PROCESS_PATH="\$\{PROCESS_PATH:\?' "$D" "T9: PROCESS_PATH fails loud"
assert_present 'PROCESS_REPO_ROOT' "$D" "T9: two-root model present"
assert_present 'GREP_BIN' "$D" "T9: grep is pinned"

# --- Task 11: timing ---
assert_absent 'date \+%s%3N' "$D" "T11: no uutils-broken date format"
assert_present 'EPOCHREALTIME' "$D" "T11: EPOCHREALTIME used for ms timing"
assert_absent '^ *local t0=' "$D" "T11: no 'local' outside a function"

# --- Task 12: porcelain parsing ---
assert_absent "awk '\\{print \\\$2\\}'" "$D" "T12: no awk \$2 on porcelain"
assert_absent 'grep -Fvxf' "$D" "T12: no -x match of absolute vs relative paths"
assert_present 'porcelain=v1 -z' "$D" "T12: NUL-delimited porcelain"

# --- Task 13: parallel dispatch ---
assert_absent '(render_prompt|extract_appendix) +"?\$\{' "$D" \
  "T13: appendix names are literal"

# --- Task 15: shell hygiene ---
assert_absent 'export BASH_XTRACEFD' "$D" "T15: BASH_XTRACEFD is not exported"
assert_absent '\\\\S' "$D" "T15: no non-POSIX \\S in ERE"
assert_absent '\] && mv ' "$D" "T15: no trailing [ ] && mv"

# --- Task 18/19: dispatch ---
assert_present 'kill-after=60s' "$D" "T19: uniform kill-after grace"
assert_absent 'timeout [0-9]+m ' "$D" "T19: no literal minute values in invocations"
assert_present 'DISPATCH_STARTED' "$D" "T18: resumable dispatch event"

# --- Task 20: renames ---
assert_absent 'claude-opus-verdict\.md|claude-opus-findings\.md' "$D" \
  "T20: model-free artifact filenames"

# --- Task 21: contradictions ---
assert_present 'lint: cookbook' "$D" "T21: cookbook blocks are lint-classified"

finish
```

- [ ] **Step 2: Run it**

Run: `bash tests/check_05_contract.sh`
Expected: the two Task 5 assertions PASS (Task 5 removed those ids); most others FAIL. Note the failing count — each subsequent task reduces it.

- [ ] **Step 3: Commit**

```bash
chmod +x tests/check_05_contract.sh
git add tests/check_05_contract.sh
git commit -m "test: add document contract regression guard"
```

---

## Task 7: Bind the Codex model and enforce strict pinning

**Files:**
- Modify: `develop-it-process.md` — model-resolution policy (lines 137–143), CLI invocation forms (lines 439–501), `codex_invoke`, the duplicate policy in the `context-discovery` appendix (line 1917), `resolved_models:` schema (lines 1928–1931)
- Test: `tests/check_05_contract.sh`

**Interfaces:**
- Consumes: `role_model`, `role_effort` from Task 5
- Produces: `codex_invoke <role> <out_path> <err_path>` — reads the prompt from stdin, resolves model/effort/timeout from the role, and always passes `--json`. Replaces the old `codex_invoke <mode> …`. `CODEX_MODEL` and `CLAUDE_MODEL` conventions used by every later dispatch site.

- [ ] **Step 1: Rewrite the model-resolution policy**

Replace lines 137–143 with:

```markdown
**Pinned models.** The Models table names exact model ids. There is no class
indirection and no fallback: an id that the CLI rejects HALTs the run with a
remediation message naming the role and the id (see Phase −1). Changing a model
is an edit to this document, which makes it reviewable.

Resolve with the cookbook helpers — never by reading `~/.codex/config.toml`,
and never from a model alias:

```bash
CLAUDE_MODEL="$(role_model "$role")"   # claude --model "$CLAUDE_MODEL"
CODEX_MODEL="$(role_model "$role")"    # codex -m "$CODEX_MODEL" -a never exec …
CODEX_EFFORT="$(role_effort "$role")"
```

**Both vendors are bound explicitly.** Passing effort and `--json` while
omitting `-m` leaves the model set by ambient config outside this document —
the same defect class as an unassigned `$CLAUDE_MODEL`. `codex` accepts
`-m/--model`; it is a global option and appears before `exec`, alongside
`-a never`.

**Forbidden codex models.** Never pass `-m`, `--model`, or `-c model=...` with
`gpt-5.1-codex-max`, `gpt-5-codex-max`, `o3`, `o3-mini`, or any other
`*-codex-max` / `o*` id. These require an OpenAI API key; this account's auth is
a ChatGPT subscription and the request fails with HTTP 400 `"model is not
supported when using Codex with a ChatGPT account"`. This prohibition — not
omitting `-m` — is what prevents that failure. `gpt-5.6-luna` and
`gpt-5.6-terra` are available to this account but deliberately unused.
```

- [ ] **Step 2: Rewrite the CLI invocation forms**

Replace the block at lines 439–466 with a single `<!-- lint: cookbook -->` block:

````markdown
<!-- lint: cookbook -->
```bash
# Claude — prompt on stdin, model and timeout resolved from the role.
# --dangerously-skip-permissions is REQUIRED: claude subprocesses run
# non-interactively and cannot receive approval for Write/Bash calls. Without
# it the subprocess exits rc=0 but never writes its STATUS file.
claude_invoke() {
  # Usage: claude_invoke <role> <out_path> <err_path> [extra args...]
  local role="$1" out="$2" err="$3"; shift 3
  local model timeout
  model="$(role_model "$role")"     || return 1
  timeout="$(role_timeout "$role")" || return 1
  timeout --kill-after=60s "${timeout}m" \
    claude --model "$model" -p --output-format=json \
           --dangerously-skip-permissions "$@" - \
    1> "$out" 2> "$err"
}

# Codex — global options (-a, -c, -m) MUST precede `exec`.
#   -a never              : non-interactive, never pause for approval.
#   -m                    : pins the model; never rely on ~/.codex/config.toml.
#   --skip-git-repo-check : required when $REPO_ROOT is not a Codex trusted dir.
#   --json                : REQUIRED — parse_usage reads JSONL from stdout.
#   -s workspace-write    : read-only blocks the reviewer's own STATUS write.
#   --add-dir             : only when $FEATURE_FOLDER is outside $REPO_ROOT.
codex_invoke() {
  # Usage: codex_invoke <role> <out_path> <err_path> [extra args...]
  # Extra args are accepted for call-site symmetry with claude_invoke; note
  # that --agents is claude-only and never reaches a codex role.
  local role="$1" out="$2" err="$3"; shift 3
  local model effort timeout add_dir=()
  model="$(role_model "$role")"     || return 1
  effort="$(role_effort "$role")"   || return 1
  timeout="$(role_timeout "$role")" || return 1
  [ -n "${FEATURE_FOLDER_OUTSIDE_REPO:-}" ] && add_dir=(--add-dir "$FEATURE_FOLDER")
  timeout --kill-after=60s "${timeout}m" \
    codex -a never -m "$model" -c model_reasoning_effort="$effort" \
      exec -C "$REPO_ROOT" -s workspace-write --skip-git-repo-check --json \
      ${add_dir[@]+"${add_dir[@]}"} "$@" - \
    1> "$out" 2> "$err"
}
```
````

Then replace the old `codex_invoke` helper at lines 478–501 entirely — it is superseded. Update the sentence at line 504 to: `Pass the role; effort and timeout follow from the Models table.`

- [ ] **Step 3: Update the duplicated policy and the resolved_models schema**

At line 1917 (`context-discovery` appendix), replace the resolution instructions with:

```markdown
4. Record the role→model map by calling `role_model` for every role in the
   Models table. Do not invent, alias, or substitute ids; do not consult
   `~/.codex/config.toml`. If any id is rejected, report `verdict=BLOCKED` with
   the rejected role and id — there is no fallback.
```

Replace the `resolved_models:` schema at lines 1928–1931 with a role-keyed map:

```markdown
resolved_models:
  # one line per dispatched role, exactly as role_model returns it
  <role-key>: <model-id>
```

- [ ] **Step 4: Run the contract check**

Run: `bash tests/check_05_contract.sh`
Expected: the four `T6:` assertions now PASS. Others still red per plan.

- [ ] **Step 5: Commit**

```bash
git add develop-it-process.md
git commit -m "feat: bind codex model explicitly and remove all model fallbacks

codex_invoke now takes a role and resolves model/effort/timeout from the table,
always passing --json. Rewrites the 'omit -m entirely' advice, which traded
model pinning for ambient config; the forbidden-id list is what actually
prevents the ChatGPT-auth 400."
```

---

## Task 8: Preflight model probe and canary additions

**Files:**
- Modify: `develop-it-process.md` — `canary_preflight` (lines 510–548), Phase −1 Step 1.0 (lines 903–911)
- Test: `tests/check_05_contract.sh` (append), `tests/check_90_live_models.sh` (create)

**Interfaces:**
- Consumes: `role_model` (Task 5)
- Produces: `canary_preflight` (extended), `probe_models` — returns 0 when every pinned id is accepted, else 1 having printed `role=<role> model=<id>` for each rejection.

- [ ] **Step 1: Append the failing assertions**

Add to `tests/check_05_contract.sh` before `finish`:

```bash
# --- Task 8: canary and model probe ---
for b in git date sha256sum cut mkdir mv tail tr grep setsid realpath flock; do
  assert_present "\"?$b\"? " "$D" "T8: canary checks $b" || true
done
assert_present 'probe_models' "$D" "T8: model probe exists"
assert_present 'python3' "$D" "T8: python3 required"
```

Simplify that loop — a per-binary grep is noisy. Replace with a single assertion on the canary's binary list:

```bash
# --- Task 8: canary and model probe ---
assert_present 'for bin in claude codex timeout awk sed jq git date sha256sum cut mkdir mv tail tr grep setsid realpath flock' \
  "$D" "T8: canary checks every used binary"
assert_present 'probe_models\(\)' "$D" "T8: model probe helper exists"
```

- [ ] **Step 2: Run to verify red**

Run: `bash tests/check_05_contract.sh`
Expected: the two `T8:` assertions FAIL.

- [ ] **Step 3: Extend `canary_preflight`**

Replace the binary loop and the `python3` warning inside `canary_preflight` (lines 512–519) with:

```bash
  local missing=()
  for bin in claude codex timeout awk sed jq git date sha256sum cut mkdir mv tail tr grep setsid realpath flock python3; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  # codex absence is handled by the failover policy, not by this list.
  local codex_present=yes
  command -v codex >/dev/null 2>&1 || codex_present=no
  # python3 is REQUIRED: render_prompt cannot function without it.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "halt: python3 missing — render_prompt requires it" >&2
    return 1
  fi
```

Add the `probe_models` helper to the same `<!-- lint: cookbook -->` block:

```bash
# Verify every pinned model id is accepted. Cheap but NOT free: one minimal
# call per distinct id. A rejection HALTs — there is no fallback.
probe_models() {
  local role model rc=0
  local -A seen=()
  for role in $(_role_keys); do
    model="$(role_model "$role")" || { rc=1; continue; }
    [ -n "${seen[$model]:-}" ] && continue
    seen[$model]=1
    case "$(role_vendor "$role")" in
      claude)
        printf 'ok\n' | claude --model "$model" -p --output-format=json \
          --dangerously-skip-permissions - >/dev/null 2>&1 \
          || { echo "model rejected: role=$role model=$model vendor=claude" >&2; rc=1; } ;;
      codex)
        printf 'ok\n' | codex -a never -m "$model" exec -C "$REPO_ROOT" \
          -s read-only --skip-git-repo-check --json - >/dev/null 2>&1 \
          || { echo "model rejected: role=$role model=$model vendor=codex" >&2; rc=1; } ;;
    esac
  done
  return "$rc"
}
```

This needs two more accessors in the role block. Add them beside `role_model`:

```bash
role_vendor() {
  case "$1" in
    *-codex|preflight-codex) echo codex ;;
    orchestrator) echo "" ;;
    *) echo claude ;;
  esac
}
_role_keys() {
  printf '%s\n' preflight-claude preflight-codex context-discovery \
    spec-reviewer-claude spec-reviewer-codex spec-fixer plan-writer \
    plan-reviewer-claude plan-reviewer-codex plan-fixer implementer \
    impl-worker debugger code-reviewer-claude code-reviewer-codex \
    all-tests-runner test-fixer finishing-branch summarizer-spec \
    summarizer-plan summarizer-implementation summarizer-code-review \
    summarizer-all-tests readiness-writer
}
```

- [ ] **Step 4: Add the probe to Phase −1**

In Phase −1 Step 1.0, insert as a new numbered step after `canary_preflight`:

```markdown
3. Run `probe_models`. Every pinned id in the Models table must be accepted by
   its CLI. On any rejection, HALT: print each `role=<role> model=<id>` line,
   state that this document pins models deliberately and has no fallback, and
   instruct the user to update the Models table. Log
   `event=MODEL_REJECTED` with the offending roles to `RUN_LOG.md` before
   stopping. This is a runtime gate; `tests/check_90_live_models.sh` performs the
   same probe as an opt-in test.
```

Renumber the following steps.

- [ ] **Step 5: Create the tier-2 live check**

Create `tests/check_90_live_models.sh`:

```bash
#!/usr/bin/env bash
# Tier 2: probe each pinned model id against its real CLI.
# Billable and network-dependent; runs only via `tests/run.sh --live`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

command -v claude >/dev/null 2>&1 || skip "claude CLI not on PATH"
command -v codex  >/dev/null 2>&1 || skip "codex CLI not on PATH"

python3 lib/extract.py cookbook 2>/dev/null || { _fail "cookbook not extractable"; finish; }
# shellcheck source=/dev/null
source "$BUILD/cookbook.sh"
REPO_ROOT="$REPO_TOP"

if probe_models; then _ok "every pinned model id is accepted"
else _fail "at least one pinned model id was rejected (see stderr above)"; fi

finish
```

- [ ] **Step 6: Run both**

Run: `bash tests/check_05_contract.sh`
Expected: the two `T8:` assertions PASS.

Run: `bash tests/run.sh`
Expected: `check_90_live_models.sh` reports `SKIP tier 2; pass --live to run`.

- [ ] **Step 7: Commit**

```bash
chmod +x tests/check_90_live_models.sh
git add develop-it-process.md tests/
git commit -m "feat: add model probe gate and complete the canary binary list

Adds probe_models plus the nine used-but-unchecked binaries and the three new
runtime tools. python3 is promoted from warn-only to required, matching the
document's own hard exit. Live probing is also available as an opt-in test."
```

---

## Task 9: Orchestration variables, two roots, and path validation

**Files:**
- Modify: `develop-it-process.md` — orchestration variables block (lines 326–351)
- Test: `tests/check_05_contract.sh`, `tests/check_06_cookbook.sh` (create)

**Interfaces:**
- Consumes: nothing
- Produces: `PROCESS_PATH`, `PROCESS_REPO_ROOT`, `REPO_ROOT`, `FEATURE_FOLDER`, `FEATURE_FOLDER_OUTSIDE_REPO`, `GREP_BIN`, `PYTHON_BIN`, `PROCESS_PATH_REL`; helpers `canon <path>`, `is_git_root <dir>`, `path_in_tree <path> <dir>` (returns 0 when path equals dir or is under `dir/`), `validate_roots` (HALTs on any violation).

- [ ] **Step 1: Write the failing unit test**

Create `tests/check_06_cookbook.sh`:

```bash
#!/usr/bin/env bash
# Check 2: unit tests for extracted cookbook helpers.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

python3 lib/extract.py cookbook 2>/dev/null || { _fail "cookbook not extractable"; finish; }
# shellcheck source=/dev/null
source "$BUILD/cookbook.sh" || { _fail "cookbook.sh failed to source"; finish; }

# --- path_in_tree: boundary-aware directory matching ---
if declare -F path_in_tree >/dev/null; then
  path_in_tree /a/b/c /a/b   && _ok "path_in_tree: child is inside"    || _fail "path_in_tree: child is inside"
  path_in_tree /a/b   /a/b   && _ok "path_in_tree: equal is inside"    || _fail "path_in_tree: equal is inside"
  path_in_tree /a/bc  /a/b   && _fail "path_in_tree: sibling prefix must NOT match" \
                             || _ok "path_in_tree: sibling prefix does not match"
  path_in_tree /a     /a/b   && _fail "path_in_tree: parent must NOT match" \
                             || _ok "path_in_tree: parent does not match"
else
  _fail "path_in_tree is not defined"
fi

# --- canon: normalizes .. and trailing slash ---
if declare -F canon >/dev/null; then
  d="$(mktemp -d)"; mkdir -p "$d/x/y"
  assert_eq "$d/x" "$(canon "$d/x/y/..")" "canon resolves .."
  assert_eq "$d/x" "$(canon "$d/x/")"     "canon strips trailing slash"
  rm -rf "$d"
else
  _fail "canon is not defined"
fi

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_06_cookbook.sh`
Expected: FAIL — `path_in_tree is not defined`, `canon is not defined`.

- [ ] **Step 3: Replace the orchestration variables block**

Replace lines 326–351 with this `<!-- lint: cookbook -->` block:

````markdown
<!-- lint: cookbook -->
```bash
# ---- Tooling pins -----------------------------------------------------------
# `grep` may be a shell-function shim in some harnesses; that shim does not
# exist in subprocess shells and errors differently on the same pattern.
GREP_BIN="${GREP_BIN:-/usr/bin/grep}"
PYTHON_BIN="$(command -v python3 || true)"
if [ -z "$PYTHON_BIN" ]; then
  echo "halt: python3 not on PATH; render_prompt requires it" >&2
  exit 1
fi

# ---- Path helpers -----------------------------------------------------------
canon() { realpath -e -- "$1"; }          # fails if the path does not exist
is_git_root() { [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$1" ]; }

# True when $1 equals $2 or lies under "$2/". Plain prefix tests are wrong:
# they would let /a/bc match the tree /a/b.
path_in_tree() {
  local p="$1" d="${2%/}"
  [ "$p" = "$d" ] || case "$p" in "$d"/*) return 0 ;; *) return 1 ;; esac
}

# ---- The two repositories ---------------------------------------------------
# This document lives in its own repository and orchestrates OTHER projects.
# PROCESS_REPO_ROOT is where this file lives; REPO_ROOT is the project under
# development. They are never the same repository.
PROCESS_PATH="${PROCESS_PATH:?must be set to this document's absolute path}"
REPO_ROOT="${REPO_ROOT:?must be set to the target project repo root}"
FEATURE_FOLDER="${FEATURE_FOLDER:?must be set before dispatching any phase}"

validate_roots() {
  local halt=0
  [ -f "$PROCESS_PATH" ] && [ -r "$PROCESS_PATH" ] \
    || { echo "halt: PROCESS_PATH is not a readable file: $PROCESS_PATH" >&2; return 1; }
  PROCESS_PATH="$(canon "$PROCESS_PATH")" || return 1
  REPO_ROOT="$(canon "$REPO_ROOT")"       || return 1
  PROCESS_REPO_ROOT="$(git -C "$(dirname "$PROCESS_PATH")" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$PROCESS_REPO_ROOT" ] \
    || { echo "halt: $PROCESS_PATH is not inside a git repository" >&2; return 1; }
  PROCESS_REPO_ROOT="$(canon "$PROCESS_REPO_ROOT")" || return 1

  is_git_root "$REPO_ROOT" \
    || { echo "halt: REPO_ROOT is not a git work-tree root: $REPO_ROOT" >&2; halt=1; }
  path_in_tree "$PROCESS_PATH" "$PROCESS_REPO_ROOT" \
    || { echo "halt: PROCESS_PATH is outside PROCESS_REPO_ROOT" >&2; halt=1; }
  [ "$PROCESS_REPO_ROOT" != "$REPO_ROOT" ] \
    || { echo "halt: PROCESS_REPO_ROOT equals REPO_ROOT; the orchestrator would review its own process file" >&2; halt=1; }

  # Path of this document RELATIVE to its own repo — required by `git show
  # HEAD:<path>`, which rejects absolute paths.
  PROCESS_PATH_REL="${PROCESS_PATH#"$PROCESS_REPO_ROOT"/}"

  # Codex's workspace-write sandbox is rooted at $REPO_ROOT. When the feature
  # folder lies outside it, reviewers cannot write their own STATUS and the
  # failure looks like a vendor outage. codex_invoke adds --add-dir in that case.
  if path_in_tree "$(canon "$FEATURE_FOLDER" 2>/dev/null || echo "$FEATURE_FOLDER")" "$REPO_ROOT"; then
    FEATURE_FOLDER_OUTSIDE_REPO=""
  else
    FEATURE_FOLDER_OUTSIDE_REPO=yes
  fi
  return "$halt"
}
```
````

- [ ] **Step 4: Run the unit test**

Run: `bash tests/check_06_cookbook.sh`
Expected: PASS — all six `path_in_tree` / `canon` assertions.

- [ ] **Step 5: Run the contract check**

Run: `bash tests/check_05_contract.sh`
Expected: the four `T9:` assertions now PASS.

- [ ] **Step 6: Commit**

```bash
chmod +x tests/check_06_cookbook.sh
git add develop-it-process.md tests/check_06_cookbook.sh
git commit -m "feat: add two-root model with real path validation

PROCESS_PATH and REPO_ROOT now fail loud rather than defaulting to a dead path
or cwd. Adds canonicalization, git-root checks, boundary-aware subtree matching,
PROCESS_PATH_REL for 'git show HEAD:<path>', and the --add-dir decision."
```

---

## Task 10: Provenance correctness

**Files:**
- Modify: `develop-it-process.md` — provenance block (formerly lines 342–350), `log_dispatch` (lines 652–720), the grammar note at line 84 and line 1497
- Test: `tests/check_05_contract.sh`, `tests/check_06_cookbook.sh`

**Interfaces:**
- Consumes: `PROCESS_REPO_ROOT`, `PROCESS_PATH_REL` (Task 9)
- Produces: `process_identity` — sets `PROCESS_FILE_SHA256`, `PROCESS_GIT_HEAD`, `PROCESS_DIRTY` correctly against the process repo; `log_dispatch <role> <phase> <iteration> <status_path> <verdict> <usage_line>`.

- [ ] **Step 1: Append the failing assertions**

Add to `tests/check_05_contract.sh` before `finish`:

```bash
# --- Task 10: provenance targets the process repo ---
assert_absent 'git rev-parse HEAD 2>/dev/null \|\| echo non-git' "$D" \
  "T10: no bare git rev-parse for provenance"
assert_present 'git -C "\$PROCESS_REPO_ROOT" rev-parse HEAD' "$D" \
  "T10: provenance HEAD comes from the process repo"
assert_present 'HEAD:\$PROCESS_PATH_REL|HEAD:\$\{PROCESS_PATH_REL\}' "$D" \
  "T10: git show uses a repo-relative path"
```

- [ ] **Step 2: Run to verify red**

Run: `bash tests/check_05_contract.sh`
Expected: the three `T10:` assertions FAIL.

- [ ] **Step 3: Replace the provenance block**

Append to the Task 9 cookbook block:

```bash
# ---- Process-file identity (logged in every dispatch entry) -----------------
# All three fields describe THIS document, so every git call targets
# PROCESS_REPO_ROOT. A bare `git` call would report the target project instead.
process_identity() {
  PROCESS_FILE_SHA256="$(sha256sum "$PROCESS_PATH" | cut -d' ' -f1)"
  PROCESS_GIT_HEAD="$(git -C "$PROCESS_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo non-git)"
  if [ "$PROCESS_GIT_HEAD" = non-git ]; then
    PROCESS_DIRTY=unknown
  elif git -C "$PROCESS_REPO_ROOT" diff --quiet HEAD -- "$PROCESS_PATH_REL" 2>/dev/null; then
    PROCESS_DIRTY=no
  else
    PROCESS_DIRTY=yes
  fi
}
```

- [ ] **Step 4: Fix `log_dispatch`**

Inside `log_dispatch`, replace the two provenance lines (formerly 661–663) with reuse of the cached values, and take the role as the first argument so the model field comes from `role_model`:

```bash
log_dispatch() {
  # Usage: log_dispatch <role> <phase> <phase_name> <iteration> <status_path> \
  #                     <verdict> "<usage_line>"
  # Appends exactly one block plus a trailing blank line. Requires
  # process_identity to have run.
  local role="$1" phase="$2" phase_name="$3" iter="$4" status_path="$5"
  local verdict="$6" usage_line="$7"
  local vendor model
  vendor="$(role_vendor "$role")"
  model="$(role_model "$role")"
  {
    printf -- '--- %s  dispatch\n' "$(iso_now)"
    printf 'phase:                    %s\n' "$phase"
    printf 'phase_name:               %s\n' "$phase_name"
    printf 'iteration:                %s\n' "$iter"
    printf 'role:                     %s\n' "$role"
    printf 'vendor:                   %s\n' "$vendor"
    printf 'model:                    %s\n' "$model"
    printf 'appendix:                 %s\n' "$role"
    printf 'develop_it_git_sha:       %s\n' "$PROCESS_GIT_HEAD"
    printf 'develop_it_file_sha256:   %s\n' "$PROCESS_FILE_SHA256"
    printf 'develop_it_dirty:         %s\n' "$PROCESS_DIRTY"
    printf 'status_path:              %s\n' "$status_path"
    printf 'verdict:                  %s\n' "$verdict"
    local kv
    for kv in $usage_line; do
      printf '%-25s %s\n' "${kv%%=*}:" "${kv#*=}"
    done
    printf '\n'
  } >> "$FEATURE_FOLDER/RUN_LOG.md"
}
```

Add the timestamp helper to the same block:

```bash
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
```

- [ ] **Step 5: Correct the grammar prose**

At line 84 and line 1497, replace the `git show HEAD:$PROCESS_PATH` description with:

```markdown
`develop_it_git_sha` is `git -C "$PROCESS_REPO_ROOT" rev-parse HEAD`;
`develop_it_file_sha256` is `sha256sum "$PROCESS_PATH" | cut -d' ' -f1`;
`develop_it_dirty` is `yes` when the working-tree copy differs from
`git -C "$PROCESS_REPO_ROOT" show "HEAD:$PROCESS_PATH_REL"`, `no` when it
matches, and `unknown` outside a git repo. All three describe THIS document, not
the project under development — a bare `git` call would report the wrong repo.
```

- [ ] **Step 6: Add a unit test for the dirty flag**

Append to `tests/check_06_cookbook.sh` before `finish`:

```bash
# --- process_identity targets the process repo, not cwd ---
if declare -F process_identity >/dev/null; then
  tmp="$(mktemp -d)"
  # A decoy "target project" repo with a different HEAD.
  git -C "$tmp" init -q .
  ( cd "$tmp" && : > f && git add f \
    && git -c user.email=t@t -c user.name=t commit -qm decoy )
  PROCESS_PATH="$PROCESS_DOC"
  PROCESS_REPO_ROOT="$REPO_TOP"
  PROCESS_PATH_REL="${PROCESS_DOC#"$REPO_TOP"/}"
  ( cd "$tmp" && process_identity && printf '%s\n' "$PROCESS_GIT_HEAD" ) > "$BUILD/head.txt"
  expected="$(git -C "$REPO_TOP" rev-parse HEAD)"
  assert_eq "$expected" "$(cat "$BUILD/head.txt")" \
    "process_identity reports the process repo HEAD even when cwd is elsewhere"
  rm -rf "$tmp"
else
  _fail "process_identity is not defined"
fi
```

- [ ] **Step 7: Run both checks**

Run: `bash tests/check_06_cookbook.sh`
Expected: PASS, including the new provenance assertion.

Run: `bash tests/check_05_contract.sh`
Expected: the three `T10:` assertions PASS.

- [ ] **Step 8: Commit**

```bash
git add develop-it-process.md tests/check_06_cookbook.sh
git commit -m "fix: record provenance against the process repo, not the target

Every bare git call for provenance reported the target project's HEAD, and the
cross-repo diff exited 128 so develop_it_dirty was a constant 'yes'. Adds
process_identity, threads the role through log_dispatch so the model field comes
from role_model, and adds 'unknown' for the non-git case."
```

---

## Task 11: Millisecond timing and `parse_usage`

**Files:**
- Modify: `develop-it-process.md` — timing snippet (lines 635–650), `parse_usage` (lines 558–650), the usage example at line 716
- Test: `tests/check_05_contract.sh`, `tests/check_06_cookbook.sh`, fixtures

**Interfaces:**
- Consumes: `role_model` (Task 5)
- Produces: `now_ms` (echoes epoch milliseconds), `timed_dispatch` wrapper, `parse_usage <vendor> <stdout-path> <wall-ms> <fallback-model>` emitting nine `key=value` pairs on one line.

- [ ] **Step 1: Create the fixtures**

`tests/fixtures/claude-usage.json`:

```json
{"type":"result","duration_ms":4210,"total_cost_usd":0.0731,
 "modelUsage":{"claude-opus-5":{"inputTokens":1200,"outputTokens":800},
               "claude-haiku-4-5-20251001":{"inputTokens":40,"outputTokens":10}},
 "usage":{"input_tokens":1200,"cache_read_input_tokens":9000,
          "cache_creation_input_tokens":300,"output_tokens":800}}
```

`tests/fixtures/codex-usage.jsonl`:

```json
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":2100,"cached_input_tokens":15000,"output_tokens":640,"reasoning_output_tokens":2048}}
```

`tests/fixtures/codex-no-turn.jsonl`:

```json
{"type":"turn.started"}
{"type":"error","message":"stream disconnected"}
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/check_06_cookbook.sh` before `finish`:

```bash
# --- now_ms returns 13-digit epoch milliseconds (uutils date lacks %3N) ---
if declare -F now_ms >/dev/null; then
  ms="$(now_ms)"
  assert_eq 13 "${#ms}" "now_ms returns 13 digits"
  case "$ms" in ''|*[!0-9]*) _fail "now_ms is not numeric: $ms" ;; *) _ok "now_ms is numeric" ;; esac
else
  _fail "now_ms is not defined"
fi

# --- parse_usage ---
if declare -F parse_usage >/dev/null; then
  out="$(parse_usage claude fixtures/claude-usage.json 4210 claude-opus-5)"
  case "$out" in
    *"model=claude-opus-5"*) _ok "parse_usage picks the main model, not the haiku helper" ;;
    *) _fail "parse_usage main-model selection: $out" ;;
  esac
  case "$out" in
    *"usage_status=ok"*) _ok "parse_usage reports ok for a good claude record" ;;
    *) _fail "parse_usage claude status: $out" ;;
  esac

  out="$(parse_usage codex fixtures/codex-usage.jsonl 900 gpt-5.6-sol)"
  case "$out" in
    *"tokens_reasoning=2048"*) _ok "parse_usage reads codex reasoning tokens" ;;
    *) _fail "parse_usage codex reasoning: $out" ;;
  esac

  # The regression: a transcript with no turn.completed must be 'unavailable',
  # not 'ok' with zeros.
  out="$(parse_usage codex fixtures/codex-no-turn.jsonl 900 gpt-5.6-sol)"
  case "$out" in
    *"usage_status=unavailable"*) _ok "parse_usage reports unavailable when turn.completed is absent" ;;
    *) _fail "parse_usage must not report ok with zeros: $out" ;;
  esac

  # Always nine pairs, whatever happens.
  assert_eq 9 "$(printf '%s' "$out" | tr ' ' '\n' | "$GREP_BIN" -c '=')" \
    "parse_usage always emits nine key=value pairs"
else
  _fail "parse_usage is not defined"
fi
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/check_06_cookbook.sh`
Expected: FAIL — `now_ms is not defined`, and `parse_usage` reports `ok` for the no-`turn.completed` fixture.

- [ ] **Step 4: Replace the timing snippet**

Delete the `local t0=$(date +%s%3N)` snippet at lines 635–650 and add to the cookbook block:

```bash
# ---- Wall-clock timing ------------------------------------------------------
# `date +%s%3N` is NOT portable: uutils coreutils ignores the %3N width and
# emits full nanoseconds, inflating every duration by ~10^6. EPOCHREALTIME is a
# bash builtin, so it does not depend on which coreutils is installed.
now_ms() { local t="${EPOCHREALTIME}"; local us="${t/[.,]/}"; printf '%s\n' "$((us / 1000))"; }

# Runs a dispatch and prints its wall-clock milliseconds on stdout. `local` is
# only legal inside a function — the previous snippet used it at top level and
# silently produced an empty duration.
timed_dispatch() {
  # Usage: wall_ms="$(timed_dispatch <command...>)"; rc is in $DISPATCH_RC
  local t0 t1
  t0="$(now_ms)"
  "$@"
  DISPATCH_RC=$?
  t1="$(now_ms)"
  printf '%s\n' "$((t1 - t0))"
}
```

- [ ] **Step 5: Fix the `parse_usage` codex branch**

In `parse_usage`, replace the codex jq invocation so an absent `turn.completed` is detected. Use a streaming filter rather than `-s`, which slurps a possibly enormous transcript:

```bash
  codex)
    # Take the LAST turn.completed record. If there is none, usage is
    # unavailable — NOT zeros with usage_status=ok.
    parsed="$(jq -r 'select(.type == "turn.completed") | .usage
                     | [(.input_tokens // 0), (.cached_input_tokens // 0),
                        (.output_tokens // 0), (.reasoning_output_tokens // 0)]
                     | @tsv' "$out_path" 2>/dev/null | tail -1)"
    if [ -z "$parsed" ]; then
      printf 'model=%s duration_ms=%s tokens_input_new=0 tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=n/a usage_status=unavailable\n' \
        "$fallback_model" "$wall_ms"
      return 0
    fi
    IFS=$'\t' read -r in_new in_cached out reasoning <<< "$parsed"
    printf 'model=%s duration_ms=%s tokens_input_new=%s tokens_input_cached=%s tokens_cache_write=0 tokens_output=%s tokens_reasoning=%s cost_usd=n/a usage_status=ok\n' \
      "$fallback_model" "$wall_ms" "$in_new" "$in_cached" "$out" "$reasoning"
    ;;
```

Update the comment at lines 574 and 644 that explains main-model selection: replace the haiku-vs-opus alphabetical example with `never select alphabetically — with fable, haiku, opus and sonnet all possible, sort order is meaningless. Select the key with the highest total token count.`

- [ ] **Step 6: Fix the usage example**

Replace lines 715–720 with a form that defines every variable it uses:

````markdown
<!-- lint: snippet -->
```bash
role=spec-reviewer-claude
out_json="$FEATURE_FOLDER/transcripts/3-spec-review-iter01-claude.json"
err_txt="${out_json%.json}.err"
status="$FEATURE_FOLDER/3-spec-review/iteration-01/claude-verdict.md"

wall_ms="$(timed_dispatch claude_invoke "$role" "$out_json" "$err_txt" < prompt.txt)"
usage_line="$(parse_usage claude "$out_json" "$wall_ms" "$(role_model "$role")")"
verdict="$("$GREP_BIN" -m1 '^verdict:' "$status" | cut -d: -f2- | tr -d '[:space:]')"

log_dispatch "$role" 3 spec-review 01 "$status" "$verdict" "$usage_line"
```
````

- [ ] **Step 7: Run the tests**

Run: `bash tests/check_06_cookbook.sh`
Expected: PASS — all timing and `parse_usage` assertions.

Run: `bash tests/check_05_contract.sh`
Expected: the three `T11:` assertions PASS.

- [ ] **Step 8: Commit**

```bash
git add develop-it-process.md tests/
git commit -m "fix: correct millisecond timing and parse_usage failure reporting

uutils date ignores %3N and emitted nanoseconds, inflating every duration by
~10^6; the snippet also used 'local' at top level so wall_ms was empty anyway.
Switches to EPOCHREALTIME in a real function. parse_usage now reports
'unavailable' when no turn.completed record exists instead of ok-with-zeros,
and streams rather than slurping the transcript."
```

---

## Task 12: NUL-delimited porcelain parser and both dirty-tree gates

**Files:**
- Modify: `develop-it-process.md` — `dirty_tree_check` (lines 726–760), Phase 6 baseline (lines 1164–1210)
- Test: `tests/check_05_contract.sh`, `tests/check_06_cookbook.sh`

**Interfaces:**
- Consumes: `path_in_tree`, `canon` (Task 9)
- Produces: `porcelain_offenders <repo> <allow...>` — prints one repo-relative offending path per line, empty when clean; `dirty_tree_check` and the Phase 6 baseline both call it.

**Context:** four independent bugs in one helper — empty regex alternation makes the gate a no-op, absolute-vs-relative paths never match, `awk '{print $2}'` mangles renames and spaces, and `grep -Fvxf` in the Phase 6 baseline excludes nothing so Phase 6 HALTs unconditionally.

- [ ] **Step 1: Write the failing tests**

Append to `tests/check_06_cookbook.sh` before `finish`:

```bash
# --- porcelain_offenders ---
if declare -F porcelain_offenders >/dev/null; then
  R="$(mktemp -d)"
  git -C "$R" init -q
  mkdir -p "$R/docs/keep" "$R/src"
  printf 'x\n' > "$R/src/a b.txt"      # a path with a space
  printf 'x\n' > "$R/src/plain.txt"
  printf 'x\n' > "$R/docs/keep/k.txt"
  git -C "$R" add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm init

  # 1. Clean tree.
  assert_eq "" "$(porcelain_offenders "$R" docs/keep)" "clean tree yields no offenders"

  # 2. An out-of-scope edit is an offender; an allow-listed one is not.
  printf 'y\n' >> "$R/src/plain.txt"
  printf 'y\n' >> "$R/docs/keep/k.txt"
  assert_eq "src/plain.txt" "$(porcelain_offenders "$R" docs/keep)" \
    "allow-listed dir is exempt, out-of-scope file is reported"
  git -C "$R" checkout -q -- .

  # 3. A path containing a space must survive parsing intact.
  printf 'y\n' >> "$R/src/a b.txt"
  assert_eq "src/a b.txt" "$(porcelain_offenders "$R" docs/keep)" \
    "a path with a space is reported intact"
  git -C "$R" checkout -q -- .

  # 4. A rename is checked on BOTH paths. Moving an out-of-scope file INTO the
  #    allow-listed dir must still be an offender: something outside it moved.
  git -C "$R" mv "src/plain.txt" "docs/keep/plain.txt"
  out="$(porcelain_offenders "$R" docs/keep)"
  case "$out" in
    *src/plain.txt*) _ok "rename reports the out-of-scope source path" ;;
    *) _fail "rename must be checked on both paths, got: [$out]" ;;
  esac
  git -C "$R" reset -q --hard

  # 5. Empty allow-list entries must not disable the gate. This was the
  #    empty-alternation bug: the whole gate silently passed.
  printf 'y\n' >> "$R/src/plain.txt"
  assert_eq "src/plain.txt" "$(porcelain_offenders "$R" "" docs/keep "")" \
    "empty allow-list entries are ignored, not gate-disabling"
  git -C "$R" checkout -q -- .

  # 6. Boundary-aware: a sibling with the allow-listed name as a prefix is NOT exempt.
  mkdir -p "$R/docs/keep-backup"
  printf 'y\n' > "$R/docs/keep-backup/b.txt"
  git -C "$R" add -A -- docs/keep-backup >/dev/null
  out="$(porcelain_offenders "$R" docs/keep)"
  case "$out" in
    *keep-backup*) _ok "sibling prefix directory is not exempted" ;;
    *) _fail "docs/keep must not exempt docs/keep-backup, got: [$out]" ;;
  esac

  rm -rf "$R"
else
  _fail "porcelain_offenders is not defined"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_06_cookbook.sh`
Expected: FAIL — `porcelain_offenders is not defined`.

- [ ] **Step 3: Replace `dirty_tree_check`**

Replace lines 726–760 with this `<!-- lint: cookbook -->` block:

````markdown
<!-- lint: cookbook -->
```bash
# Lists working-tree changes in <repo> that are NOT covered by the allow-list.
# Prints one repo-relative path per line; prints nothing when clean.
#
# Four rules earn the complexity here:
#  1. `--porcelain=v1 -z` is NUL-delimited, so paths with spaces survive.
#     A rename emits TWO fields: "R  <new>" NUL "<old>" NUL.
#  2. Allow-list entries are REPO-RELATIVE. Absolute paths can never match
#     porcelain output.
#  3. Empty entries are skipped. Joining them into a regex alternation produced
#     `^(x||)`, which matches everything and silently disabled the gate.
#  4. Directory entries match boundary-aware (equal, or under "<dir>/"), so
#     `docs/keep` does not exempt `docs/keep-backup`.
#
# Note: git reports an untracked DIRECTORY with a trailing slash
# ("docs/keep-backup/"), while files have none. Offender output therefore mixes
# both forms; match with a glob, not an exact string, when asserting on dirs.
porcelain_offenders() {
  local repo="$1"; shift
  local allow=()
  local a
  for a in "$@"; do [ -n "$a" ] && allow+=("${a%/}"); done

  _allowed() {
    local p="$1" d
    for d in ${allow[@]+"${allow[@]}"}; do
      [ "$p" = "$d" ] && return 0
      case "$p" in "$d"/*) return 0 ;; esac
    done
    return 1
  }

  local status path old
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    path="${entry:3}"
    case "$status" in
      R*|C*)
        # Consume the second field: the ORIGINAL path.
        IFS= read -r -d '' old || old=""
        # Both sides must be in scope. Checking only the destination would hide
        # a file being moved OUT of an out-of-scope location.
        _allowed "$path" || printf '%s\n' "$path"
        [ -n "$old" ] && { _allowed "$old" || printf '%s\n' "$old"; }
        ;;
      *)
        _allowed "$path" || printf '%s\n' "$path"
        ;;
    esac
  done < <(git -C "$repo" status --porcelain=v1 -z)
  unset -f _allowed
}

# Gate: HALT when the target repo has changes outside the allow-list.
# $PROCESS_PATH is deliberately NOT passed: it lives in the other repository, so
# it can never appear in this repo's porcelain output. Passing it would be dead
# weight, not protection.
dirty_tree_check() {
  # Usage: dirty_tree_check [extra-repo-relative-allow-entries...]
  local allow=("$@") offenders
  [ -n "${SPEC_PATH:-}" ] && allow+=("${SPEC_PATH#"$REPO_ROOT"/}")
  [ -n "${PLAN_PATH:-}" ] && allow+=("${PLAN_PATH#"$REPO_ROOT"/}")
  [ -n "${FEATURE_FOLDER:-}" ] && allow+=("${FEATURE_FOLDER#"$REPO_ROOT"/}")

  offenders="$(porcelain_offenders "$REPO_ROOT" ${allow[@]+"${allow[@]}"})"
  if [ -n "$offenders" ]; then
    echo "halt: working tree has changes outside the orchestration slice:" >&2
    printf '  %s\n' "$offenders" >&2   # quoted: paths may contain spaces
    return 1
  fi
  return 0
}
```
````

- [ ] **Step 4: Rewrite the Phase 6 baseline to reuse the helper**

Replace the baseline block at lines 1164–1210 with:

````markdown
<!-- lint: cookbook -->
```bash
capture_implementation_baseline() {
  IMPLEMENTATION_BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo non-git)"

  # Same allow-list semantics as dirty_tree_check — one helper, so the two
  # gates cannot diverge. The previous code used `grep -Fvxf`, whose -x demands
  # a full-line exact match of ABSOLUTE paths against RELATIVE porcelain output,
  # so nothing was ever excluded and Phase 6 HALTed unconditionally.
  local offenders
  offenders="$(dirty_tree_check)"
  if [ -n "$offenders" ] || ! dirty_tree_check >/dev/null 2>&1; then
    echo "halt: uncommitted changes outside the implementation slice; commit or stash first" >&2
    dirty_tree_check >/dev/null
    return 1
  fi

  {
    printf -- '--- %s  event=IMPLEMENTATION_BASELINE\n' "$(iso_now)"
    printf 'phase:                    6\n'
    printf 'phase_name:               implementation\n'
    printf 'base_sha:                 %s\n' "$IMPLEMENTATION_BASE_SHA"
    printf 'uncommitted_changes:      no\n'
    printf '\n'
  } >> "$FEATURE_FOLDER/RUN_LOG.md"
}
```
````

Note in the prose beneath it that the event is a **multi-line block** matching the RUN_LOG grammar; the previous single-line form could not be parsed by the summarizers or the readiness writer.

- [ ] **Step 5: Run the tests**

Run: `bash tests/check_06_cookbook.sh`
Expected: PASS — all six `porcelain_offenders` assertions.

Run: `bash tests/check_05_contract.sh`
Expected: the three `T12:` assertions PASS.

- [ ] **Step 6: Commit**

```bash
git add develop-it-process.md tests/check_06_cookbook.sh
git commit -m "fix: rewrite dirty-tree gates on NUL-delimited porcelain

Fixes four bugs in one helper: empty regex alternation made the gate a silent
no-op, absolute allow-list paths could never match relative porcelain output,
awk \$2 mangled renames and spaces, and grep -Fvxf excluded nothing so Phase 6
HALTed unconditionally. Renames are now checked on both paths, and the Phase 6
baseline event is a parseable multi-line block."
```

---

## Task 13: Parallel dispatch failure detection

**Files:**
- Modify: `develop-it-process.md` — `dispatch_reviewers_parallel` (lines 845–880)
- Test: `tests/check_02_markers.sh` (turns green), `tests/check_05_contract.sh`

**Interfaces:**
- Consumes: `claude_invoke`, `codex_invoke` (Task 7), `role_model` (Task 5)
- Produces: `dispatch_reviewers_parallel <claude_role> <codex_role> <phase> <iter>` — sets `CLAUDE_RC` and `CODEX_RC`; `CODEX_RC` is `-1` when Codex was not dispatched.

- [ ] **Step 1: Run the marker check to confirm it is still red**

Run: `bash tests/check_02_markers.sh`
Expected: FAIL on the constructed-name assertion at lines 851 and 863.

- [ ] **Step 2: Replace the helper**

Replace lines 845–880 with:

````markdown
<!-- lint: cookbook -->
```bash
# Dispatch both reviewers concurrently for one gate iteration.
#
# Roles are passed EXPLICITLY. The previous version built appendix names as
# "${phase}-reviewer-claude", which cannot produce `code-reviewer-claude` for
# any value of $phase — Phase 7 rendered an empty prompt and render_prompt
# raised ValueError.
#
# Each subshell ends with `exit "$rc"` so `wait` reports the truth. Previously
# the last command was an `echo`, so `wait` returned 0 unconditionally and no
# reviewer failure was ever detected.
dispatch_reviewers_parallel() {
  # Usage: dispatch_reviewers_parallel <claude_role> <codex_role> <phase> <iter>
  local claude_role="$1" codex_role="$2" phase="$3" iter="$4"
  local tdir="$FEATURE_FOLDER/transcripts"
  mkdir -p "$tdir"   # bash fails the redirect below if this is absent

  local base_c="$tdir/${phase}-iter${iter}-claude"
  local base_x="$tdir/${phase}-iter${iter}-codex"
  local claude_pid="" codex_pid=""

  (
    render_prompt "$claude_role" \
      | claude_invoke "$claude_role" "${base_c}.json" "${base_c}.err"
    rc=$?
    printf '%s\n' "$rc" > "${base_c}.rc.tmp" && mv "${base_c}.rc.tmp" "${base_c}.rc"
    exit "$rc"
  ) &
  claude_pid=$!

  if [ "${codex_available:-false}" = true ]; then
    (
      render_prompt "$codex_role" \
        | codex_invoke "$codex_role" "${base_x}.json" "${base_x}.err"
      rc=$?
      printf '%s\n' "$rc" > "${base_x}.rc.tmp" && mv "${base_x}.rc.tmp" "${base_x}.rc"
      exit "$rc"
    ) &
    codex_pid=$!
  fi

  wait "$claude_pid"; CLAUDE_RC=$?
  if [ -n "$codex_pid" ]; then
    wait "$codex_pid"; CODEX_RC=$?
  else
    CODEX_RC=-1   # not dispatched; distinct from rc=0
  fi
  # RUN_LOG appends are serialised here, after both children have exited, so
  # concurrent writes cannot interleave and corrupt the block grammar.
  return 0
}
```
````

- [ ] **Step 3: Initialise `codex_available`**

`codex_available` is referenced but never assigned. Add it to the Task 9 orchestration-variables block:

```bash
# Set by canary_preflight and by each per-phase preflight gate. Explicitly
# initialised because it is read under `set -u`.
codex_available="${codex_available:-false}"
codex_disabled_by_user="${codex_disabled_by_user:-false}"
```

- [ ] **Step 4: Run the checks**

Run: `bash tests/check_02_markers.sh`
Expected: PASS — all four assertions, including no constructed appendix names.

Run: `bash tests/check_05_contract.sh`
Expected: the `T13:` assertion PASSES.

- [ ] **Step 5: Remove the expected-red note**

Delete the `# EXPECTED RED until Task 13` line from `tests/check_02_markers.sh`.

- [ ] **Step 6: Commit**

```bash
git add develop-it-process.md tests/check_02_markers.sh
git commit -m "fix: make parallel reviewer dispatch detect failures

Subshells now exit with the CLI's rc so wait reports the truth; previously the
last command was an echo and wait always returned 0. Roles are passed
explicitly because no value of \$phase yields code-reviewer-claude. Adds the
missing mkdir -p for transcripts and initialises codex_available."
```

---

## Task 14: `render_prompt` hardening

**Files:**
- Modify: `develop-it-process.md` — `render_prompt` (lines 393–433), delete the `sed` example at lines 43–53
- Test: `tests/check_03_varcoverage.sh` (turns green), `tests/check_06_cookbook.sh`

**Interfaces:**
- Consumes: `PROCESS_PATH`, `PYTHON_BIN` (Task 9)
- Produces: `render_prompt <appendix-name>` — prints the substituted appendix body; exits non-zero with a one-line diagnostic when the marker is missing.

- [ ] **Step 1: Write the failing test**

Append to `tests/check_06_cookbook.sh` before `finish`:

```bash
# --- render_prompt ---
if declare -F render_prompt >/dev/null; then
  PROCESS_PATH="$PROCESS_DOC"
  ITERATION=07 FEATURE_FOLDER=/tmp/ff ROUND=03 TEST_REPORT_PATH=/tmp/tr.md
  export PROCESS_PATH ITERATION FEATURE_FOLDER ROUND TEST_REPORT_PATH

  body="$(render_prompt spec-reviewer-claude)" \
    && _ok "render_prompt extracts a known appendix" \
    || _fail "render_prompt failed on spec-reviewer-claude"
  case "$body" in
    *'$ITERATION'*) _fail "render_prompt left \$ITERATION unsubstituted" ;;
    *07*)           _ok "render_prompt substituted \$ITERATION" ;;
    *)              _fail "render_prompt output lacks the substituted value" ;;
  esac

  # Phase 8 variables: the omission that made all-tests prompts render literals.
  body="$(render_prompt all-tests-runner)"
  case "$body" in
    *'$ROUND'*) _fail "render_prompt left \$ROUND unsubstituted" ;;
    *)          _ok "render_prompt substitutes \$ROUND" ;;
  esac

  # A missing marker must be a legible error, not a Python traceback that
  # becomes the prompt.
  err="$(render_prompt no-such-appendix 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && _ok "render_prompt fails on an unknown appendix" \
                  || _fail "render_prompt must fail on an unknown appendix"
  case "$err" in
    *Traceback*) _fail "render_prompt emitted a Python traceback: $err" ;;
    *no-such-appendix*) _ok "render_prompt names the missing appendix" ;;
    *) _fail "render_prompt diagnostic is unhelpful: $err" ;;
  esac
else
  _fail "render_prompt is not defined"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_06_cookbook.sh`
Expected: FAIL — `$ROUND` unsubstituted, and the unknown-appendix case emits a traceback.

- [ ] **Step 3: Replace `render_prompt`**

Replace lines 393–433 with:

````markdown
<!-- lint: cookbook -->
```bash
# Extract one appendix and substitute orchestration variables into it.
# `sed` is NOT an alternative: multi-line values such as $FINDINGS_PATHS break
# it, and path values collide with any delimiter chosen.
render_prompt() {
  # Usage: render_prompt <appendix-name>
  local appendix="$1"
  APPENDIX="$appendix" PROCESS_PATH="$PROCESS_PATH" "$PYTHON_BIN" - <<'PY'
import os
import re
import sys

process = os.environ["PROCESS_PATH"]
name = os.environ["APPENDIX"]

text = open(process).read()
start_marker = f"<!-- BEGIN: {name} -->"
end_marker = f"<!-- END: {name} -->"

start = text.find(start_marker)
if start == -1:
    sys.exit(f"render_prompt: no BEGIN marker for appendix '{name}' in {process}")
# Search for the END marker AFTER start -- searching from 0 could match an
# earlier appendix's END and silently truncate or invert the body.
end = text.find(end_marker, start)
if end == -1:
    sys.exit(f"render_prompt: BEGIN without END for appendix '{name}' in {process}")
body = text[start:end + len(end_marker)]

# Every variable any appendix may reference. tests/check_03_varcoverage.sh
# asserts this list covers every $VAR used in every appendix body, so an
# appendix cannot start using a variable that is never substituted.
KEYS = [
    "FEATURE_FOLDER",
    "ITERATION",
    "SPEC_PATH",
    "PLAN_PATH",
    "FINDINGS_PATHS",
    "IMPLEMENTATION_BASE_SHA",
    "IMPLEMENTATION_SUMMARY_PATH",
    "DEBUGGER_STATUS_PATH",
    "REPO_ROOT",
    "ROUND",
    "TEST_REPORT_PATH",
]

# Longest name first, and a trailing boundary assertion, so a short name can
# never partially replace a longer one (e.g. $ITERATION vs $ITERATION_CAP).
for key in sorted(KEYS, key=len, reverse=True):
    value = os.environ.get(key)
    if value is None:
        continue
    body = re.sub(rf"\${key}(?![A-Za-z0-9_])", value.replace("\\", "\\\\"), body)

print(body)
PY
}
```
````

- [ ] **Step 4: Delete the superseded `sed` example**

Remove the `awk … | sed … | claude` example at lines 43–53 of the Delegation pattern and replace step 2 of that list with:

```markdown
2. Render the appendix with `render_prompt <appendix-name>` and pipe it into
   `claude_invoke <role> …` or `codex_invoke <role> …`. Never use `sed` for
   substitution: multi-line values break it, and the model/effort/timeout must
   come from the role helpers rather than being written into the command.
```

- [ ] **Step 5: Run the checks**

Run: `bash tests/check_06_cookbook.sh`
Expected: PASS — all `render_prompt` assertions.

Run: `bash tests/check_03_varcoverage.sh`
Expected: PASS — `missing` is empty.

- [ ] **Step 6: Remove the expected-red note**

Delete the `# EXPECTED RED until Task 14` line from `tests/check_03_varcoverage.sh`.

- [ ] **Step 7: Commit**

```bash
git add develop-it-process.md tests/
git commit -m "fix: harden render_prompt

Adds the missing \$ROUND and \$TEST_REPORT_PATH so Phase 8 prompts stop
rendering literals, searches the END marker from the BEGIN offset, replaces the
bare substring substitution with a boundary-aware regex, and fails with a
legible message instead of piping a Python traceback in as the prompt."
```

---

## Task 15: `validate_status`, shell policy, and xtrace hygiene

**Files:**
- Modify: `develop-it-process.md` — `validate_status` (lines 776–840), `full_log.md` preamble (lines 355–374), the five `[ -f … ] && mv` sites (lines 955–962, 1015–1017, 1089–1091, 1143–1145, 1261–1263), the proposition append at line 1774
- Test: `tests/check_05_contract.sh`, `tests/check_06_cookbook.sh`

**Interfaces:**
- Consumes: `GREP_BIN` (Task 9)
- Produces: `validate_status <path> <kind>` where `kind` is `reviewer`, `worker`, or `summarizer`; returns 0 valid, 1 invalid with a diagnostic; `status_field <path> <key>` returning a full untruncated value.

- [ ] **Step 1: Write the failing test**

Append to `tests/check_06_cookbook.sh` before `finish`:

```bash
# --- status_field / validate_status ---
if declare -F status_field >/dev/null && declare -F validate_status >/dev/null; then
  S="$BUILD/status.md"
  cat > "$S" <<'EOF'
verdict: CHANGES_REQUESTED
blockers: 0
majors: 2
minors: 5
findings: claude-findings.md
reason: cannot read /etc/a:b -- unmatched " quote
EOF
  assert_eq "CHANGES_REQUESTED" "$(status_field "$S" verdict)" "status_field reads verdict"
  # A colon inside a value must survive: -F: truncated it before.
  assert_eq 'cannot read /etc/a:b -- unmatched " quote' "$(status_field "$S" reason)" \
    "status_field preserves colons and quotes in a value"

  ( cd "$BUILD" && : > claude-findings.md )
  ( cd "$BUILD" && validate_status status.md reviewer ) \
    && _ok "validate_status accepts a complete reviewer status" \
    || _fail "validate_status rejected a valid reviewer status"

  printf 'verdict: PASS\n' > "$BUILD/thin.md"
  ( cd "$BUILD" && validate_status thin.md reviewer ) \
    && _fail "validate_status must require severity counts for reviewers" \
    || _ok "validate_status rejects a reviewer status missing severity counts"
else
  _fail "status_field / validate_status not defined"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_06_cookbook.sh`
Expected: FAIL — `status_field / validate_status not defined` (the current helper has neither name nor colon-safe parsing).

- [ ] **Step 3: Replace `validate_status`**

Replace lines 776–840 with:

````markdown
<!-- lint: cookbook -->
```bash
# Read one field from a STATUS file. Everything after the FIRST colon is the
# value, so colons and quotes inside it survive. `awk -F:` truncated at the
# first colon and `| xargs` interpreted quotes and died on an unmatched one.
status_field() {
  # Usage: status_field <status-path> <key>
  local path="$1" key="$2" line
  line="$("$GREP_BIN" -m1 "^${key}:" "$path" 2>/dev/null)" || return 1
  line="${line#*:}"
  # Trim surrounding whitespace with parameter expansion only.
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s\n' "$line"
}

# Validate a STATUS file's shape before branching on it.
# Note: `\S` is a PCRE/GNU extension and is NOT valid POSIX ERE — use
# [^[:space:]] instead.
validate_status() {
  # Usage: validate_status <status-path> <reviewer|worker|summarizer>
  local path="$1" kind="$2" v
  if [ ! -f "$path" ]; then
    echo "invalid status: missing file: $path" >&2; return 1
  fi
  if ! "$GREP_BIN" -qE '^verdict:[[:space:]]*[^[:space:]]' "$path"; then
    echo "invalid status: no non-empty verdict: field in $path" >&2; return 1
  fi
  case "$kind" in
    reviewer)
      local k
      for k in blockers majors minors findings; do
        v="$(status_field "$path" "$k")"
        if [ -z "$v" ]; then
          echo "invalid status: reviewer status missing '$k:' in $path" >&2; return 1
        fi
        case "$k" in
          blockers|majors|minors)
            case "$v" in ''|*[!0-9]*)
              echo "invalid status: $k must be an integer, got '$v' in $path" >&2
              return 1 ;;
            esac ;;
          findings)
            if [ ! -f "$(dirname "$path")/$v" ] && [ ! -f "$v" ]; then
              echo "invalid status: findings: '$v' does not exist" >&2; return 1
            fi ;;
        esac
      done ;;
    worker|summarizer) : ;;
    *) echo "validate_status: unknown kind '$kind'" >&2; return 1 ;;
  esac
  return 0
}
```
````

- [ ] **Step 4: State the shell policy and fix xtrace**

Replace the `full_log.md` preamble section (lines 355–374) with:

````markdown
### Shell policy

Every orchestrator bash block starts with:

<!-- lint: snippet -->
```bash
set -uo pipefail
```

**Never `set -e`.** Helpers signal outcomes through return codes that the
orchestrator is required to inspect and branch on; `set -e` would abort the
block instead of letting the gate decide. `-u` catches the unset-variable class
of bug that made `codex_available` and `$STATUS` silently empty.

**Bash functions do not survive across invocations.** Because each phase is a
separate bash invocation, every cookbook helper this document defines must be
re-defined in each phase block. Paste the whole cookbook at the top of each
block; do not attempt to carry definitions between phases.

### full_log.md — bash command log

<!-- lint: snippet -->
```bash
# Redirect xtrace into full_log.md for post-run analysis.
# BASH_XTRACEFD is deliberately NOT exported: exporting it leaks the fd into
# every child, so each child bash writes its own xtrace into full_log.md, and a
# child that does not inherit the fd fails with "invalid value for trace file
# descriptor".
if [ -d "${FEATURE_FOLDER:-}" ]; then
  printf '\n=== %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FEATURE_FOLDER/full_log.md"
  exec {_LOGFD}>>"$FEATURE_FOLDER/full_log.md"
  BASH_XTRACEFD=$_LOGFD
  PS4='+ '
  set -x
fi
# ... phase body ...
# At the end of the block, release the descriptor:
#   set +x; exec {_LOGFD}>&-
```

**Phase −1** runs before the feature folder exists. Send its xtrace to a temp
file rather than stderr: the Mode-1 classifier greps subprocess stderr for
`Usage:` and `unexpected argument`, and orchestrator xtrace on that stream is
misread as a CLI usage error.
````

- [ ] **Step 5: Fix the five trailing `&&` blocks**

At lines 955–962 and the four parallel sites, replace each `[ -f … ] && mv …` pair with an `if` form. For Step 1.2:

```bash
mkdir -p "$FEATURE_FOLDER/1-preflight/phase-1"
for v in claude codex; do
  src="$FEATURE_FOLDER/1-preflight/${v}-check-status.md"
  if [ -f "$src" ]; then
    mv "$src" "$FEATURE_FOLDER/1-preflight/phase-1/${v}-check-status.md"
  fi
done
# An `if` is required, not `[ -f … ] && mv`: as the LAST statement of a block
# the latter returns 1 whenever the file is absent, which is the normal
# codex-skipped path, making a successful phase look like a failure.
```

- [ ] **Step 6: Fix the proposition append**

At line 1774, change `printf '%s' "$ENTRY"` to `printf '%s\n' "$ENTRY"` and note: *the missing newline concatenated each entry onto the previous line, defeating the `^## ` mining rule.*

- [ ] **Step 7: Run the checks**

Run: `bash tests/check_06_cookbook.sh`
Expected: PASS — all four `status_field`/`validate_status` assertions.

Run: `bash tests/check_05_contract.sh`
Expected: the three `T15:` assertions PASS.

- [ ] **Step 8: Commit**

```bash
git add develop-it-process.md tests/check_06_cookbook.sh
git commit -m "fix: harden status parsing and shell hygiene

status_field takes everything after the first colon, so colons and quotes in a
value survive; drops the xargs trim that died on unmatched quotes and the
non-POSIX \\S. States set -uo pipefail (never -e) and that helpers must be
re-defined per phase block. Stops exporting BASH_XTRACEFD, and converts five
trailing '[ -f ] && mv' blocks that returned 1 on the codex-skipped path."
```

---

## Task 16: Fake-CLI stubs

**Files:**
- Create: `tests/fakebin/claude`, `tests/fakebin/codex`, `tests/check_07_fakecli.sh`

**Interfaces:**
- Consumes: `tests/lib/assert.sh`
- Produces: stubs controlled by environment variables — `FAKE_RC` (exit code, default 0), `FAKE_DELAY` (seconds to sleep, default 0), `FAKE_IGNORE_TERM` (when set, trap and ignore SIGTERM), `FAKE_ARGV_LOG` (file to append the full argv to). Each stub emits vendor-appropriate telemetry on stdout. `check_07_fakecli.sh` asserts against `$FAKE_ARGV_LOG`.

**Context:** §9 check 5. Without this, nothing verifies detached dispatch, `--add-dir` selection, timeout escalation, or resume except inspection.

- [ ] **Step 1: Write the failing test**

Create `tests/check_07_fakecli.sh`:

```bash
#!/usr/bin/env bash
# Check 5: fake-CLI integration. Exercises dispatch machinery with no tokens.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

python3 lib/extract.py cookbook 2>/dev/null || { _fail "cookbook not extractable"; finish; }

WORK="$BUILD/fakecli"; rm -rf "$WORK"; mkdir -p "$WORK"
export PATH="$PWD/fakebin:$PATH"
export FAKE_ARGV_LOG="$WORK/argv.log"

# A throwaway target repo, distinct from the process repo.
export REPO_ROOT="$WORK/target"; mkdir -p "$REPO_ROOT"
git -C "$REPO_ROOT" init -q
( cd "$REPO_ROOT" && : > seed && git add seed \
  && git -c user.email=t@t -c user.name=t commit -qm seed )
export FEATURE_FOLDER="$REPO_ROOT/docs/superpowers/specs/x-artifacts"
mkdir -p "$FEATURE_FOLDER/transcripts"
export PROCESS_PATH="$PROCESS_DOC"

# shellcheck source=/dev/null
source "$BUILD/cookbook.sh"
validate_roots || { _fail "validate_roots failed in the fake environment"; finish; }

# --- 1. claude_invoke passes the resolved model and timeout ---
: > "$FAKE_ARGV_LOG"
printf 'prompt\n' | claude_invoke spec-reviewer-claude "$WORK/o.json" "$WORK/o.err"
assert_rc 0 $? "claude_invoke succeeds with a healthy stub"
assert_present -- "--model claude-opus-5" "$FAKE_ARGV_LOG" \
  "claude_invoke passes the role's resolved model"

# --- 2. codex_invoke pins the model, effort, and --json ---
: > "$FAKE_ARGV_LOG"
printf 'prompt\n' | codex_invoke spec-reviewer-codex "$WORK/c.json" "$WORK/c.err"
assert_present -- "-m gpt-5.6-sol" "$FAKE_ARGV_LOG" "codex_invoke pins the model"
assert_present -- "model_reasoning_effort=high" "$FAKE_ARGV_LOG" "codex_invoke sets high effort"
assert_present -- "--json" "$FAKE_ARGV_LOG" "codex_invoke always passes --json"

# --- 3. --add-dir appears only when the feature folder is outside REPO_ROOT ---
case "$(cat "$FAKE_ARGV_LOG")" in
  *--add-dir*) _fail "--add-dir must be absent when FEATURE_FOLDER is inside REPO_ROOT" ;;
  *) _ok "--add-dir absent for an in-repo feature folder" ;;
esac
: > "$FAKE_ARGV_LOG"
( export FEATURE_FOLDER="$WORK/outside"; mkdir -p "$FEATURE_FOLDER"
  validate_roots >/dev/null 2>&1
  printf 'p\n' | codex_invoke plan-reviewer-codex "$WORK/c2.json" "$WORK/c2.err" )
assert_present -- "--add-dir" "$FAKE_ARGV_LOG" \
  "--add-dir present for an out-of-repo feature folder"

# --- 4. A failing stub is reported as failed ---
: > "$FAKE_ARGV_LOG"
FAKE_RC=3 dispatch_reviewers_parallel spec-reviewer-claude spec-reviewer-codex 3 01
assert_eq 3 "${CLAUDE_RC}" "a failing claude stub is detected (was always 0 before)"
assert_eq -1 "${CODEX_RC}" "CODEX_RC is -1 when codex is not dispatched"

# --- 5. timeout escalates to --kill-after for a stub that ignores SIGTERM ---
FAKE_IGNORE_TERM=1 FAKE_DELAY=30 \
  timeout --kill-after=1s 1s claude --model x -p - </dev/null >/dev/null 2>&1
rc=$?
case "$rc" in
  124|137) _ok "timeout kills a SIGTERM-ignoring process (rc=$rc)" ;;
  *) _fail "expected 124 or 137 from timeout escalation, got $rc" ;;
esac

finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_07_fakecli.sh`
Expected: FAIL — `claude: command not found`, because the stubs do not exist.

- [ ] **Step 3: Write `tests/fakebin/claude`**

```bash
#!/usr/bin/env bash
# Fake `claude` CLI for offline integration tests.
#   FAKE_RC           exit code (default 0)
#   FAKE_DELAY        seconds to sleep before responding (default 0)
#   FAKE_IGNORE_TERM  when set, trap and ignore SIGTERM
#   FAKE_ARGV_LOG     append the full argv to this file
set -u
[ -n "${FAKE_ARGV_LOG:-}" ] && printf 'claude %s\n' "$*" >> "$FAKE_ARGV_LOG"
[ -n "${FAKE_IGNORE_TERM:-}" ] && trap '' TERM
cat >/dev/null 2>&1 || true          # drain the prompt on stdin
[ "${FAKE_DELAY:-0}" != 0 ] && sleep "${FAKE_DELAY}"
case " $* " in
  *" --help "*) printf -- '--output-format --dangerously-skip-permissions --model --agents\n'; exit 0 ;;
esac
cat <<'JSON'
{"type":"result","duration_ms":1234,"total_cost_usd":0.01,
 "modelUsage":{"claude-opus-5":{"inputTokens":10,"outputTokens":5}},
 "usage":{"input_tokens":10,"cache_read_input_tokens":0,
          "cache_creation_input_tokens":0,"output_tokens":5}}
JSON
exit "${FAKE_RC:-0}"
```

- [ ] **Step 4: Write `tests/fakebin/codex`**

```bash
#!/usr/bin/env bash
# Fake `codex` CLI for offline integration tests. Same knobs as fakebin/claude.
set -u
[ -n "${FAKE_ARGV_LOG:-}" ] && printf 'codex %s\n' "$*" >> "$FAKE_ARGV_LOG"
[ -n "${FAKE_IGNORE_TERM:-}" ] && trap '' TERM
# Reject the real CLI's ordering bug so the stub cannot mask it: `-a` after
# `exec` must fail exactly as codex 0.146.0 does.
seen_exec=no
for a in "$@"; do
  case "$a" in
    exec) seen_exec=yes ;;
    -a|--ask-for-approval|-m|--model|-c|--config)
      [ "$seen_exec" = yes ] && { printf "error: unexpected argument '%s' found\n" "$a" >&2; exit 2; } ;;
  esac
done
case " $* " in
  *" --help "*) printf -- '--json --skip-git-repo-check --add-dir --model\n'; exit 0 ;;
esac
cat >/dev/null 2>&1 || true
[ "${FAKE_DELAY:-0}" != 0 ] && sleep "${FAKE_DELAY}"
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":7}}'
exit "${FAKE_RC:-0}"
```

- [ ] **Step 5: Run the check**

```bash
chmod +x tests/fakebin/claude tests/fakebin/codex tests/check_07_fakecli.sh
bash tests/check_07_fakecli.sh
```

Expected: PASS — all nine assertions. The stub's argv log proves the resolved model and effort reach the command line.

- [ ] **Step 6: Commit**

```bash
git add tests/fakebin tests/check_07_fakecli.sh
git commit -m "test: add fake-CLI stubs and integration check

Stubs record argv, so 'the resolved model reached the process' is asserted
rather than assumed. The codex stub reproduces the real CLI's rejection of
global options after exec, so it cannot mask that ordering bug."
```

---

## Task 17: Detached dispatch and the resume state machine

**Files:**
- Modify: `develop-it-process.md` — add a "Long dispatch" cookbook section; update the one-phase-per-invocation rule (lines 88–109); update resumability (lines 1610–1619)
- Test: `tests/check_05_contract.sh`, `tests/check_07_fakecli.sh`

**Interfaces:**
- Consumes: `claude_invoke`, `codex_invoke` (Task 7), `iso_now` (Task 10)
- Produces:
  - `dispatch_id <phase> <iter> <role>` → `<phase>-iter<NN>-<role>`
  - `dispatch_detached <phase> <iter> <role>` — launches, writes `.started` then `.pid`; prompt on stdin
  - `dispatch_state <phase> <iter> <role>` → one of `NEVER_LAUNCHED RUNNING ORPHANED COMPLETED TIMED_OUT FAILED CORRUPT INCONSISTENT`; sets `DISPATCH_RC` when a valid `.rc` exists
  - `await_dispatch <phase> <iter> <role> <max_wait_s>` — polls; returns 0 on a terminal state, 1 on timeout of the poll itself

- [ ] **Step 1: Write the failing test**

Append to `tests/check_07_fakecli.sh` before `finish`:

```bash
# --- detached dispatch state machine ---
for fn in dispatch_id dispatch_detached dispatch_state await_dispatch; do
  declare -F "$fn" >/dev/null || _fail "$fn is not defined"
done
[ "$_FAILURES" -eq 0 ] || finish

T="$FEATURE_FOLDER/transcripts"

assert_eq "3-iter01-spec-reviewer-claude" \
  "$(dispatch_id 3 01 spec-reviewer-claude)" "dispatch_id is deterministic"

# 1. Nothing launched yet.
assert_eq NEVER_LAUNCHED "$(dispatch_state 9 01 summarizer-spec)" \
  "no control files means NEVER_LAUNCHED"

# 2. Completed successfully.
printf 'p\n' | dispatch_detached 3 02 summarizer-spec
await_dispatch 3 02 summarizer-spec 30 || _fail "await_dispatch timed out on a fast stub"
assert_eq COMPLETED "$(dispatch_state 3 02 summarizer-spec)" "rc=0 means COMPLETED"
assert_eq 0 "$DISPATCH_RC" "DISPATCH_RC is 0 for a clean run"

# 3. Non-zero rc.
( export FAKE_RC=4; printf 'p\n' | dispatch_detached 3 03 summarizer-spec
  await_dispatch 3 03 summarizer-spec 30 )
assert_eq FAILED "$(dispatch_state 3 03 summarizer-spec)" "non-zero rc means FAILED"

# 4. timeout rc 124.
id="$(dispatch_id 3 04 summarizer-spec)"
printf '%s\n' 124 > "$T/$id.rc"
printf 'dispatch_id: %s\npid: 999999\npid_starttime: 1\n' "$id" > "$T/$id.started"
assert_eq TIMED_OUT "$(dispatch_state 3 04 summarizer-spec)" "rc=124 means TIMED_OUT"

# 5. Malformed .rc.
id="$(dispatch_id 3 05 summarizer-spec)"
printf 'garbage\n' > "$T/$id.rc"
printf 'dispatch_id: %s\npid: 999999\npid_starttime: 1\n' "$id" > "$T/$id.started"
assert_eq CORRUPT "$(dispatch_state 3 05 summarizer-spec)" "a non-numeric .rc is CORRUPT"

# 6. Started, no .rc, dead pid -> ORPHANED (the harness-crash case).
id="$(dispatch_id 3 06 summarizer-spec)"
printf 'dispatch_id: %s\npid: 999999\npid_starttime: 12345\n' "$id" > "$T/$id.started"
assert_eq ORPHANED "$(dispatch_state 3 06 summarizer-spec)" \
  "a dead pid with no .rc is ORPHANED, not RUNNING"

# 7. PID reuse: live pid, wrong starttime -> ORPHANED, not RUNNING.
sleep 60 & live=$!
id="$(dispatch_id 3 07 summarizer-spec)"
printf 'dispatch_id: %s\npid: %s\npid_starttime: 1\n' "$id" "$live" > "$T/$id.started"
assert_eq ORPHANED "$(dispatch_state 3 07 summarizer-spec)" \
  "a recycled pid is ORPHANED (starttime mismatch)"

# 8. Genuinely running.
real_start="$(awk '{print $22}' /proc/$live/stat)"
printf 'dispatch_id: %s\npid: %s\npid_starttime: %s\n' "$id" "$live" "$real_start" \
  > "$T/$id.started"
assert_eq RUNNING "$(dispatch_state 3 07 summarizer-spec)" \
  "a live pid with a matching starttime is RUNNING"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

# 9. .rc without .started -> INCONSISTENT (two runs on one folder).
id="$(dispatch_id 3 08 summarizer-spec)"
printf '0\n' > "$T/$id.rc"; rm -f "$T/$id.started"
assert_eq INCONSISTENT "$(dispatch_state 3 08 summarizer-spec)" \
  ".rc without .started is INCONSISTENT"

# 10. A DISPATCH_STARTED event is logged before launch.
assert_present 'event=DISPATCH_STARTED' "$FEATURE_FOLDER/RUN_LOG.md" \
  "launch is recorded in RUN_LOG before the process starts"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_07_fakecli.sh`
Expected: FAIL — the four `dispatch_*` functions are undefined.

- [ ] **Step 3: Add the long-dispatch cookbook section**

Insert a new section after the CLI invocation forms:

````markdown
### Long dispatch — detach and poll

The implementer (300 min), plan writer (120 min) and deep Codex review (120 min)
outlive any single bash invocation a harness will allow. They are launched
detached and polled across short calls.

**One *dispatch* per phase** is the rule — polling calls are not phase bundling.
Control files live beside the transcript:

| File | Written | Content |
|---|---|---|
| `<id>.started` | before launch | `dispatch_id`, ISO timestamp, `pid`, `pid_starttime`, `timeout_s`, model |
| `<id>.pid` | after launch | pid only |
| `<id>.rc` | on exit | exit code, one integer |
| `<id>.json` / `.err` | by the CLI | stdout / stderr |

<!-- lint: cookbook -->
```bash
dispatch_id() { printf '%s-iter%s-%s\n' "$1" "$2" "$3"; }

_pid_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

# Launch a dispatch that outlives this shell. Prompt is read from stdin.
dispatch_detached() {
  # Usage: dispatch_detached <phase> <iter> <role> [extra CLI args...] < prompt
  # Trailing arguments are forwarded to claude_invoke / codex_invoke — this is
  # how the implementer passes --agents to pin its sub-subagent model.
  local phase="$1" iter="$2" role="$3"; shift 3
  local id tdir base vendor model timeout_s prompt
  id="$(dispatch_id "$phase" "$iter" "$role")"
  tdir="$FEATURE_FOLDER/transcripts"; mkdir -p "$tdir"
  base="$tdir/$id"
  vendor="$(role_vendor "$role")"
  model="$(role_model "$role")"   || return 1
  timeout_s=$(( $(role_timeout "$role") * 60 ))

  # Buffer the prompt: the detached child cannot inherit this shell's stdin.
  prompt="$base.prompt"
  cat > "$prompt"

  # Record the intent BEFORE launching, so a crash between launch and
  # completion still leaves an auditable trace.
  {
    printf -- '--- %s  event=DISPATCH_STARTED\n' "$(iso_now)"
    printf 'phase:                    %s\n' "$phase"
    printf 'iteration:                %s\n' "$iter"
    printf 'role:                     %s\n' "$role"
    printf 'dispatch_id:              %s\n' "$id"
    printf 'model:                    %s\n' "$model"
    printf '\n'
  } >> "$FEATURE_FOLDER/RUN_LOG.md"

  # The child needs the cookbook: functions do not cross a bash -c boundary.
  # Export the definitions it calls rather than re-sourcing the document.
  export -f claude_invoke codex_invoke role_model role_effort role_timeout \
            role_vendor _role_row _role_field

  setsid bash -c '
    set -uo pipefail
    base="$1"; vendor="$2"; role="$3"; shift 3
    if [ "$vendor" = codex ]; then
      codex_invoke "$role" "$base.json" "$base.err" "$@" < "$base.prompt"
    else
      claude_invoke "$role" "$base.json" "$base.err" "$@" < "$base.prompt"
    fi
    rc=$?
    # Atomic publication: a poller must never read a partial .rc.
    printf "%s\n" "$rc" > "$base.rc.tmp" && mv "$base.rc.tmp" "$base.rc"
  ' _ "$base" "$vendor" "$role" "$@" >/dev/null 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true

  {
    printf 'dispatch_id: %s\n' "$id"
    printf 'started_at: %s\n' "$(iso_now)"
    printf 'pid: %s\n' "$pid"
    printf 'pid_starttime: %s\n' "$(_pid_starttime "$pid")"
    printf 'timeout_s: %s\n' "$timeout_s"
    printf 'model: %s\n' "$model"
  } > "$base.started.tmp" && mv "$base.started.tmp" "$base.started"
  printf '%s\n' "$pid" > "$base.pid.tmp" && mv "$base.pid.tmp" "$base.pid"
  return 0
}

# Classify a dispatch. Sets DISPATCH_RC when a valid .rc exists.
dispatch_state() {
  # Usage: dispatch_state <phase> <iter> <role>
  local base rc pid recorded current
  base="$FEATURE_FOLDER/transcripts/$(dispatch_id "$1" "$2" "$3")"
  DISPATCH_RC=""

  if [ ! -f "$base.started" ]; then
    if [ -f "$base.rc" ]; then echo INCONSISTENT; else echo NEVER_LAUNCHED; fi
    return 0
  fi

  if [ -f "$base.rc" ]; then
    rc="$(tr -d '[:space:]' < "$base.rc")"
    case "$rc" in
      ''|*[!0-9]*) echo CORRUPT; return 0 ;;
    esac
    DISPATCH_RC="$rc"
    case "$rc" in
      0)   echo COMPLETED ;;
      124) echo TIMED_OUT ;;
      *)   echo FAILED ;;
    esac
    return 0
  fi

  # No .rc yet: is the process actually alive? A bare pid is not enough — it
  # may have been recycled, so compare /proc starttime too.
  pid="$(status_field "$base.started" pid)"
  recorded="$(status_field "$base.started" pid_starttime)"
  current="$(_pid_starttime "$pid")"
  if [ -n "$current" ] && [ "$current" = "$recorded" ]; then
    echo RUNNING
  else
    echo ORPHANED
  fi
}

# Poll until a terminal state or until max_wait_s elapses.
await_dispatch() {
  # Usage: await_dispatch <phase> <iter> <role> <max_wait_s>
  local phase="$1" iter="$2" role="$3" max="$4" waited=0 state
  while [ "$waited" -lt "$max" ]; do
    state="$(dispatch_state "$phase" "$iter" "$role")"
    case "$state" in
      RUNNING) ;;
      *) printf '%s\n' "$state"; return 0 ;;
    esac
    sleep 2; waited=$((waited + 2))
  done
  printf 'RUNNING\n'
  return 1
}
```

**Resume.** On resume, call `dispatch_state` for the phase's dispatch before
doing anything else, and act on the result:

| State | Action |
|---|---|
| `NEVER_LAUNCHED` | dispatch fresh |
| `RUNNING` | resume polling — do **not** re-dispatch |
| `ORPHANED` | log `event=DISPATCH_ORPHANED`, re-dispatch once |
| `COMPLETED` | read STATUS, proceed |
| `TIMED_OUT` | apply the Mode-2 policy |
| `FAILED` | apply the failure-mode classifier |
| `CORRUPT` | treat as `FAILED`; surface the transcript path |
| `INCONSISTENT` | HALT — two runs are sharing one feature folder |

Re-dispatching after `ORPHANED` is safe only because every subagent writes its
STATUS last and atomically, so a half-written artifact from the dead process
cannot be mistaken for a finished one.
````

- [ ] **Step 4: Update the one-phase rule and resumability prose**

In the section at lines 88–109, add:

```markdown
**Polling is not bundling.** A long dispatch is launched with
`dispatch_detached` and then polled with `await_dispatch` across several short
bash invocations. That is still one dispatch for one phase. What remains
forbidden is combining two numbered phases into one block.
```

In the resumability section at lines 1610–1619, add:

```markdown
Resume reads `RUN_LOG.md` to find the last completed step **and** calls
`dispatch_state` for the current phase's dispatch. `RUN_LOG.md` alone is
insufficient: a crash after launch but before completion leaves no `dispatch`
entry, only the `event=DISPATCH_STARTED` record, and the control files are what
distinguish a still-running process from an abandoned one.
```

- [ ] **Step 5: Run the checks**

Run: `bash tests/check_07_fakecli.sh`
Expected: PASS — all ten state-machine assertions including PID reuse.

Run: `bash tests/check_05_contract.sh`
Expected: the `T18:` assertion PASSES.

- [ ] **Step 6: Commit**

```bash
git add develop-it-process.md tests/check_07_fakecli.sh
git commit -m "feat: add resumable detached dispatch

Long dispatches now survive the launching shell. Adds a deterministic
dispatch_id, atomic .rc/.started publication, PID-reuse detection via /proc
starttime, a DISPATCH_STARTED event written before launch, and an eight-state
classifier with a documented resume action per state."
```

---

## Task 18: Wire `role_timeout` through every dispatch site

**Files:**
- Modify: `develop-it-process.md` — every phase section that names a timeout (lines 933, 934, 992, 1044–1053, 1062, 1110–1119, 1213, 1225–1236, 1282–1291, 1305–1318, 1330, 1341)
- Test: `tests/check_05_contract.sh`

- [ ] **Step 1: Confirm the contract check is red**

Run: `bash tests/check_05_contract.sh`
Expected: `T19: no literal minute values in invocations` FAILS.

- [ ] **Step 2: Replace every phase-level timeout statement**

In each phase section, delete the `Timeout: N min` sentence and, where a phase
names its dispatch, reference the role instead. For example, Phase 4:

```markdown
Dispatch one `claude` subprocess for role `plan-writer` with the `plan-writer`
appendix. Inputs: `$FEATURE_FOLDER`, `$SPEC_PATH`. The subagent loads
`superpowers:writing-plans` and produces the plan at the skill's default
location. Because this role's timeout exceeds a single bash invocation, launch it
with `dispatch_detached 4 00 plan-writer` and poll with `await_dispatch`.
```

Apply the same treatment to every phase. Roles whose timeout is 120 minutes or
more (`plan-writer`, `implementer`, `code-reviewer-codex`) MUST use
`dispatch_detached`; the rest may use `claude_invoke` / `codex_invoke` directly.

For Phase 6, the dispatch also pins the sub-subagent model at the CLI. Write it
exactly as follows — the model must be **generated** from `role_model`, never
written as a literal, or it becomes a fourth place the assignment can drift:

````markdown
<!-- lint: snippet -->
```bash
# Phase 6: --agents pins the sub-subagent model in the harness, so the pin holds
# even if the supervisor disregards its instructions.
agents_json="$(jq -nc --arg m "$(role_model impl-worker)" \
  '{"impl-worker":{description:"Implementation sub-subagent",
                   prompt:"Follow the task instructions you are given.",
                   model:$m}}')"
render_prompt implementer \
  | dispatch_detached 6 00 implementer --agents "$agents_json"
```
````

Then update the `implementer` appendix (lines 2345–2354, 2365, 2383) to require
that every sub-subagent — implementation workers, spec-compliance reviewers, and
code-quality reviewers alike — is spawned with `subagent_type: impl-worker`, and
that `implementation-summary.md` records which agent type each task used so a
drift is auditable.

- [ ] **Step 3: Replace model-class prose with role names**

Every "Dispatch a `claude` Opus subprocess" / "one `claude` Sonnet subprocess"
phrase becomes "Dispatch one `claude` subprocess for role `<role-key>`". The
sites are lines 224, 986, 1049, 1052, 1053, 1060, 1115, 1118, 1119, 1213, 1225,
1236, 1291, 1305, 1313, 1318, 1324, 1328, 1336. Model class is never named in a
phase section — the Models table is the only place a model appears.

- [ ] **Step 4: Run the checks**

Run: `bash tests/check_05_contract.sh`
Expected: the two `T19:` assertions PASS.

Run: `bash tests/run.sh`
Expected: every tier-1 check passes except `check_01_lint.sh`, which does not exist yet.

- [ ] **Step 5: Commit**

```bash
git add develop-it-process.md
git commit -m "refactor: resolve timeouts and models per role at every dispatch site

Removes every literal minute value and every 'Opus'/'Sonnet' class word from the
phase sections. Roles at 120 min or more are marked for dispatch_detached."
```

---

## Task 19: Rename the model-named artifact files

**Files:**
- Modify: `develop-it-process.md` — 22 occurrences across 19 lines
- Test: `tests/check_05_contract.sh`

**Context:** must be one atomic change. `claude-opus-verdict.md` → `claude-verdict.md`, `claude-opus-findings.md` → `claude-findings.md`. The readiness writer is not a consumer (verified); the three summarizers are.

- [ ] **Step 1: Confirm red**

Run: `bash tests/check_05_contract.sh`
Expected: `T20: model-free artifact filenames` FAILS.

- [ ] **Step 2: Rename every occurrence in one pass**

```bash
sed -i 's/claude-opus-verdict\.md/claude-verdict.md/g; s/claude-opus-findings\.md/claude-findings.md/g' \
  develop-it-process.md
```

- [ ] **Step 3: Verify every site changed and none was missed**

```bash
/usr/bin/grep -c 'claude-verdict\.md' develop-it-process.md    # expect 12
/usr/bin/grep -c 'claude-findings\.md' develop-it-process.md   # expect 10
/usr/bin/grep -c 'claude-opus-' develop-it-process.md          # expect 0
```

Expected: 12, 10, 0. If the third is non-zero, stop and inspect — a partial rename leaves the summarizers reading a file nobody writes.

- [ ] **Step 4: Add a note explaining the naming**

Next to the folder-layout diagram, add:

```markdown
Reviewer artifacts are named by **vendor**, not model: `claude-verdict.md`,
`claude-findings.md`, `codex-verdict.md`, `codex-findings.md`. A filename must
not assert a model, or it starts lying the moment the Models table changes.
```

- [ ] **Step 5: Run the checks**

Run: `bash tests/check_05_contract.sh`
Expected: `T20:` PASSES.

- [ ] **Step 6: Commit**

```bash
git add develop-it-process.md
git commit -m "refactor: name reviewer artifacts by vendor, not model

claude-opus-{verdict,findings}.md -> claude-{verdict,findings}.md across all 22
occurrences in one commit; a partial rename would leave the three summarizers
reading files nobody writes."
```

---

## Task 20: Resolve the remaining contradictions

**Files:**
- Modify: `develop-it-process.md` — write-allow-list (lines 5, 23, 26, 31, 1653), transcript naming (lines 299–300, 853, 933), Codex-modes section (lines 449, 460, 504, 882–891), `preflight-codex` (lines 1859, 1881), `context7` (lines 916–928, 1829–1837, 1877–1879), leaked specifics (lines 105, 181, 2577, 2649), the `[y/N]` prompt (line 939), row 165, line 1632
- Test: `tests/check_05_contract.sh`

- [ ] **Step 1: Append the assertions**

Add to `tests/check_05_contract.sh` before `finish`:

```bash
# --- Task 20: contradictions ---
assert_absent 'Cheap \(micro\)|cheap mode|Cheap mode' "$D" "T20: cheap/deep renamed"
assert_present 'scoped|diff-aware' "$D" "T20: modes renamed to scoped/diff-aware"
assert_absent 'Phase 1 spec review|Phase 3 plan review|Phase 6 final review' "$D" \
  "T20: Codex-mode phase numbers corrected"
assert_absent 'frontend/src/features/canvas|Google ADK' "$D" "T20: leaked project specifics removed"
assert_present 'uv run pytest' "$D" "T20: test discovery uses uv"
assert_present 'CODEX_CONSENT' "$D" "T20: non-interactive consent override"
assert_present 'context7.*MCP server' "$D" "T20: context7 is described as an MCP server"
```

- [ ] **Step 2: Run to verify red**

Run: `bash tests/check_05_contract.sh`
Expected: the seven `T20:` assertions FAIL.

- [ ] **Step 3: Unify the write-allow-list**

Replace each of the four divergent statements with a reference to one canonical list. At line 26, write:

```markdown
- **Canonical write list.** The orchestrator may create directories with
  `mkdir -p` and may write ONLY: `RUN_LOG.md`, `full_log.md`,
  `process-improvement-proposition.md`, and
  `transcripts/<dispatch-id>.{json,err,rc,pid,started,prompt}` — all inside
  `$FEATURE_FOLDER`. Nothing else, ever. Reading remains restricted to STATUS
  files and the per-phase summaries they reference.
```

At lines 5, 23, 31 and 1653, replace the enumerations with "see the canonical write list in Allowed actions".

- [ ] **Step 4: Unify transcript naming**

Adopt `<phase>-iter<NN>-<vendor>.<ext>` everywhere, matching `dispatch_id`. Update lines 299–300 and 933, and note:

```markdown
Transcript and control files are named `<phase>-iter<NN>-<vendor>.<ext>`,
matching `dispatch_id`. Earlier revisions used three different schemes, which
left the readiness writer unable to locate transcripts reliably.
```

- [ ] **Step 5: Rename the Codex modes and fix the phase numbers**

Rewrite the modes table (lines 882–891):

```markdown
| Role | Mode | Filesystem allow-list | Command budget | Findings cap |
|---|---|---|---|---|
| `preflight-codex` | `micro` | skill directory listing only (no contents) | 2 | — |
| `spec-reviewer-codex` | `scoped` | `$SPEC_PATH` | 4 | blockers/majors uncapped; minors ≤10 |
| `plan-reviewer-codex` | `scoped` | `$SPEC_PATH` + `$PLAN_PATH` | 4 | blockers/majors uncapped; minors ≤10 |
| `code-reviewer-codex` | `diff-aware` | `$SPEC_PATH`, `$PLAN_PATH`, files in `git diff $IMPLEMENTATION_BASE_SHA...HEAD` | 20 | 5 blockers/majors + 5 minors |

Reasoning effort is **not** a mode property — it is per-role, in the Models
table. The previous "cheap vs deep" naming bundled effort with scope; with all
three reviewers at `high` effort, "cheap" would be actively misleading.

Spec review is Phase 3, plan review Phase 5, code review Phase 7. Earlier
revisions of this table labelled them 1, 3 and 6.
```

Update the mode words at lines 449, 460, 504, 934, 1045, 1111, 1283, 1873, 2021, 2231, 2552. Lift the findings caps in the `spec-reviewer-codex` and `plan-reviewer-codex` appendices (lines 2053, 2266) to "report every BLOCKER and MAJOR you find; cap MINOR findings at 10; keep each finding under 150 words". Leave line 2604 (`code-reviewer-codex`) at 5+5.

- [ ] **Step 6: Resolve the `preflight-codex` self-contradiction**

At line 1859, narrow the preamble:

```text
You are a dispatched subprocess. Do NOT load, execute, or follow the contents of
any Superpowers skill. This appendix is your complete instruction set.

You MAY test for the EXISTENCE of a skill directory or SKILL.md file — that is
this role's entire task. You may not read their contents.

Independence means independent judgment over the supplied artifact, not
independent repository discovery.
```

Leave the stricter "do not read any skill directory" wording in the other four Codex appendices, where no existence check is needed.

- [ ] **Step 7: Make `context7` a probed dependency**

At lines 916–928, add a third list:

```markdown
MCP servers that must be reachable:
- `context7` — required by `plan-writer`, `impl-worker`, `debugger` and
  `test-fixer`. It is an **MCP server, not a Superpowers skill**, so it is not
  covered by the skill probes above.

If `context7` is unreachable, do NOT halt. Log `event=CONTEXT7_UNAVAILABLE`,
record it in the readiness report, and downgrade every appendix's `context7`
requirement from MUST to best-effort for this run. Silently proceeding — the
previous behaviour — hid the degradation from the final report.
```

Add the probe to `preflight-claude` (line 1837) and report it in that appendix's STATUS as `context7: reachable|unreachable`.

- [ ] **Step 8: Fix the remaining small items**

- Line 105: delete the `cli_log.md` sentence; keep the rule.
- Line 181: replace `(Google ADK, httpx, click, etc.)` with `(any third-party dependency the plan names)`.
- Line 2577: replace the `rg -n "render_chart" frontend/src/...` example with `"$GREP_BIN" -rn "<symbol>" <dir> --include='*.ts'` and note that `rg` may be absent in a subprocess shell.
- Line 2649: change `pytest` to `uv run pytest` and note that `pytest` is not installed standalone.
- Lines 160, 1306, 2648, 3070: mark `start-all-tests.sh` as "a project-specific convention; fall through to discovery when absent".
- Line 939: add `A non-interactive run may pre-answer this prompt by setting CODEX_CONSENT=y|n. When CODEX_CONSENT is unset and stdin is not a TTY, HALT rather than reading EOF as "no".`
- Row 165 of the Models table is already replaced by Task 5's `summarizer-implementation` row; delete any remaining `(folded)` prose.
- Line 1632: add `Model failover is likewise forbidden. A rejected pinned id HALTs; there is no cross-model or cross-class substitution.`
- Line 147: replace the Claude-Code-specific tool names with functional descriptions ("the orchestrator must be able to read files, append to files, and run shell commands").

- [ ] **Step 9: Run the checks**

Run: `bash tests/check_05_contract.sh`
Expected: all `T20:` assertions PASS, and the whole file is green.

- [ ] **Step 10: Commit**

```bash
git add develop-it-process.md tests/check_05_contract.sh
git commit -m "fix: resolve document contradictions

Unifies the write list and transcript naming, renames cheap/deep to
scoped/diff-aware with effort moved to the role table, corrects the Codex-mode
phase numbers, narrows the preflight-codex preamble so its existence check is no
longer self-forbidden, makes context7 a probed MCP dependency with explicit
degradation, and adds CODEX_CONSENT for non-interactive runs."
```

---

## Task 21: Lint classification and the full green run

**Files:**
- Create: `tests/check_01_lint.sh`
- Modify: `develop-it-process.md` — add a lint marker above every `bash` fence; `README.md` (create)

**Interfaces:**
- Consumes: `tests/lib/extract.py` (`snippets`, `unmarked`, `cookbook`)
- Produces: a fully green `tests/run.sh`.

- [ ] **Step 1: Write the failing test**

Create `tests/check_01_lint.sh`:

```bash
#!/usr/bin/env bash
# Check 1: every fenced bash block is lint-classified; cookbook blocks lint clean.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source lib/assert.sh

# 1. No unmarked blocks. An unmarked block would silently escape the linter.
unmarked="$(python3 lib/extract.py unmarked)"
if [ -z "$unmarked" ]; then
  _ok "every bash fence carries a lint: marker"
else
  _fail "unmarked bash fences at document lines: $(printf '%s' "$unmarked" | tr '\n' ' ')"
fi

# 2. Syntax-check everything.
python3 lib/extract.py cookbook >/dev/null 2>&1 || { _fail "cookbook not extractable"; finish; }
python3 lib/extract.py snippets

bash -n "$BUILD/cookbook.sh" && _ok "cookbook.sh is syntactically valid" \
                             || _fail "cookbook.sh has a syntax error"
for s in "$BUILD"/snippets/*.sh; do
  [ -e "$s" ] || break
  bash -n "$s" || _fail "syntax error in snippet from document line ${s##*/}"
done
_ok "all snippets are syntactically valid"

# 3. shellcheck the cookbook only. Snippets legitimately reference variables
#    they do not define, so full linting there would be noise.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --shell=bash --severity=warning "$BUILD/cookbook.sh"; then
    _ok "shellcheck is clean at severity=warning"
  else
    _fail "shellcheck reported warnings or errors"
  fi
  finish
else
  note "shellcheck is not installed; install with: sudo apt-get install -y shellcheck"
  note "syntax checks above still ran and passed"
  [ "$_FAILURES" -eq 0 ] && skip "shellcheck unavailable (syntax checks passed)"
  finish
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/check_01_lint.sh`
Expected: FAIL listing every `bash` fence that still has no marker.

- [ ] **Step 3: Classify every bash fence**

Add `<!-- lint: cookbook -->` above every fence containing a complete, sourceable helper, and `<!-- lint: snippet -->` above every illustrative one. Tasks 5–17 already marked the blocks they rewrote; this step covers whatever remains. Use the failure output from Step 2 as the worklist.

Add a note in the Runtime cookbook section:

```markdown
Every fenced `bash` block in this document carries a lint marker.
`<!-- lint: cookbook -->` marks a complete, sourceable helper — these are
extracted into one file and both syntax-checked and shellchecked.
`<!-- lint: snippet -->` marks an illustrative fragment that references
orchestration variables without defining them; those get a syntax check only.
An unmarked block fails `tests/check_01_lint.sh`, so a new block cannot silently
escape the linter.
```

- [ ] **Step 4: Install shellcheck and iterate to clean**

```bash
sudo apt-get install -y shellcheck
bash tests/check_01_lint.sh
```

Fix every warning it reports in the document's cookbook blocks, re-running until
clean. Add `# shellcheck disable=SCxxxx` with a one-line justification only where
a warning is genuinely inapplicable.

- [ ] **Step 5: Write the README**

Create `README.md`:

```markdown
# develop-it-process

An autonomous SDLC orchestration prompt. `develop-it-process.md` drives `claude`
and `codex` CLI subprocesses through a phased spec → plan → implement → review
pipeline, with cross-vendor review gates.

## Usage

Set the two roots explicitly — this repository orchestrates *other* projects, so
they are never the same:

```bash
export PROCESS_PATH="$PWD/develop-it-process.md"
export REPO_ROOT="/path/to/the/target/project"
```

Then hand `develop-it-process.md` to an orchestrating agent.

## Models

Model, reasoning effort and timeout are pinned per role in the Models table in
`develop-it-process.md`, and implemented by `role_model` / `role_effort` /
`role_timeout`. `tests/check_04_table.sh` asserts the table and the functions
agree, so they cannot drift. There is no fallback: a rejected model id halts the
run.

## Tests

```bash
./tests/run.sh          # tier 1: offline, deterministic, free
./tests/run.sh --live   # adds the live model probe (billable)
```

Prerequisite for full linting: `sudo apt-get install -y shellcheck`. Without it
the lint check reports SKIP; a SKIP is never counted as a pass.
```

- [ ] **Step 6: Run the whole suite**

Run: `bash tests/run.sh`
Expected: `failed: 0`, with `check_90_live_models.sh` skipped.

- [ ] **Step 7: Run the live tier once**

Run: `bash tests/run.sh --live`
Expected: `failed: 0`. This is the check that confirms `claude-fable-5`,
`claude-opus-5`, `claude-sonnet-5` and `gpt-5.6-sol` are all accepted. If an id
is rejected, update the Models table — do not add a fallback.

- [ ] **Step 8: Commit**

```bash
git add develop-it-process.md tests/check_01_lint.sh README.md
git commit -m "test: classify every bash block and add the lint check

Unmarked blocks now fail, so no new block can escape the linter. Cookbook blocks
are shellchecked; snippets get a syntax check with a generated preamble. Adds a
README covering the two-root setup and the test tiers."
```

---

## Self-Review

**1. Spec coverage.** Every spec section maps to a task:

| Spec | Task |
|---|---|
| §5.1–5.3 role assignments, single source of truth | 5 |
| §5.4–5.6 effort, mode decoupling, findings caps | 5, 20 |
| §5.7 strict pinning | 7 |
| §5.8 preflight model probe | 8 |
| §5.9 role-keyed `resolved_models` | 7 |
| §5.10 sub-subagent pinning | 5 (`impl-worker` row + `role_model`), 20 |
| §6.1–6.2 two roots, path validation | 9 |
| §6.3 provenance | 10 |
| §6.4 codex sandbox `--add-dir` | 9 (decision), 7 (flag), 16 (test) |
| §6.5 `EPOCHREALTIME` | 11 |
| §6.6 binary checks, `GREP_BIN` | 8, 9 |
| §6.7 leaked specifics | 20 |
| §7.1 parallel dispatch | 13 |
| §7.2–7.3 porcelain parser, both gates | 12 |
| §7.4 trailing `&&` | 15 |
| §7.5 `codex_invoke --json` | 7 |
| §7.6 `render_prompt` | 14 |
| §7.7 `parse_usage` | 11 |
| §7.8 `validate_status` | 15 |
| §7.9 shell policy, xtrace, persistence | 15 |
| §8.1 detached dispatch state machine | 17 |
| §8.2 timeouts | 5 (table), 18 (wiring) |
| §8.3 renames | 19 |
| §8.4 contradictions | 20 |
| §9 harness tiers, lint classes, canary | 1–4, 6, 8, 16, 21 |
| §10 success criteria | 6 (`check_05_contract.sh`), 16–17, 21 |
| §12 ordering | task order |

**Gap found and closed:** §5.10's `--agents` JSON generation initially had no
step — Task 5 added the `impl-worker` row and Task 20 the appendix prose, but
nothing actually built the JSON. Fixed by adding the dispatch form to Task 18
Step 2, extending `dispatch_detached` to forward trailing arguments (Task 17),
and giving `codex_invoke` a matching signature so both branches of the detached
launcher are correct (Task 7).

**Second gap closed:** the detached child runs under `bash -c`, and shell
functions do not cross that boundary. Task 17 now exports the eight functions the
child calls; without this every detached dispatch would have failed with
`claude_invoke: command not found` — and because the child's output is redirected
to `/dev/null`, it would have failed *silently*, leaving only an `ORPHANED` state
with no diagnostic.

**2. Placeholder scan.** No `TBD`/`TODO`. Every code step contains runnable code.
Task 18 Steps 2–3 and Task 21 Step 3 are enumerated edits across many lines
rather than single code blocks; each names its exact line numbers and gives the
replacement text pattern, which is the most concrete form available for a
mechanical sweep.

**3. Type consistency.** Verified across tasks:
- `role_model` / `role_effort` / `role_timeout` / `role_vendor` / `_role_keys` — defined Task 5/8, used 7, 8, 10, 13, 16, 17, 18.
- `claude_invoke <role> <out> <err> [args...]` and `codex_invoke <role> <out> <err>` — defined 7, used 13, 16, 17.
- `porcelain_offenders <repo> <allow...>` — defined 12, used by `dirty_tree_check` and the Phase 6 baseline.
- `status_field <path> <key>` — defined 15, used by `dispatch_state` in 17. **Ordering note:** Task 17 depends on Task 15; the plan already sequences 15 before 17.
- `iso_now` — defined 10, used 12, 17.
- `now_ms` / `timed_dispatch` — defined 11, used in the Task 11 example.
- `canon` / `path_in_tree` / `is_git_root` / `validate_roots` — defined 9, used 12, 16.
- `dispatch_id` / `dispatch_state` / `await_dispatch` / `dispatch_detached` — defined 17, used 18.
- `PROCESS_PATH_REL` — set by `validate_roots` (9), consumed by `process_identity` (10).
- `FEATURE_FOLDER_OUTSIDE_REPO` — set by `validate_roots` (9), consumed by `codex_invoke` (7). **Forward reference:** Task 7 writes the consumer before Task 9 defines the setter. `codex_invoke` reads it as `${FEATURE_FOLDER_OUTSIDE_REPO:-}`, so it is safe under `set -u`; Task 16 is the first test that exercises both together.
