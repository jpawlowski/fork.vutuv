defmodule Vutuv.FediversePostQuotesTest do
  @moduledoc """
  What a post from another network says it quotes (issue #1609): what is read
  off the object, what is resolved, what is allowed to become a card, and what
  keeps a quoted copy from being swept.

  `async: false` — the per-host fetch budget and the HTTP stub both live in
  application/ETS state the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.FediverseHelpers, only: [stub_remote: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias VutuvWeb.Fediverse.Docs

  @quoter "https://social.example/users/them"
  @quoting_object "https://social.example/posts/1"
  @author "https://third.example/users/autorin"
  @quoted_object "https://third.example/notes/1"
  @stamp "https://third.example/quote-authorizations/1"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp quoter_account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @quoter,
      host: "social.example",
      handle: "them",
      name: "Them",
      inbox_uri: @quoter <> "/inbox"
    })
  end

  defp follower_of(account) do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{account.id}"
    })

    Repo.reload!(user)
  end

  # A `Create` carrying a quote, as Mastodon 4.5 sends one.
  defp create_activity(object_overrides) do
    object =
      Map.merge(
        %{
          "id" => @quoting_object,
          "type" => "Note",
          "attributedTo" => @quoter,
          "content" => "<p>Sehr treffend.</p>",
          "url" => "https://social.example/@them/1",
          "published" => "2026-08-20T09:00:00Z",
          "to" => [@public]
        },
        object_overrides
      )

    %{"type" => "Create", "actor" => @quoter, "object" => object}
  end

  defp quoting_post(object_overrides) do
    account = quoter_account()
    user = follower_of(account)

    assert :ok = Fediverse.record_remote_post(create_activity(object_overrides), @quoter)

    %{account: account, user: user, post: Repo.get_by!(RemotePost, object_uri: @quoting_object)}
  end

  # The quoted author's server, answering for the note, for the actor and for
  # the consent stamp.
  defp serve_third(overrides \\ %{}) do
    note =
      Map.merge(
        %{
          "id" => @quoted_object,
          "type" => "Note",
          "attributedTo" => @author,
          "content" => "<p>Der zitierte Satz.</p>",
          "url" => "https://third.example/@autorin/1",
          "published" => "2026-08-20T08:00:00Z",
          "to" => [@public]
        },
        Map.get(overrides, :note, %{})
      )

    actor = %{
      "id" => @author,
      "type" => "Person",
      "preferredUsername" => "autorin",
      "inbox" => @author <> "/inbox"
    }

    stamp =
      Map.merge(
        %{
          "id" => @stamp,
          "type" => "QuoteAuthorization",
          "attributedTo" => @author,
          "interactionTarget" => @quoted_object,
          "interactingObject" => @quoting_object
        },
        Map.get(overrides, :stamp, %{})
      )

    stub(fn path ->
      cond do
        path =~ "quote-authorizations" -> stamp
        path =~ "users" -> actor
        true -> note
      end
    end)
  end

  # One document per path, or a 404. The `content-type` is not decoration: Req's
  # decode step branches on it, so a stub without it hands the client a binary
  # where the real server's answer arrives decoded.
  defp stub(fun) do
    stub_remote(fn conn ->
      case fun.(conn.request_path) do
        nil ->
          Plug.Conn.send_resp(conn, 404, "")

        body ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    end)
  end

  describe "reading the quote off the object" do
    test "stores the canonical `quote` property and the stamp beside it" do
      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert post.quote_uri == @quoted_object
      assert post.quote_authorization_uri == @stamp
      # Nothing is resolved by the delivery itself: the inbox owes its 202 long
      # before two other servers answer.
      assert post.quoted_post_id == nil
      refute post.quote_verified
    end

    test "reads Fedibird's `quoteUri`" do
      %{post: post} = quoting_post(%{"quoteUri" => @quoted_object})
      assert post.quote_uri == @quoted_object
    end

    test "reads Misskey's `_misskey_quote`" do
      %{post: post} = quoting_post(%{"_misskey_quote" => @quoted_object})
      assert post.quote_uri == @quoted_object
    end

    test "an embedded quote object is read down to its id" do
      %{post: post} =
        quoting_post(%{"quote" => %{"id" => @quoted_object, "type" => "Note"}})

      assert post.quote_uri == @quoted_object
    end

    test "a post that quotes nothing keeps both columns empty" do
      %{post: post} = quoting_post(%{})

      assert post.quote_uri == nil
      assert post.quote_authorization_uri == nil
      refute RemotePost.quoting?(post)
    end
  end

  describe "resolve_quote/1 — a stranger's post" do
    test "fetches the quoted post, stores it and verifies a matching stamp" do
      serve_third()

      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      quoted = Repo.get_by!(RemotePost, object_uri: @quoted_object)

      assert resolved.quoted_post_id == quoted.id
      assert resolved.quote_verified
      assert RemotePost.quote_card?(resolved)
      assert quoted.content_text == "Der zitierte Satz."
    end

    test "a stamp served by the QUOTING server is no consent at all" do
      # The stamp URL is on the quoting account's own host, which is the
      # quoting server vouching for itself. Refused before any request is made.
      elsewhere = "https://social.example/quote-authorizations/1"

      serve_third()

      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => elsewhere})

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      # Still resolved — the reader gets a link — but never a card.
      assert resolved.quoted_post_id
      refute resolved.quote_verified
      refute RemotePost.quote_card?(resolved)
    end

    test "a stamp naming somebody else's quote does not authorize this one" do
      serve_third(%{stamp: %{"interactingObject" => "https://social.example/posts/999"}})

      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      assert resolved.quoted_post_id
      refute resolved.quote_verified
    end

    test "a stamp attributed to somebody other than the quoted author is refused" do
      serve_third(%{stamp: %{"attributedTo" => "https://third.example/users/wer_anders"}})

      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert :ok = Fediverse.resolve_quote(post)

      refute Repo.reload!(post).quote_verified
    end

    test "a quote with no stamp at all resolves to a link, never a card" do
      serve_third()

      %{post: post} = quoting_post(%{"quote" => @quoted_object})

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      assert resolved.quoted_post_id
      refute resolved.quote_verified
    end

    test "a quoted post its author addressed to followers only is not stored" do
      serve_third(%{note: %{"to" => [@author <> "/followers"]}})

      %{post: post} = quoting_post(%{"quote" => @quoted_object})

      assert :ok = Fediverse.resolve_quote(post)

      assert Repo.reload!(post).quoted_post_id == nil
      refute Repo.get_by(RemotePost, object_uri: @quoted_object)
    end

    test "a server that answers for somebody else's actor is refused" do
      # `own_object?/3`: the document claims an author on a different host than
      # the object it answers for.
      serve_third(%{note: %{"attributedTo" => "https://elsewhere.example/users/opfer"}})

      %{post: post} = quoting_post(%{"quote" => @quoted_object})

      assert :ok = Fediverse.resolve_quote(post)

      assert Repo.reload!(post).quoted_post_id == nil
    end

    test "a blocked instance is neither fetched nor resolved" do
      serve_third()

      {:ok, _blocked} =
        Fediverse.block_instance(
          %{host: "third.example", reason: "Test"},
          insert(:activated_user, admin?: true)
        )

      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      assert resolved.quoted_post_id == nil
      refute resolved.quote_verified
    end
  end

  describe "what a quote may not reach" do
    test "a cached followers-only post is not pulled into a public quote card" do
      account = quoter_account()
      _user = follower_of(account)

      # Cached because somebody here follows its author — a legitimate stored
      # audience — but never ours to show to anybody else.
      restricted =
        Repo.insert!(%RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/posts/0",
          content_text: "Nur für meine Follower.",
          audience: "followers",
          kind: "note",
          published_at: DateTime.utc_now(:second),
          received_at: DateTime.utc_now(:second),
          expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
        })

      stub(fn _path -> nil end)

      assert :ok =
               Fediverse.record_remote_post(
                 create_activity(%{"quote" => restricted.object_uri}),
                 @quoter
               )

      post = Repo.get_by!(RemotePost, object_uri: @quoting_object)
      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      # Not even as a self-quote, which needs no stamp at all: the quoting post
      # is public, so a card here would hand a narrowed audience to everyone who
      # can see it — anonymously, on the tag timeline.
      assert resolved.quoted_post_id == nil
      refute resolved.quote_verified
      refute RemotePost.quote_card?(resolved)
    end

    test "a post that quotes itself resolves to nothing, and stays purgeable" do
      account = quoter_account()
      user = follower_of(account)

      stub(fn _path -> nil end)

      assert :ok =
               Fediverse.record_remote_post(
                 create_activity(%{"quote" => @quoting_object}),
                 @quoter
               )

      post = Repo.get_by!(RemotePost, object_uri: @quoting_object)
      assert :ok = Fediverse.resolve_quote(post)

      # Left unguarded the row would hold itself against `spare_held/1` and
      # survive every unfollow purge until its ceiling.
      assert Repo.reload!(post).quoted_post_id == nil

      Repo.delete_all(from(f in Follow, where: f.user_id == ^user.id))
      Fediverse.purge_unfollowed_remote_posts()

      refute Repo.get(RemotePost, post.id)
    end

    test "an over-long quote URI costs the quote, never the post" do
      account = quoter_account()
      _user = follower_of(account)

      too_long = "https://third.example/notes/" <> String.duplicate("a", 2_048)

      assert :ok =
               Fediverse.record_remote_post(create_activity(%{"quote" => too_long}), @quoter)

      # The post is here, which is the whole point: one oversized optional field
      # must not take an otherwise perfectly good post out of every feed.
      post = Repo.get_by!(RemotePost, object_uri: @quoting_object)
      assert post.content_text == "Sehr treffend."
      assert post.quote_uri == nil
    end
  end

  describe "resolve_quote/1 — a self-quote" do
    test "needs no stamp and costs no request" do
      account = quoter_account()
      _user = follower_of(account)

      earlier =
        Repo.insert!(%RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/posts/0",
          content_text: "Was ich vorhin schrieb.",
          audience: "public",
          kind: "note",
          published_at: DateTime.utc_now(:second),
          received_at: DateTime.utc_now(:second),
          expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
        })

      # Nothing is served: a self-quote that reached the wire would fail here.
      stub(fn _path -> nil end)

      assert :ok =
               Fediverse.record_remote_post(
                 create_activity(%{"quote" => earlier.object_uri}),
                 @quoter
               )

      post = Repo.get_by!(RemotePost, object_uri: @quoting_object)
      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      assert resolved.quoted_post_id == earlier.id
      assert resolved.quote_verified
    end
  end

  describe "resolve_quote/1 — one of our own posts" do
    test "is resolved by the id in the path and never fetched from ourselves" do
      author = insert(:activated_user, fediverse_followers?: true)
      local = insert(:post, user: author, body: "Ein Beitrag von hier.")

      # Any request at all would be this installation asking itself.
      stub(fn _path -> nil end)

      %{post: post} = quoting_post(%{"quote" => Docs.note_url(author, local.id)})

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      assert resolved.quoted_local_post_id == local.id
      assert resolved.quoted_post_id == nil
      # No card until this installation issues stamps of its own (issue #1608):
      # we never agreed, so nothing may claim we did.
      refute resolved.quote_verified
      refute RemotePost.quote_card?(resolved)
    end

    test "a URL of ours naming no post of ours resolves to nothing" do
      stub(fn _path -> nil end)

      %{post: post} =
        quoting_post(%{
          "quote" => Docs.note_url(insert(:activated_user), Vutuv.UUIDv7.generate())
        })

      assert :ok = Fediverse.resolve_quote(post)

      resolved = Repo.reload!(post)
      assert resolved.quoted_local_post_id == nil
      assert resolved.quoted_post_id == nil
    end
  end

  describe "an edit" do
    test "brings the stamp that turns the link into a card" do
      serve_third()

      %{post: post} = quoting_post(%{"quote" => @quoted_object})
      assert :ok = Fediverse.resolve_quote(post)
      refute Repo.reload!(post).quote_verified

      update = %{
        "type" => "Update",
        "actor" => @quoter,
        "object" => %{
          "id" => @quoting_object,
          "type" => "Note",
          "attributedTo" => @quoter,
          "content" => "<p>Sehr treffend.</p>",
          "published" => "2026-08-20T09:00:00Z",
          "to" => [@public],
          "quote" => @quoted_object,
          "quoteAuthorization" => @stamp
        }
      }

      Fediverse.update_remote_post(update, @quoter)

      edited = Repo.reload!(post)
      assert edited.quote_authorization_uri == @stamp
      # The resolution itself runs in a task the test does not start.
      assert :ok = Fediverse.resolve_quote(edited)
      assert Repo.reload!(post).quote_verified
    end

    test "that takes the quote back clears the card without any request" do
      serve_third()

      %{post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert :ok = Fediverse.resolve_quote(post)
      assert Repo.reload!(post).quote_verified

      stub(fn _path -> nil end)

      update = %{
        "type" => "Update",
        "actor" => @quoter,
        "object" => %{
          "id" => @quoting_object,
          "type" => "Note",
          "attributedTo" => @quoter,
          "content" => "<p>Doch nicht.</p>",
          "published" => "2026-08-20T09:00:00Z",
          "to" => [@public]
        }
      }

      Fediverse.update_remote_post(update, @quoter)

      cleared = Repo.reload!(post)
      assert cleared.quote_uri == nil
      assert cleared.quoted_post_id == nil
      refute cleared.quote_verified
    end
  end

  describe "retention" do
    test "a quoted copy survives the purge of posts nobody follows" do
      serve_third()

      %{account: account, user: user, post: post} =
        quoting_post(%{"quote" => @quoted_object, "quoteAuthorization" => @stamp})

      assert :ok = Fediverse.resolve_quote(post)
      quoted = Repo.get_by!(RemotePost, object_uri: @quoted_object)

      # Nobody here follows the quoted author — the normal case for a quote —
      # so only the holding reference keeps this copy alive. Without it the
      # sweep takes it and the card in the reader's feed becomes a bare link
      # while they are looking at it.
      Fediverse.purge_unfollowed_remote_posts()

      assert Repo.get(RemotePost, quoted.id)
      assert Repo.get(RemotePost, post.id)

      # And it is really the quote that holds it: once the quoting post goes,
      # the next sweep takes the quoted copy with it.
      Repo.delete_all(from(p in RemotePost, where: p.id == ^post.id))
      Fediverse.purge_unfollowed_remote_posts()

      refute Repo.get(RemotePost, quoted.id)

      # The quoting post's own author is still followed, so nothing about the
      # follow explains the two results above.
      assert Repo.get_by(Follow, remote_account_id: account.id, user_id: user.id)
    end
  end
end
