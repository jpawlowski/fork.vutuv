defmodule VutuvWeb.BottomTabNavigationTest do
  @moduledoc """
  Switching bottom tabs patches the content instead of rebuilding the document
  (issue #1731).

  Four separate things have to hold, and each fails silently on its own — which
  is why they are asserted rather than eyeballed. The destinations have to share
  one `live_session` (`<.link navigate>` degrades to a full load across a
  boundary and says nothing); the links have to actually BE live-navigation
  links; the document has to have said it can be patched at all, which a tab
  open across a deploy has not; and the sticky shell, which by definition never
  mounts again, has to learn where the reader went.

  `/feed`'s agent-format siblings surviving the move to a `live` route is the
  other half, covered by `VutuvWeb.NewsfeedControllerTest`.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Debug
  alias VutuvWeb.Live.ShellNav

  # The bottom tab bar, so the assertions cannot be satisfied by the desktop
  # nav's link to the same page.
  @tab_bar ~s(nav[data-nav-bar="tabs"])

  defp shell(conn, user, extra) do
    view = unclaimed_shell(conn, user, extra)

    # What a browser running THIS release does on mount: the ShellNavReady hook
    # says the document can be patched between tabs. Without that claim the
    # navs hand out plain `href`s, so every patching assertion below has to
    # start where a current browser starts.
    render_hook(view, "shell:can_patch", %{})
    view
  end

  # The same shell before any such claim — a document from an older release,
  # which is what a tab open across a deploy is.
  defp unclaimed_shell(conn, user, extra) do
    {:ok, view, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: shell_session(user, extra))

    view
  end

  # The transport process is what a browser tab's LiveViews have in common, so
  # it is what ShellNav scopes its topic to. Standing in for the arriving page
  # means broadcasting on the shell's own.
  defp navigate_to(view, path) do
    transport_pid =
      Debug.list_liveviews()
      |> Enum.find(&(&1.pid == view.pid))
      |> Map.fetch!(:transport_pid)

    Phoenix.PubSub.broadcast(Vutuv.PubSub, ShellNav.topic(transport_pid), {:shell_path, path})
    render(view)
  end

  describe "the tab destinations are in one live_session" do
    test "feed, search, messages and notifications share live_session :default" do
      for path <- ~w(/feed /search /messages /notifications) do
        # The endpoint's own host, which is what ShellLive.live_session/1 asks
        # the router with — a literal here would be a different question.
        info =
          Phoenix.Router.route_info(VutuvWeb.Router, "GET", path, VutuvWeb.Endpoint.host())

        assert info.plug == Phoenix.LiveView.Plug,
               "#{path} is not a live route, so nothing can patch to it"

        assert {_view, _action, _opts, %{name: :default}} = info.phoenix_live_view
      end
    end
  end

  describe "the tab bar's links" do
    test "a tab whose destination shares this page's live_session patches", %{conn: conn} do
      view = shell(conn, insert(:user), %{"path" => "/feed"})

      for path <- ~w(/feed /search /messages /notifications) do
        assert has_element?(view, ~s(#{@tab_bar} a[href="#{path}"][data-phx-link="redirect"])),
               "the #{path} tab is not a live-navigation link"
      end
    end

    # A live navigation leaves the document standing, so `assets/js/tab_scroll.js`
    # is what resets the scroll on arrival and puts back where each tab was
    # left. A tab open across a deploy runs the PREVIOUS release's JavaScript
    # against the new server, and that bundle has neither — patching into it
    # would drop the reader half a screen down whatever they switched to. So the
    # shell waits to be told, and the telling is the hook's existence.
    test "a document that has not said it can patch gets ordinary links", %{conn: conn} do
      view = unclaimed_shell(conn, insert(:user), %{"path" => "/feed"})

      for path <- ~w(/feed /search /messages /notifications) do
        refute has_element?(view, ~s(#{@tab_bar} a[href="#{path}"][data-phx-link])),
               "the #{path} tab patches into a document that never claimed it could"
      end

      render_hook(view, "shell:can_patch", %{})

      assert has_element?(view, ~s(#{@tab_bar} a[href="/messages"][data-phx-link="redirect"])),
             "the claim did not turn the tabs back into live-navigation links"
    end

    test "the profile tab is an ordinary link while /:slug is a controller route", %{conn: conn} do
      user = insert(:user, username: "tabber")
      view = shell(conn, user, %{"path" => "/feed"})

      assert has_element?(view, ~s(#{@tab_bar} a[href="/tabber"]))
      refute has_element?(view, ~s(#{@tab_bar} a[href="/tabber"][data-phx-link]))
    end

    # The shell renders on every page, not only on the ones that can patch —
    # and `<.link navigate>` patches only within ONE live_session, so the
    # destination alone cannot answer the question. Both of these would spend a
    # socket round trip before falling back to a full load.
    test "from a controller page every tab is an ordinary link", %{conn: conn} do
      # /jobs is a plain `get` route, and it sits inside the live_session block
      # in the router — so "which block is it written in" is not the test either.
      view = shell(conn, insert(:user), %{"path" => "/jobs"})

      for path <- ~w(/feed /search /messages /notifications) do
        refute has_element?(view, ~s(#{@tab_bar} a[href="#{path}"][data-phx-link])),
               "the #{path} tab claims it can patch away from a controller page"
      end
    end

    test "from another live_session every tab is an ordinary link", %{conn: conn} do
      # /admin/users is a `live` route, but in `live_session :admin` — a live
      # destination is not enough, it has to be the SAME session.
      view = shell(conn, insert(:user, admin?: true), %{"path" => "/admin/users"})

      refute has_element?(view, ~s(#{@tab_bar} a[href="/feed"][data-phx-link]))
    end
  end

  describe "the sticky shell follows a live navigation" do
    test "the active tab moves with the reader", %{conn: conn} do
      view = shell(conn, insert(:user), %{"path" => "/feed"})

      assert has_element?(view, ~s(#{@tab_bar} a[href="/feed"][aria-current="page"]))

      navigate_to(view, "/notifications")

      assert has_element?(view, ~s(#{@tab_bar} a[href="/notifications"][aria-current="page"]))
      refute has_element?(view, ~s(#{@tab_bar} a[href="/feed"][aria-current="page"]))
    end

    test "the Feed tab's back-to-top face travels with it", %{conn: conn} do
      view = shell(conn, insert(:user), %{"path" => "/notifications"})

      refute has_element?(view, ~s(a[data-scroll-top]))

      navigate_to(view, "/feed")

      # `data-scroll-top` is the server's statement that THIS tab points at the
      # page under the reader's thumb; assets/js/scroll_top_tab.js reads it.
      assert has_element?(view, ~s(#{@tab_bar} a[href="/feed"][data-scroll-top]))
    end

    test "arriving at /notifications zeroes that badge and leaving brings it back", %{conn: conn} do
      user = insert(:user)
      # One unread notification: somebody followed them.
      insert(:follow, follower: insert(:user), followee: user)

      view = shell(conn, user, %{"path" => "/feed"})
      assert has_element?(view, ~s(#{@tab_bar} a[href="/notifications"] span.bg-accent), "1")

      navigate_to(view, "/notifications")
      refute has_element?(view, ~s(#{@tab_bar} a[href="/notifications"] span.bg-accent))

      navigate_to(view, "/feed")
      assert has_element?(view, ~s(#{@tab_bar} a[href="/notifications"] span.bg-accent), "1")
    end

    test "a tab that could not patch from the old page can from the new one", %{conn: conn} do
      view = shell(conn, insert(:user), %{"path" => "/jobs"})

      refute has_element?(view, ~s(#{@tab_bar} a[href="/messages"][data-phx-link]))

      navigate_to(view, "/feed")

      assert has_element?(view, ~s(#{@tab_bar} a[href="/messages"][data-phx-link="redirect"]))
    end

    test "the brand link follows the path too", %{conn: conn} do
      user = insert(:user, username: "branded")
      view = shell(conn, user, %{"path" => "/notifications"})

      # Off /feed the wordmark is "home".
      assert has_element?(view, ~s(a[data-brand][href="/"]))

      navigate_to(view, "/feed")

      # On /feed it deep-links to the member's own profile instead.
      assert has_element?(view, ~s(a[data-brand][href="/branded"]))
    end
  end
end
