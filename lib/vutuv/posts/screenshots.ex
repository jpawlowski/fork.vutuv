defmodule Vutuv.Posts.Screenshots do
  @moduledoc """
  The post **link-preview** subsystem: when a post carries a single URL and no
  image, build a preview of that page off the request path and store it as an
  attachment shown with the post.

  **The page's own preview comes first.** Most sites publish one — Open Graph's
  `og:title` / `og:description` / `og:image` — and it beats a photograph of the
  page every time: it is the headline the publisher chose, it is not covered by
  a cookie dialog, and it costs one small GET instead of a Chromium run.
  `Vutuv.OpenGraph` reads it, the image is fetched and stored server-side like
  any capture (readers never talk to the linked host), and the row is marked
  `source: "open_graph"` so the render path lays it out as a **card** rather
  than a floated thumbnail. A page that publishes nothing usable falls straight
  through to the screenshot below, so no link is worse off than before.

  **Durable queue.** Each qualifying post gets one `post_screenshots` row (see
  `Vutuv.Posts.PostScreenshot`), which is both the job and the result: a
  `pending` row is work waiting, `capturing` is in flight, `ready` carries the
  stored screenshot, `failed` gave up (retries exhausted, or a permanent refusal:
  an SSRF-blocked host, a redirecting link, or a non-200 target — only a plain
  HTTP 200 is captured). Because the queue is a table, a restart or re-deploy
  loses nothing —
  `Vutuv.Posts.ScreenshotWorker` drains it on a poll, `resume_stuck/0` re-queues
  a job a crash left mid-capture, and a transient failure retries with
  exponential backoff. This is the "re-create if in doubt" guarantee.

  **DRY.** Capture + browser frame + SSRF guard are `Vutuv.PageScreenshot`
  (shared with profile links); storage/URL/delete are `Vutuv.Screenshot` (this
  row is the scope, exactly like a `Url`), so the stored file is the same
  400×264 AVIF thumb with the `/images/screenshot.png` fallback. The capture is
  gated by the `:generate_screenshots` flag (intranet installs run air-gapped).

  **YouTube links don't screenshot.** A watch page always answers with the
  cookie-consent banner, so a capture never shows the video; the worker stores
  the thumbnail YouTube publishes for every video instead, frameless
  (`Vutuv.YoutubeThumbnail`), and falls back to the ordinary capture whenever
  that fetch fails.

  **The author sees it before publishing (issue #1714).** A composer draft
  (`Vutuv.Posts.PostDraft`) owns a job of its own, so the card appears while the
  post is still being written, and the author can point it at a different link
  in the text or ask for no card at all (`choose/2`). On publish the row's owner
  flips from the draft to the post (`adopt_draft/2`) — same row, same id, so the
  stored image never moves and the AI scan is not repeated on the same bytes.

  **Which link.** The preview is for the link the author chose, defaulting to
  the **first** one in the text. It used to be "exactly one URL or nothing",
  which meant a post with two links silently got no preview at all.

  **Cached fediverse posts ride the same queue.** A followed account's post
  (`Vutuv.Fediverse.RemotePost`) qualifies by the same rule — one URL, no
  picture — plus one of its own: never behind the author's content warning /
  sensitive flag (the author closed the lid; an auto-preview would prop it
  open). Its job carries `remote_post_id` instead of `post_id`, and everything
  downstream is shared, with two per-owner differences: the ready-announcement
  (nobody is watching a remote post get captured, so no broadcast) and the AI
  scan's owner (no local member, like the remote-picture scans).
  """

  import Ecto.Query

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.LinkSummary
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.OpenGraph
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo
  alias Vutuv.ScreenshotBlocklist
  alias Vutuv.SocialFeed.Http
  alias Vutuv.YoutubeThumbnail

  require Logger

  # A bare http(s) URL, mirroring the markdown autolinker
  # (`VutuvWeb.Markdown.autolink_bare_urls/1`).
  @url_regex ~r{https?://[^\s<>]+}

  @max_attempts 5
  @batch 5
  # Reset a `capturing` job a crash orphaned after this long (the worker's
  # capture ceiling is ~40s; 10 min is comfortably past any live capture).
  @stuck_after_seconds 600
  # Admin page size — a gallery of thumbnails, so denser than the site-wide 250.
  @per_page 24

  @doc "Retry cap before a transient failure is marked permanently `failed`."
  def max_attempts, do: @max_attempts

  @doc "Admin queue/gallery page size."
  def per_page, do: @per_page

  # The on-page display size of the stored thumb (the AVIF is 2× this, see
  # `Vutuv.Uploads.Spec` `:screenshot`); mirrors the profile-links recipe.
  @display_width 400
  @display_height 264

  ## Detection + enqueue

  @doc """
  Reconciles a post's screenshot job with what the post now is. Enqueues a
  `pending` job when the post carries exactly one URL and no image (refreshing
  the URL if it changed); removes the job (and its files) when the post no
  longer qualifies. Called after every create/update; idempotent. Takes a
  member's `Post` or a cached fediverse `RemotePost` — both own the same job
  row, keyed by their own foreign key.
  """
  def reconcile(%Post{} = post) do
    # force: the caller's struct may carry a stale `:screenshot` (nil from create
    # time) even after a prior reconcile inserted the row — reload it so a second
    # reconcile updates the row instead of colliding on the unique post_id.
    post
    |> Repo.preload([:images, :screenshot], force: true)
    |> reconcile_loaded()
  end

  def reconcile(%RemotePost{} = post) do
    post
    |> Repo.preload([:images, :screenshot], force: true)
    |> reconcile_loaded()
  end

  def reconcile(%PostDraft{} = draft) do
    draft
    |> Repo.preload(:screenshot, force: true)
    |> reconcile_loaded()
  end

  defp reconcile_loaded(owner) do
    case chosen_url_for(owner) do
      {:ok, url} -> enqueue(owner, url)
      :none -> cancel(owner)
    end
  end

  @doc """
  The link this owner's preview is for: the one already chosen, as long as it is
  still in the text, else the first one there — or `:none`. That single rule is
  both the default ("the first link") and the memory of an author's pick, so the
  choice needs no column of its own: the row already records which page it
  describes.

  `previous` is the URL on the existing row, passed in rather than read off a
  preloaded `:screenshot`. A clause matching the association would fall through
  for a caller that forgot the preload and **silently** re-point the preview at
  the first link, which is exactly the failure the "match on a column" rule is
  about.
  """
  def chosen_url(owner, previous \\ nil) do
    case candidate_urls(owner) do
      [] -> :none
      urls -> {:ok, if(previous in urls, do: previous, else: hd(urls))}
    end
  end

  defp chosen_url_for(%{screenshot: screenshot} = owner)
       when not is_struct(screenshot, Ecto.Association.NotLoaded),
       do: chosen_url(owner, screenshot && screenshot.url)

  # This installation's own login-walled / internal areas: a screenshot of them
  # would only ever be a login redirect or an admin/internal page, never useful
  # preview content, so a single-URL post pointing at one is not screenshotted.
  # These path roots are all reserved slugs (`Vutuv.Accounts.ReservedSlugs`).
  @internal_path_roots ~w(/settings /admin /system)

  @doc """
  Every link in this owner's text that a preview could be built for, in the
  order they appear — the list the author picks from, and whose **first** entry
  is the default. Empty when the owner carries an image attachment (a post that
  already shows pictures does not also get a link card).

  A URL pointing at this installation's own `/settings`, `/admin` or `/system`
  area, or at a blocklisted page (`Vutuv.ScreenshotBlocklist.blocked?/1`, e.g.
  `heise.de`), is left out — a blocklisted page never previews, so no job is
  even enqueued and the post simply shows its link.

  A cached fediverse post plays by the same rules plus one of its own: a post
  its author put behind a content warning (or flagged sensitive) offers nothing
  — the card renders it as a closed lid, and an auto-fetched preview image
  would prop that lid open.
  """
  def candidate_urls(%Post{images: [], body: body}), do: previewable_urls(body)
  def candidate_urls(%Post{images: images}) when is_list(images), do: []

  def candidate_urls(%RemotePost{images: [], content_text: text} = post) do
    if RemotePost.warned?(post), do: [], else: previewable_urls(text)
  end

  def candidate_urls(%RemotePost{images: images}) when is_list(images), do: []

  # A draft's images live in `image_ids` (the rows are still unattached), so the
  # "no picture" rule reads that list rather than an association.
  def candidate_urls(%PostDraft{image_ids: [_first | _rest]}), do: []
  def candidate_urls(%PostDraft{body: body}), do: previewable_urls(body)

  defp previewable_urls(body) do
    body
    |> extract_urls()
    |> Enum.reject(&(own_internal_url?(&1) or ScreenshotBlocklist.blocked?(&1)))
  end

  @doc "Every distinct bare `http(s)` URL in `body`, trailing punctuation trimmed."
  def extract_urls(body) when is_binary(body) do
    @url_regex
    |> Regex.scan(body)
    |> Enum.map(fn [url | _] -> trim_trailing_punctuation(url) end)
    |> Enum.uniq()
  end

  def extract_urls(_body), do: []

  # A URL at the end of a sentence catches the following `.`/`)`/`,` in the
  # greedy `[^\s<>]+`; drop those so the captured target is the real link.
  defp trim_trailing_punctuation(url), do: String.replace(url, ~r/[)\]}.,;:!?'"]+$/u, "")

  # True when `url` points at this installation's own `/settings`, `/admin` or
  # `/system` area. `Fediverse.local_host?/1` is the one "is this us" test
  # (endpoint-derived host, `www.` and case folded), so the skip is correct on
  # any third-party installation.
  defp own_internal_url?(url) do
    uri = URI.parse(url)
    Fediverse.local_host?(uri.host) and internal_path?(uri.path)
  end

  defp internal_path?(nil), do: false

  defp internal_path?(path) do
    Enum.any?(@internal_path_roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  # The refresh/keep clauses match on the preloaded `:screenshot` alone, so
  # they serve both owners; only a fresh insert needs to know whose key to set.
  defp enqueue(%{screenshot: %PostScreenshot{url: url} = existing}, url) do
    # Same URL already queued/captured: leave it (a `ready` row stays ready).
    {:ok, existing}
  end

  defp enqueue(%{screenshot: %PostScreenshot{} = existing}, url) do
    # The chosen URL changed: re-fetch. The stored file is replaced in place.
    refresh(existing, url)
  end

  defp enqueue(%Post{id: post_id, screenshot: nil}, url) do
    %PostScreenshot{post_id: post_id}
    |> PostScreenshot.enqueue_changeset(url)
    |> Repo.insert()
  end

  defp enqueue(%RemotePost{id: remote_post_id, screenshot: nil}, url) do
    %PostScreenshot{remote_post_id: remote_post_id}
    |> PostScreenshot.enqueue_changeset(url)
    |> Repo.insert()
  end

  defp enqueue(%PostDraft{id: draft_id, screenshot: nil}, url) do
    %PostScreenshot{post_draft_id: draft_id}
    |> PostScreenshot.enqueue_changeset(url)
    |> Repo.insert()
  end

  # Point an existing row at `url` with a clean slate: pending, no attempts, no
  # backoff, no error, and (through `enqueue_changeset/2`) no card left over
  # from the page it used to describe.
  defp refresh(%PostScreenshot{} = existing, url) do
    existing
    |> PostScreenshot.enqueue_changeset(url)
    |> Ecto.Changeset.change(attempts: 0, next_attempt_at: nil, last_error: nil)
    |> Repo.update()
  end

  # No longer qualifies: drop the row and its files (the render path already
  # ignores it once the post has images, but keeping the row/file would leak).
  # Unlike post deletion, nothing cascades here, so delete the row explicitly.
  defp cancel(%{screenshot: nil}), do: :ok

  defp cancel(%{screenshot: %PostScreenshot{} = existing}) do
    Repo.delete(existing)
    delete(existing)
    :ok
  end

  @doc """
  Deletes a screenshot's stored files. The DB row is left to the caller — on
  post deletion it cascades with the post (`Vutuv.Posts.delete_post/1`); on
  reconcile-cancel `cancel/1` deletes the row itself.
  """
  def delete(%PostScreenshot{} = post_screenshot) do
    Vutuv.Screenshot.delete(post_screenshot)
  end

  @doc """
  Deletes the stored screenshot files of cached fediverse posts that are about
  to be deleted. Called from the one media-wipe chokepoint every cached-post
  deletion goes through (`Vutuv.Fediverse`), so an upstream `Delete`, a report,
  a narrowing edit, the retention sweep and an instance block all shed the
  files; the rows themselves cascade with the `fediverse_posts` foreign key.
  """
  def delete_for_remote_posts(remote_post_ids) when is_list(remote_post_ids) do
    from(ps in PostScreenshot, where: ps.remote_post_id in ^remote_post_ids)
    |> Repo.all()
    |> Enum.each(&delete/1)
  end

  @doc """
  The same for composer drafts that are about to go (published, discarded, or
  swept). The rows cascade with `post_drafts`; the stored files never do, so a
  draft nobody finished would otherwise leave its preview image on disk forever.
  A published draft has already handed its row to the post (`adopt_draft/2`),
  so nothing here matches it.
  """
  def delete_for_drafts(draft_ids) when is_list(draft_ids) do
    from(ps in PostScreenshot, where: ps.post_draft_id in ^draft_ids)
    |> Repo.all()
    |> Enum.each(&delete/1)
  end

  @doc """
  The author's "this screenshot is bad, remove it" action from the post edit
  page (a capture spoiled by a cookie banner, say). Purges the stored files and
  tombstones the row as `dismissed`: the render path shows nothing but a `ready`
  row, `list_due/1` only picks up `pending` rows, and `enqueue/2` leaves an
  existing row for the same URL untouched — so a plain re-save never re-captures
  it. Changing the post's single URL still re-captures (a different page is a
  new screenshot), and dropping the link cancels the row entirely, both via
  `reconcile/1`.
  """
  def dismiss(%PostScreenshot{} = post_screenshot) do
    delete(post_screenshot)

    post_screenshot
    |> Ecto.Changeset.change(
      Map.merge(PostScreenshot.no_card(), %{
        status: "dismissed",
        screenshot: nil,
        width: nil,
        height: nil,
        captured_at: nil,
        last_error: nil,
        moderation: nil
      })
    )
    |> Repo.update()
  end

  @doc """
  The author's pick in the composer: which of the links in their text the card
  is for, or `:none` for no card at all.

  `url` must be one of `candidate_urls/1` — anything else is refused rather than
  fetched, because this arrives from the browser and "preview this address"
  would otherwise be a request the member's own server makes on a stranger's
  say-so. `:none` leaves the author's `dismissed` tombstone behind, which is the
  same "they said no" the edit page's Remove button writes, so there is one
  answer to that question and not two.
  """
  def choose(%PostDraft{} = draft, :none) do
    draft = Repo.preload(draft, :screenshot, force: true)

    case draft.screenshot do
      %PostScreenshot{} = existing -> dismiss(existing)
      nil -> dismiss_default(draft)
    end
  end

  def choose(%PostDraft{} = draft, url) when is_binary(url) do
    draft = Repo.preload(draft, :screenshot, force: true)

    cond do
      url not in candidate_urls(draft) ->
        {:error, :not_a_candidate}

      # Choosing a link the author had already said no to has to lift the
      # tombstone; `enqueue/2`'s "same URL, leave it" clause would not, and the
      # control would do nothing.
      PostScreenshot.dismissed?(draft.screenshot) ->
        refresh(draft.screenshot, url)

      true ->
        enqueue(draft, url)
    end
  end

  # Nothing has been fetched yet, but the answer still has to survive the next
  # reconcile — so the tombstone is written against the link the preview would
  # otherwise have been for.
  defp dismiss_default(draft) do
    with {:ok, url} <- chosen_url(draft),
         {:ok, job} <- enqueue(draft, url) do
      dismiss(job)
    else
      _nothing_to_refuse -> {:ok, nil}
    end
  end

  @doc """
  Hands the draft's preview to the post that was just published from it: the
  row's owner flips, nothing else moves.

  Deliberately not "copy the metadata across": the row keeps its id, so the
  stored image stays exactly where it is, the AI verdict on those bytes still
  applies, and an author who dismissed the card in the composer keeps a
  dismissed card. `Vutuv.Posts.create_post/2` has already reconciled a fresh
  `pending` row onto the post by the time this runs, so that one is dropped
  first — it is seconds old and owns no files.

  A no-op when the draft never had a preview.
  """
  def adopt_draft(%PostDraft{} = draft, %Post{} = post) do
    case Repo.preload(draft, :screenshot, force: true).screenshot do
      nil ->
        :ok

      %PostScreenshot{} = row ->
        {:ok, adopted} =
          Repo.transaction(fn ->
            # `cancel/1` is the existing "retire this row and its files".
            post |> Repo.preload(:screenshot, force: true) |> cancel()

            row
            |> Ecto.Changeset.change(post_id: post.id, post_draft_id: nil)
            |> Repo.update!()
          end)

        # The submitted body is the truth and the draft is only written on a
        # debounce, so a member who changed the link and pressed Post inside
        # that window would otherwise publish a preview for a URL their text no
        # longer carries. One reconcile settles it: the same URL is left alone,
        # a changed one re-fetches, a removed one takes the row with it.
        adopted = post |> Repo.preload(:screenshot, force: true) |> reconcile_kept(adopted)

        if adopted && PostScreenshot.ready?(adopted), do: announce_ready(adopted)
        :ok
    end
  end

  # Reconcile the freshly adopted row against the post that now owns it, and
  # answer with the row if it survived.
  defp reconcile_kept(post, adopted) do
    case reconcile_loaded(post) do
      {:ok, %PostScreenshot{} = kept} -> kept
      _dropped -> if Repo.get(PostScreenshot, adopted.id), do: adopted
    end
  end

  @doc """
  Puts a job that gave up back in the queue: `pending`/`capturing`/`failed` →
  `pending` with a clean slate (attempts reset, backoff and last error cleared),
  so the next drain picks it up. An author-`dismissed` tombstone and a `ready`
  row are refused with `{:error, :not_requeueable}` — dismissing is the author's
  decision, and a ready row is not work.

  Nothing else revives a `failed` row: the retry cap is final, so a job that
  burned its attempts while capture itself was broken (a hanging page that
  Chromium never bounded, say) would stay dead forever once the environment
  recovered. This is the admin's hand-back, from `/admin/screenshots`.
  """
  def requeue(%PostScreenshot{status: status} = job)
      when status in ~w(pending capturing failed) do
    job
    |> Ecto.Changeset.change(
      status: "pending",
      attempts: 0,
      next_attempt_at: nil,
      last_error: nil
    )
    |> Repo.update()
  end

  def requeue(%PostScreenshot{}), do: {:error, :not_requeueable}

  @doc """
  Puts every finished job whose URL is a YouTube video back in the queue, so
  the worker replaces its stored capture with the video's own thumbnail
  (`Vutuv.YoutubeThumbnail`) — the one-shot backfill for captures from before
  that existed, which all show YouTube's consent banner. `ready` and `failed`
  rows alike get a clean pending slate; an author-`dismissed` tombstone stays
  dismissed (their call, and the thumbnail may be exactly what they removed).
  Returns the number re-queued. On a release, run it via
  `Vutuv.Release.requeue_youtube_screenshots/0`.
  """
  def requeue_youtube do
    from(ps in PostScreenshot, where: ps.status in ["ready", "failed"])
    |> Repo.all()
    |> Enum.filter(&match?({:ok, _id}, YoutubeThumbnail.video_id(&1.url)))
    |> Enum.map(fn job ->
      {:ok, _requeued} =
        job
        |> Ecto.Changeset.change(
          status: "pending",
          attempts: 0,
          next_attempt_at: nil,
          last_error: nil
        )
        |> Repo.update()
    end)
    |> length()
  end

  @doc """
  Drops every job — queued, ready or failed — whose URL is on the blocklist
  today, row and stored files alike, and returns how many went.

  The one-shot cleanup after an entry is added (`Vutuv.ScreenshotBlocklist`):
  such a capture is exactly the consent-banner picture the entry exists to
  prevent, and nothing would ever replace it, since `reconcile/1` only
  re-captures when a post's URL changes. Dropping the row is what `reconcile/1`
  itself does for a post that stopped qualifying, so the card falls back to
  showing the plain link. Run from a release together with the profile-link
  half:

      bin/vutuv eval "Vutuv.Release.purge_blocklisted_screenshots()"
  """
  def purge_blocklisted do
    PostScreenshot
    |> Repo.all()
    |> Enum.filter(&ScreenshotBlocklist.blocked?(&1.url))
    |> Enum.map(fn job ->
      Repo.delete(job)
      delete(job)
    end)
    |> length()
  end

  @doc "Loads one job by id, raising when it is gone (the admin views' reads)."
  def get_job!(id), do: Repo.get!(PostScreenshot, id)

  ## Draining the queue

  @doc """
  Captures every due job. A no-op when `:generate_screenshots` is off (the rows
  stay `pending`), so an air-gapped install and the test suite launch no
  Chromium. `opts`: `capture:` injects the per-row capture function (tests stub
  it), `force:` runs even with the flag off, `limit:` caps the batch.
  """
  def deliver_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or
         Application.get_env(:vutuv, :generate_screenshots, true) do
      resume_stuck()
      capture = Keyword.get(opts, :capture, &capture_and_store/1)
      for job <- list_due(opts), do: process(job, capture)
    end

    :ok
  end

  @doc "The `pending`, retry-due jobs the next drain would pick up, oldest first."
  def list_due(opts \\ []) do
    now = DateTime.utc_now(:second)

    from(ps in PostScreenshot,
      where:
        ps.status == "pending" and ps.attempts < @max_attempts and
          (is_nil(ps.next_attempt_at) or ps.next_attempt_at <= ^now),
      order_by: [asc: ps.inserted_at],
      limit: ^Keyword.get(opts, :limit, @batch)
    )
    |> Repo.all()
  end

  @doc """
  Re-queues jobs a crash left stuck in `capturing`. Returns the count reset.
  Called on worker boot and each poll — the durability backstop.
  """
  def resume_stuck do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@stuck_after_seconds, :second)

    {count, _} =
      from(ps in PostScreenshot, where: ps.status == "capturing" and ps.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "pending", updated_at: NaiveDateTime.utc_now(:second)])

    count
  end

  defp process(%PostScreenshot{} = job, capture) do
    job = mark_capturing(job)

    case capture.(job) do
      {:ok, %{screenshot: _file} = result} ->
        # `result[:html]` is `carry_html/2`'s page; `nil` for a `capture:` stub
        # or a page that answered nothing readable, and `summarize/2` then
        # falls back to fetching for itself.
        job |> mark_ready(result) |> summarize(result[:html])

      {:error, reason} ->
        if permanent_failure?(reason),
          do: mark_failed(job, reason),
          else: mark_retry(job, reason)
    end
  end

  # A property of the target that won't change on retry: an SSRF-refused internal
  # host, a blocklisted page (`:blocklisted`, one we never shoot), a link that
  # redirects (`:redirect`), or a `4xx` non-200 answer (`{:bad_status, _}`).
  # Everything else — a `5xx` server error, an unreachable probe, a
  # missing/crashed/timed-out Chromium — is transient and retries with backoff
  # until the cap.
  defp permanent_failure?(:internal_target), do: true
  defp permanent_failure?(:blocklisted), do: true
  defp permanent_failure?(:redirect), do: true
  defp permanent_failure?({:bad_status, _status}), do: true
  defp permanent_failure?(_reason), do: false

  # The real capture, best source first. A YouTube video link stores the
  # thumbnail YouTube itself publishes (a watch-page capture only ever shows the
  # consent banner); any other page that publishes an Open Graph preview stores
  # that; everything else — and any trouble along the way — takes the Chromium
  # path, exactly as before.
  defp capture_and_store(%PostScreenshot{} = job) do
    # YouTube first, and it never reaches the metadata fetch: a watch page
    # answers a consent redirect often enough that `OpenGraph.fetch/1` would
    # spend a request to learn nothing, and the oEmbed endpoint the thumbnail
    # branch already calls carries the video's title anyway.
    with :fallback <- youtube_capture(job) do
      # Read once, use three times: which branch supplies the card's PICTURE,
      # the words that go on it either way, and the page body the summariser
      # would otherwise download all over again (`LinkSummary.summarize_html/2`
      # explains that one). `nil` when the page said nothing readable; every
      # branch takes that.
      meta =
        case OpenGraph.fetch(job.url) do
          {:ok, meta} -> meta
          :error -> nil
        end

      result =
        with :fallback <- open_graph_capture(job, meta) do
          page_capture_and_store(job, meta)
        end

      carry_html(result, meta)
    end
  end

  # On the result rather than on the row: it is a 512 KB binary that must not
  # outlive this one job, and `mark_ready/2` writes only
  # `PostScreenshot.card_columns/0`, so it never reaches the database.
  defp carry_html({:ok, result}, %{html: html}), do: {:ok, Map.put(result, :html, html)}
  defp carry_html(result, _meta), do: result

  # The Open Graph branch: `{:ok, result}` with the page's own image stored and
  # its words carried alongside, or `:fallback` — the page declared no image, or
  # that image could not be fetched or stored, and the capture branch then
  # supplies the picture for the same words.
  #
  # Note the metadata GET and `ensure_http_ok/1` below are deliberately
  # independent, so the capture path keeps its own status classification (which
  # drives the retry cap) instead of inheriting a decision made for a different
  # question.
  defp open_graph_capture(%PostScreenshot{} = job, %{image_url: image} = meta)
       when is_binary(image) do
    with {:ok, bytes, extension} <- OpenGraph.fetch_image(image),
         {:ok, result} <- store_remote_image(job, bytes, extension) do
      {:ok, Map.merge(result, card_fields("open_graph", meta))}
    else
      _other -> :fallback
    end
  end

  defp open_graph_capture(%PostScreenshot{}, _meta), do: :fallback

  # The card's words, from whichever branch got them. One function because the
  # three branches differ in where the PICTURE comes from and in nothing else —
  # writing the same keys once per branch is how the screenshot card drifted
  # away from the Open Graph one in the first place.
  #
  # A source that names no site is labelled by its host, which is what a reader
  # is checking anyway ("where does this go?").
  #
  # Read with `meta[...]` rather than `meta.title`: a source that has nothing to
  # say about a field should be able to leave the key out, instead of writing
  # `description: nil` into its own map to satisfy this function's access — which
  # is a card decision, and this is the only place that gets to make one.
  defp card_fields(source, %{} = meta) do
    %{
      source: source,
      title: meta[:title],
      description: meta[:description],
      site_name: meta[:site_name] || meta[:host]
    }
  end

  defp card_fields(source, nil), do: %{source: source}

  # The YouTube branch: `{:ok, result}` with the stored thumbnail **and the
  # video's own words**, or `:fallback` — not a YouTube video URL, a video
  # oEmbed doesn't know (deleted, private), fetch or store trouble — and the
  # caller then captures the page like any other link.
  #
  # The words matter as much as the picture here. This branch used to return
  # the thumbnail alone, so `mark_ready/2` merged `no_card/0` over it and a
  # YouTube link — the most-shared link kind on the site — was the one kind
  # that rendered as a bare float while every other link rendered as a card.
  # Which branch happened to run first was deciding the layout, and that is
  # exactly the thing `PostScreenshot.card?/1` exists to stop deciding.
  defp youtube_capture(%PostScreenshot{} = job) do
    with {:ok, video_id} <- YoutubeThumbnail.video_id(job.url),
         {:ok, bytes, meta} <- YoutubeThumbnail.fetch(video_id),
         {:ok, result} <- store_remote_image(job, bytes, ".jpg") do
      {:ok, Map.merge(result, card_fields("youtube", meta))}
    else
      _other -> :fallback
    end
  end

  # Stored raw — no browser frame: an image the publisher handed us is their
  # artwork, not a captured web page, so browser chrome around it would be a
  # lie. Shared by the YouTube thumbnail and the Open Graph image.
  defp store_remote_image(%PostScreenshot{} = job, bytes, extension) do
    tmp = Path.join(System.tmp_dir!(), "link_preview_#{job.id}#{extension}")

    try do
      File.write!(tmp, bytes)
      upload = %Plug.Upload{filename: "#{job.id}#{extension}", path: tmp}

      case Vutuv.Screenshot.store({upload, job}) do
        {:ok, file_name} ->
          {:ok, %{screenshot: file_name, width: @display_width, height: @display_height}}

        {:error, _reason} ->
          :fallback
      end
    after
      File.rm(tmp)
    end
  end

  # The classic capture: capture only a plain HTTP-200 link, then reuse the
  # shared pipeline and store through the same uploader profile links use.
  # Returns the stored filename + display size.
  defp page_capture_and_store(%PostScreenshot{} = job, meta) do
    with :ok <- ensure_http_ok(job.url),
         {:ok, framed_path} <- Vutuv.PageScreenshot.capture_framed(job.url, job.id) do
      upload = %Plug.Upload{
        content_type: "image/webp",
        filename: "#{job.id}.webp",
        path: framed_path
      }

      result =
        case Vutuv.Screenshot.store({upload, job}) do
          {:ok, file_name} ->
            {:ok,
             Map.merge(
               %{screenshot: file_name, width: @display_width, height: @display_height},
               card_fields("screenshot", meta)
             )}

          {:error, reason} ->
            {:error, reason}
        end

      File.rm(framed_path)
      result
    end
  end

  # Config key for the probe's Req options; tests inject a `plug:` through it,
  # exactly like the social-feed clients' per-provider seams.
  @probe_req_options_key :post_screenshot_req_options

  @doc """
  `:ok` only when `url` answers a plain **HTTP 200**; otherwise `{:error, reason}`
  and no screenshot is taken. A `redirect: false` GET probe (what a browser would
  get) runs in the worker before Chromium, so a link that redirects, 404s or gives
  any other non-200 answer is skipped — a bounce lands on a login/consent wall or
  a shortener's target, a 404/5xx isn't the linked page — leaving the post to show
  the plain link. Off the request path, so the probe never slows a save.

  Reasons distinguish permanent from transient (for the retry cap): a `3xx` is
  `:redirect` and a `4xx` `{:bad_status, status}` (both permanent — they won't
  become a 200 for this URL), a `5xx` is `{:server_error, status}` and a transport
  failure `:probe_failed` (both transient — the origin may recover). An internal
  host is caught here as `:internal_target` (the same permanent outcome
  `Vutuv.PageScreenshot.capture_framed/2` would give) and **never probed**, so this
  is not an SSRF request.
  """
  def ensure_http_ok(url) do
    if Vutuv.Ssrf.resolves_to_internal?(URI.parse(url).host) do
      {:error, :internal_target}
    else
      classify(probe(url))
    end
  end

  defp classify({:ok, %Req.Response{status: 200}}), do: :ok
  defp classify({:ok, %Req.Response{status: s}}) when s in 300..399, do: {:error, :redirect}

  defp classify({:ok, %Req.Response{status: s}}) when s in 400..499,
    do: {:error, {:bad_status, s}}

  defp classify({:ok, %Req.Response{status: s}}), do: {:error, {:server_error, s}}
  # Couldn't reach the target to check — transient, retried like a Chromium timeout.
  defp classify(_error), do: {:error, :probe_failed}

  # Only the status line is read, never the body, so drop it during receipt at a
  # small ceiling: a hostile member link could otherwise stream an unbounded
  # body into memory (scan finding F15).
  @probe_max_body_bytes 64 * 1024

  defp probe(url) do
    [
      url: url,
      receive_timeout: 5_000,
      connect_options: [timeout: 3_000],
      retry: false,
      redirect: false,
      # The body is never read, so Req must not spend work on (or fail over)
      # decoding it — a member link answering malformed `application/json`
      # would otherwise error the probe.
      decode_body: false,
      into: Vutuv.Http.capped_collector(@probe_max_body_bytes),
      headers: [{"user-agent", Http.user_agent()}]
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @probe_req_options_key, []))
    |> Req.get()
  end

  # The card's teaser for a page that published none of its own
  # (`Vutuv.LinkSummary`, issue #1709): what the linked page is about, read off
  # the whole page rather than off the part the picture shows.
  #
  # It runs **after** the row is `ready`, never before it. The picture is what
  # a reader is waiting for, and this is a model call — putting it in front of
  # `mark_ready/2` would hold the finished preview, the temp file and (because
  # `Vutuv.Posts.ScreenshotWorker` drains one job at a time) every capture
  # behind it.
  #
  # Strictly best-effort and deliberately not a queue of its own: every way it
  # can come to nothing leaves `summary` `nil` and the preview exactly as it
  # was, and nothing retries it. `:disabled` is not logged — on an installation
  # that never turned this on it would be a line per capture saying nothing.
  # A page that publishes its own `og:description` has already said what it is
  # about, in its author's words — the model has nothing to add and would be
  # spending half a minute to overwrite a better sentence with a worse one.
  # This is the whole division of labour between the two: the publisher's blurb
  # when there is one, ours when the page offers nothing.
  defp summarize(%PostScreenshot{description: description} = ready, _html)
       when is_binary(description),
       do: ready

  defp summarize(%PostScreenshot{} = ready, html) do
    case YoutubeThumbnail.video_id(ready.url) do
      # A video's own artwork, not a photograph of a page: there is no page
      # here to read, and the watch page would answer a consent wall anyway.
      {:ok, _video_id} -> ready
      :error -> store_summary(ready, html)
    end
  end

  defp store_summary(%PostScreenshot{url: url} = ready, html) do
    case summarize_page(url, html) do
      {:ok, summary} ->
        write_summary(ready, summary)

      {:error, :disabled} ->
        ready

      {:error, reason} ->
        Logger.info("no link summary for #{url}: #{inspect(reason)}")
        ready
    end
  end

  # The page is already in hand whenever the metadata fetch reached it, which
  # is every case a summary is actually wanted for; fetching is the fallback,
  # not the path.
  defp summarize_page(url, html) when is_binary(html), do: LinkSummary.summarize_html(url, html)
  defp summarize_page(url, _html), do: LinkSummary.summarize(url)

  # Written by id rather than through the struct we have been holding: the
  # model call is allowed to take half a minute, and in that time the author
  # can delete the post (the row cascades with it) or the AI image scan can
  # take the screenshot away. `Repo.update/1` answers a vanished row by RAISING
  # `Ecto.StaleEntryError`, which would leave `deliver_due/1`'s loop and take
  # the rest of the batch with it — for a tooltip. `update_all` on the id
  # simply writes nothing.
  defp write_summary(%PostScreenshot{} = ready, summary) do
    {_count, _} =
      from(ps in PostScreenshot, where: ps.id == ^ready.id)
      |> Repo.update_all(set: [summary: summary, updated_at: NaiveDateTime.utc_now(:second)])

    %{ready | summary: summary}
  end

  defp mark_capturing(%PostScreenshot{} = job) do
    {:ok, job} = job |> Ecto.Changeset.change(status: "capturing") |> Repo.update()
    job
  end

  defp mark_ready(%PostScreenshot{} = job, result) do
    # A fresh capture starts in AI-moderation limbo: it is announced (and
    # rendered) only once the scan releases it — otherwise a screenshot of an
    # NSFW page would bypass the upload gate (Vutuv.Moderation.ImageScans). An
    # Open Graph image is a picture a stranger's page named, so it goes through
    # exactly the same gate.
    moderation = ImageScans.initial_state()

    {:ok, ready} =
      job
      # The card half (`source` and the page's own headline) is cast through
      # the schema so the ingest caps are enforced at the write, not only at
      # the fetch. A `capture:` stub that returns none of it leaves the
      # defaults: a plain screenshot.
      # The WHOLE card half, always — never `Map.take` alone. A capture result
      # that mentions none of these is a plain screenshot and has to *say* so:
      # a row that once carried an Open Graph card and is later re-captured (an
      # admin requeue, the operator turning `:fetch_open_graph` off) would
      # otherwise keep `source: "open_graph"` and the previous page's headline,
      # and render a Chromium photograph inside a card titled by an older fetch.
      |> PostScreenshot.result_changeset(
        Map.merge(PostScreenshot.no_card(), Map.take(result, PostScreenshot.card_columns()))
      )
      |> Ecto.Changeset.change(
        status: "ready",
        screenshot: result.screenshot,
        width: result.width,
        height: result.height,
        captured_at: DateTime.utc_now(:second),
        last_error: nil,
        moderation: moderation
      )
      |> Repo.update()

    if moderation == "approved" do
      announce_ready(ready)
    else
      ImageScans.enqueue("post_screenshot", ready.id, owner_user_id(ready), ready.screenshot)
    end

    ready
  end

  @doc """
  Tells whoever is watching this preview that it can be shown now — the post's
  readers, or the one member still writing the draft it belongs to.

  Public because the release does not always happen here: a capture held by the
  AI image scan is announced by `Vutuv.Moderation.ImageSubjects.apply_approved/1`
  once the verdict lands, and that is the **normal** path with
  `:moderate_images` on. Both callers go through this one function so a new
  owner cannot be announced on one path and forgotten on the other.
  """
  # Open feeds and profiles upgrade a member post's card to show the screenshot
  # with no reload.
  def announce_ready(%PostScreenshot{post_id: post_id}) when is_binary(post_id),
    do: Vutuv.Posts.broadcast_screenshot_ready(post_id)

  # A draft's preview goes to the one member writing it, on a topic of its
  # own — deliberately **not** their `Vutuv.Activity` topic. The feed already
  # subscribes to that one, so a second subscription from
  # `VutuvWeb.Live.DraftPreview` would hand the busiest LiveView in the app two
  # copies of every unrelated activity event (`Phoenix.PubSub.subscribe/2` is a
  # bare register on a duplicate registry — it does not dedupe), and each copy
  # costs a full `get_post/1` preload chain. A private topic also stops a page
  # being woken for events it discards.
  def announce_ready(%PostScreenshot{post_draft_id: draft_id} = row) when is_binary(draft_id) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      draft_preview_topic(owner_user_id(row)),
      {:draft_preview_ready, draft_id}
    )
  end

  # A cached remote post has no author here watching for their fresh post and
  # no topic of its own, so it simply shows the screenshot on the next feed
  # load. By name, not as a catch-all, so a fourth owner raises rather than
  # silently never being told (see `owner_user_id/1` below).
  def announce_ready(%PostScreenshot{remote_post_id: id}) when is_binary(id), do: :ok

  @doc """
  Listen for this member's draft previews becoming ready.

  Both halves live here, the way every other context in the app owns its topic
  (`Posts.subscribe_post/1`, `Fediverse.subscribe_counts/0`, …): a subscriber
  should not have to name `Vutuv.PubSub` and spell the topic itself, and a
  second one copying those two lines is how a topic rename becomes a two-module
  edit.
  """
  def subscribe_draft_previews(user_id) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(Vutuv.PubSub, draft_preview_topic(user_id))

  # Private to the member: the preview belongs to a post nobody else can see yet.
  defp draft_preview_topic(user_id), do: "draft_preview:#{user_id}"

  # The AI scan's owning member: the post's author, or nobody for a remote
  # post's capture (the same ownerless shape the "remote_post_image" and
  # "remote_avatar" scans use).
  defp owner_user_id(%PostScreenshot{post_id: post_id}) when is_binary(post_id),
    do: Repo.get!(Post, post_id).user_id

  defp owner_user_id(%PostScreenshot{post_draft_id: draft_id}) when is_binary(draft_id),
    do: Repo.get!(PostDraft, draft_id).user_id

  # By name and not as a catch-all, for the reason `announce_ready/1` gives.
  defp owner_user_id(%PostScreenshot{remote_post_id: id}) when is_binary(id), do: nil

  defp mark_retry(%PostScreenshot{} = job, reason) do
    attempts = job.attempts + 1
    status = if attempts >= @max_attempts, do: "failed", else: "pending"

    Logger.warning(failure_message(job, reason))

    {:ok, job} =
      job
      |> Ecto.Changeset.change(
        status: status,
        attempts: attempts,
        next_attempt_at: backoff_at(attempts),
        last_error: error_string(reason)
      )
      |> Repo.update()

    job
  end

  defp mark_failed(%PostScreenshot{} = job, reason) do
    Logger.warning(failure_message(job, reason))

    {:ok, job} =
      job
      |> Ecto.Changeset.change(
        status: "failed",
        attempts: job.attempts + 1,
        last_error: error_string(reason)
      )
      |> Repo.update()

    job
  end

  defp backoff_at(attempts) do
    DateTime.add(DateTime.utc_now(:second), trunc(:math.pow(2, attempts)) * 60, :second)
  end

  defp error_string(reason), do: reason |> inspect() |> String.slice(0, 255)

  defp failure_message(job, reason),
    do: "post screenshot failed for #{owner_label(job)} (#{job.url}): #{inspect(reason)}"

  defp owner_label(%PostScreenshot{post_id: post_id}) when is_binary(post_id),
    do: "post #{post_id}"

  defp owner_label(%PostScreenshot{remote_post_id: id}) when is_binary(id),
    do: "remote post #{id}"

  defp owner_label(%PostScreenshot{post_draft_id: id}) when is_binary(id), do: "draft #{id}"

  ## Admin reads

  @doc """
  One page of the admin queue view: the unfinished jobs (`pending` / `capturing`
  / `failed`), newest first, with the owning post + author (or the cached
  remote post + its account) preloaded. Returns `{rows, total}`.
  Author-`dismissed` tombstones are neither unfinished work nor a gallery item,
  so they are excluded from both admin views — and so are the rows a composer
  **draft** owns, which are somebody's unpublished half-written post, not
  moderatable content, and have no page to link a row to.
  """
  def queue_page(params) do
    page(
      published_owners(
        from(ps in PostScreenshot, where: ps.status not in ["ready", "dismissed"])
      ),
      params,
      desc: :inserted_at
    )
  end

  # The admin views are about published things. A row a composer **draft** owns
  # is somebody's unfinished post: not moderatable content, and with no page for
  # a row to link to. One named function so a fourth owner is one edit, not
  # three (the rule this repo learned from the nullable-pair model).
  defp published_owners(query), do: from(ps in query, where: is_nil(ps.post_draft_id))

  @doc """
  One page of the admin gallery: captured (`ready`) screenshots, newest capture
  first, post + author preloaded (member **or** organization). Returns
  `{rows, total}`.
  """
  def gallery_page(params) do
    page(
      published_owners(from(ps in PostScreenshot, where: ps.status == "ready")),
      params,
      desc: :captured_at
    )
  end

  @doc "Count of unfinished vs ready jobs, for the admin tab labels."
  def counts do
    from(ps in PostScreenshot, where: ps.status != "dismissed")
    |> published_owners()
    |> group_by([ps], fragment("? = 'ready'", ps.status))
    |> select([ps], {fragment("? = 'ready'", ps.status), count(ps.id)})
    |> Repo.all()
    |> Enum.reduce(%{queue: 0, ready: 0}, fn
      {true, n}, acc -> %{acc | ready: n}
      {false, n}, acc -> %{acc | queue: n}
    end)
  end

  defp page(base, params, order) do
    total = Repo.aggregate(base, :count)

    rows =
      base
      |> order_by(^order)
      |> Vutuv.Pages.paginate(params, total, @per_page)
      # Both kinds of author: an organization post gets a link screenshot the
      # same way a member's does (issue #1334), and `Vutuv.Posts.path/1` — which
      # the gallery links every row with — matches on whichever one is
      # preloaded. With only `:user` the page raised on the first such row.
      |> preload(post: [:user, :organization], remote_post: :remote_account)
      |> Repo.all()

    {rows, total}
  end
end
