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

## Rollout and protection

A repository adopts the scan with a small caller workflow pinned to a reviewed
commit. Public repositories can use a repository ruleset to require the scan
and a pull request before their default branch changes. The ruleset uses zero
required approvals for a single-maintainer project. Private repositories on a
plan without branch protection still run the check, but merging green remains a
maintainer procedure. The workflow itself grants only `contents: read`.
