defmodule VutuvWeb.CardDavPushControllerTest do
  @moduledoc """
  The WebDAV-Push endpoints on the CardDAV collection (issue #1705): what the
  collection advertises, and what it does with a device's registration.

  `async: false` because `:web_push_enabled` is global.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.CardDavHelpers

  alias Vutuv.CardDav

  @token "vutuv_pat_carddav_push_test"
  @p256dh "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth_secret "BTBZMqHH6r4Tts7J_aSIgg"

  setup do
    Application.put_env(:vutuv, :web_push_enabled, true)
    on_exit(fn -> Application.put_env(:vutuv, :web_push_enabled, false) end)

    owner = insert(:activated_user, carddav_sharing: "following")
    follow!(owner, insert(:activated_user))

    carddav_token!(owner, @token)

    %{owner: owner}
  end

  defp dav(conn, method, path, body),
    do: dav(conn, @endpoint, method, path, body, token: @token, content_type: "application/xml")

  defp collection(owner), do: collection_path(owner)

  defp register_body(opts \\ []) do
    resource = Keyword.get(opts, :resource, "https://push.example.net/yohd4yai5Phiz1wi")
    encoding = Keyword.get(opts, :encoding, "aes128gcm")

    trigger =
      Keyword.get(opts, :trigger, "<content-update><D:depth>infinity</D:depth></content-update>")

    """
    <?xml version="1.0" encoding="utf-8" ?>
    <push-register xmlns="https://bitfire.at/webdav-push" xmlns:D="DAV:">
      <subscription>
        <web-push-subscription>
          <push-resource>#{resource}</push-resource>
          <content-encoding>#{encoding}</content-encoding>
          <subscription-public-key type="p256dh">#{@p256dh}</subscription-public-key>
          <auth-secret>#{@auth_secret}</auth-secret>
        </web-push-subscription>
      </subscription>
      <trigger>#{trigger}</trigger>
    </push-register>
    """
  end

  describe "what the collection advertises" do
    test "names the transport, the topic and the one trigger it supports", %{
      conn: conn,
      owner: owner
    } do
      body = dav(conn, :propfind, collection(owner), "").resp_body

      assert body =~ "<P:transports>"
      assert body =~ "vapid-public-key"
      assert body =~ CardDav.topic(owner)
      assert body =~ "<P:supported-triggers><P:content-update>"
    end

    test "advertises nothing while Web Push is off — a transport we cannot serve", %{
      conn: conn,
      owner: owner
    } do
      Application.put_env(:vutuv, :web_push_enabled, false)

      body = dav(conn, :propfind, collection(owner), "").resp_body

      refute body =~ "P:transports"
      refute body =~ "P:topic"
    end
  end

  describe "registering a device" do
    test "answers 201 with the registration URL and the expiry we granted", %{
      conn: conn,
      owner: owner
    } do
      conn = dav(conn, :post, collection(owner), register_body())

      assert conn.status == 201
      assert [location] = get_resp_header(conn, "location")
      assert location =~ "/system/carddav/a/#{owner.id}/contacts/push/"
      assert [expires] = get_resp_header(conn, "expires")
      assert expires =~ "GMT"

      assert [subscription] = CardDav.push_subscriptions(owner)
      assert subscription.push_resource == "https://push.example.net/yohd4yai5Phiz1wi"
    end

    test "the device can drop its own registration again", %{conn: conn, owner: owner} do
      [location] =
        conn |> dav(:post, collection(owner), register_body()) |> get_resp_header("location")

      path = URI.parse(location).path

      assert dav(conn, :delete, path, "").status == 204
      assert CardDav.push_subscriptions(owner) == []

      # Gone means gone, not a second 204.
      assert dav(conn, :delete, path, "").status == 404
    end

    test "a device asking only for property updates is told so", %{conn: conn, owner: owner} do
      body = register_body(trigger: "<property-update><D:depth>0</D:depth></property-update>")
      conn = dav(conn, :post, collection(owner), body)

      assert conn.status == 403
      assert conn.resp_body =~ "no-supported-trigger"
    end

    test "an encoding we cannot produce is refused rather than sent unreadable mail", %{
      conn: conn,
      owner: owner
    } do
      conn = dav(conn, :post, collection(owner), register_body(encoding: "aesgcm"))

      assert conn.status == 403
      assert conn.resp_body =~ "invalid-subscription"
    end

    test "an endpoint inside the network is refused", %{conn: conn, owner: owner} do
      conn = dav(conn, :post, collection(owner), register_body(resource: "https://10.0.0.5/push"))

      assert conn.status == 403
      assert conn.resp_body =~ "invalid-subscription"
    end

    test "with Web Push off the registration says so instead of failing later", %{
      conn: conn,
      owner: owner
    } do
      Application.put_env(:vutuv, :web_push_enabled, false)

      conn = dav(conn, :post, collection(owner), register_body())

      assert conn.status == 403
      assert conn.resp_body =~ "push-not-available"
    end
  end
end
