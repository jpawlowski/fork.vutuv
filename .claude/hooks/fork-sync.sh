#!/usr/bin/env bash
# Keeps a FORK of this repository from silently drifting behind it.
#
# Upstream's `main` can gain more than a dozen commits in a day, so a branch
# that was current when the work started is routinely behind by the time it is
# pushed — and both consequences are silent: the version bump takes a number
# `upstream/main` has already spent (same line, same value, so no merge conflict
# and no warning), and the PR carries a diff against a base nobody has any more.
#
# Two modes, registered separately in `.claude/settings.json`:
#
#   status      SessionStart. Reports the drift. A SessionStart hook's stdout
#               goes into the session's context, so it reaches the agent before
#               it picks a base branch or a version number.
#   push-gate   PreToolUse(Bash). Blocks `git push` / `gh pr create` from a
#               branch that is behind, or from a fork that never ran
#               `scripts/fork-setup.sh`.
#
# It only ever reads. Setting a fork up is `scripts/fork-setup.sh`, run
# deliberately — a hook that ships in this repository and writes to a
# contributor's `.git/config` unasked would deserve to be rejected.
#
# `bash fork-sync.sh push-gate --explain < payload.json` prints the decision
# without touching the network; `test/vutuv/fork_sync_hook_test.exs` drives it.

set -uo pipefail

# Where this project's source lives — a fact about the project, not an
# installation-specific value (README.md and SECURITY.md already name it).
CANONICAL_REPO=wintermeyer/vutuv
CANONICAL=upstream/main

# A hook must never stop to ask a human anything; nobody is at that terminal.
export GIT_TERMINAL_PROMPT=0

mode=${1:-status}
explain=0
[ "${2:-}" = "--explain" ] && explain=1

# `owner/repo`, lowercased, for a remote — both URL spellings and GitHub's
# case-insensitive names normalise to one comparable value.
slug_of() {
  local url
  url=$(git remote get-url "$1" 2>/dev/null) || return
  url=${url%.git}
  url=${url%/}
  case "$url" in
    *github.com[:/]*) url=$(printf '%s' "${url#*github.com}" | sed 's,^[:/],,') ;;
  esac
  printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}

# `canonical` | `ready` | `unconfigured`.
#
# Nothing local can prove a checkout IS a fork: a fork is byte-for-byte
# identical to its parent, and the relationship exists only on GitHub's
# servers. So prove the opposite — `origin` being the canonical repo — and
# treat everything else as a fork, which fails towards advice, not silence.
fork_state() {
  if [ "$(git config --bool vutuv.fork-sync 2>/dev/null)" = "false" ] ||
    [ "$(slug_of origin)" = "$CANONICAL_REPO" ] ||
    [ -z "$(slug_of origin)" ]; then
    printf 'canonical'
  elif git remote get-url "${CANONICAL%%/*}" >/dev/null 2>&1; then
    printf 'ready'
  else
    printf 'unconfigured'
  fi
}

behind_count() { git rev-list --count "$1".."$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
# status (SessionStart)
# ---------------------------------------------------------------------------

run_status() {
  case "$(fork_state)" in
    canonical) return 0 ;;
    unconfigured)
      echo "**This looks like a fork** ($(slug_of origin)), and it has no remote for"
      echo "$CANONICAL_REPO — so nothing here can tell how far behind it is, and pushing"
      echo "is blocked until it does. One idempotent command sets it up:"
      echo
      echo "    bash scripts/fork-setup.sh"
      echo
      echo "Running a downstream line of your own? \`git config vutuv.fork-sync false\`."
      return 0
      ;;
  esac

  git fetch --quiet "${CANONICAL%%/*}" "${CANONICAL##*/}" 2>/dev/null
  git fetch --quiet origin "${CANONICAL##*/}" 2>/dev/null

  local mirror="origin/${CANONICAL##*/}"
  local mirror_behind head_behind
  mirror_behind=$(behind_count "$mirror" "$CANONICAL")
  head_behind=$(behind_count HEAD "$CANONICAL")

  echo "## Fork status"
  echo
  echo "\`$CANONICAL\` ($CANONICAL_REPO) is the source of truth; \`$mirror\`"
  echo "($(slug_of origin)) is a mirror. Branch from, rebase onto and bump the version"
  echo "against \`$CANONICAL\` — never the mirror, which may hand out a number that is"
  echo "already spent. Push to \`origin\` only, and re-check before opening a PR and"
  echo "again before merging; this is only as fresh as the session's start."
  echo

  if [ "${mirror_behind:-0}" -gt 0 ] 2>/dev/null; then
    echo "- \`$mirror\`: **$mirror_behind behind** — \`gh repo sync $(slug_of origin) --source $CANONICAL_REPO --branch ${CANONICAL##*/} && git fetch origin\`"
  else
    echo "- \`$mirror\`: in sync"
  fi

  if [ "${head_behind:-0}" -gt 0 ] 2>/dev/null; then
    echo "- \`HEAD\` ($(git rev-parse --abbrev-ref HEAD 2>/dev/null)): **$head_behind behind** — \`git rebase $CANONICAL\`"
  fi
}

# ---------------------------------------------------------------------------
# push-gate (PreToolUse, Bash)
# ---------------------------------------------------------------------------

gate_allow() {
  [ "$explain" -eq 1 ] && echo "ALLOW${1:+ $1}"
  exit 0
}

gate_block() {
  if [ "$explain" -eq 1 ]; then
    echo "BLOCK $1"
    exit 0
  fi
  echo "" 1>&2
  echo "BLOCKED: $1" 1>&2
  exit 2
}

