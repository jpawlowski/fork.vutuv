defmodule VutuvWeb.MentionControllerTest do
  @moduledoc """
  The two JSON answers behind the composer's `@`-picker (issue #1748).

  What is asserted here is the *contract the editor reads*: the row shape it
  draws, and — the one that bites silently — that `check` reports which handles
  it actually looked up. A client that read a missing handle as "no such
  account" would strip the chip off a real member the moment somebody pasted a
  long list, so `checked` is not decoration.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Mentions

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user}
  end

  describe "GET /system/mentions/suggest" do
    test "offers a matching member with everything a row needs", %{conn: conn} do
      insert(:activated_user, username: "adalovelace", first_name: "Ada", last_name: "Lovelace")

      %{"results" => [row]} =
        conn |> get(~p"/system/mentions/suggest", q: "ada") |> json_response(200)

      assert row["handle"] == "adalovelace"
      assert row["name"] == "Ada Lovelace"
      assert row["kind"] == "user"
      # No avatar: the editor draws the initials tile instead of a broken image.
      assert row["avatar"] == nil
      assert row["initials"] == "AL"
    end

    test "offers an organization page as its own kind", %{conn: conn} do
      insert(:organization, username: "acmegmbh", name: "Acme GmbH")

      %{"results" => [row]} =
        conn |> get(~p"/system/mentions/suggest", q: "acme") |> json_response(200)

      assert row["kind"] == "organization"
      assert row["handle"] == "acmegmbh"
      assert row["initials"] == "A"
    end

    test "a missing or empty query is an empty list, not an error", %{conn: conn} do
      assert %{"results" => []} = conn |> get(~p"/system/mentions/suggest") |> json_response(200)
    end

    test "signed out it answers nobody: no JSON, a redirect", %{conn: conn} do
      conn = conn |> delete(~p"/logout") |> get(~p"/system/mentions/suggest", q: "ada")

      # The editor's fetch reads that as "no suggestions" and carries on — the
      # picker is an enhancement, and a logged-out page has no composer anyway.
      assert redirected_to(conn) == "/"
    end
  end

  describe "GET /system/mentions/check" do
    test "answers which handles exist, and which it looked at", %{conn: conn} do
      insert(:activated_user, username: "adareal")

      body =
        conn |> get(~p"/system/mentions/check", handles: "adareal,ghost") |> json_response(200)

      assert body["known"] == ["adareal"]
      assert Enum.sort(body["checked"]) == ["adareal", "ghost"]
    end

    test "`checked` stops at the cap, so the editor never guesses past it", %{conn: conn} do
      handles = Enum.map_join(1..(Mentions.max_check_handles() + 5), ",", &"handle#{&1}")

      body = conn |> get(~p"/system/mentions/check", handles: handles) |> json_response(200)

      assert length(body["checked"]) == Mentions.max_check_handles()
    end

    test "no handles is an empty answer, not an error", %{conn: conn} do
      assert %{"known" => [], "checked" => []} =
               conn |> get(~p"/system/mentions/check") |> json_response(200)
    end
  end
end
