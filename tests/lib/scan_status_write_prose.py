#!/usr/bin/env python3
"""Print the count of lines, WITHIN a top-level role appendix body (between
its BEGIN/END markers), that read as a PROSE directive for that role to
write/rewrite/overwrite a *-status.md or STATUS.md file directly -- the
role-local writer Step 6 retires (every role must call $STATUS_PUBLISHER_PATH
instead). Scoped to appendix bodies only: the surrounding orchestrator
narrative legitimately describes the (pre-Task-4) dispatch protocol in
general terms ("the subagent writes ... STATUS.md") and is out of Task 4's
scope. Matching is restricted to `.md` filenames (never the bare word
STATUS/status, a common field/section name) AND requires the verb and the
filename close together (<=40 chars) so a verb governing some OTHER object
earlier in a long sentence that merely goes on to mention a *-status.md file
in a different (read-only) clause does not false-positive -- e.g.
"Rewrite all-test-summary.md (... re-read earlier rounds' ... test-runner-
status.md ...)" must NOT match; "ATOMICALLY rewrite `implementer-status.md`
reflecting ..." must.
Usage: scan_status_write_prose.py PROCESS_DOC
"""
import re
import sys

VERB = r"(?:write|writes|rewrite|rewrites|overwrite|overwrites)"
FNAME = r"[\w$-]*-?status\.md"
NEAR = re.compile(rf"\b{VERB}\b.{{0,40}}?{FNAME}|{FNAME}.{{0,40}}?\b{VERB}\b", re.I)
APPENDIX = re.compile(r"<!-- BEGIN: ([a-z0-9-]+) -->(.*?)<!-- END: \1 -->", re.S)


def main(argv):
    text = open(argv[1]).read()
    hits = []
    for role, body in APPENDIX.findall(text):
        for ln in body.splitlines():
            if NEAR.search(ln):
                hits.append((role, ln.strip()))
    print(len(hits))
    for role, ln in hits:
        print(f"  {role}: {ln[:160]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
