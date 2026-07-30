# jdf-ops

Declarative GitHub configuration for my personal repositories — merge settings,
branch and tag rulesets, secret scanning.

```sh
./apply.sh            # report drift, change nothing
./apply.sh --apply    # make reality match repos.json
```

Every operation is a PATCH or PUT of desired state, so the no-argument form is a
drift check: it exits 0 when everything matches and 1 when something has moved.

## Scope is discovered, not listed

`repos.json` holds the policy and the exceptions to it, never the inventory.
Every **public, non-fork, non-archived** repository owned by the authenticated
user is governed by `defaults`, so a repository created tomorrow is covered
without editing anything.

Private repositories are out of scope.

## The policy

**Merge settings.** Rebase only — no merge commits, no squashing. Auto-merge and
the update-branch button on, branches deleted after merge.

**Branch ruleset** on the default branch: no deletion, no force-push, linear
history, and every change arrives through a pull request that can only be
rebased. Zero approvals required — these are single-author repositories, so the
rule worth enforcing is that changes go through a pull request, not that someone
else signs them off. `bypass_actors` is empty, which includes the owner.

No required status checks: most of these repositories have no CI, and a required
check that never reports blocks the branch permanently.

**Tag ruleset** on `refs/tags/v*` and `refs/tags/*-v*`: release tags cannot be
moved or deleted. Two patterns because both conventions are in use here, bare
(`v1.0`) and component-prefixed (`jdf-tab-huddle-v0.2.2`). Names outside them —
`nightly`, `latest`, a scratch tag — stay movable, which is what removes any
reason to disable the ruleset by hand.

**Secret scanning**, push protection, non-provider patterns and validity checks,
all enabled.

## Exceptions

An entry in `exceptions[]` overrides the defaults for one repository:

```json
{
  "name": "some-repo",
  "settings": { "allow_squash_merge": true },
  "description": "…",
  "topics": ["…"],
  "branch_ruleset": { "required_status_checks": ["build"] },
  "tag_ruleset": false
}
```

`branch_ruleset: null` exempts a repository entirely — an empty repository has no
branches, so no ruleset can be created on it.

Description and topics are reconciled **only** where an exception declares them.
Defaulting topics to `[]` would strip them off every repository that has any.

## Licence

MIT
