defmodule VutuvWeb.CardDav.Xml do
  @moduledoc """
  The WebDAV/CardDAV wire format: building `multistatus` responses, and reading
  the handful of facts a request body carries.

  **Reading is done with patterns, not with an XML parser, on purpose.** The
  bodies clients send here are tiny and fixed in shape — a list of property
  names, a list of hrefs, a sync token — while handing attacker-controlled XML
  to a full parser is how a server acquires an XXE hole: `:xmerl` resolves
  external entities, and "read this file for me" is not a feature an address
  book needs. Nothing here expands an entity, follows a `SYSTEM` reference, or
  allocates in proportion to nesting depth.

  The one thing this costs is namespace precision: an element is matched by its
  local name with any prefix, so a client that put `getetag` in a namespace of
  its own would be misread. No client does, and the alternative is a parser
  with a much worse failure mode.
  """

  @dav "DAV:"
  @carddav "urn:ietf:params:xml:ns:carddav"
  # Apple's "collection tag": one opaque value per collection that changes when
  # anything in it does. Predates RFC 6578 and is still what several clients
  # (macOS Contacts among them) check first, so it is cheap to keep answering.
  @calendarserver "http://calendarserver.org/ns/"

  alias VutuvWeb.Xml, as: SharedXml

  @doc "The XML declaration plus a `<multistatus>` wrapping the given entries."
  def multistatus(entries, opts \\ []) do
    extra =
      case Keyword.get(opts, :sync_token) do
        nil -> ""
        token -> "<D:sync-token>" <> escape(token) <> "</D:sync-token>"
      end

    ~s(<?xml version="1.0" encoding="utf-8"?>) <>
      ~s(<D:multistatus xmlns:D="#{@dav}" xmlns:C="#{@carddav}" xmlns:CS="#{@calendarserver}">) <>
      IO.iodata_to_binary(entries) <>
      extra <>
      "</D:multistatus>"
  end

  @doc """
  One `<response>` for a resource: the properties that were found, and the
  names that were asked for and do not exist here.

  Both halves matter. A client that asked for `getetag` on a collection must be
  told it is not there (404) rather than left to guess from its absence —
  that is what the second `propstat` is for.
  """
  def response(href, found, missing) do
    [
      "<D:response><D:href>",
      escape(href),
      "</D:href>",
      propstat(found),
      missing_propstat(missing),
      "</D:response>"
    ]
  end

  @doc """
  A bare status response — no properties, just an href and a code. This is how
  `sync-collection` reports a card that is gone (404), which is the whole
  mechanism by which a contact leaves a phone.
  """
  def status_response(href, status) do
    [
      "<D:response><D:href>",
      escape(href),
      "</D:href><D:status>HTTP/1.1 ",
      status,
      "</D:status></D:response>"
    ]
  end

  defp propstat([]), do: []

  defp propstat(found) do
    [
      "<D:propstat><D:prop>",
      Enum.map(found, fn {_name, xml} -> xml end),
      "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
    ]
  end

  defp missing_propstat([]), do: []

  defp missing_propstat(missing) do
    [
      "<D:propstat><D:prop>",
      Enum.map(missing, fn name -> ["<D:", name, "/>"] end),
      "</D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>"
    ]
  end

  @doc """
  XML text escaping. Everything that reaches a body goes through this.

  The table itself belongs to `VutuvWeb.Xml`, which calls itself the one XML
  text escape and is what the sitemap and the feeds use — a second copy here
  would be a second table to keep in step. Only the `nil` clause is local:
  a WebDAV property that is absent renders as an empty element rather than
  as the word "nil".
  """
  def escape(nil), do: ""
  def escape(text), do: SharedXml.escape(text)

  # ── Reading a request ──

  @doc """
  The property names a `PROPFIND` body asks for, or `:allprop` when it asks for
  everything (`<allprop/>`) or sends no body at all — which RFC 4918 defines as
  the same thing.
  """
  def requested_props(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" -> :allprop
      String.contains?(trimmed, "allprop") -> :allprop
      true -> prop_names(trimmed)
    end
  end

  defp prop_names(body) do
    case Regex.run(~r{<(?:[\w.-]+:)?prop(?:\s[^>]*)?>(.*?)</(?:[\w.-]+:)?prop>}s, body) do
      [_whole, inner] ->
        ~r{<(?:[\w.-]+:)?([\w.-]+)(?:\s[^>]*)?/?>}
        |> Regex.scan(inner)
        |> Enum.map(fn [_whole, name] -> name end)
        |> Enum.uniq()

      nil ->
        :allprop
    end
  end

  @doc """
  Which `REPORT` this is: `:sync_collection`, `:multiget`, `:query`, or
  `:unsupported`.
  """
  def report_type(body) when is_binary(body) do
    cond do
      String.contains?(body, "sync-collection") -> :sync_collection
      String.contains?(body, "addressbook-multiget") -> :multiget
      String.contains?(body, "addressbook-query") -> :query
      true -> :unsupported
    end
  end

  @doc "Every `<href>` in the body, in order — the resources a multiget names."
  def hrefs(body) when is_binary(body) do
    ~r{<(?:[\w.-]+:)?href(?:\s[^>]*)?>(.*?)</(?:[\w.-]+:)?href>}s
    |> Regex.scan(body)
    |> Enum.map(fn [_whole, href] -> href |> String.trim() |> unescape() end)
  end

  @doc """
  The `<sync-token>` a sync report carries, or `nil` for an initial sync (an
  empty element, an empty value, or no element at all all mean the same thing:
  "send me everything").
  """
  def sync_token(body) when is_binary(body) do
    case Regex.run(
           ~r{<(?:[\w.-]+:)?sync-token(?:\s[^>]*)?>(.*?)</(?:[\w.-]+:)?sync-token>}s,
           body
         ) do
      [_whole, token] -> token |> String.trim() |> nil_if_empty()
      nil -> nil
    end
  end

  @doc """
  The text content of the first element with this local name, or `nil`. Used to
  read a WebDAV-Push registration (`push-resource`, the two keys, `expires`).
  """
  def element_text(body, local_name) when is_binary(body) and is_binary(local_name) do
    pattern =
      Regex.compile!(
        "<(?:[\\w.-]+:)?" <>
          Regex.escape(local_name) <>
          "(?:\\s[^>]*)?>(.*?)</(?:[\\w.-]+:)?" <>
          Regex.escape(local_name) <> ">",
        "s"
      )

    case Regex.run(pattern, body) do
      [_whole, text] -> text |> String.trim() |> nil_if_empty()
      nil -> nil
    end
  end

  @doc "Whether an element with this local name appears at all."
  def element?(body, local_name) when is_binary(body) and is_binary(local_name) do
    Regex.match?(
      Regex.compile!("<(?:[\\w.-]+:)?" <> Regex.escape(local_name) <> "(?:[\\s/>])"),
      body
    )
  end

  @doc """
  Parses an IMF-fixdate (`Wed, 20 Dec 2023 10:03:31 GMT`), the format RFC 9110
  — and therefore WebDAV-Push's `<expires>` — uses. `nil` for anything else,
  because a client's date is not worth a 500.
  """
  def parse_http_date(nil), do: nil

  def parse_http_date(value) when is_binary(value) do
    case Regex.run(
           ~r/^[A-Za-z]{3},\s+(\d{2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$/,
           String.trim(value)
         ) do
      [_whole, day, month, year, hour, minute, second] ->
        build_date(month, [year, day, hour, minute, second])

      nil ->
        nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp build_date(month, parts) do
    with index when index != nil <- Enum.find_index(@months, &(&1 == month)),
         [year, day, hour, minute, second] <- Enum.map(parts, &String.to_integer/1),
         {:ok, naive} <- NaiveDateTime.new(year, index + 1, day, hour, minute, second) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _unparsable -> nil
    end
  end

  @doc """
  An IMF-fixdate for a response header. English names, as the format requires.

  Takes a naive stamp too, because that is what the database hands back for a
  card's `updated_at` and `getlastmodified` is the one property that needs it.
  """
  def http_date(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> http_date()

  def http_date(%DateTime{} = at), do: Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT")

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(token), do: unescape(token)

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end
end
