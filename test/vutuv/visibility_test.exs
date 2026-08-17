defmodule Vutuv.VisibilityTest do
  @moduledoc """
  The contact-visibility ladder's own maths (issue #1521): who stands on which
  rung. Everything above this — the profile card, the section pages, the CV, the
  API, the vCard — filters on `scope/2`'s answer, so a wrong verdict here is a
  wrong answer everywhere at once.

  The load-bearing case is the **one-way follower**, tested in both directions:
  anybody can create a one-way follow by clicking a button, so if it reached the
  `"connected"` rung a stranger could hand themselves a member's phone number,
  which is the exact scam-call problem the ladder exists to prevent.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Accounts
  alias Vutuv.Visibility

  defp member, do: insert(:user, email_confirmed?: true)

  describe "levels/0 and valid?/1" do
    test "the ladder is the four rungs, widest audience first" do
      assert Visibility.levels() == ~w(everyone members connected private)
    end

    test "valid?/1 accepts exactly those" do
      for level <- Visibility.levels(), do: assert(Visibility.valid?(level))
      refute Visibility.valid?("followers")
      refute Visibility.valid?("public")
      refute Visibility.valid?(nil)
    end
  end

  describe "scope/2" do
    test "an anonymous viewer sees only the public rung" do
      assert Visibility.scope(member(), nil) == ["everyone"]
    end

    test "the owner sees every rung, their own private rows included" do
      owner = member()
      assert Visibility.scope(owner, owner) == Visibility.levels()
    end

    test "a signed-in stranger reaches 'members' but not 'connected'" do
      scope = Visibility.scope(member(), member())

      assert "everyone" in scope
      assert "members" in scope
      refute "connected" in scope
      refute "private" in scope
    end

    test "a one-way follower does NOT reach 'connected'" do
      owner = member()
      follower = member()
      # The follower follows the owner; the owner has not followed back, so no
      # decision by the owner took part in this relationship.
      insert(:follow, follower: follower, followee: owner)

      refute "connected" in Visibility.scope(owner, follower)
    end

    test "somebody the owner follows does NOT reach 'connected' either" do
      owner = member()
      followed = member()
      insert(:follow, follower: owner, followee: followed)

      refute "connected" in Visibility.scope(owner, followed)
    end

    test "a mutual follow does reach 'connected', but never 'private'" do
      owner = member()
      contact = member()
      insert(:follow, follower: owner, followee: contact)
      insert(:follow, follower: contact, followee: owner)

      scope = Visibility.scope(owner, contact)

      assert "connected" in scope
      refute "private" in scope
    end

    test "the mutual follow has to be mutual on THIS pair, not merely present" do
      owner = member()
      contact = member()
      bystander = member()

      # A full mutual pair that does not involve the owner, plus the contact
      # following the owner one-way. A naive "is there a follow-back anywhere"
      # check would pass this; the pair test must not.
      insert(:follow, follower: contact, followee: bystander)
      insert(:follow, follower: bystander, followee: contact)
      insert(:follow, follower: contact, followee: owner)

      refute "connected" in Visibility.scope(owner, contact)
    end
  end

  describe "visible_to?/3" do
    test "each rung answers for the viewer who stands on it" do
      owner = member()
      stranger = member()
      contact = member()
      insert(:follow, follower: owner, followee: contact)
      insert(:follow, follower: contact, followee: owner)

      assert Visibility.visible_to?("everyone", owner, nil)
      refute Visibility.visible_to?("members", owner, nil)
      refute Visibility.visible_to?("connected", owner, nil)
      refute Visibility.visible_to?("private", owner, nil)

      assert Visibility.visible_to?("members", owner, stranger)
      refute Visibility.visible_to?("connected", owner, stranger)

      assert Visibility.visible_to?("connected", owner, contact)
      refute Visibility.visible_to?("private", owner, contact)

      assert Visibility.visible_to?("private", owner, owner)
    end

    test "an unknown or nil rung falls back to public, matching a pre-column row" do
      owner = member()

      assert Visibility.visible_to?(nil, owner, nil)
      assert Visibility.visible_to?("followers", owner, nil)
    end
  end

  describe "labels and hints" do
    test "every rung has a label, and every rung but the public one a note" do
      for level <- Visibility.levels() do
        assert is_binary(Visibility.label(level))
        assert Visibility.label(level) != ""
        assert is_binary(Visibility.hint(level))
      end

      # The note is what the profile's lock glyph says. A public row carries no
      # lock, so it must answer nil rather than an empty tooltip.
      assert Visibility.visibility_note("everyone") == nil

      for level <- ~w(members connected private) do
        assert is_binary(Visibility.visibility_note(level))
      end
    end
  end

  describe "Accounts.contact_scope/2" do
    test "matches the ladder when no exclusion is in play" do
      owner = member()
      contact = member()
      insert(:follow, follower: owner, followee: contact)
      insert(:follow, follower: contact, followee: owner)

      assert Accounts.contact_scope(owner, contact) == Visibility.scope(owner, contact)
    end

    test "an excluded member drops back to the anonymous scope" do
      owner = member()
      contact = member()
      insert(:follow, follower: owner, followee: contact)
      insert(:follow, follower: contact, followee: owner)

      assert "connected" in Accounts.contact_scope(owner, contact)

      insert(:viewer_exclusion, user: owner, excluded_user: contact, domain: nil)

      # Subtracting only: they keep the public rung and lose everything the
      # owner opened up to members and to connections.
      assert Accounts.contact_scope(owner, contact) == ["everyone"]
    end

    test "a blocked member drops back too, without a second list to maintain" do
      owner = member()
      blocked = member()
      insert(:follow, follower: owner, followee: blocked)
      insert(:follow, follower: blocked, followee: owner)

      Vutuv.Social.block_user(owner, blocked)

      assert Accounts.contact_scope(owner, blocked) == ["everyone"]
    end

    test "the anonymous and owner cases are not narrowed by an exclusion" do
      owner = member()
      insert(:viewer_exclusion, user: owner, domain: "example.com")

      assert Accounts.contact_scope(owner, nil) == ["everyone"]
      assert Accounts.contact_scope(owner, owner) == Visibility.levels()
    end
  end
end
