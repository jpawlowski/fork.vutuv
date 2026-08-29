defmodule Vutuv.CardDavPushTest do
  @moduledoc """
  The WebDAV-Push half of the address book (issue #1705): when a device is told
  that its book moved, and — just as important — when it is not.

  `async: false` because these flip `:web_push_enabled`, which is global and
  read by every push path in the app (`web_push_test.exs` is sync for the same
  reason).
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.CardDav
  alias Vutuv.CardDav.PushSubscription
  alias Vutuv.Repo
  alias Vutuv.Social

  defmodule Recorder do
    @moduledoc false
    def send_body(target, body) do
      send(self(), {:pushed, target, body})
      Application.get_env(:vutuv, :carddav_push_result, :ok)
    end
  end

  setup do
    Application.put_env(:vutuv, :web_push_enabled, true)
    Application.put_env(:vutuv, :carddav_push_sender, Recorder)

    on_exit(fn ->
      Application.put_env(:vutuv, :web_push_enabled, false)
      Application.delete_env(:vutuv, :carddav_push_sender)
      Application.delete_env(:vutuv, :carddav_push_result)
    end)

    owner = insert(:activated_user, carddav_sharing: "following")
    %{owner: owner}
  end

  defp subscribe(owner, attrs \\ %{}) do
    {:ok, subscription} =
      CardDav.register_push(
        owner,
        Map.merge(
          %{
            push_resource: "https://push.example.net/abc",
            p256dh:
              "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
            auth_secret: "BTBZMqHH6r4Tts7J_aSIgg"
          },
          attrs
        )
      )

    subscription
  end

  describe "registration" do
    test "caps an expiry a device asks too far ahead", %{owner: owner} do
      far = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)
      subscription = subscribe(owner, %{expires_at: far})

      ceiling = DateTime.add(DateTime.utc_now(), CardDav.push_max_expiry_days() * 86_400, :second)
      assert DateTime.compare(subscription.expires_at, ceiling) != :gt
    end

    test "defaults an absent expiry rather than living forever", %{owner: owner} do
      subscription = subscribe(owner)
      assert DateTime.compare(subscription.expires_at, DateTime.utc_now()) == :gt
    end

    test "refuses an endpoint pointing inside the network", %{owner: owner} do
      assert {:error, changeset} =
               CardDav.register_push(owner, %{
                 push_resource: "https://127.0.0.1/push",
                 p256dh:
                   "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
                 auth_secret: "BTBZMqHH6r4Tts7J_aSIgg"
               })

      assert changeset.errors[:push_resource]
    end

    test "refuses a key it could not encrypt to", %{owner: owner} do
      assert {:error, changeset} =
               CardDav.register_push(owner, %{
                 push_resource: "https://push.example.net/abc",
                 p256dh: "not-a-key",
                 auth_secret: "BTBZMqHH6r4Tts7J_aSIgg"
               })

      assert changeset.errors[:p256dh]
    end
  end

  describe "the topic" do
    test "is stable for a member and different between members", %{owner: owner} do
      other = insert(:activated_user)

      assert CardDav.topic(owner) == CardDav.topic(owner)
      refute CardDav.topic(owner) == CardDav.topic(other)
    end
  end

  # The sweeper only looks at a registration it has not checked recently, so a
  # test that wants a second pass has to move the clock rather than call twice.
  # A date far in the past says "due" without restating the production
  # arithmetic — a second copy of that formula is exactly what the shared
  # constant exists to avoid.
  defp age_registrations,
    do: Repo.update_all(PushSubscription, set: [checked_at: ~N[2000-01-01 00:00:00]])

  describe "push_due/1" do
    test "notifies a device once the book has moved, and not before", %{owner: owner} do
      subscription = subscribe(owner)

      # An empty book at revision 0: nothing to say.
      assert CardDav.push_due() == 0
      refute_received {:pushed, _target, _body}

      follow!(owner, insert(:activated_user))

      age_registrations()
      assert CardDav.push_due() == 1
      assert_received {:pushed, target, body}
      assert target.endpoint == "https://push.example.net/abc"
      assert body =~ "push-message"
      assert body =~ CardDav.topic(owner)
      assert body =~ "urn:vutuv:carddav:1"

      # The same state again says nothing.
      age_registrations()
      assert CardDav.push_due() == 0
      refute_received {:pushed, _target, _body}

      assert Repo.reload(subscription).last_revision == 1
    end

    test "a withdrawn contact is a change worth a push", %{owner: owner} do
      subscribe(owner)
      contact = insert(:activated_user)
      follow!(owner, contact)
      CardDav.push_due()
      assert_received {:pushed, _target, _body}

      Repo.delete_all(Social.Follow)

      age_registrations()
      assert CardDav.push_due() == 1
      assert_received {:pushed, _target, body}
      assert body =~ "urn:vutuv:carddav:2"
    end

    test "a registration just checked is not due again on the next pass", %{owner: owner} do
      subscription = subscribe(owner)
      follow!(owner, insert(:activated_user))

      assert CardDav.push_due() == 1
      assert_received {:pushed, _target, _body}
      stamped = Repo.reload(subscription).checked_at

      # The CLAUDE.md sweeper shape, from the other side: a pass that fires
      # again straight away must find nothing to do, or a second sweeper (or a
      # manual run) doubles the work of re-rendering every book.
      follow!(owner, insert(:activated_user))
      assert CardDav.push_due() == 0
      refute_received {:pushed, _target, _body}
      assert Repo.reload(subscription).checked_at == stamped

      # And once the clock has moved it is due, so nothing was lost.
      age_registrations()
      assert CardDav.push_due() == 1
    end

    test "a member's devices share one refresh instead of one each", %{owner: owner} do
      for _ <- 1..20, do: follow!(owner, insert(:activated_user))

      subscribe(owner)
      CardDav.push_due()
      age_registrations()
      follow!(owner, insert(:activated_user))
      {single, _} = Vutuv.WorkCounter.count_reductions(&CardDav.push_due/0)

      subscribe(owner, %{push_resource: "https://push.example.net/def"})
      subscribe(owner, %{push_resource: "https://push.example.net/ghi"})

      age_registrations()
      follow!(owner, insert(:activated_user))
      {three, sent} = Vutuv.WorkCounter.count_reductions(&CardDav.push_due/0)

      assert sent == 3

      # Refreshing a 22-contact book dwarfs the three encrypt-and-send calls,
      # so three devices used to cost about three times one. Twice is well
      # above the shared-refresh shape and well below the per-device one.
      assert three < single * 2,
             "three devices cost #{three} reductions against #{single} for one — " <>
               "the book is being refreshed per device"
    end

    test "stamps the clock even when it sends nothing", %{owner: owner} do
      subscription = subscribe(owner)
      assert is_nil(subscription.checked_at)

      CardDav.push_due()

      # This is the sweeper trap from CLAUDE.md: an item that had no work to do
      # must still leave the front of an oldest-first queue.
      assert %NaiveDateTime{} = Repo.reload(subscription).checked_at
    end

    test "a failed delivery keeps the revision, so the next pass retries it", %{owner: owner} do
      Application.put_env(:vutuv, :carddav_push_result, {:error, :timeout})
      subscription = subscribe(owner)
      follow!(owner, insert(:activated_user))

      assert CardDav.push_due() == 0
      assert_received {:pushed, _target, _body}

      reloaded = Repo.reload(subscription)
      assert %NaiveDateTime{} = reloaded.checked_at
      assert reloaded.last_revision == 0

      Application.put_env(:vutuv, :carddav_push_result, :ok)
      age_registrations()
      assert CardDav.push_due() == 1
    end

    test "a dead endpoint takes its registration with it", %{owner: owner} do
      Application.put_env(:vutuv, :carddav_push_result, {:error, :gone})
      subscription = subscribe(owner)
      follow!(owner, insert(:activated_user))

      CardDav.push_due()

      refute Repo.get(PushSubscription, subscription.id)
    end

    test "an expired registration is dropped rather than notified", %{owner: owner} do
      subscription = subscribe(owner)
      follow!(owner, insert(:activated_user))

      subscription
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      assert CardDav.push_due() == 0
      refute_received {:pushed, _target, _body}
      refute Repo.get(PushSubscription, subscription.id)
    end

    test "keeps working when the Mastodon adapter is switched off", %{owner: owner} do
      # The address book is the second consumer of Web Push, and it is the one
      # an intranet installation may well want *without* ActivityPub. While the
      # transport switch also asked `MastodonApi.enabled?/0`, turning the
      # adapter off silently killed this — with no error and nothing logged,
      # against what `docs/ADMINS.md` promises.
      previous = Application.fetch_env!(:vutuv, :mastodon_api_enabled)
      Application.put_env(:vutuv, :mastodon_api_enabled, false)
      on_exit(fn -> Application.put_env(:vutuv, :mastodon_api_enabled, previous) end)

      subscribe(owner)
      follow!(owner, insert(:activated_user))

      assert CardDav.push_due() == 1
      assert_received {:pushed, _target, _body}
    end

    test "does nothing at all while Web Push is off", %{owner: owner} do
      Application.put_env(:vutuv, :web_push_enabled, false)
      subscribe(owner)
      follow!(owner, insert(:activated_user))

      assert CardDav.push_due() == 0
      refute_received {:pushed, _target, _body}
      refute CardDav.push_enabled?()
    end
  end
end
