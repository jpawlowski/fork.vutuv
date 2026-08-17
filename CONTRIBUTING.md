# Contributing to vutuv

Thanks for helping! The short version:

## Getting started

Follow the [Development Setup](docs/DEVELOPERS.md#development-setup) in the
developer guide (`mise` for Erlang/Elixir, PostgreSQL 17, libvips, then
`mix setup` and `mix phx.server`). Emails land in the browser at
[/sent_emails](http://localhost:4000/sent_emails) — you'll need that for the
PIN login flow. Installing vutuv to *run* it (rather than develop it) is
covered separately in [docs/ADMINS.md](docs/ADMINS.md).

## Working from a fork

If you work in a fork rather than in a clone of this repository, staleness is
the standing hazard: `main` here can gain more than a dozen commits in a day,
so a fork is behind within hours — and nothing about being behind announces
itself. Run this once, right after cloning (it is idempotent, so run it again
whenever you are unsure):

```bash
bash scripts/fork-setup.sh
```

It adds an `upstream` remote for this repository, makes it fetch-only, fetches
it, and points `gh` at it. What that buys you:

- **`upstream` is the source of truth.** Branch from `upstream/main`, rebase
  onto `upstream/main`, and read `upstream/main` — not your fork — when you
  bump the version in `mix.exs`. A mirror one merge behind hands out a number
  that is already spent, and that collision produces no merge conflict and no
  warning: the squash lands your work without moving the version.
- **`origin` is the only push target.** The disabled push URL above is not
  paranoia; a stray `git push upstream` otherwise aims at this repository.
- **`gh repo set-default` is not cosmetic.** Without it, `gh api
  repos/{owner}/{repo}` resolves to nothing in a fork clone, and
  `scripts/bump_version.exs` quietly degrades to "could not read the open PRs;
  using mix.exs only" — losing the check that keeps two branches off the same
  version.
- **Keep your fork's `main` a pure mirror** — never commit to it, and
  fast-forward it with `gh repo sync <you>/vutuv --source wintermeyer/vutuv
  --branch main` (server-side, so it also works while `main` is checked out in
  a worktree). GitHub computes your PR's diff and its "N commits behind"
  banner from it. A push to `main` also triggers `.github/workflows/deploy.yml`
  in a fork.
- **Rebase, don't merge.** PRs here are squash-merged, so a merge commit from
  `upstream` only muddies the diff. And never reuse a branch after its PR was
  merged: the squash replays your work as a new commit, so the next PR from
  that branch opens `CONFLICTING` — and a conflicting PR gets no CI run at all.

If you work with an AI coding agent, `.claude/hooks/fork-sync.sh` does the
watching for you: it reports the drift at the start of every session, and
blocks a `git push` or `gh pr create` from a branch that was never rebased —
or from a fork that never ran the setup above (`VUTUV_ALLOW_STALE_PUSH=1`
overrides the freshness check). It only reads; the setup script is the only
thing that touches your git config. When `origin` is this repository, both are
silent, so working here directly costs nothing. Running a downstream line of
your own? `git config vutuv.fork-sync false`.

## Ground rules

- **Start every feature or bugfix with a test** that covers it, then make it
  pass.
- **Write the PR body for one minute of attention — around 200 words.** The
  reviewer does not have the code in their head: open with the issue reference
  or a one-sentence `TL;DR`, name the file to look at first, back claims with
  what you actually exercised, and say whether the deploy is hot or cold. Add a
  screenshot where the change is visual in a way words cannot carry — not for
  every visible change. Anything a reviewer can read off the diff does not
  belong in the body.
- **Run `mix precommit` before pushing** — CI runs exactly this alias
  (compile with `--warnings-as-errors`, `credo --strict`,
  `mix format --check-formatted`, `mix test`). Don't push if it fails.
- **Migrations must stay backward-compatible for one release** (blue/green
  deploys run them while the previous release still serves traffic). Plain
  additions are fine in one step; removals take two (stop using it first,
  drop it in the next deploy).
- **Every id is a UUID v7** (`Vutuv.UUIDv7`) — never integer ids, never
  UUID v4, never `Ecto.UUID.generate/0`.
- **All email goes through `Vutuv.Notifications.Emailer`** (`base_email/0` +
  `deliver/1`); regression tests fail the build on bypasses.
- Public pages have Markdown/text/JSON/XML siblings built from one doc map
  (`VutuvWeb.AgentDocs`). If you change what a public HTML page shows,
  update its doc builder too — a drift test will remind you.

## Working on the API

The third-party API lives at `/api/2.0`; its documentation is written in
Markdown under [`priv/dev_docs/`](priv/dev_docs/) and served at
[/developers](https://vutuv.de/developers). Doc changes are just Markdown
edits — please keep the curl examples runnable.

## Reporting problems

Open a [GitHub issue](https://github.com/wintermeyer/vutuv/issues) with steps
to reproduce, or — for anything security-sensitive — follow
[SECURITY.md](SECURITY.md) instead of a public issue.
