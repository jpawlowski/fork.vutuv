defmodule Vutuv.CardDavTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.CardDav
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Repo
  alias Vutuv.Social

  defp owner(level) do
    insert(:activated_user, carddav_sharing: level)
  end

  defp published_ids(user) do
    user |> CardDav.contacts() |> Enum.map(& &1.contact.id) |> Enum.sort()
  end

  describe "sharing levels" do
    test "off publishes nothing, whoever is followed" do
      me = owner("off")
      them = insert(:activated_user)
      follow!(me, them)

      assert CardDav.contacts(me) == []
      refute CardDav.publishing?(me)
    end

    test "following publishes everybody I follow" do
      me = owner("following")
      a = insert(:activated_user)
      b = insert(:activated_user)
      follow!(me, a)
      follow!(me, b)

      assert published_ids(me) == Enum.sort([a.id, b.id])
    end

    test "mutual publishes only the follows that come back" do
      me = owner("mutual")
      both = insert(:activated_user)
      one_way = insert(:activated_user)
      connect!(me, both)
      follow!(me, one_way)

      assert published_ids(me) == [both.id]
    end

    test "personally_known publishes only the marked follows" do
      me = owner("personally_known")
      known = insert(:activated_user)
      unknown = insert(:activated_user)
      follow!(me, known)
      follow!(me, unknown)
      {:ok, _follow} = Social.set_follow_marks(me, known, %{personally_known: true})

      assert published_ids(me) == [known.id]
    end

    test "a mark is not needed for the wider levels, and never leaks the other way" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(them, me)
      follow!(me, them)
      {:ok, _follow} = Social.set_follow_marks(them, me, %{personally_known: true, note: "hi"})

      # Their mark about me is theirs; my card of them carries neither.
      assert [%{note: nil}] = CardDav.contacts(me)
    end
  end

  describe "the contact's own say (carddav_visibility)" do
    test "a contact set to nobody is in no book at all", %{} do
      me = owner("following")
      them = insert(:activated_user, carddav_visibility: "nobody")
      follow!(me, them)

      assert CardDav.contacts(me) == []
      assert CardDav.counts(me)["following"] == 0
    end

    test "it outranks the subscriber, mark and all", %{} do
      me = owner("personally_known")
      them = insert(:activated_user, carddav_visibility: "nobody")
      follow!(me, them)
      {:ok, _follow} = Social.set_follow_marks(me, them, %{personally_known: true})

      # Whoever the data is about decides. A subscriber cannot mark their way
      # past somebody else's opt-out.
      assert CardDav.contacts(me) == []
    end

    test "mutual keeps them out of a one-way follower's book, and in a mutual one", %{} do
      picky = insert(:activated_user, carddav_visibility: "mutual")

      one_way = owner("following")
      follow!(one_way, picky)

      both = owner("following")
      connect!(both, picky)

      assert published_ids(one_way) == []
      assert published_ids(both) == [picky.id]
    end

    test "followers is the default, so an untouched member is carried", %{} do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)

      assert them.carddav_visibility == "followers"
      assert published_ids(me) == [them.id]
    end

    test "switching to nobody withdraws the card from the books that hold it", %{} do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)
      assert CardDav.refresh(me) == 1

      {:ok, _them} = Vutuv.Accounts.update_user(them, %{"carddav_visibility" => "nobody"})

      assert CardDav.refresh(me) == 2
      assert CardDav.live_cards(me) == []
      assert [%{deleted: true}] = CardDav.stored_cards(me)
    end
  end

  describe "who drops out" do
    test "a followee whom moderation hid is not published" do
      me = owner("following")
      them = insert(:activated_user, frozen_at: DateTime.utc_now() |> DateTime.truncate(:second))
      follow!(me, them)

      assert CardDav.contacts(me) == []
    end

    test "organization follows never appear — an address book is people" do
      me = owner("following")
      page = insert(:organization)
      {:ok, _follow} = Social.follow_organization(me, page)

      assert CardDav.contacts(me) == []
    end
  end

  describe "counts/1" do
    test "counts each level without rendering a card" do
      me = owner("off")
      known = insert(:activated_user)
      mutual = insert(:activated_user)
      plain = insert(:activated_user)
      connect!(me, mutual)
      follow!(me, known)
      follow!(me, plain)
      {:ok, _follow} = Social.set_follow_marks(me, known, %{personally_known: true})

      assert CardDav.counts(me) == %{
               "personally_known" => 1,
               "mutual" => 1,
               "following" => 3
             }
    end
  end

  describe "refresh/1" do
    test "writes one card per contact and bumps the revision once" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)

      assert CardDav.refresh(me) == 1
      assert [card] = CardDav.live_cards(me)
      assert card.contact_id == them.id
      refute card.deleted

      # Nothing changed: no write, no new revision, so every client's token
      # stays valid and its next poll transfers nothing.
      assert CardDav.refresh(me) == 1
    end

    test "an unfollowed contact becomes a tombstone rather than vanishing" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)
      assert CardDav.refresh(me) == 1

      Repo.delete_all(Vutuv.Social.Follow)

      assert CardDav.refresh(me) == 2
      assert CardDav.live_cards(me) == []
      assert [card] = CardDav.stored_cards(me)
      assert card.deleted
      assert card.revision == 2
    end

    test "switching the level off withdraws every card" do
      me = owner("following")
      follow!(me, insert(:activated_user))
      CardDav.refresh(me)

      {:ok, me} = Vutuv.Accounts.update_user(me, %{"carddav_sharing" => "off"})

      CardDav.refresh(me)
      assert CardDav.live_cards(me) == []
      assert [%{deleted: true}] = CardDav.stored_cards(me)
    end

    test "a changed profile changes the card's etag and the revision" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)
      assert CardDav.refresh(me) == 1
      [before] = CardDav.live_cards(me)

      {:ok, _them} = Vutuv.Accounts.update_user(them, %{"last_name" => "Renamed"})

      assert CardDav.refresh(me) == 2
      assert [%{etag: etag}] = CardDav.live_cards(me)
      refute etag == before.etag
    end

    test "a changed note changes the card, because the note is in the card" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)
      CardDav.refresh(me)
      [before] = CardDav.live_cards(me)

      {:ok, _follow} = Social.set_follow_marks(me, them, %{note: "met at ElixirConf"})

      CardDav.refresh(me)
      assert [%{etag: etag}] = CardDav.live_cards(me)
      refute etag == before.etag
    end
  end

  describe "changes_since/2" do
    test "reports only what moved after the token" do
      me = owner("following")
      first = insert(:activated_user)
      follow!(me, first)
      revision = CardDav.refresh(me)

      second = insert(:activated_user)
      follow!(me, second)
      CardDav.refresh(me)

      assert {:ok, rows, new_revision} = CardDav.changes_since(me, revision)
      assert new_revision == revision + 1
      assert [row] = rows
      assert row.contact_id == second.id
    end

    test "an initial sync (revision 0) reports everything" do
      me = owner("following")
      follow!(me, insert(:activated_user))
      follow!(me, insert(:activated_user))
      CardDav.refresh(me)

      assert {:ok, rows, _revision} = CardDav.changes_since(me, 0)
      assert length(rows) == 2
    end

    test "a token from the future is refused rather than guessed at" do
      me = owner("following")
      assert {:error, :invalid_token} = CardDav.changes_since(me, 99)
    end
  end

  describe "the count beside each level" do
    test "counts exactly what the book publishes, blocks included", %{} do
      me = owner("following")
      kept = insert(:activated_user)
      blocked = insert(:activated_user)
      follow!(me, kept)
      follow!(me, blocked)
      {:ok, _block} = Social.block_user(me, blocked)

      # What enforces this is not anything in `Vutuv.CardDav`: blocking severs
      # both follow edges (`Social.sever_between/2`), so a blocked member is
      # not in `follow_query/2`'s result for the count or for the book. The
      # `blocked_user_ids/1` filter in `build_entries/1` is belt and braces
      # over that, which is why this test passes with and without it — it pins
      # the promise, and names the layer that keeps it, so nobody adds a second
      # exclusion on the assumption the two answers can drift.
      assert CardDav.counts(me)["following"] == 1
      assert published_ids(me) == [kept.id]
    end

    test "a block in the other direction cuts the card too", %{} do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)
      {:ok, _block} = Social.block_user(them, me)

      assert CardDav.counts(me)["following"] == 0
      assert published_ids(me) == []
    end
  end

  describe "render_card/2" do
    test "carries a stable UID and the private note" do
      me = owner("following")
      them = insert(:activated_user, first_name: "Ada", last_name: "Lovelace")
      follow!(me, them)
      {:ok, _follow} = Social.set_follow_marks(me, them, %{note: "met at ElixirConf"})

      assert [entry] = CardDav.contacts(me)
      card = CardDav.render_card(entry, include_photo: false)

      assert card =~ "UID:urn:uuid:#{them.id}"
      assert card =~ "FN:Ada Lovelace"
      assert card =~ "NOTE:met at ElixirConf"
    end

    test "every phone label reaches the phone as a registered vCard TEL type" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)

      for type <- PhoneNumber.number_types() do
        insert(:phone_number, user: them, number_type: type)
      end

      assert [entry] = CardDav.contacts(me)
      card = CardDav.render_card(entry, include_photo: false)

      # RFC 2426 s3.3.1 knows these words and no others; a Contacts app that
      # meets an unknown one files the number under no label at all. "Work
      # Cell" is the one vutuv label with no single token of its own, and it is
      # why the comma may not be escaped: `TYPE=WORK\,CELL` would be one made-up
      # type rather than the two real ones.
      assert card =~ "TEL;TYPE=HOME:"
      assert card =~ "TEL;TYPE=CELL:"
      assert card =~ "TEL;TYPE=WORK:"
      assert card =~ "TEL;TYPE=WORK,CELL:"
      assert card =~ "TEL;TYPE=FAX:"

      refute card =~ "TYPE=Work Cell"
      refute card =~ "TYPE=WORK\\,CELL"
    end

    test "a label no longer in the vocabulary degrades to VOICE, never to itself" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)
      # A row written before `number_types/0` was narrowed: the changeset would
      # refuse it today, the database still holds it.
      Repo.insert_all({"phone_numbers", PhoneNumber}, [
        %{
          id: Vutuv.UUIDv7.generate(),
          user_id: them.id,
          value: "+49 30 111111",
          number_type: "Assistant",
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      ])

      assert [entry] = CardDav.contacts(me)
      card = CardDav.render_card(entry, include_photo: false)

      assert card =~ "TEL;TYPE=VOICE:+49 30 111111"
      refute card =~ "Assistant"
    end

    test "the etag is stable across renders — REV must not enter it" do
      me = owner("following")
      them = insert(:activated_user)
      follow!(me, them)

      assert [entry] = CardDav.contacts(me)
      assert CardDav.etag(entry) == CardDav.etag(entry)
    end
  end
end
