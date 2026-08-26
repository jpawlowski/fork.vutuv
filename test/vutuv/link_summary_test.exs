defmodule Vutuv.LinkSummaryTest do
  @moduledoc """
  The tooltip's sentence (issue #1709): the page fetch, what is handed to the
  model, and the cap that makes "at most 200 characters" a promise rather than
  a request.

  Both halves run against `plug:` stubs — the page through
  `:link_summary_req_options`, Ollama through `:link_summary_ollama_req_options`
  — so nothing here touches a network or a model. `async: false`: those keys
  are global application env, and so is the feature flag.
  """
  use ExUnit.Case, async: false

  alias Vutuv.LinkSummary

  @url "https://example.com/artikel"

  # Long enough to pass the "is there anything here to summarise" floor, which
  # is what keeps an empty shell of a page from reaching the model at all.
  @page_text String.duplicate("Ein Absatz über den Bau von Fahrradwegen. ", 12)

  setup do
    Application.put_env(:vutuv, :summarize_links, true)

    on_exit(fn ->
      Application.delete_env(:vutuv, :summarize_links)
      Application.delete_env(:vutuv, :link_summary_req_options)
      Application.delete_env(:vutuv, :link_summary_ollama_req_options)
    end)

    :ok
  end

  defp stub_page(fun), do: Application.put_env(:vutuv, :link_summary_req_options, plug: fun)

  defp stub_page_html(html) do
    stub_page(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, html)
    end)
  end

  defp stub_model(fun),
    do: Application.put_env(:vutuv, :link_summary_ollama_req_options, plug: fun)

  # The real Ollama answers `/api/chat` with the model's JSON inside the
  # assistant message, under a real JSON content-type — a stub that sends a
  # bare body would hand the client a binary the live server never sends.
  defp stub_summary(summary, on_body \\ fn _body -> :ok end) do
    stub_model(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 5_000_000)
      on_body.(Jason.decode!(raw))

      body = %{
        "message" => %{"role" => "assistant", "content" => Jason.encode!(%{summary: summary})}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  defp page(body), do: "<html><head><title>Radwege</title></head><body>#{body}</body></html>"

  describe "the installation's choice" do
    test "an installation that does not summarise links never fetches anything" do
      Application.put_env(:vutuv, :summarize_links, false)
      stub_page(fn _conn -> flunk("the page must not be fetched when the flag is off") end)

      assert LinkSummary.summarize(@url) == {:error, :disabled}
    end
  end

  describe "reading the page" do
    test "summarises what the page says" do
      stub_page_html(page("<p>#{@page_text}</p>"))
      stub_summary("Ein Bericht über den Ausbau der Radwege in Frankfurt.")

      assert LinkSummary.summarize(@url) ==
               {:ok, "Ein Bericht über den Ausbau der Radwege in Frankfurt."}
    end

    test "hands the model the page's prose, not its scripts" do
      parent = self()

      stub_page_html(
        page("<script>var tracking = 'analytics beacon';</script><p>#{@page_text}</p>")
      )

      stub_summary("Radwege.", fn body ->
        send(parent, {:prompt, hd(body["messages"])["content"]})
      end)

      assert {:ok, _summary} = LinkSummary.summarize(@url)
      assert_receive {:prompt, prompt}

      # `<script>` goes with its contents — `strip_tags/1` alone would keep the
      # JavaScript as text and spend the model's context (and its attention) on
      # a tracking beacon.
      assert prompt =~ "Fahrradwegen"
      refute prompt =~ "analytics beacon"
      assert prompt =~ @url
    end

    test "a page that is not served as UTF-8 still reaches the model" do
      # German pages served as ISO-8859-1 are still common, and nothing on the
      # way here minds: neither the strip nor the whitespace pass touches the
      # bytes, and `Jason` then raises while encoding the request. The caller
      # only ever saw that as a rescued crash and a tooltip that never came.
      parent = self()

      latin1 =
        "<html><body><p>" <>
          String.duplicate("Gr" <> <<0xFC>> <> "ne Radwege in K" <> <<0xF6>> <> "ln. ", 12) <>
          "</p></body></html>"

      stub_page(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, latin1)
      end)

      stub_summary("Radwege in der Stadt.", fn body ->
        send(parent, {:prompt, hd(body["messages"])["content"]})
      end)

      assert LinkSummary.summarize(@url) == {:ok, "Radwege in der Stadt."}
      assert_receive {:prompt, prompt}
      assert String.valid?(prompt)
      assert prompt =~ "Radwege"
    end

    test "a page with nothing readable is not worth a model call" do
      stub_page_html(page("<p>Hallo.</p>"))
      stub_model(fn _conn -> flunk("an empty page must not reach the model") end)

      assert LinkSummary.summarize(@url) == {:error, :no_text}
    end

    test "a page that does not answer 200 is skipped" do
      stub_page(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert LinkSummary.summarize(@url) == {:error, {:status, 404}}
    end

    test "an internal host is never fetched" do
      stub_page(fn _conn -> flunk("an internal host must not be fetched") end)

      assert LinkSummary.summarize("http://127.0.0.1/admin") == {:error, :internal_target}
    end
  end

  describe "trusting the answer" do
    test "an over-long answer is cut at a word, not stored whole" do
      stub_page_html(page("<p>#{@page_text}</p>"))
      stub_summary(String.duplicate("Fahrradweg ", 60))

      assert {:ok, summary} = LinkSummary.summarize(@url)

      # The cap is what makes it a tooltip: a model that ignores the character
      # budget must not be able to push a wall of text into a member's post.
      assert String.length(summary) <= LinkSummary.max_chars()
      assert String.ends_with?(summary, "…")
      refute String.ends_with?(summary, "Fahrradwe…")
    end

    test "an answer of exactly the cap is left alone" do
      stub_page_html(page("<p>#{@page_text}</p>"))
      exact = String.duplicate("a", LinkSummary.max_chars())
      stub_summary(exact)

      assert LinkSummary.summarize(@url) == {:ok, exact}
    end

    test "quotation marks and line breaks the model adds are removed" do
      stub_page_html(page("<p>#{@page_text}</p>"))
      stub_summary(~s("Ein Bericht\nüber Radwege."))

      assert LinkSummary.summarize(@url) == {:ok, "Ein Bericht über Radwege."}
    end

    test "an empty answer is a failure, not an empty tooltip" do
      stub_page_html(page("<p>#{@page_text}</p>"))
      stub_summary("   ")

      assert LinkSummary.summarize(@url) == {:error, {:content, :empty}}
    end

    test "an answer that is not the agreed shape is refused" do
      stub_page_html(page("<p>#{@page_text}</p>"))

      stub_model(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"message" => %{"content" => "not json"}}))
      end)

      assert LinkSummary.summarize(@url) == {:error, {:content, :bad_answer}}
    end

    test "an unreachable model is a service failure, not a content one" do
      stub_page_html(page("<p>#{@page_text}</p>"))
      stub_model(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, {:service, _reason}} = LinkSummary.summarize(@url)
    end
  end
end
