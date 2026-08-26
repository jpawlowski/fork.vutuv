defmodule VutuvWeb.FediverseQuoteAuthorizationTest do
  @moduledoc """
  The endpoint a third server fetches before it renders somebody's quote of a
  vutuv post (FEP-044f, issue #1608).

  This URL is the permission. It is read by servers that have never spoken to
  us, it is read again on every render, and its **absence** is how an author
  takes a quote back — so "what does it answer when the row is gone" is as much
  the feature as "what does it answer when the row is there".
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.QuoteAuthorization
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"
  @quote_post "https://social.example/users/alice/statuses/1"

  setup do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    post = create_post!(user, %{"body" => "Worth quoting."})

    {:ok, stamp} =
      %QuoteAuthorization{}
      |> QuoteAuthorization.changeset(%{
        post_id: post.id,
        user_id: user.id,
        interacting_object_uri: @quote_post,
        actor_uri: @actor,
        note_uri: Docs.note_url(user, post.id),
        accepted_at: DateTime.utc_now(:second)
      })
      |> Repo.insert()

    {:ok, user: user, post: post, stamp: stamp}
  end

  defp stamp_path(user, post, id),
    do: "/#{user.username}/posts/#{post.id}/quote-authorizations/#{id}"

  test "serves the stamp as ActivityPub", %{conn: conn, user: user, post: post, stamp: stamp} do
    conn = get(conn, stamp_path(user, post, stamp.id))

    assert response_content_type(conn, :json) =~ "application/activity+json"
    doc = json_response(conn, 200)

    assert doc["type"] == "QuoteAuthorization"
    assert doc["id"] == Docs.quote_authorization_url(user, post.id, stamp.id)
    assert doc["attributedTo"] == Docs.actor_url(user)
    assert doc["interactionTarget"] == Docs.note_url(user, post.id)
    assert doc["interactingObject"] == @quote_post
  end

  test "defines the terms the document uses", %{conn: conn, user: user, post: post, stamp: stamp} do
    doc = conn |> get(stamp_path(user, post, stamp.id)) |> json_response(200)

    assert Enum.any?(doc["@context"], fn entry ->
             is_map(entry) and Map.has_key?(entry, "QuoteAuthorization")
           end)
  end

  test "a withdrawn permission is gone", %{conn: conn, user: user, post: post, stamp: stamp} do
    :ok = Fediverse.revoke_quote_authorizations(post)

    assert conn |> get(stamp_path(user, post, stamp.id)) |> response(404)
  end

  test "one post's stamp cannot be served from another post's URL", %{
    conn: conn,
    user: user,
    stamp: stamp
  } do
    other = create_post!(user, %{"body" => "Another post entirely."})

    assert conn |> get(stamp_path(user, other, stamp.id)) |> response(404)
  end

  test "a malformed id is a miss, not a crash", %{conn: conn, user: user, post: post} do
    assert conn |> get(stamp_path(user, post, "not-a-uuid")) |> response(404)
  end

  test "a member who does not federate serves no stamps at all", %{conn: conn, post: post} do
    quiet = insert(:activated_user, fediverse_followers?: false)

    assert conn |> get(stamp_path(quiet, post, Vutuv.UUIDv7.generate())) |> response(404)
  end

  describe "the switch on /settings/fediverse" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _} =
        Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => true})

      {:ok, conn: conn}
    end

    test "offers the quoting switch", %{conn: conn} do
      body = conn |> get(~p"/settings/fediverse") |> html_response(200)

      assert body =~ ~s(name="user[fediverse_quotes?]")
    end

    test "says so in German, in words rather than a fuzzy match", %{conn: conn} do
      # `gettext.extract --merge` filled this label with the translation of an
      # unrelated string ("Fediverse quotes" -> "Fediverse") before it was
      # written by hand. Nothing fails the build on that, so the German has to
      # be asserted by name — including the short label, which is the one most
      # likely to be fuzzy-matched and least likely to be noticed.
      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/fediverse")
        |> html_response(200)

      assert body =~ "Andere Netzwerke dürfen Ihre Beiträge zitieren"
      assert body =~ "wie bei einem Repost"
    end
  end
end
