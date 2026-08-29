defmodule VutuvWeb.CardDavSettingsTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.CardDav
  alias Vutuv.Repo
  alias Vutuv.Social

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  test "the page offers the four levels and starts off", %{conn: conn} do
    body = conn |> recycle() |> get(~p"/settings/carddav") |> html_response(200)

    assert body =~ "value=\"off\""
    assert body =~ "value=\"personally_known\""
    assert body =~ "value=\"mutual\""
    assert body =~ "value=\"following\""
  end

  test "the form posts to the URL it renders, not one we hoped for", %{conn: conn} do
    body = conn |> recycle() |> get(~p"/settings/carddav") |> html_response(200)

    assert body =~ ~s(action="/settings/carddav")
  end

  test "saving a level publishes the matching contacts", %{conn: conn, user: user} do
    contact = insert(:activated_user)
    follow!(user, contact)

    conn =
      put(recycle(conn), ~p"/settings/carddav", %{"user" => %{"carddav_sharing" => "following"}})

    assert redirected_to(conn) == "/settings/carddav"
    assert Repo.reload(user).carddav_sharing == "following"
    assert [%{contact: %{id: id}}] = CardDav.contacts(Repo.reload(user))
    assert id == contact.id
  end

  test "a tampered level is a field error, not a 500", %{conn: conn} do
    conn =
      put(recycle(conn), ~p"/settings/carddav", %{"user" => %{"carddav_sharing" => "everybody"}})

    assert html_response(conn, 422)
  end

  test "the counts beside each level are the ones that would be published", %{
    conn: conn,
    user: user
  } do
    known = insert(:activated_user)
    mutual = insert(:activated_user)
    follow!(user, known)
    connect!(user, mutual)
    {:ok, _follow} = Social.set_follow_marks(user, known, %{personally_known: true})

    assert CardDav.counts(Repo.reload(user)) == %{
             "personally_known" => 1,
             "mutual" => 1,
             "following" => 2
           }

    assert conn |> recycle() |> get(~p"/settings/carddav") |> html_response(200) =~ "contact"
  end

  describe "the other half: my own card" do
    test "the visibility page offers three levels and defaults to the widest", %{conn: conn} do
      body = conn |> recycle() |> get(~p"/settings/privacy") |> html_response(200)

      assert body =~ "value=\"followers\""
      assert body =~ "value=\"mutual\""
      assert body =~ "value=\"nobody\""
      assert body =~ ~s(action="/settings/privacy")
    end

    test "the same page carries the download question, with its own levels", %{conn: conn} do
      body = conn |> recycle() |> get(~p"/settings/privacy") |> html_response(200)

      # Wider at the top than the address-book levels: the download starts from
      # a public page, and the default keeps it that way.
      assert body =~ "value=\"everyone\""
      assert body =~ "name=\"user[vcard_download]\""
    end

    test "both answers save together", %{conn: conn, user: user} do
      conn
      |> recycle()
      |> put(~p"/settings/privacy", %{
        "user" => %{"carddav_visibility" => "mutual", "vcard_download" => "nobody"}
      })
      |> then(&assert(redirected_to(&1) == "/settings/privacy"))

      saved = Repo.reload(user)
      assert saved.carddav_visibility == "mutual"
      assert saved.vcard_download == "nobody"
    end

    test "withdrawing takes the card out of the books that hold it", %{conn: conn, user: user} do
      subscriber = insert(:activated_user, carddav_sharing: "following")
      follow!(subscriber, user)
      assert [_card] = CardDav.contacts(subscriber)

      conn
      |> recycle()
      |> put(~p"/settings/privacy", %{"user" => %{"carddav_visibility" => "nobody"}})
      |> then(&assert(redirected_to(&1) == "/settings/privacy"))

      # Whoever the data is about decides, and the subscriber's setting is
      # untouched — their book simply no longer contains this member.
      assert CardDav.contacts(Repo.reload(subscriber)) == []
      assert Repo.reload(subscriber).carddav_sharing == "following"
    end

    test "a tampered level is a field error, not a 500", %{conn: conn} do
      conn =
        put(recycle(conn), ~p"/settings/privacy", %{"user" => %{"carddav_visibility" => "x"}})

      assert html_response(conn, 422)
    end
  end

  test "the connection details appear only once something is published", %{
    conn: conn,
    user: user
  } do
    refute conn |> recycle() |> get(~p"/settings/carddav") |> html_response(200) =~
             "/access_tokens/new"

    {:ok, _user} = Vutuv.Accounts.update_user(user, %{"carddav_sharing" => "following"})

    assert conn |> recycle() |> get(~p"/settings/carddav") |> html_response(200) =~
             "/access_tokens/new"
  end
end
