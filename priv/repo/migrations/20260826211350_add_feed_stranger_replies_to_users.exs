defmodule Vutuv.Repo.Migrations.AddFeedStrangerRepliesToUsers do
  @moduledoc """
  Issue #1740: whether the newsfeed carries answers written to accounts the
  reader does not follow.

  Nullable and **without** a database default, like every other preference
  column (`Vutuv.Prefs`): NULL is "never chose", which is what lets the
  installation default at /admin/preferences still reach this member. A column
  default here would silently turn every existing member into someone who had
  chosen, and the admin knob would then move nothing.

  Purely additive, so the currently deployed release is unaffected (N-1).
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:feed_stranger_replies?, :boolean)
    end
  end
end
