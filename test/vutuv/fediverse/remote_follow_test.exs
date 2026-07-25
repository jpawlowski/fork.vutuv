defmodule Vutuv.Fediverse.RemoteFollowTest do
  # The "follow from your own server" resolver: parsing what a visitor pastes
  # and looking up their server's follow dialog. async: false — the HTTP stub
  # lives in the application env.
  use ExUnit.Case, async: false

  alias Vutuv.Fediverse.RemoteFollow

  @template "https://social.example/authorize_interaction?uri={uri}"

  defp stub(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp jrd(links) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/jrd+json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"links" => links}))
    end
  end

  # Mastodon and friends serve the `schema/1.0/subscribe` spelling; the older
  # `spec/1.0#subscribe` one is also in the wild, so both must resolve.
  defp subscribe_link(template \\ @template, rel \\ "http://ostatus.org/schema/1.0/subscribe") do
    [
      %{"rel" => "self", "href" => "https://social.example/users/them"},
      %{"rel" => rel, "template" => template}
    ]
  end

  describe "parse_address/1" do
    test "accepts every shape people paste" do
      assert {:ok, {"them", "social.example"}} =
               RemoteFollow.parse_address("@them@social.example")

      assert {:ok, {"them", "social.example"}} = RemoteFollow.parse_address("them@social.example")

      assert {:ok, {"them", "social.example"}} =
               RemoteFollow.parse_address(" @them@Social.Example ")

      assert {:ok, {"them", "social.example"}} =
               RemoteFollow.parse_address("https://social.example/@them")

      assert {:ok, {"them", "social.example"}} =
               RemoteFollow.parse_address("https://social.example/users/them")
    end

    test "rejects anything that is not a Fediverse address" do
      for input <- ["", "them", "@them", "them@localhost", "them@example", "a@b@c@d", nil] do
        assert {:error, :invalid_address} = RemoteFollow.parse_address(input)
      end
    end
  end

  describe "subscribe_url/2" do
    test "asks the visitor's own server and fills our member into its dialog" do
      stub(fn conn ->
        assert conn.host == "social.example"
        assert conn.request_path == "/.well-known/webfinger"
        assert conn.query_string =~ "acct%3Athem%40social.example"

        jrd(subscribe_link()).(conn)
      end)

      assert {:ok, url} = RemoteFollow.subscribe_url("@them@social.example", "greta@vutuv.de")

      assert url ==
               "https://social.example/authorize_interaction?uri=acct%3Agreta%40vutuv.de"
    end

    test "accepts either spelling of the subscribe rel" do
      for rel <- [
            "http://ostatus.org/schema/1.0/subscribe",
            "http://ostatus.org/spec/1.0#subscribe"
          ] do
        stub(jrd(subscribe_link(@template, rel)))

        assert {:ok, _url} = RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
      end
    end

    test "never touches the network for an address that cannot be one" do
      stub(fn _conn -> raise "must not be called" end)

      assert {:error, :invalid_address} =
               RemoteFollow.subscribe_url("not an address", "g@vutuv.de")
    end

    test "reports a server that publishes no follow dialog" do
      stub(jrd([%{"rel" => "self", "href" => "https://social.example/users/them"}]))

      assert {:error, :no_remote_follow} =
               RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
    end

    test "refuses a dialog template that is not an https URL with a placeholder" do
      for bad <- ["http://social.example/i?uri={uri}", "https://social.example/i?uri="] do
        stub(jrd(subscribe_link(bad)))

        assert {:error, :no_remote_follow} =
                 RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
      end
    end

    test "reports a server that does not answer with a document" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, :unreachable} =
               RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
    end

    test "follows one redirect hop, the common apex-to-server WebFinger setup" do
      stub(fn conn ->
        case conn.host do
          "social.example" ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://mastodon.social.example/.well-known/webfinger?resource=acct:them@social.example"
            )
            |> Plug.Conn.send_resp(301, "")

          "mastodon.social.example" ->
            jrd(subscribe_link()).(conn)
        end
      end)

      assert {:ok, url} = RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
      assert url =~ "authorize_interaction"
    end

    test "stops at the second redirect rather than chasing a loop" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://other.example/.well-known/webfinger")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :unreachable} =
               RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
    end

    test "refuses a host that resolves into the private network" do
      stub(fn _conn -> raise "must not be called" end)

      # Restore the test-env resolver afterwards rather than deleting the key:
      # every other outbound fetch in the suite resolves through it.
      public = Application.get_env(:vutuv, :ssrf_resolver)

      Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)

      on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, public) end)

      assert {:error, :unreachable} =
               RemoteFollow.subscribe_url("@them@social.example", "g@vutuv.de")
    end
  end
end
