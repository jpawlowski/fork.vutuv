defmodule Vutuv.FeedStrangerRepliesTest do
  @moduledoc """
  The feed leaves out answers written to accounts the reader does not follow
  (issue #1740). The rule is "am I in this exchange", not "do I follow the
  author" — a position the newsfeed did not have before.

  What the tests are really pinning down is the *exceptions*: the fear a reader
  has about this setting is losing a thread they are part of, and all four ways
  of being part of one have a test here.

  Calibrated against the un-fixed code: without `stranger_reply_scope/2` the
  first test below fails, and only that one — the rest are guards that must pass
  either way.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp reader!(attrs \\ []), do: insert(:activated_user, attrs)

  defp followed_by!(reader) do
    author = insert(:activated_user)
    follow!(reader, author)
    author
  end

  defp post!(author, body), do: create_post!(author, %{body: body})

  defp reply!(author, parent, body) do
    {:ok, reply} = Posts.create_reply(author, parent, %{body: body})
    reply
  end

  defp feed_ids(reader) do
    Posts.feed_page(reader).entries |> Enum.map(& &1.post.id) |> MapSet.new()
  end

  test "an answer to somebody the reader does not follow is left out" do
    reader = reader!()
    author = followed_by!(reader)
    stranger = insert(:activated_user)

    reply = reply!(author, post!(stranger, "Frage?"), "Antwort.")

    refute reply.id in feed_ids(reader)
  end

  test "the reader's own answer stays, whoever it was written to" do
    reader = reader!()
    stranger = insert(:activated_user)

    reply = reply!(reader, post!(stranger, "Frage?"), "Antwort.")

    # A member's feed carries their own posts, and an answer is a post. Leaving
    # this clause out took the reader's own answers off their own feed — it is
    # the first line of Mastodon's rule for the same reason.
    assert reply.id in feed_ids(reader)
  end

  test "an answer to the reader stays" do
    reader = reader!()
    author = followed_by!(reader)

    reply = reply!(author, post!(reader, "Meine Frage?"), "Antwort.")

    assert reply.id in feed_ids(reader)
  end

  test "the author continuing their own thread stays" do
    reader = reader!()
    author = followed_by!(reader)

    reply = reply!(author, post!(author, "Erster Teil."), "Zweiter Teil.")

    assert reply.id in feed_ids(reader)
  end

  test "an answer to somebody the reader also follows stays" do
    reader = reader!()
    author = followed_by!(reader)
    other = followed_by!(reader)

    reply = reply!(author, post!(other, "Frage?"), "Antwort.")

    assert reply.id in feed_ids(reader)
  end

  test "a post that answers nothing stays" do
    reader = reader!()
    author = followed_by!(reader)

    post = post!(author, "Ein eigener Gedanke.")

    assert post.id in feed_ids(reader)
  end

  test "an answer whose parent has been deleted stays" do
    reader = reader!()
    author = followed_by!(reader)
    stranger = insert(:activated_user)
    parent = post!(stranger, "Frage?")

    reply = reply!(author, parent, "Antwort.")
    {:ok, _} = Posts.delete_post(parent)

    # The parent reference nilifies, so there is no longer anybody to be a
    # stranger — filtering it now would hide a post for a reason that no longer
    # exists.
    assert reply.id in feed_ids(reader)
  end

  test "a boost of such an answer still arrives, and that is deliberate" do
    reader = reader!()
    booster = followed_by!(reader)
    stranger = insert(:activated_user)
    reply = reply!(insert(:activated_user), post!(stranger, "Frage?"), "Antwort.")

    :ok = Posts.repost_post(booster, reply)

    # The filter judges what somebody *wrote*, not what they passed on: a boost
    # is somebody the reader follows saying "read this", which is a different
    # act with its own audience. Pinned here so the boundary is a decision on
    # record rather than something nobody got round to.
    assert Enum.any?(Posts.feed_page(reader).entries, &(&1.post.id == reply.id))
  end

  test "the member can switch them back on" do
    reader = reader!(feed_stranger_replies?: true)
    author = followed_by!(reader)
    stranger = insert(:activated_user)

    reply = reply!(author, post!(stranger, "Frage?"), "Antwort.")

    assert reply.id in feed_ids(reader)
  end
end
