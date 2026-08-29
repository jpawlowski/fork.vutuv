defmodule VutuvWeb.Live.PullRefresh do
  @moduledoc """
  The one place that knows whether this browser can run the pull-to-refresh
  gesture (issue #1730).

  Pulling a list down is the most over-learned interaction on a phone, and its
  absence reads as breakage even when nothing is broken — content already
  arrives over PubSub, but no push channel can answer "have I seen
  everything?". The gesture answers it, and it answers it over the **existing
  socket**: the release pushes `pwa:refresh`, and whichever LiveView owns the
  list re-queries and re-streams it. Never `location.reload()`, which would
  throw away the LiveView and re-fetch the document — a refresh that costs more
  than the state it refreshes.

  Two gates decide whether the gesture appears at all, and both are deliberate.

  **The page has to want it.** A LiveView that does not implement
  `handle_event("pwa:refresh", …)` never renders the hook, so the gesture is
  never offered where it would do nothing. `PostLive.Feed`, `MessageLive.Index`
  and `NotificationLive.Index` implement it.

  **The bundle has to carry it.** A deploy reloads no open tab — it reconnects
  the socket into hours-old markup — so newly patched-in markup meets the
  *previous* release's JavaScript. `app.js` therefore sends `pull_refresh: true`
  as a connect param, and only a bundle that ships the `PullToRefresh` hook can
  send it, so the claim proves itself and cannot go stale. That is the same
  seam the feed's tab ticker uses, and for the same reason it is a capability
  the bundle asserts rather than `static_changed?/1`, which answers the wider
  question "is anything in this document older than the running release?" and
  therefore turns true after *every* asset deploy (v7.347.1 learned that the
  expensive way).

  Retire the param together with the hook.

  This is the only capability of its shape right now: the feed's tab ticker
  used the same seam for `feed_ticker` until v7.483.0 retired the source tabs
  and the hook with them. If a second one appears, fold both into a shared
  `BundleCapability` module rather than copying this file.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  @doc """
  Assigns `:pull_refresh?` — read it in the template as
  `phx-hook={@pull_refresh? && "PullToRefresh"}` on the element the gesture
  belongs to. Call it in `mount/3`; `get_connect_params/1` is only valid there,
  and answers `nil` on the dead render, which is correct: the throwaway static
  paint has no socket to push over anyway.
  """
  def assign_capability(socket) do
    assign(socket, :pull_refresh?, match?(%{"pull_refresh" => true}, get_connect_params(socket)))
  end
end
