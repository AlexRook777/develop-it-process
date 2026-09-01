#!/usr/bin/env bash
# shellcheck shell=bash
#
# The develop-it runtime cookbook: every orchestration helper the process
# document (develop-it-prompt.md) invokes. Authored HERE -- the document
# carries only a per-section function index. Definitions only: no top-level
# statements, so any shell (a phase shell, the test suite, a pristine probe)
# can `source` this file safely; tests/check_01_lint.sh enforces that
# invariant, plus `bash -n` and shellcheck at severity=warning.
#
# bootstrap_runtime (defined below) copies this file verbatim into
# $FEATURE_FOLDER/.orchestration/runtime/develop-it-runtime.sh, covered by
# manifest.sha256 together with the registries extracted from the document
# and the runtime/publish-status program.
# ---- Process policy registry ------------------------------------------------
# Reads the generated policy.tsv (materialized under $RUNTIME_DIR by
# bootstrap_runtime) for a single named value. A policy name absent from the
# registry, or duplicated in it, is a process-definition bug: fail loudly with
# a machine-readable token rather than silently defaulting.
# Never abort the caller: a missing $RUNTIME_DIR or policy.tsv returns a token
# on stderr and a non-zero status, exactly like an unknown name. A top-level
# ${VAR:?} here would kill any shell that merely sources the cookbook.
policy_value() {
  local name="$1"
  local path
  if [ -z "${RUNTIME_DIR:-}" ]; then
    printf 'POLICY_RUNTIME_UNSET:%s\n' "$name" >&2
    return 1
  fi
  path="$RUNTIME_DIR/policy.tsv"
  if [ ! -r "$path" ]; then
    printf 'POLICY_REGISTRY_MISSING:%s\n' "$path" >&2
    return 1
  fi
  awk -F'\t' -v n="$name" '
    NR == 1 { next }
    $1 == n { v = $2; c++ }
    END {
      if (c == 0) { print "POLICY_UNKNOWN:" n > "/dev/stderr"; exit 1 }
      if (c > 1)  { print "POLICY_DUPLICATE:" n > "/dev/stderr"; exit 1 }
      print v
    }
  ' "$path"
}

# ---- Path helpers -----------------------------------------------------------
# `grep` may be a shell-function shim in some harnesses; that shim does not
# exist in subprocess shells and errors differently on the same pattern.
# GREP_BIN and PYTHON_BIN are set by init_orchestration_vars below, not here —
# the cookbook must contain no top-level statements.
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
#
# CRITICAL: these checks live in a FUNCTION, never at top level. A top-level
# `${VAR:?}` aborts any shell that sources the cookbook — including the test
# suite, which sources it to unit-test the helpers. The cookbook must be pure
# definitions with no executable top-level statements; check_01_lint.sh enforces
# that invariant.
init_orchestration_vars() {
  # Usage: init_orchestration_vars [phase]
  # <phase> is the schema-v2 phase number (2..10; -1/1 for preflight). Every
  # phase's own bash invocation calls `init_orchestration_vars <phase>` at the
  # top of its fresh shell. The argument is optional ONLY for pre-phase setup
  # that has no durable phase context yet -- the Step 1.0 canary, or a test
  # fixture bootstrapping a throwaway environment -- where there is nothing
  # yet to reconstruct. Whenever a phase IS given, reconstruction runs
  # UNCONDITIONALLY: there is no separate opt-in flag on top of the argument.
  local phase="${1:-}"
  PROCESS_PATH="${PROCESS_PATH:?must be set to the absolute path of this document}"
  REPO_ROOT="${REPO_ROOT:?must be set to the target project repo root}"
  FEATURE_FOLDER="${FEATURE_FOLDER:?must be set before dispatching any phase}"
  GREP_BIN="${GREP_BIN:-/usr/bin/grep}"
  PYTHON_BIN="$(command -v python3 || true)"
  if [ -z "$PYTHON_BIN" ]; then
    echo "halt: python3 not on PATH; render_prompt requires it" >&2
    return 1
  fi
  codex_available="${codex_available:-false}"
  codex_disabled_by_user="${codex_disabled_by_user:-false}"
  local roots_rc
  validate_roots
  roots_rc=$?
  # Only compute process-file identity once the roots it depends on
  # (PROCESS_PATH_REL, PROCESS_REPO_ROOT) are known good. A failed validate_roots
  # must still be reported as failure -- a successful process_identity call must
  # never mask it.
  [ "$roots_rc" -eq 0 ] && process_identity
  [ "$roots_rc" -eq 0 ] || return "$roots_rc"

  [ -z "$phase" ] || reconstruct_durable_inputs "$phase" || return 1
  return 0
}

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
  # failure looks like a vendor outage. invoke_vendor adds --add-dir in that case.
  if path_in_tree "$(canon "$FEATURE_FOLDER" 2>/dev/null || echo "$FEATURE_FOLDER")" "$REPO_ROOT"; then
    FEATURE_FOLDER_OUTSIDE_REPO=""
  else
    FEATURE_FOLDER_OUTSIDE_REPO=yes
  fi
  return "$halt"
}

# ---- Process-fileset identity (logged in every dispatch entry) --------------
# The process "file" is a SET (spec S16.2, generalized): the document itself,
# every file directly under $PROCESS_REPO_ROOT/runtime/ (this file and
# the publish-status source; runtime/ is flat by design), and every phase
# pack $PROCESS_REPO_ROOT/phases/*.md (P00 stage 2). All fields describe
# THAT set, so every git call targets PROCESS_REPO_ROOT. A bare `git` call
# would report the target project instead.
#
# develop_it_dirty (spec S16.2) is one of FOUR typed states, never a bare
# yes/no, evaluated over the WHOLE set:
#   no        every member tracked, and every member matches HEAD exactly.
#   yes       every member tracked, and at least one differs from HEAD.
#   untracked git ls-files --error-unmatch fails for at least one member --
#             this is the SAME outcome whether that file is plain-untracked
#             or ignored-untracked (ls-files only ever lists what is IN the
#             index; both are equally "not in the index"), so one check
#             covers both per spec S16.2 step 4.
#   unknown   non-git repository, OR `git diff --quiet` itself failed for a
#             reason other than "a diff exists" (exit code > 1 -- a real I/O
#             or object-database error). PROCESS_DIRTY_REASON is always set
#             when this state is reported, and only then.
# PROCESS_FILE_SHA256 is computed from the set members' own bytes via
# process_fileset_sha256, independently of git entirely (spec S16.2 step 6)
# -- it is correct in every one of the four states above, including non-git.

# The set, one repo-relative path per line: the document first (its
# PROCESS_PATH_REL, falling back to stripping the PROCESS_REPO_ROOT prefix),
# then every file directly under runtime/ plus every phases/*.md pack (P00
# stage 2), in one LC_ALL=C sorted list. Missing runtime/ or phases/
# directories (a test fixture repo) simply contribute nothing -- the digest
# below stays deterministic either way.
#
# The on-disk globs are UNIONED with `git ls-files` over the same directories
# (Task 12, closing Task 10's deferred minor): a TRACKED member deleted from
# the worktree would otherwise vanish from the set entirely, and the identity
# would silently report a clean, smaller set instead of dirty. Via the union
# the deleted member stays a member: still tracked (so not `untracked`), and
# `git diff HEAD` over it reports the deletion -- develop_it_dirty=yes.
# sha256sum's error for the missing file is suppressed as documented below.
process_fileset_files() {
  printf '%s\n' "${PROCESS_PATH_REL:-${PROCESS_PATH#"$PROCESS_REPO_ROOT"/}}"
  local f
  {
    for f in "$PROCESS_REPO_ROOT"/runtime/*; do
      [ -f "$f" ] && printf 'runtime/%s\n' "${f##*/}"
    done
    for f in "$PROCESS_REPO_ROOT"/phases/*.md; do
      [ -f "$f" ] && printf 'phases/%s\n' "${f##*/}"
    done
    git -C "$PROCESS_REPO_ROOT" ls-files -- 'runtime/*' 'phases/*.md' 2>/dev/null
  } | LC_ALL=C sort -u
}

# The deterministic set digest: sha256 over the concatenated per-file
# `sha256sum` lines ("<sha256>  <repo-relative-path>"), in
# process_fileset_files order. Any byte change to, or rename of, any member
# changes the digest. A member that cannot be hashed contributes nothing
# (its sha256sum error is suppressed), so a broken set still yields a
# digest that simply fails to match anything recorded for the intact set.
process_fileset_sha256() {
  local -a _pf_files
  mapfile -t _pf_files < <(process_fileset_files)
  ( cd "$PROCESS_REPO_ROOT" 2>/dev/null && sha256sum -- "${_pf_files[@]}" 2>/dev/null ) \
    | sha256sum | cut -d' ' -f1
}

process_identity() {
  local -a _pi_files
  mapfile -t _pi_files < <(process_fileset_files)
  PROCESS_FILE_SHA256="$(process_fileset_sha256)"
  # Code review round 2 fix: `2>/dev/null || echo non-git` INSIDE the
  # substitution is wrong on an unborn branch -- git prints the literal
  # word "HEAD" to STDOUT (not just its fatal: message to stderr) and
  # still exits non-zero, so the substitution would capture the TWO-LINE
  # garbage string "HEAD\nnon-git", never matching a plain `= non-git`
  # test. Check the exit code OUTSIDE the substitution instead, so a
  # failure always resets PROCESS_GIT_HEAD to the clean sentinel,
  # discarding whatever partial stdout git produced.
  PROCESS_GIT_HEAD="$(git -C "$PROCESS_REPO_ROOT" rev-parse HEAD 2>/dev/null)" \
    || PROCESS_GIT_HEAD=non-git
  PROCESS_DIRTY_REASON=""
  if [ "$PROCESS_GIT_HEAD" = non-git ]; then
    PROCESS_DIRTY=unknown
    PROCESS_DIRTY_REASON="PROCESS_REPO_ROOT has no HEAD (non-git or unborn branch)"
  elif ! git -C "$PROCESS_REPO_ROOT" ls-files --error-unmatch -- "${_pi_files[@]}" \
         >/dev/null 2>&1; then
    PROCESS_DIRTY=untracked
  else
    local diff_rc=0
    git -C "$PROCESS_REPO_ROOT" diff --quiet HEAD -- "${_pi_files[@]}" 2>/dev/null \
      || diff_rc=$?
    if [ "$diff_rc" -eq 0 ]; then
      PROCESS_DIRTY=no
    elif [ "$diff_rc" -eq 1 ]; then
      PROCESS_DIRTY=yes
    else
      PROCESS_DIRTY=unknown
      PROCESS_DIRTY_REASON="git diff HEAD -- <process fileset> failed (rc=$diff_rc)"
    fi
  fi
}

# ---- Timestamp helper (used by _dispatch_ingest_result and every event-tagged
# RUN_LOG block) ---------------------------------------------------------
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- Durable input reconstruction (schema-v2, spec §6.3) --------------------
# Every phase starts in a fresh shell; nothing a previous phase's shell set
# survives it. `init_orchestration_vars <phase>` calls this UNCONDITIONALLY
# whenever a phase is given -- there is no separate opt-in flag -- to
# re-derive every durable input that phase needs from validated upstream
# STATUS/events, never from an inherited shell variable. A missing durable
# input is PRELAUNCH_FAILED:<contract-name>, never reclassified as a
# dirty-tree or vendor failure.

# SPEC_PATH is never stored anywhere new: the Naming convention already makes
# it a pure function of $FEATURE_FOLDER (swap the `-artifacts` suffix for
# `-design.md`). Reconstruction is that reversal plus an existence check --
# the same derivation summarizer-plan's appendix already documents in prose.
_spec_path_from_feature_folder() {
  local dir base
  dir="$(dirname "$FEATURE_FOLDER")"
  base="$(basename "$FEATURE_FOLDER")"
  case "$base" in
    *-artifacts) printf '%s/%s-design.md\n' "$dir" "${base%-artifacts}" ;;
    *) return 1 ;;
  esac
}

# Accepted spec: gated on the spec-review gate having actually completed
# (its summary file existing), not merely on the derived path existing --
# a spec file that exists but was never reviewed is not yet "accepted".
_reconstruct_accepted_spec() {
  [ -f "$FEATURE_FOLDER/3-spec-review/spec-review-summary.md" ] \
    || { echo "PRELAUNCH_FAILED:accepted_spec" >&2; return 1; }
  SPEC_PATH="$(_spec_path_from_feature_folder)" && [ -f "$SPEC_PATH" ] \
    || { echo "PRELAUNCH_FAILED:accepted_spec" >&2; return 1; }
  # shellcheck disable=SC2034  # consumed by the calling phase shell (spec §6.3 "spec revision")
  SPEC_REVISION="$(git -C "$REPO_ROOT" log -1 --format=%H -- "$SPEC_PATH" 2>/dev/null || echo non-git)"
}

# Accepted plan: PLAN_PATH is not derivable from a naming rule -- plan-writer
# recorded it directly in plan-status.md's own `plan_path:` field, so read it
# from there rather than guessing a filename convention.
_reconstruct_accepted_plan() {
  local st="$FEATURE_FOLDER/4-plan-writing/plan-status.md"
  [ -f "$st" ] || { echo "PRELAUNCH_FAILED:accepted_plan" >&2; return 1; }
  PLAN_PATH="$(status_field "$st" plan_path)"
  [ -n "$PLAN_PATH" ] && [ -f "$PLAN_PATH" ] \
    || { echo "PRELAUNCH_FAILED:accepted_plan" >&2; return 1; }
  # shellcheck disable=SC2034  # consumed by the calling phase shell (spec §6.3 "plan revision")
  PLAN_REVISION="$(git -C "$REPO_ROOT" log -1 --format=%H -- "$PLAN_PATH" 2>/dev/null || echo non-git)"
}

# Implementation baseline AND final SHA. The baseline is the SHA captured
# before Phase 6 started (recorded in RUN_LOG, per "Step 6.0 — Capture
# implementation baseline"); the final SHA is simply current HEAD, valid the
# instant a later phase's fresh shell asks for it.
_reconstruct_implementation_baseline() {
  local st="$FEATURE_FOLDER/6-implementation/implementer-status.md"
  [ -f "$st" ] || { echo "PRELAUNCH_FAILED:implementation_baseline" >&2; return 1; }
  IMPLEMENTATION_BASE_SHA="$(status_field "$FEATURE_FOLDER/RUN_LOG.md" implementation_base_sha)"
  [ -n "$IMPLEMENTATION_BASE_SHA" ] || IMPLEMENTATION_BASE_SHA=non-git
  # shellcheck disable=SC2034  # consumed by the calling phase shell / a future task's finalization
  IMPLEMENTATION_FINAL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo non-git)"
}

# Vendor availability / proven state: the documented RUN_LOG-scan rule from
# "Run-scoped user opt-out: codex_disabled_by_user" above, as one real
# function instead of five repeated prose paragraphs at each per-phase gate.
_reconstitute_codex_disabled() {
  codex_disabled_by_user=false
  if [ -f "$FEATURE_FOLDER/RUN_LOG.md" ] \
     && "$GREP_BIN" -q '^event=CODEX_DISABLED_BY_USER_CONSENT$' "$FEATURE_FOLDER/RUN_LOG.md"; then
    codex_disabled_by_user=true
  fi
  # An `if`, not a trailing `&&`: a conditional as the final statement makes the
  # function return 1 whenever codex is NOT disabled, which is the normal path.
  if [ "$codex_disabled_by_user" = true ]; then
    codex_available=false
  fi
}

reconstruct_durable_inputs() {
  # Usage: reconstruct_durable_inputs <phase>
  local phase="$1"

  # Reconstructed for every phase, via mechanisms that already exist:
  # context7_policy() (defined below) and the codex opt-out flag's documented
  # scan rule.
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  CONTEXT7_POLICY="$(context7_policy 2>/dev/null)" || CONTEXT7_POLICY=best-effort
  _reconstitute_codex_disabled

  # Applicable optional skills: best-effort from Phase 1's own record. Never
  # gates -- an absent or unreadable record just means "none recorded".
  # `optional_skills_present` (spec S16.3/S16.4) is a required registry field
  # for both preflight roles (never the earlier "loaded_skills", a name that
  # was never actually written by either appendix), formatted as a
  # bracket-comma list like every other skill-evidence field this document
  # writes; `applicable_optional_skills` (see cookbook) takes the SAME
  # ";"-separated convention the Role Contract Registry's own multi-valued
  # cells use, so the bracket/comma form is normalized to that here, once,
  # rather than by every caller.
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  OPTIONAL_SKILLS="$(status_field "$FEATURE_FOLDER/1-preflight/phase-1/claude-check-status.md" optional_skills_present 2>/dev/null \
    | tr -d '[]' | sed -E 's/,[[:space:]]*/;/g')"

  # Applicable optional skills (spec S16.4): installed (OPTIONAL_SKILLS,
  # above) intersected with THIS run's relevant set -- context-discovery's
  # own `relevant_skills` STATUS field (2-context-discovery/status.md),
  # normalized the SAME bracket-to-";" way. Recomputed fresh in every
  # phase's shell from the two durable STATUS records, exactly like
  # CONTEXT7_POLICY/OPTIONAL_SKILLS above -- never persisted anywhere new
  # (the orchestrator's canonical write list has no slot for it, and none
  # is needed: recomputation is cheap and keeps this in sync with either
  # source ever being corrected). Absent before Phase 2 completes, which is
  # fine -- Phase 4 (plan-writer) is the first real consumer.
  local _relevant_skills
  _relevant_skills="$(status_field "$FEATURE_FOLDER/2-context-discovery/status.md" relevant_skills 2>/dev/null \
    | tr -d '[]' | sed -E 's/,[[:space:]]*/;/g')"
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  APPLICABLE_OPTIONAL_SKILLS="$(applicable_optional_skills "$OPTIONAL_SKILLS" "$_relevant_skills" 2>/dev/null)"

  # Findings / debugger-reverification inputs are optional by nature -- only
  # set when a prior round left one behind -- so they are reconstructed
  # opportunistically and never PRELAUNCH_FAILED on absence.
  DEBUGGER_STATUS_PATH="$FEATURE_FOLDER/6-implementation/debugger-status.md"
  [ -f "$DEBUGGER_STATUS_PATH" ] || DEBUGGER_STATUS_PATH=""

  # Continuation/checkpoint paths and declared foreign changes: initialized
  # empty here (Task 9) so render_prompt's `${!k+x}` substitution always
  # sees them "set", even for a phase whose own checkpointed role has never
  # failed -- but NOT actually reconstructed here. That real reconstruction
  # (`reconstruct_checkpoint_state`, "Checkpoint contract" below) genuinely
  # needs $ROLE_CONTRACTS_PATH (role_attempt_dir -> role_phases), which does
  # not exist yet at THIS point in a real phase's shell -- bootstrap_runtime
  # and its `source "$RUNTIME_DIR/develop-it-runtime.sh"` line, both of
  # which run AFTER init_orchestration_vars returns, are what materialize
  # it. A phase with a checkpointed role calls `reconstruct_checkpoint_state`
  # itself, once the runtime is sourced (see the per-phase snippet below).
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  CONTINUATION_PATH=""
  DECLARED_FOREIGN_CHANGES=""

  case "$phase" in
    4) _reconstruct_accepted_spec || return 1 ;;
    6) _reconstruct_accepted_spec || return 1
       _reconstruct_accepted_plan || return 1 ;;
    7) _reconstruct_accepted_spec || return 1
       _reconstruct_accepted_plan || return 1
       _reconstruct_implementation_baseline || return 1 ;;
    8) _reconstruct_accepted_plan || return 1
       _reconstruct_implementation_baseline || return 1 ;;
    9) _reconstruct_accepted_spec || return 1
       _reconstruct_accepted_plan || return 1
       _reconstruct_implementation_baseline || return 1
       [ -f "$FEATURE_FOLDER/7-code-review/code-review-summary.md" ] \
         || { echo "PRELAUNCH_FAILED:review_summary" >&2; return 1; }
       [ -f "$FEATURE_FOLDER/8-all-tests/all-test-summary.md" ] \
         || { echo "PRELAUNCH_FAILED:test_summary" >&2; return 1; }
       ;;
  esac
  return 0
}

# ---- Generated runtime (spec §7.1 / §7.2) -----------------------------------
# bootstrap_runtime materializes $RUNTIME_DIR from verbatim copies of this
# repository's runtime/cookbook.sh and runtime/publish-status plus the
# role-contract, policy, and event-contract registries extracted from the
# process document's tables -- an all-or-nothing operation. Sets (non-local, for the
# rest of this phase's shell): ORCHESTRATION_DIR, RUNTIME_DIR.
#
# Test hooks (read only here; production never sets them):
#   BOOTSTRAP_FAIL_AFTER=<n>          stop extraction after the n-th generated
#                                     file, leaving the staging dir in place
#                                     with NO manifest.sha256.
#   BOOTSTRAP_ORPHAN_AGE_SECONDS=<n>  override the default 300s freshness
#                                     window before an orphan staging
#                                     directory is swept (see step 2 below).
#
# Prints exactly one of BOOTSTRAP_OK, BOOTSTRAP_REUSED, or
# BOOTSTRAP_RACE_LOST_VALID on stdout and returns 0; or prints one of
# BOOTSTRAP_INTERRUPTED:<n>, RUNTIME_MANIFEST_INVALID:<path>,
# BOOTSTRAP_RACE_LOST_INVALID:<path>, or BOOTSTRAP_IO_ERROR:<path> on stderr
# -- with the failing command's own diagnostic surfaced beneath it, never
# buried in a discarded temp file -- and returns 1. EVERY failure path prints
# one of these tokens; there is no silent `return 1`.

# The ONE place every extraction failure funnels through: emits TOKEN on
# stderr, plus DETAIL_FILE's content (if given and non-empty) indented
# beneath it, so no `|| return 1` in this section can ever be silent.
_bootstrap_die() {
  local token="$1" detail_file="${2:-}"
  echo "$token" >&2
  if [ -n "$detail_file" ] && [ -s "$detail_file" ]; then
    sed 's/^/  /' "$detail_file" >&2
  fi
  return 1
}

_bootstrap_atomic_write() {
  # Usage: _bootstrap_atomic_write DEST MODE < content
  # O_CREAT|O_EXCL + a write LOOP (a single os.write can return short even for
  # a regular file, and a truncated write would have its hash certified as
  # correct by the manifest) + fsync-before-close: durable, complete bytes.
  local dest="$1" mode="$2"
  "$PYTHON_BIN" -c '
import os, sys
dest = sys.argv[1]
mode = int(sys.argv[2], 8)
data = sys.stdin.buffer.read()
fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
try:
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]
    os.fsync(fd)
finally:
    os.close(fd)
' "$dest" "$mode"
}

_bootstrap_fsync_path() {
  # Works for both a regular file and a directory fd on Linux.
  "$PYTHON_BIN" -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$1"
}

_bootstrap_rename_noreplace() {
  # Usage: _bootstrap_rename_noreplace TMP_DIR FINAL_DIR
  # renameat2(..., RENAME_NOREPLACE) via ctypes (stdlib only): fails with
  # EEXIST rather than merging when FINAL_DIR already exists -- even an EMPTY
  # FINAL_DIR, which plain rename(2) would otherwise happily replace. A race
  # result, never a licence to merge or overwrite the winner.
  "$PYTHON_BIN" -c '
import ctypes, os, sys
tmp, final = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL("libc.so.6", use_errno=True)
AT_FDCWD = -100
RENAME_NOREPLACE = 1
rc = libc.renameat2(AT_FDCWD, os.fsencode(tmp), AT_FDCWD, os.fsencode(final), RENAME_NOREPLACE)
if rc != 0:
    sys.exit(1)
' "$1" "$2"
}

# The five generated-file names, in the fixed order they are materialized and
# the fixed order the manifest records them.
_bootstrap_manifest_names() {
  printf '%s\n' develop-it-runtime.sh role-contracts.tsv policy.tsv events.tsv publish-status
}

# Returns 0 iff $1/manifest.sha256 records the CURRENT process-fileset digest
# (process_fileset_sha256: the document plus every runtime/ source file --
# editing ANY member of the set invalidates every existing runtime) AND the
# CURRENT extractor's SHA-256 -- editing tests/lib/extract.py with the set
# unchanged must also invalidate, since the extractor, not just the tables,
# determines the generated registry bytes -- lists EXACTLY the five
# generated-file entries (never fewer, never extra), every listed file
# exists with the right permissions, and `sha256sum -c` validates all five.
_bootstrap_verify_manifest() {
  local dir="$1" manifest fileset_sha recorded_sha extractor_sha recorded_extractor_sha names entries f mode
  manifest="$dir/manifest.sha256"
  [ -f "$manifest" ] || return 1
  fileset_sha="$(process_fileset_sha256)"
  recorded_sha="$("$GREP_BIN" -m1 '^process_fileset_sha256=' "$manifest" | cut -d'=' -f2)"
  [ -n "$recorded_sha" ] || return 1
  [ "$recorded_sha" = "$fileset_sha" ] || return 1

  extractor_sha="$(sha256sum "$PROCESS_REPO_ROOT/tests/lib/extract.py" 2>/dev/null | cut -d' ' -f1)"
  recorded_extractor_sha="$("$GREP_BIN" -m1 '^extractor_sha256=' "$manifest" | cut -d'=' -f2)"
  [ -n "$extractor_sha" ] || return 1
  [ -n "$recorded_extractor_sha" ] || return 1
  [ "$recorded_extractor_sha" = "$extractor_sha" ] || return 1

  names="$("$GREP_BIN" -E '^[0-9a-f]{64}  .+$' "$manifest" | sed -E 's/^[0-9a-f]{64}  //' | sort)"
  entries="$(_bootstrap_manifest_names | sort)"
  [ "$names" = "$entries" ] || return 1

  for f in $(_bootstrap_manifest_names); do
    [ -f "$dir/$f" ] || return 1
  done
  if ! ( cd "$dir" && sha256sum -c manifest.sha256 ) >/dev/null 2>&1; then
    return 1
  fi

  for f in develop-it-runtime.sh publish-status; do
    mode="$(stat -c %a "$dir/$f" 2>/dev/null)"
    [ "$mode" = 700 ] || return 1
  done
  for f in role-contracts.tsv policy.tsv events.tsv; do
    mode="$(stat -c %a "$dir/$f" 2>/dev/null)"
    [ "$mode" = 600 ] || return 1
  done
  return 0
}

# Materializes all five generated files into $1 (a fresh, empty staging
# directory) -- the runtime and publisher as verbatim atomic copies of
# $PROCESS_REPO_ROOT/runtime/{cookbook.sh,publish-status}, the three
# registries via this repository's own extractor -- honouring
# $BOOTSTRAP_FAIL_AFTER, and writes manifest.sha256 LAST -- only ever after
# all five files exist and are individually fsynced. Returns 0 on complete
# success; on interruption, returns 1 having written strictly fewer than five
# files and no manifest. EVERY failure path names itself via _bootstrap_die,
# and the failing step's own stderr (a missing runtime/ source file, an
# extractor traceback or SystemExit) rides along with the token instead of
# being buried in a discarded temp file.
_bootstrap_extract_all() {
  local tmp="$1" extractor raw written
  extractor="$PROCESS_REPO_ROOT/tests/lib/extract.py"
  raw="$tmp/.raw"
  written=0
  mkdir -p "$raw" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$raw"; return 1; }

  written=$((written + 1))
  _bootstrap_atomic_write "$tmp/develop-it-runtime.sh" 700 \
      2>"$raw/.err" < "$PROCESS_REPO_ROOT/runtime/cookbook.sh" \
    || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp/develop-it-runtime.sh" "$raw/.err"; return 1; }
  if [ -n "${BOOTSTRAP_FAIL_AFTER:-}" ] && [ "$written" -ge "$BOOTSTRAP_FAIL_AFTER" ]; then
    echo "BOOTSTRAP_INTERRUPTED:$written" >&2
    return 1
  fi

  written=$((written + 1))
  PROCESS_DOC="$PROCESS_PATH" BUILD="$raw" "$PYTHON_BIN" "$extractor" roles \
    >/dev/null 2>"$raw/.err" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$extractor" "$raw/.err"; return 1; }
  _bootstrap_atomic_write "$tmp/role-contracts.tsv" 600 < "$raw/roles.tsv" \
    || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp/role-contracts.tsv"; return 1; }
  if [ -n "${BOOTSTRAP_FAIL_AFTER:-}" ] && [ "$written" -ge "$BOOTSTRAP_FAIL_AFTER" ]; then
    echo "BOOTSTRAP_INTERRUPTED:$written" >&2
    return 1
  fi

  written=$((written + 1))
  PROCESS_DOC="$PROCESS_PATH" BUILD="$raw" "$PYTHON_BIN" "$extractor" policies \
    >/dev/null 2>"$raw/.err" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$extractor" "$raw/.err"; return 1; }
  _bootstrap_atomic_write "$tmp/policy.tsv" 600 < "$raw/policies.tsv" \
    || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp/policy.tsv"; return 1; }
  if [ -n "${BOOTSTRAP_FAIL_AFTER:-}" ] && [ "$written" -ge "$BOOTSTRAP_FAIL_AFTER" ]; then
    echo "BOOTSTRAP_INTERRUPTED:$written" >&2
    return 1
  fi

  written=$((written + 1))
  PROCESS_DOC="$PROCESS_PATH" BUILD="$raw" "$PYTHON_BIN" "$extractor" events \
    >/dev/null 2>"$raw/.err" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$extractor" "$raw/.err"; return 1; }
  _bootstrap_atomic_write "$tmp/events.tsv" 600 < "$raw/events.tsv" \
    || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp/events.tsv"; return 1; }
  if [ -n "${BOOTSTRAP_FAIL_AFTER:-}" ] && [ "$written" -ge "$BOOTSTRAP_FAIL_AFTER" ]; then
    echo "BOOTSTRAP_INTERRUPTED:$written" >&2
    return 1
  fi

  written=$((written + 1))
  _bootstrap_atomic_write "$tmp/publish-status" 700 \
      2>"$raw/.err" < "$PROCESS_REPO_ROOT/runtime/publish-status" \
    || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp/publish-status" "$raw/.err"; return 1; }
  if [ -n "${BOOTSTRAP_FAIL_AFTER:-}" ] && [ "$written" -ge "$BOOTSTRAP_FAIL_AFTER" ]; then
    echo "BOOTSTRAP_INTERRUPTED:$written" >&2
    return 1
  fi

  rm -rf "$raw"

  for f in develop-it-runtime.sh role-contracts.tsv policy.tsv events.tsv publish-status; do
    _bootstrap_fsync_path "$tmp/$f" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp/$f"; return 1; }
  done

  local manifest fileset_sha extractor_sha
  manifest="$tmp/manifest.sha256"
  fileset_sha="$(process_fileset_sha256)"
  extractor_sha="$(sha256sum "$extractor" | cut -d' ' -f1)"
  {
    printf 'process_fileset_sha256=%s\n' "$fileset_sha"
    printf 'extractor_sha256=%s\n' "$extractor_sha"
    ( cd "$tmp" && sha256sum develop-it-runtime.sh role-contracts.tsv policy.tsv events.tsv publish-status )
  } > "$manifest.part"
  _bootstrap_fsync_path "$manifest.part" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$manifest.part"; return 1; }
  mv "$manifest.part" "$manifest" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$manifest"; return 1; }
  _bootstrap_fsync_path "$manifest" || { _bootstrap_die "BOOTSTRAP_IO_ERROR:$manifest"; return 1; }
  return 0
}

# Publishes a complete, verified staging directory to $RUNTIME_DIR via
# renameat2(..., RENAME_NOREPLACE): a race MUST fail rather than merge. Then
# verifies the JUST-PUBLISHED runtime before ever reporting BOOTSTRAP_OK --
# spec 7.1(7) wants a corrupt publish surfaced at THIS Phase -1, not deferred
# to the NEXT phase's BOOTSTRAP_REUSED check. If another bootstrap already
# published first, validate ITS manifest before trusting it -- never overlay
# files into the winner.
_bootstrap_publish() {
  local tmp="$1"
  if _bootstrap_rename_noreplace "$tmp" "$RUNTIME_DIR"; then
    _bootstrap_fsync_path "$ORCHESTRATION_DIR"
    if _bootstrap_verify_manifest "$RUNTIME_DIR"; then
      echo BOOTSTRAP_OK
      return 0
    fi
    echo "RUNTIME_MANIFEST_INVALID:$RUNTIME_DIR" >&2
    return 1
  fi
  if [ ! -d "$RUNTIME_DIR" ]; then
    echo "BOOTSTRAP_IO_ERROR:$RUNTIME_DIR" >&2
    return 1
  fi
  if _bootstrap_verify_manifest "$RUNTIME_DIR"; then
    mv "$tmp" "$ORCHESTRATION_DIR/quarantine/$(basename "$tmp").$$.$RANDOM" \
      || echo "BOOTSTRAP_QUARANTINE_MV_FAILED:$tmp" >&2
    echo BOOTSTRAP_RACE_LOST_VALID
    return 0
  fi
  mv "$tmp" "$ORCHESTRATION_DIR/quarantine/$(basename "$tmp").$$.$RANDOM" \
    || echo "BOOTSTRAP_QUARANTINE_MV_FAILED:$tmp" >&2
  echo "BOOTSTRAP_RACE_LOST_INVALID:$RUNTIME_DIR" >&2
  return 1
}

# Quarantine every .runtime.tmp.* older than the freshness window. A RECENT
# staging directory may belong to a bootstrap racing us concurrently in this
# SAME feature folder; sweeping it out from under a live extraction would
# corrupt that attempt -- the renameat2(..., RENAME_NOREPLACE) publish step is
# what makes that race safe, and an unconditional sweep would defeat it by
# moving one side of the race away before it ever gets to publish. The
# directory's mtime is refreshed by each file the live extraction creates, so
# the effective window is "since the last file appeared", not "since start".
# A failed `stat` is treated as live: never sweeping is the fail-safe direction.
_bootstrap_sweep_orphans() {
  local quarantine="$1" orphan now orphan_age orphan_age_threshold
  orphan_age_threshold="${BOOTSTRAP_ORPHAN_AGE_SECONDS:-300}"
  now="$(date +%s)"
  for orphan in "$ORCHESTRATION_DIR"/.runtime.tmp.*; do
    [ -e "$orphan" ] || continue
    orphan_age=$(( now - $(stat -c %Y "$orphan" 2>/dev/null || echo "$now") ))
    [ "$orphan_age" -ge "$orphan_age_threshold" ] || continue
    mv "$orphan" "$quarantine/$(basename "$orphan").$$.$RANDOM" \
      || echo "BOOTSTRAP_QUARANTINE_MV_FAILED:$orphan" >&2
  done
}

bootstrap_runtime() {
  ORCHESTRATION_DIR="$FEATURE_FOLDER/.orchestration"
  RUNTIME_DIR="$ORCHESTRATION_DIR/runtime"
  local quarantine attempt tmp
  quarantine="$ORCHESTRATION_DIR/quarantine"

  mkdir -p "$ORCHESTRATION_DIR" "$quarantine"
  if [ $? -ne 0 ]; then
    _bootstrap_die "BOOTSTRAP_IO_ERROR:$ORCHESTRATION_DIR"
    return 1
  fi

  # 1. The final runtime already exists: reuse it if it verifies; a corrupt
  #    final runtime HALTs rather than being silently rebuilt over.
  if [ -d "$RUNTIME_DIR" ]; then
    if _bootstrap_verify_manifest "$RUNTIME_DIR"; then
      # Collect any stale orphan left by the interrupted attempt that preceded
      # this runtime. Without this, a crash-then-immediate-resume leaks its
      # staging directory forever: every later phase short-circuits here and
      # never reaches the sweep below.
      _bootstrap_sweep_orphans "$quarantine"
      echo BOOTSTRAP_REUSED
      return 0
    fi
    echo "RUNTIME_MANIFEST_INVALID:$RUNTIME_DIR" >&2
    return 1
  fi

  # 2. No final runtime yet: any .runtime.tmp.* OLDER than the freshness
  #    window is an orphan from an interrupted prior attempt -- quarantine
  #    it. A RECENT staging directory may instead belong to a bootstrap
  #    racing us concurrently in this SAME feature folder; sweeping it out
  #    from under a live extraction would corrupt that attempt -- the
  #    renameat2(..., RENAME_NOREPLACE) publish step is what makes that race
  #    safe, and an unconditional sweep here would defeat it by deleting one
  #    side of the race before it ever gets to publish. Same helper as the
  #    BOOTSTRAP_REUSED path above -- was hand-duplicated inline here, which
  #    also leaked orphan_age_threshold/now/orphan/orphan_age as globals
  #    (this function's own `local` declaration at its top never covered
  #    them, since they were never declared local in the duplicate).
  _bootstrap_sweep_orphans "$quarantine"

  # 3. Create a unique staging directory (mkdir already gives O_EXCL-equivalent
  #    directory-creation semantics) under umask 077.
  attempt="$$.$RANDOM.$RANDOM"
  tmp="$ORCHESTRATION_DIR/.runtime.tmp.$attempt"
  if ! ( umask 077; mkdir "$tmp" ); then
    _bootstrap_die "BOOTSTRAP_IO_ERROR:$tmp"
    return 1
  fi

  # 4. Extract every runtime file, validate, and write the manifest last.
  if ! _bootstrap_extract_all "$tmp"; then
    return 1
  fi
  _bootstrap_fsync_path "$tmp"

  # 5. Publish atomically, verify immediately, and classify a lost race by
  #    validating the winner.
  _bootstrap_publish "$tmp"
}

# Single source of truth for every per-role dispatch contract: one row in the
# Role Contract Registry table above, materialized into $ROLE_CONTRACTS_PATH
# (bootstrap_runtime writes $RUNTIME_DIR/role-contracts.tsv) as 16-column TSV.
# tests/check_04_table.sh asserts every role_* wrapper below agrees with the
# table for every row -- they cannot drift.
#
# Deliberately does NOT reject a duplicate role at extraction time (see
# extract.py's cmd_roles): this awk lookup is the one enforcement point for
# BOTH an unknown field (exit 42) and an unknown-or-duplicate role (exit 43).
# A role matched zero times and a role matched twice both fail closed the same
# way -- there is no safe way to guess which of two conflicting rows is right,
# and a role that does not exist at all must not silently resolve like one
# that does.
role_contract_field() {
  local role=$1 field=$2
  awk -F '\t' -v role="$role" -v field="$field" '
    # field_known is captured via the `in` operator (which never auto-vivifies
    # an array element) at NR==1, before anything reads col[field]. Reading
    # col[field] directly -- e.g. `value=$col[field]` for an unknown field --
    # DOES auto-vivify it, which would make a later `field in col` check in
    # END see it as present and silently mask an unknown field as count!=1
    # instead of exit-42. Guarding the read with `field_known &&` keeps that
    # read from ever running for an unknown field, and checking `!field_known`
    # first in END (before the exit-43 count check) keeps a `NR==1`-time
    # `exit` from being clobbered -- an `exit` inside a non-END rule still
    # runs END, and an unconditional exit there would override it.
    NR==1 {
      for (i=1; i<=NF; i++) col[$i]=i
      field_known = (field in col)
      next
    }
    field_known && $1==role { count++; value=$col[field] }
    END {
      if (!field_known) exit 42
      if (count != 1) exit 43
      print value
    }
  ' "$ROLE_CONTRACTS_PATH"
}

# Columns that may legitimately be empty (normalized from an em-dash in the
# table): `effort` for a claude role with no reasoning-effort knob, and
# `optional_inputs` for a role that takes none. Every other column resolving
# to an empty value is a process-definition bug, not a legal state.
_role_optional_cell() { case "$1" in effort|optional_inputs) return 0 ;; *) return 1 ;; esac; }

# The one function every role_* wrapper calls. Resolves $ROLE_CONTRACTS_PATH
# (falling back to $RUNTIME_DIR/role-contracts.tsv, mirroring policy_value's
# $RUNTIME_DIR fallback), maps role_contract_field's exit codes to the
# machine-readable tokens the recovery/render layer branches on, and rejects an
# empty required cell before it can be mistaken for "not set yet".
role_field() {
  local role=$1 field=$2 path value rc
  path="${ROLE_CONTRACTS_PATH:-${RUNTIME_DIR:+$RUNTIME_DIR/role-contracts.tsv}}"
  if [ -z "$path" ]; then
    echo "ROLE_REGISTRY_MISSING:unset" >&2; return 1
  fi
  if [ ! -r "$path" ]; then
    echo "ROLE_REGISTRY_MISSING:$path" >&2; return 1
  fi
  value="$(ROLE_CONTRACTS_PATH="$path" role_contract_field "$role" "$field")"; rc=$?
  case "$rc" in
    0) : ;;
    42) echo "ROLE_FIELD_UNKNOWN:$field" >&2; return 1 ;;
    43) echo "ROLE_UNKNOWN_OR_DUPLICATE:$role" >&2; return 1 ;;
    *)  echo "ROLE_LOOKUP_FAILED:$role.$field" >&2; return 1 ;;
  esac
  if [ -z "$value" ] && ! _role_optional_cell "$field"; then
    echo "ROLE_CONTRACT_EMPTY:$role.$field" >&2; return 1
  fi
  printf '%s\n' "$value"
}

# The complete §6.2 wrapper surface -- thin calls onto role_field/role_contract_field.
role_vendor()                  { role_field "$1" vendor; }
role_model()                   { role_field "$1" model; }
role_effort()                  { role_field "$1" effort; }
role_timeout()                 { role_field "$1" timeout_minutes; }
role_mutates()                 { role_field "$1" mutates; }
role_long_running()            { role_field "$1" long_running; }
role_may_spawn_children()      { role_field "$1" may_spawn_children; }
role_required_inputs()         { role_field "$1" required_inputs; }
role_optional_defaults()       { role_field "$1" optional_inputs; }
role_status_path()             { role_field "$1" status_template; }
role_outputs()                 { role_field "$1" outputs; }
role_verdicts()                 { role_field "$1" verdicts; }
role_required_status_fields()  { role_field "$1" required_status_fields; }
role_checkpoint_kind()          { role_field "$1" checkpoint_kind; }
role_phases()                   { role_field "$1" phases; }

# Every role key present in the registry, in table order. Reads the TSV rather
# than a hand-maintained list, so this can never drift from the table.
_role_keys() {
  local path
  path="${ROLE_CONTRACTS_PATH:-${RUNTIME_DIR:+$RUNTIME_DIR/role-contracts.tsv}}"
  [ -n "$path" ] && [ -r "$path" ] || return 1
  tail -n +2 "$path" | cut -f1
}

# Render the role->model map for injection into the context-discovery prompt.
# The dispatched session cannot call role_model, so the orchestrator formats it.
# Child-only roles (impl-worker) never receive a top-level dispatch and are
# excluded -- they have no place in a map keyed by dispatched role.
resolved_models_block() {
  local role
  for role in $(_role_keys); do
    [ "$(role_phases "$role" 2>/dev/null)" = child ] && continue
    printf '  %s: %s\n' "$role" "$(role_model "$role")"
  done
}

# Serializes the ATTEMPT-NUMBER-DERIVATION critical section below across
# concurrent orchestrator shells (e.g. two roles dispatched in parallel), AND
# (Task 8) every record_event append -- one mutex, every RUN_LOG.md writer.
#
# `ln TARGET LINKNAME` (hardlink creation), not `mkdir`, is the exclusive-
# creation primitive: `link(2)` is atomically all-or-nothing on POSIX by
# definition, whereas an actual concurrency measurement on this host's
# coreutils (uutils 0.8.0) showed `mkdir` losing that guarantee under real
# contention (8-way x 20 rounds: 71 total "winners", 15 rounds with more than
# one) -- silently breaking record_event's own monotonic-event_id promise,
# since two shells could both see their `mkdir` succeed for the same
# critical section. `ln` needs no dependency beyond GNU coreutils either (no
# `flock`, which is util-linux, not guaranteed by the supported-environment
# list) and is the SAME primitive acquire_write_lease already uses for its
# own exclusive creation, below.
_run_log_lock_acquire() {
  # Usage: _run_log_lock_acquire [LOCKFILE] -- defaults to the shared
  # RUN_LOG mutex every existing caller already relies on (record_event,
  # allocate_attempt, ...), none of which pass an argument, so their
  # behavior is byte-for-byte unchanged. checkpoint_append ("Checkpoint
  # contract" below) passes its OWN progress.jsonl's own lock path instead,
  # giving each checkpoint file a genuinely independent PER-FILE lock while
  # reusing this exact SAME `ln` primitive -- never a second locking
  # mechanism (spec S10.1's "per-file lock" and this document's own "use
  # the existing mutex, do not invent another" are the same requirement
  # once the lock file itself is parameterized, not two competing ones).
  local lockfile="${1:-${ORCHESTRATION_DIR:-$FEATURE_FOLDER/.orchestration}/log.lock}" tries=0 tmp lockdir
  lockdir="$(dirname "$lockfile")"
  mkdir -p "$lockdir"
  # $BASHPID, not $$: a `( ... ) &` subshell fork (dispatch_parallel's own
  # fan-out, or this file's own 8-way concurrency test) keeps $$ pointing at
  # the ORIGINAL shell, so every forked sibling would otherwise build the
  # SAME tmp name -- a real collision this exact concurrency test caught.
  # $BASHPID is the actual PID of the running shell and differs per fork.
  tmp="$lockdir/.$(basename "$lockfile").owner.$BASHPID.$RANDOM"
  printf '%s\n' "$$" > "$tmp" || { echo "RUN_LOG_LOCK_TMP_FAILED" >&2; return 1; }
  until ln "$tmp" "$lockfile" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 200 ]; then
      rm -f "$tmp"
      echo "RUN_LOG_LOCK_TIMEOUT" >&2
      return 1
    fi
    sleep 0.05
  done
  rm -f "$tmp"
}
_run_log_lock_release() {
  # Usage: _run_log_lock_release [LOCKFILE] -- same default as acquire.
  local lockfile="${1:-${ORCHESTRATION_DIR:-$FEATURE_FOLDER/.orchestration}/log.lock}"
  rm -f "$lockfile" 2>/dev/null || true
}

# Derives the next two-digit attempt monotonically from EVERY prior
# RUN_LOG.md record naming this logical dispatch -- never clock time, never
# PID. The caller (allocate_attempt) already holds the RUN_LOG writer lock,
# so this never races another allocation for the SAME logical dispatch.
next_unused_attempt() {
  # Usage: next_unused_attempt LOGICAL_DISPATCH_ID
  local logical=$1 max=0 n
  if [ -f "$FEATURE_FOLDER/RUN_LOG.md" ]; then
    while IFS= read -r n; do
      n=$((10#$n))
      [ "$n" -gt "$max" ] && max=$n
    done < <("$GREP_BIN" -oE "^dispatch_id:[[:space:]]+${logical}-a[0-9]{2}\$" \
                "$FEATURE_FOLDER/RUN_LOG.md" 2>/dev/null \
              | "$GREP_BIN" -oE '[0-9]{2}$')
  fi
  # Attempt identity is fixed two-digit by design (spec S8.1: dispatch_id =
  # logical_dispatch_id-a<NN>). A 100th attempt cannot be represented -- and,
  # worse, silently STOPS matching the grep above (which requires exactly two
  # trailing digits), which would reset this scan back to 0 and collide with
  # the existing a99 directory on the next allocate_attempt call. Unreachable
  # under the current policy caps (continuation_cap=3, prelaunch/publication/
  # transient retry caps=1, review_iteration_cap=10) -- guard it explicitly
  # rather than leaving the two-digit assumption implicit.
  if [ "$max" -ge 99 ]; then
    echo "ATTEMPT_OVERFLOW:$logical" >&2
    return 1
  fi
  printf '%d\n' $((max + 1))
}

# Phase<->token mapping, shared by allocate_attempt (forward) and
# role_attempt_dir (inverse) so the two directions can never drift apart.
# Token domain: `m1` for the reserved preflight phase -1, else a zero-padded
# two-digit decimal.
_phase_to_token() {
  # Usage: _phase_to_token PHASE
  local phase="$1"
  if [ "$phase" = -1 ]; then printf m1; else printf '%02d' "$phase"; fi
}
_token_to_phase() {
  # Usage: _token_to_phase TOKEN
  local token="$1"
  if [ "$token" = m1 ]; then printf -- '-1'; else printf '%d' "$((10#$token))"; fi
}

# Rebuilds the attempt directory purely from the dispatch id's own
# p<token>-i<NN>-... prefix (plus $FEATURE_FOLDER) -- never from a separate
# global, so it can never drift from the identity allocate_attempt just
# minted. The role argument is a real existence check (an unknown role fails
# closed here rather than silently building a path for it).
role_attempt_dir() {
  # Usage: role_attempt_dir ROLE DISPATCH_ID
  local role=$1 dispatch_id=$2 token iter phase phase_name
  role_phases "$role" >/dev/null 2>&1 \
    || { echo "ATTEMPT_DIR_UNKNOWN_ROLE:$role" >&2; return 1; }
  token="$(printf '%s\n' "$dispatch_id" | "$GREP_BIN" -oE '^p[^-]+' | cut -c2-)"
  iter="$(printf '%s\n' "$dispatch_id" | "$GREP_BIN" -oE -- '-i[0-9]{2}-' | head -1 | tr -d 'i-')"
  [ -n "$token" ] && [ -n "$iter" ] \
    || { echo "ATTEMPT_DIR_BAD_DISPATCH_ID:$dispatch_id" >&2; return 1; }
  phase="$(_token_to_phase "$token")"
  phase_name="$(_phase_name "$phase")" || return 1
  printf '%s/%s-%s/%s/attempts/%s\n' \
    "$FEATURE_FOLDER" "$phase" "$phase_name" "$iter" "$dispatch_id"
}

# P21 (Task 11): the per-phase preflight's alias-copy step (each of Phase
# 3/5/7's own Step X.0 item 5) was an identical ~20-line snippet five times
# over, differing only in the phase number and destination directory. One
# function, called once per gate.
copy_preflight_alias() {
  # Usage: copy_preflight_alias PHASE DEST_DIR
  # `cp`, never `mv` -- the attempt-scoped original at $src remains the
  # durable record (resume classification, audit_run_state, and a future
  # reconciliation all expect every attempt directory to remain exactly as
  # dispatch_attempt left it). `_latest_attempt_id` returning nothing (codex
  # skipped via consent, or a prelaunch failure that never launched) is the
  # normal non-error case -- `continue` to the next vendor, not a HALT. An
  # `if [ -f "$src" ]`, not `[ -f … ] && cp`: as the LAST statement of a
  # block the `&&` form returns 1 whenever the file is absent, which is the
  # normal codex-skipped path, making a successful phase look like a
  # failure. Either copy is a no-op if its source is absent (see "File
  # policy for non-READY paths"); order of the two copies is irrelevant.
  local phase="$1" dest="$2" v logical latest src
  for v in claude codex; do
    logical="p$(_phase_to_token "$phase")-i00-preflight-${v}"
    latest="$(_latest_attempt_id "$logical" 2>/dev/null)" || continue
    src="$(role_attempt_dir "preflight-${v}" "$latest")/STATUS.md"
    if [ -f "$src" ]; then
      cp "$src" "$dest/${v}-check-status.md"
    fi
  done
}

# The ONE place a top-level dispatch identity is minted. Sets (non-local,
# caller-visible): PHASE_TOKEN LOGICAL_DISPATCH_ID ATTEMPT DISPATCH_ID
# ATTEMPT_DIR STATUS_PATH STDOUT_PATH STDERR_PATH SNAPSHOT_DIR -- exactly
# these nine; nothing else, including $ITERATION itself, is touched. A
# prelaunch failure still consumes its allocated attempt: this function
# always appends an event=ATTEMPT_ALLOCATED record with `launched: false`
# BEFORE returning, and only a later DISPATCH_STARTED/DISPATCH_COMPLETED pair
# (written by _dispatch_ingest_result) is evidence the attempt actually
# launched -- so an attempt that never gets
# that far stays correctly recorded as `launched: false` forever.
allocate_attempt() {
  # Usage: allocate_attempt PHASE ITERATION ROLE
  # `-1` is accepted here (and by `_legal_phase_token`) purely as a reserved
  # alias for the literal phase argument every REAL preflight dispatch
  # actually passes: `1` (matching the "1-preflight/" folder every consumer
  # in this document already reads from -- context7_policy, optional-skill
  # routing, readiness-writer, the folder-layout diagram). No role's own
  # registry `phases` column ever lists `-1` (preflight-claude/preflight-codex
  # list `1;3;5;6;7`), so the `m1` token below is defined for completeness,
  # never actually minted by a real dispatch; a `pm1-...` dispatch id
  # correctly does not appear anywhere else in this document.
  local phase=$1 iteration=$2 role=$3 iter2 rc=0
  PHASE_TOKEN="$(_phase_to_token "$phase")"
  LOGICAL_DISPATCH_ID="p${PHASE_TOKEN}-i$(printf '%02d' "$iteration")-$role"
  iter2="$(printf '%02d' "$iteration")"

  mkdir -p "$ORCHESTRATION_DIR"
  _run_log_lock_acquire || return 1

  ATTEMPT="$(next_unused_attempt "$LOGICAL_DISPATCH_ID")" \
    || { _run_log_lock_release; return 1; }
  DISPATCH_ID="$LOGICAL_DISPATCH_ID-a$(printf '%02d' "$ATTEMPT")"

  ATTEMPT_DIR="$(role_attempt_dir "$role" "$DISPATCH_ID")" \
    || { rc=$?; _run_log_lock_release; return "$rc"; }
  mkdir -p "$(dirname "$ATTEMPT_DIR")"
  # Plain `mkdir` (no -p) on the leaf: this is the collision-safety backstop
  # -- an attempt directory is NEVER reused or overwritten. If the RUN_LOG
  # scan above and this mkdir ever disagree, that is a bug, and failing
  # loudly here is strictly safer than silently merging into an existing
  # attempt's files.
  if ! mkdir "$ATTEMPT_DIR" 2>/dev/null; then
    echo "ATTEMPT_DIR_COLLISION:$ATTEMPT_DIR" >&2
    _run_log_lock_release
    return 1
  fi
  # Release BEFORE record_event: record_event takes the SAME log.lock
  # itself (it is the canonical writer now, see "RUN_LOG events, decisions,
  # write leases, and snapshots" below) -- holding it here too would
  # deadlock a single-threaded shell against its own already-held lock
  # (non-reentrant). The attempt-number/attempt-directory critical section
  # above is what actually needed this lock; the RUN_LOG append below gets
  # its own fresh, independently-serialized acquisition.
  #
  # Code review note (fix #9, accepted as a latent gap, not fixed): this
  # DOES shrink the critical section. next_unused_attempt (above) derives
  # the next attempt number by scanning RUN_LOG.md for this logical
  # dispatch's OWN prior entries -- but with the lock released here, before
  # record_event durably writes THIS attempt's own ATTEMPT_ALLOCATED entry,
  # a second concurrent allocate_attempt call for the SAME logical dispatch
  # could acquire the lock in that gap, scan RUN_LOG.md, see no entry yet
  # for attempt 1, and also compute attempt=1 -- its own `mkdir
  # "$ATTEMPT_DIR"` backstop then hard-fails ATTEMPT_DIR_COLLISION instead
  # of correctly landing on attempt 2. Latent today (two roles are never
  # allocated under the SAME logical dispatch id concurrently in this
  # document's actual call graph), not exercised by any test; a future
  # caller that does share a logical dispatch across concurrent shells
  # would need the ATTEMPT_ALLOCATED write folded back inside this
  # function's own lock hold, not left to record_event's separate one.
  _run_log_lock_release

  record_event ATTEMPT_ALLOCATED dispatch_id="$DISPATCH_ID" \
    logical_dispatch_id="$LOGICAL_DISPATCH_ID" phase="$phase" iteration="$iter2" \
    role="$role" attempt="$ATTEMPT" launched=false \
    reason="attempt identity allocated" || return 1

  # shellcheck disable=SC2034  # consumed by the caller after allocate_attempt returns
  STATUS_PATH="$ATTEMPT_DIR/STATUS.md"
  # shellcheck disable=SC2034  # consumed by the caller after allocate_attempt returns
  STDOUT_PATH="$FEATURE_FOLDER/transcripts/$DISPATCH_ID.stdout"
  # shellcheck disable=SC2034  # consumed by the caller after allocate_attempt returns
  STDERR_PATH="$FEATURE_FOLDER/transcripts/$DISPATCH_ID.stderr"
  # shellcheck disable=SC2034  # consumed by the caller after allocate_attempt returns
  SNAPSHOT_DIR="$ORCHESTRATION_DIR/snapshots/$DISPATCH_ID"
}

# Extract one appendix and substitute orchestration variables into it.
# `sed` is NOT an alternative: multi-line values such as $RELEVANT_ARTIFACTS break
# it, and path values collide with any delimiter chosen.
# Every variable any appendix may reference. Declared by render_keys() rather
# than a top-level assignment, because the cookbook must be definitions-only:
# check_01_lint.sh sources it in a pristine shell and fails on any variable it
# sets. tests/check_03_varcoverage.sh asserts this list covers every $VAR used in
# every appendix body, and render_prompt passes exactly this list to python3.
render_keys() {
  printf '%s\n' FEATURE_FOLDER ITERATION SPEC_PATH PLAN_PATH FINDINGS_PATHS \
    IMPLEMENTATION_BASE_SHA IMPLEMENTATION_SUMMARY_PATH DEBUGGER_STATUS_PATH \
    REPO_ROOT ROUND TEST_REPORT_PATH RESOLVED_MODELS CONTEXT7_POLICY GREP_BIN \
    ACCEPTED_PLAN REVIEWED_REVISION FINDING_IDS WRITE_LEASE RUN_LOG \
    RELEVANT_ARTIFACTS FINAL_DIFF ACCEPTED_SPEC IMPLEMENTATION_SUMMARY \
    SEAM_FILES \
    TEST_SUMMARY REVIEW_SUMMARY DECISIONS EXCLUSIONS FOLLOWUPS DOCS_INVENTORY \
    PHASE PHASE_DIR DISPATCH_ID LOGICAL_DISPATCH_ID ATTEMPT ROLE_CONTRACTS_PATH \
    STATUS_PUBLISHER_PATH CONTINUATION_PATH DECLARED_FOREIGN_CHANGES RUNTIME_DIR \
    MODE CONTINUATION_PRIOR_CLASSIFICATION \
    APPLICABLE_OPTIONAL_SKILLS
}

# The process DOCUMENT SET for appendix/shared-block discovery (P00 stage 2):
# the core document first, then every phase pack ($PROCESS_PATH's own sibling
# phases/*.md) in LC_ALL=C sorted order -- deterministic, no role->file
# registry. A repo with no phases/ directory (a test fixture) yields the
# one-file set, so single-file callers keep working unchanged.
_process_docs() {
  printf '%s\n' "$PROCESS_PATH"
  local d f
  d="$(dirname "$PROCESS_PATH")/phases"
  [ -d "$d" ] || return 0
  for f in "$d"/*.md; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done | LC_ALL=C sort
}

render_prompt() {
  # Usage: render_prompt <appendix-name>
  #        render_prompt --check <role>   -- see render_prompt_check below.
  if [ "${1:-}" = "--check" ]; then
    shift
    render_prompt_check "$@"
    return $?
  fi
  local appendix="$1" k
  local set_keys=() envargs=()

  # Pass values EXPLICITLY. Orchestration variables are ordinary shell
  # assignments, not exports, so python3 would see none of them via os.environ —
  # the prompt would render with every $VAR intact and the subagent would be told
  # to read a file called literally "$SPEC_PATH".
  #
  # `${!k+x}` distinguishes "set but empty" from "unset", which the prefix form
  # alone cannot: an unset variable would arrive as an empty string and silently
  # substitute nothing.
  for k in $(render_keys); do
    if [ -n "${!k+x}" ]; then
      set_keys+=("$k")
      envargs+=("$k=${!k}")
    fi
  done

  env APPENDIX="$appendix" PROCESS_FILES="$(_process_docs)" \
      SET_KEYS="${set_keys[*]}" ${envargs[@]+"${envargs[@]}"} \
      "$PYTHON_BIN" - <<'PY'
import os
import re
import shlex
import sys

name = os.environ["APPENDIX"]

# The document SET (P00 stage 2): core document first, then the LC_ALL=C
# sorted phase packs -- assembled by _process_docs in the calling shell. A
# marker found in MORE THAN ONE file is a process-definition defect and
# fails loudly; the first (and only) file carrying it wins deterministically.
files = [f for f in os.environ["PROCESS_FILES"].split("\n") if f]
texts = [(f, open(f).read()) for f in files]


def find_span(begin_marker, end_marker, what):
    hits = [(f, t) for f, t in texts if begin_marker in t]
    if not hits:
        return None, None
    if len(hits) > 1:
        sys.exit(f"render_prompt: duplicate marker for {what} across process files: "
                 + ", ".join(f for f, _ in hits))
    f, t = hits[0]
    start = t.find(begin_marker)
    # Search for the END marker AFTER start -- searching from 0 could match an
    # earlier appendix's END and silently truncate or invert the body.
    end = t.find(end_marker, start)
    if end == -1:
        sys.exit(f"render_prompt: BEGIN without END for {what} in {f}")
    return f, t[start:end + len(end_marker)]


src, body = find_span(f"<!-- BEGIN: {name} -->", f"<!-- END: {name} -->",
                      f"appendix '{name}'")
if body is None:
    sys.exit(f"render_prompt: no BEGIN marker for appendix '{name}' in {' '.join(files)}")

# P20 (Task 11): appendices reference document-wide-shared prose (the
# Publish STATUS protocol, the summarizer usage-table spec, the finding-
# record field schema) instead of repeating it 25/5/6 times over. Those
# shared blocks live ONCE, outside any role's own BEGIN/END span, delimited
# by <!-- SHARED-BEGIN: <block> -->/<!-- SHARED-END: <block> -->. An
# appendix pulls one in with a single
#   <!-- INCLUDE-BEGIN: <block> key="value" ... -->
#   ...optional extra lines (become {{extra}})...
#   <!-- INCLUDE-END -->
# span; expansion happens HERE, before the plain $VAR substitution below, so
# a dispatched role's RENDERED prompt still gets the full shared text (only
# the document's OWN resident bytes shrink) and any $VAR the shared block
# itself carries (e.g. $STATUS_PUBLISHER_PATH) is still resolved normally.
_include_re = re.compile(
    r"<!-- INCLUDE-BEGIN: ([a-z][a-z0-9_-]*)([^\n]*) -->\n(.*?)<!-- INCLUDE-END -->",
    re.S,
)


def _expand_include(m):
    block, argstr, extra = m.group(1), m.group(2), m.group(3)
    s_begin, s_end = f"<!-- SHARED-BEGIN: {block} -->", f"<!-- SHARED-END: {block} -->"
    # Shared blocks are authored in the CORE document, but discovery scans the
    # same whole document set as appendix discovery (duplicates fail loudly).
    _, span = find_span(s_begin, s_end, f"shared block '{block}'")
    if span is None:
        sys.exit(f"render_prompt: appendix '{name}' includes unknown shared block '{block}'")
    shared = span[len(s_begin):-len(s_end)].strip("\n")
    try:
        params = dict(tok.split("=", 1) for tok in shlex.split(argstr))
    except ValueError:
        sys.exit(f"render_prompt: malformed INCLUDE params in appendix '{name}': {argstr!r}")
    params.setdefault("extra", extra.rstrip("\n"))
    out = shared
    for k, v in params.items():
        out = out.replace("{{" + k + "}}", v)
    leftover_params = sorted(set(re.findall(r"\{\{[a-z_]+\}\}", out)))
    if leftover_params:
        sys.exit(
            f"render_prompt: shared block '{block}' left unresolved in appendix '{name}': "
            + ", ".join(leftover_params)
        )
    return out


body = _include_re.sub(_expand_include, body)

# Only the keys the CALLER actually had set. The shell computed this list with
# ${!k+x}, so "set but empty" is honoured and "unset" is detectable here.
set_keys = os.environ.get("SET_KEYS", "").split()

# Longest name first, and a trailing boundary assertion, so a short name can
# never partially replace a longer one (e.g. $ITERATION vs $ITERATION_CAP).
for key in sorted(set_keys, key=len, reverse=True):
    value = os.environ.get(key, "")
    body = re.sub(rf"\${key}(?![A-Za-z0-9_])", value.replace("\\", "\\\\"), body)

# FAIL LOUDLY on anything left unresolved. A prompt containing a literal
# "$SPEC_PATH" tells the subagent to read a file by that name; it will either
# error confusingly or, worse, proceed against the wrong input. This is the
# check that turns "the orchestrator forgot to set $PLAN_PATH" from a silent
# wrong-input bug into an immediate, named failure.
leftover = sorted(set(re.findall(r"\$([A-Z][A-Z0-9_]{2,})", body)))
if leftover:
    sys.exit(
        f"render_prompt: appendix '{name}' references unset variable(s): "
        + ", ".join("$" + v for v in leftover)
        + f"\n  set keys were: {' '.join(sorted(set_keys)) or '(none)'}"
    )

print(body)
PY
}

# A role's `phases` cell is a semicolon-delimited set of legal phase tokens.
# `child` is legal only for a child-only contract (e.g. impl-worker); every
# other legal token is -1 (the preflight/canary stage) or 1 through 11
# (readiness-writer, Phase 11, is the current highest).
_legal_phase_token() {
  case "$1" in
    -1|1|2|3|4|5|6|7|8|9|10|11|child) return 0 ;;
    *) return 1 ;;
  esac
}

# `render_prompt --check <role>` reports, without spending a single token:
#   - every required input that is not currently set (RENDER_REQUIRED_INPUT_MISSING),
#   - every populated optional default (KEY=default),
#   - the resolved output/STATUS paths,
#   - an unsupported phase token in the registry row (ROLE_PHASE_UNSUPPORTED),
#   - any appendix variable that still cannot resolve (RENDER_VARIABLE_UNRESOLVED).
# Returns 0 iff none of the above problems were found. A role lookup failure
# (unknown role, unknown field) propagates role_field's own token unchanged.
render_prompt_check() {
  local role="$1" problems=0 phases p req tok var opt val

  phases="$(role_phases "$role")" || return 1
  for p in $(printf '%s' "$phases" | tr ';' ' '); do
    if ! _legal_phase_token "$p"; then
      echo "ROLE_PHASE_UNSUPPORTED:$p" >&2
      problems=1
    fi
  done

  req="$(role_required_inputs "$role")" || return 1
  for tok in $(printf '%s' "$req" | tr ';' ' '); do
    var="$(printf '%s' "$tok" | tr '[:lower:]' '[:upper:]')"
    if [ -z "${!var+x}" ]; then
      echo "RENDER_REQUIRED_INPUT_MISSING:$tok" >&2
      problems=1
    fi
  done

  opt="$(role_optional_defaults "$role")" || return 1
  if [ "$opt" != none ] && [ -n "$opt" ]; then
    for tok in $(printf '%s' "$opt" | tr ';' ' '); do
      case "$tok" in *=*) var="${tok%%=*}"; val="${tok#*=}" ;; *) var="$tok"; val="" ;; esac
      var="$(printf '%s' "$var" | tr '[:lower:]' '[:upper:]')"
      [ -n "${!var+x}" ] || echo "optional default: $var=$val"
    done
  fi

  # Resolve the status_template against the orchestration variables THIS
  # shell currently has set, and print the RESOLVED path -- spec 6.2 requires
  # a resolved output/STATUS path, not the literal template text. An attempt
  # identity variable the template names but this shell has not set yet is
  # reported as RENDER_VARIABLE_UNRESOLVED, the same token an unresolved
  # appendix variable gets below, rather than silently echoing "$PHASE_DIR".
  local template resolved leftover v
  template="$(role_status_path "$role")"
  if [ "$template" = none ]; then
    echo "status_template: none"
  else
    resolved="$template"
    for v in PHASE_DIR ITERATION DISPATCH_ID; do
      [ -n "${!v+x}" ] && resolved="${resolved//\$$v/${!v}}"
    done
    leftover="$("$GREP_BIN" -oE '\$[A-Z][A-Z0-9_]{2,}' <<< "$resolved" | tr -d '$' | sort -u | paste -sd, -)"
    if [ -n "$leftover" ]; then
      echo "RENDER_VARIABLE_UNRESOLVED:$leftover" >&2
      problems=1
    else
      echo "status_template: $resolved"
    fi
  fi
  echo "outputs: $(role_outputs "$role")"

  # A child-only role (phases=child, e.g. impl-worker) has no appendix to
  # render -- appendix_exists correctly returns 1 for it, and there is nothing
  # further to check here.
  if [ "$phases" != child ]; then
    local out
    out="$(render_prompt "$role" 2>&1 1>/dev/null)"
    if [ $? -ne 0 ]; then
      local unresolved
      unresolved="$("$GREP_BIN" -oE '\$[A-Z][A-Z0-9_]{2,}' <<< "$out" | tr -d '$' | sort -u | paste -sd, -)"
      echo "RENDER_VARIABLE_UNRESOLVED:${unresolved:-$out}" >&2
      problems=1
    fi
  fi

  [ "$problems" -eq 0 ]
}

# Reserved invoke_vendor prelaunch exit codes -- never a real vendor exit code
# (vendor CLIs exit small codes like 0-2 normally; `timeout`'s own reserved
# codes are 124/137). A future record_event call (Task 8) branches on these
# to classify DISPATCH_NOT_LAUNCHED (95/96) vs a run-scoped VENDOR_UNAVAILABLE
# (97) before ever reaching classify_attempt's ordinary vendor-exit-code path:
#   95  unknown vendor, or a role/field lookup failure (INVOKE_VENDOR_ROLE_LOOKUP_FAILED / INVOKE_VENDOR_UNKNOWN_VENDOR)
#   96  a prelaunch input/registry defect (INVOKE_VENDOR_PROMPT_MISSING /
#       INVOKE_VENDOR_BAD_TIMEOUT / INVOKE_VENDOR_BAD_REPO_ROOT / a field lookup failure)
#   97  VENDOR_HEADROOM_REFUSED -- the spend/quota probe below refused (or could not prove liveness)
# Each return site keeps its own echo token; grep for the token, not the number.

# The single source for the 5b spend/quota-ceiling signature vocabulary
# (Failure handling table below and this file's own comments call it "5b
# ceiling"). Both `_vendor_headroom_probe`'s probe-refusal check and
# `classify_attempt`'s substantive-dispatch check must recognise the SAME
# words -- they were previously two hand-duplicated copies of this literal,
# which could silently drift apart.
_spend_ceiling_pattern() {
  printf '%s' 'spend limit|monthly spend|usage limit reached|credit balance is too low|billing|quota exceeded|contact your organization administrator|insufficient_quota'
}

# The timeout/background/negative-PID-kill dance every vendor subprocess site
# below needs -- factored out of what used to be four hand-duplicated copies
# (the probe and the substantive launch, times claude and codex). Backgrounds
# `timeout --kill-after=KILL_AFTER DEADLINE CMD...`, `wait`s for it, and then
# sends exactly one SIGKILL to the whole process group by negative PID as a
# post-mortem sweep -- never STOP/CONT/TERM, and never while the wrapper is
# still live: this fires strictly AFTER `wait` returns, so it can never be
# mistaken for extending a live deadline. This host's `timeout` (uutils
# coreutils) leaves a grandchild the monitored process itself forked alive
# after a --kill-after escalation, even though all three processes share one
# process group -- confirmed empirically on this host, not assumed from
# either implementation's docs. GNU coreutils' own `cleanup()` signals the
# whole group, so this gap may not reproduce there; the sweep is unconditional
# defense-in-depth regardless of which `timeout` is on PATH, and is a
# harmless no-op when nothing survives.
#
# CD_DIR, when non-empty, is `cd`'d into first -- failing with the same
# INVOKE_VENDOR_BAD_REPO_ROOT/exit-96 shape every claude call site needs
# (codex passes CD_DIR empty; it takes `-C` itself instead). Any NAME=VALUE
# arguments before the mandatory `--` are `export`ed into the subshell first,
# reproducing each call site's own command-scoped env-var prefix exactly
# (a bash builtin, so no extra process enters the timeout->CMD chain). CMD's
# stdin is whatever this function's own stdin already is -- callers redirect
# at the call site (`< file` or `<<< "text"`), exactly like every original
# call site redirected its own inline `timeout` invocation.
_launch_vendor_subprocess() {
  # Usage: _launch_vendor_subprocess CD_DIR KILL_AFTER DEADLINE OUT ERR [NAME=VALUE]... -- CMD...
  local cd_dir="$1" kill_after="$2" deadline="$3" out="$4" err="$5"
  shift 5
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  local tpid trc kv
  ( if [ -n "$cd_dir" ]; then
      cd "$cd_dir" || { echo "INVOKE_VENDOR_BAD_REPO_ROOT:$cd_dir" >&2; exit 96; }
    fi
    # shellcheck disable=SC2163  # intentional: $kv IS the "NAME=VALUE" pair
    for kv in ${envs[@]+"${envs[@]}"}; do export "$kv"; done
    timeout --kill-after="$kill_after" "$deadline" "$@" \
      1> "$out" 2> "$err" &
    tpid=$!
    wait "$tpid"; trc=$?
    kill -KILL -- "-$tpid" 2>/dev/null
    exit "$trc"
  )
  return $?
}

# One minimal, cheap liveness call proving the vendor CLI currently responds
# and is not mid a spend/quota refusal. This is the ONLY vendor spend before
# the registry timeout/spend gates below. It proves ONLY current liveness --
# it MUST NOT be read as proof enough budget remains to finish the role (spec
# S12.4), and it never runs when the role's timeout is below the policy
# threshold. Any non-zero probe exit (missing binary, the probe's own 30s
# timeout, a 5xx) is ALSO refused -- an inconclusive probe proves nothing, so
# it is treated the same as an explicit spend/quota refusal, never as "OK".
_vendor_headroom_probe() {
  # Usage: _vendor_headroom_probe <role> <vendor> <attempt_out> <attempt_err>
  # <attempt_out>/<attempt_err> are the SUBSTANTIVE attempt's own stdout/stderr
  # paths (invoke_vendor's $out/$err) -- used only to derive sibling paths to
  # persist the probe's own transcript. A future run-scoped VENDOR_UNAVAILABLE
  # event (Task 6/8) needs that transcript as evidence, so it is never deleted
  # here; the CALLER (invoke_vendor) owns cleanup once that event is recorded.
  local role="$1" vendor="$2" attempt_out="$3" attempt_err="$4"
  local probe_out="${attempt_out}.headroom-probe" probe_err="${attempt_err}.headroom-probe"
  local model effort rc
  : > "$probe_out"; : > "$probe_err"
  model="$(role_contract_field "$role" model)" || return 1
  case "$vendor" in
    claude)
      _launch_vendor_subprocess "$REPO_ROOT" 10s 30s "$probe_out" "$probe_err" \
        CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 -- \
        claude --model "$model" -p --output-format=json \
               --dangerously-skip-permissions - \
        <<< "ping"
      rc=$?
      ;;
    codex)
      effort="$(role_contract_field "$role" effort)" || return 1
      _launch_vendor_subprocess "" 10s 30s "$probe_out" "$probe_err" \
        -- \
        codex -a never -m "$model" -c model_reasoning_effort="$effort" \
          exec -C "$REPO_ROOT" -s workspace-write --skip-git-repo-check --json - \
        <<< "ping"
      rc=$?
      ;;
    *) return 1 ;;
  esac
  # A non-zero probe (missing binary, the probe's own timeout, a transport
  # error) is not proof of liveness -- refuse, same as an explicit signature.
  [ "$rc" -eq 0 ] || return 1
  # Same 5b ceiling vocabulary as "Mode 5 has two shapes" in Failure handling
  # below -- a probe refusal and a substantive-dispatch ceiling are the same
  # account-level condition, so they must be recognised by the same words.
  if "$GREP_BIN" -qiE \
      "$(_spend_ceiling_pattern)" \
      "$probe_out" "$probe_err" 2>/dev/null
  then
    return 1
  fi
  return 0
}

# The single registry-driven launch point. Rejects an unknown vendor BEFORE
# any subprocess launches (a PRELAUNCH_FAILED-shaped defect, never a vendor
# outage). Applies the registry timeout with `timeout --kill-after`, via the
# SAME `_launch_vendor_subprocess` helper the headroom probe above uses --
# see its own comment for the --kill-after process-group dance this reuses.
invoke_vendor() {
  # Usage: invoke_vendor <role> <prompt_file> <stdout_path> <stderr_path>
  # EXTRA_VENDOR_ARGS (optional, ambient, claude-only): a bash array the
  # caller may set before invoking, same pattern as DISPATCH_ID/STATUS_PATH
  # above -- not a 5th positional argument, because this signature is fixed
  # across the whole implementation (Interfaces Used Across Tasks). Its one
  # consumer is Phase 6's --agents sub-subagent model pin.
  local role="$1" prompt_file="$2" out="$3" err="$4"
  local vendor model timeout_minutes threshold long_running grace deadline rc

  vendor="$(role_contract_field "$role" vendor)" \
    || { echo "INVOKE_VENDOR_ROLE_LOOKUP_FAILED:$role" >&2; return 95; }
  case "$vendor" in
    claude|codex) : ;;
    *) echo "INVOKE_VENDOR_UNKNOWN_VENDOR:$role:$vendor" >&2; return 95 ;;
  esac

  # Task 13 review fix (finding 10): may_spawn_children was a registry column
  # no dispatch code ever READ. EXTRA_VENDOR_ARGS is the ONE mechanism that
  # actually spawns children (the --agents sub-subagent model pin, Phase 6's
  # own dispatch snippet) -- gate its use here, at invoke_vendor's own single
  # choke point, on the dispatching role's own registry declaration, rather
  # than trusting every future caller to remember the rule.
  # declare -p first, under set -u: ${#EXTRA_VENDOR_ARGS[@]} itself throws
  # "unbound variable" for a TRULY unset array (unlike a scalar's ${x:-}),
  # so the length check must be short-circuited behind an existence probe
  # that never references the array's expansion directly.
  if declare -p EXTRA_VENDOR_ARGS >/dev/null 2>&1 && [ "${#EXTRA_VENDOR_ARGS[@]}" -gt 0 ]; then
    [ "$(role_may_spawn_children "$role" 2>/dev/null)" = yes ] \
      || { echo "INVOKE_VENDOR_SPAWN_NOT_AUTHORIZED:$role" >&2; return 95; }
  fi

  [ -n "$prompt_file" ] && [ -r "$prompt_file" ] \
    || { echo "INVOKE_VENDOR_PROMPT_MISSING:$prompt_file" >&2; return 96; }

  model="$(role_contract_field "$role" model)"                     || return 96
  timeout_minutes="$(role_contract_field "$role" timeout_minutes)" || return 96

  # A non-numeric or non-positive registry cell must fail LOUDLY here, not
  # coerce to 0 in the awk comparison below and silently skip the paid
  # headroom gate (the exact "silently defaulting" policy_value's own doc
  # comment forbids) -- and not reach `timeout` as a garbage "${x}m" deadline.
  # Checked BEFORE any policy_value lookup: this is a defect in THIS role's
  # own registry row, and must be diagnosed as such even when $RUNTIME_DIR/
  # policy.tsv is not yet available (e.g. a unit test with no bootstrap).
  # Same expression as tests/check_04_table.sh: a bare character-class test
  # accepts "1.2.3", which awk then reads as 1.2 -- spending a paid probe
  # before `timeout` rejects the interval.
  if ! printf '%s' "$timeout_minutes" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    echo "INVOKE_VENDOR_BAD_TIMEOUT:$role:$timeout_minutes" >&2
    return 96
  fi
  if ! awk -v t="$timeout_minutes" 'BEGIN{exit !(t+0 > 0)}'; then
    echo "INVOKE_VENDOR_BAD_TIMEOUT:$role:$timeout_minutes" >&2
    return 96
  fi

  long_running="$(role_contract_field "$role" long_running)"       || return 96
  threshold="$(policy_value long_role_headroom_threshold_minutes)" || return 96

  # Gate on the registry's OWN long_running classification (Step 4) in
  # addition to the direct timeout/threshold comparison: long_running=yes also
  # covers phases=child and may_spawn_children=yes (spec: "long_running is
  # materialized, not hand-picked"), two cases a bare timeout>=threshold
  # compare would miss. This is a pure OR -- it can only make the gate fire in
  # MORE cases, never fewer, so a role that already qualifies via timeout
  # keeps qualifying regardless of what a hand-built test registry's
  # long_running cell says.
  #
  # NOTE: this gate is deliberately BROADER than spec 12.4's literal wording
  # ("a role whose timeout_minutes is at least the threshold"). In the current
  # registry the two are identical -- every long_running=yes role is >=60 and
  # no role is yes below it -- so the OR spends nothing extra today. It only
  # bites a future sub-threshold role that spawns children, and for exactly
  # that role a paid liveness probe is the right answer, since 12.2's concern
  # is child-spawning roles. If such a role is added, the 59/60 boundary test
  # in check_07 must be re-pointed at a role that is still long_running=no.
  if [ "$long_running" = yes ] \
     || awk -v t="$timeout_minutes" -v th="$threshold" 'BEGIN{exit !(t+0 >= th+0)}'; then
    if ! _vendor_headroom_probe "$role" "$vendor" "$out" "$err"; then
      echo "VENDOR_HEADROOM_REFUSED:$role:$vendor" >&2
      return 97
    fi
  fi

  grace=60s
  deadline="${timeout_minutes}m"

  # DISPATCH_ID/LOGICAL_DISPATCH_ID/ATTEMPT are ordinary (unexported) shell
  # variables everywhere else in this document -- render_prompt depends on
  # exactly that to catch an unresolved $VAR. Exporting them on the line below
  # is scoped to this ONE command (the vendor subprocess) only, never to this
  # function's own shell or its caller, so it cannot mask that defect class.
  case "$vendor" in
    claude)
      _launch_vendor_subprocess "$REPO_ROOT" "$grace" "$deadline" "$out" "$err" \
        DISPATCH_ID="${DISPATCH_ID:-}" LOGICAL_DISPATCH_ID="${LOGICAL_DISPATCH_ID:-}" \
        ATTEMPT="${ATTEMPT:-}" STATUS_PATH="${STATUS_PATH:-}" REPO_ROOT="${REPO_ROOT:-}" \
        CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 -- \
        claude --model "$model" -p --output-format=json \
               --dangerously-skip-permissions \
               ${EXTRA_VENDOR_ARGS[@]+"${EXTRA_VENDOR_ARGS[@]}"} - \
        < "$prompt_file"
      rc=$?
      ;;
    codex)
      local effort add_dir=()
      effort="$(role_contract_field "$role" effort)" || return 96
      [ -n "${FEATURE_FOLDER_OUTSIDE_REPO:-}" ] && add_dir=(--add-dir "$FEATURE_FOLDER")
      # REPO_ROOT is passed through as an exported NAME=VALUE below purely for
      # the forked vendor subprocess's own environment (the fake CLI's
      # FAKE_MUTATION side effect -- see tests/fakebin/codex); `-C "$REPO_ROOT"`
      # in the command itself resolves identically either way.
      _launch_vendor_subprocess "" "$grace" "$deadline" "$out" "$err" \
        DISPATCH_ID="${DISPATCH_ID:-}" LOGICAL_DISPATCH_ID="${LOGICAL_DISPATCH_ID:-}" \
        ATTEMPT="${ATTEMPT:-}" STATUS_PATH="${STATUS_PATH:-}" REPO_ROOT="${REPO_ROOT:-}" -- \
        codex -a never -m "$model" -c model_reasoning_effort="$effort" \
          exec -C "$REPO_ROOT" -s workspace-write --skip-git-repo-check --json \
          ${add_dir[@]+"${add_dir[@]}"} - \
        < "$prompt_file"
      rc=$?
      ;;
  esac
  return "$rc"
}

appendix_exists() {
  # Usage: appendix_exists <role>
  # Scans the whole document set (core + phase packs, see _process_docs).
  # A marker duplicated across files is a process-definition defect: fail
  # loudly rather than let render_prompt's own duplicate check fire later.
  local role="$1" begins
  local -a docs
  mapfile -t docs < <(_process_docs)
  begins="$("$GREP_BIN" -lF -- "<!-- BEGIN: ${role} -->" "${docs[@]}" 2>/dev/null | wc -l)"
  if [ "$begins" -gt 1 ]; then
    echo "appendix_exists: duplicate BEGIN marker for '${role}' across process files" >&2
    return 1
  fi
  [ "$begins" -eq 1 ] || return 1
  "$GREP_BIN" -qF -- "<!-- END: ${role} -->" "${docs[@]}" 2>/dev/null || return 1
  return 0
}

# Canonical phase_name lookup, mirroring the phase_name table in the
# Resumability section exactly (tests/check_04_table.sh does not enforce this
# one; keep the two in sync by hand if the table ever changes). -1 is the
# pre-Phase-1 canary/model-probe stage: it is written as the ASCII hyphen
# "-1" in `phase:` fields even though section headings render it with the
# Unicode minus sign (U+2212), and it shares Phase 1's name.
_phase_name() {
  # Usage: _phase_name <phase>
  case "$1" in
    -1|1) echo preflight ;;
    2)    echo context-discovery ;;
    3)    echo spec-review ;;
    4)    echo plan-writing ;;
    5)    echo plan-review ;;
    6)    echo implementation ;;
    7)    echo code-review ;;
    8)    echo all-tests ;;
    9)    echo documentation ;;
    10)   echo git-finalization ;;
    11)   echo readiness-report ;;
    *)    echo "unknown phase: $1" >&2; return 1 ;;
  esac
}

# ---- Exclusive write lease -------------------------------------------------
# The real write-lease protocol (write-lease.json, snapshot manifest,
# staleness/ambiguous-owner reconciliation, cross-owner authority checks --
# spec S11) is defined in full under "Write leases and mutation snapshots"
# below (`acquire_write_lease`/`release_write_lease`/`_write_lease_state`).
# It replaces this section's original Task 6/7 provisional mkdir-mutex seam
# (`_dispatch_lease_try_acquire`/`_dispatch_lease_release`/`_dispatch_lease_
# state`) wholesale; nothing in this document still calls those three names.

# ---- Attempt-scoped result record (child -> parent handoff) ----------------
# A plain sanitized key=value file, one line per field (never RUN_LOG.md
# grammar — this is a private handoff file under the attempt's own directory,
# read by nobody but _dispatch_ingest_result/_dispatch_ingest_child).
_dispatch_write_result() {
  # Usage: _dispatch_write_result <dir> key=value [key=value ...]
  local dir="$1"; shift
  local kv
  mkdir -p "$dir"
  {
    for kv in "$@"; do
      printf '%s=%s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | tr '\t\n' '  ')"
    done
  } > "$dir/result.kv"
}
_dispatch_read_result_field() {
  # Usage: _dispatch_read_result_field <result.kv path> <key>
  local file="$1" key="$2" line
  line="$("$GREP_BIN" -m1 "^${key}=" "$file" 2>/dev/null)" || return 1
  printf '%s\n' "${line#*=}"
}

# Phase 1: allocate the attempt, validate every non-lease precondition, and
# render + persist the prompt. Called once per role, sequentially, from
# dispatch_parallel's own shell — BEFORE any lease is taken or any child
# forked (see the section intro above for why). Sets (caller-visible):
# PREP_OK (1 ready to launch, 0 rejected — result.kv is already written on
# rejection), PREP_PHASE_NAME, PREP_VENDOR, PREP_MUTATES, PREP_DISPATCH_ID,
# PREP_LOGICAL, PREP_ATTEMPT, PREP_ATTEMPT_DIR, PREP_STATUS_PATH,
# PREP_STDOUT_PATH, PREP_STDERR_PATH, PREP_PROMPT_FILE.
_dispatch_prelaunch() {
  # Usage: _dispatch_prelaunch <phase> <iteration> <role>
  local phase="$1" iteration="$2" role="$3"
  local phase_name reject="" vendor="" mutates=""
  local dispatch_id logical attempt attempt_dir status_path stdout_path stderr_path
  # Reset EVERY PREP_* field up front, unconditionally: a caller (dispatch_
  # parallel) reads PREP_ATTEMPT_DIR regardless of this call's return value,
  # to know where to find (or synthesize) this role's result -- an early
  # return below (bad phase, allocate_attempt failure) must never leave a
  # STALE value here from some earlier role's successful call, or ingestion
  # would read and misreport THAT role's already-written result instead.
  PREP_OK=0
  PREP_PHASE_NAME=""; PREP_VENDOR=""; PREP_MUTATES=""
  PREP_DISPATCH_ID=""; PREP_LOGICAL=""; PREP_ATTEMPT=""; PREP_ATTEMPT_DIR=""
  PREP_STATUS_PATH=""; PREP_STDOUT_PATH=""; PREP_STDERR_PATH=""; PREP_PROMPT_FILE=""

  phase_name="$(_phase_name "$phase")" || { echo "DISPATCH_ATTEMPT_BAD_PHASE:$phase" >&2; return 1; }
  # shellcheck disable=SC2034  # consumed by dispatch_parallel after this call returns
  PREP_PHASE_NAME="$phase_name"

  allocate_attempt "$phase" "$iteration" "$role" \
    || { echo "DISPATCH_ATTEMPT_ALLOCATE_FAILED:$role" >&2; return 1; }
  dispatch_id="$DISPATCH_ID"; logical="$LOGICAL_DISPATCH_ID"; attempt="$ATTEMPT"
  attempt_dir="$ATTEMPT_DIR"; status_path="$STATUS_PATH"
  stdout_path="$STDOUT_PATH"; stderr_path="$STDERR_PATH"
  PREP_DISPATCH_ID="$dispatch_id"; PREP_LOGICAL="$logical"; PREP_ATTEMPT="$attempt"
  PREP_ATTEMPT_DIR="$attempt_dir"; PREP_STATUS_PATH="$status_path"
  PREP_STDOUT_PATH="$stdout_path"; PREP_STDERR_PATH="$stderr_path"

  # Render-time identity every appendix/status-template resolution needs,
  # derived entirely from what this call just minted — callers no longer
  # hand-set $PHASE_DIR/$ITERATION/$DISPATCH_ID themselves.
  # PHASE is the raw phase argument itself (e.g. "1" or "3") -- needed ONLY
  # by a role dispatched under more than one phase number (today, only
  # preflight-claude (re-probed at Phases 1, 3, 5, 6, 7) and preflight-codex
  # (re-probed at Phases 1, 3, 5, 7 -- P09 dropped its Phase 6 dispatch):
  # its appendix cannot hardcode a single literal --phase value the way
  # every single-phase role's appendix does.
  # shellcheck disable=SC2034  # consumed by render_prompt via render_keys()
  PHASE="$phase"
  # shellcheck disable=SC2034  # consumed by render_prompt via render_keys()
  PHASE_DIR="$FEATURE_FOLDER/$phase-$phase_name"
  # shellcheck disable=SC2034  # consumed by render_prompt via render_keys()
  ITERATION="$(printf '%02d' "$iteration")"
  DISPATCH_ID="$dispatch_id"; LOGICAL_DISPATCH_ID="$logical"; ATTEMPT="$(printf '%02d' "$attempt")"

  # ---- "validate inputs and budget" (the control-flow line in the plan):
  # budget has two existing enforcement points, not a third redundant check
  # invented here -- the attempt-number ceiling is allocate_attempt's own
  # ATTEMPT_OVERFLOW guard (next_unused_attempt, above), and the timeout/spend
  # budget is invoke_vendor's registry timeout validation plus its headroom
  # probe (spec S12.4), both already run on every launch.
  # ---- validate vendor invocation, CWD, context7 policy, phase applicability
  vendor="$(role_vendor "$role" 2>/dev/null)" || reject="DISPATCH_ROLE_LOOKUP_FAILED"
  case "$vendor" in claude|codex) : ;; *) reject="${reject:-DISPATCH_UNKNOWN_VENDOR}" ;; esac
  [ -d "${REPO_ROOT:-}" ] || reject="${reject:-DISPATCH_BAD_REPO_ROOT}"
  [ -n "${CONTEXT7_POLICY+x}" ] || reject="${reject:-DISPATCH_CONTEXT7_POLICY_UNSET}"
  case ";$(role_phases "$role" 2>/dev/null);" in
    *";$phase;"*) : ;;
    *) reject="${reject:-DISPATCH_PHASE_NOT_APPLICABLE}" ;;
  esac

  # Task 13: any role whose OWN contract declares `mode` as a required input
  # (today, only `implementer`) must be dispatched with an EXPLICIT
  # $MODE=A|B|D -- never inferred here, never left to guess. Any other value,
  # including unset, is rejected before a single token is spent. This is what
  # makes "Mode C" unrepresentable: there is no fourth legal value to select it.
  case ";$(role_required_inputs "$role" 2>/dev/null);" in
    *";mode;"*)
      case "${MODE:-}" in
        A|B|D) : ;;
        *) reject="${reject:-DISPATCH_INVALID_MODE}" ;;
      esac
      ;;
  esac

  # Task 13: $FINDING_IDS names the review-repair scope (spec S17.3/S18.4) --
  # only a role whose OWN contract declares finding_ids (today: spec-fixer,
  # plan-fixer, implementation-fixer) may ever consume it. A role dispatched
  # while FINDING_IDS is set but its contract never declared it -- most
  # notably the plain `implementer` -- is asked to repair a code-review
  # finding outside its own role, which is a scope violation, not a missing-
  # input defect. This also catches an ambient $FINDING_IDS leaking forward
  # from an earlier Phase 7 dispatch into a later, unrelated one.
  if [ -n "${FINDING_IDS:-}" ]; then
    case ";$(role_required_inputs "$role" 2>/dev/null);" in
      *";finding_ids;"*) : ;;
      *) reject="${reject:-ROLE_SCOPE_VIOLATION}" ;;
    esac
  fi

  render_prompt --check "$role" >/dev/null 2>"$attempt_dir/render-check.err" \
    || reject="${reject:-DISPATCH_RENDER_CHECK_FAILED}"

  # `role_mutates` resolves this from the registry's `mutates` column. An
  # unrecognized role or a corrupt/empty cell is a registry defect, not a
  # guessed "yes"/"no": unknown or unresolved mutation state defaults to
  # REJECTION, never to mutation guessing (registry rule, §6.1) — silently
  # coercing it to "no" would skip the write lease for a role that actually
  # mutates.
  mutates="$(role_mutates "$role" 2>/dev/null)" || reject="${reject:-DISPATCH_MUTATES_LOOKUP_FAILED}"
  case "$mutates" in yes|no) : ;; *) reject="${reject:-DISPATCH_MUTATES_LOOKUP_FAILED}" ;; esac
  PREP_VENDOR="${vendor:-unknown}"
  PREP_MUTATES="$mutates"

  # ---- render fully in memory; write the immutable prompt file. Process
  # substitution must not be used here: `cmd < <(render_prompt ...)` discards
  # the renderer's exit status entirely — verified, a renderer returning 42
  # still ran the consumer with zero bytes and yielded rc 0. That would send
  # an EMPTY prompt to a real model and bill for it. Render into a variable,
  # check it, THEN write it.
  if [ -z "$reject" ]; then
    local prompt
    prompt="$(render_prompt "$role")" || reject=DISPATCH_RENDER_FAILED
    if [ -z "$reject" ] && [ -z "$prompt" ]; then reject=DISPATCH_RENDER_EMPTY; fi
    if [ -z "$reject" ]; then
      printf '%s' "$prompt" > "$attempt_dir/prompt.txt"
      chmod 400 "$attempt_dir/prompt.txt" 2>/dev/null || true
    fi
  fi
  PREP_PROMPT_FILE="$attempt_dir/prompt.txt"

  if [ -n "$reject" ]; then
    _dispatch_write_result "$attempt_dir" launched=no phase="$phase" phase_name="$phase_name" \
      iteration="$iteration" role="$role" vendor="${vendor:-unknown}" dispatch_id="$dispatch_id" \
      logical_dispatch_id="$logical" attempt="$attempt" status_path="$status_path" \
      classification=PRELAUNCH_FAILED reason="$reject" verdict="" usage_line="" \
      start_ms=0 end_ms=0 wall_ms=0 exit_code="" stdout_path="$stdout_path" \
      stderr_path="$stderr_path" mutates="${mutates:-no}" mutation_state=NO_SIDE_EFFECTS
    return 1
  fi

  # shellcheck disable=SC2034  # consumed by dispatch_parallel after this call returns
  PREP_OK=1
  return 0
}

# Writes the DISPATCH_STARTED record. Called ONLY from _dispatch_launch_attempt,
# immediately before invoke_vendor — this is what makes the timestamp real: it
# is the actual moment the attempt is about to spend, not a timestamp invented
# later once some other code happens to get around to it. May run inside a
# forked child (dispatch_parallel's fan-out); serialized against every
# sibling, and against allocate_attempt's own ATTEMPT_ALLOCATED write, through
# the same log.lock mutex — see the section intro above for why this
# does not violate "the parent orchestrator is the sole writer of RUN_LOG.md".
_dispatch_write_started() {
  # Usage: _dispatch_write_started <phase> <phase_name> <iteration> <role> \
  #        <vendor> <dispatch_id> <logical_dispatch_id> <status_path> <lease_ref>
  local phase="$1" phase_name="$2" iteration="$3" role="$4" vendor="$5"
  local dispatch_id="$6" logical="$7" status_path="$8" lease_ref="$9"
  # A real snapshot manifest exists ONLY for a mutating attempt (acquire_
  # write_lease's own "before" capture, keyed by this exact dispatch_id --
  # see "Write leases and mutation snapshots" below); a non-mutating role
  # never acquires a lease, so it never gets one either, and "none" here is
  # an honest value, not a placeholder pending later work.
  local snapshot_ref=none
  [ "${lease_ref:-none}" != none ] \
    && snapshot_ref="$ORCHESTRATION_DIR/snapshots/$dispatch_id/manifest.json"
  record_event DISPATCH_STARTED \
    phase="$phase" iteration="$(printf '%02d' "$iteration")" dispatch_id="$dispatch_id" \
    reason="vendor invocation starting" \
    phase_name="$phase_name" role="$role" vendor="$vendor" logical_dispatch_id="$logical" \
    model="$(role_model "$role" 2>/dev/null)" status_path="$status_path" \
    cwd="${REPO_ROOT:-}" lease="${lease_ref:-none}" snapshot="$snapshot_ref"
}

# Phase 3: invoke, time, classify, and record ONE role that already passed
# _dispatch_prelaunch (and, for a mutating role, already holds the lease).
# Usage: _dispatch_launch_attempt <index> — reads the per-role arrays
# dispatch_parallel just populated (roles/dp_attempt_dir/dp_dispatch_id/dp_logical/
# dp_attempt/dp_status_path/dp_stdout_path/dp_stderr_path/dp_vendor/dp_mutates/dp_prompt_file),
# plus its phase/iteration/phase_name. This is always invoked as
# "( _dispatch_launch_attempt "$i" ) &" from INSIDE dispatch_parallel's own
# body, so bash's dynamic scoping for `local` makes every one of those
# arrays visible here with no extra plumbing — the fork is a copy of the
# same shell, arrays included.
_dispatch_launch_attempt() {
  local i="$1"
  local role="${roles[$i]}" a_dir="${dp_attempt_dir[$i]}" d_id="${dp_dispatch_id[$i]}"
  local logi="${dp_logical[$i]}" att="${dp_attempt[$i]}" s_path="${dp_status_path[$i]}"
  local out_path="${dp_stdout_path[$i]}" err_path="${dp_stderr_path[$i]}"
  local vend="${dp_vendor[$i]}" mut="${dp_mutates[$i]}" p_file="${dp_prompt_file[$i]}"
  local lease_ref=none
  [ "$mut" = yes ] && lease_ref="$ORCHESTRATION_DIR/write-lease.json"

  # invoke_vendor forwards these AMBIENT (unexported) globals into the
  # vendor subprocess's environment -- it does not take them as arguments.
  # Each forked _dispatch_launch_attempt call sets its own copy fresh; the
  # per-role prelaunch loop in dispatch_parallel runs sequentially and
  # overwrites these same globals for every role in turn, so by the time
  # THIS fork actually runs, they must be (re)set from this role's own
  # dp_* arrays, never trusted to still hold what prelaunch last left there.
  DISPATCH_ID="$d_id"; LOGICAL_DISPATCH_ID="$logi"; ATTEMPT="$(printf '%02d' "$att")"
  STATUS_PATH="$s_path"

  # inspect_mutation_state's own minimal pre-attempt snapshot (Task 7 seam):
  # just enough (the pre-attempt HEAD sha, read back from $MUTATION_SNAPSHOT_DIR/
  # pre-head) to tell HEAD-moved from tree-dirty from comparison-impossible
  # once the attempt finishes. The real snapshot MANIFEST (owned-artifact
  # list, checkpoint ledger, cross-owner authority — spec S8/S11) stays
  # Task 8's job; this captures nothing beyond what RM04-RM08/RM11 need.
  MUTATION_SNAPSHOT_DIR="$a_dir"
  git -C "${REPO_ROOT:-}" rev-parse HEAD > "$a_dir/pre-head" 2>/dev/null \
    || printf 'none\n' > "$a_dir/pre-head"

  _dispatch_write_started "$phase" "$phase_name" "$iteration" "$role" "$vend" \
    "$d_id" "$logi" "$s_path" "$lease_ref"

  mkdir -p "$(dirname "$out_path")"
  local start_ms end_ms wall_ms vrc classification reason verdict="" usage_line mutation_state
  start_ms="$(now_ms)"
  run_timed invoke_vendor "$role" "$p_file" "$out_path" "$err_path"
  vrc="$DISPATCH_RC"
  wall_ms="$DISPATCH_WALL_MS"
  end_ms="$(now_ms)"

  usage_line="$(parse_usage "$vend" "$out_path" "$wall_ms" "$(role_model "$role" 2>/dev/null)")"
  [ -f "$s_path" ] && verdict="$(status_field "$s_path" verdict 2>/dev/null)"

  classify_attempt "$role" "$vrc" "$out_path" "$err_path" "$s_path"
  classification="$CLASSIFY_ATTEMPT_RESULT"; reason="$CLASSIFY_ATTEMPT_REASON"
  mutation_state="$(inspect_mutation_state "$role")"

  # Authority enforcement (spec S11.1's "unexpected changes yield ARTIFACT_
  # INTEGRITY_BLOCKED"): INTEGRITY_UNKNOWN covers BOTH a read-only role that
  # left evidence of a change while holding no lease at all, and a mutating
  # attempt whose own pre/post comparison became impossible -- either way,
  # this is the one non-terminal signal that must never pass silently.
  if [ "$mutation_state" = INTEGRITY_UNKNOWN ]; then
    record_event ARTIFACT_INTEGRITY_BLOCKED lease_owner="$role" dispatch_id="$d_id" \
      phase="$phase" iteration="$(printf '%02d' "$iteration")" \
      reason="unexplained repository change (mutation_state=INTEGRITY_UNKNOWN)" \
      >/dev/null 2>&1 || true
  fi

  post_dispatch "$vrc" "$s_path" "$err_path" "$out_path" \
    >>"$a_dir/post-dispatch.log" 2>&1 || :

  # Step 3 order: write the attempt result BEFORE releasing the lease --
  # release is the very last thing an attempt does, once its outcome is
  # already durable.
  _dispatch_write_result "$a_dir" launched=yes phase="$phase" phase_name="$phase_name" \
    iteration="$iteration" role="$role" vendor="$vend" dispatch_id="$d_id" \
    logical_dispatch_id="$logi" attempt="$att" status_path="$s_path" \
    classification="$classification" reason="$reason" verdict="$verdict" usage_line="$usage_line" \
    start_ms="$start_ms" end_ms="$end_ms" wall_ms="$wall_ms" exit_code="$vrc" \
    stdout_path="$out_path" stderr_path="$err_path" mutates="$mut" \
    mutation_state="$mutation_state"

  # release_write_lease removes only an EXACT valid owner match and captures
  # the "after" snapshot -- see "Write leases and mutation snapshots" above.
  [ "$mut" = yes ] && release_write_lease "$role"

  [ "$classification" = COMPLETED ]
}

# The ONLY code that appends DISPATCH_COMPLETED / DISPATCH_NOT_LAUNCHED /
# ATTEMPT_FAILED to RUN_LOG.md (DISPATCH_STARTED is _dispatch_write_started's
# job, above, run earlier by whichever process actually launches the
# attempt). Always runs in the parent, strictly after every forked PID has
# been `wait`ed — never from inside a child.
_dispatch_ingest_result() {
  # Usage: _dispatch_ingest_result <result.kv path>
  local rf="$1" k
  local launched="" phase="" phase_name="" iteration="" role="" vendor="" dispatch_id=""
  local logical_dispatch_id="" attempt="" status_path="" classification="" reason=""
  local verdict="" usage_line="" start_ms="" end_ms="" wall_ms="" mutates=""
  local exit_code="" stdout_path="" stderr_path="" mutation_state=""
  for k in launched phase phase_name iteration role vendor dispatch_id logical_dispatch_id \
           attempt status_path classification reason verdict usage_line start_ms end_ms wall_ms \
           mutates exit_code stdout_path stderr_path mutation_state; do
    printf -v "$k" '%s' "$(_dispatch_read_result_field "$rf" "$k" 2>/dev/null)"
  done

  # A malformed record (an unrecognized classification, most likely a
  # corrupted or hand-edited result file) still gets exactly ONE ingested
  # record -- never a crash, never a silently dropped role. The full ten-row
  # ordered-classifier vocabulary (spec S14.1, `classify_attempt`) is legal
  # here, not just the four Task 6 originally distinguished.
  case "$classification" in
    COMPLETED|TIMED_OUT|PRELAUNCH_FAILED|EXITED_NO_STATUS|MALFORMED_STATUS|UNKNOWN_VENDOR_ERROR| \
    SPEND_CEILING|PERMANENT_VENDOR_ERROR|TRANSIENT_TRANSPORT_ERROR|PUBLICATION_LOST) : ;;
    *)
      reason="DISPATCH_RESULT_MALFORMED:${classification:-empty}"
      classification=UNKNOWN_VENDOR_ERROR ;;
  esac

  # mutation_state is read straight from the child's own result.kv (computed
  # by _dispatch_launch_attempt via inspect_mutation_state, Task 7) -- a
  # missing/empty value (an older or synthesized record that predates this
  # field, e.g. a hand-built result.kv in a test, or _dispatch_ingest_child's
  # synthesized lost-result record) safely defaults to NO_SIDE_EFFECTS, never
  # a guessed dirty/checkpointed state.
  [ -n "$mutation_state" ] || mutation_state=NO_SIDE_EFFECTS
  local checkpoint_kind
  checkpoint_kind="$(role_checkpoint_kind "$role" 2>/dev/null)"

  if [ "$launched" != yes ]; then
    record_event DISPATCH_NOT_LAUNCHED \
      phase="$phase" iteration="$(printf '%02d' "${iteration:-0}" 2>/dev/null || echo "$iteration")" \
      dispatch_id="$dispatch_id" reason="$reason" \
      phase_name="$phase_name" role="$role" logical_dispatch_id="$logical_dispatch_id" \
      || return 1
    DISPATCH_RESULT_CLASSIFICATION=PRELAUNCH_FAILED
    DISPATCH_RESULT_VERDICT=""
    DISPATCH_RESULT_REASON="$reason"
    DISPATCH_RESULT_STATUS_PATH="$status_path"
    DISPATCH_RESULT_MUTATION_STATE=NO_SIDE_EFFECTS
    return 1
  fi

  # parse_usage's nine usage-telemetry fields (model/duration_ms are already
  # carried above by their own named fields; the remaining seven are pulled
  # out by NAME here rather than passed through as an opaque tail, so
  # record_event's declared-fields-only validation covers them too).
  local usage_status_v="" tokens_input_new_v=0 tokens_input_cached_v=0 tokens_cache_write_v=0
  local tokens_output_v=0 tokens_reasoning_v=0 cost_usd_v="n/a"
  local kv kk vv
  for kv in $usage_line; do
    kk="${kv%%=*}"; vv="${kv#*=}"
    case "$kk" in
      usage_status)         usage_status_v="$vv" ;;
      tokens_input_new)     tokens_input_new_v="$vv" ;;
      tokens_input_cached)  tokens_input_cached_v="$vv" ;;
      tokens_cache_write)   tokens_cache_write_v="$vv" ;;
      tokens_output)        tokens_output_v="$vv" ;;
      tokens_reasoning)     tokens_reasoning_v="$vv" ;;
      cost_usd)             cost_usd_v="$vv" ;;
    esac
  done

  record_event DISPATCH_COMPLETED \
    phase="$phase" iteration="$(printf '%02d' "$iteration")" dispatch_id="$dispatch_id" \
    reason="attempt classified: $classification" \
    phase_name="$phase_name" role="$role" vendor="$vendor" appendix="$role" \
    logical_dispatch_id="$logical_dispatch_id" \
    develop_it_git_sha="${PROCESS_GIT_HEAD:-non-git}" \
    develop_it_file_sha256="${PROCESS_FILE_SHA256:-}" develop_it_dirty="${PROCESS_DIRTY:-unknown}" \
    status_path="$status_path" verdict="$verdict" classification="$classification" \
    exit_code="$exit_code" model="$(role_model "$role" 2>/dev/null)" \
    start_ms="$start_ms" end_ms="$end_ms" duration_ms="$wall_ms" \
    stdout_path="$stdout_path" stderr_path="$stderr_path" mutation_state="$mutation_state" \
    checkpoint_kind="$checkpoint_kind" \
    tokens_input_new="$tokens_input_new_v" tokens_input_cached="$tokens_input_cached_v" \
    tokens_cache_write="$tokens_cache_write_v" tokens_output="$tokens_output_v" \
    tokens_reasoning="$tokens_reasoning_v" cost_usd="$cost_usd_v" usage_status="$usage_status_v" \
    || return 1

  if [ "$classification" != COMPLETED ]; then
    record_event ATTEMPT_FAILED \
      phase="$phase" iteration="$(printf '%02d' "$iteration")" dispatch_id="$dispatch_id" \
      reason="$reason" phase_name="$phase_name" role="$role" classification="$classification" \
      || return 1
  elif [ "$role" != preflight-claude ] && [ "$role" != preflight-codex ]; then
    # spec S16.3: a SUBSTANTIVE dispatch (anything beyond the cheap preflight
    # probes, which mark vendor_proven separately and more conservatively at
    # Phase 1 Step 1.1 item 8) that completes successfully proves its vendor
    # for the rest of the run. See "Evidence-based capability: vendor_proven"
    # above for the read side and the three signatures that CAN revoke it.
    vendor_proven_mark "$vendor" "$role" "$dispatch_id" || return 1
  fi

  DISPATCH_RESULT_CLASSIFICATION="$classification"
  DISPATCH_RESULT_VERDICT="$verdict"
  DISPATCH_RESULT_REASON="$reason"
  DISPATCH_RESULT_STATUS_PATH="$status_path"
  DISPATCH_RESULT_MUTATION_STATE="$mutation_state"
  [ "$classification" = COMPLETED ]
}

# Ingest one child's outcome, synthesizing a PRELAUNCH_FAILED record ONLY
# when the child never even reached a durable DISPATCH_STARTED -- dispatch_
# parallel calls this once per requested role, so the parent ALWAYS emits
# exactly one ingested record per role, never a silently missing one.
_dispatch_ingest_child() {
  # Usage: _dispatch_ingest_child <phase> <iteration> <role> <attempt-dir-or-empty>
  local phase="$1" iteration="$2" role="$3" attempt_dir="$4"
  if [ -z "$attempt_dir" ] || [ ! -f "$attempt_dir/result.kv" ]; then
    # A child whose DISPATCH_STARTED is already durable (its attempt dir's
    # basename IS its dispatch_id) and then produced no result was genuinely
    # launched and then lost -- an orphan, not a prelaunch failure. Writing a
    # synthetic DISPATCH_NOT_LAUNCHED here would directly contradict the
    # DISPATCH_STARTED already on disk. Leave it alone for Task 7's
    # classify_attempt/resume to turn into DISPATCH_ORPHANED.
    local maybe_id=""
    [ -n "$attempt_dir" ] && maybe_id="$(basename "$attempt_dir" 2>/dev/null)"
    if [ -n "$maybe_id" ] && dispatch_is_running "$maybe_id"; then
      # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
      DISPATCH_RESULT_CLASSIFICATION=ORPHANED_NO_RESULT
      # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
      DISPATCH_RESULT_VERDICT=""
      # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
      DISPATCH_RESULT_REASON=DISPATCH_PARALLEL_CHILD_DIED_AFTER_START
      # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
      DISPATCH_RESULT_STATUS_PATH=""
      # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
      # INTEGRITY_UNKNOWN, not the bare word UNKNOWN -- that IS one of the
      # five spec S14.2 mutation states (recovery_action's own vocabulary);
      # a value outside that vocabulary makes recovery_action return
      # unmapped for this orphan (Task 7 review finding #10).
      DISPATCH_RESULT_MUTATION_STATE=INTEGRITY_UNKNOWN
      return 1
    fi
    local synth="$attempt_dir"
    if [ -n "$synth" ]; then
      mkdir -p "$synth" 2>/dev/null
    else
      # Contained under $ORCHESTRATION_DIR, never system /tmp -- this is a
      # rare defensive fallback (a real attempt_dir is always known by the
      # time ingestion runs), not a per-call leak into shared temp space.
      synth="$(mktemp -d "${ORCHESTRATION_DIR:-${TMPDIR:-/tmp}}/lost-result.XXXXXX")"
    fi
    _dispatch_write_result "$synth" launched=no phase="$phase" \
      phase_name="$(_phase_name "$phase" 2>/dev/null)" iteration="$iteration" role="$role" \
      vendor=unknown dispatch_id="" logical_dispatch_id="" attempt="" status_path="" \
      classification=PRELAUNCH_FAILED reason=DISPATCH_PARALLEL_MISSING_RESULT \
      verdict="" usage_line="" start_ms=0 end_ms=0 wall_ms=0 exit_code="" stdout_path="" \
      stderr_path="" mutates=no mutation_state=NO_SIDE_EFFECTS
    attempt_dir="$synth"
  fi
  _dispatch_ingest_result "$attempt_dir/result.kv"
}

# The only launcher. Renders, validates, dispatches, classifies, and records
# exactly one role. Internally this is dispatch_parallel with one role -- see
# the section intro above for why that is not a redundant second lifecycle.
dispatch_attempt() {
  # Usage: dispatch_attempt <phase> <iteration> <role>
  dispatch_parallel "$1" "$2" "$3"
}

# Fan-out. See the section intro above for the three phases (prelaunch / lease
# / launch) and why each is scoped the way it is. group_wall_ms is
# max(end) - min(start) across the roles that actually launched, never a
# sum; a role that never launched contributes no start/end and is excluded
# from that computation entirely.
dispatch_parallel() {
  # Usage: dispatch_parallel <phase> <iteration> <role> [<role> ...]
  local phase="$1" iteration="$2"; shift 2
  local -a roles=("$@")
  local role seen=""
  [ "${#roles[@]}" -ge 1 ] || { echo "DISPATCH_PARALLEL_NO_ROLES" >&2; return 1; }
  for role in "${roles[@]}"; do
    case " $seen " in
      *" $role "*) echo "DISPATCH_PARALLEL_DUPLICATE_ROLE:$role" >&2; return 1 ;;
    esac
    seen="$seen $role"
  done

  local phase_name
  phase_name="$(_phase_name "$phase")" || { echo "DISPATCH_PARALLEL_BAD_PHASE:$phase" >&2; return 1; }

  # ---- Phase 1 (prelaunch): every role, sequentially, before any lease or
  # fork. Restores the v1 render-up-front invariant for the whole batch.
  local -a dp_ok=() dp_attempt_dir=() dp_dispatch_id=() dp_logical=() dp_attempt=()
  local -a dp_status_path=() dp_stdout_path=() dp_stderr_path=() dp_vendor=() dp_mutates=() dp_prompt_file=()
  local i batch_reject=""
  for i in "${!roles[@]}"; do
    if _dispatch_prelaunch "$phase" "$iteration" "${roles[$i]}"; then
      dp_ok[$i]=1
    else
      dp_ok[$i]=0
      batch_reject="${batch_reject:-${roles[$i]}}"
    fi
    dp_attempt_dir[$i]="$PREP_ATTEMPT_DIR"; dp_dispatch_id[$i]="$PREP_DISPATCH_ID"
    dp_logical[$i]="$PREP_LOGICAL"; dp_attempt[$i]="$PREP_ATTEMPT"
    dp_status_path[$i]="$PREP_STATUS_PATH"; dp_stdout_path[$i]="$PREP_STDOUT_PATH"
    dp_stderr_path[$i]="$PREP_STDERR_PATH"; dp_vendor[$i]="$PREP_VENDOR"
    dp_mutates[$i]="$PREP_MUTATES"; dp_prompt_file[$i]="$PREP_PROMPT_FILE"
  done

  if [ -n "$batch_reject" ]; then
    # A sibling failed prelaunch validation/render: every role that itself
    # passed gets its result OVERWRITTEN as not-launched too -- its own
    # render succeeding is irrelevant, nothing in this batch may spend.
    #
    # Note for Task 7 (recovery/resume): allocate_attempt already minted a
    # real attempt number for an innocent peer rejected here, purely as a
    # side effect of validating it before the batch decision was known. A
    # DISPATCH_PARALLEL_PEER_REJECTED record must NOT count against that
    # role's own retry/correction budget -- it never had a chance to run,
    # let alone fail on its own merits.
    for i in "${!roles[@]}"; do
      if [ "${dp_ok[$i]}" = 1 ]; then
        _dispatch_write_result "${dp_attempt_dir[$i]}" launched=no phase="$phase" \
          phase_name="$phase_name" iteration="$iteration" role="${roles[$i]}" \
          vendor="${dp_vendor[$i]}" dispatch_id="${dp_dispatch_id[$i]}" \
          logical_dispatch_id="${dp_logical[$i]}" attempt="${dp_attempt[$i]}" \
          status_path="${dp_status_path[$i]}" classification=PRELAUNCH_FAILED \
          reason="DISPATCH_PARALLEL_PEER_REJECTED:$batch_reject" verdict="" usage_line="" \
          start_ms=0 end_ms=0 wall_ms=0 exit_code="" stdout_path="${dp_stdout_path[$i]}" \
          stderr_path="${dp_stderr_path[$i]}" mutates="${dp_mutates[$i]}" \
          mutation_state=NO_SIDE_EFFECTS
      fi
    done
    declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
    for i in "${!roles[@]}"; do
      _dispatch_ingest_result "${dp_attempt_dir[$i]}/result.kv"
      # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
      DISPATCH_PARALLEL_CLASSIFICATION["${roles[$i]}"]="$DISPATCH_RESULT_CLASSIFICATION"
    done
    # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
    DISPATCH_PARALLEL_GROUP_WALL_MS=0
    return 1
  fi

  # ---- Phase 2 (lease): sequential, in REQUEST ORDER -- deterministic, not
  # a race: the first mutating role in the caller's argument list always
  # wins. A miss here rejects only THAT role, never its siblings (unlike
  # phase 1, lease contention is an expected per-attempt outcome).
  for i in "${!roles[@]}"; do
    if [ "${dp_mutates[$i]}" = yes ]; then
      # Declared write path defaults to "." (the whole repository): no
      # per-role narrower-path registry exists yet (a future task's job),
      # and a mutating role like implementer/debugger may legitimately touch
      # anything under $REPO_ROOT -- "." is the honest, non-overreaching
      # declaration for that contract, not a placeholder.
      if acquire_write_lease "${roles[$i]}" role "${dp_dispatch_id[$i]}" "$phase" "."; then
        :
      else
        dp_ok[$i]=0
        # RM02 vs RM03 (spec S14.3): name WHICH lease-substate this rejection
        # is, so a later recovery_action call can route it correctly instead
        # of treating every lease miss the same.
        _dispatch_write_result "${dp_attempt_dir[$i]}" launched=no phase="$phase" \
          phase_name="$phase_name" iteration="$iteration" role="${roles[$i]}" \
          vendor="${dp_vendor[$i]}" dispatch_id="${dp_dispatch_id[$i]}" \
          logical_dispatch_id="${dp_logical[$i]}" attempt="${dp_attempt[$i]}" \
          status_path="${dp_status_path[$i]}" classification=PRELAUNCH_FAILED \
          reason="DISPATCH_WRITE_LEASE_UNAVAILABLE:$(_write_lease_recovery_state \
            "$(_write_lease_state "$ORCHESTRATION_DIR/write-lease.json")")" \
          verdict="" usage_line="" \
          start_ms=0 end_ms=0 wall_ms=0 exit_code="" stdout_path="${dp_stdout_path[$i]}" \
          stderr_path="${dp_stderr_path[$i]}" mutates="${dp_mutates[$i]}" \
          mutation_state=NO_SIDE_EFFECTS
      fi
    fi
  done

  # ---- Phase 3 (launch): fork only the roles that survived both gates.
  # Every started PID is awaited unconditionally below -- a non-zero exit
  # from one child's subshell must never short-circuit the loop and skip a
  # sibling's wait.
  local -a pids=()
  for i in "${!roles[@]}"; do
    [ "${dp_ok[$i]}" = 1 ] || continue
    ( _dispatch_launch_attempt "$i" ) &
    pids+=("$!")
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || :
  done

  # ---- Ingest every role's result -- launched or not -- strictly after
  # every fork has been waited on, never from inside a child.
  declare -gA DISPATCH_PARALLEL_CLASSIFICATION=()
  local all_ok=0 started=0 s e min_start=0 max_end=0
  for i in "${!roles[@]}"; do
    # See dispatch_parallel's own -e note: never a bare call.
    _dispatch_ingest_child "$phase" "$iteration" "${roles[$i]}" "${dp_attempt_dir[$i]}" || all_ok=1
    # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
    DISPATCH_PARALLEL_CLASSIFICATION["${roles[$i]}"]="$DISPATCH_RESULT_CLASSIFICATION"
    if [ -f "${dp_attempt_dir[$i]}/result.kv" ]; then
      s="$(_dispatch_read_result_field "${dp_attempt_dir[$i]}/result.kv" start_ms 2>/dev/null)"
      e="$(_dispatch_read_result_field "${dp_attempt_dir[$i]}/result.kv" end_ms 2>/dev/null)"
      case "$s" in *[!0-9]*|'') s=0 ;; esac
      case "$e" in *[!0-9]*|'') e=0 ;; esac
      if [ "$s" -gt 0 ]; then
        if [ "$started" -eq 0 ]; then min_start="$s"; max_end="$e"; started=1
        else
          [ "$s" -lt "$min_start" ] && min_start="$s"
          [ "$e" -gt "$max_end" ] && max_end="$e"
        fi
      fi
    fi
  done
  # shellcheck disable=SC2034  # consumed by the caller after dispatch_parallel returns
  DISPATCH_PARALLEL_GROUP_WALL_MS=$((max_end - min_start))
  [ "$DISPATCH_PARALLEL_GROUP_WALL_MS" -ge 0 ] || DISPATCH_PARALLEL_GROUP_WALL_MS=0

  return "$all_ok"
}

# Extracts a vendor refusal's own text from BOTH streams and reports it only
# when it names a wrong-repo/CWD/input shape (spec S14.1's "success-envelope
# orchestration refusal"). vendor_error_text already tells "no vendor error"
# from "no transcript" by emptiness; this adds one more filter on top of it
# and preserves that same convention (prints nothing, still succeeds, when
# no refusal text is found).
# Claude's OWN `.result` text, read regardless of `is_error` (unlike
# vendor_error_text, which only extracts text when is_error==true or
# .error!=null). A genuine refusal can arrive as a "successful" envelope
# (is_error:false, rc 0) whose prose declines the task -- spec S14.1's
# "success-envelope orchestration refusal" is precisely that shape, so the
# ordinary vendor-error extractor (which treats is_error:false as "nothing
# to report") must never be the only reader consulted here. Codex has no
# comparable "successful refusal" shape (its turn.completed record carries
# no free-text result field at all), so this simply returns empty for it.
_claude_result_text() {
  # Usage: _claude_result_text <stdout-transcript-path>
  local out="$1"
  [ -s "${out:-}" ] || return 0
  jq -rs '.[] | select(type=="object") | (.result // empty)' "$out" 2>/dev/null | tail -1
}

_orchestration_refusal_text() {
  # Usage: _orchestration_refusal_text <stdout-transcript-path> <status-path> <role>
  # <status-path>/<role> gate the risky reader below -- see its own comment.
  local out="$1" status_path="${2:-}" role="${3:-}" txt
  txt="$(vendor_error_text "$out" 2>/dev/null)"
  if [ -z "$txt" ]; then
    # _claude_result_text reads ORDINARY SUCCESS PROSE, which a finished,
    # legitimately mutating role can easily contain (an implementer's own
    # summary saying it "fixed invalid input handling" or "the wrong working
    # directory case"). Consulting it when a VALID STATUS already exists
    # would misread that prose as a refusal and route a successfully
    # completed attempt into RM01's ungated correct-and-retry, discarding
    # finished work -- reproduced and fixed per Task 7 review round 2,
    # finding #1. A role that published a valid STATUS did not refuse;
    # only fall back to this reader when no valid STATUS exists at all.
    if [ ! -f "$status_path" ] || ! validate_status "$status_path" "$role" >/dev/null 2>&1; then
      txt="$(_claude_result_text "$out" 2>/dev/null)"
    fi
  fi
  [ -n "$txt" ] || return 0
  if printf '%s\n' "$txt" | "$GREP_BIN" -qiE \
    'outside (the )?(repo|repository|workspace)|wrong (repo|repository|cwd|working directory)|invalid (input|path|argument)s?([[:space:]]|$)|not inside a trusted directory'
  then
    printf '%s\n' "$txt"
  fi
}

# The real ten-outcome ordered classifier (spec S14.1), replacing Task 6's
# four-outcome `_dispatch_classify` wholesale. Sets CLASSIFY_ATTEMPT_RESULT/
# _REASON; always returns 0 (a classification was reached) -- callers branch
# on the RESULT value, exactly like the seam it replaces.
classify_attempt() {
  # Usage: classify_attempt <role> <exit_code> <stdout_file> <stderr_file> <status_file>
  local role="$1" rc="$2" out="$3" err="$4" status_path="$5"
  local refusal combined
  CLASSIFY_ATTEMPT_RESULT=""
  CLASSIFY_ATTEMPT_REASON=""

  case "$rc" in
    95|96|97)
      CLASSIFY_ATTEMPT_RESULT=PRELAUNCH_FAILED
      CLASSIFY_ATTEMPT_REASON="INVOKE_VENDOR_RC_$rc"
      return 0 ;;
  esac

  # Timeout reserves this whole block, not just 124 -- a `timeout` that
  # cannot even exec the target (126/127) or fails on its own terms (125) is
  # just as much "the invocation never produced a vendor result" as a plain
  # deadline (124) or a post-kill-after SIGKILL (137). This is spec row 2 --
  # it outranks a refusal signature found in whatever partial transcript a
  # killed attempt happened to leave behind (a timed-out MUTATING attempt
  # must route through RM06/RM07/RM08's mutation-state gate, never RM01's
  # ungated correct-and-retry).
  case "$rc" in
    124|125|126|127|137)
      CLASSIFY_ATTEMPT_RESULT=TIMED_OUT
      CLASSIFY_ATTEMPT_REASON="TIMEOUT_RC_$rc"
      return 0 ;;
  esac

  # A refusal embedded in a success envelope is evaluated BEFORE ordinary
  # vendor-liveness matching (spec S14.1's own note: rows 3-6, spend/
  # permanent/transient/unknown) -- it is a process defect (wrong repo/CWD/
  # input), not a vendor outage, regardless of rc. NOT before TIMED_OUT above.
  refusal="$(_orchestration_refusal_text "$out" "$status_path" "$role" 2>/dev/null)"
  if [ -n "$refusal" ]; then
    CLASSIFY_ATTEMPT_RESULT=PRELAUNCH_FAILED
    CLASSIFY_ATTEMPT_REASON="ORCHESTRATION_REFUSAL:${refusal:0:200}"
    return 0
  fi

  # Signature matching reads BOTH streams (vendor_error_text first, per the
  # transcript-read policy, then the stderr tail) and is NOT gated on rc: a
  # real spend ceiling can present as a "successful" rc=0 process wrapping an
  # is_error envelope just as often as a non-zero exit with a stderr message
  # -- "zero or non-zero wrapper" must classify identically.
  combined="$(vendor_error_text "$out" 2>/dev/null)"
  combined="$combined
$(tail -n 40 "$err" 2>/dev/null)"
  if printf '%s' "$combined" | "$GREP_BIN" -qiE \
    "$(_spend_ceiling_pattern)"
  then
    CLASSIFY_ATTEMPT_RESULT=SPEND_CEILING
    CLASSIFY_ATTEMPT_REASON="rc=$rc"
    return 0
  fi
  if printf '%s' "$combined" | "$GREP_BIN" -qiE \
    'authentication_error|invalid api key|permission denied|unauthorized|invalid[_ ]model|model not found|forbidden|http/?[[:space:]]?40[13]'
  then
    CLASSIFY_ATTEMPT_RESULT=PERMANENT_VENDOR_ERROR
    CLASSIFY_ATTEMPT_REASON="rc=$rc"
    return 0
  fi
  if printf '%s' "$combined" | "$GREP_BIN" -qiE \
    'rate limit|rate_limit_error|429|too many requests|overloaded_error|please try again|retry after|connection reset|stream stall|5[0-9][0-9][^0-9]'
  then
    CLASSIFY_ATTEMPT_RESULT=TRANSIENT_TRANSPORT_ERROR
    CLASSIFY_ATTEMPT_REASON="rc=$rc"
    return 0
  fi

  # UNKNOWN_VENDOR_ERROR is the catch-all for a non-zero exit only (spec:
  # "non-zero result ... not covered above") -- an rc=0 process with no
  # matched signature falls through to the STATUS-presence ladder instead.
  if [ "$rc" != 0 ]; then
    CLASSIFY_ATTEMPT_RESULT=UNKNOWN_VENDOR_ERROR
    CLASSIFY_ATTEMPT_REASON="rc=$rc"
    return 0
  fi

  if [ ! -f "$status_path" ]; then
    if compgen -G "${status_path}.tmp.*" >/dev/null 2>&1; then
      CLASSIFY_ATTEMPT_RESULT=PUBLICATION_LOST
    else
      CLASSIFY_ATTEMPT_RESULT=EXITED_NO_STATUS
    fi
    CLASSIFY_ATTEMPT_REASON="rc=0"
    return 0
  fi
  if ! validate_status "$status_path" "$role" >/dev/null 2>&1; then
    CLASSIFY_ATTEMPT_RESULT=MALFORMED_STATUS
    CLASSIFY_ATTEMPT_REASON="rc=0"
    return 0
  fi
  CLASSIFY_ATTEMPT_RESULT=COMPLETED
  CLASSIFY_ATTEMPT_REASON=""
  return 0
}

# Real offenders for MUTATION classification purposes: every changed path
# EXCEPT the fixed orchestration-bookkeeping locations (RUN_LOG.md,
# full_log.md, $ORCHESTRATION_DIR, $FEATURE_FOLDER/transcripts/, and any
# phase's own attempts/ subtree, matched structurally since it recurs under
# every numbered phase directory). Deliberately NOT dirty_tree_check's own
# allow-list: that one also exempts $SPEC_PATH/$PLAN_PATH/the WHOLE
# $FEATURE_FOLDER wholesale, which is right for the Phase-1/6 "did anything
# unexpected change" gate but wrong here -- plan-writer's only declared
# output IS $PLAN_PATH, spec-fixer/plan-fixer own $SPEC_PATH, and
# documentation-writer's outputs live under $FEATURE_FOLDER. Reusing that
# allow-list silently read every document-writing mutating role as
# NO_SIDE_EFFECTS regardless of what it actually wrote (Task 7 review
# finding #4). Real content -- SPEC_PATH, PLAN_PATH, source under $REPO_ROOT,
# any other $FEATURE_FOLDER output -- is never exempted here.
#
# Uses `--untracked-files=all` (its own git status call, not porcelain_
# offenders, which is shared with the production Phase-1/6 dirty-tree gate
# and deliberately stays on the cheaper default grouping there): $FEATURE_
# FOLDER is NEVER git-added by design, so with the default grouping git
# collapses its entire untracked subtree into ONE line the moment nothing
# under it is tracked -- exactly the case on every fresh dispatch -- which
# would make every one of the per-subpath exclusions below unmatchable.
# ponytail: recursive untracked-file listing is O(untracked files in the
# whole repo), a real cost on a repo with large ungitignored scratch trees;
# revisit if that ever measurably matters for this one per-attempt check.
_mutation_dirty() {
  local ff_rel orch_rel status path old entry
  ff_rel="${FEATURE_FOLDER#"${REPO_ROOT:-}"/}"
  orch_rel="${ORCHESTRATION_DIR#"${REPO_ROOT:-}"/}"
  _mutation_excluded() {
    local p="$1"
    case "$p" in
      "$ff_rel/RUN_LOG.md"|"$ff_rel/full_log.md") return 0 ;;
      # Task 15 round 2 fix: record_event now auto-fulfils every
      # proposition_required=yes event via append_proposition, which
      # writes this file the FIRST time any of the fifteen types fires --
      # the SAME orchestrator-bookkeeping status as RUN_LOG.md/full_log.md
      # above (written by the process itself, never a role's own
      # deliverable), and it persists across every later attempt in the
      # run exactly like they do. Missing this line made EVERY later
      # attempt's own dirty-tree check see permanent, unrelated "dirt" the
      # instant the first mandatory event of the whole run occurred.
      "$ff_rel/process-improvement-proposition.md") return 0 ;;
      "$orch_rel"|"$orch_rel"/*) return 0 ;;
      "$ff_rel/transcripts"|"$ff_rel/transcripts"/*) return 0 ;;
      "$ff_rel"/*/attempts/*) return 0 ;;
    esac
    return 1
  }
  local rc=1   # 1 = clean (no offender found), 0 = dirty (an offender found)
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"; path="${entry:3}"
    case "$status" in
      R*|C*)
        IFS= read -r -d '' old || old=""
        if ! _mutation_excluded "$path" || { [ -n "$old" ] && ! _mutation_excluded "$old"; }; then
          rc=0; break
        fi
        ;;
      *)
        _mutation_excluded "$path" || { rc=0; break; } ;;
    esac
  done < <(git -C "${REPO_ROOT:-}" status --porcelain=v1 --untracked-files=all -z 2>/dev/null)
  unset -f _mutation_excluded
  return "$rc"
}

# Compares the target repo's git HEAD/tree now against the pre-attempt
# snapshot _dispatch_launch_attempt captured at $MUTATION_SNAPSHOT_DIR/
# pre-head, and reports one of the five spec S14.2 mutation states. A
# read-only role (role_mutates != yes) is always NO_SIDE_EFFECTS UNLESS it
# somehow left evidence of a change, which is a contract violation, not a
# mutation state to route retries by -- INTEGRITY_UNKNOWN, per spec.
inspect_mutation_state() {
  # Usage: inspect_mutation_state <role>
  local role="$1" mutates pre_head cur_head dirty
  mutates="$(role_mutates "$role" 2>/dev/null)" || mutates=""

  pre_head=""
  if [ -n "${MUTATION_SNAPSHOT_DIR:-}" ] && [ -f "$MUTATION_SNAPSHOT_DIR/pre-head" ]; then
    pre_head="$(cat "$MUTATION_SNAPSHOT_DIR/pre-head" 2>/dev/null)"
  fi
  if [ -z "$pre_head" ]; then
    echo INTEGRITY_UNKNOWN
    return 0
  fi

  cur_head="$(git -C "${REPO_ROOT:-}" rev-parse HEAD 2>/dev/null || echo none)"
  if _mutation_dirty; then dirty=yes; else dirty=no; fi

  if [ "$mutates" != yes ]; then
    if [ "$cur_head" = "$pre_head" ] && [ "$dirty" = no ]; then
      echo NO_SIDE_EFFECTS
    else
      echo INTEGRITY_UNKNOWN
    fi
    return 0
  fi

  if [ "$cur_head" = "$pre_head" ] && [ "$dirty" = no ]; then
    echo NO_SIDE_EFFECTS
  elif [ "$cur_head" != "$pre_head" ] && [ "$dirty" = no ]; then
    echo CLEAN_CHECKPOINTED
  elif [ "$cur_head" != "$pre_head" ] && [ "$dirty" = yes ]; then
    echo DIRTY_CHECKPOINTED
  else
    echo DIRTY_UNCHECKPOINTED
  fi
}

# Maps (classification, mutation/lease state) onto exactly one of the twelve
# rows above. For classification=PRELAUNCH_FAILED, <state> is a LEASE
# substate (CORRECTABLE / ACTIVE_LEASE_OWNER / STALE_OR_AMBIGUOUS_LEASE,
# from _write_lease_recovery_state or "correctable" by default) -- never one of
# the five repo mutation states, since a prelaunch failure never invoked the
# vendor and has nothing yet to compare against a snapshot. Every other
# classification takes a real inspect_mutation_state value. Sets
# RECOVERY_MATRIX_ID/RECOVERY_ACTION; returns 1 only for a combination no
# row covers (a process-definition bug, never silently swallowed).
# Routes through record_event (the canonical writer -- see "RUN_LOG events,
# decisions, write leases, and snapshots" below); kept as a named wrapper
# purely so recovery_action's own call site never has to change.
_recovery_emit_orchestration_correction() {
  # Usage: _recovery_emit_orchestration_correction <logical_dispatch_id>
  local logical="$1"
  record_event ORCHESTRATION_CORRECTION logical_dispatch_id="$logical" \
    reason="correctable prelaunch defect (RM01)"
}

# Same convention, for RM09. This records that the vendor was found
# unavailable -- ACTUALLY suppressing later dispatches to it (a run-scoped
# flag every subsequent invoke_vendor call consults) remains a later task's
# job; this only makes the incident durable, per spec S14.3's "emit one
# run-scoped vendor-unavailable event".
_recovery_emit_vendor_unavailable() {
  # Usage: _recovery_emit_vendor_unavailable <logical_dispatch_id> <vendor>
  local logical="$1" vendor="${2:-unknown}"
  record_event VENDOR_UNAVAILABLE logical_dispatch_id="$logical" vendor="$vendor" \
    reason="spend ceiling (RM09)"
}

recovery_action() {
  # Usage: recovery_action <classification> <state> [logical_dispatch_id] [vendor]
  # <vendor> is optional and used ONLY to name the RM09 event below.
  # <logical_dispatch_id> is optional for every row EXCEPT RM07 (code
  # review fix: this used to say "every other row ignores them", which
  # stopped being true the moment RM07's real isolation wiring landed --
  # DIRTY_CHECKPOINTED now REQUIRES it to resolve the failed attempt's own
  # checkpoint before it can honestly judge isolation). The two-argument
  # call form `recovery_action CLASSIFICATION MUTATION_STATE` -- the
  # plan's own fixed interface -- is still legal for every row but RM07;
  # for RM07 specifically it cannot decide isolation at all and reports
  # `RECONCILE_UNKNOWN_NO_LOGICAL_ID` rather than silently guessing
  # "not isolated" (see the DIRTY_CHECKPOINTED case below). A caller that
  # reaches RM07 MUST supply the real logical_dispatch_id, and MUST have
  # done so before allocating any continuation attempt for it -- resume-
  # state reads the LATEST attempt already durable in RUN_LOG
  # (_recovery_checkpoint_context, "Checkpoint contract" below), so
  # recovery_action's own verdict has to be consulted BEFORE allocate_
  # attempt mints the continuation's new attempt id, never after.
  local classification="$1" state="$2" logical="${3:-}" vendor="${4:-}"
  RECOVERY_MATRIX_ID=""; RECOVERY_ACTION=""

  if [ "$classification" = COMPLETED ]; then
    RECOVERY_MATRIX_ID=RM12; RECOVERY_ACTION=BRANCH_ON_VERDICT
    return 0
  fi
  if [ "$classification" = PRELAUNCH_FAILED ]; then
    case "$state" in
      ACTIVE_LEASE_OWNER)       RECOVERY_MATRIX_ID=RM02; RECOVERY_ACTION=WAIT_FOR_OWNER ;;
      STALE_OR_AMBIGUOUS_LEASE) RECOVERY_MATRIX_ID=RM03; RECOVERY_ACTION=HALT_INTEGRITY ;;
      *)
        RECOVERY_MATRIX_ID=RM01; RECOVERY_ACTION=CORRECT_AND_RETRY
        [ -n "$logical" ] && _recovery_emit_orchestration_correction "$logical"
        ;;
    esac
    return 0
  fi

  # RM08 overrides every other failure row once the repo is irrecoverable or
  # uncertain (spec: "any failure, DIRTY_UNCHECKPOINTED or INTEGRITY_UNKNOWN").
  case "$state" in
    DIRTY_UNCHECKPOINTED|INTEGRITY_UNKNOWN)
      RECOVERY_MATRIX_ID=RM08; RECOVERY_ACTION=HALT_EXACT_STATE
      return 0 ;;
  esac

  case "$classification" in
    TIMED_OUT|TRANSIENT_TRANSPORT_ERROR|EXITED_NO_STATUS|PUBLICATION_LOST)
      # PUBLICATION_LOST shares this state-keyed routing with the other
      # three "no confirmed completion" classifications (spec's Recovery
      # Matrix table lists it alongside them in RM06/RM07) -- ONLY its
      # NO_SIDE_EFFECTS case gets its OWN row/cap (RM04, publication_retry_
      # cap) instead of RM05/transient_retry_cap, since "nothing mutated
      # yet, just retry the report" is a cheaper class of retry than a
      # genuine transient/timeout/no-status redispatch.
      case "$state" in
        NO_SIDE_EFFECTS)
          if [ "$classification" = PUBLICATION_LOST ]; then
            RECOVERY_MATRIX_ID=RM04; RECOVERY_ACTION=RETRY_PUBLICATION
          else
            RECOVERY_MATRIX_ID=RM05; RECOVERY_ACTION=TRANSIENT_RETRY
          fi ;;
        CLEAN_CHECKPOINTED)
          RECOVERY_MATRIX_ID=RM06; RECOVERY_ACTION=CONTINUE_WITHIN_CAP ;;
        DIRTY_CHECKPOINTED)
          # RM07's own "isolated" test (spec: "continuation ... only if the
          # partial unit is isolated"), closed as of Task 9 -- code review
          # fix: resume-state now runs HERE, before this decision, not
          # after it (the ordering the original pass got backwards, which
          # made RM07 permanently RECONCILE_BLOCKED_NOT_ISOLATED on any real
          # call). `_recovery_checkpoint_context` resolves $logical's own
          # most recent attempt and runs checkpoint_resume_state against
          # ITS real progress.jsonl right now; `checkpoint_partial_isolated`
          # then judges the tree against that freshly-resolved state. The
          # matrix ID is RM07 either way (this combination always routes
          # here); only the ACTION differs, exactly like RM11's own
          # NO_SIDE_EFFECTS/mutating split above.
          #
          # `$logical` MISSING entirely (the plan's own two-argument fixed
          # call form) is a DISTINCT case from "resolvable but genuinely not
          # isolated" (round 2 code review fix): RM07 cannot be decided
          # honestly with no logical dispatch id to resolve a checkpoint
          # from at all, so it says so with its own token
          # (RECONCILE_UNKNOWN_NO_LOGICAL_ID) instead of silently reporting
          # the SAME "not isolated" a real, evaluated non-isolated case
          # reports. A NON-empty `$logical` whose resolution still fails
          # (no attempt found, no checkpoint at that path) legitimately
          # fails closed to RECONCILE_BLOCKED_NOT_ISOLATED -- that IS a
          # real attempt to evaluate isolation, just one with nothing to
          # confirm it, which is exactly the "cannot prove isolated" case
          # this whole gate exists to fail closed on.
          RECOVERY_MATRIX_ID=RM07
          if [ -z "$logical" ]; then
            RECOVERY_ACTION=RECONCILE_UNKNOWN_NO_LOGICAL_ID
          else
            _recovery_checkpoint_context "$logical" 2>/dev/null || true
            if checkpoint_partial_isolated; then
              RECOVERY_ACTION=RECONCILE_THEN_CONTINUE_IF_ISOLATED
            else
              RECOVERY_ACTION=RECONCILE_BLOCKED_NOT_ISOLATED
            fi
          fi
          ;;
        *)
          echo "RECOVERY_ACTION_UNMAPPED_STATE:$classification:$state" >&2
          return 1 ;;
      esac ;;
    SPEND_CEILING)
      RECOVERY_MATRIX_ID=RM09; RECOVERY_ACTION=SUPPRESS_VENDOR_HALT_OR_DEGRADE
      [ -n "$logical" ] && _recovery_emit_vendor_unavailable "$logical" "$vendor"
      ;;
    PERMANENT_VENDOR_ERROR|UNKNOWN_VENDOR_ERROR)
      RECOVERY_MATRIX_ID=RM10; RECOVERY_ACTION=HALT_OR_DEGRADE ;;
    MALFORMED_STATUS)
      if [ "$state" = NO_SIDE_EFFECTS ]; then
        RECOVERY_MATRIX_ID=RM11; RECOVERY_ACTION=CORRECT_AND_RETRY
      else
        # shellcheck disable=SC2034  # consumed by the caller after recovery_action returns
        RECOVERY_MATRIX_ID=RM11
        # shellcheck disable=SC2034  # consumed by the caller after recovery_action returns
        RECOVERY_ACTION=RECONCILE_THEN_CONTINUE_IF_SAFE
      fi ;;
    *)
      echo "RECOVERY_ACTION_UNMAPPED_CLASSIFICATION:$classification:$state" >&2
      return 1 ;;
  esac
  return 0
}

# Counts CLASSIFIED FAILED attempts for one logical dispatch id -- an
# ATTEMPT_FAILED record (a launched attempt that finished but was not
# COMPLETED), or a DISPATCH_NOT_LAUNCHED record whose OWN prelaunch defect
# was the cause. A DISPATCH_NOT_LAUNCHED caused by a SIBLING's batch reject
# (reason starts with DISPATCH_PARALLEL_PEER_REJECTED, see dispatch_
# parallel's own comment on this exact carry-over) is explicitly excluded:
# that role never got a chance to fail on its own merits, so it must not
# spend its own retry/correction budget. Counting `next_unused_attempt`
# (every allocated attempt id, launched or not) was the Task 7 review's
# finding #3 -- an innocent peer-rejected role would otherwise lose its
# budget to a batch it wasn't even the cause of.
_recovery_failed_attempts_used() {
  # Usage: _recovery_failed_attempts_used <logical_dispatch_id>
  local logical="$1" log="${FEATURE_FOLDER:-}/RUN_LOG.md"
  [ -f "$log" ] || { echo 0; return 0; }
  awk -v RS="" -v logical="$logical" '
    function has_id(text,    n, lines, i) {
      n = split(text, lines, "\n")
      for (i=1;i<=n;i++) if (lines[i] ~ ("^dispatch_id:[ \t]+" logical "-a[0-9][0-9]$")) return 1
      return 0
    }
    function field(text, name,    n, lines, i, v) {
      n = split(text, lines, "\n")
      for (i=1;i<=n;i++) {
        if (index(lines[i], name ":") == 1) {
          v = substr(lines[i], length(name) + 2)
          gsub(/^[ \t]+|[ \t]+$/, "", v)
          return v
        }
      }
      return ""
    }
    /event=ATTEMPT_FAILED/ { if (has_id($0)) count++ }
    /event=DISPATCH_NOT_LAUNCHED/ {
      if (has_id($0) && field($0, "reason") !~ /^DISPATCH_PARALLEL_PEER_REJECTED:/) count++
    }
    END { print count + 0 }
  ' "$log"
}

# Enforces a recovery action's retry cap via policy_value -- never a numeric
# literal. Every actual retry still allocates its OWN new attempt id through
# the normal allocate_attempt/dispatch_attempt path; this only answers
# "is the cap for THIS action already spent" and, when it is, records
# RECOVERY_CAP_REACHED once. An action with no cap (WAIT_FOR_OWNER, every
# HALT_*, SUPPRESS_VENDOR_HALT_OR_DEGRADE, HALT_OR_DEGRADE, BRANCH_ON_VERDICT)
# always returns 0 -- recovery_action never routes those here.
#
# used_count (from _recovery_failed_attempts_used) is the number of times
# this logical dispatch has ALREADY failed for real -- the ORIGINAL attempt
# counts as failure #1, not as a retry. A cap of 1 ("retry once") must still
# permit the retry that follows failure #1 (0 retries spent so far) and only
# deny after failure #2 (the one retry already happened and also failed) --
# i.e. deny when (used_count - 1) >= cap_value, never used_count >= cap_value
# (that off-by-one denied every cap-1 row's very first retry -- Task 7
# review finding #1).
#
# Budgets are keyed by logical_dispatch_id only, not yet by cause (spec:
# "keyed by logical dispatch and cause") -- every classified failure
# recorded so far for one logical id is counted as one shared budget. This
# is exact for how these caps are exercised today (one cause per logical
# dispatch's retry history); a future mixed-cause history is Task 8/9's
# per-cause ledger to refine, not a gap this task's own tests can observe.
recovery_retry_allowed() {
  # Usage: recovery_retry_allowed <logical_dispatch_id> <recovery_action>
  local logical="$1" action="$2" cap_name cap_value used_count retries_used
  case "$action" in
    CORRECT_AND_RETRY)                     cap_name=prelaunch_correction_cap ;;
    RETRY_PUBLICATION)                      cap_name=publication_retry_cap ;;
    TRANSIENT_RETRY)                        cap_name=transient_retry_cap ;;
    CONTINUE_WITHIN_CAP| \
    RECONCILE_THEN_CONTINUE_IF_ISOLATED| \
    RECONCILE_THEN_CONTINUE_IF_SAFE)        cap_name=continuation_cap ;;
    # Code review fix: this used to fall through to the `*) return 0`
    # default below, which reads as "no cap applies, proceed" -- exactly
    # backwards for an action whose own name says NOT_ISOLATED. A non-
    # isolated dirty checkpoint is never retried/continued, unconditionally,
    # with no cap-count check at all (there is nothing to count up to).
    # RECONCILE_UNKNOWN_NO_LOGICAL_ID (round 2 fix) gets the identical
    # treatment: a caller that could not even ask the question never gets
    # to proceed as if the answer were "no cap applies" either.
    RECONCILE_BLOCKED_NOT_ISOLATED| \
    RECONCILE_UNKNOWN_NO_LOGICAL_ID)       return 1 ;;
    *) return 0 ;;
  esac
  cap_value="$(policy_value "$cap_name")" \
    || { echo "RECOVERY_CAP_LOOKUP_FAILED:$cap_name" >&2; return 1; }
  used_count="$(_recovery_failed_attempts_used "$logical")"
  retries_used=$(( used_count > 0 ? used_count - 1 : 0 ))
  if [ "$retries_used" -ge "$cap_value" ]; then
    # Continuation caps (spec S10.4/S6 Step 6) get their OWN durable event
    # name -- CONTINUATION_CAP_REACHED, never the generic RECOVERY_CAP_
    # REACHED every other capped action still uses -- because "a checkpointed
    # role ran out of resumes" is a distinct, propositable signal from an
    # ordinary retry/correction cap running out ("stop for human direction",
    # never silently restart from scratch). Same counting, same cap lookup,
    # only the emitted event differs.
    if [ "$cap_name" = continuation_cap ]; then
      record_event CONTINUATION_CAP_REACHED logical_dispatch_id="$logical" \
        cap="$cap_name" cap_value="$cap_value" attempts_used="$used_count" \
        reason="continuation cap exhausted for action $action"
    else
      record_event RECOVERY_CAP_REACHED logical_dispatch_id="$logical" \
        cap="$cap_name" cap_value="$cap_value" attempts_used="$used_count" \
        reason="retry cap exhausted for action $action"
    fi
    return 1
  fi
  # The counterpart RECOVERY_CAP_REACHED never previously had: a durable
  # record of every retry the process actually AUTHORIZED, not just the
  # ones it eventually denied.
  record_event RECOVERY_AUTHORIZED logical_dispatch_id="$logical" action="$action" \
    reason="retry authorized under $cap_name ($retries_used/$cap_value used)" \
    >/dev/null 2>&1 || true
  return 0
}

# Last event tag (DISPATCH_STARTED/DISPATCH_COMPLETED/DISPATCH_NOT_LAUNCHED)
# recorded for ONE exact dispatch id, or nothing. Same append-only "last
# match wins" scan shape as dispatch_is_running.
_dispatch_last_event_for_id() {
  # Usage: _dispatch_last_event_for_id <dispatch_id>
  local id="$1" log="${FEATURE_FOLDER:-}/RUN_LOG.md" tag="" last="" line
  [ -f "$log" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "--- "*"  event=DISPATCH_STARTED")      tag=DISPATCH_STARTED ;;
      "--- "*"  event=DISPATCH_COMPLETED")    tag=DISPATCH_COMPLETED ;;
      "--- "*"  event=DISPATCH_NOT_LAUNCHED") tag=DISPATCH_NOT_LAUNCHED ;;
      "--- "*)                                tag="" ;;
      "dispatch_id:"*)
        [ -n "$tag" ] || continue
        case "$line" in *"$id") last="$tag" ;; esac ;;
    esac
  done < "$log"
  if [ -n "$last" ]; then
    printf '%s\n' "$last"
  fi
}

# One field from the SPECIFIC DISPATCH_COMPLETED block naming this exact
# dispatch id (paragraph-mode awk: RUN_LOG blocks are blank-line separated).
_dispatch_completed_field() {
  # Usage: _dispatch_completed_field <dispatch_id> <field>
  local id="$1" field="$2" log="${FEATURE_FOLDER:-}/RUN_LOG.md"
  [ -f "$log" ] || return 1
  awk -v RS="" -v id="$id" -v field="$field:" '
    /event=DISPATCH_COMPLETED/ {
      n = split($0, lines, "\n")
      match_id = 0
      for (i=1;i<=n;i++) if (lines[i] ~ ("^dispatch_id:[ \t]+" id "$")) match_id = 1
      if (!match_id) next
      for (i=1;i<=n;i++) {
        if (index(lines[i], field) == 1) {
          v = substr(lines[i], length(field)+1)
          gsub(/^[ \t]+|[ \t]+$/, "", v)
          print v
          exit
        }
      }
    }
  ' "$log"
}

# One-shot liveness probe for spec S14.4's RUNNING_OBSERVED vs
# ORPHANED_UNOBSERVED split ("the child is known live" / "no child is
# live"). Never a supervision loop and never a hand-rolled PID file (both
# explicitly retired -- see "Long dispatch" above): a single point-in-time
# /proc scan for a live process whose OWN environment carries this exact
# DISPATCH_ID, which invoke_vendor already exports command-scoped into
# every vendor subprocess it launches.
#
# Fails SAFE, not merely "no false positive": the harmful direction here is
# a false NEGATIVE (reporting "not live" for a genuinely running writer),
# because ORPHANED_UNOBSERVED is exactly the state that authorises
# allocating a REPLACEMENT attempt -- a false negative means two writers.
# So this returns 0 ("treat as live") both when a match is found AND when
# liveness cannot be determined at all (no /proc on this host, or a read
# race/permission failure on some candidate file); it returns 1 ("confirmed
# not live") ONLY once every candidate file was actually read and none
# matched. A single `grep` call across every candidate file (rather than one
# per file) makes this one fork total instead of two forks per process
# (measured 0.44s at 426 processes with the old per-file tr|grep pipeline),
# and keeps the whole command's stderr under ONE redirect -- a per-file
# `< "$f" 2>/dev/null` leaks "Permission denied" because bash's own
# redirect-setup failure happens before that trailing `2>` takes effect;
# a single `cmd ... 2>/dev/null` has no such ordering hazard.
_dispatch_child_live() {
  # Usage: _dispatch_child_live <dispatch_id>
  local id="$1" f hit
  [ -d /proc ] || return 0
  # Pre-filter to READABLE files with the `[ -r ]` builtin (no fork) before
  # the one grep call below -- both to shrink the argument list and because
  # a file this EUID cannot even stat as readable is never a process this
  # shell could have spawned. Uses `-l` (list matching filenames) rather
  # than `-q`/an exit-code check: on a real host running under Yama's
  # default ptrace_scope, `/proc/<pid>/environ` can still refuse an actual
  # read for a same-UID process that is not a ptrace-visible descendant of
  # THIS shell (unrelated terminals, daemons under the same account), which
  # makes grep exit 2 (a read error) on nearly every real invocation
  # regardless of whether the target dispatch is alive -- an exit-code rule
  # of "2 means inconclusive" would make ORPHANED_UNOBSERVED practically
  # unreachable on such a host. Reading grep's OWN reported match list
  # sidesteps that ambiguity entirely: a name in the output is an
  # unambiguous live match; nothing in the output, across every file this
  # EUID could actually open, is treated as a confirmed non-match. (A
  # residual gap remains for the specific, unusual case of a live target
  # process this shell is not a ptrace-visible ancestor of -- a known
  # ceiling of the /proc-environ approach itself, not of this exit-code
  # handling; Task 8/9's real snapshot/lease bookkeeping is the eventual
  # fix, not a shell-only liveness probe.)
  local -a files=()
  for f in /proc/[0-9]*/environ; do
    [ -r "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0   # nothing readable at all -- cannot determine, fail safe
  # -x (whole NUL-record match) is required, not optional: without it,
  # "DISPATCH_ID=p06-i40-debugger" is a SUBSTRING of a sibling
  # "LOGICAL_DISPATCH_ID=p06-i40-debugger" environ entry, which would make a
  # logical-id lookup a guaranteed false "live" match (Task 7 review round 2,
  # finding #3). Latent today (only full -aNN attempt ids are ever passed in),
  # but -x costs nothing and removes the trap entirely.
  hit="$("$GREP_BIN" -zlxF "DISPATCH_ID=$id" "${files[@]}" 2>/dev/null)"
  [ -n "$hit" ] && return 0
  return 1
}

# The spec S14.4 seven-state resume classifier for one LOGICAL dispatch id
# (spanning every attempt allocated for it so far).
resume_dispatch_state() {
  # Usage: resume_dispatch_state <logical_dispatch_id>
  local logical="$1" max_raw max latest_id last_event
  local classification status_path role verdict
  if [ ! -f "${FEATURE_FOLDER:-}/RUN_LOG.md" ]; then
    echo NOT_STARTED; return 0
  fi
  max_raw="$(next_unused_attempt "$logical" 2>/dev/null)"
  if [ -z "$max_raw" ]; then
    # ATTEMPT_OVERFLOW or a lookup defect -- at least one attempt clearly
    # exists already (next_unused_attempt only fails once 99 already do);
    # never misreport that as NOT_STARTED.
    max=99
  else
    max=$((max_raw - 1))
  fi
  if [ "$max" -le 0 ]; then
    echo NOT_STARTED; return 0
  fi
  latest_id="${logical}-a$(printf '%02d' "$max")"

  if dispatch_is_running "$latest_id"; then
    # A durable start with no completion yet: RUNNING_OBSERVED only when a
    # live child is ACTUALLY confirmed; otherwise it is an unobserved
    # orphan (spec S14.4 splits these two, never inferred from stdout or
    # exit code, only from this durable gap plus the liveness probe).
    if _dispatch_child_live "$latest_id"; then
      echo RUNNING_OBSERVED
    else
      echo ORPHANED_UNOBSERVED
    fi
    return 0
  fi

  last_event="$(_dispatch_last_event_for_id "$latest_id")"
  case "$last_event" in
    DISPATCH_NOT_LAUNCHED)
      echo PRELAUNCH_FAILED ;;
    DISPATCH_COMPLETED)
      classification="$(_dispatch_completed_field "$latest_id" classification)"
      status_path="$(_dispatch_completed_field "$latest_id" status_path)"
      role="$(_dispatch_completed_field "$latest_id" role)"
      if [ "$classification" != COMPLETED ] || [ -z "$status_path" ] \
         || [ ! -f "$status_path" ] || ! validate_status "$status_path" "$role" >/dev/null 2>&1; then
        echo FAILED_OBSERVED
      else
        verdict="$(_dispatch_completed_field "$latest_id" verdict)"
        case "$verdict" in
          PASS|READY|DONE) echo COMPLETED_VALID ;;
          *)               echo COMPLETED_UNACCEPTED ;;
        esac
      fi
      ;;
    *)
      echo NOT_STARTED ;;
  esac
}

# ---- Event contract registry ------------------------------------------------
# `event_contract_field EVENT_TYPE FIELD` -- the single row/column lookup
# `event_required_fields` and `_event_proposition_required` (below) are thin
# calls onto, the SAME `role_contract_field`/`policy_value` TSV-lookup
# pattern the Role Contract and Process Policy registries already use (Task
# 8/P19). This RETIRES the former hand-written case statements: the Markdown
# table above is what `bootstrap_runtime` extracts into
# `$RUNTIME_DIR/events.tsv` (via `extract.py events`), and this function
# reads THAT file -- editing a cell in the table now has a real runtime
# effect the next time `bootstrap_runtime` (re-)materializes it, exactly
# like `role_contract_field`/`policy_value` against their own registries.
# The prior comment here ("enforcement does NOT flow FROM the Markdown
# table") is retired along with the ~40-branch case statements it
# described: the materialized $RUNTIME_DIR/events.tsv (fast path, below) and
# the on-demand re-extraction (fallback 1, below) both read this SAME table
# -- there is nothing left to drift from it in either state. Only the
# five-row last-resort table (fallback 2, below), for when neither a
# materialized registry nor a working extractor exists at all, is a real
# second copy -- deliberately tiny and pinned to the registry rows it
# mirrors. Fails loudly (never silently defaults) on an unknown event_type
# or a duplicated one, exactly `policy_value`'s own discipline against
# `policy.tsv`.
#
# Pre-bootstrap exception (documented the same way as record_event's own
# policy_value/process_schema_version fallback below): _preflight_halt's own
# HALT and Phase -1 gates 1-4 call record_event -- and therefore this
# lookup -- before bootstrap_runtime (gate 5) has materialized
# $RUNTIME_DIR/events.tsv (see "Preflight zero-token gate sequence" below).
# Two fallbacks, tried in order, both narrower in scope than the fast path:
#   1. Re-run the SAME extractor directly against the SAME source document
#      (mirroring bootstrap_runtime's own `extract.py events` invocation) --
#      covers every pre-bootstrap call site as long as $PROCESS_REPO_ROOT's
#      tests/lib/extract.py is itself intact, reading the identical table
#      post-bootstrap uses, just uncached.
#   2. If even THAT fails (a checkout whose tests/ directory is missing or
#      broken -- exactly what gate 5 itself exists to catch, spec §16.1),
#      `_event_contract_field_preboot` (below) hand-carries the five rows
#      "Preflight zero-token gate sequence" proves fire before $RUNTIME_DIR
#      can possibly exist, verified to match the registry above. This can
#      never be layer 1's job: gate 5's own purpose is to prove the
#      extractor works, so a broken extractor must surface AT gate 5, not
#      be silently absorbed one gate earlier by this lookup.
# Every other type, in either fallback state, fails loudly rather than
# guessing.
event_contract_field() {
  local event_type=$1 field=$2 path tsv cache_key
  path="${RUNTIME_DIR:+$RUNTIME_DIR/events.tsv}"
  if [ -n "$path" ] && [ -r "$path" ]; then
    tsv="$(cat "$path")"
  else
    # Cached per this ONE shell (fresh per phase, per spec §7.2 -- never
    # written to disk, never shared across shells): gates 1-4 alone can call
    # this up to four times before $RUNTIME_DIR/events.tsv exists, and
    # re-running the extractor on every single call would needlessly repeat
    # the same parse of this ~13k-line document. Keyed on the two inputs the
    # extraction actually depends on, so a genuine mid-shell change (a test
    # fixture swapping PROCESS_REPO_ROOT, say) still re-extracts.
    cache_key="$PROCESS_REPO_ROOT:$PROCESS_PATH"
    if [ "${_EVENT_CONTRACT_TSV_CACHE_KEY:-}" != "$cache_key" ]; then
      local build_tmp rc
      build_tmp="$(mktemp -d)"
      _EVENT_CONTRACT_TSV_CACHE="$(PROCESS_DOC="$PROCESS_PATH" BUILD="$build_tmp" "$PYTHON_BIN" \
        "$PROCESS_REPO_ROOT/tests/lib/extract.py" events 2>/dev/null)"; rc=$?
      rm -rf "$build_tmp"
      if [ "$rc" -ne 0 ] || [ -z "$_EVENT_CONTRACT_TSV_CACHE" ]; then
        _EVENT_CONTRACT_TSV_CACHE=""
        _EVENT_CONTRACT_TSV_CACHE_KEY=""
        _event_contract_field_preboot "$event_type" "$field"
        return
      fi
      _EVENT_CONTRACT_TSV_CACHE_KEY="$cache_key"
    fi
    tsv="$_EVENT_CONTRACT_TSV_CACHE"
  fi
  awk -F'\t' -v t="$event_type" -v field="$field" '
    NR==1 {
      for (i=1; i<=NF; i++) col[$i]=i
      field_known = (field in col)
      next
    }
    field_known && $1==t { count++; value=$col[field] }
    END {
      if (!field_known) { print "EVENT_FIELD_UNKNOWN:" field > "/dev/stderr"; exit 1 }
      if (count == 0)   { print "EVENT_TYPE_UNKNOWN:" t > "/dev/stderr"; exit 1 }
      if (count > 1)    { print "EVENT_TYPE_DUPLICATE:" t > "/dev/stderr"; exit 1 }
      print value
    }
  ' <<<"$tsv"
}

# Last-resort fallback (layer 2 above) when BOTH the materialized
# $RUNTIME_DIR/events.tsv AND a live extractor invocation are unavailable --
# exactly the five rows the gate-1-through-4/HALT call sites need (spec
# §16.1), each value copied verbatim from the Event Contract Registry
# above (BOTH columns -- HALT alone is `proposition_required=yes`, the
# other four are `no`; this is NOT a uniform "no", a code-review-caught bug
# in an earlier draft that would have silently dropped HALT's spec-mandated
# §21.1 proposition-ledger header during a corrupted/partial checkout);
# every other type is a process-definition bug in this state (record_event
# called with no working registry source at all) and fails loudly rather
# than guessing.
_event_contract_field_preboot() {
  local event_type=$1 field=$2 required_fields proposition_required
  case "$event_type" in
    HALT)
      required_fields=""; proposition_required="yes" ;;
    PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE)
      required_fields="run_log_state"; proposition_required="no" ;;
    LOCAL_CLI_CANARIES_PASSED)
      required_fields="codex_present"; proposition_required="no" ;;
    TARGET_DIRTY_TREE_GATE_PASSED)
      required_fields=""; proposition_required="no" ;;
    PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED)
      required_fields="develop_it_dirty;develop_it_dirty_reason"; proposition_required="no" ;;
    *) printf 'EVENT_REGISTRY_MISSING:%s\n' "$event_type" >&2; return 1 ;;
  esac
  case "$field" in
    required_fields)      printf '%s\n' "$required_fields" ;;
    proposition_required) printf '%s\n' "$proposition_required" ;;
    *) printf 'EVENT_FIELD_UNKNOWN:%s\n' "$field" >&2; return 1 ;;
  esac
}

# Usage: event_required_fields EVENT_TYPE. Thin call onto
# event_contract_field for the registry's own `required_fields` column --
# prints the `;`-separated list (possibly empty) on success, or fails with
# event_contract_field's own EVENT_TYPE_UNKNOWN/_DUPLICATE token on stderr.
# `record_event` is the only caller; an unrecognized type fails closed
# rather than silently accepting an unvalidated event.
event_required_fields() {
  event_contract_field "$1" required_fields
}

# Usage: _event_proposition_required EVENT_TYPE. Thin call onto
# event_contract_field for the registry's own `proposition_required` column
# (spec §21.1) -- prints `yes` for exactly the fifteen types the registry
# marks `yes` and `no` for every other registered type (including the eight
# "no live call site yet" rows and the ordinary dispatch-lifecycle/
# preflight-evidence rows), or fails the same way event_required_fields
# does for an unregistered type. `record_event` (below) is the only caller,
# and only ever with a type `event_required_fields` already validated.
_event_proposition_required() {
  event_contract_field "$1" proposition_required
}

# Scans RUN_LOG.md for the highest existing event_id and returns one past it
# -- never clock time, never an in-memory counter. The caller (record_event)
# already holds the run-log lock, so this cannot race another allocation.
_record_event_next_id() {
  local log="${FEATURE_FOLDER:-}/RUN_LOG.md" max=0 n
  if [ -f "$log" ]; then
    while IFS= read -r n; do
      [ "$n" -gt "$max" ] 2>/dev/null && max=$n
    done < <("$GREP_BIN" -oE '^event_id:[[:space:]]+[0-9]+$' "$log" 2>/dev/null \
              | "$GREP_BIN" -oE '[0-9]+$')
  fi
  printf '%d\n' $((max + 1))
}

# The sole canonical RUN_LOG event writer (spec S15.1/S15.3/S15.4). Assigns a
# monotonic event_id, validates the common envelope plus every field the
# Event Contract Registry declares for this type (rejecting anything NOT
# declared, so the block's content can never silently drift from the
# registry), takes the SAME run-log lock every other RUN_LOG writer in this
# document uses (`_run_log_lock_acquire`/`_run_log_lock_release`, defined
# above under "Attempt identity and attempt-scoped paths" -- one mutex for
# every RUN_LOG.md writer, not a second one invented here), appends exactly
# one fixed-order block, and releases. Decisions and corrections (spec
# S15.3/S15.4) are ordinary events under this same mechanism: OWNER_DECISION/
# RISK_ACCEPTED/PHASE_ACCEPTED/EVENT_CORRECTED are rows in the registry
# above like any other type, not a separate function -- RUN_LOG is
# append-only BY CONSTRUCTION here (every path through this function ends in
# `>>`; nothing in this document ever opens RUN_LOG.md for anything else),
# so "correct only by appending EVENT_CORRECTED" falls out for free: there is
# no edit path to forget to avoid.
#
# Usage: record_event EVENT_TYPE KEY=VALUE [KEY=VALUE ...]
# Sets RECORD_EVENT_ID (caller-visible) to the assigned event_id on success.
record_event() {
  local event_type="${1:-}"
  [ -n "$event_type" ] || { echo "RECORD_EVENT_MISSING_TYPE" >&2; return 1; }
  shift
  local required_csv
  required_csv="$(event_required_fields "$event_type")" || return 1
  # The common envelope keys, beyond header event/timestamp (spec S15.1) --
  # a local, not a top-level cookbook constant (this document's cookbook
  # blocks are definitions-only; check_01_lint.sh enforces zero top-level
  # statements in the extracted runtime).
  local common_fields="phase iteration dispatch_id caused_by_event_id authority reason"

  local -A fields=()
  local kv k
  for kv in "$@"; do
    k="${kv%%=*}"
    case " $common_fields " in
      *" $k "*) : ;;
      *)
        case ";$required_csv;" in
          *";$k;"*) : ;;
          *) echo "RECORD_EVENT_UNKNOWN_FIELD:$event_type:$k" >&2; return 1 ;;
        esac ;;
    esac
    fields["$k"]="${kv#*=}"
  done

  local phase="${fields[phase]:-}" iteration="${fields[iteration]:-}"
  local dispatch_id="${fields[dispatch_id]:-}" caused_by="${fields[caused_by_event_id]:-}"
  local authority="${fields[authority]:-process}" reason="${fields[reason]:-}"
  case "$authority" in process|owner|role|system) : ;; *)
    echo "RECORD_EVENT_BAD_AUTHORITY:$authority" >&2; return 1 ;;
  esac
  [ -n "$reason" ] || { echo "RECORD_EVENT_MISSING_REASON:$event_type" >&2; return 1; }

  local -a req_arr=()
  IFS=';' read -r -a req_arr <<<"$required_csv"
  local req
  for req in "${req_arr[@]}"; do
    [ -n "$req" ] || continue
    [ -n "${fields[$req]+x}" ] \
      || { echo "RECORD_EVENT_MISSING_FIELD:$event_type:$req" >&2; return 1; }
  done

  mkdir -p "${ORCHESTRATION_DIR:-$FEATURE_FOLDER/.orchestration}"
  _run_log_lock_acquire || return 1
  local event_id schema
  event_id="$(_record_event_next_id)"
  # Documented exception to "fail loudly, never silently default"
  # (policy_value's own doctrine, "Policy lookup contract" above): unlike
  # every other policy_value call site in this document, record_event's own
  # ATTEMPT_ALLOCATED writer (allocate_attempt, Phase -1) and other early
  # call sites are exercised in real, supported states where $RUNTIME_DIR/
  # policy.tsv is not yet materialized (bootstrap_runtime, gate 5, has not
  # run yet) -- schema=2 is the CURRENT and only schema this document has
  # ever defined (see the "process_schema_version" policy row above), so
  # defaulting to it here is a known, bounded fallback, not a guess.
  schema="$(policy_value process_schema_version 2>/dev/null)"; [ -n "$schema" ] || schema=2
  {
    printf -- '--- %s  event=%s\n' "$(iso_now)" "$event_type"
    printf '%-25s %s\n' "event_id:" "$event_id"
    printf '%-25s %s\n' "process_schema_version:" "$schema"
    printf '%-25s %s\n' "phase:" "$phase"
    printf '%-25s %s\n' "iteration:" "$iteration"
    printf '%-25s %s\n' "dispatch_id:" "$dispatch_id"
    printf '%-25s %s\n' "caused_by_event_id:" "$caused_by"
    printf '%-25s %s\n' "authority:" "$authority"
    printf '%-25s %s\n' "reason:" "$reason"
    for req in "${req_arr[@]}"; do
      [ -n "$req" ] || continue
      printf '%-25s %s\n' "${req}:" "${fields[$req]}"
    done
    printf '\n'
  } >> "$FEATURE_FOLDER/RUN_LOG.md"
  # Step 3: "flushes/fsyncs" -- the SAME fsync helper bootstrap_runtime
  # already uses for its own generated files, reused rather than
  # reinvented; a plain `>>` alone only guarantees libc's buffer was
  # handed to the kernel, not that it survived a crash immediately after.
  _bootstrap_fsync_path "$FEATURE_FOLDER/RUN_LOG.md" 2>/dev/null || true
  # Spec §21.1: an event whose type is `proposition_required=yes` ALSO gets
  # a header-only metadata record appended to pending-propositions.jsonl,
  # under this SAME lock -- so two proposition-required events racing
  # through dispatch_parallel's own forked attempts (Task 6) can never
  # interleave two header lines. `trigger` is the event_type itself (the
  # SAME "trigger tag equals the RUN_LOG event type" convention the
  # pre-existing six-trigger mapping table already uses for CODEX_
  # UNAVAILABLE/CLAUDE_FAILED/HALT/ITERATION_CAP_REACHED/_OVERRIDE);
  # `kind` is always `failure` -- every proposition_required type is an
  # off-nominal signal (a failure, a correction, a cap, a forced
  # degradation acceptance), never a `success`/`idea` entry, which only
  # ever originate from a spontaneous (non-mandatory) append. This header
  # is PENDING, non-authoritative metadata (spec §21.1's own words) --
  # `append_proposition` (below) is what turns it into real coverage.
  local proposition_required
  proposition_required="$(_event_proposition_required "$event_type")"
  if [ "$proposition_required" = yes ]; then
    mkdir -p "${ORCHESTRATION_DIR:-$FEATURE_FOLDER/.orchestration}"
    jq -cn --argjson event_id "$event_id" --arg phase "${phase:-n/a}" \
      --arg kind failure --arg trigger "$event_type" \
      '{event_id:$event_id, phase:$phase, kind:$kind, trigger:$trigger}' \
      >> "${ORCHESTRATION_DIR:-$FEATURE_FOLDER/.orchestration}/pending-propositions.jsonl"
  fi
  _run_log_lock_release
  # shellcheck disable=SC2034  # consumed by the caller after record_event returns
  RECORD_EVENT_ID="$event_id"

  # Code review fix (Task 15 round 2, BLOCKER 1): append_proposition had NO
  # real call site -- the "orchestrator calls it after record_event" prose
  # was unusable for the twelve of these fifteen types that fire from
  # INSIDE cookbook helpers (recovery_retry_allowed's RECOVERY_AUTHORIZED,
  # _dispatch_ingest_result's ATTEMPT_FAILED, ...), where no top-level
  # phase narrative has an "immediately after" moment to hook a manual call
  # onto. Auto-fulfilling HERE, unconditionally, right after the header is
  # durable and the lock is released, is the one real path that reaches
  # every type: this is what makes READY reachable for an ordinary run
  # that hits a retry, a cap, or a correction -- a pending header that
  # nothing ever fulfils otherwise unconditionally blocks readiness
  # (reconcile_propositions' own PROPOSITION_NOT_FULFILLED rule). The
  # entry's body is the event's own `reason` -- genuine, already-vetted
  # text every real call site already supplies (never fabricated, never
  # source/credential material), not a weaker stand-in for orchestrator
  # judgment. Never inside the lock above: append_proposition's own I/O
  # (process-improvement-proposition.md, pending-propositions.jsonl) needs
  # no RUN_LOG mutex, and re-reading RUN_LOG.md here is safe once the
  # event this call just fsynced is durable.
  if [ "$proposition_required" = yes ]; then
    append_proposition "$event_id" failure "$reason" >/dev/null 2>&1 || true
  fi
  # Trade-off, noted rather than silently accepted: auto-fulfilling with
  # `$reason` hollows spec §21.2's three coverage rules toward tautology
  # for these fifteen types, and the orchestrator no longer writes richer,
  # hand-composed prose for them -- ledger quality for FUTURE runs is the
  # cost, never current-run safety (§21.1: pending/fulfilled records never
  # gate the CURRENT run's own decisions; every other §21.2 rule is
  # independent of coverage and stays fully enforced). A later explicit
  # orchestrator call REPLACING the auto entry (instead of duplicating it)
  # was considered and skipped: process-improvement-proposition.md is
  # documented append-only/never-rewritten, and reconcile_propositions'
  # own DUPLICATE_PROPOSITION_COVERAGE check is spec §21.2 case 3's literal
  # text ("duplicate proposition coverage for one event") -- loosening
  # either to allow a second, richer fulfillment is a real design change,
  # not a few-line one.
}

# Parses $FEATURE_FOLDER/RUN_LOG.md's own block grammar (spec S15.1: a
# header line `--- <ISO-ts>  event=<TYPE>` followed by `key:   value` body
# lines, blocks separated by one blank line -- the SAME grammar every
# existing single-field awk reader above already parses one field at a
# time) into one JSON object per block, emitted as JSONL on stdout: every
# body key becomes a string field, verbatim, plus `_type` (the `event=`
# tag). This is the ONLY parser reconcile_propositions/audit_run_state use
# to read RUN_LOG.md -- neither hand-rolls its own block scan, so a future
# change to the block grammar has one parser to update, not two.
_run_log_events_json() {
  # Optional $1 override (Task 6/P04: latest_codex_outcome is the one caller
  # that ever reads a non-default log path, e.g. in tests) -- every other
  # caller passes no argument and gets the usual $FEATURE_FOLDER/RUN_LOG.md.
  local log="${1:-${FEATURE_FOLDER:-}/RUN_LOG.md}"
  [ -f "$log" ] || return 0
  "$PYTHON_BIN" - "$log" <<'PY'
import json, re, sys

HEADER = re.compile(r"^--- [^ ]+  event=([^ ]+)$")
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

# NIT (Task 15 round 2): split on the HEADER LINE ITSELF, never on a blank
# line -- a blank-line split truncates any block whose own multi-line
# `reason` (documented elsewhere as usually one line, but never STRUCTURALLY
# forbidden from carrying more) happens to contain one. A header line can
# only legitimately open a NEW block (record_event never emits one inside a
# value), so anchoring on it is exact regardless of blank lines inside a
# value.
blocks = []
current = None
for line in lines:
    m = HEADER.match(line)
    if m:
        if current is not None:
            blocks.append(current)
        current = {"_type": m.group(1)}
        continue
    if current is None:
        continue
    if not line.strip():
        continue
    if ":" not in line:
        continue
    k, v = line.split(":", 1)
    k = k.strip()
    if not k:
        continue
    v = v.strip()
    # event_id is always a decimal integer (spec S15.1, _record_event_next_
    # id) -- typed as a JSON NUMBER here so every jq comparison against
    # pending-propositions.jsonl's own numeric event_id (and every numeric
    # event_id ordering check below) is a same-type comparison, never a
    # string/number mismatch that silently never matches.
    if k == "event_id" and v.isdigit():
        current[k] = int(v)
    else:
        current[k] = v
if current is not None:
    blocks.append(current)

for rec in blocks:
    print(json.dumps(rec))
PY
}

# Task 6 (P04): the ONE shared reader every "scan RUN_LOG.md for the latest
# relevant event" function below is built on -- dispatch_is_running,
# vendor_proven, context7_policy, _validate_artifact_phase_accepted, and
# latest_codex_outcome each used to hand-roll their own line-by-line (or, for
# vendor_proven, blank-line-split) block scanner, five slightly-different
# grammars for the same file. All five now go through _run_log_events_json
# (above) -- the ONLY parser -- and differ only in the jq SELECT they pass
# here.
#
# Usage: _run_log_latest_event JQ_SELECT [NAME=VALUE...]
#   JQ_SELECT: a jq boolean expression evaluated against each event object
#     (bound to `.`); every NAME=VALUE becomes a `--arg NAME VALUE` binding
#     the expression may reference as `$NAME`. The reserved name `_log`
#     overrides the RUN_LOG.md path passed to _run_log_events_json instead of
#     becoming a jq argument (latest_codex_outcome's own optional LOG
#     parameter is the only caller that uses this).
# RUN_LOG.md is append-only, so file order IS chronological order: this
# prints the LAST (compact, one-line) JSON event object matching JQ_SELECT,
# or nothing with exit 1 when no event matches -- "latest matching event
# wins" is the one semantic every caller below needs, whether "latest" means
# "the current answer" (dispatch_is_running, vendor_proven, context7_policy,
# latest_codex_outcome) or merely "exists at all" (_validate_artifact_phase_
# accepted, which only cares whether the match succeeded).
_run_log_latest_event() {
  local jq_select="$1"; shift
  local log_override="" kv
  local -a jq_args=()
  for kv in "$@"; do
    case "$kv" in
      _log=*) log_override="${kv#_log=}" ;;
      *) jq_args+=(--arg "${kv%%=*}" "${kv#*=}") ;;
    esac
  done
  local hit
  hit="$(_run_log_events_json "$log_override" | jq -c "${jq_args[@]}" "select($jq_select)" 2>/dev/null | tail -n1)"
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# Usage: _run_log_latest_field JQ_SELECT FIELD [NAME=VALUE...]
# Convenience wrapper over _run_log_latest_event: prints just one FIELD of
# the latest matching event (`_type` recovers which event type actually won)
# instead of the whole object. Same exit-1-on-no-match contract.
_run_log_latest_field() {
  local jq_select="$1" field="$2"; shift 2
  local hit
  hit="$(_run_log_latest_event "$jq_select" "$@")" || return 1
  printf '%s' "$hit" | jq -r --arg f "$field" '.[$f] // empty'
}

# Usage: is_retry_within_iteration PHASE ROLE ITERATION
# Mechanizes Trigger #3's own shape test (P18 -- "Mandatory triggers" #3,
# above): true (exit 0) iff RUN_LOG.md shows at least two DISPATCH_STARTED
# entries for this EXACT (phase, role, iteration) triple, with at least one
# DISPATCH_COMPLETED for that same triple carrying a classification other
# than COMPLETED (a failed attempt) -- the exact structural definition
# Trigger #3 documents in prose ("a second dispatch entry whose iteration:
# field is unchanged from the immediately preceding failed dispatch in the
# same phase: AND whose role: matches"). A phase with no iteration loop
# always dispatches at iteration=00 for every attempt, so the exact-iteration
# match here is already the same "role equality is the load-bearing check"
# rule Trigger #3's prose states as a special case for those phases -- no
# separate branch is needed. Returns false (exit 1) on anything short of
# that shape, same boolean-exit convention as `plan_review_window_closed`
# above -- never a printed "yes"/"no" string. Built on the shared
# _run_log_events_json reader (Task 6/P04) -- never a second hand-rolled
# RUN_LOG scanner. Answers ONLY the structural question; the automatic-vs-
# user-authorised distinction Trigger #3's prose also requires stays a
# judgment call the orchestrator makes in the entry body, never mechanized
# here (that distinction is not recoverable from RUN_LOG's structure alone).
is_retry_within_iteration() {
  local phase="$1" role="$2" iteration="$3"
  local iter_padded
  iter_padded="$(printf '%02d' "$((10#$iteration))" 2>/dev/null)" || iter_padded="$iteration"
  local starts failed
  starts="$(_run_log_events_json | jq -s --arg phase "$phase" --arg role "$role" --arg iter "$iter_padded" \
    '[.[] | select(._type=="DISPATCH_STARTED" and .phase==$phase and .role==$role and .iteration==$iter)] | length' 2>/dev/null)"
  [ "${starts:-0}" -ge 2 ] || return 1
  failed="$(_run_log_events_json | jq -s --arg phase "$phase" --arg role "$role" --arg iter "$iter_padded" \
    '[.[] | select(._type=="DISPATCH_COMPLETED" and .phase==$phase and .role==$role and .iteration==$iter and .classification!="COMPLETED")] | length' 2>/dev/null)"
  [ "${failed:-0}" -ge 1 ]
}

# Append-only audit-findings ledger shared by reconcile_propositions and
# audit_run_state (spec §21.2/§20.11): one JSON object per finding,
# `{"check":"<CODE>", "detail":"...", "record_ids":[...]}`. Readiness (Phase
# 11) treats a non-empty ledger as a blocking `NOT_READY` audit, quoting
# each finding's own `record_ids` -- never a prose summary standing in for
# the exact IDs.
_audit_finding() {
  # Usage: _audit_finding CHECK_CODE DETAIL [RECORD_ID...]
  local check="$1" detail="$2"; shift 2
  local ids_json
  if [ "$#" -gt 0 ]; then
    ids_json="$(printf '%s\n' "$@" | jq -R . | jq -s -c .)"
  else
    ids_json='[]'
  fi
  mkdir -p "${ORCHESTRATION_DIR:?}"
  jq -cn --arg check "$check" --arg detail "$detail" --argjson record_ids "$ids_json" \
    '{check:$check, detail:$detail, record_ids:$record_ids}' \
    >> "$ORCHESTRATION_DIR/audit-findings.jsonl"
}

# The orchestrator-only writer that turns ONE pending header into a real,
# durable entry (spec §21.1: "the orchestrator immediately uses that record
# to append one full proposition entry through append_proposition; the
# helper validates the header/event relation before writing"). Never called
# from inside a dispatched role's own appendix -- the SAME rule append_
# followup already documents for followups.jsonl. Refuses to write anything
# unless the header's own `trigger` field agrees with what RUN_LOG.md
# ACTUALLY recorded for that exact event_id, and that recorded type is
# itself `proposition_required=yes` -- a forged or stale header can never
# buy its way into a real entry. On success, appends the entry (using the
# EXACT header/format already documented in "Entry format"/"First-write
# header" below) and a separate fulfillment record
# (`{"event_id":N,"fulfilled_at":<ts>}`) to pending-propositions.jsonl --
# reconcile_propositions' own coverage/staleness checks read that
# fulfillment record, never the prose body this function also writes.
append_proposition() {
  # Usage: append_proposition EVENT_ID KIND BODY
  local event_id="${1:-}" kind="${2:-}" body="${3:-}"
  [ -n "$event_id" ] || { echo "APPEND_PROPOSITION_MISSING_EVENT_ID" >&2; return 1; }
  [ -n "$kind" ] || { echo "APPEND_PROPOSITION_MISSING_KIND" >&2; return 1; }
  local pending="${ORCHESTRATION_DIR:?}/pending-propositions.jsonl"
  [ -f "$pending" ] || { echo "APPEND_PROPOSITION_NO_PENDING_FILE" >&2; return 1; }

  local header
  header="$(jq -c --argjson id "$event_id" 'select(.event_id==$id and has("trigger"))' \
    "$pending" 2>/dev/null | tail -n1)"
  [ -n "$header" ] || { echo "APPEND_PROPOSITION_NO_HEADER:$event_id" >&2; return 1; }
  local phase trigger header_kind
  phase="$(printf '%s' "$header" | jq -r '.phase')"
  trigger="$(printf '%s' "$header" | jq -r '.trigger')"
  header_kind="$(printf '%s' "$header" | jq -r '.kind')"
  # NIT (Task 15 round 2): the caller's own KIND must agree with the
  # header's own auto-recorded kind -- otherwise a caller could file a
  # `HALT` event under `kind: success`, which the Trigger -> kind mapping
  # table (spec's own fixed enum for mandatory entries) never permits.
  [ "$kind" = "$header_kind" ] \
    || { echo "APPEND_PROPOSITION_KIND_MISMATCH:$event_id:$kind!=$header_kind" >&2; return 1; }

  local real_type
  real_type="$(_run_log_events_json | jq -r --argjson id "$event_id" \
    'select(.event_id==$id) | ._type' 2>/dev/null | head -n1)"
  [ -n "$real_type" ] || { echo "APPEND_PROPOSITION_NO_SUCH_EVENT:$event_id" >&2; return 1; }
  [ "$real_type" = "$trigger" ] \
    || { echo "APPEND_PROPOSITION_HEADER_EVENT_MISMATCH:$event_id:$trigger!=$real_type" >&2; return 1; }
  [ "$(_event_proposition_required "$real_type")" = yes ] \
    || { echo "APPEND_PROPOSITION_NOT_MANDATORY:$event_id:$real_type" >&2; return 1; }

  local path="${FEATURE_FOLDER:?}/process-improvement-proposition.md"
  local phase_name
  phase_name="$(_phase_name "$phase" 2>/dev/null)" || phase_name="$phase"
  local entry
  entry="$(printf '## %s — phase %s (%s) — kind: %s — trigger: %s\n\n%s\n' \
    "$(iso_now)" "$phase" "$phase_name" "$kind" "$trigger" "$body")"
  if [ ! -f "$path" ]; then
    {
      printf '%s\n' "# Process improvement propositions"
      printf '\n%s\n' "Auto-generated by the develop-it orchestrator during a real run. Entries here are observations about the develop-it process itself — they are written *during* the current run but only *read* by future runs that want to improve the process file."
      printf '\n%s\n' "The orchestrator never reads back from this file in the current run. Writing here cannot influence current execution."
      printf '\n%s\n' 'Mining for improvement: grep `^## ` for entry headers, `kind: friction` etc. for category filters.'
      printf '\n---\n\n'
      printf '%s\n' "$entry"
    } > "$path"
  else
    printf '\n%s\n' "$entry" >> "$path"
  fi

  jq -cn --argjson event_id "$event_id" --arg fulfilled_at "$(iso_now)" \
    '{event_id:$event_id, fulfilled_at:$fulfilled_at}' >> "$pending"
}

# Structural self-check for a process-improvement-proposition.md file (P17)
# -- pairs this append-only ledger with a validator the same way
# validate_followups/validate_verification_records do for theirs. Parses
# ONLY each entry's own header line (`## <ts> -- phase <N> (<phase_name>)
# -- kind: <kind>[ -- trigger: <TYPE>]`, "Entry format" above), never the
# free-form Context/Proposed improvement body -- a pure shape check, never a
# RUN_LOG cross-reference (that is reconcile_propositions' own job, against
# pending-propositions.jsonl, never this file). Requires the three fields
# ("Entry format" above) present on every entry header, and -- when a
# header carries a `trigger:` tag at all (mandatory entries only; spontaneous
# and deviation entries never do, per "Entry format" above) -- that its value
# is one of the six legal tag values the "Trigger -> kind mapping" table
# documents for the five numbered mandatory triggers (trigger #5 alone
# contributes two: ITERATION_CAP_REACHED and ITERATION_CAP_OVERRIDE).
#
# NEVER call this against the CURRENT run's own in-progress
# process-improvement-proposition.md -- doing so would read the file during
# the very run that is writing it, which the Non-influence guarantee above
# forbids outright regardless of purpose. This function exists for
# offline/maintainer validation of a CLOSED prior run's file (e.g. auditing
# historical runs before changing the Trigger -> kind mapping table); no
# call site in this document's live orchestration flow invokes it against
# $FEATURE_FOLDER's own file, and none should ever be added.
validate_proposition_log() {
  # Usage: validate_proposition_log PROPOSITION_LOG_PATH
  local path="$1"
  [ -f "$path" ] || { echo "validate_proposition_log: missing file: $path" >&2; return 1; }
  "$PYTHON_BIN" - "$path" <<'PY'
import re, sys

path = sys.argv[1]
HEADER = re.compile(
    r'^## (?P<ts>[^ ]+) . phase (?P<phase>[^ ]+) \((?P<phase_name>[^)]+)\) . kind: (?P<kind>[^ ]+)'
    r'(?: . trigger: (?P<trigger>[^ ]+))?$')
LEGAL_TRIGGERS = {"CODEX_UNAVAILABLE", "CLAUDE_FAILED", "RETRY_WITHIN_ITERATION",
                   "HALT", "ITERATION_CAP_REACHED", "ITERATION_CAP_OVERRIDE"}

errors = []
with open(path, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

for lineno, line in enumerate(lines, 1):
    if not line.startswith("## "):
        continue
    m = HEADER.match(line)
    if not m or not (m.group("ts") and m.group("phase") and m.group("kind")):
        errors.append(f"line {lineno}: entry header missing a required field (timestamp/phase/kind): {line!r}")
        continue
    trigger = m.group("trigger")
    if trigger is not None and trigger not in LEGAL_TRIGGERS:
        errors.append(f"line {lineno}: illegal trigger tag {trigger!r} (must be one of {sorted(LEGAL_TRIGGERS)})")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY
}

# Event-ID proposition/event reconciliation (spec §21.2). Reads ONLY
# pending-propositions.jsonl's own headers/fulfillment records and RUN_LOG's
# event envelopes (via _run_log_events_json, above) -- never process-
# improvement-proposition.md's own prose body. Appends one _audit_finding
# per violated rule and returns non-zero iff at least one rule was
# violated; readiness (audit_run_state, below) treats ANY finding as
# blocking. Matches EXACT event ids throughout -- never a time window.
reconcile_propositions() {
  local orch="${ORCHESTRATION_DIR:?}" rc=0
  local pending="$orch/pending-propositions.jsonl"
  [ -f "$pending" ] || : > "$pending"
  local events; events="$(mktemp "$orch/.tmp.reconcile-events.XXXXXX")"
  _run_log_events_json > "$events" 2>/dev/null || true

  # Task 9 perf fix: every rule below used to spawn its own `jq` call PER
  # matching event/header row (O(events) or O(headers) subprocesses each) --
  # rewritten so each rule is exactly one `jq` invocation that joins the
  # whole $events/$pending arrays itself and emits one TSV row per finding
  # (or per row needing a bash-side decision); bash then only loops over
  # jq's OWN output, never over source data. The one registry lookup no
  # rule can safely move into jq (_event_proposition_required, a TSV-backed
  # role/event-contract lookup) is done ONCE per DISTINCT event _type seen
  # in $events -- never once per event -- and the resulting allow-list is
  # handed into every rule's jq program as `--argjson mandatory`.
  local -a mandatory_types=()
  local one_type
  while IFS= read -r one_type; do
    [ -n "$one_type" ] || continue
    [ "$(_event_proposition_required "$one_type")" = yes ] && mandatory_types+=("$one_type")
  done < <(jq -r '._type' "$events" 2>/dev/null | sort -u)
  local mandatory_json
  mandatory_json="$(printf '%s\n' "${mandatory_types[@]+"${mandatory_types[@]}"}" | jq -R . | jq -s -c .)"

  # Rule 1/2/5: every mandatory RUN_LOG event <-> exactly one header, and
  # exactly one fulfillment record (append_proposition's own durable proof
  # a real entry was written) -- zero fulfillments is an incomplete (stale)
  # proposition, e.g. an EVENT_CORRECTED whose own correction was never
  # actually written up; more than one of either is duplicate coverage.
  local id t hc fc
  while IFS=$'\t' read -r id t hc fc; do
    [ -n "$id" ] || continue
    if [ "${hc:-0}" -eq 0 ]; then
      _audit_finding MANDATORY_EVENT_WITHOUT_HEADER \
        "mandatory RUN_LOG event=$t has no proposition header" "event_id:$id"
      rc=1
    elif [ "$hc" -gt 1 ]; then
      _audit_finding DUPLICATE_PROPOSITION_HEADER \
        "mandatory RUN_LOG event=$t has $hc proposition headers, expected exactly one" "event_id:$id"
      rc=1
    fi
    if [ "${fc:-0}" -eq 0 ]; then
      _audit_finding PROPOSITION_NOT_FULFILLED \
        "mandatory RUN_LOG event=$t has a pending header but no fulfilled proposition entry" "event_id:$id"
      rc=1
    elif [ "$fc" -gt 1 ]; then
      _audit_finding DUPLICATE_PROPOSITION_COVERAGE \
        "mandatory RUN_LOG event=$t was fulfilled by more than one proposition entry" "event_id:$id"
      rc=1
    fi
  done < <(jq -r -s --argjson pending "$(jq -c -s '.' "$pending" 2>/dev/null || echo '[]')" \
      --argjson mandatory "$mandatory_json" '
    .[] as $e
    | select($mandatory | index($e._type) != null)
    | ($pending | map(select(.event_id == $e.event_id))) as $hdrs
    | [$e.event_id, $e._type,
       ([$hdrs[] | select(has("trigger"))] | length),
       ([$hdrs[] | select(has("fulfilled_at"))] | length)]
    | @tsv
  ' "$events" 2>/dev/null)

  # Rule 3/4/6: every header names a REAL mandatory event with a matching
  # trigger -- a header whose trigger claims a launched vendor failure
  # (ATTEMPT_FAILED) for an event_id RUN_LOG actually recorded as
  # DISPATCH_NOT_LAUNCHED (a prelaunch defect that never launched anything)
  # is the specific mislabeling spec §21.2 names; any OTHER trigger/type
  # disagreement (e.g. a stale header left over from an EVENT_CORRECTED
  # reclassification) is the generic mismatch case. jq itself resolves each
  # header's real event type (joined against $events by event_id) and
  # picks exactly one of the four outcomes below -- the SAME branch order
  # as the original per-row bash chain (each header contributes at most one
  # finding), so bash only has to route the finding, never decide it.
  local check trig real_type
  while IFS=$'\t' read -r id check trig real_type; do
    [ -n "$id" ] || continue
    case "$check" in
      PROPOSITION_HEADER_WITHOUT_EVENT)
        if [ -z "$real_type" ]; then
          _audit_finding PROPOSITION_HEADER_WITHOUT_EVENT \
            "proposition header names event_id RUN_LOG never recorded" "event_id:$id"
        else
          _audit_finding PROPOSITION_HEADER_WITHOUT_EVENT \
            "proposition header names event_id=$id whose RUN_LOG type ($real_type) is not proposition_required" \
            "event_id:$id"
        fi
        rc=1 ;;
      PRELAUNCH_MISLABELED_AS_VENDOR_FAILURE)
        _audit_finding PRELAUNCH_MISLABELED_AS_VENDOR_FAILURE \
          "proposition claims a launched vendor failure (ATTEMPT_FAILED) for event_id=$id, which RUN_LOG records as DISPATCH_NOT_LAUNCHED" \
          "event_id:$id"
        rc=1 ;;
      PROPOSITION_HEADER_TRIGGER_MISMATCH)
        _audit_finding PROPOSITION_HEADER_TRIGGER_MISMATCH \
          "proposition header trigger ($trig) does not match event_id=$id's own recorded type ($real_type)" \
          "event_id:$id"
        rc=1 ;;
    esac
  done < <(jq -r -s --slurpfile events "$events" --argjson mandatory "$mandatory_json" '
    .[] | select(has("trigger")) as $h
    | ($events | map(select(.event_id == $h.event_id)) | .[0]._type // "") as $real_type
    | if ($real_type == "") then
        [$h.event_id, "PROPOSITION_HEADER_WITHOUT_EVENT", $h.trigger, $real_type]
      elif ($h.trigger == "ATTEMPT_FAILED" and $real_type == "DISPATCH_NOT_LAUNCHED") then
        [$h.event_id, "PRELAUNCH_MISLABELED_AS_VENDOR_FAILURE", $h.trigger, $real_type]
      elif ($mandatory | index($real_type) == null) then
        [$h.event_id, "PROPOSITION_HEADER_WITHOUT_EVENT", $h.trigger, $real_type]
      elif ($h.trigger != $real_type) then
        [$h.event_id, "PROPOSITION_HEADER_TRIGGER_MISMATCH", $h.trigger, $real_type]
      else empty
      end
    | @tsv
  ' "$pending" 2>/dev/null)

  # Rule 7: a retry/continuation attempt (dispatch_id's own attempt suffix
  # >= 2) must have a causal RECOVERY_AUTHORIZED for the SAME logical
  # dispatch, recorded strictly BEFORE the retry's own DISPATCH_STARTED
  # event_id -- never merely present somewhere in the run. `dispatch_id //
  # ""` before `capture(...)?` guards the same fault-isolation class as the
  # EVENT_CORRECTED rule below: `capture` on a bare `null` (a DISPATCH_
  # STARTED record missing its own dispatch_id field) is ALSO a fatal jq
  # error, not a silent non-match -- a plain string that just doesn't match
  # the regex is the only case `capture` fails open on by itself.
  local sid did logi
  while IFS=$'\t' read -r sid did logi; do
    [ -n "$sid" ] || continue
    _audit_finding RETRY_WITHOUT_RECOVERY_AUTHORIZED \
      "dispatch_id=$did is a continuation attempt with no causal RECOVERY_AUTHORIZED for logical_dispatch_id=$logi" \
      "event_id:$sid" "dispatch_id:$did"
    rc=1
  done < <(jq -r -s '
    (map(select(._type=="RECOVERY_AUTHORIZED"))) as $auths
    | .[] | select(._type=="DISPATCH_STARTED") as $s
    | ((($s.dispatch_id // "") | capture("-a(?<n>[0-9]{2})$")?).n) as $attn
    | select($attn != null and ($attn|tonumber) >= 2)
    | select([$auths[] | select(.logical_dispatch_id == $s.logical_dispatch_id and .event_id < $s.event_id)] | length == 0)
    | [$s.event_id, $s.dispatch_id, $s.logical_dispatch_id]
    | @tsv
  ' "$events" 2>/dev/null)

  # §21.2 case 6: "an event correction not reflected in the final
  # classification" -- EVENT_CORRECTED.replacement_classification must
  # actually govern what happens NEXT for the corrected dispatch, not just
  # sit in RUN_LOG as an unconsumed claim. Re-derive what SHOULD happen via
  # the SAME recovery_action helper a live run itself uses (fed the
  # REPLACEMENT classification and the corrected attempt's own already-
  # recorded mutation_state -- mutation_state is a property of the repo at
  # attempt time, unaffected by a later classification correction) and
  # check RUN_LOG's actual downstream history against it. Read-only: two of
  # recovery_action's own branches (PRELAUNCH_FAILED, SPEND_CEILING) emit
  # their OWN record_event side effects, which a deterministic audit must
  # never trigger -- corrections reclassifying to either are skipped here
  # (a correction that drastic needs human review, not automated
  # recomputation), never silently mis-evaluated as some OTHER action.
  # recovery_action is real bash business logic (a state matrix), not a jq
  # expression -- it stays a per-record call below -- but every OTHER field
  # this rule needs (the corrected dispatch's own id/mutation_state/logical
  # id, and whether a later DISPATCH_STARTED exists) is resolved by ONE jq
  # join first, so nothing here spawns jq per correction any more.
  #
  # Fault isolation (code review fix): `corrected_event_id // ""` and
  # `tonumber?` guard against a malformed/missing field -- `startswith`/
  # `tonumber` on a bare `null` or non-numeric string are FATAL jq errors,
  # not a per-record skip, and in a single -s (slurp) pass a fatal error
  # aborts the WHOLE invocation, silently discarding every finding for
  # every OTHER (well-formed) record already queued behind it in the
  # stream -- not just the one malformed record the original per-record
  # bash loop would have `continue`d past. `tonumber?` on a non-numeric
  # `$xid_raw` (or `""`) yields no value at all for that record, and
  # `select($xid != null)` then drops it cleanly, same as the original's
  # `[ -n "$xdid" ] || continue`.
  local cid xid rclass xmut xlogical later_cnt raction
  while IFS=$'\t' read -r cid xid rclass xmut xlogical later_cnt; do
    [ -n "$cid" ] || continue
    recovery_action "$rclass" "$xmut" "$xlogical" >/dev/null 2>&1
    raction="$RECOVERY_ACTION"
    [ -n "$raction" ] || continue
    case "$raction" in
      CONTINUE_WITHIN_CAP|TRANSIENT_RETRY|RETRY_PUBLICATION|CORRECT_AND_RETRY| \
      RECONCILE_THEN_CONTINUE_IF_ISOLATED|RECONCILE_THEN_CONTINUE_IF_SAFE)
        if [ "${later_cnt:-0}" -eq 0 ]; then
          _audit_finding EVENT_CORRECTION_NOT_REFLECTED \
            "correction event_id=$cid reclassifies event_id=$xid as $rclass (action=$raction, implies a continuation), but no later DISPATCH_STARTED exists for logical_dispatch_id=$xlogical" \
            "event_id:$cid" "corrected_event_id:$xid"
          rc=1
        fi
        ;;
      HALT_OR_DEGRADE|HALT_EXACT_STATE|HALT_INTEGRITY|WAIT_FOR_OWNER| \
      SUPPRESS_VENDOR_HALT_OR_DEGRADE|BRANCH_ON_VERDICT| \
      RECONCILE_BLOCKED_NOT_ISOLATED|RECONCILE_UNKNOWN_NO_LOGICAL_ID)
        if [ "${later_cnt:-0}" -gt 0 ]; then
          _audit_finding EVENT_CORRECTION_NOT_REFLECTED \
            "correction event_id=$cid reclassifies event_id=$xid as $rclass (action=$raction, implies no further automatic attempt), but a later DISPATCH_STARTED exists for logical_dispatch_id=$xlogical" \
            "event_id:$cid" "corrected_event_id:$xid"
          rc=1
        fi
        ;;
    esac
  done < <(jq -r -s '
    (map(select(._type=="DISPATCH_COMPLETED"))) as $completed
    | . as $all
    | .[] | select(._type=="EVENT_CORRECTED") as $ec
    | ($ec.corrected_event_id // "") as $xid_raw
    | select(($xid_raw | startswith("finding:")) | not)
    | ($ec.replacement_classification) as $rclass
    | select(($rclass == "PRELAUNCH_FAILED" or $rclass == "SPEND_CEILING") | not)
    | ($xid_raw | tonumber?) as $xid
    | select($xid != null)
    | ([$all[] | select(.event_id == $xid) | .dispatch_id // empty] | first // empty) as $xdid
    | select($xdid != "")
    | ([$completed[] | select(.dispatch_id == $xdid) | .mutation_state // empty] | first // empty) as $xmut
    | select($xmut != "")
    | ($xdid | sub("-a[0-9][0-9]$"; "")) as $xlogical
    | ([$all[] | select(._type=="DISPATCH_STARTED" and .logical_dispatch_id==$xlogical and .event_id > $ec.event_id)] | length) as $later_cnt
    | [$ec.event_id, $xid, $rclass, $xmut, $xlogical, $later_cnt]
    | @tsv
  ' "$events" 2>/dev/null)

  # Rule 8: exactly one completion block (DISPATCH_COMPLETED or
  # DISPATCH_NOT_LAUNCHED) per dispatch id that ever started.
  local d_id cnt
  while IFS=$'\t' read -r d_id cnt; do
    [ -n "$d_id" ] || continue
    if [ "$cnt" -eq 0 ]; then
      _audit_finding DISPATCH_COMPLETION_MISSING \
        "dispatch_id=$d_id started but has no completion record" "dispatch_id:$d_id"
    else
      _audit_finding DISPATCH_COMPLETION_DUPLICATE \
        "dispatch_id=$d_id has $cnt completion records, expected exactly one" "dispatch_id:$d_id"
    fi
    rc=1
  done < <(jq -r -s '
    (map(select(._type=="DISPATCH_STARTED" and .dispatch_id != "") | .dispatch_id) | unique) as $started
    | (map(select(._type=="DISPATCH_COMPLETED" or ._type=="DISPATCH_NOT_LAUNCHED"))) as $completions
    | $started[] as $d
    | ([$completions[] | select(.dispatch_id == $d)] | length) as $cnt
    | select($cnt != 1)
    | [$d, $cnt]
    | @tsv
  ' "$events" 2>/dev/null)

  rm -f "$events"
  return "$rc"
}

# The full spec §20.11/§21.2 readiness audit. Appends its OWN findings to
# the SAME audit-findings.jsonl reconcile_propositions writes to (calling
# it as one of its own clauses, never re-deriving event/proposition
# reconciliation a second way), and additionally verifies runtime/process
# identity, dispatch quiescence, lease clearance, explicit phase-acceptance
# revisions, review-gate disposition, verification results, documentation
# outputs, the follow-up ledger, context7 precedence, and the Phase 10
# result. Returns non-zero iff any clause found a problem; Phase 11 reads
# audit-findings.jsonl afterward for the exact record IDs.
audit_run_state() {
  local orch="${ORCHESTRATION_DIR:?}" rc=0
  local events; events="$(mktemp "$orch/.tmp.audit-events.XXXXXX")"
  _run_log_events_json > "$events" 2>/dev/null || true

  # Runtime manifest still verifies (Task 3 seam) -- a manifest that
  # verified once at bootstrap but was tampered with since is exactly what
  # this re-check at readiness time exists to catch.
  if [ -n "${RUNTIME_DIR:-}" ] && declare -F _bootstrap_verify_manifest >/dev/null 2>&1; then
    _bootstrap_verify_manifest "$RUNTIME_DIR" \
      || { _audit_finding RUNTIME_MANIFEST_INVALID "runtime manifest failed verification" "runtime:$RUNTIME_DIR"; rc=1; }
  fi

  # Process identity: every DISPATCH_COMPLETED this run wrote must carry
  # the SAME develop_it_file_sha256 -- more than one distinct value means
  # the process file was silently swapped mid-run. Names the CONFLICTING
  # event_ids (MINOR fix, Task 15 round 2): "count:N" alone named neither
  # the sha values nor which dispatches disagreed -- Step 5 requires the
  # conflicting record IDs, not just a tally.
  # Task 9 perf fix: the conflict set is every DISPATCH_COMPLETED with a
  # non-empty sha (that is exactly what the old per-distinct-sha loop's
  # union worked out to, one jq spawn per distinct value) -- one jq call
  # gets there directly.
  local sha_count distinct_shas cid
  local -a conflict_ids
  distinct_shas="$(jq -r 'select(._type=="DISPATCH_COMPLETED") | .develop_it_file_sha256 // empty' \
    "$events" 2>/dev/null | sed '/^$/d' | sort -u)"
  sha_count="$(printf '%s\n' "$distinct_shas" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "${sha_count:-0}" -gt 1 ]; then
    conflict_ids=()
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      conflict_ids+=("event_id:$cid")
    done < <(jq -r 'select(._type=="DISPATCH_COMPLETED" and (.develop_it_file_sha256 // "") != "") | .event_id' \
      "$events" 2>/dev/null)
    _audit_finding PROCESS_IDENTITY_MISMATCH \
      "more than one develop_it_file_sha256 recorded across this run's dispatches ($sha_count distinct values)" \
      "${conflict_ids[@]}"
    rc=1
  fi

  # Every attempt classified, no dangling completion block, mandatory
  # events/propositions reconcile by exact event id -- reconcile_
  # propositions' own job; never re-derived here.
  reconcile_propositions || rc=1

  # "All attempts classified" (spec §20.11), taken literally (code review
  # fix, Task 15 round 2): reconcile_propositions only counts that a
  # completion BLOCK exists per dispatch id, never that its own
  # `classification` field is one of classify_attempt's legal values. A
  # blank or corrupted classification on an otherwise-present
  # DISPATCH_COMPLETED slips through that count untouched.
  local unclassified_ids ucid
  unclassified_ids="$(jq -r 'select(._type=="DISPATCH_COMPLETED") |
    select(.classification=="" or (.classification|IN(
      "COMPLETED","TIMED_OUT","PRELAUNCH_FAILED","EXITED_NO_STATUS","MALFORMED_STATUS",
      "UNKNOWN_VENDOR_ERROR","SPEND_CEILING","PERMANENT_VENDOR_ERROR",
      "TRANSIENT_TRANSPORT_ERROR","PUBLICATION_LOST")|not)) | .event_id' \
    "$events" 2>/dev/null)"
  while IFS= read -r ucid; do
    [ -n "$ucid" ] || continue
    _audit_finding ATTEMPT_NOT_CLASSIFIED \
      "DISPATCH_COMPLETED event_id=$ucid carries no legal classify_attempt classification" \
      "event_id:$ucid"
    rc=1
  done <<<"$unclassified_ids"

  # No RUNNING_OBSERVED / ORPHANED_UNOBSERVED dispatch left behind.
  local logi state
  while IFS= read -r logi; do
    [ -n "$logi" ] || continue
    state="$(resume_dispatch_state "$logi" 2>/dev/null)"
    case "$state" in
      RUNNING_OBSERVED|ORPHANED_UNOBSERVED)
        _audit_finding DISPATCH_NOT_QUIESCED \
          "logical_dispatch_id=$logi is still $state at readiness time" "logical_dispatch_id:$logi"
        rc=1 ;;
    esac
  done < <(jq -r '.logical_dispatch_id // empty' "$events" 2>/dev/null | sed '/^$/d' | sort -u)

  # No active write lease remains. Names the exact holder (MINOR fix, Task
  # 15 round 2): "lease_state:$lease_state" alone named a CLASSIFICATION,
  # never a record id -- Step 5 requires the conflicting record IDs. The
  # lease file itself carries lease_owner/dispatch_id even when malformed
  # enough to fail _write_lease_state's own JSON checks (jq -r with a `//
  # empty` fallback degrades to an empty string rather than erroring), so
  # both are always at least attempted.
  local lease_state lease_file lease_owner lease_dispatch
  lease_file="$orch/write-lease.json"
  lease_state="$(_write_lease_state "$lease_file" 2>/dev/null)"
  if [ "$lease_state" != NO_LEASE ]; then
    lease_owner="$(jq -r '.lease_owner // empty' "$lease_file" 2>/dev/null)"
    lease_dispatch="$(jq -r '.dispatch_id // empty' "$lease_file" 2>/dev/null)"
    _audit_finding WRITE_LEASE_REMAINS \
      "a write lease remains at readiness time ($lease_state)" \
      "lease_owner:${lease_owner:-unknown}" "dispatch_id:${lease_dispatch:-none}"
    rc=1
  fi

  # RUN_LOG checkpoints and Git snapshots agree (spec §20.11's final
  # clause), taken as existence/well-formedness of the two durable
  # artifacts each DISPATCH record itself names -- the minimal, real
  # reading available without re-deriving checkpoint semantics a second
  # time (checkpoint_resume_state already owns that): a completed
  # checkpointed attempt whose own progress ledger vanished, or a started
  # mutating attempt whose own declared snapshot manifest vanished, is
  # exactly the kind of "RUN_LOG says X exists, the filesystem disagrees"
  # split this clause exists to catch.
  # Task 9 perf fix: field extraction (event_id/checkpoint_kind/status_path)
  # is now ONE upstream jq pass emitting TSV rows -- the per-row `jq empty
  # "$cp_path"` call that follows is irreducible (it validates the actual
  # progress.jsonl FILE's own bytes, external to $events, one real file per
  # checkpointed dispatch), not the events x rules pattern this task targets.
  local cp_id cp_kind cp_status cp_dir cp_path
  while IFS=$'\t' read -r cp_id cp_kind cp_status; do
    [ -n "$cp_id" ] || continue
    case "$cp_kind" in ""|none) continue ;; esac
    [ -n "$cp_status" ] || continue
    cp_dir="$(dirname "$cp_status")"
    cp_path="$cp_dir/progress.jsonl"
    if [ ! -f "$cp_path" ]; then
      _audit_finding CHECKPOINT_MALFORMED \
        "DISPATCH_COMPLETED event_id=$cp_id declares checkpoint_kind=$cp_kind but $cp_path does not exist" \
        "event_id:$cp_id"
      rc=1
    elif ! jq empty "$cp_path" >/dev/null 2>&1 && [ -s "$cp_path" ]; then
      _audit_finding CHECKPOINT_MALFORMED \
        "DISPATCH_COMPLETED event_id=$cp_id's own progress.jsonl at $cp_path is not valid JSONL" \
        "event_id:$cp_id"
      rc=1
    fi
  done < <(jq -r 'select(._type=="DISPATCH_COMPLETED") |
    [.event_id, (.checkpoint_kind // ""), (.status_path // "")] | @tsv' "$events" 2>/dev/null)

  local snap_id snap_path
  while IFS=$'\t' read -r snap_id snap_path; do
    [ -n "$snap_id" ] || continue
    case "$snap_path" in ""|none) continue ;; esac
    [ -f "$snap_path" ] || {
      _audit_finding SNAPSHOT_MISSING \
        "DISPATCH_STARTED event_id=$snap_id declares snapshot=$snap_path but the manifest file does not exist" \
        "event_id:$snap_id"
      rc=1
    }
  done < <(jq -r 'select(._type=="DISPATCH_STARTED") |
    [.event_id, (.snapshot // "")] | @tsv' "$events" 2>/dev/null)

  # Every explicit PHASE_ACCEPTED decision's own artifact_revision matches
  # the STATUS the accepted dispatch actually published. This is the ONE
  # place this audit reads a STATUS file: spec §21.1's metadata-only
  # restriction binds reconcile_propositions' own proposition-coverage
  # checks above, not this separate spec §20.11 "every accepted output ...
  # matches its recorded revision" clause, which names STATUS revisions
  # explicitly. status_path is read straight off the accepted dispatch's
  # OWN durable DISPATCH_COMPLETED event -- never re-derived from a role
  # name this event does not carry.
  # Task 9 perf fix: the per-row extraction AND the status_path cross-
  # reference (originally its own jq spawn per PHASE_ACCEPTED row) are now
  # one upstream jq join over $events; only `status_field` (a real STATUS-
  # file parse, external to $events) remains per row.
  local pid pdid parev stat_path stat_rev
  while IFS=$'\t' read -r pid pdid parev stat_path; do
    [ -n "$pid" ] || continue
    # spec §20.11's "every accepted output EXISTS" leg (MAJOR fix, Task 15
    # round 2): a missing status_path field or a status_path whose file was
    # deleted/never written is itself the violation -- silently `continue`-
    # ing here let an accepted phase with no real evidence pass clean.
    if [ -z "$stat_path" ] || [ ! -f "$stat_path" ]; then
      _audit_finding ACCEPTED_OUTPUT_MISSING \
        "PHASE_ACCEPTED event_id=$pid names dispatch_id=$pdid whose own STATUS file (${stat_path:-<no status_path recorded>}) does not exist" \
        "event_id:$pid" "dispatch_id:$pdid"
      rc=1
      continue
    fi
    stat_rev="$(status_field "$stat_path" artifact_revision 2>/dev/null)"
    if [ "$parev" != "$stat_rev" ]; then
      _audit_finding PHASE_ACCEPTED_REVISION_MISMATCH \
        "PHASE_ACCEPTED event_id=$pid declares artifact_revision=$parev but dispatch_id=$pdid's own STATUS carries ${stat_rev:-<missing>}" \
        "event_id:$pid" "dispatch_id:$pdid"
      rc=1
    fi
  done < <(jq -r -s '
    (map(select(._type=="DISPATCH_COMPLETED"))) as $completed
    | .[] | select(._type=="PHASE_ACCEPTED") as $pa
    | ($pa.dispatch_id // "") as $pdid
    | ($pa.artifact_revision // "") as $parev
    | select($pdid != "" and $parev != "")
    | ([$completed[] | select(.dispatch_id == $pdid) | .status_path // ""] | first // "") as $stat_path
    | [$pa.event_id, $pdid, $parev, $stat_path]
    | @tsv
  ' "$events" 2>/dev/null)

  # Review caps respected (spec §20.11), as its OWN check (code review fix,
  # Task 15 round 2): the BLOCKING_FINDING_UNRESOLVED scan below only
  # catches a cap blown while a finding is STILL open -- it says nothing
  # about a cap reached and then silently continued past with every
  # finding dispositioned but NO recorded authorization for having gone
  # past the cap at all. Every ITERATION_CAP_REACHED needs a LATER (higher
  # event_id) ITERATION_CAP_OVERRIDE for the SAME phase_name, or a later
  # HALT (the gate stopped instead of silently continuing) -- one of the
  # two is the durable trail spec §18.2's "no unreviewed final fix, no
  # silent cap bypass" discipline requires.
  # Task 9 perf fix: one jq pass computes both later-override/later-HALT
  # counts per ITERATION_CAP_REACHED event (previously two jq spawns PER
  # row) and emits only the rows that actually violate the rule.
  local cap_id cap_phase
  while IFS=$'\t' read -r cap_id cap_phase; do
    [ -n "$cap_id" ] || continue
    _audit_finding REVIEW_CAP_NOT_RESPECTED \
      "event_id=$cap_id reached the review_iteration_cap for phase_name=$cap_phase with neither a later ITERATION_CAP_OVERRIDE nor a later HALT" \
      "event_id:$cap_id"
    rc=1
  done < <(jq -r -s '
    . as $all
    | .[] | select(._type=="ITERATION_CAP_REACHED") as $cap
    | ($cap.phase_name // "") as $phase
    | ([$all[] | select(._type=="ITERATION_CAP_OVERRIDE" and .phase_name==$phase and .event_id > $cap.event_id)] | length) as $ov
    | ([$all[] | select(._type=="HALT" and .event_id > $cap.event_id)] | length) as $ha
    | select($ov == 0 and $ha == 0)
    | [$cap.event_id, $phase]
    | @tsv
  ' "$events" 2>/dev/null)

  # Blocking findings resolved by a later review -- the LAST iteration
  # directory of each review gate.
  local gate_dir last_iter catalog fid
  for gate_dir in 3-spec-review 5-plan-review 7-code-review; do
    [ -d "$FEATURE_FOLDER/$gate_dir" ] || continue
    last_iter="$(find "$FEATURE_FOLDER/$gate_dir" -maxdepth 1 -type d -regextype posix-extended \
      -regex '.*/[0-9]{2}' 2>/dev/null | sort | tail -n1)"
    [ -n "$last_iter" ] || continue
    catalog="$last_iter/findings-catalog.jsonl"
    [ -f "$catalog" ] || continue
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      _audit_finding BLOCKING_FINDING_UNRESOLVED \
        "finding $fid in $gate_dir is open/reopened and undispositioned at readiness time" "finding_id:$fid"
      rc=1
    done < <(jq -r 'select((.status=="open" or .status=="reopened") and
                            (.severity=="blocker" or .severity=="major")) | .finding_id' \
      "$catalog" 2>/dev/null)
  done

  # Required verification PASS or approved EXCLUDED (validate_verification_
  # records already enforces per-record structure; this adds the readiness-
  # time check that no verification_id's LATEST outcome is a plain FAIL).
  local vfile vid
  for vfile in "$FEATURE_FOLDER"/8-all-tests/*/verification-records.jsonl; do
    [ -f "$vfile" ] || continue
    validate_verification_records "$vfile" >/dev/null 2>&1 \
      || { _audit_finding VERIFICATION_RECORDS_MALFORMED "verification records failed structural validation" "$vfile"; rc=1; }
    while IFS= read -r vid; do
      [ -n "$vid" ] || continue
      _audit_finding VERIFICATION_NOT_PASS "verification $vid's latest recorded result is FAIL" "verification_id:$vid"
      rc=1
    done < <(jq -s -r 'group_by(.verification_id) | map(last) | .[] | select(.result=="FAIL") | .verification_id' \
      "$vfile" 2>/dev/null)
  done

  # Documentation accepted: the three required Phase 9 outputs exist.
  local doc
  for doc in uat.md planned-vs-realized.md documentation-validation.md; do
    [ -f "$FEATURE_FOLDER/9-documentation/$doc" ] || {
      _audit_finding DOCUMENTATION_OUTPUT_MISSING "required documentation output is missing" \
        "9-documentation/$doc"
      rc=1
    }
  done

  # Followups valid (P17): the real validate_followups cookbook function --
  # the same structural gate validate_verification_records performs for its
  # own ledger, catching the five required-non-empty-text fields the
  # per-id scan below (retained for its own exact-id naming) never checks.
  if [ -f "$FEATURE_FOLDER/followups.jsonl" ]; then
    validate_followups "$FEATURE_FOLDER/followups.jsonl" >/dev/null 2>&1 \
      || { _audit_finding FOLLOWUPS_MALFORMED "followups.jsonl failed structural validation" "$FEATURE_FOLDER/followups.jsonl"; rc=1; }
  fi

  # Followups valid: well-formed, legal status, unique id (reuses the same
  # field list/status enum append_followup itself enforces on write; this
  # re-validates the ledger as a whole at readiness time, naming the exact
  # offending id).
  if [ -f "$FEATURE_FOLDER/followups.jsonl" ]; then
    local bad_id
    while IFS= read -r bad_id; do
      [ -n "$bad_id" ] || continue
      _audit_finding FOLLOWUP_INVALID "followups.jsonl record fails validation" "id:$bad_id"
      rc=1
    done < <("$PYTHON_BIN" - "$FEATURE_FOLDER/followups.jsonl" <<'PY'
import json, sys
seen = set()
FIELDS = ("id","origin_phase","origin_finding","description","actor",
          "prerequisite","risk","status","evidence")
LEGAL = {"open", "deferred", "accepted_risk", "resolved"}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except json.JSONDecodeError:
        print("malformed-line")
        continue
    fid = r.get("id", "malformed")
    if any(f not in r for f in FIELDS) or r.get("status") not in LEGAL or fid in seen:
        print(fid)
        continue
    seen.add(fid)
PY
)
  fi

  # Latest context7 event overrides earlier reachability: delegate to the
  # existing, already-tested context7_policy reader (its own contract
  # already implements "latest RUN_LOG event wins"). context7_policy's OWN
  # only failure mode is "no evidence either way: refuse to guess" (no
  # Phase 1 STATUS AND no RUN_LOG event) -- a run that reached Phase 11 is
  # expected to have durable Phase 1 evidence, so THAT failure, here, is a
  # genuine integrity gap worth a finding, not a discarded return code
  # (code review fix, Task 15 round 2: the previous form called this and
  # threw away both stdout and rc, so it could never fail).
  if declare -F context7_policy >/dev/null 2>&1; then
    if ! context7_policy >/dev/null 2>"$orch/.tmp.context7.err"; then
      # Names the concrete missing artifact as the record id (code review
      # fix, round 3: "phase:1" was a phase label, not a record id -- the
      # SAME gap already fixed for WRITE_LEASE_REMAINS/PROCESS_IDENTITY_
      # MISMATCH). context7_policy's own only failure mode is a total
      # absence of evidence, so there is no conflicting EVENT to name;
      # the concrete, dereferenceable thing IS the status path it looked
      # for and did not find -- the same "missing path as record id"
      # convention DOCUMENTATION_OUTPUT_MISSING already uses above.
      _audit_finding CONTEXT7_POLICY_UNRESOLVED \
        "context7_policy could not resolve a policy from durable evidence at readiness time" \
        "1-preflight/phase-1/claude-check-status.md"
      rc=1
    fi
    rm -f "$orch/.tmp.context7.err"
  fi

  # Phase 10 result valid: exactly the LATEST GIT_FINALIZATION_RESULT event,
  # never missing or FAILED. BLOCKED is a valid, non-blocking degradation --
  # Phase 11's own terminal-verdict rule downgrades it to READY_WITH_NOTES,
  # this audit does not fail on it.
  local gfr outcome gid
  gfr="$(jq -c 'select(._type=="GIT_FINALIZATION_RESULT")' "$events" 2>/dev/null | tail -n1)"
  if [ -z "$gfr" ]; then
    _audit_finding GIT_FINALIZATION_MISSING "no event=GIT_FINALIZATION_RESULT is durable in RUN_LOG.md" "phase:10"
    rc=1
  else
    outcome="$(printf '%s' "$gfr" | jq -r '.outcome // empty')"
    if [ "$outcome" = FAILED ]; then
      gid="$(printf '%s' "$gfr" | jq -r '.event_id')"
      _audit_finding GIT_FINALIZATION_FAILED "Phase 10 git finalization outcome is FAILED" "event_id:$gid"
      rc=1
    fi
  fi

  rm -f "$events"
  return "$rc"
}

# Repository-containment check for one DECLARED_PATH (repo-relative; an
# absolute input is rejected outright). realpath -m (no existence
# requirement) rather than `canon`'s realpath -e: a declared write path may
# name a file this attempt is about to CREATE, which does not exist yet.
#
# Gap (P25/Task 11, compressed -- full rationale in _snapshot_capture's own
# comment below, same gap): verified correct, but UNREACHABLE today -- every
# live caller declares only "." (whole repo, trivially contained). A future
# per-role narrower-path registry column is the reactivation trigger; this
# function needs no change when that lands.
_write_lease_path_ok() {
  local repo="$1" p="$2" resolved
  case "$p" in /*) return 1 ;; esac
  resolved="$(realpath -m -- "$repo/$p" 2>/dev/null)" || return 1
  path_in_tree "$resolved" "$repo"
}

# Fine-grained classification of an EXISTING write-lease.json (spec S11.3's
# four resume substates, plus ambiguous/malformed/absent). Never mutates the
# file; never reclaims a lease. Reuses the SAME durable dispatch-lifecycle
# evidence `resume_dispatch_state` already reads (`dispatch_is_running`,
# `_dispatch_child_live`, `_dispatch_last_event_for_id`,
# `_dispatch_completed_field`) rather than inventing a second liveness
# signal for the lease file to carry.
#
# Code review fix #1: `dispatch_parallel`'s own Phase 2 (lease acquisition)
# runs sequentially, BEFORE any child is forked in Phase 3 -- so at the
# instant a losing sibling's own acquire attempt runs, the winner's lease
# exists but its DISPATCH_STARTED does not yet (that is written from inside
# the forked child, immediately before invoke_vendor). Treating that gap as
# AMBIGUOUS_LEASE turned "ordinary same-batch contention" (this document's
# own words, "Unified attempt dispatch" above) into an ARTIFACT_INTEGRITY_
# BLOCKED alarm and an RM03 HALT instead of RM02's WAIT_FOR_OWNER -- verified
# live before this fix. The WRITE_LEASE_STARTUP_GRACE_SECONDS window below
# (default 30s, env-overridable like BOOTSTRAP_ORPHAN_AGE_SECONDS) is what
# tells "no DISPATCH_STARTED yet because the owner just started" from "no
# DISPATCH_STARTED and never will be, because something died before it
# could write one": within the grace window, no evidence at all is treated
# as the owner still being between acquire and launch (ACTIVE); past it, the
# silence itself becomes the ambiguity signal.
_write_lease_state() {
  # Usage: _write_lease_state [lease_file]
  local lease_file="${1:-${ORCHESTRATION_DIR:-}/write-lease.json}"
  [ -f "$lease_file" ] || { echo NO_LEASE; return 0; }
  jq empty "$lease_file" >/dev/null 2>&1 || { echo MALFORMED_LEASE; return 0; }
  local dispatch_id authority acquired_at acquired_epoch_stored
  dispatch_id="$(jq -r '.dispatch_id // empty' "$lease_file" 2>/dev/null)"
  authority="$(jq -r '.authority // empty' "$lease_file" 2>/dev/null)"
  acquired_at="$(jq -r '.acquired_at // empty' "$lease_file" 2>/dev/null)"
  acquired_epoch_stored="$(jq -r '.acquired_epoch // empty' "$lease_file" 2>/dev/null)"
  case "$authority" in role|orchestrator) : ;; *) echo MALFORMED_LEASE; return 0 ;; esac

  if [ -z "$dispatch_id" ] || [ "$dispatch_id" = null ]; then
    # Phase 10 direct orchestrator finalization: no dispatch id to check
    # liveness against. Its mere presence blocks a second mutating writer
    # for as long as it exists -- treated as active until explicitly
    # released.
    echo ACTIVE_LEASE_OWNER
    return 0
  fi

  if dispatch_is_running "$dispatch_id"; then
    if _dispatch_child_live "$dispatch_id"; then
      echo ACTIVE_LEASE_OWNER
    else
      echo ORPHANED_UNOBSERVED_OWNER
    fi
    return 0
  fi

  case "$(_dispatch_last_event_for_id "$dispatch_id")" in
    DISPATCH_COMPLETED)
      if [ "$(_dispatch_completed_field "$dispatch_id" classification)" = COMPLETED ]; then
        echo COMPLETED_LOST_RELEASE
      else
        echo OBSERVED_FAILED_OWNER
      fi
      ;;
    "")
      local now acquired_epoch age
      now="$(date +%s)"
      # Prefer the epoch stamped at acquisition time (no reparse needed).
      # Fall back to the GNU-only `date -d` parse only for leases written
      # before acquired_epoch existed.
      if [ -n "$acquired_epoch_stored" ] && [ "$acquired_epoch_stored" != null ]; then
        acquired_epoch="$acquired_epoch_stored"
      else
        acquired_epoch="$(date -u -d "$acquired_at" +%s 2>/dev/null)"
      fi
      if [ -n "$acquired_epoch" ]; then
        age=$((now - acquired_epoch))
      else
        age=-1
      fi
      if [ "$age" -ge 0 ] && [ "$age" -le "${WRITE_LEASE_STARTUP_GRACE_SECONDS:-30}" ]; then
        echo ACTIVE_LEASE_OWNER
      else
        echo AMBIGUOUS_LEASE
      fi
      ;;
    *)
      echo AMBIGUOUS_LEASE ;;
  esac
}

# Folds the fine-grained classification above into the two-value vocabulary
# recovery_action's PRELAUNCH_FAILED branch routes on (spec S14.3, RM02 vs
# RM03): every non-live substate is treated identically -- never reclaimed
# automatically, always routed to RM03's HALT for integrity reconciliation.
_write_lease_recovery_state() {
  case "$1" in
    ACTIVE_LEASE_OWNER|NO_LEASE) echo "$1" ;;
    *) echo STALE_OR_AMBIGUOUS_LEASE ;;
  esac
}

# Every currently-dirty repo-relative path, for the lease JSON's own
# declared_foreign_paths (spec S10.4's "declared foreign changes", which a
# continuation's isolation check later reads back) -- captured fresh ONLY
# on a dispatch's FIRST attempt, and durably persisted there (below) so
# every LATER attempt for the SAME logical dispatch can carry it FORWARD
# instead of re-deriving it. Code review fix (round 2): a 2nd-or-later
# attempt must not re-derive from the CURRENT tree at all -- the current
# tree may already carry the prior, dying attempt's own uncheckpointed
# mutation, and re-deriving would launder that into "foreign" (round 1's
# bug). But discarding the declaration outright (returning `[]` for every
# continuation, round 1's own fix) over-corrects: it also discards
# genuinely pre-existing foreign dirt that attempt 1 legitimately declared,
# capping every continuation on a non-pristine tree at 1 regardless of the
# policy's own continuation_cap. Carrying attempt 1's OWN durable
# declaration forward is the precise fix -- it was captured before ANY
# attempt (including attempt 1 itself) had a chance to mutate anything, so
# it can never contain a dying attempt's own leftover work, and it still
# preserves real pre-run dirt across every continuation. checkpoint_
# partial_isolated separately tolerates the checkpoint's own declared
# dirty-unit artifact_path regardless of this list's contents. The fixed
# orchestration-bookkeeping paths (RUN_LOG.md/full_log.md/$ORCHESTRATION_DIR/
# transcripts//attempts/ subtrees -- the SAME allow-list _mutation_dirty and
# checkpoint_partial_isolated already use) are excluded from the fresh
# capture: they are never "foreign", they are this process's own
# bookkeeping.
#
# _is_orchestration_bookkeeping_path is the shared predicate for that
# allow-list, reused verbatim by checkpoint_partial_isolated below --
# _mutation_dirty's own copy is deliberately left as its own local closure
# (see its comment): refactoring it carries real regression risk for a
# property this pair is the only other consumer of.
_is_orchestration_bookkeeping_path() {
  # Usage: _is_orchestration_bookkeeping_path PATH FF_REL ORCH_REL
  local path="$1" ff_rel="$2" orch_rel="$3"
  case "$path" in
    "$ff_rel/RUN_LOG.md"|"$ff_rel/full_log.md") return 0 ;;
    # Task 15 round 2 fix: record_event's auto-fulfilled proposition ledger
    # is never a role's own mutation -- same orchestrator-bookkeeping
    # exclusion _mutation_dirty's own copy needs.
    "$ff_rel/process-improvement-proposition.md") return 0 ;;
    "$orch_rel"|"$orch_rel"/*) return 0 ;;
    "$ff_rel/transcripts"|"$ff_rel/transcripts"/*) return 0 ;;
    "$ff_rel"/*/attempts/*) return 0 ;;
  esac
  return 1
}

# Usage: _write_lease_foreign_paths_now DISPATCH_ID
_write_lease_foreign_paths_now() {
  local dispatch_id="${1:-}" attempt_num logical carry_file
  attempt_num="$(printf '%s\n' "$dispatch_id" | "$GREP_BIN" -oE '[0-9]{2}$')"
  if [ -n "$attempt_num" ] && [ "$((10#$attempt_num))" -gt 1 ]; then
    logical="${dispatch_id%-a[0-9][0-9]}"
    carry_file="${ORCHESTRATION_DIR:-}/snapshots/${logical}-a01/declared-foreign-paths.json"
    if [ -f "$carry_file" ]; then
      cat "$carry_file"
    else
      echo '[]'
    fi
    return 0
  fi
  local ff_rel orch_rel
  ff_rel="${FEATURE_FOLDER#"${REPO_ROOT:-}"/}"
  orch_rel="${ORCHESTRATION_DIR#"${REPO_ROOT:-}"/}"
  local entry status path out=()
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"; path="${entry:3}"
    _is_orchestration_bookkeeping_path "$path" "$ff_rel" "$orch_rel" && continue
    out+=("$path")
    case "$status" in R*|C*) IFS= read -r -d '' _ || true ;; esac
  done < <(git -C "${REPO_ROOT:-}" status --porcelain=v1 --untracked-files=all -z 2>/dev/null)
  local result
  if [ "${#out[@]}" -gt 0 ]; then
    result="$(printf '%s\n' "${out[@]}" | jq -R . | jq -s -c .)"
  else
    result='[]'
  fi
  # Durable so a LATER continuation (above) can carry it forward instead of
  # re-deriving from a tree its own dying predecessor has since mutated.
  # Lives under the SAME never-deleted snapshots/ directory acquire_write_
  # lease already creates for this exact dispatch_id (_snapshot_capture,
  # below) -- one more small file there, not a new durable-storage location.
  if [ -n "$dispatch_id" ]; then
    mkdir -p "${ORCHESTRATION_DIR:-}/snapshots/$dispatch_id" 2>/dev/null
    printf '%s\n' "$result" > "${ORCHESTRATION_DIR:-}/snapshots/$dispatch_id/declared-foreign-paths.json" 2>/dev/null || true
  fi
  printf '%s\n' "$result"
}

# Exclusive creation of $ORCHESTRATION_DIR/write-lease.json (spec S11.1).
# Usage: acquire_write_lease OWNER AUTHORITY DISPATCH_ID PHASE DECLARED_PATH...
# OWNER is the lease_owner (a role name, or "orchestrator-finalization" for
# direct Phase 10 mutation); AUTHORITY is "role" or "orchestrator";
# DISPATCH_ID is the dispatch id string, or empty for Phase 10 (recorded as
# JSON null). PHASE is a REQUIRED, explicit parameter (code review fix #2):
# an earlier revision read an undeclared AMBIENT $phase, which happened to
# exist only because dispatch_parallel's own caller declares a `local phase`
# -- correct by accident there, but silently "phase":"" for any other
# caller (Phase 10 finalization included, the exact case spec Step 5's own
# JSON example spells out as "phase":"10"). Every DECLARED_PATH is verified
# contained in $REPO_ROOT before anything is written. Refuses an active,
# malformed, stale, or ambiguous existing lease -- and for anything other
# than a genuinely live owner, additionally emits ARTIFACT_INTEGRITY_BLOCKED
# and returns failure without ever launching a second writer (spec S11.1's
# own words).
acquire_write_lease() {
  if [ "$#" -lt 4 ]; then
    echo "WRITE_LEASE_USAGE:acquire_write_lease OWNER AUTHORITY DISPATCH_ID PHASE DECLARED_PATH..." >&2
    return 1
  fi
  local owner="$1" authority="$2" dispatch_id="$3" phase="$4"; shift 4
  local -a declared=("$@")
  case "$authority" in role|orchestrator) : ;; *)
    echo "WRITE_LEASE_BAD_AUTHORITY:$authority" >&2; return 1 ;;
  esac
  [ -n "$owner" ] || { echo "WRITE_LEASE_BAD_OWNER" >&2; return 1; }

  local p
  for p in "${declared[@]}"; do
    _write_lease_path_ok "${REPO_ROOT:?}" "$p" \
      || { echo "WRITE_LEASE_PATH_NOT_CONTAINED:$p" >&2; return 1; }
  done

  mkdir -p "${ORCHESTRATION_DIR:?}"
  local lease_file="$ORCHESTRATION_DIR/write-lease.json"
  local key manifest_dir
  key="${dispatch_id:-$owner}"
  manifest_dir="$ORCHESTRATION_DIR/snapshots/$key"
  mkdir -p "$manifest_dir"

  local dispatch_id_json declared_json baseline_head tmp
  if [ -n "$dispatch_id" ]; then dispatch_id_json="$(jq -Rn --arg v "$dispatch_id" '$v')"
  else dispatch_id_json=null; fi
  baseline_head="$(git -C "${REPO_ROOT:-}" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "${#declared[@]}" -gt 0 ]; then
    # ponytail: a declared path containing an embedded newline splits into
    # two JSON array entries here (printf-then-jq-per-line has no other way
    # to frame a path list). Every real caller today only ever declares "."
    # (dispatch_parallel's own lease-phase call, below) -- a literal that
    # can never contain a newline -- so this is a real but currently
    # unreachable gap, not a live one; revisit with NUL-delimited framing if
    # a future per-role path column ever lets a caller declare a real,
    # attacker-influenceable path.
    declared_json="$(printf '%s\n' "${declared[@]}" | jq -R . | jq -s .)"
  else
    declared_json='[]'
  fi

  # declared_foreign_paths (Task 9 seam, closed across two review rounds:
  # round 1 caught unfiltered capture laundering a dying continuation-
  # predecessor's own uncheckpointed mutation into "foreign"; round 2 caught
  # that fix over-correcting to `[]` on every continuation, which also
  # discarded genuinely pre-existing foreign dirt and capped continuation_
  # cap at 1 on any non-pristine tree). `_write_lease_foreign_paths_now`
  # (above) now captures real pre-existing dirt fresh ONLY on a dispatch's
  # first attempt (excluding this process's own bookkeeping paths), persists
  # THAT declaration durably, and every later attempt for the same logical
  # dispatch carries it forward unchanged -- see its own doc comment for the
  # full rationale. declared_foreign_commits stays `[]`: this process never
  # has more than one lease/writer at a time, so there is no OTHER actor's
  # commit for a fresh acquisition to declare against baseline_head -- an
  # honest empty default, not a guessed value.
  local foreign_paths_json
  foreign_paths_json="$(_write_lease_foreign_paths_now "$dispatch_id")"

  # acquired_epoch is captured from the SAME `date` invocation family as
  # acquired_at, once, here -- so the read side (`_write_lease_state`) never
  # has to reparse the formatted timestamp with GNU-only `date -d` (that
  # reparse silently failed on non-GNU `date`, reproducing the exact false
  # AMBIGUOUS_LEASE this lease-startup-grace machinery exists to prevent).
  # Leases written before this field existed fall back to the old parse.
  tmp="$ORCHESTRATION_DIR/.write-lease.tmp.$BASHPID.$RANDOM"
  jq -n \
    --argjson schema_version 2 --argjson dispatch_id "$dispatch_id_json" \
    --arg lease_owner "$owner" --arg authority "$authority" --arg phase "$phase" \
    --arg acquired_at "$(iso_now)" --argjson acquired_epoch "$(date +%s)" \
    --arg baseline_head "$baseline_head" \
    --argjson declared_write_paths "$declared_json" \
    --argjson declared_foreign_paths "$foreign_paths_json" --argjson declared_foreign_commits '[]' \
    --arg snapshot_manifest_path "$manifest_dir/manifest.json" \
    '{schema_version:$schema_version, dispatch_id:$dispatch_id, lease_owner:$lease_owner,
      authority:$authority, phase:$phase, acquired_at:$acquired_at,
      acquired_epoch:$acquired_epoch,
      baseline_head:$baseline_head, declared_write_paths:$declared_write_paths,
      declared_foreign_paths:$declared_foreign_paths,
      declared_foreign_commits:$declared_foreign_commits,
      snapshot_manifest_path:$snapshot_manifest_path}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; echo "WRITE_LEASE_BUILD_FAILED" >&2; return 1; }

  if ln "$tmp" "$lease_file" 2>/dev/null; then
    rm -f "$tmp"
    _snapshot_capture before "$owner" "$dispatch_id" "$manifest_dir/manifest.json" "${declared[@]}"
    record_event WRITE_LEASE_ACQUIRED lease_owner="$owner" lease_authority="$authority" \
      dispatch_id="$dispatch_id" phase="$phase" \
      authority="$([ "$authority" = orchestrator ] && echo system || echo role)" \
      reason="write lease acquired"
    return 0
  fi
  rm -f "$tmp"

  local fine
  fine="$(_write_lease_state "$lease_file")"
  case "$(_write_lease_recovery_state "$fine")" in
    ACTIVE_LEASE_OWNER)
      echo "WRITE_LEASE_ACTIVE:$fine" >&2 ;;
    *)
      echo "WRITE_LEASE_BLOCKED:$fine" >&2
      record_event ARTIFACT_INTEGRITY_BLOCKED lease_owner="$owner" \
        dispatch_id="$dispatch_id" phase="$phase" \
        reason="write lease blocked: existing lease is $fine" >/dev/null 2>&1 || true
      ;;
  esac
  return 1
}

# Removes ONLY an exact, valid owner match (spec S11.3). A missing lease,
# malformed JSON, or a lease held by someone else is refused, never forced --
# the caller (dispatch_parallel/_dispatch_launch_attempt) only ever calls
# this for a lease IT itself just acquired, so any mismatch here is a real
# integrity signal, not routine contention. Captures the "after" snapshot
# (spec S11.2) before the lease file itself disappears, once the classified
# outcome is already durable (the caller's own attempt-result write already
# happened by this point -- see the section intro above).
release_write_lease() {
  # Usage: release_write_lease OWNER
  local owner="${1:-}" lease_file="${ORCHESTRATION_DIR:?}/write-lease.json"
  [ -n "$owner" ] || { echo "WRITE_LEASE_BAD_OWNER" >&2; return 1; }
  [ -f "$lease_file" ] || { echo "WRITE_LEASE_NOT_HELD:$owner" >&2; return 1; }
  jq empty "$lease_file" >/dev/null 2>&1 \
    || { echo "WRITE_LEASE_MALFORMED:$owner" >&2; return 1; }
  local held_owner dispatch_id manifest_path
  held_owner="$(jq -r '.lease_owner // empty' "$lease_file" 2>/dev/null)"
  if [ "$held_owner" != "$owner" ]; then
    echo "WRITE_LEASE_NOT_OWNER:$owner:$held_owner" >&2
    return 1
  fi
  dispatch_id="$(jq -r '.dispatch_id // empty' "$lease_file" 2>/dev/null)"
  manifest_path="$(jq -r '.snapshot_manifest_path // empty' "$lease_file" 2>/dev/null)"
  [ -n "$manifest_path" ] && _snapshot_capture after "$owner" "$dispatch_id" "$manifest_path"
  rm -f "$lease_file"
  record_event WRITE_LEASE_RELEASED lease_owner="$owner" dispatch_id="$dispatch_id" \
    reason="write lease released"
}

# Captures a before/after JSON snapshot manifest at $4 (spec S11.2): HEAD,
# the full `git status --porcelain=v1 -z` tree state, hashes/blob IDs and a
# copy of every existing declared artifact, process identity, the active
# allow-list, known foreign changes, and the capture timestamp. "before" and
# "after" share ONE manifest file (a top-level key each), so a later
# authorized scoped-recovery read (spec S11.2/S11.3) sees both sides
# together. Diagnostic and scoped-recovery input ONLY -- this document never
# reads its own output back to perform an automatic rollback.
#
# Gap (P25/Task 11, compressed): the per-artifact hash/copy branch below IS
# fully implemented and unit-tested (tests/check_06_cookbook.sh), but is
# UNREACHABLE today -- same as `_write_lease_path_ok` above, every live
# caller declares only "." (whole repo). HEAD plus the porcelain status line
# still cover a "." declaration's integrity need. Reactivation trigger: a
# future per-role narrower-path registry column; nothing here needs to
# change when that lands. `declared_foreign_paths` in the write-lease JSON
# (acquire_write_lease, above) IS populated today (`_write_lease_foreign_
# paths_now`) -- see that function's own comment for why `declared_foreign_
# commits` stays `[]` rather than a second gap.
_snapshot_capture() {
  # Usage: _snapshot_capture before|after OWNER DISPATCH_ID MANIFEST_PATH [DECLARED_PATH...]
  local stage="$1" owner="$2" dispatch_id="$3" manifest="$4"; shift 4
  local -a declared=("$@")
  mkdir -p "$(dirname "$manifest")" 2>/dev/null
  local head status_z artifacts_json="[]" p h copies_dir
  head="$(git -C "${REPO_ROOT:-}" rev-parse HEAD 2>/dev/null || echo none)"
  status_z="$(git -C "${REPO_ROOT:-}" status --porcelain=v1 -z 2>/dev/null | tr '\0' '\n')"
  copies_dir="$(dirname "$manifest")/$stage"
  for p in "${declared[@]}"; do
    [ "$p" = "." ] && continue
    [ -f "${REPO_ROOT:-}/$p" ] || continue
    h="$(git -C "${REPO_ROOT:-}" hash-object -- "$p" 2>/dev/null)"
    [ -n "$h" ] || h="$(sha256sum "${REPO_ROOT:-}/$p" 2>/dev/null | cut -d' ' -f1)"
    mkdir -p "$copies_dir/$(dirname "$p")" 2>/dev/null
    cp -p "${REPO_ROOT:-}/$p" "$copies_dir/$p" 2>/dev/null || true
    artifacts_json="$(printf '%s' "$artifacts_json" \
      | jq --arg p "$p" --arg h "${h:-}" '. + [{"path":$p,"blob":$h}]' 2>/dev/null)"
    [ -n "$artifacts_json" ] || artifacts_json="[]"
  done
  # The SAME fixed allow-list _mutation_dirty (above) already scans against
  # -- reused, not re-invented, and recorded here so the manifest is
  # self-describing about which changes are bookkeeping, never content.
  local ff_rel orch_rel allow_list_json
  ff_rel="${FEATURE_FOLDER#"${REPO_ROOT:-}"/}"
  orch_rel="${ORCHESTRATION_DIR#"${REPO_ROOT:-}"/}"
  allow_list_json="$(jq -n --arg a "$ff_rel/RUN_LOG.md" --arg b "$ff_rel/full_log.md" \
    --arg c "$orch_rel" --arg d "$ff_rel/transcripts" \
    '[$a, $b, $c, $d]')"
  # "Known foreign changes" (spec S11.2): whatever was ALREADY dirty before
  # this attempt acquired its lease is, by definition, not this attempt's
  # own doing -- the prior "before" stage's own status line IS that record;
  # only the "after" stage carries it; "before" has no earlier stage to cite.
  local foreign_json='null'
  local prior="{}"
  if [ "$stage" = after ] && [ -f "$manifest" ]; then
    prior="$(cat "$manifest" 2>/dev/null)"
    [ -n "$prior" ] || prior="{}"
    foreign_json="$(printf '%s' "$prior" | jq '.before.status // null')"
  fi
  jq -n \
    --arg stage "$stage" --arg owner "$owner" --arg dispatch_id "${dispatch_id:-}" \
    --arg head "$head" --arg status "$status_z" --argjson artifacts "$artifacts_json" \
    --arg process_git_head "${PROCESS_GIT_HEAD:-}" --arg process_file_sha256 "${PROCESS_FILE_SHA256:-}" \
    --arg process_dirty "${PROCESS_DIRTY:-}" --arg captured_at "$(iso_now)" --argjson prior "$prior" \
    --argjson allow_list "$allow_list_json" --argjson foreign_changes "$foreign_json" \
    '$prior + {($stage): {stage:$stage, owner:$owner, dispatch_id:$dispatch_id, head:$head,
      status:$status, artifacts:$artifacts, process_git_head:$process_git_head,
      process_file_sha256:$process_file_sha256, process_dirty:$process_dirty,
      allow_list:$allow_list, foreign_changes:$foreign_changes,
      captured_at:$captured_at}}' > "$manifest.tmp.$$" 2>/dev/null \
    && mv "$manifest.tmp.$$" "$manifest" \
    || rm -f "$manifest.tmp.$$"
}

# Usage: acquire_test_lease OWNER PHASE
acquire_test_lease() {
  local owner="${1:-}" phase="${2:-}"
  [ -n "$owner" ] || { echo "TEST_LEASE_BAD_OWNER" >&2; return 1; }
  mkdir -p "${ORCHESTRATION_DIR:?}"
  local lease_file="$ORCHESTRATION_DIR/test-lease.json"
  local timeout="${TEST_LEASE_WAIT_TIMEOUT_SECONDS:-120}" \
    interval="${TEST_LEASE_POLL_INTERVAL_SECONDS:-5}" waited=0 tmp
  while :; do
    tmp="$ORCHESTRATION_DIR/.test-lease.tmp.$BASHPID.$RANDOM"
    jq -n --arg owner "$owner" --arg phase "$phase" --arg acquired_at "$(iso_now)" \
      --argjson acquired_epoch "$(date +%s)" \
      '{lease_owner:$owner, phase:$phase, acquired_at:$acquired_at, acquired_epoch:$acquired_epoch}' \
      > "$tmp" 2>/dev/null || { rm -f "$tmp"; echo "TEST_LEASE_BUILD_FAILED" >&2; return 1; }
    if ln "$tmp" "$lease_file" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    [ "$waited" -ge "$timeout" ] && break
    sleep "$interval"
    waited=$((waited + interval))
  done
  # No dispatch-liveness classification exists for this lock (see the
  # section prose above) -- unlike a stuck write-lease, an orphaned
  # test-lease has no automatic reclaim path, so the HALT message itself
  # IS the recovery documentation: name the file, the owner who holds it
  # (best-effort re-read; the file may already be gone by the time this
  # prints, in which case "unknown" is honest, not a bug), and the manual
  # remedy, so an operator is never left to discover `rm test-lease.json`
  # by reading this cookbook.
  local blocked_owner
  blocked_owner="$(jq -r '.lease_owner // empty' "$lease_file" 2>/dev/null)"
  echo "TEST_LEASE_BLOCKED:$lease_file owner=${blocked_owner:-unknown} -- if that owner's dispatch/process is no longer running, remove this file and retry" >&2
  return 1
}

# Usage: release_test_lease OWNER
release_test_lease() {
  local owner="${1:-}" lease_file="${ORCHESTRATION_DIR:?}/test-lease.json"
  [ -n "$owner" ] || { echo "TEST_LEASE_BAD_OWNER" >&2; return 1; }
  [ -f "$lease_file" ] || { echo "TEST_LEASE_NOT_HELD:$owner" >&2; return 1; }
  local held_owner
  held_owner="$(jq -r '.lease_owner // empty' "$lease_file" 2>/dev/null)"
  [ "$held_owner" = "$owner" ] || { echo "TEST_LEASE_NOT_OWNER:$owner:$held_owner" >&2; return 1; }
  rm -f "$lease_file"
}

# The sole canonical checkpoint writer (spec S10.1). Validates the common
# envelope's required fields, then -- code review fix -- runs the SAME
# strict `checkpoint_resume_state` parser resume reads use to determine
# what "last" means, rather than a separate lenient scanner: an existing
# malformed/discontinuous suffix now genuinely REFUSES the append (spec
# S10.1's "cannot authorize automatic continuation" protects writes too,
# not just resume reads -- a lenient scanner that silently skipped a
# truncated line let a new record build on top of it undetected). The
# required sequence is exactly `last + 1` (contiguous, never merely
# increasing) so a write can never itself create the gap resume-side
# validation would later reject. Appends exactly one JSON object per line
# under a lock scoped to THIS progress_path (`_run_log_lock_acquire`'s own
# optional-lockfile-argument form, "Attempt identity" above) -- a genuinely
# per-file lock, reusing the existing `ln` primitive rather than inventing
# a second one.
#
# Task 9 performance fix: a full `checkpoint_resume_state` re-scan on EVERY
# append is O(n) per call (a `git cat-file`/`git merge-base` per commit-
# bearing record, a `sha256sum` per artifact record) -- O(n^2) subprocess
# spawns by the end of an n-record run. `PROGRESS_PATH.cursor` is a sidecar
# written after every successful append recording {dispatch_id, byte_offset,
# sha256} for the file AS OF that append. On the next append, trust it ONLY
# when: the cursor's own dispatch_id matches this call's, the file's CURRENT
# size equals the recorded byte_offset exactly, AND the file's CURRENT
# sha256 equals the recorded one -- i.e. the file is byte-for-byte what it
# was the instant we last fully validated it (checkpoint_append is the SOLE
# writer of this file, so "unchanged bytes" means "still exactly as valid as
# it was"). That is the entire integrity signal: two O(1)-subprocess checks
# (`wc -c`, one `sha256sum`) standing in for the O(n) re-validation. The
# cursor's own numeric fields are never trusted directly for "what is the
# last sequence" -- that is always re-read fresh off the file's OWN trailing
# record once the hash check passes, so a cursor whose sha256/byte_offset
# happen to still match but whose OTHER fields were hand-edited can't lie
# about the sequence. ANY mismatch (missing cursor, wrong dispatch_id, size
# mismatch, hash mismatch, an unparseable cursor, an unparseable trailing
# record) drops straight through to the original full-scan path below --
# never a partial trust, never a best-effort guess. Resume-time validation
# (`checkpoint_resume_state`, called directly by recovery/reconstruction
# code) is untouched by any of this and always re-scans the whole file.
#
# Usage: checkpoint_append PROGRESS_PATH DISPATCH_ID ROLE KEY=VALUE...
# Required KEY=VALUE fields: sequence, unit_type, unit_id, state,
# artifact_path, artifact_sha256, commit_sha, verification, next_unit.
# Optional: finding_ids (a JSON array literal; default []).
checkpoint_append() {
  local progress_path="$1" dispatch_id="$2" role="$3"; shift 3
  [ -n "$progress_path" ] && [ -n "$dispatch_id" ] && [ -n "$role" ] \
    || { echo "CHECKPOINT_APPEND_USAGE" >&2; return 1; }
  local -A f=()
  local kv k
  for kv in "$@"; do
    k="${kv%%=*}"
    f["$k"]="${kv#*=}"
  done
  local req
  for req in sequence unit_type unit_id state artifact_path artifact_sha256 \
             commit_sha verification next_unit; do
    [ -n "${f[$req]+x}" ] || { echo "CHECKPOINT_APPEND_MISSING_FIELD:$req" >&2; return 1; }
  done
  case "${f[sequence]}" in
    ''|*[!0-9]*) echo "CHECKPOINT_APPEND_BAD_SEQUENCE:${f[sequence]}" >&2; return 1 ;;
  esac

  mkdir -p "$(dirname "$progress_path")" 2>/dev/null
  local lockfile="$progress_path.lock"
  _run_log_lock_acquire "$lockfile" || return 1
  local last=0
  if [ -f "$progress_path" ]; then
    local cursor_path="$progress_path.cursor" cursor_trusted=0
    if [ -f "$cursor_path" ]; then
      local cur_dispatch cur_offset cur_stored_sha cur_size
      cur_dispatch="$(jq -r '.dispatch_id // empty' "$cursor_path" 2>/dev/null)"
      cur_offset="$(jq -r '.byte_offset // empty' "$cursor_path" 2>/dev/null)"
      cur_stored_sha="$(jq -r '.sha256 // empty' "$cursor_path" 2>/dev/null)"
      cur_size="$(wc -c < "$progress_path" 2>/dev/null | tr -d ' ')"
      if [ "$cur_dispatch" = "$dispatch_id" ] && [ -n "$cur_offset" ] \
         && [ "$cur_offset" = "$cur_size" ] && [ -n "$cur_stored_sha" ]; then
        local cur_real_sha
        cur_real_sha="$(sha256sum "$progress_path" 2>/dev/null | cut -d' ' -f1)"
        [ -n "$cur_real_sha" ] && [ "$cur_real_sha" = "$cur_stored_sha" ] && cursor_trusted=1
      fi
    fi
    if [ "$cursor_trusted" -eq 1 ]; then
      # The cursor's own hash checked out: the file is byte-identical to the
      # instant it was last fully validated (VALID by construction -- see
      # comment above), so it's still VALID now. The last sequence is still
      # re-derived fresh from the file's OWN trailing record, never trusted
      # off the cursor's own (separately editable) fields.
      local _cur_last_line _cur_last_seq
      _cur_last_line="$(tail -n 1 "$progress_path" 2>/dev/null)"
      _cur_last_seq="$(printf '%s' "$_cur_last_line" | jq -r '.sequence // empty' 2>/dev/null)"
      case "$_cur_last_seq" in
        ''|*[!0-9]*) cursor_trusted=0 ;;
        *) last="$_cur_last_seq" ;;
      esac
    fi
    if [ "$cursor_trusted" -ne 1 ]; then
      # Run checkpoint_resume_state inside a SUBSHELL (command substitution),
      # not directly: it sets the CHECKPOINT_* globals, and this is only an
      # INTERNAL lookup of "what sequence/state is this file at", not the
      # caller's own resume-state call -- calling it directly would clobber
      # whatever a caller (e.g. recovery_action, just before deciding to
      # continue) already had in those same globals (code review fix: latent
      # today since every real call site is a role subprocess with nothing
      # else reading them, but real the moment an orchestrator-side caller
      # runs both in one shell). A subshell's own variable assignments never
      # escape it, so this reads the two values it needs off stdout instead.
      local _resume_line _resume_state _resume_seq _resume_reason
      _resume_line="$(checkpoint_resume_state "$progress_path" "$dispatch_id"         && printf '%s	%s	%s' "$CHECKPOINT_STATE" "$CHECKPOINT_LAST_SEQUENCE" "$CHECKPOINT_BAD_REASON")"
      IFS=$'	' read -r _resume_state _resume_seq _resume_reason <<<"$_resume_line"
      if [ "$_resume_state" = NEEDS_RECONCILIATION ]; then
        _run_log_lock_release "$lockfile"
        echo "CHECKPOINT_APPEND_NEEDS_RECONCILIATION:$_resume_reason" >&2
        return 1
      fi
      last="${_resume_seq:-0}"
    fi
  fi
  if [ "${f[sequence]}" -ne $((last + 1)) ]; then
    _run_log_lock_release "$lockfile"
    echo "CHECKPOINT_SEQUENCE_NOT_INCREASING:${f[sequence]}!=$((last + 1))" >&2
    return 1
  fi
  local finding_ids="${f[finding_ids]:-[]}"
  local record
  # -c (compact): this is JSONL -- exactly one line per record. jq -n's
  # default pretty-printed multi-line output would silently shred the
  # "one record per line" invariant checkpoint_resume_state's own reader
  # depends on.
  record="$(jq -cn \
    --argjson schema_version 2 --arg dispatch_id "$dispatch_id" \
    --argjson sequence "${f[sequence]}" --arg role "$role" \
    --arg unit_type "${f[unit_type]}" --arg unit_id "${f[unit_id]}" \
    --arg state "${f[state]}" --arg artifact_path "${f[artifact_path]}" \
    --arg artifact_sha256 "${f[artifact_sha256]}" --arg commit_sha "${f[commit_sha]}" \
    --argjson finding_ids "$finding_ids" --arg verification "${f[verification]}" \
    --arg next_unit "${f[next_unit]}" --arg timestamp "$(iso_now)" \
    '{schema_version:$schema_version, dispatch_id:$dispatch_id, sequence:$sequence,
      role:$role, unit_type:$unit_type, unit_id:$unit_id, state:$state,
      artifact_path:$artifact_path, artifact_sha256:$artifact_sha256,
      commit_sha:$commit_sha, finding_ids:$finding_ids, verification:$verification,
      next_unit:$next_unit, timestamp:$timestamp}' 2>/dev/null)"
  if [ -z "$record" ]; then
    _run_log_lock_release "$lockfile"
    echo "CHECKPOINT_APPEND_BUILD_FAILED" >&2
    return 1
  fi
  printf '%s\n' "$record" >> "$progress_path"
  _bootstrap_fsync_path "$progress_path" 2>/dev/null || true
  # Refresh the cursor unconditionally -- whether THIS call trusted a prior
  # cursor or fell back to a full scan, the file is now freshly known-VALID,
  # so every append self-heals the sidecar for the next one. Best-effort: a
  # failure to write it costs a future full scan, never correctness (the
  # trust check above fails closed on a missing/stale cursor either way).
  local new_size new_sha
  new_size="$(wc -c < "$progress_path" 2>/dev/null | tr -d ' ')"
  new_sha="$(sha256sum "$progress_path" 2>/dev/null | cut -d' ' -f1)"
  if [ -n "$new_size" ] && [ -n "$new_sha" ]; then
    jq -cn --arg dispatch_id "$dispatch_id" --argjson byte_offset "$new_size" \
      --arg sha256 "$new_sha" \
      '{dispatch_id:$dispatch_id, byte_offset:$byte_offset, sha256:$sha256}' \
      > "$progress_path.cursor" 2>/dev/null || true
  fi
  _run_log_lock_release "$lockfile"
}

# Parses PROGRESS_PATH in strict order and validates every record BEFORE
# treating it as part of the resumable prefix (spec S10.1: "cannot authorize
# automatic continuation until an integrity check resolves it"). Never
# mutates the file. Sets, always: CHECKPOINT_STATE (NO_CHECKPOINT / VALID /
# NEEDS_RECONCILIATION), CHECKPOINT_LAST_SEQUENCE, CHECKPOINT_LAST_DISPATCH_ID,
# CHECKPOINT_COMPLETED_UNITS (space-separated unit_ids, state=completed),
# CHECKPOINT_DIRTY_UNIT (the sole open, never-completed unit_id in the
# valid-so-far prefix, or empty), CHECKPOINT_DIRTY_ARTIFACT_PATH (that open
# unit's own artifact_path, for the isolation test below), CHECKPOINT_
# NEXT_UNIT, and CHECKPOINT_BAD_REASON (why the file is not fully VALID, if
# it is not). A record failing ANY check below ends the valid prefix right
# there -- everything before it still counts as partial-state evidence nothing
# from it or after is trusted for authorizing new work.
#
# Usage: checkpoint_resume_state PROGRESS_PATH EXPECTED_DISPATCH_ID
checkpoint_resume_state() {
  local path="$1" expected_id="$2"
  CHECKPOINT_STATE=NO_CHECKPOINT
  CHECKPOINT_LAST_SEQUENCE=0
  CHECKPOINT_LAST_DISPATCH_ID=""
  CHECKPOINT_COMPLETED_UNITS=""
  CHECKPOINT_DIRTY_UNIT=""
  CHECKPOINT_DIRTY_ARTIFACT_PATH=""
  CHECKPOINT_NEXT_UNIT=""
  CHECKPOINT_BAD_REASON=""
  [ -f "$path" ] || return 0

  local -A open_units=()
  local line n=0 ok=1 last_seq=0
  local schema dispatch_id sequence state unit_id artifact_path artifact_sha256 commit_sha next_unit
  # `read -r line || [ -n "$line" ]`, not a bare `read`: a genuinely
  # TRUNCATED final record (no trailing newline -- an interrupted write) has
  # `read` return non-zero at EOF while still populating $line with the
  # partial content. A bare `while read` loop condition would silently DROP
  # that iteration -- exactly the "truncated final record" fixture this
  # function must instead recognize as MALFORMED, not quietly ignore.
  while IFS= read -r line || [ -n "$line" ]; do
    # $n counts REAL record lines only (incremented AFTER the blank-skip):
    # a whitespace-only file ("\n\n\n") must report NO_CHECKPOINT, not a
    # vacuous VALID with zero units -- incrementing before the blank check
    # let $n go non-zero on pure whitespace and slipped past the "$n -eq 0"
    # guard below (code review fix).
    [ -n "$line" ] || continue
    n=$((n + 1))
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      ok=0; CHECKPOINT_BAD_REASON="MALFORMED_RECORD_AT_LINE_$n"; break
    fi
    schema="$(printf '%s' "$line" | jq -r '.schema_version // empty')"
    dispatch_id="$(printf '%s' "$line" | jq -r '.dispatch_id // empty')"
    sequence="$(printf '%s' "$line" | jq -r '.sequence // empty')"
    state="$(printf '%s' "$line" | jq -r '.state // empty')"
    unit_id="$(printf '%s' "$line" | jq -r '.unit_id // empty')"
    artifact_path="$(printf '%s' "$line" | jq -r '.artifact_path // empty')"
    artifact_sha256="$(printf '%s' "$line" | jq -r '.artifact_sha256 // empty')"
    commit_sha="$(printf '%s' "$line" | jq -r '.commit_sha // empty')"
    next_unit="$(printf '%s' "$line" | jq -r '.next_unit // empty')"

    if [ "$schema" != 2 ]; then
      ok=0; CHECKPOINT_BAD_REASON="BAD_SCHEMA_AT_LINE_$n"; break
    fi
    if [ -n "$expected_id" ] && [ "$dispatch_id" != "$expected_id" ]; then
      ok=0; CHECKPOINT_BAD_REASON="WRONG_DISPATCH_ID_AT_LINE_$n:$dispatch_id"; break
    fi
    case "$sequence" in ''|*[!0-9]*)
      ok=0; CHECKPOINT_BAD_REASON="BAD_SEQUENCE_AT_LINE_$n"; break ;;
    esac
    # Strictly CONTIGUOUS, not merely increasing (code review fix): a gap
    # (1 then 7) is exactly the "discontinuous checkpoint" spec S10.1 already
    # promises gets blocked -- `-le` alone let a gap silently report VALID.
    if [ "$sequence" -ne $((last_seq + 1)) ]; then
      ok=0
      CHECKPOINT_BAD_REASON="SEQUENCE_NOT_INCREASING_AT_LINE_$n:$sequence!=$((last_seq + 1))"
      break
    fi
    if [ -n "$artifact_path" ] && [ "$artifact_path" != null ]; then
      case "$artifact_path" in
        "${FEATURE_FOLDER:-\x00}"|"${FEATURE_FOLDER:-\x00}"/*) : ;;
        *)
          ok=0
          CHECKPOINT_BAD_REASON="ARTIFACT_PATH_OUTSIDE_FEATURE_FOLDER_AT_LINE_$n:$artifact_path"
          break ;;
      esac
      if [ -f "$artifact_path" ] && [ -n "$artifact_sha256" ] && [ "$artifact_sha256" != null ]; then
        local real_sha
        real_sha="$(sha256sum "$artifact_path" 2>/dev/null | cut -d' ' -f1)"
        if [ "$real_sha" != "$artifact_sha256" ]; then
          ok=0
          CHECKPOINT_BAD_REASON="STALE_ARTIFACT_REVISION_AT_LINE_$n:$artifact_path"
          break
        fi
      fi
    fi
    if [ -n "$commit_sha" ] && [ "$commit_sha" != null ]; then
      if ! git -C "${REPO_ROOT:-}" cat-file -e "${commit_sha}^{commit}" 2>/dev/null; then
        ok=0
        CHECKPOINT_BAD_REASON="COMMIT_NOT_IN_REPO_AT_LINE_$n:$commit_sha"
        break
      fi
      if ! git -C "${REPO_ROOT:-}" merge-base --is-ancestor "$commit_sha" HEAD 2>/dev/null; then
        ok=0
        CHECKPOINT_BAD_REASON="COMMIT_NOT_REACHABLE_FROM_HEAD_AT_LINE_$n:$commit_sha"
        break
      fi
    fi

    last_seq="$sequence"
    # shellcheck disable=SC2034  # consumed by the caller after checkpoint_resume_state returns
    CHECKPOINT_LAST_SEQUENCE="$sequence"
    # shellcheck disable=SC2034  # consumed by the caller after checkpoint_resume_state returns
    CHECKPOINT_LAST_DISPATCH_ID="$dispatch_id"
    # shellcheck disable=SC2034  # consumed by the caller after checkpoint_resume_state returns
    CHECKPOINT_NEXT_UNIT="$next_unit"
    if [ "$state" = completed ]; then
      CHECKPOINT_COMPLETED_UNITS="${CHECKPOINT_COMPLETED_UNITS:+$CHECKPOINT_COMPLETED_UNITS }$unit_id"
      unset "open_units[$unit_id]" 2>/dev/null || true
    else
      open_units["$unit_id"]="$artifact_path"
    fi
  done < "$path"

  if [ "$n" -eq 0 ]; then
    CHECKPOINT_STATE=NO_CHECKPOINT
    return 0
  fi

  local dirty_count="${#open_units[@]}"
  if [ "$dirty_count" -eq 1 ]; then
    local -a _open_keys=("${!open_units[@]}")
    CHECKPOINT_DIRTY_UNIT="${_open_keys[0]}"
    CHECKPOINT_DIRTY_ARTIFACT_PATH="${open_units[${_open_keys[0]}]}"
  fi

  if [ "$ok" -eq 1 ] && [ "$dirty_count" -le 1 ]; then
    CHECKPOINT_STATE=VALID
  else
    [ -n "$CHECKPOINT_BAD_REASON" ] || CHECKPOINT_BAD_REASON="MULTIPLE_DIRTY_PARTIAL_UNITS:$dirty_count"
    # shellcheck disable=SC2034  # consumed by the caller after checkpoint_resume_state returns
    CHECKPOINT_STATE=NEEDS_RECONCILIATION
  fi
  return 0
}

# RM07's own "is the partial unit isolated" test (spec: "continuation ...
# only if the partial unit is isolated"). Meaningful only once checkpoint_
# resume_state has already run and set $CHECKPOINT_DIRTY_UNIT for the
# failed attempt's own progress.jsonl -- a caller with no checkpoint context
# at all (empty $CHECKPOINT_DIRTY_UNIT) always fails closed, never
# optimistically isolated. "Isolated" means: every currently-dirty path in
# the tree is either the one open unit's own declared artifact
# ($CHECKPOINT_DIRTY_ARTIFACT_PATH), a pre-existing foreign path the current
# write-lease already declared (declared_foreign_paths, spec S10.4's
# "declared foreign changes" -- `_write_lease_foreign_paths_now`'s own
# capture, above), or the fixed orchestration-bookkeeping allow-list
# (RUN_LOG.md/full_log.md/$ORCHESTRATION_DIR/transcripts//attempts/
# subtrees -- the SAME paths `_mutation_dirty`, above, exempts, via the
# shared `_is_orchestration_bookkeeping_path` predicate `_write_lease_
# foreign_paths_now` also uses; `_mutation_dirty`'s own copy is left as its
# own local closure, since refactoring it carries real regression risk for
# a property this pair is the only other consumer of).
checkpoint_partial_isolated() {
  # Usage: checkpoint_partial_isolated [LEASE_FILE]
  local lease_file="${1:-${ORCHESTRATION_DIR:-}/write-lease.json}"
  # CHECKPOINT_STATE must be VALID, not merely "$CHECKPOINT_DIRTY_UNIT is
  # non-empty" (code review fix: a malformed/discontinuous SUFFIX after a
  # genuinely partial prefix left $CHECKPOINT_DIRTY_UNIT set from that valid
  # prefix, so a NEEDS_RECONCILIATION file authorized continuation exactly
  # like a fully VALID one -- the one gate Step 5 actually requires never
  # ran). VALID already implies at most one dirty unit (checkpoint_resume_
  # state's own dirty_count<=1 condition), so this one check subsumes both.
  [ "${CHECKPOINT_STATE:-}" = VALID ] || return 1
  [ -n "${CHECKPOINT_DIRTY_UNIT:-}" ] || return 1
  local ff_rel orch_rel
  ff_rel="${FEATURE_FOLDER#"${REPO_ROOT:-}"/}"
  orch_rel="${ORCHESTRATION_DIR#"${REPO_ROOT:-}"/}"
  # Seeded with one empty sentinel, not `()`: `"${foreign[@]}"` on a
  # genuinely EMPTY array aborts under `set -u` on bash 4.0-4.3 (fixed in
  # 4.4+) -- the sentinel keeps the array always non-empty and never
  # matches a real (non-empty) path, the same guard `_write_lease_foreign_
  # paths_now`'s own `-gt 0` check applies by a different route.
  local -a foreign=("")
  if [ -f "$lease_file" ]; then
    while IFS= read -r p; do [ -n "$p" ] && foreign+=("$p"); done \
      < <(jq -r '.declared_foreign_paths[]? // empty' "$lease_file" 2>/dev/null)
  fi
  local own_rel=""
  if [ -n "${CHECKPOINT_DIRTY_ARTIFACT_PATH:-}" ] && [ "$CHECKPOINT_DIRTY_ARTIFACT_PATH" != null ]; then
    own_rel="${CHECKPOINT_DIRTY_ARTIFACT_PATH#"${REPO_ROOT:-}"/}"
  fi
  local entry status path f is_ok
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"; path="${entry:3}"
    _is_orchestration_bookkeeping_path "$path" "$ff_rel" "$orch_rel" && continue
    is_ok=0
    [ -n "$own_rel" ] && [ "$path" = "$own_rel" ] && is_ok=1
    for f in "${foreign[@]}"; do [ "$f" = "$path" ] && is_ok=1 && break; done
    [ "$is_ok" -eq 1 ] || return 1
    case "$status" in R*|C*) IFS= read -r -d '' _ || true ;; esac
  done < <(git -C "${REPO_ROOT:-}" status --porcelain=v1 --untracked-files=all -z 2>/dev/null)
  return 0
}

# Recovers the ROLE suffix from a p<token>-i<NN>-<role> logical dispatch id
# -- the same token/iteration-marker parse role_attempt_dir itself uses,
# reused here rather than re-derived, so this can never drift from what a
# real dispatch_id actually looks like.
_logical_role() {
  # Usage: _logical_role LOGICAL_DISPATCH_ID
  local logical="$1" tok iter
  tok="$(printf '%s\n' "$logical" | "$GREP_BIN" -oE '^p[^-]+')"
  iter="$(printf '%s\n' "$logical" | "$GREP_BIN" -oE -- '-i[0-9]{2}-' | head -1)"
  [ -n "$tok" ] && [ -n "$iter" ] || return 1
  printf '%s\n' "${logical#"$tok""$iter"}"
}

# Highest ALREADY-ALLOCATED attempt id for LOGICAL, or failure if none has
# been allocated yet -- a thin, side-effect-free wrapper around next_unused_
# attempt's own "next" number (minus one). Deliberately NOT a shared helper
# that also resolves the progress.jsonl PATH and stashes a second value in a
# global: this function is always called through `$(...)` command
# substitution, which runs in a SUBSHELL -- any sibling global a callee sets
# there is invisible to the caller once the subshell exits (a real bug this
# document's own review caught: an earlier version tried exactly that and
# silently lost LATEST_ATTEMPT_ID every time). One pure stdout value avoids
# the whole class of bug.
_latest_attempt_id() {
  # Usage: _latest_attempt_id LOGICAL_DISPATCH_ID
  local logical="$1" latest_num
  latest_num="$(next_unused_attempt "$logical" 2>/dev/null)" || return 1
  [ "$latest_num" -gt 1 ] || return 1
  printf '%s-a%02d\n' "$logical" "$((latest_num - 1))"
}

# RM07's REAL wiring (code review fix -- this closes the "isolation test is
# reachable only from the unit test" gap): runs checkpoint_resume_state
# against the JUST-FAILED attempt's OWN progress.jsonl, in the RIGHT order
# -- BEFORE checkpoint_partial_isolated's decision needs it, not after, and
# not left to a caller that never calls it at all. Always resets CHECKPOINT_
# DIRTY_UNIT/STATE first: a caller with no resolvable logical id (or no
# checkpoint at that path) must fail closed on FRESH empty state, never on
# whatever a PREVIOUS, unrelated recovery_action call left behind.
#
# ORDERING CONSTRAINT (documented per code review, round 2 -- was implicit):
# `_latest_attempt_id` (below) resolves the HIGHEST attempt id ALREADY
# durable in RUN_LOG for this logical dispatch, i.e. the failed attempt
# recovery_action is being asked to reconcile. The caller MUST invoke
# recovery_action (and therefore this function) BEFORE allocate_attempt
# mints the continuation's own NEW attempt id -- allocating first would
# make this resolve to the CONTINUATION's own (not-yet-run) attempt instead
# of the failed one. The real flow already satisfies this (a phase decides
# whether/how to redispatch from the classified failure, THEN allocates);
# this is a genuine ordering requirement on any caller, not an accident of
# today's call graph, so it is spelled out here rather than left implicit.
_recovery_checkpoint_context() {
  # Usage: _recovery_checkpoint_context LOGICAL_DISPATCH_ID -- call BEFORE
  # allocate_attempt mints a continuation's own new attempt id (see above).
  local logical="$1" role latest_id dir path
  CHECKPOINT_STATE=""
  CHECKPOINT_DIRTY_UNIT=""
  [ -n "$logical" ] || return 1
  role="$(_logical_role "$logical")" || return 1
  latest_id="$(_latest_attempt_id "$logical")" || return 1
  dir="$(role_attempt_dir "$role" "$latest_id" 2>/dev/null)" || return 1
  path="$dir/progress.jsonl"
  checkpoint_resume_state "$path" "$latest_id"
}

# Best-effort continuation-context reconstruction for ONE checkpointed role
# (spec S10.4's "continuation input"): populates CONTINUATION_PATH (the
# failed attempt's own validated-on-disk checkpoint path, or empty),
# DECLARED_FOREIGN_CHANGES (space-separated, from the CURRENT write-lease's
# own declared_foreign_paths, or empty), and CONTINUATION_PRIOR_CLASSIFICATION
# (spec S20.6's "prior classification" -- the failed attempt's own
# classify_attempt result, e.g. TIMED_OUT/PUBLICATION_LOST/DIRTY_CHECKPOINTED,
# read via the SAME _dispatch_completed_field helper resume_dispatch_state
# itself already uses, never a second reader of DISPATCH_COMPLETED). Read-
# only; never allocates an attempt or authorizes anything -- recovery_action/
# recovery_retry_allowed paired with checkpoint_resume_state still gate
# whether a continuation may actually launch.
_reconstruct_continuation_state() {
  # Usage: _reconstruct_continuation_state ROLE LOGICAL_DISPATCH_ID
  local role="$1" logical="$2" path
  [ -n "$logical" ] || return 0
  case "$(resume_dispatch_state "$logical" 2>/dev/null)" in
    FAILED_OBSERVED) : ;;
    *) return 0 ;;
  esac
  local latest_id dir
  latest_id="$(_latest_attempt_id "$logical")" || return 0
  dir="$(role_attempt_dir "$role" "$latest_id" 2>/dev/null)" || return 0
  path="$dir/progress.jsonl"
  [ -f "$path" ] && CONTINUATION_PATH="$path"
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  CONTINUATION_PRIOR_CLASSIFICATION="$(_dispatch_completed_field "$latest_id" classification 2>/dev/null)"
  if [ -f "${ORCHESTRATION_DIR:-}/write-lease.json" ]; then
    DECLARED_FOREIGN_CHANGES="$(jq -r '.declared_foreign_paths[]? // empty' \
      "$ORCHESTRATION_DIR/write-lease.json" 2>/dev/null | tr '\n' ' ')"
    DECLARED_FOREIGN_CHANGES="${DECLARED_FOREIGN_CHANGES% }"
  fi
}

# Dispatches _reconstruct_continuation_state to the right role/logical-id
# for a given phase (spec S10.2's six checkpointed roles). Unlike reconstruct_
# durable_inputs's OTHER reconstructions (registry-free -- status_field/git
# only), this one genuinely needs $ROLE_CONTRACTS_PATH (role_attempt_dir ->
# role_phases), so it MUST run AFTER bootstrap_runtime/`source "$RUNTIME_DIR/
# develop-it-runtime.sh"` -- never inside init_orchestration_vars itself,
# whose own reconstructions run BEFORE that source line (see the per-phase
# snippet below). <iteration> defaults to "00" (the three single-shot
# phases: 4, 6, 9); pass the phase's own current $ITERATION for the three
# that iterate (3, 5, 7) once that phase's loop has set it.
reconstruct_checkpoint_state() {
  # Usage: reconstruct_checkpoint_state PHASE [ITERATION]
  local phase="$1" iter="${2:-00}" role="" logical=""
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  CONTINUATION_PATH=""
  DECLARED_FOREIGN_CHANGES=""
  # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
  CONTINUATION_PRIOR_CLASSIFICATION=""
  case "$phase" in
    3) role=spec-fixer ;;
    4) role=plan-writer; iter=00 ;;
    5) role=plan-fixer ;;
    6) role=implementer; iter=00 ;;
    7) role=implementation-fixer ;;
    9) role=documentation-writer; iter=00 ;;
    *) return 0 ;;
  esac
  logical="p$(printf '%02d' "$phase")-i$(printf '%02d' "$((10#$iter))")-$role"
  _reconstruct_continuation_state "$role" "$logical"

  # Task 13: phase 6's implementer is the one role with an explicit mode
  # contract (A|B|D). This is the SAME call the Phase 6 preamble already
  # makes to populate $CONTINUATION_PATH, so deriving the default $MODE here
  # -- A when there is nothing to continue, D once a real continuation
  # checkpoint is found -- keeps both facts resolved together, from the same
  # evidence, in one place. Step 6.2 (post-debug re-dispatch) overrides this
  # to MODE=B itself, right before that re-dispatch; nothing here ever
  # produces B, since a debugger pass is orthogonal to whether a PRIOR
  # implementer attempt left a continuable checkpoint.
  if [ "$phase" = 6 ]; then
    # shellcheck disable=SC2034  # consumed via render_keys()/render_prompt's ${!k} indirection
    MODE=A
    [ -n "$CONTINUATION_PATH" ] && MODE=D
  fi
  return 0
}

# Usage: dispatch_is_running <dispatch_id>
# 0 (true) iff RUN_LOG.md has a DISPATCH_STARTED for this id with no later
# DISPATCH_COMPLETED or DISPATCH_NOT_LAUNCHED for the same id.
# Task 6 (P04): rewritten on _run_log_latest_field (the shared reader, above)
# instead of a hand-rolled line scan. Also fixes a live bug in the old scan:
# its `*"$id")` case pattern was an UNANCHORED SUFFIX match against the whole
# `dispatch_id:<value>` line, so a dispatch id that happened to be a suffix
# of another one (e.g. id "x-a01" would match a stored "p06-i00-x-a01") could
# false-positive. `.dispatch_id==$id` below is an exact match on the parsed
# field, never a substring/suffix comparison.
dispatch_is_running() {
  local id="$1" log="$FEATURE_FOLDER/RUN_LOG.md"
  [ -f "$log" ] || return 1
  local type
  type="$(_run_log_latest_field \
    '(._type=="DISPATCH_STARTED" or ._type=="DISPATCH_COMPLETED" or ._type=="DISPATCH_NOT_LAUNCHED") and (.dispatch_id // "")==$id' \
    _type "id=$id")" || return 1
  [ "$type" = DISPATCH_STARTED ]
}

# A user-facing "role X is running" claim is only ever correct when
# dispatch_is_running agrees. When it does not, this appends a durable
# correction via record_event (the full typed proposition ledger remains a
# later task's job; this is the minimal durable evidence this document owes)
# and returns non-zero so the caller corrects its own narration instead of
# repeating the false claim.
assert_dispatch_running_claim() {
  # Usage: assert_dispatch_running_claim <dispatch_id> <narrated-claim>
  local id="$1" claim="$2"
  if dispatch_is_running "$id"; then
    return 0
  fi
  record_event PROCESS_DEVIATION dispatch_id="$id" \
    reason="narrated as running with no matching DISPATCH_STARTED: $claim"
  return 1
}

canary_preflight() {
  # HARD-REQUIRED binaries. `codex` is deliberately NOT here: its absence is
  # handled by the asymmetric failover policy below, and listing it in both places
  # made the canary contradict itself — it would halt on a missing binary the very
  # next lines describe as optional.
  # `env` is required by render_prompt to pass substitution values explicitly;
  # `realpath` by canon(). Long dispatch uses the harness's background execution,
  # so no process-supervision tools are needed.
  local missing=()
  for bin in claude timeout awk sed jq git date sha256sum cut mkdir mv tail tr \
             grep realpath env python3; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  # codex is optional here; a missing binary drives the failover policy (Mode 0),
  # which Phase 1 escalates to a HALT on its own terms.
  local codex_present=yes
  command -v codex >/dev/null 2>&1 || codex_present=no

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "halt: required binaries missing: ${missing[*]}" >&2
    echo "  note: python3 is required by render_prompt for multi-line variable" >&2
    echo "  substitution; there is no sed-based alternative." >&2
    return 1
  fi

  # write-lease.json's startup-grace fallback (for leases written before
  # acquired_epoch existed) reparses acquired_at with GNU-only `date -d`. A
  # silent parse failure there reproduces the exact false AMBIGUOUS_LEASE the
  # grace window exists to prevent, so the capability is asserted here as an
  # environment defect rather than surfacing as a misclassified lease.
  if [ "$(date -u -d "1970-01-01T00:00:01Z" +%s 2>/dev/null)" != "1" ]; then
    echo "halt: 'date -d' cannot parse ISO-8601 UTC timestamps on this host (non-GNU date?)" >&2
    return 1
  fi

  # Syntax sanity-check both CLIs (no model call, no token spend).
  claude --help >/dev/null 2>&1 || { echo "halt: 'claude --help' failed" >&2; return 1; }
  claude --help 2>&1 | grep -q -- '--output-format' \
    || { echo "halt: 'claude' CLI does not support --output-format; upgrade Claude Code" >&2; return 1; }
  claude --help 2>&1 | grep -q -- '--dangerously-skip-permissions' \
    || { echo "halt: 'claude' CLI does not support --dangerously-skip-permissions; upgrade Claude Code" >&2; return 1; }
  if [ "$codex_present" = yes ]; then
    if ! codex exec --help >/dev/null 2>&1; then
      echo "warn: 'codex exec --help' failed — Codex CLI may be incompatible; failover applies" >&2
      codex_present=no
    elif ! codex exec --help 2>&1 | grep -q -- '--json'; then
      echo "warn: 'codex exec --help' lacks --json; usage telemetry for codex unavailable; failover applies" >&2
      codex_present=no
    elif ! codex exec --help 2>&1 | grep -q -- '--skip-git-repo-check'; then
      echo "warn: 'codex exec --help' lacks --skip-git-repo-check; upgrade Codex CLI" >&2
      codex_present=no
    fi
  fi

  # Echo result so the caller can branch.
  printf 'canary_ok codex_present=%s\n' "$codex_present"
}

# Verify every pinned model id is accepted. Inexpensive but NOT free: one
# minimal call per distinct id. A rejection HALTs — there is no fallback.
probe_models() {
  # Usage: probe_models <codex_present:yes|no>
  # A missing codex binary is NOT a rejected model; probing it anyway mislabels an
  # environment defect as a Models-table error.
  local codex_present="${1:-yes}"
  local role model rc=0
  local -A seen=()
  for role in $(_role_keys); do
    model="$(role_model "$role")" || { rc=1; continue; }
    [ -n "${seen[$model]:-}" ] && continue
    seen[$model]=1
    case "$(role_vendor "$role")" in
      claude)
        printf 'ok\n' | timeout --kill-after=10s 30s \
          claude --model "$model" -p --output-format=json \
          --dangerously-skip-permissions - >/dev/null 2>&1 \
          || { echo "model rejected: role=$role model=$model vendor=claude" >&2; rc=1; } ;;
      codex)
        [ "$codex_present" = yes ] || continue
        printf 'ok\n' | timeout --kill-after=10s 30s \
          codex -a never -m "$model" exec -C "$REPO_ROOT" \
          -s read-only --skip-git-repo-check --json - >/dev/null 2>&1 \
          || { echo "model rejected: role=$role model=$model vendor=codex" >&2; rc=1; } ;;
    esac
  done
  return "$rc"
}

# parse_usage <vendor> <stdout-path> <wall-duration-ms> <declared-model>
# Prints: model=<m> duration_ms=<n> tokens_input_new=<n> tokens_input_cached=<n> tokens_cache_write=<n> tokens_output=<n> tokens_reasoning=<n> cost_usd=<n|n/a> usage_status=<ok|unavailable>
parse_usage() {
  local vendor="$1" out_path="$2" wall_ms="$3" declared_model="$4"
  local model dur in_new in_cached cache_w out reasoning cost status

  if [ ! -s "$out_path" ]; then
    printf 'model=unknown duration_ms=%s tokens_input_new=0 tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=n/a usage_status=unavailable\n' "$wall_ms"
    return 0
  fi

  if [ "$vendor" = "claude" ]; then
    # Single JSON object on stdout.
    # .modelUsage can contain MORE than one model: Claude Code internally uses a small
    # Haiku helper alongside the dispatched main model. Prefer the key matching the
    # dispatched model id when present; never select alphabetically — with fable,
    # haiku, opus and sonnet all possible, sort order is meaningless. Select the
    # key with the highest total token count.
    local parsed
    parsed=$(jq -r --arg fb "$declared_model" '
      (.modelUsage // {}) as $mu
      | (if ($mu | has($fb)) then $fb
         elif ($mu | length) > 0 then ($mu | to_entries | max_by(.value.outputTokens // 0) | .key)
         else "unknown" end) as $model
      | [
        $model,
        (.duration_ms // 0),
        (.usage.input_tokens // 0),
        (.usage.cache_read_input_tokens // 0),
        (.usage.cache_creation_input_tokens // 0),
        (.usage.output_tokens // 0),
        0,
        (.total_cost_usd // "n/a")
      ] | @tsv
    ' "$out_path" 2>/dev/null) || parsed=""
    if [ -z "$parsed" ]; then
      printf 'model=unknown duration_ms=%s tokens_input_new=0 tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=n/a usage_status=unavailable\n' "$wall_ms"
      return 0
    fi
    IFS=$'\t' read -r model dur in_new in_cached cache_w out reasoning cost <<< "$parsed"
    status="ok"
  elif [ "$vendor" = "codex" ]; then
    # Take the LAST turn.completed record. If there is none, usage is
    # unavailable — NOT zeros with usage_status=ok. A streaming filter is used
    # rather than `-s`, which slurps a possibly enormous transcript into memory.
    local parsed
    parsed="$(jq -r 'select(.type == "turn.completed") | .usage
                     | [(.input_tokens // 0), (.cached_input_tokens // 0),
                        (.output_tokens // 0), (.reasoning_output_tokens // 0)]
                     | @tsv' "$out_path" 2>/dev/null | tail -1)"
    if [ -z "$parsed" ]; then
      printf 'model=unknown duration_ms=%s tokens_input_new=0 tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=n/a usage_status=unavailable\n' "$wall_ms"
      return 0
    fi
    local in_total
    IFS=$'\t' read -r in_total in_cached out reasoning <<< "$parsed"
    # tokens_input_new is NEW input only: Codex reports input_tokens as the
    # TOTAL, cached included, so the difference must be taken and clamped at 0.
    in_new=$(( in_total - in_cached ))
    [ "$in_new" -lt 0 ] && in_new=0
    cache_w=0
    # Codex JSON has no model field; use the orchestrator-resolved model id.
    model="$declared_model"
    dur="$wall_ms"
    cost="n/a"
    status="ok"
  else
    printf 'model=unknown duration_ms=%s tokens_input_new=0 tokens_input_cached=0 tokens_cache_write=0 tokens_output=0 tokens_reasoning=0 cost_usd=n/a usage_status=unavailable\n' "$wall_ms"
    return 0
  fi

  printf 'model=%s duration_ms=%s tokens_input_new=%s tokens_input_cached=%s tokens_cache_write=%s tokens_output=%s tokens_reasoning=%s cost_usd=%s usage_status=%s\n' \
    "$model" "$dur" "$in_new" "$in_cached" "$cache_w" "$out" "$reasoning" "$cost" "$status"
}

# ---- Wall-clock timing ------------------------------------------------------
# Calling `date` with a `%3N`-style width specifier is NOT portable: uutils
# coreutils ignores that width and emits full nanoseconds, inflating every
# duration by ~10^6. EPOCHREALTIME is a bash builtin, so it does not depend on
# which coreutils is installed.
now_ms() { local t="${EPOCHREALTIME}"; local us="${t/[.,]/}"; printf '%s\n' "$((us / 1000))"; }

# Runs a command and records BOTH its duration and its exit code in globals.
#
# It must NOT be called via `wall_ms="$(run_timed ...)"` or as the last element
# of a pipe: both run it in a subshell, so any global the function sets is
# discarded and the caller sees nothing. Call it directly and read the globals.
#   run_timed invoke_vendor "$role" "$prompt_file" "$out" "$err"
#   echo "$DISPATCH_WALL_MS $DISPATCH_RC"
#
# `local` is also only legal inside a function — the previous snippet used it at
# top level, so the assignment never happened and the duration was always empty.
run_timed() {
  # Usage: run_timed <command...>   -> sets DISPATCH_WALL_MS, DISPATCH_RC
  local t0 t1
  t0="$(now_ms)"
  "$@"
  # shellcheck disable=SC2034  # consumed by the caller after run_timed returns
  DISPATCH_RC=$?
  t1="$(now_ms)"
  # shellcheck disable=SC2034  # consumed by the caller after run_timed returns
  DISPATCH_WALL_MS=$((t1 - t0))
  return 0
}

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

  # A single pre-joined membership string, walked one path-ancestor at a
  # time with a plain `case` substring match below, replaces the old
  # define-then-`unset -f _allowed` global-function closure substitute --
  # that was a latent reentrancy trap (bash functions are always global; a
  # nested/concurrent porcelain_offenders call could unset _allowed out from
  # under another call still relying on it). Nothing here is global, so
  # there is nothing for a second call to clobber. "$p is allowed" iff some
  # ancestor of $p (walking up via dirname, $p itself included) is exactly
  # one of the allow entries -- the same "equal to, or nested under" rule
  # `_allowed` used to implement per-entry. An empty $allow_joined ("||")
  # matches nothing, same as the old empty-array case (everything is an
  # offender).
  local old_ifs="$IFS" allow_joined
  IFS='|'; allow_joined="|${allow[*]}|"; IFS="$old_ifs"

  local status path old p cand
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    path="${entry:3}"
    old=""
    case "$status" in
      R*|C*)
        # Consume the second field: the ORIGINAL path. Both sides must be in
        # scope -- checking only the destination would hide a file being
        # moved OUT of an out-of-scope location.
        IFS= read -r -d '' old || old="" ;;
    esac
    for p in "$path" ${old:+"$old"}; do
      # Strip exactly one trailing slash before the walk (git reports an
      # untracked DIRECTORY with one, per the note above) -- `dirname` on a
      # string that still has one collapses straight past the directory's
      # own name to its PARENT, which would skip the exact allow-list entry.
      cand="${p%/}"
      while :; do
        case "$allow_joined" in *"|$cand|"*) continue 2 ;; esac
        [ "$cand" = "." ] && break
        cand="$(dirname -- "$cand")"
      done
      printf '%s\n' "$p"
    done
  done < <(git -C "$repo" status --porcelain=v1 -z)
}

# Gate: HALT when the target repo has changes outside the allow-list.
# $PROCESS_PATH is deliberately NOT passed: it lives in the other repository, so
# it can never appear in this repo's porcelain output. Passing it would be dead
# weight, not protection.
# shellcheck disable=SC2120  # optional allow-list args are passed from phase blocks
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

# Prints one hygiene-recommendation warning line on stdout when the
# .gitignore pattern is absent; prints nothing when it is present. This is
# advisory ONLY: dirty_tree_check's own allow-list ALWAYS covers
# $FEATURE_FOLDER regardless (see its own body above), so the runtime
# dirty-check risk is already handled either way -- an absent .gitignore
# entry only means orchestration artifacts stay untracked-but-unignored,
# a cosmetic `git status` nuisance, never a functional gap. It is normal
# and expected for this to print on every run whose target repo has not
# yet added the pattern; it is not a sign anything is broken. Never halts
# -- always returns 0.
verify_gitignore_guard() {
  local gi="$REPO_ROOT/.gitignore"
  if [ -f "$gi" ] && "$GREP_BIN" -q -- 'docs/superpowers/specs/\*-artifacts/' "$gi"; then
    return 0
  fi
  printf 'warn: recommend adding docs/superpowers/specs/*-artifacts/ to .gitignore so orchestration artifacts do not pollute commits\n'
  return 0
}

# Reads $FEATURE_FOLDER/RUN_LOG.md if present. NEVER writes anything, in any
# of its four outcomes. Prints one of NEW_RUN_ELIGIBLE / RESUME_ELIGIBLE on
# stdout and returns 0, or a HALT token (RUN_LOG_SCHEMA_V1_OR_UNKNOWN /
# RUN_LOG_SCHEMA_MALFORMED / RUN_LOG_IDENTITY_MISMATCH) on stderr, with an
# instruction to use the run's recorded process version, and returns 1.
#
#   absent (no file, or a zero-byte file)      -> NEW_RUN_ELIGIBLE
#   malformed (no schema-v2 event= entries at
#     all -- neither legacy nor v2 shape)      -> RUN_LOG_SCHEMA_MALFORMED, HALT
#   v1 (has "--- <ts>  dispatch" blocks but no
#     "event=" tag anywhere)                   -> RUN_LOG_SCHEMA_V1_OR_UNKNOWN, HALT
#   mismatched identity (schema-v2, but the
#     earliest recorded develop_it_git_sha
#     differs from the CURRENT process commit) -> RUN_LOG_IDENTITY_MISMATCH, HALT
#   valid v2, matching identity                 -> RESUME_ELIGIBLE
validate_existing_run_log() {
  local log="$FEATURE_FOLDER/RUN_LOG.md"
  if [ ! -s "$log" ]; then
    printf 'NEW_RUN_ELIGIBLE\n'
    return 0
  fi

  if ! "$GREP_BIN" -q -- '^--- .*  event=' "$log"; then
    echo "RUN_LOG_SCHEMA_V1_OR_UNKNOWN" >&2
    echo "  $log has no schema-v2 event entries (legacy schema-v1 log, or unrecognized content)." >&2
    echo "  Use this run's recorded process version to continue it, or start a new feature folder." >&2
    return 1
  fi

  if ! "$GREP_BIN" -q -- '^process_schema_version:[[:space:]]*2$' "$log"; then
    echo "RUN_LOG_SCHEMA_MALFORMED" >&2
    echo "  $log has event entries but none declares process_schema_version: 2." >&2
    echo "  Use this run's recorded process version to continue it, or start a new feature folder." >&2
    return 1
  fi

  local recorded
  recorded="$("$GREP_BIN" -m1 -oE '^develop_it_git_sha:[[:space:]]*[^[:space:]]+' "$log" \
              | "$GREP_BIN" -oE '[^[:space:]]+$')"
  if [ -n "$recorded" ] && [ "$recorded" != non-git ] && [ "$recorded" != "$PROCESS_GIT_HEAD" ]; then
    echo "RUN_LOG_IDENTITY_MISMATCH" >&2
    echo "  This run started under process commit $recorded; the current checkout is $PROCESS_GIT_HEAD." >&2
    echo "  Check out commit $recorded of $PROCESS_REPO_ROOT (this run's recorded process version) to resume it, or start a new feature folder." >&2
    return 1
  fi

  printf 'RESUME_ELIGIBLE\n'
}

# Runs the five zero-token gates (spec S16.1 steps 1-5), in order, writing
# one record_event success marker per gate. Returns 0 with all five durable
# and $CODEX_PRESENT set ("yes"|"no"), or non-zero the instant any gate
# fails -- no later gate's event, and no paid probe or dispatch, is ever
# reached. $FEATURE_FOLDER must already be set (derived from the spec path
# per "Naming convention") and MUST NOT yet be assumed to exist; this
# function creates it.
# The uniform Step 1.0 HALT-logging rule, as real code: creates
# $FEATURE_FOLDER if needed (safe even when gate 1's own validate_roots
# failed -- $FEATURE_FOLDER is a pure string transform of the spec path,
# independent of REPO_ROOT/PROCESS_PATH validity) and appends ONE
# event=HALT entry naming the reason, then returns 1. NEVER called for
# gate 1's validate_existing_run_log failure -- that is the ONE documented
# exception (zero bytes written; see "Preflight zero-token gate sequence"
# above) and returns 1 directly instead, before this function is reached.
_preflight_halt() {
  echo "halt: $1" >&2
  mkdir -p "$FEATURE_FOLDER"
  record_event HALT reason="$1" 2>/dev/null
  return 1
}

preflight_zero_token_gates() {
  # Gate 1: paths + new-run schema eligibility.
  init_orchestration_vars || { _preflight_halt "gate1 invalid paths"; return 1; }
  local run_log_state
  run_log_state="$(validate_existing_run_log)" || return 1
  mkdir -p "$FEATURE_FOLDER"
  record_event PATHS_AND_NEW_RUN_SCHEMA_ELIGIBLE \
    run_log_state="$run_log_state" reason="paths validated against PROCESS_REPO_ROOT; run_log $run_log_state" \
    || return 1

  # Gate 2: local CLI/binary canaries (no token spend).
  local canary_out
  canary_out="$(canary_preflight)" || { _preflight_halt "gate2 canary_preflight failed"; return 1; }
  CODEX_PRESENT="${canary_out#*codex_present=}"
  record_event LOCAL_CLI_CANARIES_PASSED \
    codex_present="$CODEX_PRESENT" reason="canary_preflight ok" || return 1

  # Gate 3: target dirty-tree gate. $SPEC_PATH/$PLAN_PATH/$FEATURE_FOLDER are
  # not yet derivable this early, so dirty_tree_check's own automatic
  # allow-list entries for them stay empty; $PROCESS_PATH lives in the OTHER
  # repository (PROCESS_REPO_ROOT != REPO_ROOT, enforced by validate_roots)
  # and never appears in $REPO_ROOT's own porcelain output regardless.
  dirty_tree_check || { _preflight_halt "gate3 dirty_tree_check failed"; return 1; }
  record_event TARGET_DIRTY_TREE_GATE_PASSED reason="dirty_tree_check ok" || return 1

  # Gate 4: process identity (already resolved by gate 1's
  # init_orchestration_vars) + gitignore guard (advisory only, never halts).
  local gitignore_warning
  gitignore_warning="$(verify_gitignore_guard)"
  [ -z "$gitignore_warning" ] || echo "$gitignore_warning" >&2
  record_event PROCESS_IDENTITY_AND_GITIGNORE_VALIDATED \
    develop_it_dirty="$PROCESS_DIRTY" develop_it_dirty_reason="${PROCESS_DIRTY_REASON:-}" \
    reason="identity resolved against PROCESS_REPO_ROOT" || return 1

  # Gate 5: runtime + registries. bootstrap_runtime is idempotent and safe
  # to call even when $RUNTIME_DIR already verifies (BOOTSTRAP_REUSED).
  #
  # MUST NOT be called inside a `$(...)` command substitution: bootstrap_
  # runtime's own doc comment says it sets ORCHESTRATION_DIR/RUNTIME_DIR
  # "non-local, for the rest of this phase's shell" -- a command
  # substitution forks a subshell, so those assignments (and every other
  # global bootstrap_runtime sets) would die with it, exactly the "never
  # rely on a subshell to preserve globals" rule `run_timed`'s own doc
  # comment already states elsewhere in this cookbook. Every other call
  # site in this document (e.g. the Phase 6 worked example above) calls it
  # bare for the same reason; capture its printed token via a plain
  # redirect instead, which does not fork.
  local bootstrap_result bootstrap_tmp bootstrap_err
  bootstrap_tmp="$(mktemp)"; bootstrap_err="$(mktemp)"
  if ! bootstrap_runtime >"$bootstrap_tmp" 2>"$bootstrap_err"; then
    # record_event's reason field is ONE line (blocks are blank-line
    # separated) -- bootstrap_runtime's own stderr can legitimately span
    # several (a token line plus indented detail), so flatten before
    # handing it to _preflight_halt.
    _preflight_halt "gate5 bootstrap_runtime failed: $(tr '\n' ' ' < "$bootstrap_err")"
    rm -f "$bootstrap_tmp" "$bootstrap_err"
    return 1
  fi
  cat "$bootstrap_err" >&2
  bootstrap_result="$(cat "$bootstrap_tmp")"
  rm -f "$bootstrap_tmp" "$bootstrap_err"
  # shellcheck disable=SC1090  # RUNTIME_DIR is set by bootstrap_runtime above, in THIS shell
  source "$RUNTIME_DIR/develop-it-runtime.sh" || return 1
  record_event RUNTIME_AND_REGISTRIES_VERIFIED \
    bootstrap_result="$bootstrap_result" reason="bootstrap_runtime ok" || return 1

  printf 'GATES_PASSED codex_present=%s\n' "$CODEX_PRESENT"
}

# Usage: vendor_proven_mark VENDOR ROLE [DISPATCH_ID]
# Call once, immediately after a substantive dispatch's classification comes
# back COMPLETED with a non-failure verdict. Idempotent: recording it twice
# is harmless (the reader only cares whether at least one exists after the
# last revocation). DISPATCH_ID, when known, rides on the common envelope's
# own `dispatch_id` field -- "role and event ID" evidence (spec S16.3) is the
# VENDOR_PROVEN event's own `event_id` (assigned by record_event) plus this.
vendor_proven_mark() {
  local vendor="$1" role="$2" dispatch_id="${3:-}"
  record_event VENDOR_PROVEN role="$role" vendor="$vendor" dispatch_id="$dispatch_id" \
    reason="substantive dispatch completed: role=$role vendor=$vendor"
}

# Usage: vendor_proven VENDOR   -> prints "true" or "false"
# A vendor is proven iff its LATEST relevant RUN_LOG entry (in file order) is
# a VENDOR_PROVEN event for that vendor, rather than a revoking signature for
# that vendor: `event=MODEL_REJECTED` (a rejected model id -- Phase -1's
# model-probe gate), or a DISPATCH_COMPLETED/ATTEMPT_FAILED entry whose
# classification is `SPEND_CEILING` (run-scoped spend ceiling) or
# `PERMANENT_VENDOR_ERROR` (classify_attempt's auth/permission/invalid-model
# refusal signature -- see "Ordered failure classification" above). A cheap
# probe or publication-loss failure (`TIMED_OUT`, `TRANSIENT_TRANSPORT_ERROR`,
# `EXITED_NO_STATUS`, `PUBLICATION_LOST`, `UNKNOWN_VENDOR_ERROR`) carries
# none of those, so it can never revoke a prior proof.
# Task 6 (P04): this used to be vendor_proven's own bespoke parser --
# `blocks = text.split("\n\n")` -- the exact blank-line split
# _run_log_events_json's own comment (above) documents as discredited: a
# VENDOR_PROVEN/DISPATCH_COMPLETED block whose `reason:` wraps onto a second
# line contains a blank line and would silently truncate or merge with its
# neighbor. Rewritten on the shared _run_log_latest_field reader instead: the
# LATEST event that is either a VENDOR_PROVEN for this vendor, a
# MODEL_REJECTED for this vendor, or ANY event for this vendor whose own
# `classification` field is SPEND_CEILING/PERMANENT_VENDOR_ERROR decides the
# answer -- exactly the three-way "latest wins" the old block scan
# implemented by hand, now expressed as one jq SELECT.
vendor_proven() {
  local vendor="$1" type
  type="$(_run_log_latest_field \
    '(.vendor // "")==$vendor and (._type=="VENDOR_PROVEN" or ._type=="MODEL_REJECTED" or .classification=="SPEND_CEILING" or .classification=="PERMANENT_VENDOR_ERROR")' \
    _type "vendor=$vendor")" || true
  if [ "$type" = VENDOR_PROVEN ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# Usage: vendor_preflight_reprobe_once VENDOR MODE
# Decides whether a per-phase preflight probe FAILURE (Modes 0-5, "Mode-
# specific response table") should be accepted at face value, or given one
# re-probe before the phase degrades to single-vendor coverage. This is
# what makes `vendor_proven` (spec S16.3) a real behavioural input at
# Phases 3/5/7 rather than write-only telemetry the per-phase gate never
# reads: a vendor already proven THIS run by a real substantive dispatch
# gets one extra chance against a probe wobble -- the SAME "known false
# negative, re-probe rather than degrade" pattern `skills_reprobe_needed`
# already applies to skill probes, generalized to vendor-availability
# probes. Mode 5 (quota/rate-limit signal) is excluded: it is evidence of
# an actual capacity problem, the closest this probe's own taxonomy comes
# to the "spend ceiling" signature that legitimately revokes proven
# capability -- re-probing it would just spend another cheap call to
# rediscover the same real quota exhaustion.
# Prints "yes" (re-probe once, then accept whatever the second probe says)
# or "no" (accept this failure immediately, degrade as before).
# NOTE ON SCOPE: "once" is once per per-phase gate, not once per run. This is
# a stateless decision keyed on (vendor_proven, mode), so a run that wobbles at
# Phases 3, 5 and 7 performs up to three re-probes -- one per gate. That is the
# intent: it mirrors the sticky-within-phase semantics of codex_available, and
# each re-probe is a single cheap `micro` call. A SUCCESSFUL re-probe records
# no event, so a run that wobbled and recovered leaves no audit trail of the
# retry; only the degradation path is durable.
vendor_preflight_reprobe_once() {
  local vendor="$1" mode="$2"
  case "$mode" in
    5) printf 'no\n'; return 0 ;;
  esac
  if [ "$(vendor_proven "$vendor" 2>/dev/null)" = true ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# Usage: latest_codex_outcome PHASE
# Zero-cost (no dispatch, no RUN_LOG write) lookup of the most recent codex
# per-phase-preflight outcome already durable for PHASE's own gate
# (iteration 00), read straight out of RUN_LOG.md. P09: Phase 6 no longer
# dispatches `preflight-codex` at all (it bought only an early-warning line
# for a full paid probe), so Step 6.−1 calls this against Phase 5, falling
# back to Phase 3, instead of running one. Scans blocks top-to-bottom
# (RUN_LOG is append-only) and keeps the LAST match, since a resumed run may
# have re-probed. Recognizes the three legal `(phase, iteration=00)` codex
# block shapes: a `DISPATCH_COMPLETED` for `role: preflight-codex`
# (`verdict: READY` or a confirmed `MISSING_SKILLS`/`UNCERTAIN`), a
# `CODEX_UNAVAILABLE` (`failure_mode: <N>`, or the literal
# `missing_skills`/`uncertain` mode string used by the skill-probe re-probe
# branches), or a `CODEX_SKIPPED_BY_USER_CONSENT`. Prints one of `READY`,
# `UNAVAILABLE mode=<N>`, `SKIPPED`, or `none` (no matching entry for that
# phase at all -- e.g. a fresh run that never reached that gate).
# Task 6 (P04): rewritten on the shared _run_log_latest_event reader instead
# of its own blank-line-split scanner (same discredited grammar vendor_proven
# used to hand-roll -- see the comment there). The LOG override this function
# has always accepted is threaded through via _run_log_latest_event's
# reserved `_log=` binding rather than duplicated here.
latest_codex_outcome() {
  local phase="$1" log="${2:-$FEATURE_FOLDER/RUN_LOG.md}"
  [ -f "$log" ] || { printf 'none\n'; return 0; }
  local select='(._type=="DISPATCH_COMPLETED" or ._type=="CODEX_UNAVAILABLE" or ._type=="CODEX_SKIPPED_BY_USER_CONSENT")
    and ((.phase // "")==$phase) and ((.iteration // "")=="00")
    and (._type!="DISPATCH_COMPLETED" or (.role // "")=="preflight-codex")'
  local hit
  hit="$(_run_log_latest_event "$select" "phase=$phase" "_log=$log")" || true
  if [ -z "$hit" ]; then
    printf 'none\n'; return 0
  fi
  local type verdict failure_mode
  type="$(printf '%s' "$hit" | jq -r '._type')"
  case "$type" in
    DISPATCH_COMPLETED)
      verdict="$(printf '%s' "$hit" | jq -r '.verdict // ""')"
      case "$verdict" in
        READY) printf 'READY\n' ;;
        "") printf 'none\n' ;;
        *) printf 'UNAVAILABLE mode=%s\n' "$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]')" ;;
      esac
      ;;
    CODEX_UNAVAILABLE)
      failure_mode="$(printf '%s' "$hit" | jq -r '.failure_mode // "unknown"')"
      printf 'UNAVAILABLE mode=%s\n' "$failure_mode"
      ;;
    *)
      printf 'SKIPPED\n'
      ;;
  esac
}

# Usage: applicable_optional_skills INSTALLED_CSV RELEVANT_CSV
# Both arguments are ";"-separated skill-name lists (the same convention the
# Role Contract Registry's own multi-valued cells use). Prints the ordered,
# deduplicated intersection, ";"-separated, on stdout -- installed skills
# NOT called for by this run's work types are never included, and relevant
# skills NOT installed never appear either (their absence is not a halt --
# see spec S16.4, "optional absence never halts").
applicable_optional_skills() {
  local installed="$1" relevant="$2"
  "$PYTHON_BIN" - "$installed" "$relevant" <<'PY'
import sys
installed = [s for s in sys.argv[1].split(";") if s]
relevant = [s for s in sys.argv[2].split(";") if s]
relevant_set = set(relevant)
seen = []
for s in installed:
    if s in relevant_set and s not in seen:
        seen.append(s)
print(";".join(seen))
PY
}

# Usage: skills_reprobe_needed PRIOR_READY_THIS_RUN FS_EVIDENCE_PRESENT PUBLICATION_LOST
#   PRIOR_READY_THIS_RUN   "yes" iff an earlier phase in the SAME run already
#                          recorded READY for this vendor (a per-phase missing
#                          claim contradicting that is the first trigger).
#   FS_EVIDENCE_PRESENT    "yes" iff a deterministic filesystem check (skill
#                          directory or SKILL.md present under a checked
#                          plugin root) shows the skill actually exists.
#   PUBLICATION_LOST       "yes" iff the attempt reached a `.tmp` STATUS
#                          publication but never renamed it (lost final
#                          STATUS -- see "File policy for non-READY paths").
# Prints "true" or "false". Any single "yes" among the three triggers one.
skills_reprobe_needed() {
  local prior_ready="${1:-no}" fs_evidence="${2:-no}" publication_lost="${3:-no}"
  case "$prior_ready$fs_evidence$publication_lost" in
    *yes*) printf 'true\n' ;;
    *)     printf 'false\n' ;;
  esac
}

# Extract the vendor's own error text from a dispatch's stdout transcript.
# Handles both shapes in one slurped pass: Claude's single `--output-format=json`
# envelope (`is_error` + `.result`) and Codex's `--json` JSONL error items.
# Prints nothing — and still succeeds — when the transcript holds no vendor
# error, so the caller distinguishes "no vendor error" from "no transcript" by
# emptiness, never by exit code.
vendor_error_text() {
  # Usage: vendor_error_text <stdout-transcript-path>
  local out="$1" txt=""
  [ -s "${out:-}" ] || return 0
  # `-s` (slurp) is what lets ONE filter serve both vendors: it reads a single
  # object into a 1-element array and JSONL into an N-element one. Without it
  # the Codex arm would need a second, near-identical invocation.
  txt="$(jq -rs '
    .[]
    | select(type == "object")
    | if .is_error == true then (.result // empty)
      elif (.error? != null) then (.error | if type == "string" then . else tojson end)
      else empty end
  ' "$out" 2>/dev/null)" || txt=""
  [ -n "$txt" ] || return 0
  # Bound it the same way the stderr tail is bounded: a .result can carry a
  # multi-kilobyte payload, and this text is destined for a user-facing halt.
  # Substring expansion, NOT `| head -c`: under the mandated `set -o pipefail`,
  # head closing the pipe early sends printf SIGPIPE and the function returns
  # 141 on exactly the inputs it handled correctly.
  printf '%s\n' "${txt:0:2000}"
}

post_dispatch() {
  # Usage: post_dispatch <rc> <status_path> <err_path> [out_path]
  # <out_path> is the stdout transcript ("$base.json"). It is the 4th and
  # optional argument only so that call sites predating the stdout-JSON rule
  # keep working; every new call site MUST pass it, or vendor-side refusals go
  # undiagnosed.
  local rc="$1" status_path="$2" err_path="$3" out_path="${4:-}"
  # An empty or non-numeric rc must be treated as a failure, not a syntax
  # error. Nothing writes a `.rc` file: this rc is passed in by the caller
  # (from `wait`'s exit status), so a bad value here means the caller itself
  # got confused, not that a control file was ever consulted.
  local rc_bad
  case "${rc:-}" in
    ''|*[!0-9]*) rc_bad=yes ;;
    0)           rc_bad=no ;;
    *)           rc_bad=yes ;;
  esac
  if [ "$rc_bad" = yes ] || [ ! -f "$status_path" ]; then
    echo "subprocess failed (rc=$rc, status_present=$( [ -f "$status_path" ] && echo yes || echo no ))" >&2
    local verr=""
    [ -n "$out_path" ] && verr="$(vendor_error_text "$out_path")"
    if [ -n "$verr" ]; then
      echo "vendor error (stdout JSON is_error):" >&2
      printf '%s\n' "$verr" >&2
    fi
    if [ -s "$err_path" ]; then
      tail -n 40 "$err_path" >&2
    else
      echo "(stderr empty — expected for vendor-side refusals; see the vendor error above)" >&2
    fi
    return 1
  fi
  return 0
}

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

# Legal verdicts and required extra fields, keyed by CONCRETE ROLE.
#
# Both resolve through the Role Contract Registry (`role_verdicts` /
# `role_required_status_fields`), not a hand-maintained case statement — the
# registry IS the contract for what a role's subagent writes, and
# tests/lib/verdicts.py + tests/check_06_cookbook.sh assert every appendix's
# own "Allowed verdicts" declaration agrees with it. An enum that merely looks
# plausible is worse than none: accepting an invalid verdict lets it fall
# through every gate `case` arm silently, and rejecting a LEGAL one turns a
# correct failure report into a bogus malformed-STATUS Mode 4.
_status_verdicts() {
  local v
  v="$(role_verdicts "$1" 2>/dev/null)" || return 1
  # Filter the `none` sentinel (impl-worker: a child-only role that writes no
  # STATUS at all) so it is never returned as if it were a legal verdict --
  # consistent with _status_required_fields' own common_v2/none filtering.
  printf '%s\n' "$v" | tr ';' '\n' | "$GREP_BIN" -v -E '^none$' | tr '\n' ' '
}

# Extra required fields beyond verdict/reason, keyed by concrete role.
# `common_v2` (verdict/reason/cost_hint) is handled by validate_status's own
# generic rules below, not repeated here — only the role-specific extras
# beyond that common baseline are returned. `none` (the impl-worker sentinel —
# it writes no STATUS at all) likewise contributes no required field.
_status_required_fields() {
  local v
  v="$(role_required_status_fields "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$v" | tr ';' '\n' | "$GREP_BIN" -v -E '^(common_v2|none)$' | tr '\n' ' '
}

# Validate a STATUS file's shape before branching on it.
# Note: the PCRE/GNU non-whitespace shorthand is not valid POSIX ERE — use
# [^[:space:]] instead.
validate_status() {
  # Usage: validate_status <status-path> <role>
  # <role> is a CONCRETE role key, not a category.
  local path="$1" role="$2" v verdict legal ok k
  if [ ! -f "$path" ]; then
    echo "invalid status: missing file: $path" >&2; return 1
  fi
  if ! "$GREP_BIN" -qE '^verdict:[[:space:]]*[^[:space:]]' "$path"; then
    echo "invalid status: no non-empty verdict: field in $path" >&2; return 1
  fi

  legal="$(_status_verdicts "$role")" \
    || { echo "validate_status: unknown role '$role'" >&2; return 1; }
  verdict="$(status_field "$path" verdict)"
  ok=no
  for v in $legal; do [ "$verdict" = "$v" ] && ok=yes; done
  if [ "$ok" = no ]; then
    echo "invalid status: verdict '$verdict' is not legal for role $role [$legal] in $path" >&2
    return 1
  fi

  # Contract rule 4 (line 797): any verdict other than PASS/READY/DONE requires a
  # non-empty one-line reason. SKIPPED counts as needing one — it explains why.
  case "$verdict" in
    PASS|READY|DONE) : ;;
    *)
      if [ -z "$(status_field "$path" reason)" ]; then
        echo "invalid status: verdict '$verdict' requires a non-empty reason: in $path" >&2
        return 1
      fi ;;
  esac

  for k in $(_status_required_fields "$role"); do
    v="$(status_field "$path" "$k")"
    if [ -z "$v" ]; then
      echo "invalid status: role $role requires '$k:' in $path" >&2; return 1
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
      verification)
        # Contract rule 5 (line 798).
        case "$v" in
          PASS|FAIL|PARTIAL) : ;;
          *) echo "invalid status: verification must be PASS|FAIL|PARTIAL, got '$v' in $path" >&2
             return 1 ;;
        esac ;;
      context7)
        case "$v" in
          reachable|unreachable) : ;;
          *) echo "invalid status: context7 must be reachable|unreachable, got '$v' in $path" >&2
             return 1 ;;
        esac ;;
    esac
  done
  return 0
}

# Reconstruct the context7 policy from durable state. Called at the top of
# EVERY phase block and on resume -- never assigned once and relied upon later,
# because shell variables do not survive a phase boundary.
#
# Full spec S15.5 precedence, latest-event-wins (Task 8): the LATEST valid
# CONTEXT7_UNAVAILABLE/CONTEXT7_RESTORED event in RUN_LOG.md always overrides
# a Phase 1 STATUS reading that came before it -- a Phase-1-reachable probe
# does NOT stay "required" forever if a later phase records the server going
# unavailable. CONTEXT7_RESTORED only overrides back to "required" when its
# own `probe:` field cites a successful deterministic probe; any other value
# (or a missing probe field) is a restoration claim without evidence, so it
# stays best-effort. Only with NO such event anywhere does this fall back to
# Phase 1's own STATUS reading -- previously the ONLY signal this function
# consulted, which meant a later CONTEXT7_UNAVAILABLE could never downgrade
# an already-reachable Phase 1 reading.
# Task 6 (P04): rewritten on the shared _run_log_latest_event reader instead
# of its own line-by-line tag/probe state machine. Fetching the LATEST event
# whose type is either CONTEXT7_UNAVAILABLE or CONTEXT7_RESTORED as one JSON
# object -- rather than tracking `tag`/`probe` by hand across every line --
# also removes the need to manually reset `probe` at each new header: the
# parser already scopes fields to their own block.
context7_policy() {
  local log="$FEATURE_FOLDER/RUN_LOG.md" last="" probe="" hit=""
  if [ -f "$log" ]; then
    hit="$(_run_log_latest_event '._type=="CONTEXT7_UNAVAILABLE" or ._type=="CONTEXT7_RESTORED"')" || true
    if [ -n "$hit" ]; then
      last="$(printf '%s' "$hit" | jq -r '._type')"
      probe="$(printf '%s' "$hit" | jq -r '(.probe // "") | gsub("\\s";"")')"
    fi
  fi
  case "$last" in
    CONTEXT7_UNAVAILABLE)
      printf 'best-effort\n'; return 0 ;;
    CONTEXT7_RESTORED)
      if [ "$probe" = success ]; then
        printf 'required\n'; return 0
      fi
      printf 'best-effort\n'; return 0
      ;;
  esac
  local st="$FEATURE_FOLDER/1-preflight/phase-1/claude-check-status.md"
  if [ -f "$st" ] && [ "$(status_field "$st" context7)" = reachable ]; then
    printf 'required\n'; return 0
  fi
  # No evidence either way: refuse to guess. Guessing `required` would make
  # every dispatch fail; guessing `best-effort` would silently weaken the run.
  echo "halt: cannot determine context7 policy; Phase 1 STATUS and RUN_LOG both silent" >&2
  return 1
}

# ---- Structural artifact manifest (spec §17.1) -----------------------------
_artifact_manifest_field() {
  # Usage: _artifact_manifest_field ROLE FIELD
  # FIELD in: output_var, min_bytes, required_headings, forbidden_markers,
  # revision_calc, requires_complete_marker.
  case "$1:$2" in
    plan-writer:output_var)                  echo PLAN_PATH ;;
    plan-writer:min_bytes)                    echo 200 ;;
    plan-writer:required_headings)            echo "Goal;File Structure and Responsibilities" ;;
    plan-writer:forbidden_markers)            echo 'TBD;<placeholder>;TODO: fill in' ;;
    plan-writer:revision_calc)                echo sha256 ;;
    plan-writer:requires_complete_marker)     echo yes ;;

    spec-fixer:output_var)                    echo SPEC_PATH ;;
    spec-fixer:min_bytes)                     echo 100 ;;
    spec-fixer:required_headings)             echo "" ;;
    spec-fixer:forbidden_markers)             echo '...(truncated);<!-- TRUNCATED -->' ;;
    spec-fixer:revision_calc)                 echo sha256 ;;
    spec-fixer:requires_complete_marker)      echo no ;;

    plan-fixer:output_var)                    echo PLAN_PATH ;;
    plan-fixer:min_bytes)                      echo 200 ;;
    plan-fixer:required_headings)             echo "" ;;
    plan-fixer:forbidden_markers)             echo '...(truncated);<!-- TRUNCATED -->' ;;
    plan-fixer:revision_calc)                 echo sha256 ;;
    plan-fixer:requires_complete_marker)      echo no ;;

    implementer:output_var)                   echo IMPLEMENTATION_SUMMARY_PATH ;;
    implementer:min_bytes)                    echo 100 ;;
    implementer:required_headings)            echo "" ;;
    implementer:forbidden_markers)            echo '...(truncated);<!-- TRUNCATED -->' ;;
    implementer:revision_calc)                echo git_sha ;;
    implementer:requires_complete_marker)     echo no ;;

    implementation-fixer:output_var)               echo IMPLEMENTATION_SUMMARY_PATH ;;
    implementation-fixer:min_bytes)                echo 100 ;;
    implementation-fixer:required_headings)        echo "" ;;
    implementation-fixer:forbidden_markers)        echo '...(truncated);<!-- TRUNCATED -->' ;;
    implementation-fixer:revision_calc)            echo git_sha ;;
    implementation-fixer:requires_complete_marker) echo no ;;

    *) echo "ARTIFACT_MANIFEST_UNKNOWN:$1:$2" >&2; return 1 ;;
  esac
}

# `validate_artifact ROLE DISPATCH_ID` (spec §17.1) -- runs before
# dispatching a review gate's reviewers against a producer's revision. The
# attempt directory (and so the STATUS path) is derived from DISPATCH_ID's
# OWN encoded phase/iteration tokens via `role_attempt_dir` -- never from
# ambient $PHASE_DIR/$ITERATION, which would name the wrong directory at
# the two cross-phase call sites this task introduces (Phase 5 validating
# Phase 4's plan-writer; Phase 7 validating Phase 6's implementer run with
# the CALLING phase's own ambient values, not the producer's). Requires an
# accepted verdict (`DONE`, or an explicit
# RUN_LOG `event=PHASE_ACCEPTED` decision naming this exact artifact_path --
# spec §17.1's "explicit accepted partial-artifact decision" for a producer
# whose own STATUS was never DONE; no role's registry ever lists
# PHASE_ACCEPTED as a legal STATUS verdict, so this is read from RUN_LOG,
# never from the producer's own STATUS file), requires the manifest's output
# path to resolve inside $FEATURE_FOLDER or $REPO_ROOT, requires the
# manifest to pass (size, headings, forbidden markers, revision, completion
# marker), and prints "revision=<value>" on success. Size or marker presence
# ALONE never authorizes review -- every check below must pass, not just one.
_validate_artifact_phase_accepted() {
  # Usage: _validate_artifact_phase_accepted ARTIFACT_PATH
  # True iff RUN_LOG.md carries a durable event=PHASE_ACCEPTED block whose
  # OWN artifact_path field names this exact artifact.
  # Task 6 (P04): rewritten on the shared _run_log_latest_field reader
  # instead of its own line-by-line tag scan -- "does a match exist at all"
  # falls out of _run_log_latest_field's own exit-1-on-no-match contract, so
  # there is no separate `match` flag to thread through by hand.
  local artifact_path="$1" log="${FEATURE_FOLDER:-}/RUN_LOG.md" want
  [ -f "$log" ] || return 1
  want="$(printf '%s' "$artifact_path" | tr -d '[:space:]')"
  _run_log_latest_field \
    '._type=="PHASE_ACCEPTED" and ((.artifact_path // "") | gsub("\\s";"")) == $want' \
    _type "want=$want" >/dev/null
}

validate_artifact() {
  local role="$1" dispatch_id="$2"
  local attempt_dir status_path
  attempt_dir="$(role_attempt_dir "$role" "$dispatch_id")" \
    || { echo "VALIDATE_ARTIFACT_BAD_DISPATCH_ID:$dispatch_id" >&2; return 1; }
  status_path="$attempt_dir/STATUS.md"
  [ -f "$status_path" ] || { echo "VALIDATE_ARTIFACT_NO_STATUS:$status_path" >&2; return 1; }
  validate_status "$status_path" "$role" || { echo "VALIDATE_ARTIFACT_BAD_STATUS" >&2; return 1; }

  local output_var min_bytes headings_csv forbidden_csv revision_calc needs_marker
  output_var="$(_artifact_manifest_field "$role" output_var)" || return 1
  min_bytes="$(_artifact_manifest_field "$role" min_bytes)" || return 1
  headings_csv="$(_artifact_manifest_field "$role" required_headings)" || return 1
  forbidden_csv="$(_artifact_manifest_field "$role" forbidden_markers)" || return 1
  revision_calc="$(_artifact_manifest_field "$role" revision_calc)" || return 1
  needs_marker="$(_artifact_manifest_field "$role" requires_complete_marker)" || return 1

  local artifact_path="${!output_var:-}"
  [ -n "$artifact_path" ] || { echo "VALIDATE_ARTIFACT_NO_PATH_VAR:$output_var" >&2; return 1; }

  local verdict; verdict="$(status_field "$status_path" verdict)"
  case "$verdict" in
    # DONE_WITH_EXCLUSIONS (spec S19.2) is a second legitimate implementer
    # terminal verdict -- the whole point of Step 6 is that Phase 7 can
    # review an implementation that ends here just as it reviews a plain
    # DONE. No other role's registry row legalizes this verdict (validate_status
    # already rejects it there), so widening this case costs nothing for
    # any other caller of validate_artifact.
    DONE|DONE_WITH_EXCLUSIONS) : ;;
    *)
      _validate_artifact_phase_accepted "$artifact_path" \
        || { echo "VALIDATE_ARTIFACT_NOT_ACCEPTED:$verdict" >&2; return 1; }
      ;;
  esac

  [ -f "$artifact_path" ] || { echo "VALIDATE_ARTIFACT_MISSING_FILE:$artifact_path" >&2; return 1; }

  local resolved in_root=no root
  resolved="$(realpath -m -- "$artifact_path" 2>/dev/null)" || resolved="$artifact_path"
  for root in "$FEATURE_FOLDER" "${REPO_ROOT:-}"; do
    [ -n "$root" ] || continue
    root="$(realpath -m -- "$root" 2>/dev/null)" || continue
    path_in_tree "$resolved" "$root" && { in_root=yes; break; }
  done
  [ "$in_root" = yes ] || { echo "VALIDATE_ARTIFACT_OUTSIDE_ROOT:$artifact_path" >&2; return 1; }

  local nonblank_bytes
  nonblank_bytes="$(tr -d '[:space:]' < "$artifact_path" | wc -c)"
  if [ "$nonblank_bytes" -lt "$min_bytes" ]; then
    echo "VALIDATE_ARTIFACT_TOO_SMALL:$nonblank_bytes<$min_bytes" >&2; return 1
  fi

  if [ -n "$headings_csv" ]; then
    local -a _va_h; IFS=';' read -r -a _va_h <<<"$headings_csv"
    local h
    for h in "${_va_h[@]}"; do
      [ -n "$h" ] || continue
      # Heading-anchored: a required heading "Goal" must appear as an ACTUAL
      # ATX heading line (optionally followed by more words -- "## Goal
      # Statement" counts), never merely as a substring anywhere in the file
      # (a plain grep -F would let "## Non-Goals" satisfy a "Goal"
      # requirement).
      "$GREP_BIN" -qE -- "^#{1,6}[[:space:]]+${h}([[:space:]]|\$)" "$artifact_path" \
        || { echo "VALIDATE_ARTIFACT_MISSING_HEADING:$h" >&2; return 1; }
    done
  fi

  if [ -n "$forbidden_csv" ]; then
    local -a _va_f; IFS=';' read -r -a _va_f <<<"$forbidden_csv"
    local m
    for m in "${_va_f[@]}"; do
      [ -n "$m" ] || continue
      "$GREP_BIN" -qF -- "$m" "$artifact_path" \
        && { echo "VALIDATE_ARTIFACT_FORBIDDEN_MARKER:$m" >&2; return 1; }
    done
  fi

  local revision declared
  declared="$(status_field "$status_path" artifact_revision)"
  case "$revision_calc" in
    sha256)
      revision="$(sha256sum "$artifact_path" | awk '{print $1}')"
      if [ -n "$declared" ] && [ "$declared" != null ] && [ "$declared" != "$revision" ]; then
        echo "VALIDATE_ARTIFACT_REVISION_MISMATCH:declared=$declared computed=$revision" >&2
        return 1
      fi
      ;;
    git_sha)
      [ -n "$declared" ] && [ "$declared" != null ] \
        || { echo "VALIDATE_ARTIFACT_NO_DECLARED_REVISION" >&2; return 1; }
      revision="$declared"
      ;;
    *) echo "VALIDATE_ARTIFACT_BAD_REVISION_CALC:$revision_calc" >&2; return 1 ;;
  esac

  if [ "$needs_marker" = yes ]; then
    local marker="$attempt_dir/artifact-complete.json"
    [ -f "$marker" ] || { echo "VALIDATE_ARTIFACT_MISSING_COMPLETE_MARKER:$marker" >&2; return 1; }
  fi

  printf 'revision=%s\n' "$revision"
}

# ---- Finding ingestion (spec §17.2) -----------------------------------------
_iteration_dir_from_status() {
  # Usage: _iteration_dir_from_status STATUS_PATH
  # STATUS_PATH is always <iteration-dir>/attempts/<dispatch-id>/STATUS.md.
  dirname "$(dirname "$(dirname "$1")")"
}

# Usage: ingest_findings ROLE STATUS_FILE OUTPUT_JSONL
# Prints "blockers=N", "majors=N", "minors=N" (post-merge, catalog-wide, open/
# reopened counts only) on success.
ingest_findings() {
  local role="$1" status_file="$2" output_jsonl="$3"
  [ -f "$status_file" ] || { echo "INGEST_FINDINGS_NO_STATUS:$status_file" >&2; return 1; }
  [ -f "$output_jsonl" ] || { echo "INGEST_FINDINGS_NO_OUTPUT:$output_jsonl" >&2; return 1; }
  validate_status "$status_file" "$role" || { echo "INGEST_FINDINGS_BAD_STATUS" >&2; return 1; }

  local iter_dir catalog tmp existing out rc
  iter_dir="$(_iteration_dir_from_status "$status_file")"
  catalog="$iter_dir/findings-catalog.jsonl"
  mkdir -p "$iter_dir"
  tmp="$catalog.tmp.$$"
  existing="/dev/null"
  [ -f "$catalog" ] && existing="$catalog"

  out="$("$PYTHON_BIN" - "$existing" "$output_jsonl" "$tmp" <<'PY'
import sys, json, re, unicodedata, hashlib, ast, os, difflib

existing_path, input_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def norm_text(s):
    s = unicodedata.normalize("NFKC", s or "").strip().lower()
    s = re.sub(r'[`*_]+', '', s)
    s = re.sub(r'\\(.)', r'\1', s)
    s = re.sub(r'\s+', ' ', s)
    return s

def norm_issue_key(s):
    s = unicodedata.normalize("NFKC", s or "").strip().lower()
    s = re.sub(r'[_\s]+', '-', s)
    s = re.sub(r'-{2,}', '-', s)
    return s.strip('-')

HEADING_RE = re.compile(r'^(#{1,6})\s+(.*)$')
FENCE_RE = re.compile(r'^(```|~~~)')
TABLE_RE = re.compile(r'^\s*\|')
LIST_RE = re.compile(r'^\s*([-*+]|\d+\.)\s+')
QUOTE_RE = re.compile(r'^\s*>')
ANCHOR_RE = re.compile(r'\{#([A-Za-z0-9_-]+)\}\s*$')

def markdown_location(path, line_no, weak_out):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError:
        weak_out["weak"] = True
        return f"UNREADABLE:{path}"

    stack = []
    root_counts = {}
    breadcrumbs = [None] * (len(lines) + 2)
    for i, raw in enumerate(lines, start=1):
        m = HEADING_RE.match(raw)
        if m:
            level = len(m.group(1))
            text = m.group(2)
            am = ANCHOR_RE.search(text)
            anchor = am.group(1) if am else None
            text = ANCHOR_RE.sub('', text).strip()
            while stack and stack[-1]["level"] >= level:
                stack.pop()
            parent_counts = stack[-1]["counts"] if stack else root_counts
            key = (level, norm_text(text))
            parent_counts[key] = parent_counts.get(key, 0) + 1
            stack.append({"level": level, "text": norm_text(text),
                          "occurrence": parent_counts[key], "counts": {},
                          "anchor": anchor})
        breadcrumbs[i] = list(stack)

    idx = max(1, min(line_no, len(lines))) if lines else 1
    bc = breadcrumbs[idx] or []
    raw_line = lines[idx - 1] if 0 <= idx - 1 < len(lines) else ""

    if HEADING_RE.match(raw_line):
        kind = "heading"
    elif TABLE_RE.match(raw_line):
        kind = "table"
    elif LIST_RE.match(raw_line):
        kind = "list-item"
    elif QUOTE_RE.match(raw_line):
        kind = "blockquote"
    elif FENCE_RE.match(raw_line):
        kind = "code-fence"
    elif raw_line.strip() == "":
        kind = "blank"
    else:
        kind = "paragraph"

    fingerprint = hashlib.sha256(norm_text(raw_line).encode("utf-8")).hexdigest()[:16]
    anchor = bc[-1]["anchor"] if bc and bc[-1].get("anchor") else None
    # An explicit anchor is a SECTION-level id, constant for every line in
    # that section -- it must never REPLACE the per-line fingerprint (that
    # would collapse every distinct finding in an anchored section onto one
    # locator) or ADD to it (spec S17.2's disambiguator).
    tail = f"{anchor}:{fingerprint}" if anchor else fingerprint
    crumb = "/".join(f"{n['text']}#{n['occurrence']}" for n in bc)
    return f"{crumb}::{kind}:{tail}"

def code_location(path, line_no, weak_out):
    if path.endswith(".py"):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                src = f.read()
            tree = ast.parse(src)
            best = None
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    lo = node.lineno
                    hi = getattr(node, "end_lineno", lo)
                    if lo <= line_no <= hi and (best is None or (hi - lo) < (best[1] - best[0])):
                        best = (lo, hi, node.name)
            if best:
                return f"{path}::{best[2]}"
        except (OSError, SyntaxError):
            pass
    else:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                lines = f.read().split("\n")
            decl_re = re.compile(
                r'^\s*(?:export\s+)?(?:async\s+)?(?:function|def|class|func|fn)\s+([A-Za-z_][A-Za-z0-9_]*)')
            for i in range(min(line_no, len(lines)), 0, -1):
                m = decl_re.match(lines[i - 1] or '')
                if m:
                    return f"{path}::{m.group(1)}"
        except OSError:
            pass
    weak_out["weak"] = True
    return f"{path}::line:{line_no}"

def load_jsonl(path):
    records = []
    if path in ("/dev/null", "", None) or not os.path.exists(path):
        return records
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records

REQUIRED = ["source_finding_id", "reviewer_role", "vendor", "phase", "iteration",
            "severity", "artifact_path", "issue_key"]

catalog = {}
for rec in load_jsonl(existing_path):
    catalog[rec["finding_id"]] = rec

collisions = []
seen_this_round = set()

for rec in load_jsonl(input_path):
    missing = [k for k in REQUIRED if not rec.get(k)]
    if missing:
        print(f"REJECTED:{rec.get('source_finding_id','?')}:missing={','.join(missing)}", file=sys.stderr)
        sys.exit(3)
    if rec["severity"] not in ("blocker", "major", "minor"):
        print(f"REJECTED:{rec['source_finding_id']}:bad-severity", file=sys.stderr)
        sys.exit(3)

    artifact_kind = rec.get("artifact_kind") or (
        "markdown" if rec["artifact_path"].endswith(".md") else "code")
    weak = {"weak": False}
    line_no = int(rec.get("line") or 0)
    if artifact_kind == "markdown":
        normalized_location = markdown_location(rec["artifact_path"], line_no, weak)
    else:
        normalized_location = code_location(rec["artifact_path"], line_no, weak)
    normalized_issue_key = norm_issue_key(rec["issue_key"])

    finding_id = hashlib.sha256(
        (artifact_kind + "\0" + normalized_location + "\0" + normalized_issue_key)
        .encode("utf-8")).hexdigest()

    supplied = rec.get("finding_id")
    if supplied and supplied != finding_id:
        print(f"MISMATCH:{rec['source_finding_id']}:{supplied}!={finding_id}", file=sys.stderr)
        sys.exit(4)

    severity = rec["severity"]
    prior = catalog.get(finding_id)
    provenance = rec.get("provenance") or "unknown"
    origin_iteration = rec.get("origin_iteration") or rec["iteration"]
    status = "open"
    recur_count = 0
    if prior:
        recur_count = prior.get("recur_count", 0)
        origin_iteration = prior.get("origin_iteration", origin_iteration)
        prior_severity = prior.get("severity")
        # Two records for the SAME (artifact_kind, normalized_location,
        # normalized_issue_key) legitimately vary in wording round to round
        # (fresh reviewer subprocesses write their own prose) -- that alone
        # is never a reason to DROP the re-report (code review fix: an
        # earlier version `continue`d here, which skipped the reopen logic
        # below entirely and let a fixer's stale fixed/verified claim
        # survive an unresolved re-report -- the same failure class as the
        # original wording-based bug, reached via severity instead). Any
        # content difference (severity, summary, or required_change) is
        # still recorded via `collisions` as an EVENT_CORRECTED audit
        # signal -- but it NEVER changes which record wins or skips the
        # reopen/promotion logic below.
        # Fresh reviewer subprocesses write their OWN prose every round --
        # an ordinary re-report of the SAME issue routinely rewords its
        # summary/required_change and must NOT be treated as a collision
        # (that was the actual round-1 wording bug's root cause). Only fire
        # the EVENT_CORRECTED audit signal when the classification itself
        # conflicts (severity mismatch), or the content is so different it
        # reads as a genuinely different finding, not a reword -- difflib's
        # stdlib similarity ratio is the cheap, dependency-free proxy for
        # "large content divergence" (ponytail: one crude global threshold,
        # not per-domain tuned; revisit if a real run's false-positive/
        # negative rate on it ever matters).
        def _diverges(a, b):
            return difflib.SequenceMatcher(None, a or "", b or "").ratio() < 0.5
        if (prior_severity and prior_severity != severity) or (
                _diverges(prior.get("summary", ""), rec.get("summary", ""))
                or _diverges(prior.get("required_change", ""), rec.get("required_change", ""))):
            collisions.append(finding_id)
        if prior_severity and prior_severity != severity:
            sev_rank = {"blocker": 0, "major": 1, "minor": 2}
            if sev_rank.get(prior_severity, 9) < sev_rank.get(severity, 9):
                # prior is already the more severe classification -- keep
                # THAT severity (never silently downgrade), but still fall
                # through to the reopen logic below using the freshly
                # reported record's own content otherwise.
                severity = prior_severity
                rec = dict(rec)
                rec["severity"] = severity
        if prior.get("status") in ("fixed", "verified"):
            provenance = "fix_regression"
            status = "reopened"
            recur_count = prior.get("recur_count", 0) + 1
        else:
            status = prior.get("status", "open")
            if status in ("accepted_risk", "deferred", "superseded"):
                status = "reopened"

    merged = dict(rec)
    merged["finding_id"] = finding_id
    merged["normalized_location"] = normalized_location
    merged["normalized_issue_key"] = normalized_issue_key
    merged["provenance"] = provenance
    merged["origin_iteration"] = origin_iteration
    merged["status"] = status
    merged["recur_count"] = recur_count
    merged["weak_location"] = bool(weak["weak"])
    merged.setdefault("related_finding_ids", [])
    catalog[finding_id] = merged
    seen_this_round.add(finding_id)

# ponytail: promotion is keyed on "not re-reported THIS ingestion call",
# not on "the reviewer whose ingestion this is actually covers this
# finding's artifact/section" -- a reviewer role that structurally cannot
# see a given artifact_path (e.g. a spec-only reviewer silently clean on a
# code finding) would incorrectly promote it. Every real call site in this
# document ingests exactly the reviewer round that DOES cover the artifact
# under review at that gate, so this does not misfire in practice; add an
# artifact_path/reviewer-scope filter here if a future gate ever ingests
# multiple unrelated artifacts through the same iteration catalog.
for fid, rec in catalog.items():
    if fid in seen_this_round:
        continue
    if rec.get("status") == "fixed":
        rec["status"] = "verified"

with open(out_path, "w", encoding="utf-8") as f:
    for fid in sorted(catalog):
        f.write(json.dumps(catalog[fid], sort_keys=True) + "\n")

OPEN_STATUSES = ("open", "reopened")
blockers = sum(1 for r in catalog.values() if r["severity"] == "blocker" and r["status"] in OPEN_STATUSES)
majors = sum(1 for r in catalog.values() if r["severity"] == "major" and r["status"] in OPEN_STATUSES)
minors = sum(1 for r in catalog.values() if r["severity"] == "minor" and r["status"] in OPEN_STATUSES)
print(f"blockers={blockers}")
print(f"majors={majors}")
print(f"minors={minors}")
print(f"collisions={','.join(collisions)}")
PY
)"
  rc=$?
  case $rc in
    0) : ;;
    3) echo "INGEST_FINDINGS_INVALID_RECORD" >&2; echo "$out" >&2; return 1 ;;
    4) echo "INGEST_FINDINGS_ID_MISMATCH" >&2; echo "$out" >&2; return 1 ;;
    *) echo "INGEST_FINDINGS_INTERNAL_ERROR:$rc" >&2; echo "$out" >&2; return 1 ;;
  esac

  mv "$tmp" "$catalog"

  local collisions_csv
  collisions_csv="$(printf '%s\n' "$out" | "$GREP_BIN" '^collisions=' | cut -d= -f2-)"
  if [ -n "$collisions_csv" ]; then
    local -a _if_coll; IFS=',' read -r -a _if_coll <<<"$collisions_csv"
    local fid
    for fid in "${_if_coll[@]}"; do
      [ -n "$fid" ] || continue
      record_event EVENT_CORRECTED corrected_event_id="finding:$fid" \
        replacement_classification=finding_collision \
        evidence="canonical id collision: conflicting severity classification" \
        downstream_effect=kept_more_severe_classification \
        phase="$(status_field "$status_file" phase)" \
        iteration="$(status_field "$status_file" iteration)" \
        reason="ingest_findings: colliding finding severity for $fid" >/dev/null \
        || { echo "INGEST_FINDINGS_EVENT_CORRECTED_FAILED:$fid" >&2; return 1; }
    done
  fi

  printf '%s\n' "$out" | "$GREP_BIN" -E '^(blockers|majors|minors)='
}

# ---- Bounded fixer batching and disposition ledger (spec §17.3, §18.4) -----
# Usage: select_finding_batch CATALOG_PATH
# Prints a SPACE-separated list of at most `document_fixer_batch_size` open/
# reopened blocker+major finding IDs (blockers first, then oldest
# origin_iteration first) -- never minors, which fixers address
# opportunistically, not as part of a bounded batch. Space-separated (not
# comma-separated) so an unquoted `$FINDING_IDS` expansion word-splits into
# separate positional args wherever a caller (dispositions_complete, a
# fixer's own per-ID loop) needs that -- a hex sha256 finding_id can never
# itself contain whitespace, so this is a safe delimiter choice.
select_finding_batch() {
  local catalog="$1" cap
  cap="$(policy_value document_fixer_batch_size)" || return 1
  [ -f "$catalog" ] || { printf '\n'; return 0; }
  jq -s -r --argjson cap "$cap" '
    map(select((.status=="open" or .status=="reopened")
               and (.severity=="blocker" or .severity=="major")))
    | sort_by([(if .severity=="blocker" then 0 else 1 end), .origin_iteration])
    | .[0:$cap]
    | map(.finding_id)
    | join(" ")
  ' "$catalog"
}

# Usage: record_finding_disposition CATALOG_PATH FINDING_ID DISPOSITION [EVIDENCE]
# DISPOSITION is exactly one of: fixed, already_satisfied, blocked,
# subsumed_by:<finding_id>, accepted_risk:<decision_id>, deferred:<followup_id>
# (spec §17.3). These map onto the catalog's own mandated `status` vocabulary
# (spec §17.2: open|fixed|verified|accepted_risk|deferred|superseded) -- NEVER
# the raw disposition token itself, which is why `blocked`/`already_satisfied`/
# `subsumed_by` are not catalog-status values: `blocked` stays "open" (a fixer
# admitting it could NOT act must never close the gate -- it also sets the
# fixer's own dispatch verdict=BLOCKED, which HALTs separately);
# `already_satisfied` maps to "fixed" (the SAME fixer-can't-close-its-own-
# finding rule as an actual fix: only a subsequent reviewer round not
# re-reporting it promotes it to "verified"); `subsumed_by:*` maps to
# "superseded". This vocabulary deliberately has NO "verified" value -- only
# ingest_findings (driven by a FRESH reviewer round) can ever promote a
# catalog entry to "verified"; a fixer calling this function can never close
# its own finding (spec §18.1's proof). The full disposition string (with its
# `:<id>` suffix) is preserved verbatim in `.disposition`, separate from the
# mapped `.status`.
record_finding_disposition() {
  local catalog="$1" fid="$2" disposition="$3" evidence="${4:-}"
  [ -f "$catalog" ] || { echo "DISPOSITION_NO_CATALOG:$catalog" >&2; return 1; }
  local base
  case "$disposition" in
    fixed|already_satisfied) base="fixed" ;;
    blocked)                 base="open" ;;
    subsumed_by:*)   base="superseded" ;;
    accepted_risk:*) base="accepted_risk" ;;
    deferred:*)      base="deferred" ;;
    *) echo "DISPOSITION_BAD_VALUE:$disposition" >&2; return 1 ;;
  esac
  jq -e --arg id "$fid" 'select(.finding_id==$id)' "$catalog" >/dev/null 2>&1 \
    || { echo "DISPOSITION_UNKNOWN_FINDING:$fid" >&2; return 1; }

  local lockfile="$catalog.lock"
  _run_log_lock_acquire "$lockfile" || return 1
  local tmp="$catalog.tmp.$$"
  if ! jq -c --arg id "$fid" --arg base "$base" --arg disp "$disposition" \
        --arg ev "$evidence" --arg ts "$(iso_now)" '
    if .finding_id == $id
    then .status = $base | .disposition = $disp | .disposition_evidence = $ev
         | .disposition_by = "fixer" | .disposition_at = $ts
    else . end' "$catalog" > "$tmp"
  then
    rm -f "$tmp"; _run_log_lock_release "$lockfile"
    echo "DISPOSITION_WRITE_FAILED" >&2; return 1
  fi
  mv "$tmp" "$catalog"
  _run_log_lock_release "$lockfile"
}

# Usage: dispositions_complete CATALOG_PATH FINDING_ID...
# 0 iff every named finding's catalog status is no longer open/reopened --
# NOT simply "has a disposition recorded": `blocked` IS one of the six
# legal dispositions (spec S17.3) but deliberately maps to status=open (it
# must never close the gate), so a finding disposed `blocked` still reports
# missing here. Harmless in practice -- a `blocked` disposition also sets
# the fixer's own dispatch verdict=BLOCKED, which HALTs before this would
# ever matter -- but the check is genuinely "is the gate unblocked", not
# "did every ID get touched".
dispositions_complete() {
  local catalog="$1"; shift
  local -a missing=()
  local fid st
  for fid in "$@"; do
    [ -n "$fid" ] || continue
    st="$(jq -r --arg id "$fid" 'select(.finding_id==$id) | .status' "$catalog" 2>/dev/null | tail -n1)"
    case "$st" in open|reopened|"") missing+=("$fid") ;; esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    local IFS=,
    echo "DISPOSITIONS_MISSING:${missing[*]}" >&2
    return 1
  fi
  return 0
}

# ---- Convergence signals and divergence detection (spec §18.3) -------------
# Usage: record_convergence_signals PHASE ITERATION BYTES_BEFORE BYTES_AFTER \
#   NEW_COUNT RECURRING_COUNT RESOLVED_COUNT REOPENED_COUNT FIX_REGRESSION_COUNT NET_OPEN
record_convergence_signals() {
  local phase="$1" iteration="$2" before="$3" after="$4" new_c="$5" recurring="$6" \
        resolved="$7" reopened="$8" fix_regression="$9" net_open="${10}"
  local growth_pct=0
  if [ "$before" -gt 0 ] 2>/dev/null; then
    growth_pct=$(( ((after - before) * 100) / before ))
  fi
  local phase_name; phase_name="$(_phase_name "$phase")" || return 1
  record_event CONVERGENCE_RECORDED phase="$phase" iteration="$iteration" \
    phase_name="$phase_name" growth_pct="$growth_pct" new_count="$new_c" \
    recurring_count="$recurring" resolved_count="$resolved" reopened_count="$reopened" \
    fix_regression_count="$fix_regression" net_open_blockers_majors="$net_open" \
    reason="review/fix cycle convergence signals" >/dev/null || return 1
  mkdir -p "$PHASE_DIR"
  jq -cn --arg iteration "$iteration" --argjson growth_pct "$growth_pct" \
    --argjson new_count "$new_c" --argjson recurring_count "$recurring" \
    --argjson resolved_count "$resolved" --argjson reopened_count "$reopened" \
    --argjson fix_regression_count "$fix_regression" --argjson net_open "$net_open" \
    '{iteration:$iteration, growth_pct:$growth_pct, new_count:$new_count,
      recurring_count:$recurring_count, resolved_count:$resolved_count,
      reopened_count:$reopened_count, fix_regression_count:$fix_regression_count,
      net_open:$net_open}' >> "$PHASE_DIR/convergence.jsonl"
}

# Usage: divergence_check PHASE ITERATION CATALOG_PATH
# Prints "yes:<reason>" or "no". Reads $PHASE_DIR/convergence.jsonl (the last
# two recorded rounds, for rules 3/4 below) and CATALOG_PATH (the current
# iteration's own catalog, for rules 1/2 -- ponytail note: rule 2's "two
# consecutive rounds" is approximated as "still open >=1 iteration after it
# first appeared as a fix regression", which needs only this one iteration's
# catalog rather than a second historical snapshot; upgrade to an exact
# per-round diff if that approximation ever proves too coarse).
divergence_check() {
  local phase="$1" iteration="$2" catalog="$3"
  local ledger="$PHASE_DIR/convergence.jsonl"
  local threshold; threshold="$(policy_value artifact_growth_warning_pct)" || return 1
  local iter_num
  iter_num=$((10#$iteration))

  if [ -f "$catalog" ]; then
    local recur_hit fixregress_hit
    recur_hit="$(jq -s '[.[] | select((.recur_count // 0) >= 2)] | length' "$catalog" 2>/dev/null)"
    if [ "${recur_hit:-0}" -gt 0 ] 2>/dev/null; then
      echo "yes:finding_recurred_twice"; return 0
    fi
    fixregress_hit="$(jq -s --argjson iter "$iter_num" '
      [.[] | select(.provenance=="fix_regression" and .severity=="blocker"
        and (.status=="open" or .status=="reopened")
        and (($iter - (.origin_iteration|tonumber)) >= 1))] | length
    ' "$catalog" 2>/dev/null)"
    if [ "${fixregress_hit:-0}" -gt 0 ] 2>/dev/null; then
      echo "yes:fix_regression_persists"; return 0
    fi
  fi

  if [ -f "$ledger" ] && [ "$(wc -l < "$ledger")" -ge 2 ]; then
    local last2 g1 g2 net1 net2 reopened1 reopened2 resolved1 resolved2
    last2="$(tail -n2 "$ledger")"
    g1="$(printf '%s\n' "$last2" | sed -n 1p | jq -r '.growth_pct')"
    g2="$(printf '%s\n' "$last2" | sed -n 2p | jq -r '.growth_pct')"
    net1="$(printf '%s\n' "$last2" | sed -n 1p | jq -r '.net_open')"
    net2="$(printf '%s\n' "$last2" | sed -n 2p | jq -r '.net_open')"
    reopened1="$(printf '%s\n' "$last2" | sed -n 1p | jq -r '.reopened_count')"
    reopened2="$(printf '%s\n' "$last2" | sed -n 2p | jq -r '.reopened_count')"
    resolved1="$(printf '%s\n' "$last2" | sed -n 1p | jq -r '.resolved_count')"
    resolved2="$(printf '%s\n' "$last2" | sed -n 2p | jq -r '.resolved_count')"
    if [ "$g1" -gt "$threshold" ] && [ "$g2" -gt "$threshold" ] && [ "$net2" -ge "$net1" ]; then
      echo "yes:growth_without_reduction"; return 0
    fi
    if [ "$reopened1" -gt "$resolved1" ] && [ "$reopened2" -gt "$resolved2" ]; then
      echo "yes:fixer_reopens_more_than_resolved"; return 0
    fi
  fi
  echo "no"
}

# Usage: divergent_round_cap_hit_before PHASE_NAME
# P08: prints "yes" iff RUN_LOG.md already carries a DIVERGENT_ROUND_CAP_
# REACHED event for this phase_name -- i.e. the cap the caller is ABOUT to
# record would be the SECOND consecutive hit on this gate, and the loop must
# HALT instead of dispatching a third consolidation batch (registry's
# `divergent_round_cap` meaning: "before ... a second such cap hit ... HALTs
# instead of dispatching a third"). Counts by phase_name alone, never by
# which reviewer's findings tipped divergence_check into "yes" -- Phase 7's
# catalog can be fed by code-reviewer-*/seam-verifier (P01) alike, and this
# scan is deliberately blind to finding source so the stop condition counts
# the same way regardless of it. Built on the shared _run_log_events_json
# reader (Task 6/P04) -- never a second hand-rolled RUN_LOG scanner.
divergent_round_cap_hit_before() {
  local phase_name="$1"
  local n
  n="$(_run_log_events_json | jq -s --arg p "$phase_name" \
    '[.[] | select(._type=="DIVERGENT_ROUND_CAP_REACHED" and .phase_name==$p)] | length' 2>/dev/null)"
  if [ "${n:-0}" -ge 1 ]; then echo yes; else echo no; fi
}

# Extract the plan's embedded machine-checkable task block (spec S19.1): a
# single fenced ```json code block immediately following a "## Task
# Contract" heading, one JSON object per non-blank line.
_plan_task_block() {
  # Usage: _plan_task_block PLAN_PATH
  local plan_path="$1"
  "$PYTHON_BIN" - "$plan_path" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
m = re.search(r'^##\s+Task Contract\s*$\n+```json\n(.*?)\n```', text, re.M | re.S)
if not m:
    sys.stderr.write("no '## Task Contract' fenced json block found\n")
    sys.exit(1)
sys.stdout.write(m.group(1))
PY
}

# Validate every executable-task-contract field (spec S19.1): unique stable
# task_id, every required field present (null/empty allowed only where the
# schema says so), actor in the legal four-value enum, prerequisites form a
# DAG over reachable tasks, a non-implementer actor carries a non-empty
# handoff, no credential field carries inline secret material, every
# credential NAME is available in the CURRENT environment (checked by
# presence only -- the value is never read or printed), every verification
# entry is genuinely executable (not ambiguous, not a bare
# post-implementation-only review remedy), and no step/verification command
# implies an external/destructive effect the task's own side_effects field
# left undeclared. Prints one error per line to stderr; returns non-zero if
# any task is invalid.
validate_plan_tasks() {
  # Usage: validate_plan_tasks PLAN_PATH
  local plan_path="$1" block tmp rc
  [ -f "$plan_path" ] || { echo "validate_plan_tasks: missing plan: $plan_path" >&2; return 1; }
  block="$(_plan_task_block "$plan_path")" || return 1
  tmp="$(mktemp)"
  printf '%s\n' "$block" > "$tmp"
  "$PYTHON_BIN" - "$tmp" <<'PY'
import json, os, re, sys

path = sys.argv[1]
REQUIRED_NONEMPTY = ("task_id", "objective", "files", "actor", "steps", "verification")
NULLABLE = ("credential", "rollback", "handoff")
EMPTY_LIST_OK = ("prerequisites", "side_effects", "skills")
ALL_FIELDS = REQUIRED_NONEMPTY + NULLABLE + EMPTY_LIST_OK
ACTORS = {"implementer", "owner", "CI", "deployed_environment"}
SECRET_RE = re.compile(r"[=:]\s*[^\s]{8,}|sk-[A-Za-z0-9]|AKIA[0-9A-Z]{16}")
AMBIGUOUS_RE = re.compile(r"(?i)\b(tbd|todo|similar to|see above|as before|etc\.)\b")
POST_IMPL_RE = re.compile(r"(?i)\bcode review\b|\bpost-?implementation review\b")
# Two-tier destructive-effect detection (code review fix, major 5): a bare
# verb match on "delete"/"deploy" false-positive-HALTed ordinary plans
# ("Delete the temporary scratch file", "Run the deployment script test").
# SPECIFIC patterns are inherently destructive regardless of context; the
# two GENERIC verbs only count when they co-occur (anywhere in the same
# task's haystack) with a word naming real destructive SCOPE.
DESTRUCTIVE_VERBS_SPECIFIC = re.compile(
    r"(?i)\brm -rf\b|\bdrop tables?\b|\bsend emails?\b|\bpush to prod\b|"
    r"\btruncate\b|\bmigrate production\b")
DESTRUCTIVE_VERBS_GENERIC = re.compile(r"(?i)\bdeploy\w*\b|\bdelete\w*\b")
DESTRUCTIVE_SCOPE = re.compile(
    r"(?i)\b(production|prod|database|table|customer|user|account|record|row)s?'?s?\b"
    r"|\buser data\b")

tasks, order, errors = {}, [], []
with open(path) as f:
    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            t = json.loads(line)
        except json.JSONDecodeError as e:
            errors.append(f"line {lineno}: invalid JSON: {e}")
            continue
        tid = t.get("task_id")
        if not tid:
            errors.append(f"line {lineno}: missing task_id")
            continue
        if tid in tasks:
            errors.append(f"task {tid}: duplicate task_id")
            continue
        tasks[tid] = t
        order.append(tid)

# Declaration-order index for the "reachable PRIOR tasks" rule (spec S19.1,
# code review fix medium 7): membership alone is not enough -- a
# prerequisite existing somewhere in the block is not the same as it being
# declared BEFORE the task that depends on it.
tid_pos = {tid: i for i, tid in enumerate(order)}

for tid, t in tasks.items():
    for field in ALL_FIELDS:
        if field not in t:
            errors.append(f"task {tid}: missing {field}")
            continue
        if field in REQUIRED_NONEMPTY and t[field] in (None, "", [], {}):
            errors.append(f"task {tid}: missing {field}")

    actor = t.get("actor")
    if actor is not None and actor not in ACTORS:
        errors.append(f"task {tid}: actor '{actor}' is not in implementer|owner|CI|deployed_environment")
    if actor and actor != "implementer" and not t.get("handoff"):
        errors.append(f"task {tid}: actor={actor} requires non-empty handoff")

    for dep in t.get("prerequisites") or []:
        if dep not in tasks:
            errors.append(f"task {tid}: prerequisite '{dep}' is unreachable")
        elif tid_pos[dep] >= tid_pos[tid]:
            errors.append(f"task {tid}: prerequisite '{dep}' is a forward reference (declared at or after {tid}, not a reachable PRIOR task)")

    cred = t.get("credential")
    if cred:
        if SECRET_RE.search(str(cred)):
            errors.append(f"task {tid}: credential field looks like it carries secret material")
        # Availability is checked ONLY for actor=implementer. An owner/CI/
        # deployed_environment task naming a credential is precisely the
        # handoff case this schema exists to express -- the orchestrator
        # by definition does not (and should not) hold that credential
        # itself, so checking it here would HALT every legitimate handoff
        # task. `in os.environ` (membership), not `.get()`, so this stays
        # presence-only in fact, not just in the comment above it.
        elif actor == "implementer" and cred not in os.environ:
            errors.append(f"task {tid}: credential '{cred}' is not available in the current environment")

    verifs = t.get("verification") or []
    if not isinstance(verifs, list) or not verifs:
        errors.append(f"task {tid}: verification must be a non-empty list")
    else:
        for i, v in enumerate(verifs):
            if not isinstance(v, dict) or not v.get("command"):
                errors.append(f"task {tid}: verification[{i}] missing command")
                continue
            if not v.get("environment"):
                errors.append(f"task {tid}: verification[{i}] missing environment")
            if not v.get("expected_result"):
                errors.append(f"task {tid}: verification[{i}] missing expected_result")
            cmd = str(v["command"])
            if POST_IMPL_RE.search(cmd):
                errors.append(f"task {tid}: verification[{i}] relies on a post-implementation-only review remedy, not an executable check")
            elif AMBIGUOUS_RE.search(cmd):
                errors.append(f"task {tid}: verification[{i}] command is ambiguous: {cmd!r}")

    haystack = " ".join(t.get("steps") or []) + " " + " ".join(
        v.get("command", "") for v in verifs if isinstance(v, dict))
    _destructive = bool(DESTRUCTIVE_VERBS_SPECIFIC.search(haystack)) or (
        bool(DESTRUCTIVE_VERBS_GENERIC.search(haystack)) and bool(DESTRUCTIVE_SCOPE.search(haystack)))
    if _destructive and not (t.get("side_effects") or []):
        errors.append(f"task {tid}: undeclared side effect -- steps/verification imply an external/destructive effect but side_effects is empty")

# DAG / cycle check over the declared prerequisite graph.
WHITE, GRAY, BLACK = 0, 1, 2
color = {tid: WHITE for tid in tasks}

def visit(tid, stack):
    if color[tid] == BLACK:
        return
    if color[tid] == GRAY:
        errors.append("cycle detected: " + " -> ".join(stack + [tid]))
        return
    color[tid] = GRAY
    for dep in tasks[tid].get("prerequisites") or []:
        if dep in tasks:
            visit(dep, stack + [tid])
    color[tid] = BLACK

for tid in tasks:
    if color[tid] == WHITE:
        visit(tid, [])

# P16: refuse a plan whose task graph would let two independently-schedulable
# tasks both declare an environment=exclusive verification command -- an
# exclusive command must run alone (spec §19.2 above), so two of them are
# only safe when one task is a (transitive) prerequisite of the other,
# guaranteeing they never run concurrently. `seen` bounds the walk even over
# an already-reported cycle -- this check never depends on the DAG check
# above having succeeded.
def _ancestors(tid, seen):
    for dep in tasks.get(tid, {}).get("prerequisites") or []:
        if dep in tasks and dep not in seen:
            seen.add(dep)
            _ancestors(dep, seen)
    return seen

exclusive_tasks = [
    tid for tid, t in tasks.items()
    if any(isinstance(v, dict) and v.get("environment") == "exclusive"
           for v in (t.get("verification") or []))
]
_ancestor_cache = {}
for i, a in enumerate(exclusive_tasks):
    for b in exclusive_tasks[i + 1:]:
        anc_a = _ancestor_cache.setdefault(a, _ancestors(a, set()))
        anc_b = _ancestor_cache.setdefault(b, _ancestors(b, set()))
        if b not in anc_a and a not in anc_b:
            errors.append(
                f"tasks {a} and {b}: both declare an environment=exclusive verification "
                f"command with no prerequisite ordering between them -- co-scheduling two "
                f"exclusive commands is refused (P16)")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY
  rc=$?
  rm -f "$tmp"
  return $rc
}

# The only four legal verification-record result values (spec S19.2).
# SKIPPED and empty are rejected -- never treated as a synonym for PASS.
_verification_result_legal() {
  case "$1" in PASS|FAIL|EXCLUDED|NOT_RUN) return 0 ;; *) return 1 ;; esac
}

# The only four legal exclusion_class enum values (spec S19.2, P15) -- an
# empty string (result != EXCLUDED, where the field is legitimately null) is
# ALSO accepted here; only a non-empty, non-enum value is illegal input.
_exclusion_class_legal() {
  case "$1" in ""|pre_existing|environment_bound|actor_bound|outside_capability) return 0 ;; *) return 1 ;; esac
}

# Append one verification record (spec S19.2) to a verification-records.jsonl
# file. The sole writer, so every record carries the same ten fields in the
# same order regardless of caller, gated by the same result-legality check
# every reader relies on.
append_verification_record() {
  # Usage: append_verification_record RECORDS_JSONL VERIFICATION_ID COMMAND \
  #   ENVIRONMENT RESULT EXIT_CODE EVIDENCE_PATH BASELINE_COMPARISON REASON \
  #   FOLLOWUP_ID EXCLUSION_CLASS
  local path="$1" vid="$2" command="$3" environment="$4" result="$5" \
    exit_code="${6:-}" evidence_path="${7:-}" baseline_comparison="${8:-}" \
    reason="${9:-}" followup_id="${10:-}" exclusion_class="${11:-}"
  _verification_result_legal "$result" \
    || { echo "append_verification_record: illegal result '$result' (only PASS|FAIL|EXCLUDED|NOT_RUN are legal; SKIPPED and empty are rejected)" >&2; return 1; }
  _exclusion_class_legal "$exclusion_class" \
    || { echo "append_verification_record: illegal exclusion_class '$exclusion_class' (only pre_existing|environment_bound|actor_bound|outside_capability, or empty, are legal)" >&2; return 1; }
  mkdir -p "$(dirname "$path")"
  jq -nc --arg vid "$vid" --arg command "$command" --arg environment "$environment" \
    --arg result "$result" --arg exit_code "$exit_code" --arg evidence_path "$evidence_path" \
    --arg baseline_comparison "$baseline_comparison" --arg reason "$reason" --arg followup_id "$followup_id" \
    --arg exclusion_class "$exclusion_class" \
    '{verification_id:$vid, command:$command, environment:$environment, result:$result,
      exit_code:(if $exit_code=="" then null else ($exit_code|tonumber? // $exit_code) end),
      evidence_path:(if $evidence_path=="" then null else $evidence_path end),
      baseline_comparison:(if $baseline_comparison=="" then null else $baseline_comparison end),
      reason:(if $reason=="" then null else $reason end),
      followup_id:(if $followup_id=="" then null else $followup_id end),
      exclusion_class:(if $exclusion_class=="" then null else $exclusion_class end)}' >> "$path"
}

# Validate a verification-records.jsonl file against spec S19.2's nine
# fields and per-result rules. Prints one error per line to stderr; returns
# non-zero if any record is invalid.
validate_verification_records() {
  # Usage: validate_verification_records RECORDS_JSONL
  local path="$1"
  [ -f "$path" ] || { echo "validate_verification_records: missing file: $path" >&2; return 1; }
  "$PYTHON_BIN" - "$path" <<'PY'
import json, re, sys

path = sys.argv[1]
FIELDS = ("verification_id", "command", "environment", "result", "exit_code",
          "evidence_path", "baseline_comparison", "reason", "followup_id",
          "exclusion_class")
RESULTS = {"PASS", "FAIL", "EXCLUDED", "NOT_RUN"}
# P15: exclusion_class is a typed enum, not a substring sniffed out of free
# text -- the retired EXCLUSION_MARKERS keyword list ("pre-existing",
# "environment-bound", "actor-bound", "outside") no longer exists anywhere in
# this document; a reason like "outside the scope of this refactor" no
# longer passes just for containing one of those words.
EXCLUSION_CLASSES = {"pre_existing", "environment_bound", "actor_bound", "outside_capability"}
# ponytail: keyword/tool-name matching on command text, not real semantic
# intent detection (code review fix, low 10) -- a benchmark tool invoked
# under a name not listed here (or wrapped in an unfamiliar script) still
# slips through as an ordinary PASS/FAIL. Upgrade path if this bites: a
# declared `x_measurement_kind: performance` field on the plan's own
# verification entry, set by the plan-writer/reviewer, instead of guessing
# from the command string.
PERF_RE = re.compile(
    r"(?i)\b(?:perf|benchmark|latency|throughput|hyperfine|wrk|jmeter|k6|"
    r"locust|siege|autocannon|req/s|ops/sec|p9[0-9])\b")

# Mode B (post-debug re-verification) APPENDS a fresh outcome under the
# SAME verification_id rather than rewriting the file (code review fix,
# low 11) -- an old FAIL sitting alongside a new PASS for the identical
# check would otherwise make "every non-excluded record is PASS"
# permanently unsatisfiable for any run that ever needed debugging.
# LAST occurrence of a given verification_id wins; everything before it is
# superseded history, validated as part of the file's structure (a parse
# error is always reported) but never re-checked against the per-result
# rules below -- only the CURRENT outcome of each check is evaluated.
errors = []
by_id = {}
order_id = []
with open(path) as f:
    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError as e:
            errors.append(f"line {lineno}: invalid JSON: {e}")
            continue
        vid = r.get("verification_id")
        if vid not in by_id:
            order_id.append(vid)
        by_id[vid] = (lineno, r)

for vid in order_id:
    lineno, r = by_id[vid]
    for field in FIELDS:
        if field not in r:
            errors.append(f"line {lineno}: missing field {field}")
    result = r.get("result")
    # An empty result is never PASS -- SKIPPED and empty are rejected;
    # only PASS|FAIL|EXCLUDED|NOT_RUN are legal.
    if result not in RESULTS:
        errors.append(f"line {lineno} ({r.get('verification_id')}): result {result!r} is not one of PASS|FAIL|EXCLUDED|NOT_RUN")
        continue
    reason = (r.get("reason") or "").strip()
    if result == "EXCLUDED":
        # P15: exclusion_class is the load-bearing typed field -- a bare
        # reason string (however plausible-sounding) is a claim, never
        # evidence. Missing/illegal values fail here regardless of what
        # `reason` says.
        exclusion_class = r.get("exclusion_class")
        if exclusion_class not in EXCLUSION_CLASSES:
            errors.append(f"line {lineno} ({r['verification_id']}): EXCLUDED requires exclusion_class to be one of pre_existing|environment_bound|actor_bound|outside_capability, got {exclusion_class!r}")
        if not r.get("evidence_path"):
            errors.append(f"line {lineno} ({r['verification_id']}): EXCLUDED requires a non-null evidence_path -- exclusion_class alone is a claim, not evidence")
        # A non-null path is still only a claim: nothing in it distinguishes
        # PRE-EXISTING from NEW. "cannot hide a new regression" is met only by
        # a baseline showing the check already failed this way BEFORE the
        # change. baseline_comparison is already in the schema; require it.
        # Actor- and environment-bound exclusions are exempt: no baseline can
        # exist for a check this actor/environment cannot run at all.
        elif exclusion_class not in ("actor_bound", "environment_bound"):
            if not r.get("baseline_comparison"):
                errors.append(f"line {lineno} ({r['verification_id']}): EXCLUDED as pre_existing/outside_capability requires a non-null baseline_comparison proving the check failed the same way before this change")
    if result == "NOT_RUN":
        if not reason:
            errors.append(f"line {lineno} ({r['verification_id']}): NOT_RUN requires a named actor/prerequisite in reason")
        # P15: a NOT_RUN that names its blocker only in prose can evaporate
        # with no tracked handoff work -- the ledger (followups.jsonl) is
        # exactly where that work is supposed to live, so require the link.
        if not r.get("followup_id"):
            errors.append(f"line {lineno} ({r['verification_id']}): NOT_RUN requires a non-null followup_id linking it to tracked handoff work")
    if result in ("PASS", "FAIL") and PERF_RE.search(str(r.get("command", ""))):
        env = r.get("environment") or ""
        baseline = r.get("baseline_comparison")
        if env != "controlled" or not baseline:
            errors.append(f"line {lineno} ({r['verification_id']}): a performance verdict without a declared controlled environment and comparable baseline must be recorded as NOT_RUN (advisory/inconclusive), not {result}")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY
}

# The four legal follow-up status values (spec S20.9). Never SKIPPED,
# never empty -- a follow-up with no status is not yet a follow-up.
_followup_status_legal() {
  case "$1" in open|deferred|accepted_risk|resolved) return 0 ;; *) return 1 ;; esac
}

# Append one canonical follow-up record (spec S20.9) to followups.jsonl.
# The sole writer: only the orchestrator calls this, only after a role's own
# dispatch classification is durable, and only from candidates that role
# RETURNED through its own STATUS -- never a path a role's own appendix
# writes to directly. Refuses a duplicate id (append-only, like RUN_LOG.md)
# and an illegal status before anything is written.
append_followup() {
  # Usage: append_followup ID ORIGIN_PHASE ORIGIN_FINDING DESCRIPTION ACTOR \
  #   PREREQUISITE RISK STATUS EVIDENCE
  local id="$1" origin_phase="$2" origin_finding="$3" description="$4" \
    actor="$5" prerequisite="$6" risk="$7" status="$8" evidence="${9:-}"
  local path="${FEATURE_FOLDER:?}/followups.jsonl"
  mkdir -p "${FEATURE_FOLDER:?}"
  [ -n "$id" ] || { echo "append_followup: missing id" >&2; return 1; }
  _followup_status_legal "$status" \
    || { echo "append_followup: illegal status '$status' (only open|deferred|accepted_risk|resolved are legal)" >&2; return 1; }
  if [ -f "$path" ] && jq -e --arg id "$id" 'select(.id == $id)' "$path" >/dev/null 2>&1; then
    echo "append_followup: duplicate id '$id' (the ledger is append-only; ids may not be reused)" >&2
    return 1
  fi
  jq -nc --arg id "$id" --arg origin_phase "$origin_phase" \
    --arg origin_finding "$origin_finding" --arg description "$description" \
    --arg actor "$actor" --arg prerequisite "$prerequisite" --arg risk "$risk" \
    --arg status "$status" --arg evidence "$evidence" \
    '{id:$id, origin_phase:$origin_phase,
      origin_finding:(if $origin_finding=="" or $origin_finding=="null" then null else $origin_finding end),
      description:$description, actor:$actor, prerequisite:$prerequisite, risk:$risk,
      status:$status,
      evidence:(if $evidence=="" or $evidence=="null" then null else $evidence end)}' >> "$path"
}

# Validate a followups.jsonl file against spec S20.9's eight fields and
# per-record rules (P17) -- mirrors validate_verification_records for this
# second append-only ledger. Re-checks the SAME field list/status enum/
# duplicate-id rules append_followup enforces on write, PLUS the five
# required-non-empty-text fields append_followup itself never re-validates
# once written (a crash mid-append, hand-edit, or resume can still corrupt
# the file after a clean write). Prints one error per line to stderr;
# returns non-zero if any record is invalid.
validate_followups() {
  # Usage: validate_followups FOLLOWUPS_JSONL
  local path="$1"
  [ -f "$path" ] || { echo "validate_followups: missing file: $path" >&2; return 1; }
  "$PYTHON_BIN" - "$path" <<'PY'
import json, sys

path = sys.argv[1]
FIELDS = ("id", "origin_phase", "origin_finding", "description", "actor",
          "prerequisite", "risk", "status", "evidence")
STATUSES = {"open", "deferred", "accepted_risk", "resolved"}
NULLABLE = {"origin_finding", "evidence"}

errors = []
seen_ids = {}
with open(path) as f:
    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError as e:
            errors.append(f"line {lineno}: invalid JSON: {e}")
            continue
        for field in FIELDS:
            if field not in r:
                errors.append(f"line {lineno}: missing field {field}")
        rid = r.get("id")
        if rid:
            if rid in seen_ids:
                errors.append(f"line {lineno}: duplicate id {rid!r} (first seen at line {seen_ids[rid]}) -- the ledger is append-only, ids may not be reused")
            else:
                seen_ids[rid] = lineno
        status = r.get("status")
        if status not in STATUSES:
            errors.append(f"line {lineno} (id={rid}): status {status!r} is not one of open|deferred|accepted_risk|resolved")
        for field in FIELDS:
            if field in NULLABLE or field == "status":
                continue
            val = r.get(field)
            if not (isinstance(val, str) and val.strip()):
                errors.append(f"line {lineno} (id={rid}): {field} must be non-empty text")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
PY
}

# True once Phase 6 has captured its implementation baseline -- the plan's
# pre-implementation review window is closed for the remainder of THIS run
# from that point on (spec S20.5/S20.6). Reads the SAME durable
# IMPLEMENTATION_BASELINE event Step 6.0's capture_implementation_baseline
# writes, so there is exactly one source of truth for "has Phase 6 started."
plan_review_window_closed() {
  # Usage: plan_review_window_closed
  [ -f "$FEATURE_FOLDER/RUN_LOG.md" ] || return 1
  "$GREP_BIN" -q '^--- .*  event=IMPLEMENTATION_BASELINE$' "$FEATURE_FOLDER/RUN_LOG.md"
}

# Phase 5's actual review-window pre-check (spec S19.1/S20.5-S20.6, code
# review fix major 6): a REAL callable gate, not prose alone -- this is what
# makes "STALE without a vendor call" a provable fact rather than a claim.
# Prints exactly "stale" or "open" and NEVER calls dispatch_attempt,
# dispatch_parallel, or invoke_vendor on either path -- callers branch on the
# printed word; the STALE path costs zero vendor tokens by construction,
# not merely by convention.
plan_review_stale_gate() {
  # Usage: plan_review_stale_gate
  if plan_review_window_closed; then
    record_event PLAN_REVIEW_STALE phase=5 phase_name=plan-review \
      plan_revision="$(sha256sum "$PLAN_PATH" | awk '{print $1}')" \
      reason="pre-implementation review window closed at Phase 6 start"
    printf 'stale\n'
  else
    printf 'open\n'
  fi
}

# Zero-token pre-implementation gate (spec S19.1/S20.5-S20.6): implementation
# may only start from a plan revision whose latest plan-review verdict is
# accepted (the gate's own summarizer reports DONE) and whose open blocking
# finding count, across every plan-review iteration's own findings catalog,
# is zero.
plan_ready_for_implementation() {
  # Usage: plan_ready_for_implementation
  local status="$FEATURE_FOLDER/5-plan-review/summarizer-status.md"
  [ -f "$status" ] \
    || { echo "plan not ready: no plan-review summarizer status (5-plan-review/summarizer-status.md)" >&2; return 1; }
  local verdict
  verdict="$(status_field "$status" verdict)"
  [ "$verdict" = DONE ] \
    || { echo "plan not ready: plan-review summarizer verdict='$verdict', not DONE" >&2; return 1; }
  local open_blockers=0 f n rc
  for f in "$FEATURE_FOLDER"/5-plan-review/*/findings-catalog.jsonl; do
    [ -f "$f" ] || continue
    # "open" ALONE undercounts: ingest_findings marks a blocker "reopened"
    # exactly when a fixer's 'fixed' disposition was re-reported by a later
    # reviewer round -- the single most dangerous class this gate exists to
    # catch. Match select_finding_batch's own open-set definition (open OR
    # reopened), not a narrower one invented here.
    #
    # Fail CLOSED, not open: a jq parse failure or a non-integer result must
    # refuse readiness, never silently count as zero blockers. The old
    # `2>/dev/null` + `${n:-0}` combination let a malformed/corrupt catalog
    # sail through as "0 open blockers."
    n="$(jq -s '[.[] | select(.severity=="blocker" and (.status=="open" or .status=="reopened"))] | length' "$f")"
    rc=$?
    case "$rc:$n" in
      0:*[!0-9]*|0:) 
        echo "plan not ready: findings catalog $f produced a non-numeric count ('$n')" >&2
        return 1 ;;
      0:*) : ;;
      *)
        echo "plan not ready: could not evaluate findings catalog $f (jq exit $rc)" >&2
        return 1 ;;
    esac
    open_blockers=$(( open_blockers + n ))
  done
  if [ "$open_blockers" -ne 0 ]; then
    echo "plan not ready: $open_blockers open or reopened blocking finding(s) remain in plan review" >&2
    return 1
  fi
  return 0
}

capture_implementation_baseline() {
  IMPLEMENTATION_BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo non-git)"

  # Same allow-list semantics as dirty_tree_check — one helper, so the two
  # gates cannot diverge. The previous code matched absolute paths against
  # relative porcelain output with an exact-line filter, so nothing was ever
  # excluded and Phase 6 HALTed unconditionally.
  # dirty_tree_check reports offenders on STDERR and signals via its exit code,
  # so branch on the code and let its diagnostic reach the user directly. Do not
  # capture its stdout -- it prints nothing there.
  if ! dirty_tree_check; then
    {
      printf -- '--- %s  event=IMPLEMENTATION_BASELINE_BLOCKED\n' "$(iso_now)"
      printf 'candidate_sha:  %s\n' "$IMPLEMENTATION_BASE_SHA"
      printf 'reason:         dirty-tree\n'
      printf '\n'
    } >> "$FEATURE_FOLDER/RUN_LOG.md"
    echo "halt: uncommitted changes outside the implementation slice; commit or stash first" >&2
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

# ---- Seam classification (P01) ----------------------------------------------
# Usage: seam_verifier_dispatch_files <phase> <iteration> <file> [<file> ...]
# Prints the subset of the given files that match a seam_globs pattern, one
# per line -- this iteration's $SEAM_FILES input for the seam-verifier
# dispatch. An empty result means no seam-classified file is in scope: this
# function has ALREADY recorded the required RUN_LOG evidence for that skip
# (event=SEAM_VERIFIER_SKIPPED) before returning, so no call site can forget
# to log why zero seams were dispatched this iteration.
seam_verifier_dispatch_files() {
  local phase="$1" iteration="$2"; shift 2
  local globs pattern file
  globs="$(policy_value seam_globs)" || return 1
  local -a pats=()
  IFS=';' read -r -a pats <<<"$globs"
  local -a hits=()
  for file in "$@"; do
    [ -n "$file" ] || continue
    for pattern in "${pats[@]}"; do
      [ -n "$pattern" ] || continue
      # shellcheck disable=SC2254  # intentional glob match against the
      # seam_globs policy value -- this is a classification, not a literal
      # string compare.
      case "$file" in
        $pattern) hits+=("$file"); break ;;
      esac
    done
  done
  if [ "${#hits[@]}" -eq 0 ]; then
    record_event SEAM_VERIFIER_SKIPPED phase="$phase" iteration="$iteration" \
      phase_name=code-review role=seam-verifier vendor=claude \
      reason="no seam-classified file in the diff"
    return 0
  fi
  printf '%s\n' "${hits[@]}"
}
