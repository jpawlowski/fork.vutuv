defmodule VutuvWeb.MastodonApi.LinkPreviewCardTest do
  @moduledoc """
  The link preview a Mastodon client is handed — issue #1715.

  The preview existed on both sides of the API and only the website passed it
  on: `Vutuv.MastodonApi.Presenter` hardcoded `card: nil`, so the same
  single-link post showed a card in a browser and a bare URL in an app.

  Every test reads the status through the API and looks at `card`; the one
  about the **picture** then follows the URL it names down to the file on disk.
  Asserting the URL's shape alone would pass on one pointing at the linked
  host, which is the single thing this must never serve.

  Calibrated against the un-fixed adapter: put `card: nil` back into
  `Presenter`'s two status heads and every assertion here that expects a card
  goes red.

  `async: false` because it drives the rate-limited API endpoints and, like
  `VutuvWeb.UploadsServingTest`, writes real files into the storage tree the
  endpoint serves from (each under its own row's id, removed on exit).
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers
  import Vutuv.PostsHelpers

  alias Ecto.Changeset
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo

  @url "https://example.com/artikel"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # A ready preview row. `screenshot:` says what its picture is: a filename
  # names one without putting a file on disk (a row whose bytes are gone, which
  # is all a test needs unless it fetches the URL), `nil` leaves the row
  # without one at all (a job still waiting), and `:capture` stores a real file
  # the way the worker does — through `Vutuv.Screenshot.store/1`, so the served
  # thumb is really under the row's own id and `Screenshot.stored_url/1` finds
  # it there. Only the tests that follow the URL pay for that.
  defp preview(owner, attrs \\ [])
  defp preview(%Post{id: id}, attrs), do: preview_row(:post_id, id, attrs)
  defp preview(%RemotePost{id: id}, attrs), do: preview_row(:remote_post_id, id, attrs)

  defp preview_row(owner_key, owner_id, attrs) do
    {picture, attrs} = Keyword.pop(attrs, :screenshot, "deadbeef1234.jpg")

    row =
      Repo.insert!(
        struct(
          %PostScreenshot{
            url: @url,
            status: "ready",
            source: "open_graph",
            title: "Was die Seite über sich sagt",
            description: "Der Teaser, den der Verlag selbst geschrieben hat.",
            site_name: "Example",
            width: 400,
            height: 264,
            screenshot: if(is_binary(picture), do: picture)
          },
          [{owner_key, owner_id} | attrs]
        )
      )

    # Only a real capture needs a second write: storing the file needs the
    # row's id, which is what names its directory on disk.
    if picture == :capture,
      do: Repo.update!(Changeset.change(row, screenshot: store_thumb(row))),
      else: row
  end

  defp store_thumb(row) do
    source = tmp_jpeg("capture")

    # `Vutuv.Screenshot.delete/1` and not two `rm_rf`s of paths spelled out
    # here: this module writes into the real checkout, so cleanup that drifts
    # from the uploader's layout leaves member-shaped image files in the working
    # tree — and hand-built paths already missed the quarantine tree the store
    # uses whenever image moderation is on.
    on_exit(fn -> Vutuv.Screenshot.delete(row) end)

    {:ok, file} = Vutuv.Screenshot.store({%Plug.Upload{path: source, filename: "shot.jpg"}, row})
    file
  end

  # A real (tiny) JPEG on disk: both the capture and the photo post go through
  # libvips, which opens the file rather than taking our word for it.
  defp tmp_jpeg(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.jpg")
    {:ok, image} = Image.new(64, 42, color: [30, 90, 160])
    {:ok, _written} = Image.write(image, path)
    on_exit(fn -> File.rm(path) end)

    path
  end

  defp link_post(author), do: create_post!(author, %{body: "Lest das: #{@url}"})

  defp card(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("card")

  describe "a member's single-link post" do
    setup %{conn: conn} do
      author = federating_member()
      post = link_post(author)
      row = preview(post, screenshot: :capture)

      {:ok, conn: mastodon_conn(conn, mastodon_token(author, ["read"])), post: post, preview: row}
    end

    test "carries the linked page's card", ctx do
      card = card(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      assert card["type"] == "link"
      assert card["url"] == @url
      assert card["title"] == "Was die Seite über sich sagt"
      assert card["description"] == "Der Teaser, den der Verlag selbst geschrieben hat."
      assert card["provider_name"] == "Example"
    end

    # The load-bearing half: a client must reach OUR copy of the picture, so
    # that reading a status in an app tells the linked site nothing about the
    # reader. The website's own card takes exactly the same care.
    test "names our own stored picture, the file and not a path we made up", ctx do
      card = card(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      assert card["image"] =~ "/screenshots/#{ctx.preview.id}/"
      refute card["image"] =~ "example.com"

      # Absolute, because a client fetches it from a phone rather than from a
      # page on our domain.
      assert %URI{scheme: scheme, path: path} = URI.parse(card["image"])
      assert scheme in ["http", "https"]

      # And it names a file that is really there. **Deliberately on disk rather
      # than through `get(build_conn(), path)`**, which reads as the stronger
      # check and is not: the endpoint's `/screenshots` mount resolves its root
      # at COMPILE time (`Application.compile_env(:vutuv, :uploads_dir_prefix)`,
      # empty here) while the uploader resolves the same prefix at RUNTIME — and
      # some thirty test modules move that runtime value to a tmp dir for their
      # own files. Whenever one of them is between its `put_env` and its
      # restore, the file is written and found under the tmp prefix and the
      # static mount looks in the checkout, so the fetch 404s over the suite's
      # global state rather than over anything this card did. That the mount
      # serves this tree at all is `VutuvWeb.UploadsServingTest`'s claim, made
      # once and not re-made here.
      assert File.exists?(Vutuv.Uploads.disk_dir(String.trim_leading(path, "/")))
    end

    # Mastodon types these as strings, not as nullable ones; a client decoding
    # the card into non-optional fields drops the whole card over a null.
    test "fills the fields Mastodon types as strings", ctx do
      card = card(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      assert card["author_name"] == ""
      assert card["author_url"] == ""
      assert card["provider_url"] == ""
      assert card["html"] == ""
      assert card["embed_url"] == ""
      assert card["width"] == 400
      assert card["height"] == 264
    end

    # A list endpoint says what the permalink says. The renderer batches the
    # previews for a whole page (`Screenshots.preview_map/2`) rather than
    # reading a `:screenshot` preload, so an endpoint that never asked for one
    # still answers the same.
    test "a timeline says the same as the permalink", ctx do
      author_id = ctx.post.user_id

      [status] =
        ctx.conn |> get("/api/v1/accounts/#{author_id}/statuses") |> json_response(200)

      assert status["card"]["title"] == "Was die Seite über sich sagt"
    end
  end

  describe "a preview that is not one" do
    setup %{conn: conn} do
      author = federating_member()
      {:ok, conn: mastodon_conn(conn, mastodon_token(author, ["read"])), author: author}
    end

    test "a job still waiting to be captured has no card", ctx do
      post = link_post(ctx.author)
      preview(post, status: "pending", screenshot: nil)

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end

    # The author's tombstone: they pressed "No preview", and `dismiss/1` clears
    # the words along with the picture. A card here would put back exactly what
    # they removed.
    test "a dismissed preview has no card", ctx do
      post = link_post(ctx.author)
      row = preview(post)
      {:ok, _dismissed} = Screenshots.dismiss(row)

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end

    # A row with no headline is a bare floated capture on the website, and a
    # `PreviewCard` whose `title` is empty is a grey tile in every client.
    test "a capture with no words at all has no card", ctx do
      post = link_post(ctx.author)
      preview(post, title: nil, description: nil, site_name: nil)

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end

    # `Vutuv.Screenshot.url/2` answers the bundled stand-in for a row whose file
    # is gone. The website draws it in the card's picture cell, where it reads
    # as "no screenshot"; a client has no such cell, so it gets the words and no
    # picture rather than a generic tile.
    test "a row whose file is missing keeps its words and loses its picture", ctx do
      post = link_post(ctx.author)
      preview(post)

      card = card(ctx.conn, "/api/v1/statuses/#{post.id}")

      assert card["title"] == "Was die Seite über sich sagt"
      assert card["image"] == nil
      assert card["width"] == 0
      assert card["height"] == 0
    end

    # The website's own gate: a post that shows pictures does not also show a
    # link card. The queue never gives such a post a preview row, so this only
    # ever catches a stale one — which is the ordinary state on an installation
    # with `:generate_screenshots` off, where nothing reconciles the row away
    # after the edit that added the picture.
    test "a post that carries pictures has no card", ctx do
      {:ok, picture} =
        Vutuv.Posts.create_pending_image(ctx.author, tmp_jpeg("photo"), "photo.jpg")

      post = create_post!(ctx.author, %{body: "Mit Foto: #{@url}", image_ids: [picture.id]})
      preview(post)

      status = ctx.conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)

      assert [_attachment] = status["media_attachments"]
      assert status["card"] == nil
    end

    test "a post without a link has no card at all", ctx do
      post = create_post!(ctx.author, %{body: "Nur Text."})

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end
  end

  describe "a cached post from another network" do
    setup %{conn: conn} do
      reader = federating_member()
      post = cached_post(remote_account(), content_text: "Lest das: #{@url}")
      row = preview(post, screenshot: :capture)

      {:ok, conn: mastodon_conn(conn, mastodon_token(reader, ["read"])), post: post, preview: row}
    end

    test "gets the same card a member's post gets", ctx do
      card = card(ctx.conn, "/api/v1/statuses/remote-#{ctx.post.id}")

      assert card["title"] == "Was die Seite über sich sagt"
      assert card["image"] =~ "/screenshots/#{ctx.preview.id}/"
    end

    # The author closed the lid. A client hides `media_attachments` behind
    # `sensitive` and has never hidden a card, so a card here would prop it back
    # open — the one thing an auto-preview must not do.
    test "no card once its author raised a content warning", ctx do
      Repo.update!(Changeset.change(ctx.post, sensitive: true))

      assert card(ctx.conn, "/api/v1/statuses/remote-#{ctx.post.id}") == nil
    end
  end
end
