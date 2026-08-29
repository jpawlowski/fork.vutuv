defmodule VutuvWeb.ProfileContactMarksTest do
  @moduledoc """
  The viewer's two private marks on their own follow (issue #1705): the
  "personally known" toggle in the profile's ⋯ menu, and the private note card.

  What every one of these asserts, one way or another, is that the marks belong
  to the follower: they show on the follower's view of the profile, they never
  show on anybody else's, and the person marked is never told.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.CardDav
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow

  describe "the personally-known toggle" do
    test "flips the menu label without a reload", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:follow, follower: viewer, followee: owner)

      {:ok, view, html} = live(conn, ~p"/#{owner}")
      assert html =~ "Mark as personally known"

      assert view
             |> element(~s(button[phx-click="toggle_personally_known"]))
             |> render_click() =~ "Remove the mark"

      assert Repo.get_by!(Follow, follower_id: viewer.id).personally_known
    end

    test "is not offered to somebody who does not follow", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, ~s(button[phx-click="toggle_personally_known"]))
    end

    test "the person marked is never told, and never sees it on their own profile", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      {owner_conn, owner} = create_and_login_user(second_conn())
      insert(:follow, follower: viewer, followee: owner)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")
      view |> element(~s(button[phx-click="toggle_personally_known"])) |> render_click()

      # The marked member's own profile says nothing about it — and neither
      # does their view of the member who marked them.
      {:ok, _view, own_page} = live(owner_conn, ~p"/#{owner}")
      refute own_page =~ "personally known"

      {:ok, _view, their_page} = live(recycle(owner_conn), ~p"/#{viewer}")
      refute their_page =~ "Remove the mark"
    end
  end

  describe "the private note" do
    test "saves, comes back, and reaches the address book", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:follow, follower: viewer, followee: owner)
      {:ok, viewer} = Vutuv.Accounts.update_user(viewer, %{"carddav_sharing" => "following"})

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      assert view
             |> form("#private-note form, form[phx-submit=save_note]", %{
               "note" => "met at ElixirConf"
             })
             |> render_submit() =~ "met at ElixirConf"

      assert Repo.get_by!(Follow, follower_id: viewer.id).note == "met at ElixirConf"

      assert [entry] = CardDav.contacts(viewer)
      assert CardDav.render_card(entry, include_photo: false) =~ "NOTE:met at ElixirConf"
    end

    test "an empty box clears the note", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:follow, follower: viewer, followee: owner)
      {:ok, _follow} = Social.set_follow_marks(viewer, owner, %{note: "old"})

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      view |> form("form[phx-submit=save_note]", %{"note" => "   "}) |> render_submit()

      assert Repo.get_by!(Follow, follower_id: viewer.id).note == nil
    end

    test "the card is not shown at all without a follow", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      refute has_element?(view, "#private-note")
    end

    test "nobody else can read it — not even the member it is about", %{conn: conn} do
      {_conn, viewer} = create_and_login_user(conn)
      {owner_conn, owner} = create_and_login_user(second_conn())
      insert(:follow, follower: viewer, followee: owner)
      {:ok, _follow} = Social.set_follow_marks(viewer, owner, %{note: "secret note"})

      # The member the note is about, on their own profile and on the note
      # author's: neither carries a word of it.
      refute owner_conn |> get(~p"/#{owner}") |> html_response(200) =~ "secret note"
      refute owner_conn |> recycle() |> get(~p"/#{viewer}") |> html_response(200) =~ "secret note"
    end

    # A second signed-in member needs a conn of their own, initialised the way
    # ConnCase initialises the first one — the PIN login writes to the session.
    defp second_conn, do: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
  end
end
