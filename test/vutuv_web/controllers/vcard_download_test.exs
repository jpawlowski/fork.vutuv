defmodule VutuvWeb.VCardDownloadTest do
  @moduledoc """
  Who may take a profile away as a `.vcf` (issue #1705).

  The sibling of `carddav_visibility`, and the reason that one means anything:
  withdrawing from every address book while a one-click download sits on the
  profile withdraws nothing. What each test really checks is that the button,
  the advertised alternate and the URL agree — a member who says no must not be
  left with a link that 404s, and a 404 must not be reachable around a hidden
  link.
  """
  use VutuvWeb.ConnCase, async: true

  describe "everyone (the default)" do
    test "a logged-out visitor gets the file and the button", %{conn: conn} do
      user = insert_activated_user()

      assert user.vcard_download == "everyone"
      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(200) =~ "BEGIN:VCARD"
      assert conn |> recycle() |> get(~p"/#{user}") |> html_response(200) =~ "download-vcard"
    end
  end

  describe "nobody" do
    test "the file is gone and nothing points at it", %{conn: conn} do
      user = insert_activated_user(vcard_download: "nobody")

      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(404)

      html = conn |> recycle() |> get(~p"/#{user}") |> html_response(200)
      refute html =~ "download-vcard"
      # The head alternates and the "Other formats" card go with it: a page
      # never advertises a URL it would refuse.
      refute html =~ "#{user.username}.vcf"
    end

    test "the owner can still take their own", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, user} = Vutuv.Accounts.update_user(user, %{"vcard_download" => "nobody"})

      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(200) =~ "BEGIN:VCARD"
    end

    test "the other agent formats are untouched", %{conn: conn} do
      user = insert_activated_user(vcard_download: "nobody")

      # This setting is about the contact card, not about machine readability.
      assert conn |> recycle() |> get("/#{user.username}.json") |> response(200)
      assert conn |> recycle() |> get("/#{user.username}.md") |> response(200)
    end
  end

  describe "followers" do
    test "a logged-out visitor is refused", %{conn: conn} do
      user = insert_activated_user(vcard_download: "followers")

      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(404)
      refute conn |> recycle() |> get(~p"/#{user}") |> html_response(200) =~ "download-vcard"
    end

    test "a signed-in member who does not follow is refused too", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      user = insert_activated_user(vcard_download: "followers")

      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(404)
    end

    test "a follower gets it", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      user = insert_activated_user(vcard_download: "followers")
      follow!(viewer, user)

      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(200) =~ "BEGIN:VCARD"
      assert conn |> recycle() |> get(~p"/#{user}") |> html_response(200) =~ "download-vcard"
    end
  end

  describe "the two settings are separate questions" do
    test "withdrawing from address books leaves the download alone, and the reverse", %{
      conn: conn
    } do
      user = insert_activated_user(carddav_visibility: "nobody")

      # A subscription and a one-off file are different acts; saying no to one
      # is not saying no to the other.
      assert conn |> recycle() |> get("/#{user.username}.vcf") |> response(200) =~ "BEGIN:VCARD"

      other = insert_activated_user(vcard_download: "nobody")
      assert other.carddav_visibility == "followers"
    end
  end
end
