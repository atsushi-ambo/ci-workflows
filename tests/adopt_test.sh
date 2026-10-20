#!/usr/bin/env bash
# Tests scripts/adopt.sh on throwaway repositories with a stub gh: the files it
# writes, that a second run changes nothing, and what it refuses.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd -P)
adopt=$here/scripts/adopt.sh
tmp=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"' EXIT
sha=0123456789abcdef0123456789abcdef01234567
failures=0

# Stub gh: answers only the calls adopt.sh makes, logs label creation.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "repo view") printf '{"nameWithOwner":"%s/demo","defaultBranchRef":{"name":"%s"}}\n' "${STUB_OWNER:-atsushi-ambo}" "${STUB_BRANCH:-main}" ;;
  "release view") echo v1.2.3 ;;
  "api repos/atsushi-ambo/ci-workflows/commits/v1.2.3") echo "$STUB_SHA" ;;
  "label list") [ -f "$STUB_LABELS" ] && cat "$STUB_LABELS" || true ;;
  "label create") echo "$3" >>"$STUB_LABELS" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_SHA=$sha

fail() { echo "FAIL [$case]: $*" >&2; failures=$((failures + 1)); }
expect_file() { [ -f "$1" ] || fail "missing $1"; }
expect_grep() { grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"; }
expect_no_file() { [ ! -e "$1" ] || fail "unexpected $1"; }

# new_repo NAME: a git repository whose files come from the heredoc on stdin
# (lines "=== path" start a file).
new_repo() {
  local dir=$tmp/$1 file=""
  mkdir -p "$dir"
  git -C "$dir" init -q
  while IFS= read -r line; do
    if [[ $line == "=== "* ]]; then
      file=$dir/${line#=== }; mkdir -p "$(dirname "$file")"; : >"$file"
    elif [ -n "$file" ]; then
      printf '%s\n' "$line" >>"$file"
    fi
  done
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -qm fixture --allow-empty
  export STUB_LABELS=$dir.labels
  cd "$dir"
}
# Runs adopt.sh twice; the second run must not change anything.
adopt_twice() {
  "$adopt" "$@" >"$tmp/out1" || { fail "first run failed: $(cat "$tmp/out1")"; return; }
  git add -A
  git -c user.name=t -c user.email=t@example.com commit -qm adopted --allow-empty
  "$adopt" "$@" >"$tmp/out2" || { fail "second run failed"; return; }
  [ -z "$(git status --porcelain)" ] || fail "second run changed: $(git status --porcelain)"
  grep -Eq '^- (added|updated)' "$tmp/out2" && fail "second run reported changes: $(cat "$tmp/out2")"
  return 0
}

case=single-ci
new_repo single <<'EOF'
=== .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs: {}
EOF
adopt_twice
expect_grep .github/workflows/security.yml "uses: atsushi-ambo/ci-workflows/.github/workflows/security.yml@$sha # v1.2.3"
expect_grep .github/workflows/automerge.yml "uses: atsushi-ambo/ci-workflows/.github/workflows/automerge.yml@$sha # v1.2.3"
expect_grep .github/workflows/automerge.yml 'workflows: ["CI", "security"]'
expect_grep .github/workflows/automerge.yml "default-branch: main"
expect_grep .github/dependabot.yml 'package-ecosystem: "github-actions"'
expect_grep "$STUB_LABELS" automerge
[ "$(wc -l <"$STUB_LABELS")" -eq 1 ] || fail "label created more than once"

case=scan-only
new_repo scanonly <<'EOF'
=== README.md
docs
EOF
STUB_BRANCH=master adopt_twice
expect_grep .github/workflows/security.yml 'branches: ["master"]'
expect_no_file .github/workflows/automerge.yml
expect_grep "$tmp/out1" "skipped auto-merge: no CI workflow"
expect_no_file "$STUB_LABELS"

case=existing-callers
new_repo existing <<'EOF'
=== .github/workflows/security.yml
name: Security
on: [pull_request]
jobs: {}
=== .github/workflows/gitleaks.yml
name: gitleaks
on:
  pull_request:
jobs:
  scan:
    uses: atsushi-ambo/ci-workflows/.github/workflows/security.yml@e32497f0fb113b8a5556c218b4fef1ca398283c2
=== .github/workflows/automerge.yml
name: automerge
jobs:
  merge:
    uses: atsushi-ambo/ci-workflows/.github/workflows/automerge.yml@456ca23091f484ee76af73531125108bc96976e1
    with:
      ci-workflows: |
        Security
        gitleaks
=== .github/dependabot.yml
version: 2
updates:
    - package-ecosystem: "npm"
      directory: "/"
      schedule:
        interval: "daily"
EOF
adopt_twice
expect_grep .github/workflows/gitleaks.yml "security.yml@$sha # v1.2.3"
expect_grep .github/workflows/automerge.yml "automerge.yml@$sha # v1.2.3"
expect_grep .github/workflows/automerge.yml "        gitleaks"
expect_grep .github/workflows/security.yml "name: Security"
expect_no_file .github/workflows/secret-scan.yml
expect_grep .github/dependabot.yml 'package-ecosystem: "npm"'
expect_grep .github/dependabot.yml '    - package-ecosystem: "github-actions"'
expect_grep .github/dependabot.yml '      directory: "/"'

case=explicit-ci
new_repo explicit <<'EOF'
=== .github/workflows/security.yml
name: Security audit
on:
  pull_request:
jobs: {}
=== .github/workflows/test.yml
name: test
on:
  pull_request:
jobs: {}
EOF
adopt_twice --ci test.yml --ci security.yml
expect_grep .github/workflows/secret-scan.yml "name: secret-scan"
expect_grep .github/workflows/automerge.yml 'workflows: ["test", "Security audit", "secret-scan"]'

case=ambiguous
new_repo ambiguous <<'EOF'
=== .github/workflows/a.yml
name: a
on: [push, pull_request]
jobs: {}
=== .github/workflows/b.yml
name: b
on: pull_request
jobs: {}
EOF
adopt_twice
expect_no_file .github/workflows/automerge.yml
expect_grep "$tmp/out1" "several workflows run on pull_request"

case=deploys-on-push
new_repo deploys <<'EOF'
=== .github/workflows/ci.yml
name: CI
on:
  pull_request:
jobs: {}
=== .github/workflows/pages.yml
name: Pages
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
EOF
adopt_twice
expect_no_file .github/workflows/automerge.yml
expect_grep "$tmp/out1" "deploys or publishes on push"

case=name-collision
new_repo collision <<'EOF'
=== .github/workflows/ci.yml
name: security
on:
  pull_request:
jobs: {}
EOF
if "$adopt" --ci ci.yml >"$tmp/out1" 2>&1; then fail "accepted two workflows named security"; fi
expect_grep "$tmp/out1" "are both named 'security'"
expect_no_file .github/workflows/automerge.yml

case=commented-and-quoted
new_repo commented <<'EOF'
=== .github/workflows/ci.yml
name: CI
'on':
  pull_request:
jobs: {}
#    uses: atsushi-ambo/ci-workflows/.github/workflows/security.yml@e32497f0fb113b8a5556c218b4fef1ca398283c2
=== .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions # keep pins fresh
    directory: /
    schedule:
      interval: weekly
EOF
adopt_twice
expect_grep .github/workflows/security.yml "security.yml@$sha # v1.2.3"
expect_grep .github/workflows/automerge.yml 'workflows: ["CI", "security"]'
[ "$(grep -c github-actions .github/dependabot.yml)" -eq 1 ] || fail "duplicated the github-actions entry"

case=other-owner
new_repo other <<'EOF'
=== README.md
x
EOF
if STUB_OWNER=someone-else "$adopt" >"$tmp/out1" 2>&1; then fail "ran for another owner"; fi
expect_grep "$tmp/out1" "not owned by atsushi-ambo"
[ -z "$(git status --porcelain)" ] || fail "wrote files for another owner"

case=not-root
mkdir -p "$tmp/other/sub"
cd "$tmp/other/sub"
if "$adopt" >"$tmp/out1" 2>&1; then fail "ran outside the repository root"; fi

case=not-git
mkdir -p "$tmp/plain"
cd "$tmp/plain"
if "$adopt" >"$tmp/out1" 2>&1; then fail "ran outside a git repository"; fi
expect_grep "$tmp/out1" "not inside a git repository"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "adopt.sh: all tests passed"
