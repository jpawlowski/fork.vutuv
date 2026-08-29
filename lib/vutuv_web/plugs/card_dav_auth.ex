defmodule VutuvWeb.Plug.CardDavAuth do
  @moduledoc """
  HTTP Basic authentication for the CardDAV address book (issue #1705), with a
  personal access token as the password.

  **Never the account password.** A CardDAV client stores what it is given, on
  the device, forever — that is how the protocol works — so what it is given
  must be revocable on its own: a token minted at `/settings/apps`, carrying
  `contacts:read` and nothing else, killable per device without touching the
  account. It is the same credential and the same `Vutuv.ApiAuth.verify_token/1`
  the JSON API uses, so a revoked token stops the phone on its next poll.

  **The username field is not checked.** Every client insists on one, so the
  settings page tells members to type their handle, but the token is the whole
  credential: comparing a stored handle against a member who has since renamed
  would fail every device at once for no security gained.

  A 401 carries `WWW-Authenticate: Basic`, which is what makes a client offer
  its stored password instead of giving up.

  **The realm is a constant, and must stay one.** It was derived from
  `Endpoint.url()` — which reads right until you remember that a client stores
  its password per *protection space*: host, port, realm, scheme. A member
  reaching the site under any name other than the configured one (`www.`, an
  installation's second hostname, a LAN address in development) then gets a
  challenge whose realm belongs to a different host, finds no credential that
  matches it, and — being a background daemon with nobody to ask — stops. No
  error, no prompt, no retry: macOS Contacts simply reported "account
  verification failed" while never once sending an `Authorization` header
  (observed 2026-08-26). The realm is a label inside *our* protection space; it
  has no business naming a host.

  `charset` is deliberately absent too: RFC 7617 allows it and every credential
  here is a base64url token, so it buys nothing and only gives a strict parser
  something extra to trip over.
  """

  @behaviour Plug

  import Plug.Conn

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.Scopes
  alias Vutuv.CardDav
  alias VutuvWeb.Gettext, as: WebGettext
  alias VutuvWeb.Plug.Locale

  @scope "contacts:read"
  # Host-independent on purpose — see the moduledoc.
  @realm "vutuv"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if CardDav.enabled?() do
      authenticate(conn)
    else
      conn |> send_resp(404, "") |> halt()
    end
  end

  defp authenticate(conn) do
    with {:ok, password} <- basic_password(conn),
         {:ok, token, user} <- ApiAuth.verify_token(password),
         true <- Scopes.granted?(token.scopes, @scope),
         # A member who has switched the address book off has no collection at
         # all, token or no token — the setting is the gate, and a token minted
         # before they switched it off must not outlive that decision.
         true <- CardDav.publishing?(user) do
      # There is no Locale plug on this pipeline — no session, no Accept-Language
      # worth trusting from a sync client — but the address book's name and
      # description are shown in the member's Contacts app, so they follow the
      # member's own interface language rather than the installation default.
      Gettext.put_locale(WebGettext, supported_locale(user.locale))
      assign(conn, :current_user, user)
    else
      _refused -> unauthorized(conn)
    end
  end

  # The same fallback `VutuvWeb.Plug.Locale` applies: an unsupported value
  # renders English rather than being handed to Gettext as a dead locale.
  defp supported_locale(locale) do
    if Locale.locale_supported?(locale), do: locale, else: "en"
  end

  # `Plug.BasicAuth.parse_basic_auth/1` is the same header walk (RFC 7617), and
  # this is the one unauthenticated entry point of the feature — not the place
  # to keep a hand-maintained parser beside the one Plug already ships.
  # The username is deliberately unused; see the moduledoc.
  defp basic_password(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_username, password} -> {:ok, password}
      :error -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="#{@realm}"))
    |> send_resp(401, "")
    |> halt()
  end
end
