#!/bin/sh
# Publish a repository tree as a single orphan commit, force-pushed.
# usage: publish.sh <repo-dir> <remote-url> <branch> <message>
#
# A fresh `git init` in the tree gives an orphan branch for free: there is no
# history to inherit, so the branch is always exactly one commit and years of
# published debs never accumulate in git.
set -eu
# shellcheck source=/dev/null
. "$(dirname "$0")/../packaging/repo.conf"

repo="${1:?repo dir required}"
remote="${2:?remote url required}"
branch="${3:?branch required}"
message="${4:?commit message required}"

cd "$repo"
rm -rf .git
git init -q -b "$branch"
git config user.name  "unison-deb CI"
# Extract email from MAINTAINER (format: "Name <email>")
git config user.email "$(printf '%s' "$MAINTAINER" | sed -n 's/.*<\(.*\)>.*/\1/p')"

# Published debs are binaries; keep git from mangling them or guessing text.
printf '* -text -diff\n' > .gitattributes
# Pages serves the tree verbatim; this stops Jekyll from hiding files whose
# names begin with an underscore or being run at all.
: > .nojekyll

git add -A
git commit -q -m "$message"
git push -q --force "$remote" "$branch:$branch"
echo "published $(git rev-parse --short HEAD) to $branch"
