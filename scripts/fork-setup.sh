#!/usr/bin/env bash
# One-time setup for a FORK of this repository. Idempotent — run it again any
# time; it only reports what was already in place.
#
# Pull requests go to the canonical repository, so that repository, not your
# fork, is the source of truth for the base branch and for the version number.
# Reading `origin/main` instead is not a staler answer but a wrong one: a mirror
# one merge behind hands out a version number upstream has already spent, and
# that collision produces no merge conflict and no warning.
#
# `.claude/hooks/fork-sync.sh` checks that this ran and blocks a push until it
# has; it never performs these changes itself, because a hook that writes to
# your `.git/config` unasked has no business shipping in a repository.
#
#   bash scripts/fork-setup.sh

set -euo pipefail

CANONICAL_REPO=wintermeyer/vutuv
REMOTE=upstream
BRANCH=main

cd "$(git rev-parse --show-toplevel)"

origin_slug=$(git remote get-url origin 2>/dev/null |
  sed -e 's,\.git$,,' -e 's,.*github\.com[:/],,' | tr '[:upper:]' '[:lower:]')

if [ "$origin_slug" = "$CANONICAL_REPO" ]; then
  echo "origin is $CANONICAL_REPO — this is not a fork, nothing to set up."
  exit 0
fi

echo "Setting up a fork of $CANONICAL_REPO (origin: ${origin_slug:-none})"

if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "https://github.com/$CANONICAL_REPO.git"
  echo "  ✓ remote '$REMOTE' → $CANONICAL_REPO (updated)"
else
  git remote add "$REMOTE" "https://github.com/$CANONICAL_REPO.git"
  echo "  ✓ remote '$REMOTE' → $CANONICAL_REPO"
fi

# Fetch-only. An agent with a `git push` reflex otherwise aims at somebody
# else's repository, and write access is not what makes that a bad idea.
git remote set-url --push "$REMOTE" DISABLED_use_origin
echo "  ✓ pushing to '$REMOTE' disabled — push to origin only"

if git fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null; then
  echo "  ✓ fetched $REMOTE/$BRANCH ($(git rev-parse --short "$REMOTE/$BRANCH"))"
else
  echo "  ! could not fetch $REMOTE/$BRANCH — run 'git fetch $REMOTE' once you are online"
fi

# Not cosmetic: without a default repo, `gh api repos/{owner}/{repo}` resolves
# to nothing in a fork clone, and `scripts/bump_version.exs` degrades to "could
# not read the open PRs; using mix.exs only" — losing the very check that keeps
# two branches off the same version number.
if command -v gh >/dev/null 2>&1; then
  if gh repo set-default "$CANONICAL_REPO" >/dev/null 2>&1 </dev/null; then
    echo "  ✓ gh default repository → $CANONICAL_REPO"
  else
    echo "  ! 'gh repo set-default $CANONICAL_REPO' failed — run it once you are logged in"
  fi
else
  echo "  ! gh is not installed — run 'gh repo set-default $CANONICAL_REPO' when it is"
fi

cat <<DONE

Done. From here on:

  - branch from, rebase onto, and bump the version against $REMOTE/$BRANCH
  - push to origin only; the PR goes to $CANONICAL_REPO
  - keep your fork's $BRANCH a pure mirror and never commit to it:
      gh repo sync $origin_slug --source $CANONICAL_REPO --branch $BRANCH

CONTRIBUTING.md, "Working from a fork", has the reasoning for each of these.
DONE
