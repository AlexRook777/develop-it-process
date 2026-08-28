#!/usr/bin/env python3
"""Print "<appendix>\\t<declared verdicts>" for every appendix in the doc.

Each appendix's role-contract block declares:
    Allowed verdicts: `DONE;PARTIAL;BLOCKED`
(semicolon-delimited, matching the registry's `verdicts` column exactly, so
tests/check_06_cookbook.sh can compare normalized semicolon-delimited SETS
against `role_verdicts <role>` and report both sides on drift.)
"""
import re
import sys

text = open(sys.argv[1]).read()
for m in re.finditer(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", text, re.S):
    name, body = m.group(1), m.group(2)
    v = re.search(r"^-\s*Allowed verdicts:\s*`?([^`\n]+?)`?\s*$", body, re.M)
    if v:
        declared = ";".join(p.strip() for p in v.group(1).split(";") if p.strip())
        print(f"{name}\t{declared}")
