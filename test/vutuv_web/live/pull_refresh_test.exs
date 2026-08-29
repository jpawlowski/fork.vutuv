defmodule VutuvWeb.PullRefreshTest do
  @moduledoc """
  Pull a list down to refresh it (issue #1730).

  Content already arrives over PubSub, so what is worth testing is not that a
  refresh brings *something* — it is the three rules that make this gesture
  worth having at all:

    * it is a **socket round trip**, never a page reload;
    * it is **opt-in per page**, so it never appears where nothing handles it;
    * and it is **not offered to a browser whose bundle predates the hook**,
      because a deploy reloads no open tab.

  Each page's refresh is driven with rows created the way the *live* path
  cannot see them (a factory insert rather than the context function that
  broadcasts), so a green assertion can only mean the refresh ran the query.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Chat
  alias Vutuv.Social

  # `get/2` recycles a conn that has already been sent, and recycling drops
  # `private` — connect params included. Recycling first is what gets them as
  # far as the join. (`feed_tab_ticker_test.exs` says the same thing over its
  # own two lines; sharing six lines was not worth a macro to reach the
  # caller's `@endpoint`.)
  defp live_at(conn, path, connect_params) do
    {:ok, view, _html} =
      conn |> recycle() |> put_connect_params(connect_params) |> live(path)

    view
  end

  # What a current bundle sends on join. `app.js` puts the key there, and only
  # a bundle carrying the PullToRefresh hook can — see
  # `VutuvWeb.Live.PullRefresh`.
  @current %{"pull_refresh" => true}

  describe "the feed" do
    test "offers the gesture and re-runs its query on the push", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = insert(:user, email_confirmed?: true)
      Social.follow(user, author.id)

      view = live_at(conn, ~p"/feed", @current)
      # On its own wrapper, not on `#feed` itself: `#feed` carries `FeedUrl`
      # since v7.600.0, and LiveView reads `phx-hook` as a single name.
      assert has_element?(view, ~s(#feed-pull[phx-hook="PullToRefresh"]))

      # A bare row: `Posts.create_post/2` would broadcast and the open feed
      # would take it live, which would prove nothing about the refresh.
      insert(:post, user: author, body: "gezogen, nicht geschoben")
      refute render(view) =~ "gezogen, nicht geschoben"

      render_hook(view, "pwa:refresh", %{})
      assert render(view) =~ "gezogen, nicht geschoben"
    end
  end

  describe "notifications" do
    test "offers the gesture and reloads the list on the push", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      view = live_at(conn, ~p"/notifications", @current)
      assert has_element?(view, ~s(#notifications[phx-hook="PullToRefresh"]))

      # `follow!/2` inserts the edge without `Social.follow/2`'s broadcast, so
      # the open page cannot have seen it arrive.
      follower = insert(:user, first_name: "Nachgezogen", last_name: "Test")
      follow!(follower, user)
      refute render(view) =~ "Nachgezogen"

      render_hook(view, "pwa:refresh", %{})
      assert render(view) =~ "Nachgezogen"
    end
  end

  describe "messages" do
    # This page is a full-viewport chat: the document does not scroll, the
    # conversation list is its own scroll container, and a gesture that engaged
    # on the wrong element would be worse than none. So the hook sits on the
    # list and says so.
    test "arms the conversation list, not the page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      view = live_at(conn, ~p"/messages", @current)

      assert has_element?(
               view,
               ~s(#conversations[phx-hook="PullToRefresh"][data-pull-scroller="self"])
             )

      refute has_element?(view, ~s(#messages[phx-hook="PullToRefresh"]))
    end

    test "reloads the conversation list on the push", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      other = insert(:user, first_name: "Nachzuegler", last_name: "Test")

      view = live_at(conn, ~p"/messages", @current)
      refute render(view) =~ "Nachzuegler"

      conversation = insert_conversation_between(other, user)
      {:ok, _} = Chat.send_message(other, conversation.id, "spaet dran")

      render_hook(view, "pwa:refresh", %{})
      assert render(view) =~ "Nachzuegler"
    end
  end

  # One test for all three pages: a browser whose bundle predates the hook is
  # not a per-page condition, it is the same claim missing from the join, and
  # three copies of it only made the list of pages harder to extend.
  test "no page offers the gesture to a bundle that predates the hook", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    for {path, id} <- [
          {~p"/feed", "feed-pull"},
          {~p"/notifications", "notifications"},
          {~p"/messages", "conversations"}
        ] do
      view = live_at(conn, path, %{})

      assert has_element?(view, "##{id}"), "#{path} did not render at all"
      refute has_element?(view, ~s(##{id}[phx-hook="PullToRefresh"]))
    end
  end

  describe "the client half a LiveView test cannot reach" do
    test "the bundle declares the capability the gate reads" do
      assert_bundle_capability("pull_refresh", "PullToRefresh")
    end

    # The one mistake this feature exists to avoid. `location.reload()` throws
    # away the LiveView, rebuilds the socket and re-fetches the whole document,
    # so the "refresh" costs more than the state it refreshes — on a slow line,
    # worse than not having the gesture at all.
    test "the gesture ends in a socket push, never a page reload" do
      # Comments stripped first: the file explains at length why the reload is
      # wrong, and naming the mistake must not count as making it.
      code =
        "assets/js/pull_to_refresh.js"
        |> File.read!()
        |> String.replace(~r{^\s*//.*$}m, "")

      refute code =~ ~r/location\s*\.\s*reload/,
             "pull-to-refresh must push `pwa:refresh` over the socket, not reload the page"

      assert code =~ ~S|pushEvent("pwa:refresh"|,
             "the release has to push the event whichever LiveView owns the list handles"

      assert code =~ "passive: false",
             "the touchmove listener has to be non-passive, or the native scroll cannot be prevented"
    end

    # The two states a pull-to-refresh gets wrong, neither of which shows up in
    # a screenshot: a list that is already scrolled down, and a pull the finger
    # abandons half way. Both are decided in the client, so they are asserted
    # here rather than through the socket — the LiveView only ever sees the
    # event that these guards decide not to send.
    test "a list that is already scrolled never starts the gesture" do
      code = js()

      # The guard has to sit in `begin`, before any state is built: a pull that
      # starts mid-list belongs to the browser's own scrolling, and stealing it
      # would fight the scroll the reader actually asked for.
      begin_body = body_of(code, "begin(e) {")

      assert begin_body =~ ~r/if\s*\(!this\.atTop\(\)\)\s*return/,
             "begin() must bail out unless the scroller is at the top"

      assert code =~ ~r/atTop\(\)\s*\{\s*return this\.scroller\.scrollTop <= 0/,
             "atTop/0 must read the scroller's own scrollTop, not the window's"

      # And again during the pull: momentum can carry the container off the top
      # between two frames, and from there on the gesture is not ours either.
      track_body = body_of(code, "track(e) {")

      assert track_body =~ ~r/if\s*\(!this\.atTop\(\)\)\s*return this\.collapse\(\)/,
             "track() must collapse if the list has scrolled away from the top mid-pull"
    end

    test "a pull released below the threshold refreshes nothing" do
      code = js()
      release_body = body_of(code, "release() {")

      # `crossed` is set in track() at the moment the threshold is passed, so
      # release() reads a decision already made rather than re-measuring a
      # distance the finger may have given back.
      assert release_body =~ ~r/const armed = this\.pull\.crossed/,
             "release() must read the crossed flag, not re-measure the distance"

      assert release_body =~ ~r/if\s*\(!armed\)\s*return this\.collapse\(\)/,
             "an unarmed release must collapse and return before any pushEvent"

      # The push must sit *after* that early return, or an abandoned pull would
      # still refresh the list.
      [before_push, _] = String.split(release_body, ~S|pushEvent("pwa:refresh"|, parts: 2)

      assert before_push =~ "if (!armed) return this.collapse()",
             "the unarmed guard has to precede the push, not follow it"

      # An interrupted gesture is not only a short pull: the system can take the
      # touch away (a call, a notification, the edge-swipe back). touchcancel
      # has to end the pull the same way touchend does.
      assert code =~ ~S|addEventListener("touchcancel", this.onEnd)|,
             "touchcancel must run the same release path as touchend"
    end
  end

  defp js, do: File.read!("assets/js/pull_to_refresh.js")

  # The body of one object-literal method, from its opening line to the closing
  # brace at the same indentation. Cheap on purpose: it only has to keep an
  # assertion about `begin` from being satisfied by a line in `track`.
  defp body_of(code, header) do
    [_, rest] = String.split(code, header, parts: 2)
    [body, _] = String.split(rest, "\n  },", parts: 2)
    body
  end
end
