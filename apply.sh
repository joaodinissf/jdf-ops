#!/usr/bin/env bash
# Reconcile personal repositories against repos.json.
#
#   ./apply.sh                     report drift, change nothing
#   ./apply.sh --apply             make reality match the file
#   ./apply.sh [--apply] <repo>…   restrict to the named repos
#
# Idempotent: every operation is a PATCH/PUT of desired state, so re-running
# when nothing has drifted produces no changes. That makes the no-argument form
# a drift check you can run from CI.
#
# Scope is discovered rather than listed -- every public, non-fork,
# non-archived repo owned by the authenticated user. repos.json carries the
# policy and its exceptions, not the inventory, so a repo created tomorrow is
# governed without editing anything.
set -euo pipefail

CFG="$(dirname "$0")/repos.json"
APPLY=false
[[ "${1:-}" == "--apply" ]] && { APPLY=true; shift; }

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
jq empty "$CFG" || { echo "repos.json is not valid JSON" >&2; exit 1; }

ME="$(gh api user --jq .login)"

drift=0
note() { printf '  %-22s %s\n' "$1" "$2"; }
changed() { drift=$((drift+1)); printf '  %-22s %s\n' "DRIFT $1" "$2"; }

# One repo failing must not abort the run: an empty repo has no branch to
# protect, and a security feature may be unavailable on this account tier.
# Every other repo still reconciles, and the failure is printed rather than
# swallowed.
try() {
  local what=$1; shift
  gh api "$@" >/dev/null 2>&1 || note "WARN" "$what failed"
}

# patch_repo <repo> <patch-body>  -- PATCH only if the current state differs.
patch_repo() {
  local repo=$1 body=$2 cur diff
  cur=$(gh api "repos/$ME/$repo" 2>/dev/null)
  # -r matters: without it jq emits a quoted string, so the emptiness test below
  # never fires. And `//` must not be used to default the current value: jq
  # treats `false` as null-ish, so every false-valued setting would compare
  # unequal to itself.
  diff=$(jq -rn --argjson cur "$cur" --argjson want "$body" \
    '[$want | to_entries[] | select($cur[.key] != .value) | .key] | join(", ")')
  [[ -z "$diff" ]] && return 0
  changed "$repo" "settings: $diff"
  $APPLY && try "$repo settings" -X PATCH "repos/$ME/$repo" --input - <<<"$body"
  return 0
}

# Security flags live under security_and_analysis and read back as {status:...}.
patch_security() {
  local repo=$1 want=$2 cur diff body
  cur=$(gh api "repos/$ME/$repo" --jq '.security_and_analysis // {}' 2>/dev/null)
  diff=$(jq -rn --argjson cur "$cur" --argjson want "$want" \
    '[$want | to_entries[] | select((($cur[.key] // {}).status // "disabled") != .value) | .key] | join(", ")')
  [[ -z "$diff" ]] && return 0
  changed "$repo" "security: $diff"
  body=$(jq -n --argjson want "$want" '{security_and_analysis: ($want | with_entries(.value = {status: .value}))}')
  $APPLY && try "$repo security" -X PATCH "repos/$ME/$repo" --input - <<<"$body"
  return 0
}

patch_topics() {
  local repo=$1 want=$2 cur
  cur=$(gh api "repos/$ME/$repo" --jq '.topics | sort' 2>/dev/null)
  [[ "$(jq -cn --argjson a "$cur" '$a')" == "$(jq -cn --argjson b "$want" '$b | sort')" ]] && return 0
  changed "$repo" "topics"
  $APPLY && jq -n --argjson n "$want" '{names: $n}' | try "$repo topics" -X PUT "repos/$ME/$repo/topics" --input -
  return 0
}

