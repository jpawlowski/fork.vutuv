defmodule VutuvWeb.RemoteFollowController do
  @moduledoc """
  The profile's "Follow from your own server" button
  (`POST /:slug/fediverse/follow`).

  A visitor from Mastodon (or any other ActivityPub app) types the address of
  their own account; we resolve their server's follow dialog
  (`Vutuv.Fediverse.RemoteFollow`) and send them there with this member filled
  in, so the follow is confirmed where their account lives. Nothing is stored
  here and no credential ever reaches vutuv — the address is used for one
  lookup and then forgotten.

  It is the one outbound fetch an anonymous visitor can trigger, so it is
  fenced on three sides: the installation switch plus this member actually
  federating (the form is not even rendered otherwise, and a crafted POST is
  refused), a rate limit per IP, and the SSRF/size/timeout guards inside the
  resolver. Every failure lands back on the profile with a plain-language
  flash — the handle is on the page to copy, so there is always a way through.
  """

  use VutuvWeb, :controller

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteFollow
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.RateLimit

  # A lookup is cheap for us and slow for the server we ask, so the budget is
  # generous for a human and useless as a scanning gadget.
  @limit 20
  @window_ms :timer.hours(1)

  def create(conn, params) do
    user = conn.assigns[:user]
    address = params["address"] || ""

    cond do
      not followable?(user) ->
        conn
        |> put_flash(:error, gettext("This profile is not on the Fediverse."))
        |> back_to(user)

      RateLimit.check(conn, :remote_follow, nil, limit: @limit, window_ms: @window_ms) ==
          :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> back_to(user)

      true ->
        resolve(conn, user, address)
    end
  end

  defp resolve(conn, user, address) do
    case RemoteFollow.subscribe_url(address, Docs.acct(user)) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, reason} ->
        conn
        |> put_flash(:error, message(reason, address))
        |> back_to(user)
    end
  end

  # Same gate the profile card renders on: a member who moved their Fediverse
  # account away is followed at the new address, not here.
  defp followable?(user), do: Fediverse.federated?(user) and not Fediverse.moved?(user)

  # Each message names what to do next, never just what failed.
  defp message(:invalid_address, _address) do
    gettext("That is not a Fediverse address. It looks like @you@example.social.")
  end

  defp message(:no_remote_follow, address) do
    gettext(
      "%{server} did not offer a follow dialog. Copy the handle above and paste it into your app's search instead.",
      server: server_name(address)
    )
  end

  defp message(_unreachable, address) do
    gettext(
      "%{server} did not answer. Copy the handle above and paste it into your app's search instead.",
      server: server_name(address)
    )
  end

  # The typed host, echoed back so the message names the server the visitor
  # meant — but only once it parsed, so nothing unvalidated reaches the page.
  defp server_name(address) do
    case RemoteFollow.parse_address(address) do
      {:ok, {_user, host}} -> host
      _ -> gettext("Your server")
    end
  end

  defp back_to(conn, user), do: redirect(conn, to: ~p"/#{user}" <> "#profile-fediverse")
end
