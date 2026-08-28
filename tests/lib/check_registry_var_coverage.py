#!/usr/bin/env python3
"""Cross-validate every $VAR a role appendix references against that SAME
role's own registry row (`required_inputs` + `optional_inputs`) -- Task 4
code review fix #4: appendices were introducing $ITERATION/$ROUND wholesale
without checking whether the role's registry contract actually declares
`iteration`/`round`. (check_03_varcoverage.sh's existing check only proves a
var is in render_prompt's global substitution list, i.e. render_prompt CAN
resolve it -- never that the ROLE'S OWN contract says it should receive it.)

A small set of vars is mechanical plumbing every appendix's STATUS
publication needs regardless of the role's declared business inputs (the
attempt-identity/publisher-invocation scaffolding Task 4 introduced, plus
pre-existing shell-tooling handles) -- these are exempt everywhere. Every
other var must map (via the obvious UPPER_SNAKE -> lower_snake token
convention) to one of that role's required_inputs/optional_inputs cells.

Usage: check_registry_var_coverage.py PROCESS_DOC ROLE_CONTRACTS_TSV
Prints one "role: $VAR not declared in required_inputs/optional_inputs" line
per violation; exit 0 with no output means every appendix only reaches for
what its own contract declares.
"""
import re
import sys

EXEMPT_VARS = {
    "FEATURE_FOLDER", "PHASE_DIR", "DISPATCH_ID", "LOGICAL_DISPATCH_ID",
    "ATTEMPT", "ROLE_CONTRACTS_PATH", "STATUS_PUBLISHER_PATH", "GREP_BIN",
    "RESOLVED_MODELS",
}

APPENDIX = re.compile(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", re.S)
VARUSE = re.compile(r"\$([A-Z][A-Z0-9_]{2,})")


def registry_rows(tsv_path):
    with open(tsv_path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        role_i = header.index("role")
        req_i = header.index("required_inputs")
        opt_i = header.index("optional_inputs")
        rows = {}
        for line in f:
            cols = line.rstrip("\n").split("\t")
            declared = set()
            for i in (req_i, opt_i):
                cell = cols[i] if len(cols) > i else ""
                declared |= {t for t in cell.split(";") if t and t != "—"}
            rows[cols[role_i]] = declared
        return rows


def main(argv):
    doc_path, tsv_path = argv[1], argv[2]
    text = open(doc_path).read()
    rows = registry_rows(tsv_path)
    problems = []
    for role, body in APPENDIX.findall(text):
        if role not in rows:
            continue
        declared = rows[role]
        for var in sorted(set(VARUSE.findall(body))):
            if var in EXEMPT_VARS:
                continue
            token = var.lower()
            if token not in declared:
                problems.append(f"{role}: ${var} not declared in required_inputs/optional_inputs")
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
