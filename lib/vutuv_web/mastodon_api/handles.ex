defmodule VutuvWeb.MastodonApi.Handles do
  @moduledoc """
  Turning a handle a client sent into the account it names.

  One owner for the whole grammar, because two endpoints ask the same question
  and would otherwise answer it differently: `GET /api/v2/search?resolve=true`
  and `GET /api/v1/accounts/lookup`. They differ in exactly one thing — whether
  a handle we have never seen may cost a WebFinger request — so that is the one
  thing this module splits (`resolve/2` may, `local/2` never does).

  Members and organization pages share one handle namespace here, so `@acme`
  names one of the two and never both; a page is also reachable by its slug,
  which is the address its canonical URL carries.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.MastodonApi
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization

  @doc """
  The account `query` names, resolving an unknown `@user@host` over the network.

  This is the search page's "resolve" behaviour, and the network call is the
  reason it is not the default anywhere else.
  """
  def resolve(conn, query), do: parse(conn, query, true)

  @doc """
  The account `query` names **without** ever leaving this installation.

  Mastodon's own `/api/v1/accounts/lookup` is defined as the WebFinger-free
  twin of search, and a client leans on it: it is what the compose window calls
  on every `@` it sees, so a version that reached out would spend somebody's
  hourly follow budget on typing. A handle on a host that is not ours therefore
  answers nothing here rather than being fetched.
  """
  def local(conn, query), do: parse(conn, query, false)

  defp parse(conn, "@" <> address, remote?), do: parse(conn, address, remote?)

  defp parse(conn, address, remote?) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [handle] -> local_account(conn, handle)
      [handle, host] -> qualified(conn, address, handle, String.downcase(host), remote?)
    end
  end

  defp parse(_conn, _query, _remote?), do: nil

  # `client_host?/1`, not a list of the two hosts we happen to think of: it also
  # answers for the `www.` alias, and serving a site at both the apex and its
  # `www.` name is the oldest convention on the web. Spelled out, the miss was
  # not a polite "unknown handle" — `@member@www.<our host>` fell through to the
  # remote branch, so this installation WebFingered **itself** over the network
  # and told the member their own site was unreachable.
  defp qualified(conn, address, handle, host, remote?) do
    cond do
      MastodonApi.client_host?(host) -> local_account(conn, handle)
      remote? -> remote_account(conn, address)
      true -> nil
    end
  end

  defp remote_account(conn, address) do
    subject = conn.assigns.current_organization || conn.assigns.current_user

    case Fediverse.resolve_remote_account(subject, "@" <> address) do
      {:ok, account} -> account
      _error -> nil
    end
  end

  defp local_account(conn, handle) do
    handle
    |> String.downcase()
    |> known_account()
    |> visible_to_identity(conn)
  end

  defp known_account(handle) do
    Accounts.get_user_by_username(handle) ||
      Organizations.get_organization_by_username(handle) ||
      Organizations.get_organization_by_slug(handle)
  end

  defp visible_to_identity(%User{} = user, conn) do
    viewer = if is_nil(conn.assigns.current_organization), do: conn.assigns.current_user
    if Moderation.profile_visible_to?(user, viewer), do: user
  end

  defp visible_to_identity(%Organization{} = organization, conn) do
    current_id = conn.assigns.current_organization && conn.assigns.current_organization.id

    if Organizations.public_visible?(organization) or current_id == organization.id,
      do: organization
  end

  defp visible_to_identity(nil, _conn), do: nil
end
