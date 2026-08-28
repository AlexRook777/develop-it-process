#!/usr/bin/env python3
"""Cross-validate each top-level role appendix's declared `output_count` /
`output_NN` lines against its own registry row's `outputs` cell (Task 4 code
review fix #3: output_count was hardcoded to 0 everywhere, so the publisher's
contiguity/absolute-path/realpath-containment validation was never exercised
by any real role).

A registry `outputs` cell lists tokens; some are STATUS-inherent or already
carried by a dedicated common field, not a separate declared artifact -- see
EXEMPT_OUTPUT_TOKENS below. Every other token must correspond to exactly one
`output_NN` line in the appendix's `## Publish STATUS` STATUS-content heredoc.

Usage: check_output_declarations.py PROCESS_DOC ROLE_CONTRACTS_TSV
Prints one "role: detail" line per mismatch found; exit 0 with no output
means every appendix agrees with its registry row.
"""
import re
import sys

# Kept in sync by hand with roles_meta.EXEMPT_OUTPUT_TOKENS in the scratch
# generator -- status/verdict/check_status are the STATUS file itself, not a
# separate artifact; progress.jsonl already travels as checkpoint_path;
# changed_paths is a dynamic-length list field, not a single declared output.
EXEMPT_OUTPUT_TOKENS = {"status", "verdict", "check_status", "progress.jsonl", "changed_paths"}

APPENDIX = re.compile(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", re.S)
OUTPUT_COUNT_RE = re.compile(r"^output_count:\s*(\d+)\s*$", re.M)
OUTPUT_LINE_RE = re.compile(r"^output_(\d+):", re.M)


def registry_rows(tsv_path):
    with open(tsv_path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        role_i, outputs_i = header.index("role"), header.index("outputs")
        rows = {}
        for line in f:
            cols = line.rstrip("\n").split("\t")
            rows[cols[role_i]] = cols[outputs_i]
        return rows


def expected_count(outputs_cell):
    tokens = [t for t in outputs_cell.split(";") if t]
    return len([t for t in tokens if t not in EXEMPT_OUTPUT_TOKENS])


def main(argv):
    doc_path, tsv_path = argv[1], argv[2]
    text = open(doc_path).read()
    rows = registry_rows(tsv_path)
    problems = []
    for role, body in APPENDIX.findall(text):
        if role not in rows:
            continue  # a role with no registry row is check_04's problem, not this one
        want = expected_count(rows[role])
        m = OUTPUT_COUNT_RE.search(body)
        if not m:
            problems.append(f"{role}: no output_count field found")
            continue
        declared = int(m.group(1))
        actual_lines = sorted(int(n) for n in OUTPUT_LINE_RE.findall(body))
        if declared != want:
            problems.append(f"{role}: output_count={declared} but registry outputs cell implies {want}")
        elif actual_lines != list(range(1, declared + 1)):
            problems.append(f"{role}: output_count={declared} but output_NN lines present are {actual_lines}")
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