strip_quotes() {
  local t=$1
  t=${t#\"}
  t=${t%\"}
  t=${t#\'}
  t=${t%\'}
  printf '%s' "$t"
}

run_push_gate() {
  [ "${VUTUV_ALLOW_STALE_PUSH:-}" = "1" ] && gate_allow "bypassed"

  local payload command payload_cwd
  payload=$(cat)

  # Unlike `precommit-before-push.sh`, which fails CLOSED because unverified
  # code must not reach production, this gate fails OPEN: an unreadable payload
  # or an unreachable GitHub is not evidence that a branch is stale, and a gate
  # that blocks on a flaky network earns an unconditional bypass within a day.
  command -v jq >/dev/null 2>&1 || gate_allow "no jq"

  command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)
  payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)

  # Split on the operators separating one command from the next, then read each
  # segment's own argv0. A substring match on "git push" both over-matches (a
  # plain `grep` for it) and misses `git -C <dir> push` — the lesson
  # `precommit-before-push.sh` records at length.
  local segments hit="" hit_dir="" chain_dir=""
  segments=$(printf '%s' "$command" | awk '{gsub(/&&|\|\||;|\||&/, "\n"); print}')

  local words idx argv0 dir_opt subcommand j w sub1 sub2 next
  while IFS= read -r segment; do
    read -ra words <<<"$segment"
    [ "${#words[@]}" -eq 0 ] && continue

    idx=0
    while [ "$idx" -lt "${#words[@]}" ]; do
      case "${words[$idx]}" in
        [A-Za-z_]*=*) idx=$((idx + 1)) ;;
        *) break ;;
      esac
    done
    [ "$idx" -lt "${#words[@]}" ] || continue

    argv0=$(strip_quotes "${words[$idx]}")
    case "${argv0##*/}" in
      cd)
        next=$((idx + 1))
        [ "$next" -lt "${#words[@]}" ] && chain_dir=$(strip_quotes "${words[$next]}")
        continue
        ;;

      git)
        dir_opt=""
        subcommand=""
        j=$((idx + 1))
        while [ "$j" -lt "${#words[@]}" ]; do
          w=$(strip_quotes "${words[$j]}")
          case "$w" in
            -C)
              j=$((j + 1))
              [ "$j" -lt "${#words[@]}" ] && dir_opt=$(strip_quotes "${words[$j]}")
              ;;
            -C?*) dir_opt=${w#-C} ;;
            -c | --git-dir | --work-tree | --namespace | --exec-path | --config-env) j=$((j + 1)) ;;
            -*) : ;;
            *)
              subcommand=$w
              break
              ;;
          esac
          j=$((j + 1))
        done
        if [ "$subcommand" = "push" ]; then
          hit="push"
          hit_dir=${dir_opt:-$chain_dir}
          break
        fi
        ;;

      gh)
        # `gh pr create` fixes the PR's base, which is what a stale branch gets
        # wrong. `gh pr merge` is deliberately not gated: by then the branch is
        # pushed and `/deploy` step 11 owns the version re-check.
        sub1=""
        sub2=""
        for w in "${words[@]:$((idx + 1))}"; do
          w=$(strip_quotes "$w")
          case "$w" in -*) continue ;; esac
          if [ -z "$sub1" ]; then
            sub1=$w
          elif [ -z "$sub2" ]; then
            sub2=$w
            break
          fi
        done
        if [ "$sub1" = "pr" ] && [ "$sub2" = "create" ]; then
          hit="pr-create"
          hit_dir=$chain_dir
          break
        fi
        ;;
    esac
  done <<<"$segments"

  [ -n "$hit" ] || gate_allow

  local dir toplevel behind
  dir=${hit_dir:-${payload_cwd:-$PWD}}
  toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || gate_allow "not a worktree"
  [ -n "$toplevel" ] || gate_allow "not a worktree"
  cd "$toplevel" || gate_allow "unreachable worktree"

  case "$(fork_state)" in
    canonical) gate_allow "canonical checkout" ;;
    unconfigured)
      [ "$explain" -eq 1 ] && gate_block "unconfigured fork"
      gate_block "this fork has no remote for $CANONICAL_REPO, so nothing can tell whether
the branch is current — and a stale branch means a spent version number and a
PR against a base nobody has any more. Set it up first:

  bash scripts/fork-setup.sh"
      ;;
  esac

  [ "$explain" -eq 1 ] && {
    echo "HIT $hit $toplevel"
    exit 0
  }

  # Best effort: a failed fetch leaves the previous ref in place, and comparing
  # against that beats comparing against nothing.
  git fetch --quiet "${CANONICAL%%/*}" "${CANONICAL##*/}" 2>/dev/null

  behind=$(behind_count HEAD "$CANONICAL")
  [ "${behind:-0}" -gt 0 ] 2>/dev/null || gate_allow

  gate_block "\`$(git rev-parse --abbrev-ref HEAD)\` is $behind commit(s) behind \`$CANONICAL\`.
Rebase first, or the version bump collides and the PR's base is stale:

  git fetch ${CANONICAL%%/*} ${CANONICAL##*/} && git rebase $CANONICAL

Then re-run \`elixir scripts/bump_version.exs …\` and \`mix precommit\`.
Deliberate stale push: prefix the command with VUTUV_ALLOW_STALE_PUSH=1."
}

case "$mode" in
  status) run_status ;;
  push-gate) run_push_gate ;;
  *) echo "usage: fork-sync.sh {status|push-gate} [--explain]" 1>&2 ;;
esac

exit 0
