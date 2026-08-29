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

  The event rides a topic of its own (`Screenshots.subscribe_draft_previews/1`),
  private to the one member writing the draft and deliberately not their
  `Vutuv.Activity` topic — see that function's neighbour `announce_ready/1` for
  why.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Vutuv.Posts.Screenshots
  alias VutuvWeb.PostLive.Composer

  def on_mount(:default, _params, _session, socket) do
    # The dead render is thrown away the moment the socket connects, so
    # subscribing for it would be a subscription nobody reads.
    if connected?(socket) and socket.assigns[:current_user] do
      Screenshots.subscribe_draft_previews(socket.assigns.current_user.id)
      {:cont, attach_hook(socket, :draft_preview, :handle_info, &forward/2)}
    else
      {:cont, socket}
    end
  end

  # The composer is asked to re-read, at the id it names for itself.
  defp forward({:draft_preview_ready, _draft_id}, socket) do
    send_update(Composer, id: Composer.dom_id(), refresh_link_preview: true)
    {:halt, socket}
  end

  defp forward(_other, socket), do: {:cont, socket}
end
