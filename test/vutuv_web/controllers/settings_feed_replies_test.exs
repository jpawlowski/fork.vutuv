defmodule VutuvWeb.SettingsFeedRepliesTest do
  @moduledoc """
  The /settings side of the feed's answer filter (issue #1740).

  The `action=` assertion is not decoration: a Save button pointing at a route
  that no longer exists is invisible to a test that PUTs a path it made up
  itself, and that is exactly how every button on /settings/privacy 404ed in
  production from v7.34 to v7.42. So this reads the URL out of the rendered form
  and submits through it.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Prefs

  test "the rendered form posts at a route that exists", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings/preferences") |> html_response(200)

    assert html =~ ~s(action="/settings/feed_replies")
    assert html =~ ~s(name="user[feed_stranger_replies?]")
  end

  test "renders in German for a German visitor", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/settings/preferences")
      |> html_response(200)

    # Named explicitly because `gettext.extract --merge` fuzzy-fills a new msgid
    # with the translation of whatever it looks like: both flash strings here
    # arrived pre-filled as "Fediverse-Einstellungen" and "Reiter-Einstellungen",
    # and nothing in the build would have said so.
    assert html =~ "Antworten in deinem Feed"
    assert html =~ "Antworten an Personen anzeigen, denen ich nicht folge"
  end

  test "saving through it records the member's choice", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # Shipped default is "leave them out", and NULL means "never chose".
    assert is_nil(user.feed_stranger_replies?)
    refute Prefs.get(user, :feed_stranger_replies?)

    conn =
      put(conn, ~p"/settings/feed_replies", %{"user" => %{"feed_stranger_replies?" => "true"}})

    assert redirected_to(conn) == ~p"/settings/preferences"
    assert Prefs.get(Repo.reload!(user), :feed_stranger_replies?)
  end

  test "the reset link clears it back to inheriting", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    put(conn, ~p"/settings/feed_replies", %{"user" => %{"feed_stranger_replies?" => "true"}})
    assert Repo.reload!(user).feed_stranger_replies? == true

    conn = post(conn, ~p"/settings/feed_replies/reset")

    assert redirected_to(conn) == ~p"/settings/preferences"
    assert is_nil(Repo.reload!(user).feed_stranger_replies?)
  end
end
