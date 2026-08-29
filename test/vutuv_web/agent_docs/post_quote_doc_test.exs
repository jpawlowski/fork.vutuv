defmodule VutuvWeb.AgentDocs.PostQuoteDocTest do
  @moduledoc """
  The post a quote carries, in the permalink's agent formats (issue #1610).

  The HTML card shows who wrote the quoted post, links to it and prints a few
  lines of it, so the `.md` / `.txt` / `.json` / `.xml` siblings have to say the
  same — that is the contract `agent_docs_drift_test.exs` enforces in general
  and this file spells out for quotes, including the three states the card
  degrades to.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.Post

  defp formats_for(path) do
    %{
      html: get(build_conn(), path) |> html_response(200),
      md: get(build_conn(), path <> ".md").resp_body,
      txt: get(build_conn(), path <> ".txt").resp_body,
      json: get(build_conn(), path <> ".json").resp_body,
      xml: get(build_conn(), path <> ".xml").resp_body
    }
  end

  defp quote_of(json), do: Jason.decode!(json)["quote_of"]

  setup do
    author = insert_activated_user(first_name: "Olga", last_name: "Original")
    quoter = insert_activated_user(first_name: "Quinn", last_name: "Quoter")
    quoted = create_post!(author, %{body: "Suspension bridges are underrated."})
    {:ok, post} = Posts.create_quote(quoter, quoted, %{body: "Exactly right."})

    %{author: author, quoter: quoter, quoted: quoted, post: post}
  end

  test "names the quoted post's author, links it and carries its text", ctx do
    rendered = formats_for(Posts.path(ctx.post))

    for {format, body} <- rendered do
      assert body =~ "Suspension bridges are underrated.",
             "the quoted post's text is missing from the #{format} version"
    end

    assert rendered.md =~ "Quoting a post by [Olga Original]"
    assert rendered.txt =~ "Quoting a post by Olga Original."
    assert rendered.txt =~ Posts.path(ctx.quoted)

    assert %{"state" => "post", "author" => "Olga Original"} = quote_of(rendered.json)
    assert quote_of(rendered.json)["url"] =~ Posts.path(ctx.quoted)
    assert rendered.xml =~ "<quote_of>"
  end

  test "the quote count joins the engagement line once somebody has quoted", ctx do
    rendered = formats_for(Posts.path(ctx.quoted))

    assert Jason.decode!(rendered.json)["quote_count"] == 1
    assert rendered.md =~ "Quotes: 1"
    assert rendered.txt =~ "Quotes: 1"
  end

  test "a post nobody quoted keeps its counts line as it was", ctx do
    plain = create_post!(ctx.author, %{body: "Nothing to do with bridges."})

    rendered = formats_for(Posts.path(plain))

    assert Jason.decode!(rendered.json)["quote_count"] == 0
    assert Jason.decode!(rendered.json)["quote_of"] == nil
    refute rendered.md =~ "Quotes:"
  end

  test "a deleted quoted post degrades to its author's name", ctx do
    {:ok, _} = Posts.delete_post(ctx.quoted)

    rendered = formats_for(Posts.path(ctx.post))

    assert rendered.md =~ "Quoting a now-deleted post by Olga Original."
    assert rendered.txt =~ "Quoting a now-deleted post by Olga Original."
    assert %{"state" => "deleted", "url" => nil} = quote_of(rendered.json)
    refute rendered.md =~ "Suspension bridges are underrated."
  end

  test "a frozen quoted post is withheld rather than quoted", ctx do
    Repo.update_all(from(p in Post, where: p.id == ^ctx.quoted.id),
      set: [frozen_at: NaiveDateTime.utc_now(:second)]
    )

    rendered = formats_for(Posts.path(ctx.post))

    assert rendered.md =~ "The quoted post is not available."
    assert %{"state" => "unavailable", "author" => nil} = quote_of(rendered.json)
    refute rendered.txt =~ "Suspension bridges are underrated."
  end
end
