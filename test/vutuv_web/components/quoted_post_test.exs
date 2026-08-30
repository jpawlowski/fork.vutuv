defmodule VutuvWeb.QuotedPostTest do
  @moduledoc """
  What a post from another network shows for what it quotes (issue #1609).

  The three states are the point: a card only where the quoted author's consent
  was established, a link everywhere else, and nothing at all where the author
  already wrote that link into their own text. The German is asserted by name
  because "Quoted post" is exactly the kind of short string a `gettext.extract
  --merge` fuzzy-fills with somebody else's translation.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts.Post
  alias VutuvWeb.PostComponents

  @quoted_uri "https://third.example/notes/1"

  setup do
    Gettext.put_locale(VutuvWeb.Gettext, "en")
    :ok
  end

  defp author,
    do: %RemoteAccount{
      id: "01a0-account",
      actor_uri: "https://third.example/users/autorin",
      host: "third.example",
      handle: "autorin",
      name: "Die Autorin"
    }

  defp quoted(attrs \\ %{}) do
    Map.merge(
      %RemotePost{
        id: "01a0-quoted",
        object_uri: @quoted_uri,
        origin_url: "https://third.example/@autorin/1",
        content_text: "Der zitierte Satz.",
        audience: "public",
        remote_account: author()
      },
      attrs
    )
  end

  defp quoting(attrs) do
    Map.merge(
      %RemotePost{
        id: "01a0-quoting",
        object_uri: "https://social.example/posts/1",
        content_text: "Sehr treffend.",
        audience: "public"
      },
      attrs
    )
  end

  defp render_quote(post), do: render_component(&PostComponents.quoted_post/1, remote_post: post)

  test "a post that quotes nothing renders nothing" do
    html = render_quote(quoting(%{}))

    refute html =~ "data-quoted-post"
    refute html =~ "Quoted post"
  end

  test "an unverified quote is a link, never a card" do
    html = render_quote(quoting(%{quote_uri: @quoted_uri, quoted_post: quoted()}))

    assert html =~ ~s(data-quoted-post-link="#{@quoted_uri}")
    assert html =~ "Quoted post"
    assert html =~ @quoted_uri
    # The quoted author's words are not shown on the quoting server's say-so.
    refute html =~ "Der zitierte Satz."
  end

  test "a verified quote is the card, with who wrote it and what it says" do
    html =
      render_quote(
        quoting(%{
          quote_uri: @quoted_uri,
          quote_verified: true,
          quoted_post_id: "01a0-quoted",
          quoted_post: quoted()
        })
      )

    assert html =~ ~s(data-quoted-post="01a0-quoted")
    assert html =~ "Die Autorin"
    assert html =~ "@autorin@third.example"
    assert html =~ "Der zitierte Satz."
    # The whole tile is the way out; there is no second link beside it.
    assert html =~ "https://third.example/@autorin/1"
    refute html =~ "Quoted post"
  end

  test "a warned quoted post shows the warning instead of its text" do
    warned = quoted(%{summary: "Spoiler zum Tatort", sensitive: true})

    html =
      render_quote(
        quoting(%{
          quote_uri: @quoted_uri,
          quote_verified: true,
          quoted_post_id: "01a0-quoted",
          quoted_post: warned
        })
      )

    assert html =~ "Spoiler zum Tatort"
    refute html =~ "Der zitierte Satz."
  end

  test "a quote of one of our posts links to the vutuv permalink, not the pasted URL" do
    local = %Post{id: "01a0-local", organization_id: nil, user: %User{username: "stefan"}}

    html =
      render_quote(
        quoting(%{
          quote_uri: "https://www.vutuv.test/stefan/posts/01a0-local",
          quoted_local_post_id: local.id,
          quoted_local_post: local
        })
      )

    assert html =~ "/stefan/posts/01a0-local"
    assert html =~ "Quoted post"
  end

  test "a longer URL in the body does not swallow the link to a shorter one" do
    # The body names `…/notes/12`, the quote points at `…/notes/1`. A substring
    # search reads that as "already written" and drops the link; whole URLs do
    # not.
    post =
      quoting(%{
        content_text: "Siehe auch #{@quoted_uri}2",
        quote_uri: @quoted_uri
      })

    assert render_quote(post) =~ "Quoted post"
  end

  test "nothing is added when the author already wrote the link themselves" do
    post =
      quoting(%{
        content_text: "Sehr treffend: #{@quoted_uri}",
        quote_uri: @quoted_uri
      })

    refute render_quote(post) =~ "Quoted post"
  end

  test "a missing preload costs the card, not the page" do
    # No `quoted_post:` given, so the association is the `NotLoaded` a bare
    # struct carries — exactly what a query without `RemotePost.quote_preload/0`
    # hands the card.
    post = quoting(%{quote_uri: @quoted_uri, quote_verified: true, quoted_post_id: "01a0-quoted"})

    html = render_quote(post)

    refute html =~ "data-quoted-post="
    assert html =~ "Quoted post"
  end

  test "German names the quoted post as a quote, not as a reply or a share" do
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    assert render_quote(quoting(%{quote_uri: @quoted_uri})) =~ "Zitierter Beitrag"
  end
end
