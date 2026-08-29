defmodule Vutuv.OpenGraphTest do
  @moduledoc """
  Reading a linked page's own preview (`Vutuv.OpenGraph`, issue #1706): the
  meta-tag parser on its own, and the guard rails around the fetch.

  `async: false` and it flips `:fetch_open_graph`, which every link-preview
  capture reads (`Vutuv.Posts.Screenshots.open_graph_capture/1`) — the test
  config keeps it off so no other test can dial out, and these turn it on for
  themselves.
  """
  use ExUnit.Case, async: false

  alias Vutuv.OpenGraph

  setup do
    put_config(:fetch_open_graph, true)
    on_exit(fn -> Application.delete_env(:vutuv, :open_graph_req_options) end)
    :ok
  end

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp stub(fun) when is_function(fun),
    do: Application.put_env(:vutuv, :open_graph_req_options, plug: fun)

  defp html(head), do: "<!doctype html><html><head>#{head}</head><body>hi</body></html>"

  describe "parse/2" do
    test "reads the four Open Graph properties" do
      meta =
        html("""
        <meta property="og:title" content="A headline">
        <meta property="og:description" content="A teaser sentence.">
        <meta property="og:site_name" content="Example Times">
        <meta property="og:image" content="https://example.test/card.jpg">
        """)
        |> OpenGraph.parse("https://example.test/article")

      assert meta.title == "A headline"
      assert meta.description == "A teaser sentence."
      assert meta.site_name == "Example Times"
      assert meta.image_url == "https://example.test/card.jpg"
    end

    test "single quotes, reversed attribute order and odd casing all read" do
      meta =
        html("<META CONTENT='A headline' PROPERTY='og:title'>")
        |> OpenGraph.parse("https://example.test/")

      assert meta.title == "A headline"
    end

    test "a twitter card stands in where og: is missing, and og: wins where both are there" do
      meta =
        html("""
        <meta name="twitter:title" content="From twitter">
        <meta name="twitter:image" content="https://example.test/t.png">
        <meta property="og:image" content="https://example.test/og.png">
        """)
        |> OpenGraph.parse("https://example.test/")

      assert meta.title == "From twitter"
      assert meta.image_url == "https://example.test/og.png"
    end

    test "entities in a value are decoded, named and numeric alike" do
      meta =
        html("""
        <meta property="og:title" content="Bild &amp; Ton: &#8222;Ja&#8220;">
        <meta property="og:image" content="https://example.test/c.jpg?a=1&amp;b=2">
        """)
        |> OpenGraph.parse("https://example.test/")

      assert meta.title == "Bild & Ton: „Ja“"
      assert meta.image_url == "https://example.test/c.jpg?a=1&b=2"
    end

    test "the punctuation a real headline is written with decodes by name too" do
      meta =
        html("""
        <meta property="og:title" content="Google&rsquo;s &ldquo;phone&rdquo; &mdash; reviewed&hellip;">
        """)
        |> OpenGraph.parse("https://example.test/")

      # The named spellings, which a page that writes entities at all uses for
      # everything. The numeric ones (`&#8217;`) already worked, which is
      # exactly why a card headline could ship reading `Google&rsquo;s`.
      assert meta.title == "Google’s “phone” — reviewed…"
    end

    test "the long tail of named entities decodes too, and case is not folded" do
      meta =
        html(~s(<meta property="og:title" content="Caf&eacute; &frac12; &Aacute;&aacute;">))
        |> OpenGraph.parse("https://example.test/")

      # `:mochiweb_charref` is the whole HTML5 table, so there is no edge to be
      # one entity away from. `&Aacute;` and `&aacute;` are different letters —
      # the hand-typed table this replaced downcased the name and would have
      # answered the same character for both.
      assert meta.title == "Café ½ Áá"
    end

    test "an entity nothing knows is left as text, not swallowed" do
      meta =
        html(~s(<meta property="og:title" content="a &notanentity; b">))
        |> OpenGraph.parse("https://example.test/")

      assert meta.title == "a &notanentity; b"
    end

    test "a NUL entity is refused rather than written into a title" do
      meta =
        html(~s(<meta property="og:title" content="a&#0;b">))
        |> OpenGraph.parse("https://example.test/")

      # A NUL byte is valid UTF-8 and Postgres is not: it answers 22021
      # `character_not_in_repertoire`, so this would raise inside
      # `mark_ready/2`'s `{:ok, _} = Repo.update()` and leave the job
      # `capturing` for `resume_stuck/0` to hand back without counting an
      # attempt — an unbounded retry loop driven by any page that emits `&#0;`.
      refute String.contains?(meta.title, <<0>>)
      assert meta.title == "a&#0;b"
    end

    test "a LITERAL NUL byte is refused too, which the entity guard cannot do" do
      # The sibling above covers `&#0;`, which `entity_text/2` declines to
      # build. This one is the byte itself, sitting in the attribute — not an
      # entity, so that guard never sees it, and `\s` does not match it either.
      # It rode all the way into `mark_ready/2`'s update until `normalise/2`
      # gained `RemoteHtml.scrub_nul/1`.
      meta =
        html(~s(<meta property="og:title" content="a) <> <<0>> <> ~s(b">))
        |> OpenGraph.parse("https://example.test/")

      refute String.contains?(meta.title, <<0>>)
      assert meta.title == "ab"
    end

    test "a LITERAL NUL in the <title> fallback is refused as well" do
      # The `<title>` is the other value `normalise/2` cleans, and it is the one
      # a page reaches without declaring any Open Graph at all.
      meta =
        html("<title>Bild" <> <<0>> <> " und Ton</title>")
        |> OpenGraph.parse("https://example.test/")

      refute String.contains?(meta.title, <<0>>)
      assert meta.title == "Bild und Ton"
    end

    test "a relative or protocol-relative image is resolved against the page" do
      assert OpenGraph.parse(
               html(~s(<meta property="og:image" content="/img/card.jpg">)),
               "https://example.test/news/article?x=1"
             ).image_url == "https://example.test/img/card.jpg"

      assert OpenGraph.parse(
               html(~s(<meta property="og:image" content="//cdn.example.test/c.jpg">)),
               "https://example.test/news"
             ).image_url == "https://cdn.example.test/c.jpg"
    end

    test "a commented-out meta block is not the page's preview" do
      meta =
        html("""
        <!-- <meta property="og:title" content="Draft headline"> -->
        <meta property="og:title" content="Real headline">
        """)
        |> OpenGraph.parse("https://example.test/")

      assert meta.title == "Real headline"
    end

    test "a repeated property keeps the page's first choice" do
      meta =
        html("""
        <meta property="og:image" content="https://example.test/first.jpg">
        <meta property="og:image" content="https://example.test/second.jpg">
        """)
        |> OpenGraph.parse("https://example.test/")

      assert meta.image_url == "https://example.test/first.jpg"
    end

    test "whitespace is collapsed and an empty value counts as absent" do
      meta =
        html("""
        <meta property="og:title" content="A
              wrapped   headline">
        <meta property="og:description" content="   ">
        """)
        |> OpenGraph.parse("https://example.test/")

      assert meta.title == "A wrapped headline"
      assert meta.description == nil
    end

    test "an over-long description is cut to the display cap" do
      long = String.duplicate("a", 3000)

      meta =
        html(~s(<meta property="og:description" content="#{long}">))
        |> OpenGraph.parse("https://example.test/")

      assert String.length(meta.description) == 1000
    end

    test "a page with no meta tags at all yields nils, not a crash" do
      assert OpenGraph.parse("<html><body>plain</body></html>", "https://example.test/") ==
               %{title: nil, description: nil, site_name: nil, image_url: nil}
    end

    test "the <title> element stands in when og:title is missing" do
      meta =
        "<html><head><title>Plain old page</title></head><body>hi</body></html>"
        |> OpenGraph.parse("https://example.test/article")

      assert meta.title == "Plain old page"
    end

    test "og:title beats the <title> element" do
      meta =
        ~s(<html><head><title>SEO tail | Example</title>) <>
          ~s(<meta property="og:title" content="The headline"></head></html>)

      assert OpenGraph.parse(meta, "https://example.test/article").title == "The headline"
    end

    test "a <title> gets the same entity decoding and whitespace collapse as a meta value" do
      meta =
        "<html><head><title>\n  Bild &amp; Ton\n  </title></head></html>"
        |> OpenGraph.parse("https://example.test/article")

      assert meta.title == "Bild & Ton"
    end

    test "a commented-out <title> is not the page's headline either" do
      meta =
        "<html><head><!-- <title>Old draft</title> --><title>Real</title></head></html>"
        |> OpenGraph.parse("https://example.test/article")

      assert meta.title == "Real"
    end

    test "an empty <title> counts as absent" do
      meta =
        "<html><head><title>   </title></head></html>"
        |> OpenGraph.parse("https://example.test/article")

      assert meta.title == nil
    end
  end

  describe "fetch/1" do
    defp respond(conn, status, type, body) do
      conn
      |> Plug.Conn.put_resp_content_type(type, nil)
      |> Plug.Conn.send_resp(status, body)
    end

    test "returns the page's preview and the host it came from" do
      stub(fn conn ->
        respond(
          conn,
          200,
          "text/html",
          html("""
          <meta property="og:title" content="A headline">
          <meta property="og:image" content="https://example.test/c.jpg">
          """)
        )
      end)

      assert {:ok, meta} = OpenGraph.fetch("https://example.test/article")
      assert meta.title == "A headline"
      assert meta.host == "example.test"
    end

    test "a page that declares no image still yields its words" do
      stub(fn conn ->
        respond(conn, 200, "text/html", html(~s(<meta property="og:title" content="Just words">)))
      end)

      assert {:ok, meta} = OpenGraph.fetch("https://example.test/article")
      assert meta.title == "Just words"
      assert meta.image_url == nil
    end

    test "a page with no meta tags at all is carried by its <title>" do
      stub(fn conn ->
        respond(conn, 200, "text/html", "<html><head><title>Plain page</title></head></html>")
      end)

      assert {:ok, meta} = OpenGraph.fetch("https://example.test/article")
      assert meta.title == "Plain page"
    end

    test "a page with neither is no card at all" do
      stub(fn conn -> respond(conn, 200, "text/html", html("")) end)
      assert OpenGraph.fetch("https://example.test/article") == :error
    end

    test "a redirect is not followed — the linked page is the page" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 301, "") end)
      assert OpenGraph.fetch("https://example.test/article") == :error
    end

    test "a non-HTML answer is never parsed" do
      stub(fn conn ->
        respond(conn, 200, "application/pdf", ~s(<meta property="og:title" content="x">))
      end)

      assert OpenGraph.fetch("https://example.test/paper") == :error
    end

    test "an internal host is refused before any request goes out" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :requested)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert OpenGraph.fetch("http://localhost/admin") == :error
      assert OpenGraph.fetch("http://127.0.0.1/admin") == :error
      refute_received :requested
    end

    test "the flag off means nothing is fetched at all" do
      put_config(:fetch_open_graph, false)
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :requested)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert OpenGraph.fetch("https://example.test/article") == :error
      refute_received :requested
    end
  end

  describe "fetch_image/1" do
    test "returns the bytes and the extension for each accepted format" do
      for {type, extension} <- [
            {"image/jpeg", ".jpg"},
            {"image/png", ".png"},
            {"image/webp", ".webp"}
          ] do
        stub(fn conn -> respond(conn, 200, type, "IMAGEBYTES") end)

        assert OpenGraph.fetch_image("https://example.test/c") == {:ok, "IMAGEBYTES", extension}
      end
    end

    test "a format the uploader cannot store falls through" do
      stub(fn conn -> respond(conn, 200, "image/avif", "IMAGEBYTES") end)
      assert OpenGraph.fetch_image("https://example.test/c.avif") == :error
    end

    test "an HTML answer dressed as an image is refused" do
      stub(fn conn -> respond(conn, 200, "text/html", "<html>nope</html>") end)
      assert OpenGraph.fetch_image("https://example.test/c.jpg") == :error
    end

    test "an internal host is refused before any request goes out" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :requested)
        respond(conn, 200, "image/png", "IMAGEBYTES")
      end)

      assert OpenGraph.fetch_image("http://169.254.169.254/latest/meta-data/") == :error
      refute_received :requested
    end
  end
end
