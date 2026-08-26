defmodule VutuvWeb.Plug.AgentRoute do
  @moduledoc """
  Lets a **`live` route** keep the agent-format siblings a controller used to
  negotiate (`VutuvWeb.AgentDocs`), so a page can be both.

  A public page needs `/feed.md`, `/feed.json` and friends, and
  `AgentDocs.respond/2` is driven from a conn — which is why those pages were
  routed to a controller that `live_render`ed the real LiveView. A route that is
  not a `live` route cannot be in a `live_session`, and `<.link navigate>` only
  patches *within* one session, so every one of those pages cost a full document
  on arrival (issue #1731).

  This plug separates the *format* from the *page*. The route is declared `live`
  and names its old controller in the route's `:private` map:

      live("/feed", PostLive.Feed, :index,
        private: %{vutuv_agent_route: {NewsfeedController, :index}})

  Phoenix merges a route's `:private` into the conn **before** the pipeline runs
  (`Phoenix.Router.Route.build_prepare/1`), together with the path params, so by
  the time this plug sees the request it knows both. It then splits the request
  in two:

    * a **non-HTML** representation — an agent format by URL extension or
      `Accept` (`VutuvWeb.Plug.AgentFormat`), or an ActivityPub request — is
      dispatched straight to the named controller action and halts, exactly as
      if the route had never changed;
    * an **HTML** request falls through to `Phoenix.LiveView.Plug`, with the
      `<link rel="alternate">` head tags and `Vary: accept` this plug puts there
      in the controller's place (`AgentDocs.put_html_alternates/1` — the one
      thing the retired `show_html` branch did besides rendering).

  Last in the `:browser` pipeline, so the dispatched controller sees everything
  a controller route would have: session, viewer, acting-as identity and locale.
  """

  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.FediverseController
  alias VutuvWeb.Plug.AgentFormat

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{private: %{vutuv_agent_route: {controller, action}}} = conn, _opts) do
    if machine_request?(conn) do
      conn |> hand_over() |> controller.call(controller.init(action)) |> halt()
    else
      AgentDocs.put_html_alternates(conn)
    end
  end

  def call(conn, _opts), do: conn

  # Everything the LiveView cannot answer: the agent documents (.md/.txt/.json/
  # .xml/.vcf, or the matching Accept header) and the ActivityPub representation
  # a remote server asks for at the same URL.
  #
  # **The ActivityPub half fixes one page of a bug that is not this page's.**
  # The `:browser` pipeline accepts `activity+json`, so the format survives
  # negotiation and reaches the router on the conn; no LiveView has a template
  # for it, so `Plug.Conn.resp/3` is handed a `{:safe, iodata}` body and raises
  # with no matching clause. That is a 500 on **every** `live_render` page, not
  # a consequence of routing `/feed` as `live` — measured on `/organizations`,
  # which this change never touches and which raises identically. (`ld+json`
  # answers a clean 406, because it is not in that `accepts` list.)
  #
  # It is answered here rather than left alone because the answer is already
  # wired up: this route names a controller that negotiates formats, so one
  # predicate turns the raise into the 404 a private timeline deserves. It is
  # not the class-wide fix, and nothing here should be read as one — that is
  # issue #1776, and it belongs in `:accepts` or in the render, above every
  # page that has this shape.
  defp machine_request?(conn) do
    AgentFormat.agent_format?(conn) or FediverseController.ap_request?(conn)
  end

  # The route's `:private` also carries `:phoenix_live_view`, which is how
  # `Phoenix.LiveView.Static` recognises a request as belonging to a
  # `live_session` — including for a LiveView merely *embedded* in whatever the
  # response renders. Leaving it on hands the shared `app` layout's ShellLive
  # the session's `on_mount` hooks, and `InitAssigns` attaches a
  # `:handle_params` hook, which LiveView refuses for a view that was not
  # mounted at the router: a 404 error page raised instead of rendering. This
  # request is not being served by the live route any more, so its mark comes
  # off with it.
  defp hand_over(conn), do: %{conn | private: Map.delete(conn.private, :phoenix_live_view)}
end
