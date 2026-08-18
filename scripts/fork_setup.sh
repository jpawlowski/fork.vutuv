#!/usr/bin/env bash
# Sets a fork of this repository up to track it: adds a fetch-only `upstream`
# remote, fetches it, and points `gh` at the canonical repository. Safe to
# re-run at any time.
#
#   ./scripts/fork_setup.sh
#
# The `gh` step is not cosmetic: without a default repository, `gh api
# repos/{owner}/{repo}` resolves to nothing in a fork clone, and
# `scripts/bump_version.exs` quietly falls back to reading `mix.exs` alone.

set -euo pipefail

CANONICAL_REPO=${VUTUV_CANONICAL_REPO:-wintermeyer/vutuv}
CANONICAL_URL="https://github.com/$CANONICAL_REPO.git"

toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Run this from inside your fork's checkout." >&2
  exit 1
}
cd "$toplevel"

origin_url=$(git remote get-url origin 2>/dev/null) || origin_url=""
origin_slug=$(printf '%s' "$origin_url" |
  sed -E 's,.*github\.com[:/]|\.git$,,g' | tr '[:upper:]' '[:lower:]')

if [ "$origin_slug" = "$CANONICAL_REPO" ]; then
  echo "origin is $CANONICAL_REPO — this is not a fork, nothing to set up."
  exit 0
fi

echo "Setting up a fork of $CANONICAL_REPO (origin: ${origin_slug:-none})"

# Replace the remote rather than rewriting its URL: `git remote set-url` leaves
# a missing or stale fetch refspec in place, and then nothing ever lands in
# `upstream/main` while every command still reports success.
git remote remove upstream 2>/dev/null || true
git remote add upstream "$CANONICAL_URL"
# Fetch-only, so that a stray `git push upstream` cannot aim at someone else's
# repository.
git remote set-url --push upstream DISABLED_use_origin
echo "  ✓ upstream → $CANONICAL_REPO (fetch-only)"

# GIT_TERMINAL_PROMPT=0 and the closed stdin matter: on a 401 the fetch would
# otherwise sit on a username prompt forever, and nobody is at this terminal.
if err=$(GIT_TERMINAL_PROMPT=0 git fetch --quiet upstream main 2>&1 </dev/null) &&
  sha=$(git rev-parse --short upstream/main 2>/dev/null); then
  echo "  ✓ fetched upstream/main ($sha)"
else
  echo "  ! could not fetch upstream/main: ${err:-no such branch}"
fi

if command -v gh >/dev/null 2>&1; then
  if err=$(gh repo set-default "$CANONICAL_REPO" 2>&1 </dev/null); then
    echo "  ✓ gh default repository → $CANONICAL_REPO"
  else
    echo "  ! gh repo set-default failed: $err"
  fi
else
  echo "  ! gh is not installed — run 'gh repo set-default $CANONICAL_REPO' later"
fi

echo
echo "Branch from upstream/main and push to origin only."
case "$origin_slug" in
  "" | *:*) ;;
  */*) echo "Keep your fork's main a mirror: gh repo sync $origin_slug --source $CANONICAL_REPO --branch main" ;;
esac