# Rulesets are matched by name so this updates in place rather than stacking
# duplicates on every run.
ensure_ruleset() {
  local repo=$1 name=$2 body=$3 id
  id=$(gh api "repos/$ME/$repo/rulesets" --jq "[.[] | select(.name==\"$name\")][0].id // empty" 2>/dev/null || true)
  if [[ -z "$id" ]]; then
    changed "$repo" "ruleset '$name' missing"
    $APPLY && try "$repo ruleset '$name'" -X POST "repos/$ME/$repo/rulesets" --input - <<<"$body"
  else
    local cur ok
    cur=$(gh api "repos/$ME/$repo/rulesets/$id" --jq '{enforcement, conditions, rules}' 2>/dev/null)
    # Subset comparison, not equality: GitHub echoes back defaults we never
    # declare (dismissal_restriction, required_reviewers, do_not_enforce_on_create),
    # so exact equality would report drift on every run forever.
    ok=$(jq -rn --argjson cur "$cur" --argjson want "$body" '
      def params($t): [$cur.rules[] | select(.type==$t) | .parameters // {}][0] // null;
      ($cur.enforcement == $want.enforcement)
      and ($cur.conditions == $want.conditions)
      and (([$cur.rules[].type] | sort) == ([$want.rules[].type] | sort))
      and (all($want.rules[];
             (.parameters // {}) as $p | params(.type) as $g |
             ($p | length) == 0 or ($g != null and all($p | to_entries[]; $g[.key] == .value))))')
    if [[ "$ok" != "true" ]]; then
      changed "$repo" "ruleset '$name' differs"
      $APPLY && try "$repo ruleset '$name'" -X PUT "repos/$ME/$repo/rulesets/$id" --input - <<<"$body"
    fi
  fi
  return 0
}

# Rulesets this file does not define still govern the repo, and they stack:
# GitHub enforces the union. Reported rather than counted as drift, because an
# unmanaged ruleset is information, not a policy violation -- but silence here
# would let "in sync" mean far less than it sounds.
report_unmanaged() {
  local repo=$1 extra
  extra=$(gh api "repos/$ME/$repo/rulesets" \
    --jq '[.[] | select(.name != "default" and .name != "tags") | "\(.name) [\(.target)]"] | join(", ")' \
    2>/dev/null || true)
  [[ -n "$extra" ]] && note "$repo" "unmanaged: $extra"
  return 0
}

branch_ruleset_body() {
  jq -n --argjson reviews "$1" --argjson threads "$2" --argjson checks "$3" --argjson refs "$4" '
    {name: "default", target: "branch", enforcement: "active", bypass_actors: [],
     conditions: {ref_name: {include: $refs, exclude: []}},
     rules: ([{type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"},
       {type: "pull_request", parameters: {
          required_approving_review_count: $reviews,
          dismiss_stale_reviews_on_push: false, require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: $threads,
          allowed_merge_methods: ["rebase"]}}]
      + (if ($checks | length) > 0 then [{type: "required_status_checks", parameters: {
            strict_required_status_checks_policy: false,
            required_status_checks: ($checks | map({context: .}))}}] else [] end))}'
}

tag_ruleset_body() {
  jq -n --argjson refs "$1" '
    {name: "tags", target: "tag", enforcement: "active", bypass_actors: [],
     conditions: {ref_name: {include: $refs, exclude: []}},
     rules: [{type: "deletion"}, {type: "update"}, {type: "non_fast_forward"}]}'
}

$APPLY || echo "DRY RUN — reporting drift only. Re-run with --apply to reconcile."
echo

d_settings=$(jq -c '.defaults.settings' "$CFG")
d_security=$(jq -c '.defaults.security' "$CFG")
d_reviews=$(jq '.defaults.branch_ruleset.required_approving_review_count' "$CFG")
d_threads=$(jq '.defaults.branch_ruleset.required_review_thread_resolution' "$CFG")
d_refs=$(jq -c '.defaults.branch_ruleset.ref_include' "$CFG")
d_tag=$(jq '.defaults.tag_ruleset' "$CFG")
d_tag_refs=$(jq -c '.defaults.tag_ref_include' "$CFG")

d_private=$(jq -c '.defaults.private_overrides' "$CFG")

# Each entry is name:visibility. Word-split rather than mapfile: macOS ships
# bash 3.2, which has neither mapfile nor readarray. Repository names cannot
# contain whitespace.
REPOS=$(gh repo list "$ME" --source --no-archived --limit 300 --json name,visibility \
  --jq '.[] | "\(.name):\(.visibility | ascii_downcase)"' | sort | tr '\n' ' ')
governed=$(wc -w <<<"$REPOS" | tr -d ' ')

# A positional filter narrows the run to the named repos. Names are intersected
# with the discovered set rather than trusted: an unknown name is refused, so a
# typo cannot quietly reconcile nothing while reporting success, and the filter
# can never reach a repo the policy does not govern.
if [[ $# -gt 0 ]]; then
  selected=
  for want in "$@"; do
    hit=
    for entry in $REPOS; do
      [[ "${entry%:*}" == "$want" ]] && hit=$entry
    done
    [[ -z "$hit" ]] && { echo "not a governed repo: $want" >&2; exit 1; }
    selected="$selected $hit"
  done
  REPOS=$selected
  echo "restricted to:$(tr ' ' '\n' <<<"$selected" | sed 's/:.*//' | tr '\n' ' ')"
  echo
fi

for entry in $REPOS; do
  repo=${entry%:*}
  vis=${entry##*:}
  ex=$(jq -c --arg n "$repo" '[.exceptions[]? | select(.name==$n)][0] // {}' "$CFG")

  # Private repos get merge settings and nothing else. Rulesets and secret
  # scanning both need paid features there, and GitHub answers with a 200 that
  # changes nothing rather than an error -- so attempting them would report
  # drift forever.
  if [[ "$vis" == "private" ]]; then
    echo "$repo (private)"
    want=$(jq -cn --argjson d "$d_settings" --argjson p "$d_private" --argjson e "$ex" \
      '$d + $p + ($e.settings // {})')
    patch_repo "$repo" "$want"
    continue
  fi

  echo "$repo"

  want=$(jq -cn --argjson d "$d_settings" --argjson e "$ex" '$d + ($e.settings // {})')
  desc=$(jq -r '.description // empty' <<<"$ex")
  [[ -n "$desc" ]] && want=$(jq -c --arg d "$desc" '. + {description: $d}' <<<"$want")
  patch_repo "$repo" "$want"
  patch_security "$repo" "$d_security"

  # Topics are reconciled only where an exception declares them. Defaulting to
  # [] would strip the topics off every repo that has any.
  [[ "$(jq -r 'has("topics")' <<<"$ex")" == "true" ]] && \
    patch_topics "$repo" "$(jq -c '.topics' <<<"$ex")"

  br=$(jq -c 'if has("branch_ruleset") then .branch_ruleset else {} end' <<<"$ex")
  if [[ "$br" != "null" ]]; then
    # has() rather than `//` throughout: `false // default` yields the default,
    # so every deliberately-false override would silently revert.
    reviews=$(jq --argjson d "$d_reviews" \
      'if has("required_approving_review_count") then .required_approving_review_count else $d end' <<<"$br")
    threads=$(jq --argjson d "$d_threads" \
      'if has("required_review_thread_resolution") then .required_review_thread_resolution else $d end' <<<"$br")
    checks=$(jq -c 'if has("required_status_checks") then .required_status_checks else [] end' <<<"$br")
    refs=$(jq -c --argjson d "$d_refs" 'if has("ref_include") then .ref_include else $d end' <<<"$br")
    ensure_ruleset "$repo" "default" "$(branch_ruleset_body "$reviews" "$threads" "$checks" "$refs")"
  fi

  tag=$(jq --argjson d "$d_tag" 'if has("tag_ruleset") then .tag_ruleset else $d end' <<<"$ex")
  if [[ "$tag" == "true" ]]; then
    trefs=$(jq -c --argjson d "$d_tag_refs" 'if has("tag_ref_include") then .tag_ref_include else $d end' <<<"$ex")
    ensure_ruleset "$repo" "tags" "$(tag_ruleset_body "$trefs")"
  fi

  report_unmanaged "$repo"
done

echo
printf 'governed %s repo(s): public in full, private for merge settings only\n' "$governed"
printf 'forks and archived repos are out of scope\n'
[[ $# -gt 0 ]] && printf 'this run covered %s of them\n' "$(wc -w <<<"$REPOS" | tr -d ' ')"

if [[ $drift -eq 0 ]]; then
  echo "in sync — no drift"
elif $APPLY; then
  echo "reconciled $drift item(s)"
else
  echo "$drift item(s) drifted — re-run with --apply"
  exit 1
fi
