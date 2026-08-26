defmodule VutuvWeb.Live.ShellNav do
  @moduledoc """
  Tells the **sticky** `VutuvWeb.ShellLive` which page the browser tab is on
  after a live navigation.

  `sticky: true` is what keeps the shell — its badges, its PubSub
  subscriptions, its presence tracking — alive while the page under it is
  replaced (issue #1731). The price is that the shell no longer re-mounts, so
  the `"path"` its mount session carried is frozen at the document's first load,
  and everything that reads it (the active-tab highlight, the "back to top" Feed
  tab, `brand_path`, the badge the arrived-at page must zero) would go stale on
  the first tab press.

  Nothing hands one LiveView's `handle_params` to another, so the two talk over
  PubSub on a topic scoped to the **browser tab**: `socket.transport_pid` is the
  websocket process, shared by every LiveView on one page and by nobody else, so
  a member reading vutuv in two tabs never has one tab's navigation move the
  other's highlight. Being one process it is also always on this node, which is
  what `local_broadcast/3` says out loud and a cluster-wide `broadcast/3` would
  not.

  Only live navigation needs this. A full document load re-mounts the shell with
  a fresh `"path"`, and a dead render has no transport at all — both sides are
  therefore no-ops until the socket is connected.
  """

  alias Phoenix.LiveView

  @doc "The sticky shell subscribes to its own browser tab's navigations."
  def subscribe(%LiveView.Socket{} = socket) do
    if LiveView.connected?(socket), do: Phoenix.PubSub.subscribe(Vutuv.PubSub, topic(socket))
    :ok
  end

  @doc """
  Announces the page this socket just navigated to, and as far as possible only
  then. Call it **before** assigning the new `:shell_path`, which is where the
  previous one is read from.

  The `VutuvWeb.Live.InitAssigns` `:default` hook calls this from every
  `handle_params`, which is more often than a navigation: a page patching its
  own URL (the notifications pager, a message thread) runs one too, and those
  are what the comparison drops.

  One case gets through: the first `handle_params` after a connected mount has
  no previous path, so a plain full page load still sends one message for a
  path the shell mounted with. The shell recognises it (nothing it derives from
  the path changes, so nothing re-renders) and it is one message per document,
  not per patch — cheap enough not to be worth a second source of truth for
  "where did this socket start".
  """
  def broadcast_path(%LiveView.Socket{} = socket, path) when is_binary(path) do
    if LiveView.connected?(socket) and socket.assigns[:shell_path] != path do
      Phoenix.PubSub.local_broadcast(Vutuv.PubSub, topic(socket), {:shell_path, path})
    end

    socket
  end

  @doc """
  The topic one browser tab's shell listens on. Public so a test can play the
  part of the arriving page (`Phoenix.LiveView.Debug.list_liveviews/0` reports
  the transport pid) without a second copy of the string.
  """
  def topic(%LiveView.Socket{transport_pid: pid}), do: topic(pid)
  def topic(transport_pid) when is_pid(transport_pid), do: "shell_nav:#{inspect(transport_pid)}"
end
