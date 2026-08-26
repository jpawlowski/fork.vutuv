defmodule Vutuv.Posts.PostScreenshot do
  @moduledoc """
  A post's auto-generated **link preview** — both the durable queue job and,
  once captured, the attachment record. Created for a post that carries a single
  URL and no image (see `Vutuv.Posts.Screenshots`).

  **Two kinds of preview, one row.** `source` says which: `"open_graph"` is the
  preview the linked page publishes about itself (`Vutuv.OpenGraph` — the
  publisher's own `title`, `description`, `site_name` and image, rendered as a
  card below the post), `"screenshot"` a headless-Chromium photograph of the
  page (the fallback, floated beside the text). Both store their image in
  `screenshot` through the same uploader, so everything downstream — storage,
  moderation, retries, dismissal, the admin views — is shared.

  **Two owners, one queue.** A row belongs to exactly one of a member's post
  (`post_id`) or a cached fediverse post from a followed account
  (`remote_post_id`, `Vutuv.Fediverse.RemotePost`) — a DB check constraint
  enforces the exactly-one. Everything downstream (worker, capture, YouTube
  thumbnail, retries, AI moderation, admin views) is shared; only the enqueue
  trigger and the "who is told when it's ready" differ per owner.

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
  @sources ~w(screenshot open_graph)

  schema "post_screenshots" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:source, :string, default: "screenshot")

    # The linked page's own Open Graph preview, `nil` on a screenshot row. Read
    # from the page by `Vutuv.OpenGraph`, which caps each value on ingest; the
    # columns are `text` because a remote page's metadata is not ours to bound.
    field(:title, :string)
    field(:description, :string)
    field(:site_name, :string)
    field(:screenshot, :string)
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
  Whether this preview is the page's **own** card (Open Graph) rather than a
  capture of it — the one question the render path asks, because the two are
  laid out differently: a card carries text and gets the full width below the
  post, a bare screenshot floats beside it.

  Matches on the `source` **column** and the presence of a title, never on a
  preloaded association or on "does it happen to have a description": a row
  that says `open_graph` but never got a headline has nothing card-shaped to
  show.
  """
  def card?(%__MODULE__{source: "open_graph", title: title}) when is_binary(title), do: true
  def card?(%__MODULE__{}), do: false
  def card?(nil), do: false

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

  A refresh also clears the card fields and puts `source` back to `screenshot`:
  the row is about to describe a **different page**, and a stale headline
  surviving beside the new page's image would be the worst of both.
  """
  def enqueue_changeset(post_screenshot, url) do
    post_screenshot
    |> cast(%{url: url, status: "pending"}, [:url, :status])
    |> validate_required([:url])
    |> validate_length(:url, max: 2000)
    |> validate_inclusion(:status, @statuses)
    |> change(%{source: "screenshot", title: nil, description: nil, site_name: nil})
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
    |> cast(attrs, [:source, :title, :description, :site_name])
    |> validate_inclusion(:source, @sources)
    |> validate_length(:title, max: OpenGraph.max_title())
    |> validate_length(:description, max: OpenGraph.max_description())
    |> validate_length(:site_name, max: OpenGraph.max_site_name())
  end
end
