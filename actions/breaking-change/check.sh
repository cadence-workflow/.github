#!/usr/bin/env bash
#
# Fail a PR that is "breaking" but whose description is missing the
# breaking-change checklist. Breaking = a Conventional Commits '!' in the title,
# or a change to any caller-supplied watched path.
#
# Driven by action.yml; inputs arrive as environment variables:
#   PR_NUMBER PR_TITLE BASE_SHA HEAD_SHA WATCH_PATHS CHECKLIST TEMPLATE_PATH
#   GH_TOKEN GH_REPO      (used by `gh pr view`)
#
# The pure helpers below are sourced directly by check_test.bats; main() runs
# only when the script is executed.

set -euo pipefail

# External inputs (from action.yml env). Defaulted so `set -u` is safe and so
# shellcheck sees them as assigned when the script is checked in isolation.
PR_NUMBER="${PR_NUMBER:-}"
PR_TITLE="${PR_TITLE:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"
WATCH_PATHS="${WATCH_PATHS:-}"
CHECKLIST="${CHECKLIST:-}"
TEMPLATE_PATH="${TEMPLATE_PATH:-}"

# Trim leading/trailing whitespace from a single argument.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Exit 0 if the title carries the Conventional Commits breaking marker
# (type(scope)!: ...); non-zero otherwise.
title_is_breaking() {
  local re='^[a-zA-Z]+(\([^)]*\))?!:'
  [[ "$1" =~ $re ]]
}

# Read watched globs (one per line) on stdin, print git ":(glob)<glob>"
# pathspecs, skipping blanks.
to_pathspecs() {
  local glob
  while IFS= read -r glob; do
    glob="$(trim "$glob")"
    [[ -z "$glob" ]] && continue
    printf ':(glob)%s\n' "$glob"
  done
}

# Print, one per line, the checklist headings ($2, comma-separated) that do not
# appear in the PR body ($1).
missing_sections() {
  local body="$1" checklist="$2" raw item
  local old_ifs="$IFS"
  IFS=','
  # Intentional word-split on the comma-separated checklist.
  # shellcheck disable=SC2086
  for raw in $checklist; do
    item="$(trim "$raw")"
    [[ -z "$item" ]] && continue
    [[ "$body" != *"$item"* ]] && printf '%s\n' "$item"
  done
  IFS="$old_ifs"
}

# Canonical fallback template, used only when TEMPLATE_PATH is unset/missing.
# Kept verbatim in sync with each repo's breaking_change_pr_template.md.
default_template() {
  cat <<'TEMPLATE'
**Detailed Description**
[In-depth description of the changes made to the schema or interfaces, specifying new fields, removed fields, or modified data structures]

**Impact Analysis**
- **Backward Compatibility**: [Analysis of backward compatibility]
- **Forward Compatibility**: [Analysis of forward compatibility]

**Testing Plan**
- **Unit Tests**: [Do we have unit test covering the change?]
- **Persistence Tests**: [If the change is related to a data type which is persisted, do we have persistence tests covering the change?]
- **Integration Tests**: [Do we have integration test covering the change?]
- **Compatibility Tests**: [Have we done tests to test the backward and forward compatibility?]

**Rollout Plan**
- What is the rollout plan?
- Does the order of deployment matter?
- Is it safe to rollback? Does the order of rollback matter?
- Is there a kill switch to mitigate the impact immediately?
TEMPLATE
}

print_template() {
  if [[ -n "${TEMPLATE_PATH:-}" && -f "${TEMPLATE_PATH}" ]]; then
    cat "${TEMPLATE_PATH}"
    return
  fi
  # A set-but-missing template usually means the caller passed template-path but
  # forgot to check out the repo. Warn rather than silently print the built-in
  # copy, which can drift from the repo's canonical template.
  if [[ -n "${TEMPLATE_PATH:-}" ]]; then
    echo "::warning::template-path '${TEMPLATE_PATH}' not found (did the caller check out the repo?); using built-in template" >&2
  fi
  default_template
}

# Print the breaking reason, or nothing if the PR is not breaking.
detect_reason() {
  if title_is_breaking "${PR_TITLE:-}"; then
    printf "title carries the Conventional Commits '!' breaking marker"
    return
  fi

  # Only diff when watched paths are supplied (ignoring pure-whitespace input).
  if [[ -z "${WATCH_PATHS//[$'\n\r\t ']/}" ]]; then
    return
  fi

  local pathspecs=()
  mapfile -t pathspecs < <(printf '%s\n' "$WATCH_PATHS" | to_pathspecs)
  [[ ${#pathspecs[@]} -eq 0 ]] && return

  # Three-dot (merge-base) form so only PR-introduced changes count, not
  # commits that landed on the base branch after the fork point. Fail loudly on
  # a git error rather than masking it as "no change".
  local changed
  if ! changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}" -- "${pathspecs[@]}")"; then
    echo "::error::git diff failed for watched-path detection (base=${BASE_SHA} head=${HEAD_SHA})" >&2
    exit 1
  fi
  if [[ -n "$changed" ]]; then
    printf 'changed watched path(s): %s' "$(echo "$changed" | tr '\n' ' ')"
  fi
  # Explicit success: a trailing failed test would otherwise make the function
  # return non-zero, and `reason="$(detect_reason)"` under `set -e` would abort
  # main() on every non-breaking PR.
  return 0
}

main() {
  local reason
  reason="$(detect_reason)"

  if [[ -z "$reason" ]]; then
    echo "No breaking-change signal (no '!' in title, no watched path changed)."
    return 0
  fi
  echo "Breaking change detected: ${reason}"

  local body missing
  body="$(gh pr view "$PR_NUMBER" --json body --jq '.body')"
  missing="$(missing_sections "$body" "$CHECKLIST")"

  if [[ -n "$missing" ]]; then
    echo "::error::Breaking change detected (${reason}) but the PR description is missing: $(echo "$missing" | tr '\n' ' ')"
    echo "Please add the following sections to your PR description:"
    echo "---"
    print_template
    echo "---"
    exit 1
  fi
  echo "All required breaking-change sections are present."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
