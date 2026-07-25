defmodule VutuvWeb.SavedSearchSettingsTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.SavedSearches
  alias VutuvWeb.SavedSearchToken

  describe "/settings/saved_searches" do
    test "shows the empty state before anything is saved", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/saved_searches") |> html_response(200)
      assert html =~ "saved-searches-empty"
    end

    test "the hub carries the row even with nothing saved", %{conn: conn} do
      # It used to join the menu only once a search existed, which made the
      # settings menu a different shape on every visit and the feature
      # impossible to discover from the hub.
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings") |> html_response(200)
      assert html =~ ~s(href="#{~p"/settings/saved_searches"}")
    end

    test "lists a saved search and keeps it on the settings menu", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, search} =
        SavedSearches.create(user, %{kind: :jobs, query: "q=elixir", notify: :daily})

      html = conn |> get(~p"/settings/saved_searches") |> html_response(200)
      assert html =~ "saved-search-#{search.id}"
      assert html =~ "elixir"
      assert html =~ ~s(href="#{~p"/settings/saved_searches"}")
    end

    test "updates a search's alert cadence", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, search} =
        SavedSearches.create(user, %{kind: :jobs, query: "q=elixir", notify: :daily})

      conn =
        patch(conn, ~p"/settings/saved_searches/#{search.id}", %{
          "saved_search" => %{"notify" => "weekly"}
        })

      assert redirected_to(conn) == ~p"/settings/saved_searches"
      assert SavedSearches.get_for_user(user, search.id).notify == :weekly
    end

    test "deletes a saved search", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, search} =
        SavedSearches.create(user, %{kind: :jobs, query: "q=elixir", notify: :daily})

      conn = delete(conn, ~p"/settings/saved_searches/#{search.id}")
      assert redirected_to(conn) == ~p"/settings/saved_searches"
      assert SavedSearches.get_for_user(user, search.id) == nil
    end

    test "cannot touch another member's search", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      other = insert(:activated_user)

      {:ok, search} =
        SavedSearches.create(other, %{kind: :jobs, query: "q=elixir", notify: :daily})

      conn = delete(conn, ~p"/settings/saved_searches/#{search.id}")
      assert redirected_to(conn) == ~p"/settings/saved_searches"
      # Untouched: still owned by the other member.
      assert SavedSearches.get_for_user(other, search.id).notify == :daily
    end
  end

  describe "per-search disable link" do
    test "the confirm page switches the search off on submit", %{conn: conn} do
      search = insert(:saved_search, notify: :daily)
      token = SavedSearchToken.sign(search)

      assert conn |> get(~p"/unsubscribe/search/#{token}") |> html_response(200) =~
               "saved-search-disable-form"

      conn = post(conn, ~p"/unsubscribe/search/#{token}")
      assert html_response(conn, 200) =~ "no longer"
      assert Vutuv.Repo.reload!(search).notify == :none
    end

    test "a bad token 404s", %{conn: conn} do
      assert conn |> get(~p"/unsubscribe/search/not-a-token") |> response(404)
    end
  end
end
