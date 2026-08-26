defmodule Vutuv.OpenGraph do
  @moduledoc """
  Reads the preview a linked page publishes **about itself** — the Open Graph
  protocol's `og:title` / `og:description` / `og:site_name` / `og:image` — so a
  post that links to it can show the publisher's own headline, teaser and
  artwork instead of a headless-Chromium photograph of the page
  (`Vutuv.Posts.Screenshots`, which keeps the capture as the fallback).

  This is the generic form of what `Vutuv.YoutubeThumbnail` does for one site:
  ask the publisher rather than photograph them. No per-site list is involved
  and nothing is embedded — the metadata is fetched server-side and the image is
  stored through our own uploader, so a reader's browser never talks to the
  linked host and no viewer IP leaks to it.

  **Twitter cards count as Open Graph here.** A page that carries only
  `twitter:title` / `twitter:description` / `twitter:image` means the same thing
  by them, and reading both costs one extra clause; `og:` always wins.

  **The parser is deliberately not an HTML parser.** All that is needed are the
  `<meta>` tags in the document head, so the body is scanned for those tags and
  their attributes with a regex, and the handful of HTML entities that appear in
  attribute values are decoded (`decode_entities/1`). Only the first
  `@max_head_bytes` of the answer are read, since a preview declared halfway
  down a megabyte of markup is not one this installation is going to find.

  Gated by the `:fetch_open_graph` config flag (an intranet installation runs
  air-gapped, and an operator may prefer never to fetch a third party's
  metadata); tests stub HTTP through the `:open_graph_req_options` seam, exactly
  like the YouTube and probe paths.
  """

  alias Vutuv.RemoteHtml
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post
  alias Vutuv.Ssrf

  @req_options_key :open_graph_req_options

  # The head is at the top of the document; a page that has not declared its
  # preview within this much markup does not get one. Also the receive cap, so
  # a hostile endpoint streaming forever is dropped during receipt.
  @max_head_bytes 512 * 1024

  # An og:image we are willing to store. Bounded because it is fetched from an
  # untrusted host, and restricted to the three formats the screenshot uploader
  # accepts (`Vutuv.Screenshot`'s extension whitelist) — an AVIF or SVG
  # og:image falls back to the ordinary capture rather than growing a converter.
  @max_image_bytes 5 * 1024 * 1024
  @image_types %{"image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp"}
  # Never store a format the uploader would reject: the extensions above are
  # checked against `Vutuv.Screenshot`'s own whitelist at compile time, so
  # narrowing that list cannot quietly leave this map behind.
  @unstorable Map.values(@image_types) -- Vutuv.Screenshot.extension_whitelist()
  if @unstorable != [] do
    raise "og:image extensions the uploader rejects: #{inspect(@unstorable)}"
  end

  # Display caps. The columns are `text`, so these are about what a card can
  # show, not what Postgres can hold: a title over two lines and a teaser over
  # two are clamped in the markup anyway, and a page that puts an essay in its
  # og:description should not fill the row with it.
  @max_title 300
  @max_description 1000
  @max_site_name 100

  @doc "Display cap on a card's headline; `Vutuv.Posts.PostScreenshot` validates against it."
  def max_title, do: @max_title

  @doc "Display cap on a card's teaser."
  def max_description, do: @max_description

  @doc "Display cap on a card's site name."
  def max_site_name, do: @max_site_name

  @doc """
  The preview `url` publishes about itself: `{:ok, meta}` with at least
  `:title` and `:image_url` set, or `:error`.

  `:error` covers everything that is not a usable card — the flag is off, the
  host is internal, the page did not answer a plain HTTP 200 (a redirect is not
  followed, matching the capture path's rule), it is not HTML, or it declares no
  title/image. The caller then captures the page as before, so a page without
  Open Graph tags is exactly as well served as it is today.
  """
  def fetch(url) when is_binary(url) do
    with true <- enabled?(),
         {:ok, host} <- external_host(url),
         {:ok, %Req.Response{status: 200} = resp} <-
           get(url, "text/html,application/xhtml+xml", @max_head_bytes),
         true <- html?(resp),
         body when is_binary(body) <- resp.body,
         %{title: title, image_url: image} = meta when is_binary(title) and is_binary(image) <-
           parse(body, url) do
      {:ok, Map.put(meta, :host, host)}
    else
      _other -> :error
    end
  rescue
    _error -> :error
  end

  def fetch(_url), do: :error

  @doc """
  Fetches a card's image: `{:ok, bytes, extension}` or `:error`. Same guard rail
  as the remote-avatar fetch (`Vutuv.SocialFeed.Http.fetch_avatar/2`) — the URL
  comes out of an untrusted page, so the host is SSRF-vetted, the answer must be
  a real image of a format the uploader accepts, and the size is capped.

  The bytes go through the ordinary screenshot uploader afterwards, which runs
  them past AI image moderation like any other capture: a page is free to
  declare anything as its `og:image`, and that must not become a bypass of the
  gate an uploaded picture goes through.
  """
  def fetch_image(image_url) when is_binary(image_url) do
    with true <- enabled?(),
         {:ok, _host} <- external_host(image_url),
         {:ok, %Req.Response{status: 200, body: body} = resp} <-
           get(image_url, "image/*", @max_image_bytes),
         extension when is_binary(extension) <- @image_types[Http.content_type(resp)],
         true <- is_binary(body) and body != "" and byte_size(body) <= @max_image_bytes do
      {:ok, body, extension}
    else
      _other -> :error
    end
  rescue
    _error -> :error
  end

  def fetch_image(_image_url), do: :error

  @doc "Whether this installation reads linked pages' Open Graph metadata at all."
  def enabled?, do: Application.get_env(:vutuv, :fetch_open_graph, true)

  @doc """
  The Open Graph metadata in an HTML document, as
  `%{title:, description:, site_name:, image_url:}` — each value `nil` when the
  page does not declare it. `page_url` resolves a relative `og:image` (the
  protocol asks for an absolute URL and plenty of pages ignore that).

  Public because it is the part worth testing on its own: the fetch around it is
  guard rails, this is the reading.
  """
  def parse(html, page_url) when is_binary(html) do
    tags = html |> capped() |> strip_comments() |> head_slice() |> meta_tags()

    %{
      title: pick(tags, ["og:title", "twitter:title"], @max_title),
      description: pick(tags, ["og:description", "twitter:description"], @max_description),
      site_name: pick(tags, ["og:site_name"], @max_site_name),
      image_url:
        tags
        |> pick(["og:image:secure_url", "og:image", "twitter:image"], 2000)
        |> absolute(page_url)
    }
  end

  @meta_regex ~r/<meta\s[^>]*>/i

  # Every `<meta …>` tag's attributes, as a map from the `property`/`name` key
  # (downcased) to its `content`. First declaration wins — a page repeating
  # `og:image` means the first one is its primary choice. The attribute-quoting
  # grammar is `Vutuv.RemoteHtml.tag_attributes/1`, shared with the `rel=me`
  # scan so a fix to it cannot leave one of the two behind.
  defp meta_tags(html) do
    @meta_regex
    |> Regex.scan(html)
    |> Enum.reduce(%{}, fn [tag], acc ->
      attrs = RemoteHtml.tag_attributes(tag)
      key = attrs["property"] || attrs["name"]
      content = attrs["content"]

      if is_binary(key) and is_binary(content) and not Map.has_key?(acc, key),
        do: Map.put(acc, key, content),
        else: acc
    end)
  end

  # `binary_slice/3` rather than `String.slice/3`: this is a byte cap, and
  # counting graphemes would walk the whole buffer to answer the same thing.
  defp capped(html), do: binary_slice(html, 0, @max_head_bytes)

  # The tags live in the document head, so cut there: the body is where the
  # megabytes are and none of it can carry a preview. Runs **after**
  # `strip_comments/1`, because a commented-out `<!-- <body …> -->` sitting
  # above the real tags would otherwise cut the head short and lose them.
  defp head_slice(html) do
    case :binary.match(html, ["</head", "</HEAD", "<body", "<BODY"]) do
      {at, _length} -> binary_part(html, 0, at)
      :nomatch -> html
    end
  end

  # An HTML comment can hold a whole second `<meta>` block (a commented-out
  # template, a conditional comment), and picking a preview out of one would
  # show something the page does not.
  #
  # Split rather than `String.replace(~r/<!--.*?-->/s, "")`: on markup with an
  # **unclosed** `<!--` the lazy regex expands to the end of the buffer and then
  # retries from every later `<!--`, which is quadratic in how many there are —
  # and this runs on a single sequential worker, so one hostile page would hold
  # up every other member's link preview. Splitting is Boyer-Moore and cannot
  # backtrack. An unclosed comment swallows the rest of the head, which is what
  # a browser does with it too.
  defp strip_comments(html) do
    case :binary.split(html, "<!--", [:global]) do
      [only] -> only
      [first | rest] -> IO.iodata_to_binary([first | Enum.map(rest, &after_comment/1)])
    end
  end

  defp after_comment(segment) do
    case :binary.split(segment, "-->") do
      [_comment, tail] -> tail
      [_unclosed] -> ""
    end
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  @entity_regex ~r/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);/

  # The HTML entities that turn up in a `content` attribute, named and numeric.
  # Without this a card headline reads `Bild &amp; Ton`, and an `&amp;` inside
  # an `og:image` URL breaks the fetch.
  #
  # One pass, not a chain of replacements: a chain has to decode `&amp;` LAST or
  # a literal `&amp;amp;` unescapes twice, and that ordering is a rule somebody
  # has to remember (`Vutuv.RemoteHtml` states it in a comment for exactly this
  # reason). A single pass cannot double-decode at all. An entity this does not
  # know is left standing rather than swallowed.
  defp decode_entities(value) do
    Regex.replace(@entity_regex, value, fn whole, body -> entity(body, whole) end)
  end

  defp entity(<<?#, marker, digits::binary>>, whole) when marker in [?x, ?X],
    do: digits |> Integer.parse(16) |> codepoint(whole)

  defp entity(<<?#, digits::binary>>, whole), do: digits |> Integer.parse() |> codepoint(whole)
  defp entity(name, whole), do: Map.get(@entities, String.downcase(name), whole)

  # A lone surrogate is not a codepoint `<<n::utf8>>` can build (it raises), and
  # neither is a number past the Unicode range: leave those entities as text.
  defp codepoint({number, ""}, _whole)
       when number in 0..0xD7FF or number in 0xE000..0x10FFFF,
       do: <<number::utf8>>

  defp codepoint(_parsed, whole), do: whole

  # The first of `keys` the page declares: entities decoded, whitespace collapsed
  # to single spaces (a `content` attribute may hold newlines), trimmed, and
  # clamped through the same ellipsis clamp every other remote text goes
  # through — a cut teaser should not read as if the publisher wrote it that
  # way. nil when none of the keys carries anything but whitespace.
  defp pick(tags, keys, max) do
    case Enum.find_value(keys, &Map.get(tags, &1)) do
      value when is_binary(value) ->
        value
        |> decode_entities()
        |> String.replace(~r/\s+/u, " ")
        |> Post.presence()
        |> clamp(max)

      _missing ->
        nil
    end
  end

  defp clamp(nil, _max), do: nil
  defp clamp(value, max), do: Post.truncate(value, max)

  # A relative or protocol-relative og:image resolved against the page it was
  # declared on; anything that is not http(s) afterwards is dropped.
  defp absolute(nil, _page_url), do: nil

  defp absolute(image_url, page_url) do
    case page_url |> URI.merge(image_url) |> to_string() |> URI.parse() do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        to_string(uri)

      _other ->
        nil
    end
  rescue
    _error -> nil
  end

  # The host, once it is an outside one we may talk to. `resolves_to_internal?`
  # answers true for anything unresolvable too, so this is also the "is that a
  # real address" check.
  defp external_host(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if Ssrf.resolves_to_internal?(host), do: :error, else: {:ok, host}

      _other ->
        :error
    end
  end

  defp html?(resp), do: Http.content_type(resp) in ["text/html", "application/xhtml+xml"]

  # The guard rails — no retry, **no redirect** (the page the member linked is
  # the page whose preview we show, the same rule the capture path applies),
  # `decode_body: false`, the capped collector, this installation's User-Agent —
  # are `Http.base_options/3`, shared with every other outbound fetch rather
  # than copied here for the fourth time. Only the timeouts differ: a web page
  # is bigger than an API answer and worth a little longer, but not long enough
  # to hold up the queue behind it.
  defp get(url, accept, max_bytes) do
    url
    |> Http.base_options(max_bytes, accept)
    |> Keyword.merge(receive_timeout: 8_000, connect_options: [timeout: 4_000])
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
  end
end
