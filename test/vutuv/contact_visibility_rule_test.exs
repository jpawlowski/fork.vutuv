defmodule Vutuv.ContactVisibilityRuleTest do
  @moduledoc """
  The contact ladder (issue #1521) is written down twice, and this file exists to
  keep the two copies honest.

  `Vutuv.Accounts.contact_scope/2` answers "which rungs may this viewer see of
  this owner" and is what a profile render uses: one owner, one resolution.
  `Vutuv.Accounts.contact_visible/2` is the same rule as a WHERE clause, for the
  two paths that ask about thousands of owners in one query — the search page and
  the LinkedIn contact match. Neither can be expressed in terms of the other:
  a scope per owner would be a query per owner, and the clause cannot hand a
  render a list of rungs.

  Two expressions of one rule drift. So rather than testing each against a
  hand-written expectation, this walks every rung against every kind of viewer
  and asserts the two **agree** — a mismatch fails here whichever half moved.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query
  import Vutuv.Factory

  alias Vutuv.Accounts
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Repo
  alias Vutuv.Visibility

  setup do
    owner = insert(:user)

    numbers =
      Map.new(Visibility.levels(), fn level ->
        {level, insert(:phone_number, user: owner, visibility: level)}
      end)

    stranger = insert(:user)

    connected = insert(:user)
    insert(:follow, follower: owner, followee: connected)
    insert(:follow, follower: connected, followee: owner)

    # A one-way follower is deliberately NOT a connection: the whole point of the
    # "connected" rung is that the owner took part in the decision.
    follower = insert(:user)
    insert(:follow, follower: follower, followee: owner)

    followee = insert(:user)
    insert(:follow, follower: owner, followee: followee)

    excluded = insert(:user)
    insert(:viewer_exclusion, user: owner, excluded_user: excluded, domain: nil)

    # Excluded by the domain of their confirmed address, and still connected —
    # the subtractive list has to beat the wider rung it is subtracted from.
    domain_excluded = insert(:user)
    insert(:email, user: domain_excluded, value: "someone@ausgeschlossen.example")
    insert(:viewer_exclusion, user: owner, domain: "ausgeschlossen.example")
    insert(:follow, follower: owner, followee: domain_excluded)
    insert(:follow, follower: domain_excluded, followee: owner)

    blocked = insert(:user)
    {:ok, _} = Vutuv.Social.block_user(owner, blocked)

    %{
      owner: owner,
      numbers: numbers,
      viewers: [
        {"the owner themselves", owner},
        {"a visitor who is not signed in", nil},
        {"a signed-in stranger", stranger},
        {"a connection", connected},
        {"somebody who follows the owner", follower},
        {"somebody the owner follows", followee},
        {"an excluded member", excluded},
        {"a connection excluded by email domain", domain_excluded},
        {"a blocked member", blocked}
      ]
    }
  end

  describe "the resolved scope and the WHERE clause" do
    test "agree for every rung and every kind of viewer", ctx do
      for {description, viewer} <- ctx.viewers,
          level <- Visibility.levels() do
        scope = Accounts.contact_scope(ctx.owner, viewer)
        expected = level in scope
        actual = visible_by_clause?(ctx.numbers[level], viewer)

        assert actual == expected,
               """
               The two halves of the contact rule disagree.

                 rung:     #{level}
                 viewer:   #{description}
                 scope:    #{inspect(scope)} -> #{expected}
                 clause:   #{actual}
               """
      end
    end

    test "let a member reach their own rows and nobody else's", ctx do
      other = insert(:user)
      insert(:phone_number, user: other, visibility: "private")

      for level <- Visibility.levels() do
        assert visible_by_clause?(ctx.numbers[level], ctx.owner)
      end

      refute visible_by_clause?(ctx.numbers["private"], other)
    end
  end

  describe "the email variant" do
    test "reads the previous release's rows out of the retired boolean", ctx do
      # Rows written before the migration carry a NULL visibility and mean their
      # audience through `public?` (see the migration's N-1 note). The clause has
      # to answer for those exactly as `contact_scope/2` does for the struct.
      published = insert(:email, user: ctx.owner)
      unpublished = insert(:email, user: ctx.owner, public?: false, visibility: "private")

      for email <- [published, unpublished] do
        Repo.update_all(from(e in "emails", where: e.id == type(^email.id, Vutuv.UUIDv7)),
          set: [visibility: nil]
        )
      end

      stranger = insert(:user)

      assert visible_by_clause?(published, stranger, :email)
      refute visible_by_clause?(unpublished, stranger, :email)
      assert visible_by_clause?(unpublished, ctx.owner, :email)
    end
  end

  # Asks the WHERE clause about exactly one row: does this contact row survive
  # for this viewer? Bound with the `:contact` alias the clause requires.
  defp visible_by_clause?(row, viewer, source \\ :plain) do
    schema = if source == :email, do: Vutuv.Accounts.Email, else: PhoneNumber

    from(c in schema, as: :contact, where: c.id == type(^row.id, Vutuv.UUIDv7))
    |> where(^Accounts.contact_visible(viewer, source))
    |> Repo.exists?()
  end
end
