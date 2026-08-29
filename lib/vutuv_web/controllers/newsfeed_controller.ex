defmodule VutuvWeb.NewsfeedController do
  @moduledoc """
  The **agent-format siblings** of the signed-in member's newsfeed —
  `/feed.md/.txt/.json/.xml` (`VutuvWeb.AgentDocs.FeedDoc`), the viewer's
  timeline in another format. (Named NewsfeedController, not FeedController,
  which already serves the RSS feeds.)

  It has no route of its own any more, and that is the point of issue #1731.
  `/feed`'s HTML is now `live("/feed", VutuvWeb.PostLive.Feed, :index)` inside
  `live_session :default`, so switching to it from Messages, Notifications or
  Search patches the content instead of rebuilding the document — which a route
  behind a controller could never do, a non-`live` route not being allowed in a
  `live_session`. The format negotiation that used to justify the controller
  moved into the pipeline (`VutuvWeb.Plug.AgentDocRoute`), which calls
  `send_doc/2` below for an extension or `Accept` request and lets an ordinary
  browser request fall through to the LiveView.

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

  @doc """
  Sends the feed as `format`. Called by `VutuvWeb.Plug.AgentDocRoute` from the
  `/feed` pipeline, not dispatched by the router — the browser pipeline has
  already run, so `conn.assigns[:current_user]` is the viewer it always was.
  """
  def send_doc(conn, format) do
    case conn.assigns[:current_user] do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      viewer ->
        # A foreign/expired `?cursor=` falls back to the first page rather than
        # erroring: the worst case is re-showing the latest posts.
        cursor = ApiV2.cursor_or_nil(conn.params)

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
