# Shared CI security workflow

A read-only secret scan for repositories owned by `atsushi-ambo`. The workflow
uses a SHA-pinned checkout action, verifies the downloaded gitleaks archive,
scans full Git history, and runs without project or deployment credentials.
A caller's `.gitleaks.toml` is honored when present.

Call it from a small workflow in each project:

```yaml
name: security
on:
  pull_request:
  push:
    branches: [main] # replace with the project's default branch
permissions:
  contents: read
jobs:
  scan:
    uses: atsushi-ambo/ci-workflows/.github/workflows/security.yml@COMMIT_SHA
```

Pin `COMMIT_SHA` to a reviewed commit. Update callers deliberately after a change
here has passed its own checks. This repository is public so both public and
private personal projects can call it. No secrets or deployment logic belong
here. Project-specific lint, tests, database services, and deployment remain in
each project. Before making this check mandatory in an existing repository,
inspect any historical findings and revoke real leaked credentials.

Deployment follows each project's hosting architecture. Use short-lived OIDC
credentials, limit the trusted repository/ref/environment in the cloud trust
policy, and keep deployment jobs separate from untrusted pull-request checks.

## Adopting the shared CI in a project

`scripts/adopt.sh` sets up the same shared CI in any project of
`atsushi-ambo`, new or existing. Run it from the project's repository root,
review the diff, then commit it in a pull request:

```sh
/Users/atsushiambo/personal/app/ci-workflows/scripts/adopt.sh [--ci <workflow file>]... [--branch <default branch>]
```

It writes only these files, pinning this repository to the commit of its
latest release with a `# vX.Y.Z` comment so Dependabot can bump the pin:

- `.github/workflows/security.yml`: the secret scan caller. An existing caller
  of the shared scan keeps its file name and only gets the new pin; if
  `security.yml` is taken by an unrelated workflow, `secret-scan.yml` is used.
- `.github/workflows/automerge.yml`: the auto-merge caller, which waits for the
  project's CI and the secret scan. Without `--ci` it picks the one workflow
  that runs on `pull_request`; it adds no auto-merge (and says why) when there
  is none, several, one limited by `paths`, a workflow that deploys or
  publishes on push (a merge by the workflow token would not trigger it), or
  CI outside GitHub Actions. An existing caller keeps its CI list and only gets
  the new pin unless `--ci` is given (repeatable).
- `.github/dependabot.yml`: a weekly `github-actions` entry, added without
  changing other entries.

It also creates the `automerge` label when the auto-merge caller is present.
It never commits, pushes or changes repository settings, refuses to run
outside a git repository root or for a repository of another owner, and a
second run changes nothing. `tests/adopt_test.sh` checks this with a stub `gh`.

Releases are tagged `vX.Y.Z` here after their checks pass; projects then move
to a new release through Dependabot pull requests or by running `adopt.sh`
again.

## Auto-merge for labelled pull requests

`automerge.yml` merges a pull request once the project's own CI has passed on
its latest commit. It is for repositories where GitHub's native auto-merge and
branch protection are not available (private repositories on the Free plan).
It only calls the GitHub API and never checks out or runs pull-request code.

A PR is merged only when all of these hold: it has the `automerge` label, comes
from a branch of the same repository, was opened by the repository owner, is
not a draft, targets the default branch, the newest `pull_request` run of every
listed CI workflow for that exact PR and commit succeeded, and the branch
already contains the latest default branch. The merge uses
`--match-head-commit`, merges are serialized per repository (a manual push to the default branch in
the seconds between the up-to-date check and the merge is not detected), and afterwards
each listed CI workflow that has `workflow_dispatch` is started on the default
branch (a merge made with the workflow token does not trigger `push`
workflows, so deploy-on-push workflows will not run either).

Caller, with the workflow names copied from the project's CI (`name:`):

```yaml
name: automerge
on:
  workflow_run:
    workflows: [CI] # the project's CI workflow names
    types: [completed]
  # A label added, or a draft marked ready, after CI already passed.
  pull_request_target:
    types: [labeled, ready_for_review]
permissions: {}
jobs:
  merge:
    uses: atsushi-ambo/ci-workflows/.github/workflows/automerge.yml@COMMIT_SHA
    permissions:
      contents: write
      pull-requests: write
      actions: write
    with:
      default-branch: main
      ci-workflows: |
        CI
```

The caller job must grant the three write permissions above; the reusable
workflow cannot raise them. Create the label once per repository:

```sh
gh label create automerge --color 0e8a16 --description "Merge automatically once CI passes on the latest commit"
```

Keep the list under `workflow_run.workflows` and `ci-workflows` the same.
Do not list a workflow that is filtered by `paths` and may not run for a PR;
such a PR would then never merge automatically.

## Rollout and protection

A repository adopts the scan with a small caller workflow pinned to a reviewed
commit. Public repositories can use a repository ruleset to require the scan
and a pull request before their default branch changes. The ruleset uses zero
required approvals for a single-maintainer project. Private repositories on a
plan without branch protection still run the check, but merging green remains a
maintainer procedure. The workflow itself grants only `contents: read`.
