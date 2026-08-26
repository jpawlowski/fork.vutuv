defmodule Vutuv.Posts.PostScreenshot do
  @moduledoc """
  A post's auto-generated **link preview** — both the durable queue job and,
  once captured, the attachment record. Created for a post that carries a single
  URL and no image (see `Vutuv.Posts.Screenshots`).

  **One card, two sources for its picture.** `source` says where the image came
  from: `"open_graph"` is the artwork the linked page publishes about itself
  (`Vutuv.OpenGraph`), `"screenshot"` a headless-Chromium photograph of the page.
  Both store it in `screenshot` through the same uploader, so everything
  downstream — storage, moderation, retries, dismissal, the admin views — is
  shared, and both render as the same card.

  What decides the **shape** is `card?/1` — whether there are words to put in
  one — and not `source`. A page's `og:title` is the headline where it has one
  and its `<title>` otherwise; the teaser is its `og:description` or, failing
  that, `summary`. Only a page that answered nothing at all keeps the old bare
  float. A reader cannot see which source a picture came from, so letting that
  pick the layout made two posts linking two ordinary pages look like two
  different features (issue #1706).

  **Three owners, one queue.** A row belongs to exactly one of a member's post
  (`post_id`), a cached fediverse post from a followed account
  (`remote_post_id`, `Vutuv.Fediverse.RemotePost`), or the composer draft the
  post is still being written in (`post_draft_id`, `Vutuv.Posts.PostDraft`) — a
  DB check constraint enforces the exactly-one. Everything downstream (worker,
  capture, YouTube thumbnail, retries, AI moderation, admin views) is shared;
  only the enqueue trigger and the "who is told when it's ready" differ.

  The draft owner is what makes the preview visible **before** the post exists
  (issue #1714). On publish the row's owner flips from the draft to the post
  (`Vutuv.Posts.Screenshots.adopt_draft/2`) — the row keeps its id, so the
  stored files stay where they are and the AI scan is not run a second time on
  the same bytes.

  The row is the queue: a `pending`/`capturing`/`failed` row is work the
  `Vutuv.Posts.ScreenshotWorker` drains, so a restart or re-deploy loses
  nothing; a `ready` row carries the stored screenshot. A `dismissed` row is the
  author's tombstone — they removed a bad auto-screenshot (a cookie-banner-covered
  capture, say) from the post edit page (`Vutuv.Posts.Screenshots.dismiss/1`): it
  renders nothing, the worker skips it, and a plain re-save of the same URL never
  re-captures it. All fields are set programmatically by the context (never cast
  from member params), so there is no public form changeset — state transitions go
  through `Ecto.Changeset.change/2` in `Vutuv.Posts.Screenshots`.

  The stored file is served exactly like a profile link's screenshot: this row
  is the `Vutuv.Screenshot` scope (it has `.id` + `.screenshot`), so
  `Vutuv.Screenshot.url({ps.screenshot, ps}, :thumb)` yields the 400×264 AVIF
  thumb with the `/images/screenshot.png` fallback.
  """

  use VutuvWeb, :model

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.OpenGraph

  @statuses ~w(pending capturing ready failed dismissed)
  # Where the card's PICTURE came from — never what it looks like, which
  # `card?/1` decides. `youtube` is the publisher's own artwork like
  # `open_graph`, but fetched from the oEmbed endpoint rather than read off the
  # page, because a watch page answers a consent redirect often enough that
  # capturing it is pointless.
  @sources ~w(screenshot open_graph youtube)

  schema "post_screenshots" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:post_draft, Vutuv.Posts.PostDraft)

    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:source, :string, default: "screenshot")

    # What the linked page says about itself, on a row of either source: read by
    # `Vutuv.OpenGraph`, which caps each value on ingest. `title` falls back to
    # the `<title>` element, so a page with no meta tags at all still has a
    # headline; `description` and `site_name` are Open Graph only, and `nil`
    # where the page declares neither. The columns are `text` because a remote
    # page's metadata is not ours to bound.
    field(:title, :string)
    field(:description, :string)
    field(:site_name, :string)
    field(:screenshot, :string)

    # One sentence saying what the linked page is about (`Vutuv.LinkSummary`,
    # issue #1709) — the card's teaser where the page published no
    # `og:description` of its own (`teaser/1`). Written by a local model off the
    # whole page and `nil` whenever that did not happen: the installation does
    # not summarise links (off by default), the page answered nothing readable,
    # the model was not reachable. Never cast from member params; nothing
    # user-facing writes it.
    #
    # Its length cap lives in `LinkSummary.max_chars/0` and nowhere else. Unlike
    # the three columns above it, this one never passes through
    # `result_changeset/2` — `Screenshots.write_summary/2` writes it by id with
    # `update_all`, deliberately, so a row that vanished during the model call
    # is a no-op rather than a raise — so a `validate_length` here would read as
    # a guarantee and enforce nothing.
    field(:summary, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)
    field(:captured_at, :utc_datetime)

    # AI image moderation state (Vutuv.Moderation.ImageScans): a captured
    # screenshot is held back ("pending") until the scan releases it.
    field(:moderation, :string)

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  Whether this preview has **words** — a headline — and so renders as a card
  rather than as a bare floated capture. The one question the render path asks,
  because the two are laid out differently: a card carries text and gets the
  full width below the post, a bare capture floats beside it.

  Deliberately **not** "did the page publish Open Graph". Where the picture came
  from is invisible to a reader, and making it decide the shape produced two
  unrelated renderings of the same act — a member posts a link, and whether they
  get a card depended on whether a stranger had maintained their meta tags. The
  picture is the publisher's artwork when they offer one and our capture when
  they do not; `source` records which, and the card looks the same either way.

  Matches on the `title` **column**, never on a preloaded association: a row
  that got no headline at all has nothing card-shaped to show and keeps the
  float.
  """
  def card?(%__MODULE__{title: title}) when is_binary(title), do: true
  def card?(%__MODULE__{}), do: false
  def card?(nil), do: false

  @doc """
  The card's teaser: the publisher's own `og:description` where there is one,
  otherwise the sentence `Vutuv.LinkSummary` wrote about the page (issue
  #1709), otherwise `nil`.

  That order is the whole division of labour between the two, in one place: the
  publisher's blurb is written by someone who knows the page, our summary is a
  stand-in for when nobody wrote one. `Vutuv.Posts.Screenshots.summarize/2`
  never asks the model when a description is already there, so in practice at
  most one of the two columns is filled — this stays an ordering rather than a
  race.
  """
  def teaser(%__MODULE__{description: description}) when is_binary(description), do: description
  def teaser(%__MODULE__{summary: summary}) when is_binary(summary), do: summary
  def teaser(%__MODULE__{}), do: nil

  # Every column that describes the linked PAGE rather than the job. Named once
  # because four places need the same list and they had already drifted: the
  # refresh reset cleared `summary`, the dismiss reset did not, so a tombstone
  # kept the previous page's sentence — which since `teaser/1` renders it would
  # have put one page's description under another page's headline. A fifth card
  # column later is one edit here, not four across two modules.
  @card_fields [:source, :title, :description, :site_name, :summary]

  @doc """
  The card columns a capture result may write; `no_card/0` clears them.

  Called `card_columns` and not `card_fields` because
  `Vutuv.Posts.Screenshots.card_fields/2` already means something else in the
  same call chain — a map of card *values* built from a page's metadata — and
  the two sat four lines apart there.
  """
  def card_columns, do: @card_fields

  @doc """
  The card half of a row, blanked: no words, and `source` back to the plain
  capture default. What a refresh writes (the row is about to describe a
  different page) and what a dismissal writes (there is no card any more).
  """
  @no_card @card_fields |> Map.from_keys(nil) |> Map.put(:source, "screenshot")

  def no_card, do: @no_card

  @doc """
  Whether the author said no to this preview — the tombstone the composer's
  **No preview** button and the edit page's Remove button both write.

  Beside `card?/1` and `ready?/1` for the same reason those exist: the literal
  `"dismissed"` is a state of this schema, and the render path asking for it by
  string is the copy that gets missed when the status is ever renamed.
  """
  def dismissed?(%__MODULE__{status: "dismissed"}), do: true
  def dismissed?(%__MODULE__{}), do: false
  def dismissed?(nil), do: false

  @doc """
  Whether a captured screenshot is ready to render — captured **and**
  released by the AI image scan (a captured-but-unreleased screenshot shows
  to nobody, exactly like an uncaptured one).
  """
  def ready?(%__MODULE__{status: "ready", screenshot: screenshot, moderation: moderation})
      when is_binary(screenshot),
      do: ImageScans.released?(moderation)

  def ready?(%__MODULE__{}), do: false

  @doc """
  The enqueue changeset for a new/refreshed job — the URL and a `pending` reset.
  `url` is a bare `http(s)` string extracted from the post body (`text` column,
  but capped so a pathological URL can't blow past a sane length).

  A refresh also clears **every** word on the row and puts `source` back to
  `screenshot`: it is about to describe a **different page**, and a stale
  headline surviving beside the new page's image would be the worst of both.
  `summary` belongs in that reset for exactly the same reason the other three
  do — it is a sentence about the old page, and since it now renders inside the
  card (`teaser/1`) rather than in a hover tooltip, leaving it behind would put
  one page's description under another page's headline.
  """
  def enqueue_changeset(post_screenshot, url) do
    post_screenshot
    |> cast(%{url: url, status: "pending"}, [:url, :status])
    |> validate_required([:url])
    |> validate_length(:url, max: 2000)
    |> validate_inclusion(:status, @statuses)
    |> change(no_card())
  end

  @doc """
  The changeset stamping a finished capture's kind and metadata. The length
  validations read the ingest caps from `Vutuv.OpenGraph` rather than repeating
  the numbers — the columns are `text`, so these bound what a card may *show*,
  and if the two sides ever drifted this changeset would go invalid inside
  `mark_ready/2`, whose `{:ok, _} = Repo.update()` would raise and leave the job
  `capturing` for `resume_stuck/0` to hand back **without** counting an
  attempt: an unbounded retry loop rather than a failed job.
  """
  def result_changeset(post_screenshot, attrs) do
    post_screenshot
    |> cast(attrs, @card_fields)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:title, max: OpenGraph.max_title())
    |> validate_length(:description, max: OpenGraph.max_description())
    |> validate_length(:site_name, max: OpenGraph.max_site_name())
  end
end
