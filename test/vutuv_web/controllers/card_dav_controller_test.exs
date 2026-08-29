defmodule VutuvWeb.CardDavControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.CardDavHelpers

  alias Vutuv.ApiAuth
  alias Vutuv.CardDav
  alias Vutuv.Social

  @token "vutuv_pat_carddav_test_token"

  setup do
    owner = insert(:activated_user, carddav_sharing: "following")
    contact = insert(:activated_user, first_name: "Ada", last_name: "Lovelace")
    follow!(owner, contact)

    carddav_token!(owner, @token)

    %{owner: owner, contact: contact}
  end

  defp dav(conn, method, path, body, token \\ @token),
    do: dav(conn, @endpoint, method, path, body, token: token)

  defp collection(owner), do: collection_path(owner)
  defp card(owner, contact), do: card_path(owner, contact)

  describe "authentication" do
    test "no credentials asks for them instead of failing silently", %{conn: conn, owner: owner} do
      conn =
        conn
        |> put_req_header("content-type", "text/xml")
        |> dispatch(@endpoint, :propfind, collection(owner), "")

      assert conn.status == 401
      assert ["Basic realm=\"vutuv\""] = get_resp_header(conn, "www-authenticate")
    end

    test "the realm names no host — a client stores its password per protection space", %{
      owner: owner
    } do
      # Host, port, realm and scheme together identify where a stored password
      # belongs. A realm derived from the configured host means a client that
      # reached us under any other name (www., a second hostname, a LAN address)
      # finds no credential that matches, and a background daemon with nobody to
      # ask simply stops: macOS Contacts reported "account verification failed"
      # without ever sending an Authorization header.
      for host <- ["vutuv.de", "www.vutuv.de", "10.6.0.10"] do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, host)
          |> put_req_header("content-type", "text/xml")
          |> dispatch(@endpoint, :propfind, collection(owner), "")

        assert ["Basic realm=\"vutuv\""] = get_resp_header(conn, "www-authenticate")
      end
    end

    test "a token without contacts:read is refused", %{conn: conn, owner: owner} do
      other = "vutuv_pat_wrong_scope"

      insert(:api_token,
        user: owner,
        scopes: ["profile:read"],
        token_hash: ApiAuth.hash_token(other)
      )

      assert dav(conn, :propfind, collection(owner), "", other).status == 401
    end

    test "a member who switched the address book off has no collection", %{
      conn: conn,
      owner: owner
    } do
      {:ok, _owner} = Vutuv.Accounts.update_user(owner, %{"carddav_sharing" => "off"})

      assert dav(conn, :propfind, collection(owner), "").status == 401
    end

    test "a revoked token stops working", %{conn: conn, owner: owner} do
      [token] = ApiAuth.list_pats(owner)
      ApiAuth.revoke_token!(token)

      assert dav(conn, :propfind, collection(owner), "").status == 401
    end
  end

  describe "discovery" do
    test "/.well-known/carddav points at the service root, unauthenticated", %{conn: conn} do
      conn = get(conn, "/.well-known/carddav")

      # 301, not 302: RFC 6764 wants a client to remember where the service
      # lives rather than ask again on every sync.
      assert redirected_to(conn, 301) == "/system/carddav/"
    end

    test "a client's PROPFIND is answered in place, not redirected", %{conn: conn, owner: owner} do
      # iOS follows a redirect here, meets the 401 at the redirected location
      # and gives up rather than retrying there — "CardDAV account verification
      # failed", seen in the iOS 27 Simulator. So the challenge and the answer
      # both have to be at the URL the client asked about.
      unauthenticated =
        conn
        |> put_req_header("content-type", "text/xml")
        |> dispatch(@endpoint, :propfind, "/.well-known/carddav", "")

      assert unauthenticated.status == 401
      assert ["Basic realm=" <> _rest] = get_resp_header(unauthenticated, "www-authenticate")

      answered = dav(conn, :propfind, "/.well-known/carddav", "")

      assert answered.status == 207
      # The href names the URL that was asked about, and the document points at
      # the principal, which is what the client follows next.
      assert answered.resp_body =~ "<D:href>/.well-known/carddav</D:href>"
      assert answered.resp_body =~ "/system/carddav/p/#{owner.id}/"
    end

    test "the site root answers PROPFIND with the same service document", %{
      conn: conn,
      owner: owner
    } do
      # A CardDAV account's server is a bare host name, so its account URL is
      # `https://<host>/` — and that is what iOS asks first (it PROPFINDs `/`
      # and `/principals/`). A router that answers neither is a server it
      # decides cannot sync contacts.
      conn = dav(conn, :propfind, "/", "")

      assert conn.status == 207
      assert conn.resp_body =~ "<D:href>/</D:href>"
      assert conn.resp_body =~ "/system/carddav/p/#{owner.id}/"
    end

    test "the website's own GET / is untouched by that", %{conn: conn} do
      assert conn |> get("/") |> html_response(200)
    end

    test "OPTIONS advertises the CardDAV compliance classes", %{conn: conn, owner: owner} do
      conn = dav(conn, :options, collection(owner), "")

      assert conn.status == 200
      assert ["1, 3, addressbook"] = get_resp_header(conn, "dav")
    end

    test "the service root names the principal", %{conn: conn, owner: owner} do
      body = dav(conn, :propfind, "/system/carddav/", "").resp_body

      assert body =~ "current-user-principal"
      assert body =~ "/system/carddav/p/#{owner.id}/"
    end

    test "the principal names the address book home", %{conn: conn, owner: owner} do
      body = dav(conn, :propfind, "/system/carddav/p/#{owner.id}", "").resp_body

      assert body =~ "addressbook-home-set"
      assert body =~ "/system/carddav/a/#{owner.id}/"
    end
  end

  describe "PROPFIND on the collection" do
    test "declares itself an address book and carries a sync token", %{conn: conn, owner: owner} do
      conn = dav(conn, :propfind, collection(owner), "")

      assert conn.status == 207
      assert conn.resp_body =~ "<C:addressbook/>"
      assert conn.resp_body =~ "urn:vutuv:carddav:"
      assert conn.resp_body =~ "getctag"
    end

    test "says read-only in the protocol, not only in the docs", %{conn: conn, owner: owner} do
      body = dav(conn, :propfind, collection(owner), "").resp_body

      assert body =~ "<D:current-user-privilege-set><D:privilege><D:read/></D:privilege>"
      refute body =~ "<D:write/>"
    end

    test "Depth 1 lists every card", %{conn: conn, owner: owner, contact: contact} do
      conn =
        conn
        |> put_req_header("depth", "1")
        |> dav(:propfind, collection(owner), "")

      assert conn.resp_body =~ card(owner, contact)
      assert conn.resp_body =~ "getetag"
    end

    test "a property the client asked for and we do not have comes back 404", %{
      conn: conn,
      owner: owner
    } do
      request = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getetag/></D:prop></D:propfind>
      """

      body = dav(conn, :propfind, collection(owner), request).resp_body

      assert body =~ "404 Not Found"
      assert body =~ "<D:getetag/>"
    end
  end

  describe "GET a card" do
    test "serves the vCard with an ETag", %{conn: conn, owner: owner, contact: contact} do
      conn = dav(conn, :get, card(owner, contact), "")

      assert conn.status == 200
      assert conn.resp_body =~ "BEGIN:VCARD"
      assert conn.resp_body =~ "FN:Ada Lovelace"
      assert conn.resp_body =~ "UID:urn:uuid:#{contact.id}"
      assert [etag] = get_resp_header(conn, "etag")
      assert String.starts_with?(etag, "\"")
      assert ["text/vcard" <> _charset] = get_resp_header(conn, "content-type")
    end

    test "the private note rides along, and only to its author", %{
      conn: conn,
      owner: owner,
      contact: contact
    } do
      {:ok, _follow} = Social.set_follow_marks(owner, contact, %{note: "met at ElixirConf"})

      assert dav(conn, :get, card(owner, contact), "").resp_body =~ "NOTE:met at ElixirConf"
    end

    test "somebody I no longer follow is gone", %{conn: conn, owner: owner, contact: contact} do
      Repo.delete_all(Vutuv.Social.Follow)

      assert dav(conn, :get, card(owner, contact), "").status == 404
    end
  end

  describe "REPORT sync-collection" do
    setup %{conn: conn, owner: owner} do
      # The initial sync, which is what a phone does when the account is added.
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:sync-collection xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
        <D:sync-token/><D:sync-level>1</D:sync-level>
        <D:prop><D:getetag/><C:address-data/></D:prop>
      </D:sync-collection>
      """

      conn = dav(conn, :report, collection(owner), body)
      token = Regex.run(~r{<D:sync-token>(.*?)</D:sync-token>}, conn.resp_body) |> Enum.at(1)

      %{initial: conn, token: token}
    end

    test "an initial sync hands over every card with its data", %{
      initial: conn,
      contact: contact
    } do
      assert conn.status == 207
      assert conn.resp_body =~ "BEGIN:VCARD"
      assert conn.resp_body =~ "FN:Ada Lovelace"
      assert conn.resp_body =~ contact.id
    end

    test "a second sync with the same token carries nothing", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      body = sync_body(token)

      refute dav(conn, :report, collection(owner), body).resp_body =~ "BEGIN:VCARD"
    end

    test "unfollowing reports the card as gone, which is what deletes it on the phone", %{
      conn: conn,
      owner: owner,
      contact: contact,
      token: token
    } do
      Repo.delete_all(Vutuv.Social.Follow)

      response = dav(conn, :report, collection(owner), sync_body(token)).resp_body

      assert response =~ card(owner, contact)
      assert response =~ "404 Not Found"
      refute response =~ "BEGIN:VCARD"
    end

    test "a token we never minted is refused rather than guessed at", %{
      conn: conn,
      owner: owner
    } do
      conn = dav(conn, :report, collection(owner), sync_body("urn:some:other:server:9"))

      assert conn.status == 403
      assert conn.resp_body =~ "valid-sync-token"
    end

    defp sync_body(token) do
      """
      <?xml version="1.0" encoding="utf-8"?>
      <D:sync-collection xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
        <D:sync-token>#{token}</D:sync-token><D:sync-level>1</D:sync-level>
        <D:prop><D:getetag/><C:address-data/></D:prop>
      </D:sync-collection>
      """
    end
  end

  describe "REPORT addressbook-multiget" do
    test "returns the named cards and 404s the rest", %{
      conn: conn,
      owner: owner,
      contact: contact
    } do
      stranger = insert(:activated_user)

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <C:addressbook-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
        <D:prop><D:getetag/><C:address-data/></D:prop>
        <D:href>#{card(owner, contact)}</D:href>
        <D:href>#{card(owner, stranger)}</D:href>
      </C:addressbook-multiget>
      """

      response = dav(conn, :report, collection(owner), body).resp_body

      assert response =~ "FN:Ada Lovelace"
      assert response =~ "404 Not Found"
    end
  end

  describe "writes" do
    test "PUT is refused with the privilege the collection already advertised", %{
      conn: conn,
      owner: owner,
      contact: contact
    } do
      conn = dav(conn, :put, card(owner, contact), "BEGIN:VCARD\nEND:VCARD")

      assert conn.status == 403
      assert conn.resp_body =~ "need-privileges"
    end

    test "DELETE is refused too", %{conn: conn, owner: owner, contact: contact} do
      assert dav(conn, :delete, card(owner, contact), "").status == 403
    end
  end

  describe "the installation switch" do
    test "CARDDAV_ENABLED=false 404s the whole thing", %{conn: conn, owner: owner} do
      Application.put_env(:vutuv, :carddav_enabled, false)
      on_exit(fn -> Application.put_env(:vutuv, :carddav_enabled, true) end)

      assert dav(conn, :propfind, collection(owner), "").status == 404
      assert CardDav.enabled?() == false
    end
  end
end
