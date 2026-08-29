defmodule VutuvWeb.CardDavHelpTest do
  @moduledoc """
  The member-facing setup guide at `/system/carddav` (issue #1705).

  A help page nobody can reach is not help, and one that tells a member to type
  `vutuv.de` is wrong on every other installation — so what these check is that
  it renders in each language, that the host is this installation's own, and
  that the pictures it points at are actually there.
  """
  use VutuvWeb.ConnCase, async: true

  test "renders in each of the site's languages", %{conn: conn} do
    for {locale, marker} <- [
          {"de", "Kontakte aufs Telefon holen"},
          {"en", "Getting contacts onto your phone"},
          {"it", "Portare i contatti sul telefono"}
        ] do
      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "#{locale}-#{String.upcase(locale)},#{locale}")
        |> get(~p"/system/carddav")
        |> html_response(200)

      assert body =~ marker
    end
  end

  test "names this installation's own host, never a hard-coded one", %{conn: conn} do
    body = conn |> get(~p"/system/carddav") |> html_response(200)

    assert body =~ VutuvWeb.Endpoint.host()
    refute body =~ "{{host}}"
  end

  test "the pictures it points at exist", %{conn: conn} do
    body = conn |> get(~p"/system/carddav") |> html_response(200)

    images = Regex.scan(~r{/images/help/carddav/[\w.-]+}, body) |> List.flatten() |> Enum.uniq()

    assert length(images) >= 4

    for image <- images do
      assert File.exists?(Path.join("priv/static", image)), "missing #{image}"
    end
  end

  test "the raw Markdown sibling is served too", %{conn: conn} do
    body = conn |> get("/system/carddav.md") |> response(200)

    assert body =~ "# "
    refute body =~ "{{host}}"
  end
end
