defmodule VutuvWeb.CardDavController do
  @moduledoc """
  The CardDAV address book (issue #1705): the contacts a member publishes,
  served to their phone, their Mac or their Thunderbird.

  `Vutuv.CardDav` owns which cards exist and what they contain; this module
  only speaks the protocol. CardDAV is RFC 6352 — there is one version of it,
  and this is it. The pieces implemented here are the ones a real client walks
  through:

    * `/.well-known/carddav` → the service root (RFC 6764), so a member types
      only the site's address into their phone.
    * `PROPFIND` down the chain service → principal → home → collection, which
      is how a client finds the address book without being told a URL.
    * `REPORT addressbook-multiget` (fetch these cards) and `REPORT
      sync-collection` (RFC 6578: what changed since this token, **including
      what is gone**).
    * `GET` on a card, with an `ETag` so a poll that changed nothing transfers
      nothing.

  **Read-only, and it says so in the protocol.** `current-user-privilege-set`
  (RFC 3744) advertises `DAV:read` alone, which is what makes macOS Contacts
  grey the account out rather than let a member type into a card that will
  bounce; every write method answers 403 with `need-privileges` behind that.
  Per-property write is not something CardDAV can express — its unit is the
  whole card — so a writable `NOTE` would mean taking a client's `PUT`, keeping
  one property and silently discarding the rest of its edits. Notes are edited
  on vutuv.

  **The URLs carry member ids, not handles.** A member who renames their
  account would otherwise find the address book they configured months ago
  answering 404 on every device at once.

  **Known simplification:** `addressbook-query` answers with the whole
  collection rather than evaluating the filter. Clients use that report to
  search, and a superset is an answer they can filter themselves while a wrong
  subset is not. The two reports that carry the synchronisation — multiget and
  sync-collection — are exact.

  **WebDAV-Push** (the DAVx⁵ draft) is served on top: the collection advertises
  a `transports` / `topic` / `supported-triggers` trio, a client `POST`s a
  `push-register` document to the collection and `DELETE`s the registration URL
  it gets back, and `Vutuv.CardDav` sends the notification over ordinary Web
  Push. That transport is the client's own push service and this
  installation's self-signed VAPID key — no certificate, no third party. Note
  that iOS and macOS Contacts honour a *different* push extension, Apple's own
  over APNS, which needs a certificate no third-party server can obtain; an
  iPhone therefore stays on polling however much push we serve here.

  Authentication is HTTP Basic with a personal access token as the password
  (`VutuvWeb.Plug.CardDavAuth`), never the account password.
  """

  use VutuvWeb, :controller

  alias Vutuv.CardDav
  alias Vutuv.WebPush
  alias VutuvWeb.CardDav.Xml
  alias VutuvWeb.Endpoint
  alias VutuvWeb.UserHelpers

  # vCard 3.0 (RFC 2426) is what CardDAV mandates and what every client reads;
  # `VutuvWeb.AgentDocs.VCard` renders exactly that. vCard 4.0 is deliberately
  # NOT advertised — announcing a format we do not produce is a lie a client
  # acts on.
  @vcard_type "text/vcard"
  @vcard_version "3.0"
  @max_resource_size 1_000_000

  # ── Discovery ──

  @doc """
  RFC 6764: `/.well-known/carddav` is the one URL a member should ever have to
  type. A **GET** — a browser, a curious human — is answered with the 301 the
  spec suggests.

  A client's `PROPFIND` is not: it is served in place by `service/2` (see the
  router). iOS follows the redirect, meets the 401 at the redirected location,
  and gives up instead of retrying there — so the challenge has to be at the
  URL the client asked about.
  """
  def well_known(conn, _params) do
    # 301, the code RFC 6764 asks for: a client is meant to remember where the
    # service lives rather than ask again on every sync.
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/system/carddav/")
  end

  # ── OPTIONS: the capability handshake every client starts with ──

  def options(conn, _params) do
    conn
    |> dav_headers()
    # POST is here for the WebDAV-Push registration only; nothing else on this
    # collection accepts a write.
    |> put_resp_header("allow", "OPTIONS, GET, HEAD, PROPFIND, REPORT, POST")
    |> send_resp(200, "")
  end

  # ── PROPFIND down the discovery chain ──

  # The service root. Its one job is to name the principal; a client that
  # landed on /.well-known/carddav asks exactly this and follows the answer.
  def service(conn, _params) do
    user = conn.assigns.current_user
    # The href is the URL the client actually asked about: this action answers
    # both `/system/carddav/` and `/.well-known/carddav` (see the router), and
    # a multistatus whose href names a different resource than the request is
    # the kind of thing a client is entitled to distrust.
    propfind(conn, [{conn.request_path, resource_props(user, :service, 0)}])
  end

  def principal(conn, _params) do
    user = conn.assigns.current_user
    propfind(conn, [{principal_path(user), resource_props(user, :principal, 0)}])
  end

  # The home set. Depth 1 lists the one address book inside it.
  def home(conn, _params) do
    user = conn.assigns.current_user
    revision = CardDav.revision(user)

    entries =
      case depth(conn) do
        "0" ->
          [{home_path(user), resource_props(user, :home, revision)}]

        _deeper ->
          [
            {home_path(user), resource_props(user, :home, revision)},
            {collection_path(user), resource_props(user, :addressbook, revision)}
          ]
      end

    propfind(conn, entries)
  end

  # The address book itself. Depth 1 is a client's non-sync way of listing it,
  # so the collection is brought up to date first — the same refresh the sync
  # report runs.
  def collection(conn, _params) do
    user = conn.assigns.current_user
    snapshot = CardDav.snapshot(user)

    collection_entry =
      {collection_path(user), resource_props(user, :addressbook, snapshot.revision)}

    entries =
      case depth(conn) do
        "0" ->
          [collection_entry]

        _deeper ->
          [collection_entry] ++
            Enum.map(snapshot.cards, fn card ->
              {card_path(user, card.contact_id), card_properties(card)}
            end)
      end

    propfind(conn, entries)
  end

  def card_propfind(conn, %{"card" => contact_id}) do
    user = conn.assigns.current_user

    case CardDav.entry(user, contact_id) do
      {:ok, _entry, card} ->
        propfind(conn, [{card_path(user, contact_id), card_properties(card)}])

      :error ->
        not_found(conn)
    end
  end

  # ── GET: one card ──

  def card(conn, %{"card" => contact_id}) do
    user = conn.assigns.current_user

    case CardDav.entry(user, contact_id) do
      {:ok, entry, card} ->
        conn
        |> put_resp_header("etag", quoted(card.etag))
        |> put_resp_content_type(@vcard_type)
        |> send_resp(200, CardDav.render_card(entry, rev: card.updated_at))

      :error ->
        not_found(conn)
    end
  end

  # ── REPORT ──

  def report(conn, _params) do
    {:ok, body, conn} = read_body(conn)
    user = conn.assigns.current_user

    # The type is read first: building the snapshot means refreshing and
    # rendering the whole book, which a report we are about to refuse with a
    # 400 has no use for.
    # Each branch fetches what it needs: the sync report answers from
    # `changes_since/2` and has no use for the card rows, and a report we are
    # about to refuse has no use for either.
    case Xml.report_type(body) do
      :unsupported ->
        send_resp(conn, 400, "")

      :sync_collection ->
        book = CardDav.book(user)
        sync_report(conn, user, book, body, Xml.requested_props(body))

      :multiget ->
        multiget_report(conn, user, CardDav.snapshot(user), body, Xml.requested_props(body))

      :query ->
        data_report(conn, user, CardDav.snapshot(user), Xml.requested_props(body))
    end
  end

  # RFC 6578. Three answers in one document: added and changed cards carry
  # their properties, and a card that is gone carries a bare 404 — which is the
  # only way an unfollowed contact ever leaves a phone.
  defp sync_report(conn, user, book, body, requested) do
    with {:ok, since} <- CardDav.parse_sync_token(Xml.sync_token(body)),
         {:ok, rows, revision} <- CardDav.changes_since(user, since, book.revision) do
      entries = Enum.map(rows, &sync_entry(user, book.entries, &1, requested))
      multistatus(conn, entries, sync_token: CardDav.sync_token(revision))
    else
      _invalid -> invalid_sync_token(conn)
    end
  end

  # A tombstone is reported as a bare 404 on its href — the answer that makes
  # the client delete the card locally.
  defp sync_entry(user, _entries, %{deleted: true} = row, _requested),
    do: Xml.status_response(card_path(user, row.contact_id), "404 Not Found")

  defp sync_entry(user, entries, row, requested),
    do: card_response(user, entries, row, requested)

  defp multiget_report(conn, user, snapshot, body, requested) do
    wanted =
      body
      |> Xml.hrefs()
      |> Enum.map(&card_id_from_href/1)
      |> Enum.reject(&is_nil/1)

    held = Map.new(snapshot.cards, &{&1.contact_id, &1})
    {found, missing} = Enum.split_with(wanted, &Map.has_key?(held, &1))

    entries =
      Enum.map(found, &card_response(user, snapshot.entries, Map.fetch!(held, &1), requested)) ++
        Enum.map(missing, &Xml.status_response(card_path(user, &1), "404 Not Found"))

    multistatus(conn, entries, [])
  end

  defp data_report(conn, user, snapshot, requested) do
    multistatus(
      conn,
      Enum.map(snapshot.cards, &card_response(user, snapshot.entries, &1, requested)),
      []
    )
  end

  # One card in a report: its stored properties plus, when the client asked for
  # it, the card itself. `address-data` is the only property that costs a
  # render, so it is built only when requested.
  defp card_response(user, entries, card, requested) do
    available =
      case Map.get(entries, card.contact_id) do
        nil ->
          card_properties(card)

        entry ->
          card_properties(card) ++
            [
              {"address-data",
               fn ->
                 data = CardDav.render_card(entry, rev: card.updated_at)
                 "<C:address-data>#{Xml.escape(data)}</C:address-data>"
               end}
            ]
      end

    {found, missing} = select_props(requested, available)
    Xml.response(card_path(user, card.contact_id), found, missing)
  end

  # ── WebDAV-Push registration ──

  @doc """
  A device asks to be told when this book changes: `POST` of a
  `push-register` document to the collection (the DAVx⁵ WebDAV-Push draft).

  Answers 201 with the `Location` of the registration — which is the URL the
  device later `DELETE`s — and the `Expires` this server actually granted,
  which may be sooner than the one it asked for.
  """
  def push_register(conn, _params) do
    {:ok, body, conn} = read_body(conn)
    user = conn.assigns.current_user

    with :ok <- push_available(),
         :ok <- supported_trigger(body),
         :ok <- supported_encoding(body),
         {:ok, attrs} <- push_attrs(body),
         {:ok, subscription} <- CardDav.register_push(user, attrs) do
      conn
      |> put_resp_header("location", push_url(user, subscription.id))
      |> put_resp_header("expires", Xml.http_date(subscription.expires_at))
      |> send_resp(201, "")
    else
      {:error, condition} when is_binary(condition) -> error(conn, condition)
      # A changeset error means the device sent something we will not store —
      # an endpoint pointing inside the network, an unusable key. That is
      # `invalid-subscription` in the draft's vocabulary, and saying so beats a
      # 422 the client has no rule for.
      {:error, %Ecto.Changeset{}} -> error(conn, "invalid-subscription")
    end
  end

  @doc "The device drops its own registration again."
  def push_unregister(conn, %{"registration" => id}) do
    user = conn.assigns.current_user

    case CardDav.get_push_subscription(user, id) do
      nil ->
        not_found(conn)

      subscription ->
        {:ok, _deleted} = CardDav.unregister_push(subscription)
        send_resp(conn, 204, "")
    end
  end

  defp push_available do
    if CardDav.push_enabled?(), do: :ok, else: {:error, "push-not-available"}
  end

  # The draft lets a client name the triggers it wants. This collection only
  # ever has one thing to report — its contents changed — so a device asking
  # exclusively for property updates is told so rather than registered for a
  # notification that would never arrive.
  defp supported_trigger(body) do
    cond do
      not Xml.element?(body, "trigger") -> :ok
      Xml.element?(body, "content-update") -> :ok
      true -> {:error, "no-supported-trigger"}
    end
  end

  # Our sender encrypts with aes128gcm (RFC 8291) and nothing else, so a device
  # asking for the older aesgcm is refused here rather than handed messages it
  # cannot decrypt.
  defp supported_encoding(body) do
    case Xml.element_text(body, "content-encoding") do
      nil -> :ok
      "aes128gcm" -> :ok
      _other -> {:error, "invalid-subscription"}
    end
  end

  defp push_attrs(body) do
    with resource when is_binary(resource) <- Xml.element_text(body, "push-resource"),
         key when is_binary(key) <- Xml.element_text(body, "subscription-public-key"),
         secret when is_binary(secret) <- Xml.element_text(body, "auth-secret") do
      {:ok,
       %{
         push_resource: resource,
         p256dh: key,
         auth_secret: secret,
         expires_at: Xml.parse_http_date(Xml.element_text(body, "expires"))
       }}
    else
      _incomplete -> {:error, "invalid-subscription"}
    end
  end

  # Absolute, because the draft asks for an absolute registration URL. Composed
  # on `collection_path/1` rather than spelled again: a device stores this URL
  # and comes back to it with DELETE, so the two must agree by construction.
  defp push_url(user, id), do: Endpoint.url() <> collection_path(user) <> "push/#{id}"

  # ── Writes ──

  @doc """
  Every write method, refused in one place. 403 with `need-privileges` is the
  answer RFC 3744 defines for "you may read this and nothing more", and it is
  what `current-user-privilege-set` already advertised.
  """
  def read_only(conn, _params) do
    error(conn, "need-privileges")
  end

  # ── Properties ──

  defp resource_props(user, kind, revision) do
    principal = principal_path(user)

    common = [
      {"current-user-principal", href_prop("current-user-principal", principal)},
      {"principal-URL", href_prop("principal-URL", principal)},
      {"owner", href_prop("owner", principal)},
      {"current-user-privilege-set",
       "<D:current-user-privilege-set><D:privilege><D:read/></D:privilege>" <>
         "</D:current-user-privilege-set>"}
    ]

    kind_props(kind, user, revision) ++ common
  end

  defp kind_props(:service, _user, _revision) do
    [{"resourcetype", "<D:resourcetype><D:collection/></D:resourcetype>"}]
  end

  defp kind_props(:principal, user, _revision) do
    [
      {"resourcetype", "<D:resourcetype><D:collection/><D:principal/></D:resourcetype>"},
      {"displayname", text_prop("D", "displayname", UserHelpers.full_name(user))},
      {"addressbook-home-set", carddav_href_prop("addressbook-home-set", home_path(user))}
    ]
  end

  defp kind_props(:home, user, _revision) do
    [
      {"resourcetype", "<D:resourcetype><D:collection/></D:resourcetype>"},
      {"displayname", text_prop("D", "displayname", UserHelpers.full_name(user))},
      {"addressbook-home-set", carddav_href_prop("addressbook-home-set", home_path(user))}
    ]
  end

  defp kind_props(:addressbook, user, revision) do
    token = CardDav.sync_token(revision)

    [
      {"resourcetype", "<D:resourcetype><D:collection/><C:addressbook/></D:resourcetype>"},
      {"displayname", text_prop("D", "displayname", gettext("vutuv contacts"))},
      # Apple's collection tag, which predates RFC 6578 and is still the first
      # thing macOS Contacts compares. Same value as the sync token: both mean
      # "the state of this collection".
      {"getctag", text_prop("CS", "getctag", token)},
      {"sync-token", text_prop("D", "sync-token", token)},
      {"supported-report-set", supported_report_set()},
      {"supported-address-data",
       ~s(<C:supported-address-data><C:address-data-type content-type="#{@vcard_type}") <>
         ~s( version="#{@vcard_version}"/></C:supported-address-data>)},
      {"max-resource-size", text_prop("C", "max-resource-size", @max_resource_size)},
      {"addressbook-description",
       text_prop("C", "addressbook-description", gettext("The contacts you follow on vutuv."))}
    ] ++ push_props(user)
  end

  # WebDAV-Push, advertised only where it can actually be served: the property
  # trio is absent when Web Push is off, so a client is never told about a
  # transport that would refuse its registration.
  defp push_props(user) do
    if CardDav.push_enabled?() do
      [
        {"transports",
         ~s(<P:transports><P:web-push><P:vapid-public-key type="p256ecdsa">) <>
           Xml.escape(WebPush.public_key()) <>
           "</P:vapid-public-key></P:web-push></P:transports>"},
        {"topic", text_prop("P", "topic", CardDav.topic(user))},
        # Only `content-update`, and at depth 1: what changes here is which
        # cards the collection holds and what is in them. The collection's own
        # properties (its name, its owner) do not change under a member.
        {"supported-triggers",
         "<P:supported-triggers><P:content-update><D:depth>1</D:depth>" <>
           "</P:content-update></P:supported-triggers>"}
      ]
    else
      []
    end
  end

  defp card_properties(card) do
    [
      {"getetag", "<D:getetag>#{quoted(card.etag)}</D:getetag>"},
      {"getcontenttype", text_prop("D", "getcontenttype", "#{@vcard_type}; charset=utf-8")},
      {"resourcetype", "<D:resourcetype/>"},
      {"getlastmodified", text_prop("D", "getlastmodified", Xml.http_date(card.updated_at))}
    ]
  end

  defp supported_report_set do
    reports = ["<D:sync-collection/>", "<C:addressbook-multiget/>", "<C:addressbook-query/>"]

    inner =
      Enum.map_join(reports, "", fn report ->
        "<D:supported-report><D:report>#{report}</D:report></D:supported-report>"
      end)

    "<D:supported-report-set>#{inner}</D:supported-report-set>"
  end

  defp href_prop(name, path), do: "<D:#{name}><D:href>#{Xml.escape(path)}</D:href></D:#{name}>"

  defp carddav_href_prop(name, path),
    do: "<C:#{name}><D:href>#{Xml.escape(path)}</D:href></C:#{name}>"

  defp text_prop(ns, name, value),
    do: "<#{ns}:#{name}>#{Xml.escape(value)}</#{ns}:#{name}>"

  # ── Plumbing ──

  # One PROPFIND answer: every entry keeps the properties the client asked for
  # and is told, per resource, which of the names it sent do not exist there.
  defp propfind(conn, entries) do
    {:ok, body, conn} = read_body(conn)
    requested = Xml.requested_props(body)

    responses =
      Enum.map(entries, fn {href, available} ->
        {found, missing} = select_props(requested, available)
        Xml.response(href, found, missing)
      end)

    multistatus(conn, responses, [])
  end

  # A property value may arrive as a thunk (`address-data` renders a whole
  # card), so nothing is built for a property the client did not ask for.
  defp select_props(:allprop, available), do: {resolve(available), []}

  defp select_props(names, available) do
    found = Enum.filter(available, fn {name, _value} -> name in names end)
    missing = names -- Enum.map(found, fn {name, _value} -> name end)
    {resolve(found), Enum.filter(missing, &valid_prop_name?/1)}
  end

  defp resolve(props) do
    Enum.map(props, fn
      {name, value} when is_function(value, 0) -> {name, value.()}
      {name, value} -> {name, value}
    end)
  end

  # The 404 half of a propstat echoes names back into the document, so only
  # plain element names may pass — never whatever a client happened to send.
  defp valid_prop_name?(name), do: Regex.match?(~r/^[A-Za-z][\w.-]*$/, name)

  defp multistatus(conn, entries, opts) do
    conn
    |> dav_headers()
    |> put_resp_content_type("application/xml")
    |> send_resp(207, Xml.multistatus(entries, opts))
  end

  # "1, 3" are the RFC 4918 compliance classes this answers; `addressbook` is
  # RFC 6352's. `access-control` is deliberately absent: the privilege property
  # is answered, but the ACL method is not implemented, and a client that acts
  # on a claimed class it cannot use is worse off than one that never saw it.
  defp dav_headers(conn), do: put_resp_header(conn, "dav", "1, 3, addressbook")

  defp depth(conn) do
    case get_req_header(conn, "depth") do
      [value | _rest] -> String.trim(value)
      [] -> "0"
    end
  end

  defp not_found(conn), do: send_resp(conn, 404, "")

  defp invalid_sync_token(conn), do: error(conn, "valid-sync-token")

  defp error(conn, condition) do
    body =
      ~s(<?xml version="1.0" encoding="utf-8"?>) <>
        ~s(<D:error xmlns:D="DAV:"><D:#{condition}/></D:error>)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(403, body)
  end

  defp card_id_from_href(href) do
    case href |> URI.parse() |> Map.get(:path) do
      nil -> nil
      path -> path |> String.split("/", trim: true) |> List.last()
    end
  end

  defp principal_path(user), do: "/system/carddav/p/#{user.id}/"
  defp home_path(user), do: "/system/carddav/a/#{user.id}/"
  defp collection_path(user), do: "/system/carddav/a/#{user.id}/contacts/"
  defp card_path(user, contact_id), do: "/system/carddav/a/#{user.id}/contacts/#{contact_id}"

  defp quoted(etag), do: ~s("#{etag}")
end
