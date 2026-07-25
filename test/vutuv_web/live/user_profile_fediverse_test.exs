defmodule VutuvWeb.UserProfileFediverseTest do
  @moduledoc """
  The profile's Fediverse card and its "Follow from your own server" button:
  what a visitor arriving from Mastodon and friends sees, and what happens when
  they hand us their own address. Not async — the installation switch and the
  HTTP stub for the remote WebFinger lookup both live in the application env.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias VutuvWeb.Fediverse.Docs

  @card "#profile-fediverse"
  @handle "#profile-fediverse-handle"
  @form "#remote-follow-form"

  defp federating_member(attrs \\ []) do
    insert_activated_user(Keyword.merge([fediverse_followers?: true], attrs))
  end

  defp stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp serve_subscribe_template do
    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/jrd+json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "links" => [
            %{
              "rel" => "http://ostatus.org/spec/1.0#subscribe",
              "template" => "https://social.example/authorize_interaction?uri={uri}"
            }
          ]
        })
      )
    end)
  end

  describe "the card" do
    test "shows a federating member's handle to a logged-out visitor", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, @card)
      assert render(view) =~ Docs.handle(user)
      assert has_element?(view, @form)
    end

    test "is absent for a member who does not federate", %{conn: conn} do
      user = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      refute has_element?(view, @card)
    end

    test "is absent while the installation switch is off", %{conn: conn} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      refute has_element?(view, @card)
    end

    test "points at the forwarding address once the member moved away", %{conn: conn} do
      user = federating_member(moved_to: "https://social.example/users/greta")

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, "#fediverse-moved-to")
      assert render(view) =~ "@greta@social.example"
      # Following here would land on a redirect, so the tool is not offered.
      refute has_element?(view, @form)
      refute has_element?(view, @handle)
    end

    test "the form posts to the route that exists", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert view
             |> element(@form)
             |> render() =~ ~s|action="/#{user.username}/fediverse/follow"|
    end
  end

  describe "POST /:slug/fediverse/follow" do
    test "sends the visitor to their own server's follow dialog", %{conn: conn} do
      user = federating_member()
      serve_subscribe_template()

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) ==
               "https://social.example/authorize_interaction?uri=" <>
                 URI.encode_www_form("acct:" <> Docs.acct(user))
    end

    test "the token the rendered form carries really passes CSRF", %{conn: conn} do
      user = federating_member()
      serve_subscribe_template()

      # ConnTest skips CSRF on a plain post/3, so the one thing worth proving
      # here is that the token a LiveView-rendered form stamps is accepted: the
      # profile is rendered by a LiveView, which loads the session's CSRF state
      # separately from the controller.
      conn = get(conn, ~p"/#{user}")

      conn =
        submit_with_csrf(conn, ~p"/#{user}/fediverse/follow", %{
          "address" => "@them@social.example"
        })

      assert redirected_to(conn) =~ "https://social.example/authorize_interaction"
    end

    test "explains a typo instead of guessing", %{conn: conn} do
      user = federating_member()
      stub_remote(fn _conn -> raise "must not be called" end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "not an address"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "@you@example.social"
    end

    test "names the server that could not be reached", %{conn: conn} do
      user = federating_member()
      stub_remote(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "social.example"
    end

    test "refuses a member who does not federate", %{conn: conn} do
      user = insert_activated_user()
      stub_remote(fn _conn -> raise "must not be called" end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not on the Fediverse"
    end

    test "refuses a member who moved their account away", %{conn: conn} do
      user = federating_member(moved_to: "https://social.example/users/greta")
      stub_remote(fn _conn -> raise "must not be called" end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
    end
  end
end
