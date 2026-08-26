defmodule VutuvWeb.PostScreenshotRenderTest do
  @moduledoc """
  A ready link screenshot floats beside its post's text; a not-yet-captured one
  renders nothing. Exercised through the post permalink (`:full` mode) and the
  profile page (`:preview` mode).

  The other shape the same row can take — the linked page's own Open Graph card
  (issue #1706) — is laid out the opposite way on purpose: full width **below**
  the post, because it carries text. Both layouts are pinned here, since what
  makes each one right is that the other one is wrong for it.
  """
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo

  @body_text "Please go through the open issues at"

  defp author, do: insert(:activated_user)

  defp post_with_screenshot(author, attrs) do
    post = create_post!(author, %{body: "#{@body_text} https://example.com/page"})

    Repo.insert!(
      struct(
        %PostScreenshot{post_id: post.id, url: "https://example.com/page", status: "pending"},
        attrs
      )
    )

    post
  end

  describe "post permalink (full mode)" do
    test "shows the screenshot once it is ready", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)
      assert html =~ "data-link-screenshot"
    end

    test "floats it beside the text rather than stacking it below", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)

      # The float lives on the screenshot element itself ...
      assert [tag] = Regex.run(~r/<a[^>]*data-link-screenshot[^>]*>/, html)
      assert tag =~ "float-right"

      # ... and inside the body container, ahead of the prose: a CSS float only
      # wraps the content that FOLLOWS it, so a screenshot rendered as a block
      # after the body lands below the text instead of beside it. Split at the
      # body container first — the post body also rides along in the page's
      # <head> metadata, which would otherwise win the position comparison.
      assert [_head, body_flow] = String.split(html, "markdown--post", parts: 2)
      assert at(body_flow, "data-link-screenshot") < at(body_flow, @body_text)
    end

    test "hovering it says what the linked page is about", %{conn: conn} do
      user = author()

      post =
        post_with_screenshot(user,
          status: "ready",
          screenshot: "abcdef012345.avif",
          summary: "Eine Übersicht der offenen Aufgaben im vutuv-Projekt."
        )

      html = html_response(get(conn, Posts.path(post)), 200)

      # On the link, not on the image: the tooltip should cover the whole tile
      # (issue #1709).
      assert [tag] = Regex.run(~r/<a[^>]*data-link-screenshot[^>]*>/, html)
      assert tag =~ "title="
      assert html =~ "Eine Übersicht der offenen Aufgaben im vutuv-Projekt."
    end

    test "renders no title at all for a capture that has no summary", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)

      # Every capture taken before #1709, and every installation that does not
      # summarise links: an empty tooltip would be worse than none.
      assert [tag] = Regex.run(~r/<a[^>]*data-link-screenshot[^>]*>/, html)
      refute tag =~ "title="
    end

    test "shows nothing while the screenshot is still pending", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "pending")

      html = html_response(get(conn, Posts.path(post)), 200)
      refute html =~ "data-link-screenshot"
    end
  end

  # Source-order position of `needle`, so a test can pin that one piece of
  # markup comes before another.
  defp at(html, needle) do
    assert {start, _length} = :binary.match(html, needle)
    start
  end

  describe "the page's own card (Open Graph)" do
    defp post_with_card(author, attrs \\ []) do
      defaults = [
        status: "ready",
        screenshot: "abcdef012345.avif",
        source: "open_graph",
        title: "Ein Titel von der Seite selbst",
        description: "Der Teaser, den die Seite anbietet.",
        site_name: "Example Times"
      ]

      post_with_screenshot(author, Keyword.merge(defaults, attrs))
    end

    test "shows the page's words, not just its picture", %{conn: conn} do
      post = post_with_card(author())

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ "data-link-card"
      assert html =~ "Ein Titel von der Seite selbst"
      assert html =~ "Der Teaser, den die Seite anbietet."
      assert html =~ "Example Times"
    end

    test "sits below the post at full width instead of floating beside it", %{conn: conn} do
      post = post_with_card(author())

      html = html_response(get(conn, Posts.path(post)), 200)

      # Not the float: a card carrying a headline in a third of the column is
      # unreadable, which is the whole reason it is a different layout.
      assert [tag] = Regex.run(~r/<a[^>]*data-link-card[^>]*>/, html)
      refute tag =~ "float-right"
      refute html =~ "data-link-screenshot"

      # ... and after the prose, not ahead of it.
      assert [_head, body_flow] = String.split(html, "markdown--post", parts: 2)
      assert at(body_flow, @body_text) < at(body_flow, "data-link-card")
    end

    test "is a real link, unlike the decorative float", %{conn: conn} do
      post = post_with_card(author())

      html = html_response(get(conn, Posts.path(post)), 200)

      assert [tag] = Regex.run(~r/<a[^>]*data-link-card[^>]*>/, html)
      # Its accessible name is the page's own headline — more than the bare URL
      # already in the prose — so hiding it from assistive tech would lose a
      # line rather than spare a duplicate.
      refute tag =~ "aria-hidden"
      assert tag =~ ~s(href="https://example.com/page")
      assert tag =~ "nofollow"
    end

    test "the linked host learns nothing about the reader", %{conn: conn} do
      post = post_with_card(author())

      html = html_response(get(conn, Posts.path(post)), 200)

      assert [card] = Regex.run(~r|<a[^>]*data-link-card.*?</a>|s, html)

      # The picture is OURS, and the assertion is on the SHAPE of the address
      # rather than on one path: `Vutuv.OpenGraph.fetch_image/1` downloaded the
      # page's `og:image` on the server and `store_remote_image/2` wrote it
      # under `/screenshots/`, and where that file is missing or held by the AI
      # scan the strip shows a local stand-in instead — three paths, all of
      # them ours, and the invariant that matters is that none of them is
      # absolute. The remote address is used once, in that fetch, and is not
      # even a column on the row. So a reader's browser makes no request to the
      # linked host while merely scrolling past — the same bargain
      # `Vutuv.RemoteMedia` strikes for fediverse images.
      assert [_img, src] = Regex.run(~r/<img[^>]*src="([^"]*)"/, card)
      assert String.starts_with?(src, "/")
      refute String.starts_with?(src, "//")

      # Which leaves the click as the only moment the target hears from anyone,
      # and it hears no more than the bare URL in the prose above already tells
      # it: `VutuvWeb.Markdown` withholds the referrer there, and a reader who
      # clicks the card instead of the text must not be worse off for it.
      assert card =~ "noreferrer"
    end

    test "the same card on the profile preview, and no float clamp with it", %{conn: conn} do
      user = author()
      _post = post_with_card(user)

      html = html_response(get(conn, ~p"/#{user.username}"), 200)

      assert html =~ "data-link-card"
      assert html =~ "Ein Titel von der Seite selbst"
      # The body clamps normally: there is nothing to wrap around.
      refute html =~ "post-clamp--wrap"
    end

    test "a row carrying no headline is not a card", %{conn: conn} do
      post = post_with_card(author(), title: nil)

      html = html_response(get(conn, Posts.path(post)), 200)

      refute html =~ "data-link-card"
      # It falls back to the float rather than rendering an empty card.
      assert html =~ "data-link-screenshot"
    end
  end

  # The half of the contract that is easy to lose: for a reader the card is one
  # thing, and where its picture came from is not a distinction they can see.
  # Every assertion here would have passed just as well when `card?/1` asked
  # `source == "open_graph"` — except the ones that use `source: "screenshot"`,
  # which is the point.
  describe "our own capture, in the same card" do
    test "a captured page with a headline is a card, not a float", %{conn: conn} do
      post =
        post_with_screenshot(author(),
          status: "ready",
          screenshot: "abcdef012345.avif",
          source: "screenshot",
          title: "Die Überschrift der Seite",
          site_name: "example.com"
        )

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ "data-link-card"
      assert html =~ "Die Überschrift der Seite"
      assert html =~ "example.com"
      refute html =~ "data-link-screenshot"
    end

    test "the summary stands in as the teaser where the page offered none", %{conn: conn} do
      post =
        post_with_screenshot(author(),
          status: "ready",
          screenshot: "abcdef012345.avif",
          source: "screenshot",
          title: "Die Überschrift der Seite",
          summary: "Was auf dieser Seite steht, in einem Satz."
        )

      html = html_response(get(conn, Posts.path(post)), 200)

      # As TEXT in the card, not as the float's `title=` tooltip. Asserting the
      # bare sentence passes either way — the float carries the same words in
      # an attribute — which is exactly how the first version of this test
      # stayed green against the un-fixed code.
      assert html =~ "data-link-card"
      assert html =~ "Was auf dieser Seite steht, in einem Satz."
      refute html =~ ~s(title="Was auf dieser Seite steht)
    end

    test "the publisher's own teaser wins over our summary", %{conn: conn} do
      post =
        post_with_screenshot(author(),
          status: "ready",
          screenshot: "abcdef012345.avif",
          source: "open_graph",
          title: "Ein Titel",
          description: "Der Klappentext des Verlegers.",
          summary: "Unser Ersatzsatz."
        )

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ "Der Klappentext des Verlegers."
      refute html =~ "Unser Ersatzsatz."
    end
  end

  describe "profile page (preview mode)" do
    test "floats the screenshot beside the post so the text wraps around it", %{conn: conn} do
      user = author()
      _post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, ~p"/#{user.username}"), 200)
      assert html =~ "data-link-screenshot"
      # The float-wrap layout: the screenshot floats and the body clamps by height
      # so the text flows around AND below it (no dead column beside a short shot).
      assert html =~ "float-right"
      assert html =~ "post-clamp--wrap"
    end
  end
end
