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

Pull requests are opened against this repository, so `upstream` — not your
fork — is what you branch from. Set that up once after cloning:

```bash
git remote add upstream https://github.com/wintermeyer/vutuv.git
git remote set-url --push upstream DISABLED   # a stray push must not aim here
git fetch upstream
gh repo set-default wintermeyer/vutuv         # gh pr create / merge target this repo
```

Then branch from and rebase onto `upstream/main`. Push only to `origin`; keep
your fork's `main` a mirror with
`gh repo sync <you>/vutuv --source wintermeyer/vutuv --branch main` and never
commit to it.

## Ground rules

- **Start every feature or bugfix with a test** that covers it, then make it
  pass.
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
- **Optional: let the title say what reviewing costs.** With twenty open pull
  requests a list gives no reading order, and the one number GitHub shows
  misleads — a change can list `+2878` with 1820 of those lines in
  `priv/gettext/`. If you want to help with that, use
  [Conventional Commits](https://www.conventionalcommits.org/) and put a
  bracket at the end. Start the description lowercase and end it without a full
  stop — that is what the standard's usual linter checks, and a sentence-cased
  subject fails it out of the box. Names keep their own case (`iOS`,
  `QuoteRequest`, `Vutuv.EtsCache`), and in a German subject line the nouns stay
  capitalised; only the first word changes.

  ```
  fix(ui): make the sticky top bar actually stick [2m]
  fix(mobile): stop iOS zooming the page in when a form field is focused [2m]
  feat(fediverse): advertise a quote policy and answer QuoteRequest [15m ?]
  feat(carddav): an address book that reaches the phone [60m+ ?]
  ```

  The minutes are the **code you would actually read**, over 100 — leave out
  whatever is machine-checkable or merely follows the change: generated files,
  lockfiles, translations, tests, documentation. Double it for authentication
  and authorization, database migrations, long-lived processes and state,
  visibility or permission rules, and delivery to foreign systems. They rank
  pull requests against each other and promise nothing about anyone's clock.
  `?` marks a change that needs a product decision rather than a code review;
  `after #N` a real code or schema dependency, not a shared file. Leave the
  bracket off when you would rather not guess — a title without one is fine,
  and no reviewer is obliged to read it.

  The scope in parentheses is the subsystem, and `docs/architecture/*.md`
  already names most of them: `fediverse`, `feed`, `posts`, `profiles`,
  `messages`, `images`, `search`, `moderation`, `mentions`, `api`. For what has
  no chapter, use a plain name — `ui`, `mobile`, `desktop`, `pwa`, `push`,
  `seo`, `carddav`, `core`, `build`. Two things decide which one:

  - **Name what the change touches, not the topic around it.** A quote-post
    feature that touches neither `fediverse.ex` nor `docs.ex` is `posts`, not
    `fediverse` — otherwise the reviewer opens a file the diff never reaches.
  - **Say what the description does not.** `feat(organizations): Organization
    pages preview as themselves` wastes the slot; `feat(seo):` names the
    surface instead, which is the part the sentence is missing.

  `ui` is usually too coarse. Whether a reviewer needs a phone in hand changes
  the work, so anything on the bottom bar, on touch gestures or in iOS is
  `mobile`, and `ui` is left for chrome that looks the same either way.

  The bracket is review metadata, so whoever merges may drop it from the squash
  subject — `gh pr merge --squash -t "…"` takes the subject you give it. Nothing
  depends on that: it reads fine if it stays, and it does not vanish on its own,
  because a squash only uses a lone commit's own subject and a long-lived pull
  request always ends up carrying a merge commit.

## Working on the API

The third-party API lives at `/api/2.0`; its documentation is written in
Markdown under [`priv/dev_docs/`](priv/dev_docs/) and served at
[/developers](https://vutuv.de/developers). Doc changes are just Markdown
edits — please keep the curl examples runnable.

## Reporting problems

Open a [GitHub issue](https://github.com/wintermeyer/vutuv/issues) with steps
to reproduce, or — for anything security-sensitive — follow
[SECURITY.md](SECURITY.md) instead of a public issue.
