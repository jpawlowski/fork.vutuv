#!/usr/bin/env bash
# SessionStart hook: in a fork, report how far it has fallen behind the
# canonical repository. A SessionStart hook's stdout is added to the session's
# context, so this reaches an agent before it picks a base branch.
#
# Silent unless there is something to say — and silent altogether in a clone of
# the canonical repository. Nothing local can prove a checkout *is* a fork (it
# is byte-for-byte identical to its parent), so this proves the opposite: that
# `origin` is the canonical repository. Opt out with
# `git config vutuv.fork-sync false`.

set -uo pipefail

CANONICAL_REPO=${VUTUV_CANONICAL_REPO:-wintermeyer/vutuv}

toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$toplevel" || exit 0

[ "$(git config --bool vutuv.fork-sync 2>/dev/null)" = "false" ] && exit 0

origin_url=$(git remote get-url origin 2>/dev/null) || exit 0
origin_slug=$(printf '%s' "$origin_url" |
  sed -E 's,.*github\.com[:/]|\.git$,,g' | tr '[:upper:]' '[:lower:]')

# An unchanged slug means the sed matched no GitHub URL, so this is some other
# host and none of the advice below applies.
case "$origin_slug" in
  "" | *:* | *//* | "$CANONICAL_REPO") exit 0 ;;
esac

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "This looks like a fork of $CANONICAL_REPO with no remote for it."
  echo "Run \`./scripts/fork_setup.sh\` once, then branch from \`upstream/main\`."
  exit 0
fi

# Bounded and non-interactive: nobody is at this terminal to answer a password
# prompt, and a stalled network must not hold up the session.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=5'
fetch() {
  git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 \
    fetch --quiet --no-tags "$1" main </dev/null 2>/dev/null
}

if ! fetch upstream || ! git rev-parse --verify --quiet upstream/main >/dev/null; then
  echo "Could not reach $CANONICAL_REPO — cannot tell how far behind this fork is."
  exit 0
fi
fetch origin

mirror_behind=$(git rev-list --count origin/main..upstream/main)
head_behind=$(git rev-list --count HEAD..upstream/main)
[ "${mirror_behind:-0}" -eq 0 ] && [ "${head_behind:-0}" -eq 0 ] && exit 0

echo "## Fork status"
echo
[ "${mirror_behind:-0}" -gt 0 ] &&
  echo "- \`origin/main\` is **$mirror_behind behind** — \`gh repo sync $origin_slug --source $CANONICAL_REPO --branch main && git fetch origin\`"
[ "${head_behind:-0}" -gt 0 ] &&
  echo "- \`$(git rev-parse --abbrev-ref HEAD)\` is **$head_behind behind** — \`git rebase upstream/main\`"
echo
echo "Branch from and rebase onto \`upstream/main\`; \`origin/main\` is only a mirror of it."
