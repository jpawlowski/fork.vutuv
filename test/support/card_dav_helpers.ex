defmodule Vutuv.CardDavHelpers do
  @moduledoc """
  The fixtures every CardDAV request test needs: a member who publishes, a
  token that may read contacts, the Basic-auth dispatch and the collection's
  URL layout.

  Three test files carried their own copy of all four. The paths are the worst
  of it — they are what a client follows, so a route rename has to be caught
  somewhere, and it will not be caught by four hand-written literals agreeing
  with each other by luck.
  """

  alias Vutuv.ApiAuth

  @doc "A personal access token with the `contacts:read` scope, minted for `user`."
  def carddav_token!(user, token) do
    Vutuv.Factory.insert(:api_token,
      user: user,
      scopes: ["contacts:read"],
      token_hash: ApiAuth.hash_token(token)
    )

    token
  end

  @doc """
  Dispatches a CardDAV request with Basic auth.

  The username is deliberately arbitrary — the server does not check it (see
  `VutuvWeb.Plug.CardDavAuth`), and a test that passed a real handle would
  quietly assert the opposite. `Phoenix.ConnTest` insists on a content-type
  whenever a binary body is set, even the empty one a PROPFIND may send.

  No default arguments: every caller wraps this in its own two- or three-arity
  `dav`, and a default here would generate an arity that clashes with theirs.
  """
  def dav(conn, endpoint, method, path, body, opts) do
    token = Keyword.fetch!(opts, :token)
    type = Keyword.get(opts, :content_type, "text/xml")

    conn
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("device:" <> token))
    |> Plug.Conn.put_req_header("content-type", type)
    |> Phoenix.ConnTest.dispatch(endpoint, method, path, body)
  end

  @doc "The collection's URL layout, in one place rather than four."
  def principal_path(owner), do: "/system/carddav/p/#{owner.id}/"
  def home_path(owner), do: "/system/carddav/a/#{owner.id}/"
  def collection_path(owner), do: "/system/carddav/a/#{owner.id}/contacts/"
  def card_path(owner, contact), do: collection_path(owner) <> "#{contact.id}"
  def push_path(owner, id), do: collection_path(owner) <> "push/#{id}"
end
