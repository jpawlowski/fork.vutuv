defmodule VutuvWeb.Plug.Locale do
  @moduledoc """
  Resolves everything about a request that is "where the reader is": the
  interface language, the date shape they read (`Vutuv.DateRegions`) and the
  time zone their stamps are written in (`Vutuv.ViewerClock`).

  The language goes into Gettext, the other two into the viewer clock, and both
  are also stored in the session so a LiveView — a process this plug never ran
  in — can pick them up on mount (`VutuvWeb.LiveLocale`).
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias Vutuv.DateRegions
  alias Vutuv.Languages
  alias Vutuv.ViewerClock

  def init(default), do: default

  def call(conn, _default) do
    conn
    |> handle_locale(conn.assigns[:current_user])
    |> put_viewer_clock(conn.assigns[:current_user])
  end

  defp handle_locale(conn, %User{locale: nil}), do: handle_locale(conn, nil)

  defp handle_locale(conn, nil), do: conn |> resolve_locale() |> assign_locale(conn)

  defp handle_locale(conn, %User{locale: loc}) do
    assign_locale(loc, conn)
  end

  # The date shape and time zone this reader gets. The browser's own guess is
  # kept beside the resolved value — the sign-up form stamps it on the new
  # account (`Vutuv.Accounts`), and a LiveView mount re-runs the same
  # resolution off the session, so it has to travel there too.
  defp put_viewer_clock(conn, user) do
    browser_region = DateRegions.from_accept_language(get_req_header(conn, "accept-language"))
    ViewerClock.put_viewer(user, browser_region)

    conn
    |> assign(:browser_date_region, browser_region)
    |> store_in_session(:date_region, browser_region)
  end

  defp process_header([]), do: []

  # Splits header on commas.
  defp process_header(header) do
    header
    |> hd
    |> String.split(",")
  end

  @doc """
  The interface language this request's `Accept-Language` asks for — the first
  entry whose base subtag this installation has, else `"en"`.

  What the anonymous branch of `call/2` resolves, and public because one route
  needs the answer without the plug: `/site.webmanifest` is served from the
  `:machine_docs` pipeline, which has no session and no `current_user`, and its
  shortcut labels are what a phone writes into the launcher's long-press menu,
  so they have to be in the reader's language all the same.

  """
  def resolve_locale(conn) do
    conn
    |> get_req_header("accept-language")
    |> process_header()
    |> get_supported_locale()
    |> supported_or_default()
  end

  defp get_supported_locale([]), do: nil

  # Returns the first header locale whose base subtag the app supports,
  # else the visitor's most preferred locale.
  defp get_supported_locale(locales) do
    # `||` rather than find_value/3's default, which is built eagerly and thrown
    # away whenever the header does match — the normal case, and now also on
    # every /site.webmanifest.
    Enum.find_value(locales, fn entry ->
      base =
        entry
        |> String.split(";")
        |> hd()
        |> String.split("-")
        |> hd()

      if locale_supported?(base), do: base
    end) || get_first_locale(locales)
  end

  # Give locale data to all modules that require it. The locale also goes into
  # the session so LiveViews — which run in their own process, where this plug
  # never ran — can pick it up on mount (see `VutuvWeb.Live.InitAssigns` and
  # `VutuvWeb.ShellLive`). Without that, /messages and /notifications flipped
  # the whole chrome back to English for German users.
  #
  defp assign_locale(locale, conn) do
    locale = supported_or_default(locale)
    Gettext.put_locale(VutuvWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> store_in_session(:locale, locale)
  end

  # API requests run this plug without a fetched session — skip them.
  defp store_in_session(conn, key, value) do
    case conn.private do
      %{plug_session_fetch: :done} -> put_session(conn, key, value)
      _ -> conn
    end
  end

  # An unsupported value (nil, or a browser subtag like "fr" that no config
  # locale matches) becomes "en" rather than travelling on into Gettext, the
  # `<html lang>` and the session as a dead value that renders English content
  # under a foreign lang tag.
  defp supported_or_default(locale), do: if(locale_supported?(locale), do: locale, else: "en")

  # Gets the first locale provided
  defp get_first_locale(locales) do
    locales
    |> hd
    |> String.split("-")
    |> hd
  end

  def locale_supported?(nil), do: false

  # Checks locale provided against app config for supported locales. Must be
  # exact equality, not a substring match: callers (address_controller, the
  # emailer) pass arbitrary strings, and a 3-letter subtag that is a superstring
  # of a supported 2-letter code ("deu" contains "de", "eng" contains "en")
  # would false-match under `String.contains?/2`.
  def locale_supported?(locale), do: locale in Languages.site_locales()
end
