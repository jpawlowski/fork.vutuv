defmodule VutuvWeb.MastodonApi.ApiVersionSixTest do
  @moduledoc """
  What `api_versions: %{mastodon: 6}` promises a client, checked against what
  the adapter actually answers.

  Mastodon's API version is a feature-detection number, not a label: a client
  reads it out of `/api/v2/instance` and then calls the endpoints that number
  stands for. Each bump names one change (`lib/mastodon/version.rb` in
  mastodon/mastodon): 3 is `attribution_domains`, **4 the media-deletion
  methods**, 5 the `blur` filter action and **6 the hashtag feature/unfeature
  API** — with 1 and 2 carrying grouped notifications and their move to
  `/api/v2`. Claiming 6 while a client's call for one of them falls through to
  the adapter's 404 is a broken server, not a missing feature.

  Beside those, the entity fields vutuv has data for and used to send empty.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.MastodonApi
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Tags

  describe "the status entity carries what a post really holds" do
    test "tags, mentions, language and the edit mark", %{conn: conn} do
      author = insert(:activated_user)
      # `unique_username/1` because the mention grammar is `[A-Za-z0-9_]+` and the
      # factory's default usernames carry a hyphen, which would truncate the
      # handle and fail the existence check rather than this endpoint.
      mentioned = insert(:activated_user, username: unique_username("mentioned"))
      tag_name = unique_tag_name("Elixir")

      {:ok, post} =
        Posts.create_post(author, %{
          body: "Hallo @#{mentioned.username}",
          tags: tag_name,
          language: "de"
        })

      token = mastodon_token(author, ["read"])

      status =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      # A client linkifies and offers "open hashtag" from this list; it was
      # always empty, so a post's own tags were unreachable from a phone.
      assert [%{"name" => slug, "url" => url}] = status["tags"]
      assert slug == Tags.get_canonical_tag_by_slug(slug).slug
      assert url =~ "/tags/" <> slug

      # The prefill a client builds a reply from.
      assert [%{"acct" => acct, "id" => id}] = status["mentions"]
      assert acct == mentioned.username
      assert id == mentioned.id

      # Declared by the author (v7.313.0), and a client filters its timeline on
      # it — an undeclared post is treated as "every language", which is not the
      # same claim.
      assert status["language"] == "de"

      # Untouched since it was written.
      assert status["edited_at"] == nil
    end

    test "an edited post says when", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Erste Fassung"})

      # The website's own rule: `updated_at` more than a minute past
      # `inserted_at` is what its card calls edited.
      edited_at = NaiveDateTime.add(post.inserted_at, 600)
      post = post |> Ecto.Changeset.change(updated_at: edited_at) |> Repo.update!()

      token = mastodon_token(author, ["read"])

      status =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert status["edited_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end
  end

  describe "the account entity carries the member's proven webpages" do
    test "a verified link becomes a Mastodon field with verified_at", %{conn: conn} do
      user = insert(:activated_user)

      insert(:url,
        user: user,
        value: "https://example.org/me",
        description: "Meine Seite",
        verified_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      )

      # Unproven links stay out: `verified_at: nil` in a client reads as a plain
      # row, which is not what a proof-backed field says.
      insert(:url, user: user, value: "https://unproven.example/", description: "Noch offen")

      token = mastodon_token(user, ["read"])

      account =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert [field] = account["fields"]
      assert field["name"] == "Meine Seite"
      assert field["value"] =~ "https://example.org/me"
      assert field["value"] =~ ~s(rel="me)
      assert field["verified_at"]
    end
  end

  describe "GET /api/v1/accounts/lookup" do
    test "resolves a bare handle and a fully qualified local one", %{conn: conn} do
      user = insert(:activated_user)
      other = insert(:activated_user)
      token = mastodon_token(user, ["read"])

      found =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/lookup", %{"acct" => other.username})
        |> json_response(200)

      assert found["id"] == other.id

      qualified =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v1/accounts/lookup", %{
          "acct" => "@#{other.username}@#{MastodonApi.local_domain()}"
        })
        |> json_response(200)

      assert qualified["id"] == other.id
    end

    test "an unknown handle is a 404 and not the website's HTML", %{conn: conn} do
      token = mastodon_token(insert(:activated_user), ["read"])

      assert conn
             |> mastodon_conn(token)
             |> get("/api/v1/accounts/lookup", %{"acct" => "nobody-here-at-all"})
             |> json_response(404)
    end
  end

  describe "hashtags (API version 6 territory)" do
    setup do
      user = insert(:activated_user)
      tag = insert(:tag)
      %{user: user, tag: tag, token: mastodon_token(user, ["read", "write"])}
    end

    test "GET /api/v1/tags/:id names the topic", %{conn: conn, tag: tag, token: token} do
      rendered =
        conn |> mastodon_conn(token) |> get("/api/v1/tags/#{tag.slug}") |> json_response(200)

      assert rendered["name"] == tag.slug
      assert rendered["url"] =~ "/tags/#{tag.slug}"
      refute rendered["following"]
    end

    test "follow and unfollow round-trip through vutuv's own subscription", %{
      conn: conn,
      user: user,
      tag: tag,
      token: token
    } do
      followed =
        conn
        |> mastodon_conn(token)
        |> post("/api/v1/tags/#{tag.slug}/follow")
        |> json_response(200)

      # The answer has to already say so, or the client flips its button back on
      # the next read.
      assert followed["following"]
      assert Tags.tag_followed?(user, tag)

      listed =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v1/followed_tags")
        |> json_response(200)

      assert [%{"name" => name, "following" => true}] = listed
      assert name == tag.slug

      dropped =
        build_conn()
        |> mastodon_conn(token)
        |> post("/api/v1/tags/#{tag.slug}/unfollow")
        |> json_response(200)

      refute dropped["following"]
      refute Tags.tag_followed?(Repo.reload!(user), tag)
    end

    test "an unknown hashtag is a 404", %{conn: conn, token: token} do
      assert conn
             |> mastodon_conn(token)
             |> get("/api/v1/tags/no_such_topic_here")
             |> json_response(404)
    end
  end

  describe "grouped notifications (API version 1/2)" do
    test "a group key opens, fills and dismisses", %{conn: conn} do
      author = insert(:activated_user)
      liker = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Etwas zum Mögen"})
      :ok = Posts.like_post(liker, post)

      token = mastodon_token(author, ["read", "write"])

      %{"notification_groups" => [group]} =
        conn |> mastodon_conn(token) |> get("/api/v2/notifications") |> json_response(200)

      key = group["group_key"]

      one =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v2/notifications/#{key}")
        |> json_response(200)

      assert one["group_key"] == key
      assert one["notifications_count"] == 1

      accounts =
        build_conn()
        |> mastodon_conn(token)
        |> get("/api/v2/notifications/#{key}/accounts")
        |> json_response(200)

      assert [%{"id" => id}] = accounts
      assert id == liker.id

      assert build_conn()
             |> mastodon_conn(token)
             |> post("/api/v2/notifications/#{key}/dismiss")
             |> json_response(200)
    end

    test "an unknown group key is a 404", %{conn: conn} do
      token = mastodon_token(insert(:activated_user), ["read"])

      assert conn
             |> mastodon_conn(token)
             |> get("/api/v2/notifications/favourite-does-not-exist")
             |> json_response(404)
    end
  end

  describe "the search page's hashtags know the viewer" do
    test "a followed tag reports following: true", %{conn: conn} do
      user = insert(:activated_user)
      other = insert(:activated_user)
      {:ok, _follow} = Social.follow(user, other.id)
      tag = insert(:tag)
      {:ok, _} = Tags.follow_tag(user, tag)

      token = mastodon_token(user, ["read"])

      %{"hashtags" => hashtags} =
        conn
        |> mastodon_conn(token)
        |> get("/api/v2/search", %{"q" => tag.name, "type" => "hashtags"})
        |> json_response(200)

      assert Enum.any?(hashtags, &(&1["name"] == tag.slug and &1["following"]))
    end
  end
end
