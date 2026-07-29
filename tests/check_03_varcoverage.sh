#!/usr/bin/env bash
# Check 4: every $VAR used in an appendix body is substituted by render_prompt.
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

# 2. Collect the substitution list by ASKING the cookbook, not by parsing it.
#    The keys live in the shell function render_keys(). An earlier version of this
#    check scraped a python `for key in [...]` literal that Task 14 removes, so it
#    could never have turned green.
load_cookbook || finish
if ! declare -F render_keys >/dev/null; then
  _fail "render_keys is not defined in the cookbook"
  finish
fi
subst="$(render_keys | sort -u)"
if [ -z "$subst" ]; then
  _fail "render_keys returned nothing"
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
