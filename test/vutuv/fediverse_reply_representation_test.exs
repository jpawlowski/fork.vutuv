defmodule Vutuv.FediverseReplyRepresentationTest do
  @moduledoc """
  What an answer written here says about itself on the way out (issue #1739).

  Two halves of one symptom. `inReplyTo` was written only when the answered
  author federates — and `fediverse_followers?` defaults to off, so most answers
  travelled without the one field saying they *were* answers, and every
  receiving server filed them as fresh threads. And an answer to a **vutuv**
  post carried no `Mention`, no `cc` and no leading handle at all, while an
  answer to a note on another server has carried all three since #1070.

  The rule now: an answer always names what it answers, even when nothing serves
  a Note at that id. That reference dangles by design — the answered member
  chose to stay out of the Fediverse, so their post is not findable out there
  either way. The account beside it is named only when it can be resolved.

  Calibrated against the un-fixed code — put the `federated?` gate back into
  `reply_parent/1`, or take the local `Mention`/`cc`/handle back out, and the
  cases below go red.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  import Ecto.Query, only: [order_by: 2]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Posts
  alias Vutuv.Posts.PostDenial
  alias VutuvWeb.Fediverse.Docs

  setup do
    author = member()

    {:ok, _follower} =
      Fediverse.add_follower(author, %{
        actor_uri: "https://follower.example/users/f",
        inbox_uri: "https://follower.example/inbox"
      })

    %{author: author}
  end

  # `unique_username/1` and not the factory default: the mention grammar stops at
  # a hyphen, so a `user-4` would silently make the "@ in the body" case below
  # test nothing.
  defp member, do: federating_member(username: unique_username())

  defp create_reply!(author, parent) do
    {:ok, reply} = Posts.create_reply(author, parent, %{body: "Antwort."})
    reply
  end

  defp queued_notes do
    Delivery
    |> order_by(asc: :id)
    |> Repo.all()
    |> Enum.map(&(&1.activity_json |> Jason.decode!() |> Map.get("object")))
  end

  describe "answering a member who federates" do
    setup do
      parent_author = member()
      %{parent_author: parent_author, parent: insert(:post, user: parent_author, body: "Frage?")}
    end

    test "names them every way a receiving server reads", ctx do
      {:ok, _reply} = Posts.create_reply(ctx.author, ctx.parent, %{body: "Sehe ich auch so."})

      assert [note] = queued_notes()

      # The field that makes it a reply at all — without it Mastodon files the
      # post as a fresh thread and shows it to everybody.
      assert note["inReplyTo"] == Docs.note_url(ctx.parent_author, ctx.parent.id)

      # Addressed to them directly, so it reaches their server and their
      # notifications, the way the remote-reply path has done since #1070.
      assert Docs.actor_url(ctx.parent_author) in note["cc"]

      assert Enum.any?(
               note["tag"],
               &(&1["type"] == "Mention" and &1["href"] == Docs.actor_url(ctx.parent_author))
             )

      # And the reader is told in the body who is being answered.
      assert note["content"] =~ Docs.handle(ctx.parent_author)
    end

    test "announces them once even when the body names them too", ctx do
      {:ok, _reply} =
        Posts.create_reply(ctx.author, ctx.parent, %{
          body: "@#{ctx.parent_author.username} sehe ich auch so."
        })

      assert [note] = queued_notes()

      mentions =
        Enum.filter(note["tag"], &(&1["href"] == Docs.actor_url(ctx.parent_author)))

      assert length(mentions) == 1
    end
  end

  describe "answering a member who keeps out of the Fediverse" do
    setup do
      # `fediverse_followers?` defaults to false, which is most members.
      parent_author = insert(:activated_user, username: unique_username())
      %{parent_author: parent_author, parent: insert(:post, user: parent_author, body: "Frage?")}
    end

    test "still says what it answers, and names nobody", ctx do
      {:ok, _reply} = Posts.create_reply(ctx.author, ctx.parent, %{body: "Sehe ich auch so."})

      assert [note] = queued_notes()

      # Dangling on purpose: nothing serves a Note at that id, and a reader
      # cannot open it. What it buys is that the post no longer reads as the
      # start of a conversation.
      assert note["inReplyTo"] == Docs.note_url(ctx.parent_author, ctx.parent.id)

      # But the account itself is not named: their actor document 404s, so a
      # handle in the body would link a reader to nothing.
      assert note["cc"] == [Docs.followers_url(ctx.author)]
      refute Map.has_key?(note, "tag")
      refute note["content"] =~ Docs.handle(ctx.parent_author)
    end
  end

  describe "answering a post that is not public" do
    test "says nothing about it", ctx do
      parent_author = member()
      parent = insert(:post, user: parent_author, body: "Nur für wenige.")
      reply = create_reply!(ctx.author, parent)

      Repo.insert!(%PostDenial{post_id: parent.id, wildcard: "everyone"})

      note = Docs.note(Repo.preload(reply, Docs.note_preloads()), ctx.author)

      # The one shape left that travels without saying what it answers, and the
      # reason is privacy rather than resolvability: the id is a UUID v7, so
      # publishing the URL would tell readers who may not see the post that it
      # exists and when it was written.
      refute Map.has_key?(note, "inReplyTo")
    end
  end

  describe "what must keep travelling" do
    test "a post that answers nothing", ctx do
      {:ok, _post} = Posts.create_post(ctx.author, %{body: "Ein eigener Gedanke."})

      assert [note] = queued_notes()
      refute Map.has_key?(note, "inReplyTo")

      # And nobody is addressed or mentioned who was never answered — the guard
      # on resolving the answered account once for the whole Note.
      assert note["cc"] == [Docs.followers_url(ctx.author)]
      refute Map.has_key?(note, "tag")
    end

    test "an answer under a post of the author's own", ctx do
      own = insert(:post, user: ctx.author, body: "Erster Teil.")

      {:ok, _reply} = Posts.create_reply(ctx.author, own, %{body: "Zweiter Teil."})

      assert [note] = queued_notes()
      assert note["inReplyTo"] == Docs.note_url(ctx.author, own.id)
    end
  end
end
