defmodule Vutuv.FediverseQuoteAuthorizationTest do
  @moduledoc """
  Consent-respecting quote posts, the answering half (FEP-044f, issue #1608).

  The thing under test is a **permission**, so most of these assert what does
  *not* happen: no stamp for a post whose audience is narrowed, none for a
  frozen one, none for a member who switched quoting off, and — the one that is
  easy to get wrong — no stamp for a "quote" hosted on our own installation,
  which would be a stranger talking us into authorizing one of our own posts
  against another.

  async: false — the inbound caps live in the shared `Vutuv.RateLimiter` ETS
  table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  import Ecto.Query
  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.QuoteAuthorization
  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  @public "https://www.w3.org/ns/activitystreams#Public"
  @actor "https://social.example/users/alice"
  @inbox "https://social.example/users/alice/inbox"
  @quote_post "https://social.example/users/alice/statuses/1"

  setup do
    Vutuv.RateLimiter.reset()
    Repo.delete_all(Delivery)

    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    post = create_post!(user, %{"body" => "Worth quoting."})

    {:ok, user: user, post: post}
  end

  defp requester(overrides \\ %{}) do
    Map.merge(%{uri: @actor, handle: "alice", name: "Alice", inbox: @inbox}, overrides)
  end

  defp quote_request(user, post, overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "QuoteRequest",
        "id" => "#{@actor}/quote_requests/1",
        "actor" => @actor,
        "object" => Docs.note_url(user, post.id),
        "instrument" => %{
          "id" => @quote_post,
          "type" => "Note",
          "attributedTo" => @actor,
          "quote" => Docs.note_url(user, post.id)
        }
      },
      overrides
    )
  end

  defp stamps, do: Repo.all(from(a in QuoteAuthorization, order_by: a.id))

  defp delivered do
    Delivery
    |> Repo.all()
    |> Enum.map(&Jason.decode!(&1.activity_json))
  end

  describe "the policy a Note advertises" do
    test "names the public collection while the member allows quoting", %{
      user: user,
      post: post
    } do
      note = Docs.note(post, user)

      assert %{"canQuote" => %{"automaticApproval" => [@public], "manualApproval" => []}} =
               note["interactionPolicy"]
    end

    test "names only the author once the member switches quoting off", %{post: post} do
      user = insert(:activated_user, fediverse_followers?: true, fediverse_quotes?: false)
      note = Docs.note(post, user)

      assert %{"canQuote" => %{"automaticApproval" => [approval]}} = note["interactionPolicy"]
      assert approval == Docs.actor_url(user)
      refute approval == @public
    end

    test "the standalone document defines the policy terms it uses", %{user: user, post: post} do
      # Without the JSON-LD terms a conforming consumer drops the policy, so the
      # page would promise nothing while the delivered copy promised quoting.
      context = Docs.note_document(post, user)["@context"]

      assert is_list(context)
      assert "https://www.w3.org/ns/activitystreams" in context
      assert Enum.any?(context, &(is_map(&1) and Map.has_key?(&1, "interactionPolicy")))
    end
  end

  describe "answering a QuoteRequest" do
    test "issues a stamp and an Accept whose result is that stamp", %{user: user, post: post} do
      request = quote_request(user, post)

      assert :ok = Fediverse.record_quote_request(user, request, requester())

      assert [%QuoteAuthorization{} = stamp] = stamps()
      assert stamp.post_id == post.id
      assert stamp.user_id == user.id
      assert stamp.interacting_object_uri == @quote_post
      assert stamp.actor_uri == @actor
      assert stamp.inbox_uri == @inbox
      assert stamp.note_uri == Docs.note_url(user, post.id)

      assert [accept] = delivered()
      assert accept["type"] == "Accept"
      assert accept["object"]["type"] == "QuoteRequest"
      assert accept["object"]["id"] == request["id"]

      # The whole mechanism: `result` has to be the stamp's own URL, exactly.
      assert accept["result"] == Docs.quote_authorization_url(user, post.id, stamp.id)
    end

    test "the echoed request carries the quoting post as an id, not as their document",
         %{user: user, post: post} do
      :ok = Fediverse.record_quote_request(user, quote_request(user, post), requester())

      assert [accept] = delivered()
      assert accept["object"]["instrument"] == @quote_post
    end

    test "a redelivered request re-answers without minting a second permission", %{
      user: user,
      post: post
    } do
      request = quote_request(user, post)

      assert :ok = Fediverse.record_quote_request(user, request, requester())
      assert :ok = Fediverse.record_quote_request(user, request, requester())

      assert [_only_one] = stamps()
      assert length(delivered()) == 2
    end

    test "a second quoting post gets its own stamp", %{user: user, post: post} do
      :ok = Fediverse.record_quote_request(user, quote_request(user, post), requester())

      other =
        quote_request(user, post, %{
          "id" => "#{@actor}/quote_requests/2",
          "instrument" => %{"id" => "#{@actor}/statuses/2", "attributedTo" => @actor}
        })

      :ok = Fediverse.record_quote_request(user, other, requester())

      assert length(stamps()) == 2
    end
  end

  describe "refusals the requester is told about" do
    test "a member who switched quoting off gets a Reject and grants nothing", %{post: post} do
      user = insert(:activated_user, fediverse_followers?: true, fediverse_quotes?: false)
      {:ok, _actor} = Fediverse.ensure_actor(user)
      post = create_post!(user, %{"body" => post.body})

      assert :skip = Fediverse.record_quote_request(user, quote_request(user, post), requester())
      assert stamps() == []
    end

    test "a request naming no quoting post at all is rejected", %{user: user, post: post} do
      request = quote_request(user, post) |> Map.delete("instrument")

      assert :ok = Fediverse.record_quote_request(user, request, requester())

      assert stamps() == []
      assert [reject] = delivered()
      assert reject["type"] == "Reject"
    end

    test "a quoting post hosted here is rejected rather than authorized", %{
      user: user,
      post: post
    } do
      # A stranger must not be able to talk this installation into stamping one
      # of its own posts as the quote: the stamp would then vouch for a pairing
      # nobody here ever made.
      local = Docs.note_url(user, post.id)
      request = quote_request(user, post, %{"instrument" => %{"id" => local}})

      assert :ok = Fediverse.record_quote_request(user, request, requester())

      assert stamps() == []
      assert [%{"type" => "Reject"}] = delivered()
    end
  end

  describe "silence, because answering would disclose something" do
    test "a post whose audience is narrowed grants nothing and says nothing", %{
      user: user,
      post: post
    } do
      {:ok, _} =
        Posts.update_post(post, %{
          "body" => post.body,
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      assert :skip = Fediverse.record_quote_request(user, quote_request(user, post), requester())
      assert stamps() == []
      assert delivered() == []
    end

    test "a frozen post grants nothing", %{user: user, post: post} do
      frozen = %{post | frozen_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)}

      Repo.update_all(from(p in Posts.Post, where: p.id == ^post.id),
        set: [frozen_at: frozen.frozen_at]
      )

      assert :skip = Fediverse.record_quote_request(user, quote_request(user, post), requester())
      assert stamps() == []
      assert delivered() == []
    end

    test "a request naming somebody else's post grants nothing", %{user: user, post: post} do
      stranger = insert(:activated_user, fediverse_followers?: true)

      assert :skip =
               Fediverse.record_quote_request(stranger, quote_request(user, post), requester())

      assert stamps() == []
      assert delivered() == []
    end
  end

  describe "withdrawal" do
    test "revoking a post drops its stamps and tells the quoting server", %{
      user: user,
      post: post
    } do
      :ok = Fediverse.record_quote_request(user, quote_request(user, post), requester())
      assert [stamp] = stamps()
      Repo.delete_all(Delivery)

      assert :ok = Fediverse.revoke_quote_authorizations(post)

      assert stamps() == []

      assert Enum.any?(delivered(), fn activity ->
               activity["type"] == "Delete" and
                 activity["object"]["formerType"] == "QuoteAuthorization" and
                 activity["object"]["id"] ==
                   Docs.quote_authorization_url(user, post.id, stamp.id)
             end)
    end

    test "deleting the post takes the permission with it", %{user: user, post: post} do
      :ok = Fediverse.record_quote_request(user, quote_request(user, post), requester())
      assert [_stamp] = stamps()

      {:ok, _} = Posts.delete_post(post)

      assert stamps() == []
    end

    test "the stamp is findable only under its own post", %{user: user, post: post} do
      :ok = Fediverse.record_quote_request(user, quote_request(user, post), requester())
      assert [stamp] = stamps()

      other = create_post!(user, %{"body" => "Another post entirely."})

      assert %QuoteAuthorization{} = Fediverse.get_quote_authorization(post.id, stamp.id)
      assert is_nil(Fediverse.get_quote_authorization(other.id, stamp.id))
    end
  end
end
