defmodule VutuvWeb.PostNoteReplyTest do
  @moduledoc """
  The permalink half of issue #1739.

  The same post is served as an ActivityPub Note at its own URL, and anything
  that reaches it there — a boost, a search, somebody pasting the link — must
  get back what the delivery queue sent, not a second opinion. So this pins the
  two ends of the rule on that surface: an answer always carries `inReplyTo`,
  and the answered account is named beside it only when it can be resolved.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  defp member, do: federating_member(username: unique_username())

  defp get_note(conn, post) do
    conn
    |> put_req_header("accept", "application/activity+json")
    |> get(Posts.path(post))
  end

  test "an answer under a federating member's post names them too", %{conn: conn} do
    parent_author = member()
    parent = insert(:post, user: parent_author, body: "Frage?")
    {:ok, reply} = Posts.create_reply(member(), parent, %{body: "Antwort."})

    note = conn |> get_note(Repo.preload(reply, :user)) |> json_response(200)

    assert note["inReplyTo"] == Docs.note_url(parent_author, parent.id)
    assert Docs.actor_url(parent_author) in note["cc"]
  end

  test "an answer under a non-federating member's post still says it is one", %{conn: conn} do
    # Keeps out of the Fediverse, which is the default and most members.
    parent_author = insert(:activated_user, username: unique_username())
    parent = insert(:post, user: parent_author, body: "Frage?")
    {:ok, reply} = Posts.create_reply(member(), parent, %{body: "Antwort."})

    note = conn |> get_note(Repo.preload(reply, :user)) |> json_response(200)

    # The reference dangles — that id serves no Note — but the post no longer
    # pretends to open a conversation. Nobody is named beside it.
    assert note["inReplyTo"] == Docs.note_url(parent_author, parent.id)
    assert note["cc"] == [Docs.followers_url(Repo.preload(reply, :user).user)]
  end
end
