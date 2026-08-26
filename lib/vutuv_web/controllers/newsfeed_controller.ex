defmodule VutuvWeb.NewsfeedController do
  @moduledoc """
  The **agent-format siblings** of the newsfeed — `/feed.md/.txt/.json/.xml`
  (`VutuvWeb.AgentDocs.FeedDoc`), the viewer's timeline in another format.
  (Named NewsfeedController, not FeedController, which already serves the RSS
  feeds.)

  The HTML page is not here: `/feed` is a real `live` route inside
  `live_session :default` (`VutuvWeb.PostLive.Feed`), so a bottom-tab press
  patches the content instead of rebuilding the document (issue #1731).
  `VutuvWeb.Plug.AgentRoute` is what keeps both at one URL — it dispatches the
  non-HTML representations here and lets HTML fall through to the LiveView.

  Unlike every other agent-format page these docs are **not** the anonymous
  public view: the feed is per-viewer and login-only. So an agent-format
  request without a signed-in viewer is a plain 404 (a private feed has no
  anonymous document and a `.md` URL must never serve HTML), and the doc is
  sent `private, no-store` + `noindex/noai` so a shared cache can never hand
  one member's feed to another.
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.FeedDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.PostLive.Feed

  # AgentRoute only dispatches here for a format the LiveView cannot answer, so
  # `negotiate/2` resolving to `:html` means the request reached this action by
  # some other path — a 404 rather than the HTML page, which the route owns.
  def index(conn, params) do
    case AgentDocs.negotiate(conn) do
      :html -> ControllerHelpers.render_error(conn, 404)
      format -> send_feed_doc(conn, format, params)
    end
  end

  defp send_feed_doc(conn, format, params) do
    case conn.assigns[:current_user] do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      viewer ->
        # A foreign/expired `?cursor=` falls back to the first page rather than
        # erroring: the worst case is re-showing the latest posts.
        cursor = ApiV2.cursor_or_nil(params)

        # One page of the document is one arrival on the HTML page
        # (`Feed.first_page_size/0` rather than a mirrored constant — a number
        # kept in step by a comment is a number that drifts). The size is all
        # the two share: the document is deliberately the WHOLE feed, with no
        # source filter, since it carries none of the switches the member has
        # over there and narrowing it by one they cannot see here would leave an
        # agent no way to ask for the rest.
        page = Posts.feed_page(viewer, limit: Feed.first_page_size(), cursor: cursor)
        AgentDocs.send_doc(conn, format, FeedDoc.build(viewer, page), cache: "private, no-store")
    end
  end
end
