defmodule VutuvWeb.PostQuoteLiveTest do
  @moduledoc """
  The quote page (`/posts/:id/quote`) and the compact card a quote carries
  (issue #1610).

  The page is shaped like the reply page and gated like the reshare: only a
  visible, public post can be quoted. What it publishes is a **top-level post**,
  so it lands on its own permalink rather than back in a conversation — there is
  none to go back to.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  describe "GET /posts/:id/quote" do
    test "shows the quoted post and the composer", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      quoted =
        create_post!(other_user(first_name: "Olga", last_name: "Original"), %{
          body: "the original"
        })

      {:ok, _live, html} = live(conn, ~p"/posts/#{quoted.id}/quote")

      assert html =~ "the original"
      assert html =~ "Olga Original"
      assert html =~ "composer-form"
      # Said before anybody types: this is not an answer.
      assert html =~ "not an answer"
    end

    test "redirects logged-out visitors to login", %{conn: conn} do
      quoted = create_post!(other_user(), %{body: "x"})

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/posts/#{quoted.id}/quote")
    end

    test "sends viewers away for restricted or invisible posts", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      restricted =
        create_post!(other_user(), %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

      hidden = create_post!(other_user(), %{body: "x", denials: [%{"denied_user_id" => user.id}]})

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{restricted.id}/quote")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{hidden.id}/quote")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/0/quote")
    end

    test "publishing lands on the quote's own permalink", %{conn: conn} do
      {conn, quoter} = create_and_login_user(conn)
      quoted = create_post!(other_user(), %{body: "the original"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{quoted.id}/quote")

      live
      |> form("#composer-form", %{"post" => %{"body" => "worth reading"}})
      |> render_submit()

      # Its own permalink, not back into a conversation — there is none.
      assert {path, _flash} = assert_redirect(live)
      assert path =~ "/#{quoter.username}/posts/"
      assert Posts.quote_count(quoted.id) == 1
    end

    test "a blocked quoter is refused on submit, in the quote's own words", %{conn: conn} do
      # Quiet blocking: the author's public post stays visible to the blocked
      # member, so the page mounts and the refusal comes on save — and it says
      # "quote", not "reply", or it sends them looking for an answer box.
      {conn, quoter} = create_and_login_user(conn)
      author = other_user()
      {:ok, _} = Vutuv.Social.block_user(author, quoter)
      quoted = create_post!(author, %{body: "open to all"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{quoted.id}/quote")

      live
      |> form("#composer-form", %{"post" => %{"body" => "let me in"}})
      |> render_submit()

      assert live |> element("#composer-error") |> render() =~ "can no longer quote"
      assert Posts.quote_count(quoted.id) == 0
    end
  end

  describe "the card a quote carries" do
    test "the feed shows the quoted post inside the quote", %{conn: conn} do
      {conn, quoter} = create_and_login_user(conn)
      author = other_user(first_name: "Olga", last_name: "Original")
      quoted = create_post!(author, %{body: "the original words"})
      {:ok, _} = Posts.create_quote(quoter, quoted, %{body: "my own words"})

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "my own words"
      assert html =~ "the original words"
      assert html =~ ~s(data-quoted-post=")
    end

    test "a deleted quoted post degrades to its author's name", %{conn: conn} do
      {conn, quoter} = create_and_login_user(conn)
      author = other_user(first_name: "Olga", last_name: "Original")
      quoted = create_post!(author, %{body: "the original words"})
      {:ok, _} = Posts.create_quote(quoter, quoted, %{body: "my own words"})
      {:ok, _} = Posts.delete_post(quoted)

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "my own words"
      assert html =~ ~s(data-quoted-post-state="gone")
      assert html =~ "@#{author.username}"
      refute html =~ "the original words"
    end

    test "a frozen quoted post says so rather than showing its text", %{conn: conn} do
      {conn, quoter} = create_and_login_user(conn)
      quoted = create_post!(other_user(), %{body: "the original words"})
      {:ok, _} = Posts.create_quote(quoter, quoted, %{body: "my own words"})

      Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^quoted.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ ~s(data-quoted-post-state="unavailable")
      refute html =~ "the original words"
    end
  end

  describe "the German render" do
    # `mix gettext.extract --merge` fuzzy-fills a brand-new msgid with the
    # translation of whatever it looks similar to and fails no build, so these
    # strings ship as confident nonsense unless a German render asserts them by
    # name. It really happened to this feature: "Quote this post" came back as
    # "Diese Anzeige melden" (report this ad) and "Only public posts can be
    # quoted." as the repost sentence.
    test "names the quote controls in German, not a fuzzy neighbour", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      quoted = create_post!(other_user(), %{body: "das Original"})

      {:ok, _live, html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/posts/#{quoted.id}/quote")

      assert html =~ "zitieren"
      assert html =~ "Es ist keine Antwort"
      refute html =~ "Anzeige"
    end

    test "names the quoted card's placeholder in German", %{conn: conn} do
      {conn, quoter} = create_and_login_user(conn)
      quoted = create_post!(other_user(), %{body: "das Original"})
      {:ok, _} = Posts.create_quote(quoter, quoted, %{body: "meine Worte"})
      {:ok, _} = Posts.delete_post(quoted)

      {:ok, _live, html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/feed")

      assert html =~ "Zitiert einen inzwischen gelöschten Beitrag von"
    end
  end
end
