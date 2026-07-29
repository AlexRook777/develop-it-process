#!/usr/bin/env python3
"""Print "<appendix>\\t<declared verdict line>" for every appendix in the doc."""
import re
import sys

text = open(sys.argv[1]).read()
for m in re.finditer(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", text, re.S):
    name, body = m.group(1), m.group(2)
    v = re.search(r"^verdict: (.+)$", body, re.M)
    if v:
        print(f"{name}\t{v.group(1).strip()}")
