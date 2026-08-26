defmodule VutuvWeb.Live.DraftPreview do
  @moduledoc """
  Makes the link preview in the composer appear by itself once the fetch behind
  it lands (issue #1714).

  `VutuvWeb.PostLive.Composer` draws that card, and a LiveComponent has no
  process of its own — a subscription made inside one would land its messages in
  the host LiveView's `handle_info/2`, which most of the hosts never wrote. So
  the listening happens once **per page**, here, and the composer is told by
  component id. Exactly the arrangement `VutuvWeb.Live.RemoteCounts` uses for
  the remote action bar, and for the same reason: five hosts (the feed, the
  reply page, the two remote-reply pages, the edit page) and a clause missing
  from one is invisible — that composer simply never stops saying "Fetching".

  `attach_hook/4` is what makes this cheap for the hosts that have no
  `handle_info/2` at all: the hook runs before the LiveView's own clauses and
  halts on its own message, so a page opts in with one line and handles nothing.

  The event rides a **topic of its own** (`Screenshots.draft_preview_topic/1`),
  private to the one member writing the draft — nobody else has any business
  hearing about an unpublished post. Deliberately not their `Vutuv.Activity`
  topic, even though that is also private to them: `VutuvWeb.PostLive.Feed`
  already subscribes to it, and `Phoenix.PubSub.subscribe/2` is a bare register
  on a duplicate registry, so a second subscription here would hand the busiest
  LiveView in the app two copies of every unrelated activity event — each
  costing a full `get_post/1` preload chain. A topic nobody else holds cannot
  be double-subscribed by a future host either.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Vutuv.Posts.Screenshots
  alias VutuvWeb.PostLive.Composer

  def on_mount(:default, _params, _session, socket) do
    # The dead render is thrown away the moment the socket connects, so
    # subscribing for it would be a subscription nobody reads.
    if connected?(socket) and socket.assigns[:current_user] do
      Phoenix.PubSub.subscribe(
        Vutuv.PubSub,
        Screenshots.draft_preview_topic(socket.assigns.current_user.id)
      )

      {:cont, attach_hook(socket, :draft_preview, :handle_info, &forward/2)}
    else
      {:cont, socket}
    end
  end

  # The composer is asked to re-read. Its id comes from the component that owns
  # it rather than being spelled here: a host rendering it under another id
  # would otherwise get a card that never stops saying "Fetching", with no
  # error anywhere.
  defp forward({:draft_preview_ready, _draft_id}, socket) do
    send_update(Composer, id: Composer.dom_id(), refresh_link_preview: true)
    {:halt, socket}
  end

  defp forward(_other, socket), do: {:cont, socket}
end
