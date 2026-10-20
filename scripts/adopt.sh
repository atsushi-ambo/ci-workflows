#!/usr/bin/env bash
# Adds the shared CI of atsushi-ambo/ci-workflows to the repository in the
# current directory: the secret scan caller, the auto-merge caller, and a
# Dependabot entry that keeps GitHub Actions (and these pins) up to date.
#
# Usage, from the project's repository root:
#   adopt.sh [--ci <workflow file in .github/workflows>]... [--branch <default branch>]
#
# It only writes .github/workflows/security.yml (or updates the pin of an
# existing caller of the shared scan), .github/workflows/automerge.yml and
# .github/dependabot.yml, and creates the "automerge" label when missing. It
# never commits, pushes or changes repository settings. Running it twice
# gives no further change.
set -euo pipefail

OWNER=atsushi-ambo
SHARED=atsushi-ambo/ci-workflows
WF=.github/workflows

usage() {
  sed -n '6,7p' "$0" | sed 's/^# \{0,3\}//'
}
die() { echo "adopt.sh: $*" >&2; exit 1; }
summary=()
note() { summary+=("$*"); }

ci_files=()
branch=""
while [ $# -gt 0 ]; do
  case $1 in
    --ci) [ $# -ge 2 ] || die "--ci needs a workflow file"; ci_files+=("${2#"$WF"/}"); shift 2 ;;
    --branch) [ $# -ge 2 ] || die "--branch needs a branch name"; branch=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for tool in git gh jq; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
[ "$(cd "$root" && pwd -P)" = "$(pwd -P)" ] || die "run from the repository root: $root"

repo_json=$(gh repo view --json nameWithOwner,defaultBranchRef) || die "gh cannot see this repository"
repo=$(jq -r .nameWithOwner <<<"$repo_json")
[ "${repo%%/*}" = "$OWNER" ] || die "$repo is not owned by $OWNER; refusing"
if [ -z "$branch" ]; then
  branch=$(jq -r '.defaultBranchRef.name // empty' <<<"$repo_json")
  [ -n "$branch" ] || die "no default branch (empty repository?); pass --branch"
fi
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "unexpected branch name: $branch"

tag=$(gh release view --repo "$SHARED" --json tagName --jq .tagName) || die "no release of $SHARED"
sha=$(gh api "repos/$SHARED/commits/$tag" --jq .sha) || die "cannot resolve $tag"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "unexpected commit for $tag: $sha"
pin="$sha # $tag"

# --- reading workflows (plain text; enough for the usual layouts) ----------

# The "on:" block of a workflow, without comments.
on_block() {
  sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//' "$1" |
    awk '/^(["\047]?on["\047]?|true):/ {inside=1; print; next} inside && /^[^[:space:]]/ {inside=0} inside {print}'
}
has_trigger() { on_block "$1" | grep -Eq "(^|[^A-Za-z_])$2([^A-Za-z_]|$)"; }
wf_name() {
  local name
  name=$(sed -n 's/^name:[[:space:]]*//p' "$1" | head -n1 | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']$//")
  echo "${name:-$1}"
}
calls_scan() { grep -Eq "^[[:space:]]*(- )?uses:[[:space:]]*$SHARED/\.github/workflows/security\.yml@" "$1"; }
calls_automerge() { grep -Eq "^[[:space:]]*(- )?uses:[[:space:]]*$SHARED/\.github/workflows/automerge\.yml@" "$1"; }

# Writes $2 to file $1 unless it already has exactly that content.
put() {
  local file=$1 content=$2 verb=added
  [ -f "$file" ] && verb=updated
  if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
    note "unchanged $file"
    return
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" >"$file"
  note "$verb $file"
}
# Rewrites the pin of every "uses: <shared>/<workflow>@..." line in $1.
repin() {
  local file=$1 workflow=$2 before after
  before=$(cat "$file")
  after=$(sed -E "s|^([[:space:]]*(- )?uses:[[:space:]]*$SHARED/\.github/workflows/$workflow@).*\$|\1$pin|" "$file")
  if [ "$before" = "$after" ]; then
    note "unchanged $file"
  else
    printf '%s\n' "$after" >"$file"
    note "updated $file (pinned $workflow to $tag)"
  fi
}

mkdir -p "$WF"
shopt -s nullglob
workflows=("$WF"/*.yml "$WF"/*.yaml)

# --- secret scan --------------------------------------------------------------

scan_files=()
for f in ${workflows[@]+"${workflows[@]}"}; do
  if calls_scan "$f"; then scan_files+=("$f"); fi
done
if [ "${#scan_files[@]}" -gt 0 ]; then
  for f in "${scan_files[@]}"; do repin "$f" security.yml; done
else
  scan_file=$WF/security.yml
  if [ -e "$scan_file" ] || [ -e "$WF/security.yaml" ]; then
    scan_file=$WF/secret-scan.yml
    [ ! -e "$scan_file" ] || die "$WF/security.yml and $scan_file exist but do not call the shared scan"
  fi
  scan_name=$(basename "$scan_file" .yml)
  put "$scan_file" "name: $scan_name
on:
  pull_request:
  push:
    branches: [\"$branch\"]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  scan:
    uses: $SHARED/.github/workflows/security.yml@$pin"
  scan_files=("$scan_file")
  workflows+=("$scan_file")
fi

# --- auto-merge ---------------------------------------------------------------

automerge_file=$WF/automerge.yml
skip_reason=""
required=()
if [ "${#ci_files[@]}" -gt 0 ]; then
  for c in "${ci_files[@]}"; do
    [ -f "$WF/$c" ] || die "no workflow $WF/$c"
    has_trigger "$WF/$c" pull_request || die "$WF/$c does not run on pull_request"
    required+=("$WF/$c")
  done
elif [ -f "$automerge_file" ] && calls_automerge "$automerge_file"; then
  required=(keep)
else
  candidates=()
  for f in ${workflows[@]+"${workflows[@]}"}; do
    [ "$f" = "$automerge_file" ] && continue
    calls_scan "$f" && continue
    has_trigger "$f" pull_request && candidates+=("$f")
  done
  deploys=()
  for f in ${workflows[@]+"${workflows[@]}"}; do
    has_trigger "$f" push || continue
    if sed -e '/^[[:space:]]*#/d' "$f" | grep -Eiq '(^|[^a-z_-])(deploy|publish)|^[[:space:]]+environment:'; then
      deploys+=("$f")
    fi
  done
  if [ -d .circleci ] || [ -f .travis.yml ] || [ -f .gitlab-ci.yml ]; then
    skip_reason="tests run outside GitHub Actions, which auto-merge cannot see"
  elif [ "${#deploys[@]}" -gt 0 ]; then
    skip_reason="${deploys[*]} deploys or publishes on push, and a merge made by auto-merge does not trigger push workflows"
  elif [ "${#candidates[@]}" -eq 0 ]; then
    skip_reason="no CI workflow runs on pull_request besides the secret scan"
  elif [ "${#candidates[@]}" -gt 1 ]; then
    skip_reason="several workflows run on pull_request (${candidates[*]}); choose with --ci (repeatable)"
  elif on_block "${candidates[0]}" | grep -Eq '^[[:space:]]+paths(-ignore)?:'; then
    skip_reason="${candidates[0]} is limited by paths and may not run for every PR"
  else
    required=("${candidates[0]}")
  fi
fi

if [ -n "$skip_reason" ]; then
  note "skipped auto-merge: $skip_reason"
elif [ "${required[0]}" = keep ]; then
  repin "$automerge_file" automerge.yml
  note "kept the CI list of the existing $automerge_file (pass --ci to replace it)"
else
  # Auto-merge finds runs by workflow name, so the names must tell the
  # required workflows apart from each other and from any other workflow.
  names=()
  name_files=()
  for f in "${required[@]}" "${scan_files[@]}"; do
    n=$(wf_name "$f")
    [[ $n != *'"'* ]] || die "workflow name with a double quote: $n"
    seen=""
    for g in ${name_files[@]+"${name_files[@]}"}; do [ "$g" = "$f" ] && seen=1; done
    [ -n "$seen" ] && continue
    for g in ${workflows[@]+"${workflows[@]}"}; do
      [ "$g" = "$f" ] || [ "$g" = "$automerge_file" ] && continue
      [ "$(wf_name "$g")" != "$n" ] || die "$f and $g are both named '$n'; rename one"
    done
    names+=("$n")
    name_files+=("$f")
  done
  list=$(printf '"%s", ' "${names[@]}")
  put "$automerge_file" "name: automerge
# Merges a PR labelled \"automerge\" once CI has passed on its latest commit.
# The checks live in $SHARED; it never runs the PR's code.
on:
  workflow_run:
    workflows: [${list%, }]
    types: [completed]
  # A label added, or a draft marked ready, after CI already passed.
  pull_request_target:
    types: [labeled, ready_for_review]
permissions: {}
jobs:
  merge:
    uses: $SHARED/.github/workflows/automerge.yml@$pin
    permissions:
      contents: write
      pull-requests: write
      actions: write
    with:
      default-branch: $branch
      ci-workflows: |
$(printf '        %s\n' "${names[@]}")"
fi

if [ -f "$automerge_file" ] && calls_automerge "$automerge_file"; then
  labels=$(gh label list --limit 200 --json name --jq '.[].name')
  if grep -qx automerge <<<"$labels"; then
    note "label automerge already exists"
  else
    gh label create automerge --color 0e8a16 \
      --description "Merge automatically once CI passes on the latest commit" >/dev/null
    note "created label automerge"
  fi
fi

# --- Dependabot for GitHub Actions --------------------------------------------

dependabot=.github/dependabot.yml
[ -f .github/dependabot.yaml ] && dependabot=.github/dependabot.yaml
entry="package-ecosystem: \"github-actions\"
  directory: \"/\"
  schedule:
    interval: \"weekly\""
if [ ! -f "$dependabot" ]; then
  put "$dependabot" "version: 2
updates:
  - $(sed '2,$s/^/  /' <<<"$entry")"
elif grep -Eq "package-ecosystem:[[:space:]]*[\"']?github-actions[\"']?[[:space:]]*(#.*)?$" "$dependabot"; then
  note "unchanged $dependabot (github-actions entry present)"
else
  grep -q '^updates:' "$dependabot" || die "$dependabot has no top-level updates:; add the github-actions entry by hand"
  if awk '/^updates:/ {after=1; next} after && /^[A-Za-z]/ {found=1} END {exit !found}' "$dependabot"; then
    die "$dependabot has keys after updates:; add the github-actions entry by hand"
  fi
  indent=$(sed -n 's/^\([[:space:]]*\)- .*/\1/p' "$dependabot" | head -n1)
  [ -n "$(tail -c1 "$dependabot")" ] && echo >>"$dependabot"
  sed "1s/^/$indent- /; 2,\$s/^/$indent/" <<<"$entry" >>"$dependabot"
  note "updated $dependabot (added github-actions entry)"
fi

echo "adopt.sh: $repo ($branch), shared CI $tag ($sha)"
printf -- '- %s\n' "${summary[@]}"
