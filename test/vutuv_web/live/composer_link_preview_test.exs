defmodule VutuvWeb.ComposerLinkPreviewTest do
  @moduledoc """
  The link preview in the composer (issue #1714): it appears while you write,
  it says which link it is for, and you can point it somewhere else or turn it
  off — all before anything is published.

  The draft debounce is 0 in the test env (`config/test.exs`), so the reconcile
  happens inside the `validate` that typed the link and there is no timer to
  race. The capture itself is drained by hand rather than by the worker.

  `async: false`: it flips `:generate_screenshots` (read by every post save and
  by the draft reconcile), `:fetch_open_graph` (read by `Vutuv.OpenGraph`) and
  `:moderate_images` (read by `Vutuv.Moderation.ImageScans`), all of which are
  application-wide.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo

  @first "https://first.example/page"
  @second "https://second.example/page"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_composer_og_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    put_env(:uploads_dir_prefix, tmp)
    put_env(:generate_screenshots, true)
    put_env(:fetch_open_graph, true)
    put_env(:moderate_images, false)

    fixture = Path.join(tmp, "fixture.png")
    {:ok, image} = Image.new(64, 36, color: [10, 90, 200])
    {:ok, _written} = Image.write(image, fixture)
    png = File.read!(fixture)

    Application.put_env(:vutuv, :open_graph_req_options,
      plug: fn conn ->
        case conn.request_path do
          "/page" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html", nil)
            |> Plug.Conn.send_resp(200, """
            <html><head>
            <meta property="og:title" content="Headline of #{conn.host}">
            <meta property="og:description" content="Teaser of #{conn.host}.">
            <meta property="og:site_name" content="#{conn.host}">
            <meta property="og:image" content="https://#{conn.host}/card.png">
            </head></html>
            """)

          "/card.png" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png", nil)
            |> Plug.Conn.send_resp(200, png)
        end
      end
    )

    on_exit(fn ->
      File.rm_rf(tmp)
      Application.delete_env(:vutuv, :open_graph_req_options)
    end)

    :ok
  end

  defp put_env(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  # Two round trips with the same text, because that is what "the member
  # stopped typing" looks like to the server: a link is only fetched once it has
  # survived a whole autosave pause unchanged, so a half-typed URL is never
  # requested (see `sync_link_preview/1`). The debounce is 0 in the test env, so
  # each `render_change` is one pause.
  defp type(live, body) do
    live |> form("#composer-form", %{"post" => %{"body" => body}}) |> render_change()
    live |> form("#composer-form", %{"post" => %{"body" => body}}) |> render_change()
  end

  defp type_once(live, body) do
    live |> form("#composer-form", %{"post" => %{"body" => body}}) |> render_change()
  end

  describe "a single link" do
    test "the preview appears while writing, without publishing anything", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      html = type(live, "Schau mal: #{@first}")

      # Fetching, said out loud rather than an empty box.
      assert html =~ "data-composer-link-preview"
      assert html =~ "Fetching the preview"

      Screenshots.deliver_due(force: true)
      html = type(live, "Schau mal: #{@first} ")

      assert html =~ "data-link-card"
      assert html =~ "Headline of first.example"
      # Nothing has been published.
      assert Repo.aggregate(Post, :count) == 0
    end

    test "one link is a two-state toggle, not a one-way switch", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      html = type(live, "Schau mal: #{@first}")

      # Both halves are there, so turning the preview off can be undone; the
      # "Preview for:" label is not, because with one link there is nothing to
      # choose between.
      assert html =~ "No preview"
      assert has_element?(live, ~s([phx-value-url="#{@first}"]))
      refute html =~ "Preview for:"
    end

    test "the panel speaks German too", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} =
        conn
        |> Phoenix.ConnTest.recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      html = type(live, "Schau mal: #{@first}")

      # By name, because `gettext.extract --merge` fuzzy-filled these from
      # unrelated strings — "No preview" arrived as "Buchbesprechung".
      assert html =~ "Linkvorschau"
      assert html =~ "Keine Vorschau"
      assert html =~ "Vorschau wird geholt"

      html =
        live
        |> element(~s([phx-click="choose-link-preview"][phx-value-url="none"]))
        |> render_click()

      assert html =~ "Dieser Beitrag geht ohne Linkvorschau raus."
    end

    test "a half-typed link is not fetched", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      # One pause with a link that is still being typed: the panel appears and
      # says it is working, but nothing has been requested yet — the address on
      # screen is a prefix, and fetching prefixes means real captures and real
      # AI-scan spend on pages nobody asked for.
      html = type_once(live, "Schau mal: https://first.exam")

      assert html =~ "Fetching the preview"
      assert Posts.draft_link_preview(Posts.get_draft(user)) == nil

      # The same text a pause later is a link the member meant.
      type_once(live, "Schau mal: https://first.exam")
      assert Posts.draft_link_preview(Posts.get_draft(user)).url == "https://first.exam"
    end

    test "no link, no panel", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      refute type(live, "Nur Text, kein Link") =~ "data-composer-link-preview"
    end
  end

  describe "several links" do
    test "the first one is previewed and the author can switch", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      type(live, "Zwei: #{@first} und #{@second}")
      Screenshots.deliver_due(force: true)
      html = type(live, "Zwei: #{@first} und #{@second} ")

      assert html =~ "Preview for:"
      assert html =~ "Headline of first.example"

      html =
        live
        |> element(~s([phx-click="choose-link-preview"][phx-value-url="#{@second}"]))
        |> render_click()

      # The pick is recorded straight away; the new page's words follow once
      # the fetch lands.
      assert Posts.draft_link_preview(Posts.get_draft(user)).url == @second
      assert html =~ "Fetching the preview"

      Screenshots.deliver_due(force: true)
      html = type(live, "Zwei: #{@first} und #{@second}  ")

      assert html =~ "Headline of second.example"
      refute html =~ "Headline of first.example"
    end

    test "turning the preview off, and back on again", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      type(live, "Schau mal: #{@first}")
      Screenshots.deliver_due(force: true)
      type(live, "Schau mal: #{@first} ")

      html =
        live
        |> element(~s([phx-click="choose-link-preview"][phx-value-url="none"]))
        |> render_click()

      assert html =~ "This post goes out without a link preview."
      refute html =~ "data-link-card"
      assert Posts.draft_link_preview(Posts.get_draft(user)).status == "dismissed"

      # Pressing the same link again has to undo it — the tombstone is the
      # author's, so only the author lifts it.
      live
      |> element(~s([phx-click="choose-link-preview"][phx-value-url="#{@first}"]))
      |> render_click()

      assert Posts.draft_link_preview(Posts.get_draft(user)).status == "pending"
    end
  end

  describe "taking the link back out" do
    test "the preview goes with it, and the post does not inherit it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      type(live, "Schau mal: #{@first}")
      Screenshots.deliver_due(force: true)
      assert Posts.draft_link_preview(Posts.get_draft(user))

      # The link is gone. Waiting for the candidates to "settle" would wait
      # forever — [] never differs from [] again — so the row would outlive the
      # link and be handed to the post on publish.
      html = type(live, "Schau mal, doch ohne Link.")

      refute html =~ "data-composer-link-preview"
      assert Posts.draft_link_preview(Posts.get_draft(user)) == nil
      assert Repo.aggregate(PostScreenshot, :count) == 0

      live
      |> form("#composer-form", %{"post" => %{"body" => "Schau mal, doch ohne Link."}})
      |> render_submit()

      post = Repo.one!(from(p in Post, where: p.user_id == ^user.id))
      assert Repo.preload(post, :screenshot, force: true).screenshot == nil
    end

    test "swapping the link between the last autosave and Post republishes nothing stale", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      type(live, "Schau mal: #{@first}")
      Screenshots.deliver_due(force: true)
      assert Posts.draft_link_preview(Posts.get_draft(user)).url == @first

      # Submitted params are the truth; the draft still names the old link.
      live
      |> form("#composer-form", %{"post" => %{"body" => "Doch lieber: #{@second}"}})
      |> render_submit()

      post = Repo.one!(from(p in Post, where: p.user_id == ^user.id))
      adopted = Repo.preload(post, :screenshot, force: true).screenshot

      # Adoption alone would have published the first page's card under a body
      # that names the second.
      assert adopted.url == @second
      assert adopted.title == nil
    end
  end

  describe "publishing" do
    test "the post shows the very preview the composer showed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      type(live, "Schau mal: #{@first}")
      Screenshots.deliver_due(force: true)
      shown = Posts.draft_link_preview(Posts.get_draft(user))
      assert shown.status == "ready"

      live
      |> form("#composer-form", %{"post" => %{"body" => "Schau mal: #{@first}"}})
      |> render_submit()

      post = Repo.one!(from(p in Post, where: p.user_id == ^user.id))
      adopted = Repo.preload(post, :screenshot, force: true).screenshot

      # The same row: no gap where the published post has no preview, and no
      # second fetch of a page we already read.
      assert adopted.id == shown.id
      assert adopted.title == "Headline of first.example"
      assert Posts.get_draft(user) == nil
    end
  end
end
