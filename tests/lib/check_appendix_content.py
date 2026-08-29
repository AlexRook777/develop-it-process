#!/usr/bin/env python3
"""Assert that specific top-level role appendices still carry specific
non-STATUS role-contract sentences: verdict rules, findings-file format
blocks, progress.jsonl durability notes, etc. -- the exact content Task 4's
Step 6 conversion (STATUS write -> one publish-status call) must NOT take
with it (code review fix #1: an earlier pass replaced whole `## Output`
sections and lost ~54 lines of contract this way).

Usage: check_appendix_content.py PROCESS_DOC
Prints one "role: missing DESC" line per violation; exit 0 with no output
means every checked appendix still carries its expected content.
"""
import re
import sys

CHECKS = [
    ("spec-reviewer-claude", r"blockers=0.{0,3}AND.{0,3}majors=0", "verdict rule (blockers=0 AND majors=0)"),
    ("spec-reviewer-codex", r"blockers=0.{0,3}AND.{0,3}majors=0", "verdict rule (blockers=0 AND majors=0)"),
    ("plan-reviewer-claude", r"blockers=0.{0,3}AND.{0,3}majors=0", "verdict rule (blockers=0 AND majors=0)"),
    ("plan-reviewer-codex", r"blockers=0.{0,3}AND.{0,3}majors=0", "verdict rule (blockers=0 AND majors=0)"),
    ("code-reviewer-claude", r"blockers=0.{0,3}AND.{0,3}majors=0", "verdict rule (blockers=0 AND majors=0)"),
    ("code-reviewer-codex", r"blockers=0.{0,3}AND.{0,3}majors=0", "verdict rule (blockers=0 AND majors=0)"),
    ("spec-reviewer-codex", r"###\s*Finding N", "findings-file format block"),
    ("plan-reviewer-codex", r"###\s*Finding N", "findings-file format block"),
    ("code-reviewer-codex", r"###\s*Finding N", "findings-file format block"),
    ("implementer", r"NEEDS_DEBUG.{0,3}if verification failed", "verdict rule: NEEDS_DEBUG"),
    ("implementer", r"No-secret check result", "human summary contents: no-secret check"),
    ("implementer", r"drift from .subagent_type: impl-worker. is auditable", "implementer/impl-worker drift audit"),
    # Task 9: progress.jsonl is now a real checkpoint_append call site, not
    # free-hand "write it yourself" prose -- check for the real call rather
    # than the retired "incrementally" wording.
    ("implementation-fixer", r"checkpoint_append", "progress.jsonl checkpoint_append call"),
    ("documentation-writer", r"checkpoint_append", "progress.jsonl checkpoint_append call"),
    ("spec-fixer", r"addressed_blockers", "addressed_blockers/majors/deferred_minors fields"),
    ("debugger", r"does not promise verification passes", "advisory verdict note"),
    ("test-fixer", r"does not promise the suite passes", "advisory verdict note"),
]


def main(argv):
    text = open(argv[1]).read()
    problems = []
    for role, pattern, desc in CHECKS:
        m = re.search(rf"<!-- BEGIN: {role} -->(.*?)<!-- END: {role} -->", text, re.S)
        body = m.group(1) if m else ""
        if not re.search(pattern, body):
            problems.append(f"{role}: missing {desc}")
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
