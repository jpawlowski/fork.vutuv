defmodule VutuvWeb.AgentDocs.RemoteQuoteDocTest do
  @moduledoc """
  What a cached post's **quote** (issue #1609) reads as in the agent formats.

  The HTML card shows the quoted author and their words, so the `.md`/`.txt`/
  `.json`/`.xml` siblings of the three public pages that render that card — the
  profile, the post archive and `/tags/:slug` — have to carry the same fact.
  Without it an entry whose whole content is a reaction ("genau das") reads as a
  post with nothing in it, the same gap `pictures:` was added to close.

  Consent decides how a **person** is shown a quote, not whether a machine is
  told about one: a link-only quote is the same fact to an agent as a card.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts.Post
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.JSON
  alias VutuvWeb.AgentDocs.Markdown
  alias VutuvWeb.AgentDocs.PostDoc
  alias VutuvWeb.AgentDocs.Text
  alias VutuvWeb.AgentDocs.Xml

  @quoted_uri "https://third.example/notes/1"

  setup do
    Gettext.put_locale(VutuvWeb.Gettext, "en")
    :ok
  end

  defp author,
    do: %RemoteAccount{
      actor_uri: "https://third.example/users/autorin",
      host: "third.example",
      handle: "autorin",
      name: "Die Autorin"
    }

  defp quoted,
    do: %RemotePost{
      id: "01a0-quoted",
      object_uri: @quoted_uri,
      origin_url: "https://third.example/@autorin/1",
      content_text: "Der zitierte Satz.",
      remote_account: author()
    }

  defp quoting(attrs) do
    Map.merge(
      %RemotePost{
        id: "01a0-quoting",
        object_uri: "https://social.example/posts/1",
        origin_url: "https://social.example/@them/1",
        content_text: "Genau das.",
        published_at: ~U[2026-08-20 09:00:00Z],
        remote_account: %RemoteAccount{
          actor_uri: "https://social.example/users/them",
          host: "social.example",
          handle: "them",
          name: "Them"
        }
      },
      attrs
    )
  end

  defp entry(post), do: PostDoc.timeline_entry(%{remote_post: post})

  test "a post that quotes nothing carries no quote fact" do
    assert entry(quoting(%{})).quote == nil
    refute Markdown.quote_suffix(entry(quoting(%{}))) =~ "Quotes"
  end

  test "a resolved quote names where it lives and who wrote it" do
    fact =
      entry(
        quoting(%{quote_uri: @quoted_uri, quoted_post_id: "01a0-quoted", quoted_post: quoted()})
      ).quote

    # The browsable URL, not the canonical AP id: on several servers the id is
    # not a page a reader can open.
    assert fact == %{
             url: "https://third.example/@autorin/1",
             author: "Die Autorin",
             network: "fediverse"
           }
  end

  test "an unresolved quote still hands over the address" do
    fact = entry(quoting(%{quote_uri: @quoted_uri})).quote

    assert fact == %{url: @quoted_uri, author: nil, network: "fediverse"}
  end

  test "a quote of one of our posts is named as a vutuv post" do
    local = %Post{id: "01a0-local", organization_id: nil, user: %User{username: "stefan"}}

    fact =
      entry(
        quoting(%{
          quote_uri: "https://www.vutuv.test/stefan/posts/01a0-local",
          quoted_local_post_id: local.id,
          quoted_local_post: local
        })
      ).quote

    assert fact.network == "vutuv"
    assert fact.url =~ "/stefan/posts/01a0-local"
  end

  test "all four formats say it" do
    doc =
      AgentDocs.doc_meta("post_archive", "/stefan/posts")
      |> Map.merge(%{
        title: "Stefan · Posts",
        description: "Post archive",
        author: %{name: "Stefan", url: "https://vutuv.test/stefan"},
        period: nil,
        total: 1,
        posts: [
          entry(
            quoting(%{
              quote_uri: @quoted_uri,
              quoted_post_id: "01a0-quoted",
              quoted_post: quoted()
            })
          )
        ]
      })

    for {name, rendered} <- [
          {"markdown", Markdown.render(doc)},
          {"text", Text.render(doc)},
          {"json", JSON.render(doc)},
          {"xml", Xml.render(doc)}
        ] do
      assert rendered =~ "third.example/@autorin/1", "#{name} lost the quoted URL"
      assert rendered =~ "Die Autorin", "#{name} lost the quoted author"
    end
  end

  test "German names it a quote rather than a reply" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    suffix =
      Markdown.quote_suffix(
        entry(
          quoting(%{quote_uri: @quoted_uri, quoted_post_id: "01a0-quoted", quoted_post: quoted()})
        )
      )

    assert suffix =~ "Zitiert"
  end
end
