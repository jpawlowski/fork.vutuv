defmodule VutuvWeb.NewsfeedControllerTest do
  @moduledoc """
  The newsfeed's agent-format siblings (`/feed.md/.txt/.json/.xml`,
  VutuvWeb.AgentDocs.FeedDoc): the signed-in viewer's own timeline in another
  format. Unlike the public agent docs these are per-viewer and login-only, so
  they are private (never cached, noindex/noai) and 404 for anonymous callers.
  The HTML page itself is covered by VutuvWeb.PostFeedLiveTest.

  `/feed` is a `live` route now (issue #1731), so every case here also asserts
  that `VutuvWeb.Plug.AgentRoute` still hands the non-HTML representations to
  this controller — the whole point of that plug is that a page can be a
  LiveView **and** keep its siblings at the same URL.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Posts

  defp fresh_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

  # A logged-in viewer following an author who has posted, so the feed is
  # non-empty.
  defp feed_with_post(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:user, email_confirmed?: true, first_name: "Fiona", last_name: "Friend")
    insert(:follow, follower: user, followee: friend)
    {:ok, _post} = Posts.create_post(friend, %{body: "Bridges over troubled water"})
    {conn, user}
  end

  describe "agent formats render the viewer's feed" do
    test "Markdown carries the feed type, viewer name and the post", %{conn: conn} do
      {conn, user} = feed_with_post(conn)

      doc = get(conn, "/feed.md")

      assert doc.status == 200
      assert get_resp_header(doc, "content-type") == ["text/markdown; charset=utf-8"]
      assert doc.resp_body =~ "type: feed"
      assert doc.resp_body =~ "Feed of #{user.first_name}"
      assert doc.resp_body =~ "Bridges over troubled water"
    end

    test "JSON is a feed document with the post and pagination fields", %{conn: conn} do
      {conn, _user} = feed_with_post(conn)

      doc = get(conn, "/feed.json")
      assert doc.status == 200
      body = Jason.decode!(doc.resp_body)

      assert body["type"] == "feed"
      assert Map.has_key?(body, "more")
      assert Map.has_key?(body, "next_cursor")
      assert [%{"excerpt" => "Bridges over troubled water"} | _] = body["posts"]
    end

    test "text and XML also carry the post", %{conn: conn} do
      {conn, _user} = feed_with_post(conn)

      assert recycle(conn) |> get("/feed.txt") |> Map.get(:resp_body) =~
               "Bridges over troubled water"

      xml = recycle(conn) |> get("/feed.xml")
      assert xml.resp_body =~ "<feed>"
      assert xml.resp_body =~ "Bridges over troubled water"
    end

    test "an empty feed renders without posts", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      doc = get(conn, "/feed.md")
      assert doc.status == 200
      assert doc.resp_body =~ "type: feed"
    end

    test "several followees reposting one post collapse to a single line with a roster", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      renate = insert(:user, email_confirmed?: true, first_name: "Renate", last_name: "Repost")
      bruno = insert(:user, email_confirmed?: true, first_name: "Bruno", last_name: "Booster")
      insert(:follow, follower: user, followee: renate)
      insert(:follow, follower: user, followee: bruno)

      {:ok, post} =
        Posts.create_post(insert(:user, email_confirmed?: true), %{body: "much shared"})

      :ok = Posts.repost_post(renate, post)
      :ok = Posts.repost_post(bruno, post)

      body = get(conn, "/feed.md").resp_body

      # One line for the post (no duplicate), naming the newest reposter and
      # counting the rest.
      assert length(String.split(body, "much shared")) - 1 == 1
      assert body =~ "reposted by Bruno Booster and 1 more"

      # JSON exposes the full roster as names (the AgentDocs entry shape, where
      # author/reposted_by are names too), newest first.
      json = Jason.decode!(recycle(conn) |> get("/feed.json") |> Map.get(:resp_body))
      entry = Enum.find(json["posts"], &(&1["id"] == post.id))
      assert entry["reposters"] == ["Bruno Booster", "Renate Repost"]
      assert entry["reposted_by"] == "Bruno Booster"
    end

    test "?lang=de renders the German labels", %{conn: conn} do
      {conn, _user} = feed_with_post(conn)

      doc = get(conn, "/feed.md?lang=de")

      assert doc.status == 200
      assert doc.resp_body =~ "Feed von"
    end
  end

  describe "the HTML page and the documents share one URL (issue #1731)" do
    test "the HTML page advertises its siblings and varies on Accept", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      page = get(conn, "/feed")

      assert page.status == 200
      assert get_resp_header(page, "vary") == ["accept"]

      # The <head> alternates and the Link header are built from the same
      # assign, which VutuvWeb.Plug.AgentRoute now sets in the retired
      # controller HTML branch's place.
      for format <- ~w(md txt json xml) do
        assert page.resp_body =~ ~s(href="/feed.#{format}")
      end

      link = get_resp_header(page, "link") |> Enum.join(", ")
      assert link =~ ~s(</feed.md>; rel="alternate"; type="text/markdown")
    end

    # The ActivityPub header is NOT dispatched here — `/feed` is a routed
    # LiveView now, so `:html_only` refuses the format with the same 406 every
    # other page of that shape gives (`VutuvWeb.Plug.HtmlOnly`, issue #1776).
    # Asserted for the whole class in `http_status_contract_test.exs`, which
    # sweeps every routed LiveView rather than naming this one.

    test "the HTML page is the LiveView, not this controller", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      page = get(conn, "/feed")

      assert page.status == 200
      # A `live` route dispatches through Phoenix.LiveView.Plug; if AgentRoute
      # ever swallowed the HTML request, this would name the controller.
      refute page.private[:phoenix_controller] == VutuvWeb.NewsfeedController
      assert page.resp_body =~ "data-phx-main"
    end
  end

  describe "the feed docs are private, not public agent pages" do
    test "they are sent private/no-store and noindex/noai", %{conn: conn} do
      {conn, _user} = feed_with_post(conn)

      doc = get(conn, "/feed.json")

      assert get_resp_header(doc, "cache-control") == ["private, no-store"]
      assert get_resp_header(doc, "x-robots-tag") == ["noindex, noai, noimageai"]
      assert get_resp_header(doc, "content-signal") == ["ai-train=no, search=no, ai-input=no"]
    end

    test "an anonymous agent-format request 404s (no anonymous feed document)", %{conn: _conn} do
      assert get(fresh_conn(), "/feed.json").status == 404
      assert get(fresh_conn(), "/feed.md").status == 404
    end

    test "there is no vCard sibling for a feed", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      assert get(conn, "/feed.vcf").status == 404
    end
  end
end
