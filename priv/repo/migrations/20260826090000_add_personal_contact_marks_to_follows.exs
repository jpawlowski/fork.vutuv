defmodule Vutuv.Repo.Migrations.AddPersonalContactMarksToFollows do
  use Ecto.Migration

  @moduledoc """
  The two private marks a member may put on their own follow (issue #1705):
  `personally_known` — "I have actually met this person" — and `note`, a free
  text only its author ever reads.

  Both belong to the **follower**, not to the person followed: nothing here is
  ever rendered on the followee's profile, sent in a notification, or counted
  anywhere public. They are the follower's own filing marks.

  Deliberately two columns and not one: a note is where you write down what you
  want to remember about somebody, and "we have met" is a fact about the
  relationship. A member who notes "answers fast, ask about the Elixir job" has
  not thereby said they know that person, and the address-book filter keys on
  the flag alone.

  `note` is `:text`, not varchar(255) — it is prose, and a member typing into a
  box has no idea a limit exists (see CLAUDE.md). The changeset caps it at
  10,000 characters, the same ceiling the profile descriptions carry.

  N-1 safe: two additions, one with a default, and the previous release neither
  reads nor writes either.
  """

  def change do
    alter table(:follows) do
      add(:personally_known, :boolean, null: false, default: false)
      add(:note, :text)
    end

    # The address-book filter's narrowest level asks exactly this question, per
    # follower: "which of my follows did I mark?". Partial, because `false` is
    # the answer for nearly every row and indexing those buys nothing.
    create(
      index(:follows, [:follower_id], where: "personally_known", name: "follows_personally_known_index")
    )
  end
end
