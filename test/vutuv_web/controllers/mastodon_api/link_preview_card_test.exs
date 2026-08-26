defmodule VutuvWeb.MastodonApi.LinkPreviewCardTest do
  @moduledoc """
  The link preview a Mastodon client is handed — issue #1715.

  The preview existed on both sides of the API and only the website passed it
  on: `Vutuv.MastodonApi.Presenter` hardcoded `card: nil`, so the same
  single-link post showed a card in a browser and a bare URL in an app.

  Every test reads the status through the API and looks at `card`; the one
  about the **picture** then fetches the URL it names on a bare conn, the way a
  phone's image loader would. Asserting the URL alone would pass on one
  pointing at the linked host, which is the single thing this must never serve.

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
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo

  @url "https://example.com/artikel"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # A captured preview, stored the way the worker stores one — through
  # `Vutuv.Screenshot.store/1`, so the served file really is on disk under the
  # row's own id and `Screenshot.url/2` finds it there.
  #
  # `screenshot:` in `attrs` opts out: `:none` leaves the row without a picture
  # (a job still waiting), a filename puts one on the row without putting a file
  # on disk (a row whose file is gone).
  defp preview(owner_key, owner_id, attrs) do
    {picture, attrs} = Keyword.pop(attrs, :screenshot, :capture)

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
    source = Path.join(System.tmp_dir!(), "capture-#{System.unique_integer([:positive])}.jpg")
    {:ok, image} = Image.new(64, 42, color: [30, 90, 160])
    {:ok, _written} = Image.write(image, source)

    on_exit(fn ->
      File.rm(source)
      File.rm_rf(Vutuv.Uploads.disk_dir("screenshots/#{row.id}"))
      File.rm_rf(Vutuv.Uploads.disk_dir("originals/screenshots/#{row.id}"))
    end)

    {:ok, file} = Vutuv.Screenshot.store({%Plug.Upload{path: source, filename: "shot.jpg"}, row})
    file
  end

  defp link_post(author), do: create_post!(author, %{body: "Lest das: #{@url}"})

  defp card(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("card")

  describe "a member's single-link post" do
    setup %{conn: conn} do
      author = federating_member()
      post = link_post(author)
      row = preview(:post_id, post.id, [])

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
    test "names our stored picture, and that URL loads for the client", ctx do
      card = card(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      assert card["image"] =~ "/screenshots/#{ctx.preview.id}/"
      refute card["image"] =~ "example.com"

      # Absolute, because a client fetches it from a phone rather than from a
      # page on our domain — and then really served, on a conn with no cookie
      # and no bearer.
      assert %URI{scheme: scheme, path: path} = URI.parse(card["image"])
      assert scheme in ["http", "https"]
      assert get(build_conn(), path).status == 200
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
    # previews for a whole page (`Screenshots.preview_map/1`) rather than
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
      preview(:post_id, post.id, status: "pending", screenshot: :none)

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end

    # The author's tombstone: they pressed "No preview", and `dismiss/1` clears
    # the words along with the picture. A card here would put back exactly what
    # they removed.
    test "a dismissed preview has no card", ctx do
      post = link_post(ctx.author)
      row = preview(:post_id, post.id, [])
      {:ok, _dismissed} = Screenshots.dismiss(Repo.reload!(row))

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end

    # A row with no headline is a bare floated capture on the website, and a
    # `PreviewCard` whose `title` is empty is a grey tile in every client.
    test "a capture with no words at all has no card", ctx do
      post = link_post(ctx.author)
      preview(:post_id, post.id, title: nil, description: nil, site_name: nil)

      assert card(ctx.conn, "/api/v1/statuses/#{post.id}") == nil
    end

    # `Vutuv.Screenshot.url/2` answers the bundled stand-in for a row whose file
    # is gone. The website draws it in the card's picture cell, where it reads
    # as "no screenshot"; a client has no such cell, so it gets the words and no
    # picture rather than a generic tile.
    test "a row whose file is missing keeps its words and loses its picture", ctx do
      post = link_post(ctx.author)
      preview(:post_id, post.id, screenshot: "deadbeef1234.jpg")

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
      src = Path.join(System.tmp_dir!(), "photo-#{System.unique_integer([:positive])}.jpg")
      {:ok, image} = Image.new(64, 64, color: [10, 200, 100])
      {:ok, _written} = Image.write(image, src)
      on_exit(fn -> File.rm(src) end)

      {:ok, picture} = Vutuv.Posts.create_pending_image(ctx.author, src, "photo.jpg")
      post = create_post!(ctx.author, %{body: "Mit Foto: #{@url}", image_ids: [picture.id]})
      preview(:post_id, post.id, [])

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
      row = preview(:remote_post_id, post.id, [])

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
